import 'dart:async';

import 'package:flutter/foundation.dart';

import '../codec/mp1.dart';
import '../codec/rgba.dart';
import '../companion/ble.dart';
import '../companion/client.dart';
import '../companion/control.dart';
import '../geo/elevation.dart';
import '../geo/geo.dart';
import '../geo/los.dart';
import '../models/channel.dart';
import '../models/chat.dart';
import '../models/contact.dart';
import '../models/device.dart';
import '../models/repeater.dart';
import '../models/signal.dart';
import '../models/uri_card.dart';
import '../sim/sim_mesh.dart';
import '../transfer/catchup.dart';
import '../transfer/engine.dart';
import '../transfer/protocol.dart';

enum AppMode { simulator, bluetooth }

class NodeSession {
  NodeSession({
    required this.id,
    required this.name,
    required this.radio,
    required this.engine,
    required this.conversations,
  });

  String id;
  String name;
  final PacketRadio radio;
  final TransferEngine engine;
  final List<Conversation> conversations;
  StreamSubscription<TransferEvent>? sub;
  StreamSubscription<CompanionNotice>? noticeSub;

  CompanionControl? get companion =>
      radio is CompanionControl ? radio as CompanionControl : null;
}

class AppController extends ChangeNotifier {
  AppController() {
    _bootSimulator();
  }

  AppMode mode = AppMode.simulator;
  String activeNodeId = 'anna';
  String? status;
  String? error;

  final codec = Mp1Codec();
  final mesh = SimMesh();
  final sessions = <String, NodeSession>{};
  final bleHits = <BleScanHit>[];
  bool scanning = false;
  int homeTab = 0;
  final repeaterSessions = <String, RepeaterSession>{};
  final pings = <String, PingResult>{};
  final noiseSamples = <NoiseSample>[];
  final _pingStarted = <String, DateTime>{};
  final _pingTimers = <String, Timer>{};
  bool pingingAll = false;
  String? pathFocusKey;
  LosResult? lastLos;
  bool losBusy = false;
  double? selfLatOverride;
  double? selfLonOverride;
  double? selfAltOverride;
  double selfAglM = 2;
  bool useOnlineElevation = false;
  ElevationSource elevationSource = const SyntheticElevation();

  CompanionClient? _bleClient;
  BleTransport? _bleTransport;
  BleScanner? _scanner;
  StreamSubscription<List<BleScanHit>>? _scanSub;
  bool _connecting = false;

  NodeSession get active => sessions[activeNodeId]!;

  Conversation? _open;
  Conversation? get openConversation => _open;

  CompanionControl? get companion =>
      sessions[activeNodeId]?.companion ?? _bleClient;

  List<MeshContact> get contacts => companion?.contacts ?? const [];

  DeviceSelf? get self => companion?.self;

  RadioSettings? get radioSettings => companion?.radio;

  BatteryInfo? get battery => companion?.battery;

  FirmwareInfo? get firmware => companion?.firmware;

  void selectTab(int index) {
    homeTab = index;
    notifyListeners();
  }

  void _bootSimulator() {
    _disposeSessions();
    pings.clear();
    noiseSamples.clear();
    lastLos = null;
    pathFocusKey = null;
    mode = AppMode.simulator;
    final anna = SimIdentity(
      id: 'anna',
      name: 'Anna',
      publicKey: keyFromSeed(11),
      lat: 48.137154,
      lon: 11.576124,
      alt: 515,
    );
    final ben = SimIdentity(
      id: 'ben',
      name: 'Ben',
      publicKey: keyFromSeed(23),
      lat: 48.1520,
      lon: 11.6120,
      alt: 525,
    );
    final annaRadio = SimRadio(mesh: mesh, identity: anna);
    final benRadio = SimRadio(mesh: mesh, identity: ben);
    annaRadio.loadPeers();
    benRadio.loadPeers();
    final relay = MeshContact(
      publicKey: keyFromSeed(99),
      name: 'Relay1',
      type: AdvType.repeater,
      outPath: Uint8List.fromList([0x02, 0x07]),
      lastAdvert: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      lat: 47.7033,
      lon: 12.0123,
      alt: 1838,
    );
    mesh.repeater = SimVirtualRepeater(contact: relay);
    annaRadio.contacts.add(relay);
    benRadio.contacts.add(relay);
    sessions['anna'] = _sessionForSim(annaRadio);
    sessions['ben'] = _sessionForSim(benRadio);
    activeNodeId = 'anna';
    _open = active.conversations.first;
    status = 'Simulator: Anna und Ben teilen sich ein virtuelles Mesh.';
    notifyListeners();
  }

  NodeSession _sessionForSim(SimRadio radio) {
    final engine = TransferEngine(
      radio: radio,
      codec: codec,
      budget: AirtimeBudget(airtimeFactor: 0.25, bitsPerSecond: 2400),
    );
    final session = NodeSession(
      id: radio.identity.id,
      name: radio.identity.name,
      radio: radio,
      engine: engine,
      conversations: _convosFrom(
        idPrefix: radio.identity.id,
        channels: radio.channels,
        contacts: radio.contacts,
      ),
    );
    session.sub = engine.events.listen((e) => _onEvent(session, e));
    session.noticeSub = radio.notices.listen((n) => _onNotice(session, n));
    return session;
  }

  List<Conversation> _convosFrom({
    required String idPrefix,
    required List<MeshChannel> channels,
    required List<MeshContact> contacts,
  }) {
    final convos = <Conversation>[];
    for (final ch in channels) {
      convos.add(
        Conversation(
          id: '$idPrefix-ch${ch.index}',
          title: ch.name,
          isChannel: true,
          channelIdx: ch.index,
        ),
      );
    }
    if (convos.isEmpty) {
      convos.add(
        Conversation(
          id: '$idPrefix-ch0',
          title: 'Public',
          isChannel: true,
          channelIdx: 0,
        ),
      );
    }
    for (final c in contacts) {
      convos.add(_convoForContact(idPrefix, c));
    }
    return convos;
  }

  Conversation _convoForContact(String idPrefix, MeshContact c) {
    return Conversation(
      id: '$idPrefix-dm-${c.keyHex}',
      title: c.name,
      isChannel: false,
      peerKey: Uint8List.fromList(c.publicKey),
      peerType: c.type,
      favourite: c.isFavourite,
    );
  }

  void switchNode(String id) {
    if (!sessions.containsKey(id)) return;
    activeNodeId = id;
    _open = active.conversations.first;
    notifyListeners();
  }

  void open(Conversation c) {
    _open = c;
    c.unread = 0;
    notifyListeners();
  }

  Conversation openContact(MeshContact contact) {
    final existing = _findConvoFor(active, contact.publicKey);
    if (existing != null) {
      open(existing);
      return existing;
    }
    final convo = _convoForContact(active.id, contact);
    active.conversations.add(convo);
    open(convo);
    return convo;
  }

  void useSimulator() {
    error = null;
    _disconnectBle();
    _bootSimulator();
  }

  Future<void> startScan() async {
    error = null;
    mode = AppMode.bluetooth;
    scanning = true;
    bleHits.clear();
    notifyListeners();
    _scanner = BleScanner();
    try {
      _scanSub = _scanner!.scan().listen((hits) {
        bleHits
          ..clear()
          ..addAll(hits);
        notifyListeners();
      });
    } catch (e) {
      scanning = false;
      error = 'Bluetooth-Scan fehlgeschlagen: $e';
      notifyListeners();
    }
  }

  Future<void> stopScan() async {
    await _scanner?.stop();
    await _scanSub?.cancel();
    scanning = false;
    notifyListeners();
  }

  Future<void> connectBle(BleScanHit hit) async {
    if (_connecting) return;
    _connecting = true;
    error = null;
    status = 'Verbinde mit ${hit.name} …';
    notifyListeners();
    await stopScan();
    try {
      _bleTransport = BleTransport(hit.device);
      await _bleTransport!.connect();
      _bleClient = CompanionClient(transport: _bleTransport!);
      await _bleClient!.handshake();
      _disposeSessions();
      final engine = TransferEngine(
        radio: _bleClient!,
        codec: codec,
        budget: AirtimeBudget(),
      );
      final name = _bleClient!.self?.name ?? hit.name;
      final session = NodeSession(
        id: 'ble',
        name: name,
        radio: _bleClient!,
        engine: engine,
        conversations: _convosFrom(
          idPrefix: 'ble',
          channels: _bleClient!.channels,
          contacts: _bleClient!.contacts,
        ),
      );
      session.sub = engine.events.listen((e) => _onEvent(session, e));
      session.noticeSub = _bleClient!.notices.listen((n) => _onNotice(session, n));
      sessions['ble'] = session;
      activeNodeId = 'ble';
      _open = session.conversations.first;
      status = 'Verbunden mit $name';
      notifyListeners();
    } catch (e) {
      error = 'Kopplung fehlgeschlagen: $e';
      status = null;
      notifyListeners();
    } finally {
      _connecting = false;
    }
  }

  RadioDestination destFor(Conversation c) {
    if (c.isChannel) return RadioDestination.channel(c.channelIdx ?? 0);
    final key = c.peerKey ?? Uint8List(6);
    MeshContact? peer;
    for (final contact in contacts) {
      if (contact.publicKey.length >= key.length) {
        var ok = true;
        for (var i = 0; i < key.length && i < 6; i++) {
          if (contact.publicKey[i] != key[i]) {
            ok = false;
            break;
          }
        }
        if (ok) {
          peer = contact;
          break;
        }
      }
    }
    final path = peer != null && peer.hasPath
        ? Uint8List.fromList(peer.outPath!)
        : null;
    return RadioDestination.dm(key, path: path);
  }

  Future<void> sendText(String text) async {
    final conv = _open;
    if (conv == null || text.trim().isEmpty) return;
    final trimmed = text.trim();
    final ts = DateTime.now();
    final prefix = _selfPrefix();
    final catchId = conv.isChannel && prefix != null
        ? catchUpMsgId(
            '${conv.channelIdx ?? 0}|${_hex(prefix)}|${ts.millisecondsSinceEpoch ~/ 1000}|$trimmed',
          )
        : null;
    final msg = ChatMessage(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      kind: ChatKind.text,
      outgoing: true,
      timestamp: ts,
      text: trimmed,
      delivery: conv.isChannel ? DeliveryStatus.sent : DeliveryStatus.sending,
      catchUpId: catchId,
      channelAcks: conv.isChannel ? _acksForSend() : null,
    );
    conv.messages.add(msg);
    notifyListeners();
    try {
      final receipt = await active.engine.sendText(destFor(conv), trimmed);
      final idx = conv.messages.indexWhere((m) => m.id == msg.id);
      if (idx >= 0) {
        conv.messages[idx] = conv.messages[idx].copyWith(
          delivery: DeliveryStatus.sent,
          ackCode: receipt?.expectedAck,
        );
      }
      notifyListeners();
    } catch (e) {
      final idx = conv.messages.indexWhere((m) => m.id == msg.id);
      if (idx >= 0) {
        conv.messages[idx] = conv.messages[idx].copyWith(
          delivery: DeliveryStatus.failed,
        );
      }
      error = 'Senden fehlgeschlagen: $e';
      notifyListeners();
    }
  }

  Future<EncodedTransfer> previewEncode(
    RgbaImage source, {
    required bool includeUpgrade,
    required bool fourColor,
    bool dither = true,
  }) {
    return SynchronousFuture(
      codec.encode(
        source,
        options: EncodeOptions(
          includeUpgrade: includeUpgrade,
          fourColorPreview: fourColor,
          dither: dither,
        ),
      ),
    );
  }

  Future<void> sendEncoded(EncodedTransfer encoded, {RgbaImage? source}) async {
    final conv = _open;
    if (conv == null) return;
    final dest = destFor(conv);
    final sent = await active.engine.sendImage(
      encoded: encoded,
      destination: dest,
    );
    final local = source != null ? fullResImage(source) : sent.preview.image;
    conv.messages.add(
      ChatMessage(
        id: 'out-${sent.transferId}',
        kind: ChatKind.image,
        outgoing: true,
        timestamp: DateTime.now(),
        image: local,
        transferId: sent.transferId,
        catchUpId: conv.isChannel
            ? catchUpMsgId(
                '${conv.channelIdx ?? 0}|${_hex(_selfPrefix() ?? Uint8List(0))}|img|${sent.transferId}',
              )
            : null,
        channelAcks: conv.isChannel ? _acksForSend() : null,
      ),
    );
    notifyListeners();
  }

  void setSimReachable(String radioId, bool reachable) {
    final session = sessions[radioId];
    final radio = session?.radio;
    if (radio is! SimRadio) return;
    radio.reachable = reachable;
    if (reachable && session != null) {
      unawaited(radio.sendSelfAdvert(flood: true));
      unawaited(_requestCatchUp(session));
    }
    notifyListeners();
  }

  bool isSimReachable(String radioId) {
    final radio = sessions[radioId]?.radio;
    return radio is SimRadio && radio.reachable;
  }

  Future<void> replayChannel() async {
    final session = active;
    for (final c in contacts.where((c) => c.isChat)) {
      if (_peerLikelyOnline(c)) {
        await _replayPendingTo(session, c);
      }
    }
    status = 'Channel-Nachreichen gesendet';
    notifyListeners();
  }

  Future<void> pull(ChatMessage msg) async {
    final conv = _open;
    if (conv == null || msg.transferId == null) return;
    final idx = conv.messages.indexWhere((m) => m.id == msg.id);
    if (idx >= 0) {
      conv.messages[idx] = conv.messages[idx].copyWith(
        pullReceived: 0,
        pullTotal: msg.image?.upgradeChunks ?? 0,
      );
      notifyListeners();
    }
    await active.engine.requestUpgrade(msg.transferId!, destFor(conv));
  }

  Future<void> sendAdvert({bool flood = false}) async {
    await companion?.sendSelfAdvert(flood: flood);
    status = flood ? 'Advert (Flood) gesendet' : 'Advert (Zero-Hop) gesendet';
    notifyListeners();
  }

  Future<void> renameSelf(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    await companion?.setAdvertName(trimmed);
    active.name = trimmed;
    status = 'Name: $trimmed';
    notifyListeners();
  }

  Future<void> applyRadio(RadioSettings settings) async {
    await companion?.applyRadio(settings);
    status = 'Funk: ${settings.summary}';
    notifyListeners();
  }

  Future<void> refreshBattery() async {
    await companion?.refreshBattery();
    notifyListeners();
  }

  Future<void> toggleFavourite(MeshContact contact) async {
    await companion?.setFavourite(contact, !contact.isFavourite);
    final convo = _findConvoFor(active, contact.publicKey);
    if (convo != null) convo.favourite = !contact.isFavourite;
    notifyListeners();
  }

  Future<void> deleteContact(MeshContact contact) async {
    await companion?.removeContact(contact);
    active.conversations.removeWhere((c) {
      if (c.isChannel || c.peerKey == null) return false;
      return _keyEq(c.peerKey!, contact.publicKey);
    });
    notifyListeners();
  }

  void showPath({MeshContact? focus}) {
    homeTab = 3;
    pathFocusKey = focus?.keyHex;
    notifyListeners();
  }

  void setSelfFix({double? lat, double? lon, double? alt, double? aglM}) {
    if (lat != null) selfLatOverride = lat;
    if (lon != null) selfLonOverride = lon;
    if (alt != null) selfAltOverride = alt;
    if (aglM != null) selfAglM = aglM;
    notifyListeners();
  }

  void setOnlineElevation(bool on) {
    useOnlineElevation = on;
    elevationSource = on ? OpenMeteoElevation() : const SyntheticElevation();
    notifyListeners();
  }

  Future<void> ping(MeshContact contact) async {
    final key = contact.keyHex;
    _pingTimers[key]?.cancel();
    _pingStarted[key] = DateTime.now();
    pings[key] = PingResult(
      keyHex: key,
      name: contact.name,
      type: contact.type,
      at: DateTime.now(),
      inFlight: true,
      hops: contact.hopCount,
    );
    status = 'Ping an ${contact.name} …';
    notifyListeners();
    _pingTimers[key] = Timer(const Duration(seconds: 4), () {
      final cur = pings[key];
      if (cur == null || !cur.inFlight) return;
      pings[key] = cur.copyWith(inFlight: false, ok: false);
      status = '${contact.name}: keine Antwort';
      notifyListeners();
    });
    try {
      await companion?.requestStatus(contact);
    } catch (e) {
      _pingTimers[key]?.cancel();
      pings[key] = pings[key]!.copyWith(inFlight: false, ok: false);
      status = 'Ping fehlgeschlagen: $e';
      notifyListeners();
    }
  }

  Future<void> pingAll() async {
    if (pingingAll) return;
    pingingAll = true;
    notifyListeners();
    for (final c in [...contacts]) {
      await ping(c);
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    pingingAll = false;
    notifyListeners();
  }

  GeoPoint? selfPoint() {
    final me = self;
    final lat = selfLatOverride ?? me?.lat;
    final lon = selfLonOverride ?? me?.lon;
    final alt = selfAltOverride ?? me?.alt ?? 0;
    if (lat == null || lon == null) return null;
    final p = GeoPoint(lat: lat, lon: lon, elevM: alt, aglM: selfAglM);
    return p.isValid ? p : null;
  }

  GeoPoint? pointFor(MeshContact c, {double? aglM}) {
    if (!c.hasLocation) return null;
    final p = GeoPoint(
      lat: c.lat!,
      lon: c.lon!,
      elevM: c.alt ?? 0,
      aglM: aglM ?? defaultAgl(c.type),
    );
    return p.isValid ? p : null;
  }

  Future<LosResult> computeLos(MeshContact dest, {double? destAgl}) async {
    final from = selfPoint();
    final to = pointFor(dest, aglM: destAgl);
    losBusy = true;
    pathFocusKey = dest.keyHex;
    notifyListeners();
    if (from == null || to == null) {
      lastLos = analyzeLos(
        from: from ?? const GeoPoint(lat: 0, lon: 0),
        to: to ?? const GeoPoint(lat: 0, lon: 0),
        fromName: self?.name ?? active.name,
        toName: dest.name,
        freqMhz: radioSettings?.freqMhz ?? 869.525,
      );
      losBusy = false;
      notifyListeners();
      return lastLos!;
    }
    List<double> terrain;
    try {
      terrain = await elevationSource.along(from, to);
    } catch (_) {
      terrain = syntheticTerrain(from, to);
    }
    lastLos = analyzeLos(
      from: from,
      to: to,
      fromName: self?.name ?? active.name,
      toName: dest.name,
      freqMhz: radioSettings?.freqMhz ?? 869.525,
      terrainM: terrain,
    );
    losBusy = false;
    notifyListeners();
    return lastLos!;
  }

  NoiseSample? get lastNoise =>
      noiseSamples.isEmpty ? null : noiseSamples.last;

  int? get localNoiseFloor {
    final radio = sessions[activeNodeId]?.radio;
    if (radio is SimRadio) return radio.noiseFloor;
    return lastNoise?.dbm;
  }

  RepeaterSession repeaterSession(MeshContact contact) {
    return repeaterSessions.putIfAbsent(
      contact.keyHex,
      () => RepeaterSession(contact),
    );
  }

  RepeaterSession? _repeaterByPrefix(List<int>? prefix) {
    if (prefix == null || prefix.isEmpty) return null;
    for (final session in repeaterSessions.values) {
      final key = session.contact.publicKey;
      if (key.length < prefix.length) continue;
      var ok = true;
      for (var i = 0; i < prefix.length && i < 6; i++) {
        if (key[i] != prefix[i]) {
          ok = false;
          break;
        }
      }
      if (ok) return session;
    }
    for (final c in contacts) {
      if (c.publicKey.length < prefix.length) continue;
      var ok = true;
      for (var i = 0; i < prefix.length && i < 6; i++) {
        if (c.publicKey[i] != prefix[i]) {
          ok = false;
          break;
        }
      }
      if (ok) return repeaterSession(c);
    }
    return null;
  }

  Future<void> loginRepeater(MeshContact contact, String password) async {
    final session = repeaterSession(contact);
    session.busy = true;
    session.lastError = null;
    session.transcript.add(CliLine(kind: CliLineKind.info, text: 'Login …'));
    notifyListeners();
    try {
      await companion?.loginRepeater(contact, password);
    } catch (e) {
      session.lastError = '$e';
      session.busy = false;
      notifyListeners();
    }
  }

  Future<void> logoutRepeater(MeshContact contact) async {
    final session = repeaterSession(contact);
    session.transcript.add(CliLine(kind: CliLineKind.sent, text: 'logout'));
    await companion?.logoutRepeater(contact);
    session.loggedIn = false;
    session.isAdmin = false;
    session.permissions = 0;
    notifyListeners();
  }

  Future<void> sendCli(MeshContact contact, String command) async {
    final trimmed = command.trim();
    if (trimmed.isEmpty) return;
    final session = repeaterSession(contact);
    session.lastCommand = trimmed;
    session.transcript.add(CliLine(kind: CliLineKind.sent, text: trimmed));
    session.busy = true;
    notifyListeners();
    try {
      await companion?.sendCli(contact, trimmed);
    } catch (e) {
      session.transcript.add(CliLine(kind: CliLineKind.error, text: '$e'));
      session.busy = false;
      notifyListeners();
    }
  }

  Future<void> requestRepeaterStatus(MeshContact contact) async {
    final session = repeaterSession(contact);
    session.busy = true;
    notifyListeners();
    await companion?.requestStatus(contact);
  }

  Future<void> traceRepeater(MeshContact contact) async {
    status = 'Trace ${contact.name} …';
    notifyListeners();
    await companion?.tracePath(contact);
  }

  Future<void> shareZeroHop(MeshContact contact) async {
    await companion?.shareContactZeroHop(contact);
    status = '${contact.name} per Zero-Hop geteilt';
    notifyListeners();
  }

  Future<void> resetPath(MeshContact contact) async {
    await companion?.resetPath(contact);
    status = 'Pfad zu ${contact.name} zurückgesetzt';
    notifyListeners();
  }

  String exportSelfUri() {
    final me = self;
    if (me == null) return '';
    return MeshCoreUri.contact(name: me.name, publicKey: me.publicKey, type: me.type);
  }

  String exportContactUri(MeshContact contact) => MeshCoreUri.contact(
        name: contact.name,
        publicKey: contact.publicKey,
        type: contact.type,
      );

  Future<String?> importContactUri(String raw) async {
    final parsed = MeshCoreUri.parseContact(raw);
    if (parsed == null) return 'Kein gültiger meshcore:// Kontakt';
    await companion?.addOrUpdateContact(parsed);
    if (_findConvoFor(active, parsed.publicKey) == null) {
      active.conversations.add(_convoForContact(active.id, parsed));
    }
    status = '${parsed.name} importiert';
    notifyListeners();
    return null;
  }

  void _onNotice(NodeSession session, CompanionNotice n) {
    switch (n.kind) {
      case CompanionNoticeKind.ack:
        _markDelivered(session, n.ackCode, n.rttMs);
      case CompanionNoticeKind.advert:
        if (n.contact != null) {
          _ensureConvo(session, n.contact!);
          status = 'Advert: ${n.contact!.name}';
          if (n.contact!.isChat) {
            unawaited(_replayPendingTo(session, n.contact!));
          }
        }
      case CompanionNoticeKind.status:
        status = n.statusSummary;
        _recordPingReply(session, n);
        final st = _repeaterByPrefix(n.pubkey);
        if (st != null) {
          st.status = n.repeaterStatus ?? st.status;
          st.busy = false;
        }
      case CompanionNoticeKind.pathUpdated:
        status = 'Pfad aktualisiert';
      case CompanionNoticeKind.login:
        final login = _repeaterByPrefix(n.pubkey);
        if (login != null) {
          login
            ..loggedIn = true
            ..isAdmin = n.isAdmin ?? ((n.permissions ?? 0) & 1) == 1
            ..permissions = n.permissions ?? 0
            ..busy = false
            ..lastError = null
            ..transcript.add(
              CliLine(kind: CliLineKind.info, text: 'Login OK · ${login.roleLabel}'),
            );
        }
        status = 'Repeater-Login OK';
      case CompanionNoticeKind.loginFail:
        final fail = _repeaterByPrefix(n.pubkey);
        if (fail != null) {
          fail
            ..loggedIn = false
            ..busy = false
            ..lastError = 'Login fehlgeschlagen'
            ..transcript.add(
              CliLine(kind: CliLineKind.error, text: 'Login fehlgeschlagen'),
            );
        }
        status = 'Repeater-Login fehlgeschlagen';
      case CompanionNoticeKind.cli:
        final cli = _repeaterByPrefix(n.pubkey);
        if (cli != null) {
          final text = n.cliText ?? '';
          cli
            ..busy = false
            ..transcript.add(CliLine(kind: CliLineKind.reply, text: text));
          if ((cli.lastCommand ?? '').startsWith('neighbors')) {
            final parsed = parseNeighborsReply(text);
            if (parsed.isNotEmpty) {
              cli.neighbors
                ..clear()
                ..addAll(parsed);
            }
          }
          if (cli.lastCommand == 'logout' || text.toLowerCase().contains('logout')) {
            cli.loggedIn = false;
            cli.isAdmin = false;
          }
        }
      case CompanionNoticeKind.trace:
        status = n.traceSummary ?? 'Trace empfangen';
        _recordTracePing(n);
        final tr = _repeaterByPrefix(n.pubkey);
        if (tr != null) {
          tr.transcript.add(
            CliLine(kind: CliLineKind.info, text: n.traceSummary ?? 'Trace'),
          );
        }
    }
    notifyListeners();
  }

  void _markDelivered(NodeSession session, int? ack, int? rtt) {
    if (ack == null) return;
    for (final conv in session.conversations) {
      for (var i = 0; i < conv.messages.length; i++) {
        final m = conv.messages[i];
        if (m.outgoing && m.ackCode == ack && m.delivery != DeliveryStatus.delivered) {
          conv.messages[i] = m.copyWith(
            delivery: DeliveryStatus.delivered,
            rttMs: rtt,
          );
          return;
        }
      }
    }
    // Simulator: ACK may arrive before the receipt is stored.
    for (final conv in session.conversations) {
      for (var i = conv.messages.length - 1; i >= 0; i--) {
        final m = conv.messages[i];
        if (m.outgoing &&
            m.kind == ChatKind.text &&
            m.delivery != DeliveryStatus.delivered) {
          conv.messages[i] = m.copyWith(
            delivery: DeliveryStatus.delivered,
            rttMs: rtt,
            ackCode: ack,
          );
          return;
        }
      }
    }
  }

  void _ensureConvo(NodeSession session, MeshContact contact) {
    if (_findConvoFor(session, contact.publicKey) != null) return;
    session.conversations.add(_convoForContact(session.id, contact));
  }

  Conversation? _findConvoFor(NodeSession session, List<int> key) {
    for (final c in session.conversations) {
      if (c.isChannel || c.peerKey == null) continue;
      if (_keyEq(c.peerKey!, key)) return c;
    }
    return null;
  }

  bool _keyEq(List<int> a, List<int> b) {
    final n = a.length < b.length ? a.length : b.length;
    final take = n < 6 ? n : 6;
    for (var i = 0; i < take; i++) {
      if (a[i] != b[i]) return false;
    }
    return take > 0;
  }

  void _onEvent(NodeSession session, TransferEvent e) {
    if (e.catchUp != null) {
      _handleCatchUp(session, e);
      return;
    }
    if (e.outgoing && e.image != null) {
      notifyListeners();
      return;
    }
    Conversation? conv;
    if (e.fromChannel || (e.destination?.isPublicChannel ?? false)) {
      final idx = e.channelIdx ?? e.destination?.channelIdx ?? 0;
      conv = session.conversations.cast<Conversation?>().firstWhere(
        (c) => c!.isChannel && c.channelIdx == idx,
        orElse: () => session.conversations.first,
      );
    } else {
      conv = session.conversations.cast<Conversation?>().firstWhere((c) {
        if (c!.isChannel) return false;
        final key = c.peerKey;
        final pre = e.senderPrefix;
        if (key == null || pre == null) return c.title != session.name;
        return key.length >= 6 &&
            key[0] == pre[0] &&
            key[1] == pre[1] &&
            key[2] == pre[2] &&
            key[3] == pre[3] &&
            key[4] == pre[4] &&
            key[5] == pre[5];
      }, orElse: () => session.conversations.length > 1
          ? session.conversations[1]
          : session.conversations.first);
    }
    if (conv == null) return;
    if (e.chunkTotal != null && e.chunkReceived != null) {
      final idx = conv.messages.indexWhere((m) => m.transferId == e.transferId);
      if (idx >= 0) {
        conv.messages[idx] = conv.messages[idx].copyWith(
          pullReceived: e.chunkReceived,
          pullTotal: e.chunkTotal,
        );
      }
      notifyListeners();
      return;
    }
    if (e.image != null) {
      final existing = conv.messages.indexWhere(
        (m) => m.transferId == e.transferId && m.kind == ChatKind.image,
      );
      final msg = ChatMessage(
        id: 'img-${e.transferId}-${e.message.hashCode}',
        kind: ChatKind.image,
        outgoing: false,
        timestamp: DateTime.now(),
        image: e.image,
        transferId: e.transferId,
        canPull: (e.image?.upgradeChunks ?? 0) > 0 && !e.fromChannel,
        hopCount: e.hopCount,
        snr: e.snr,
        senderName: _nameForPrefix(session, e.senderPrefix),
      );
      if (existing >= 0) {
        conv.messages[existing] = msg;
      } else {
        conv.messages.add(msg);
        if (!identical(conv, _open) || session.id != activeNodeId) {
          conv.unread += 1;
        }
      }
    } else if (e.isText) {
      conv.messages.add(
        ChatMessage(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          kind: ChatKind.text,
          outgoing: false,
          timestamp: e.timestamp != null
              ? DateTime.fromMillisecondsSinceEpoch(e.timestamp! * 1000, isUtc: true)
                  .toLocal()
              : DateTime.now(),
          text: e.message,
          hopCount: e.hopCount,
          snr: e.snr,
          senderName: _nameForPrefix(session, e.senderPrefix),
        ),
      );
      if (!identical(conv, _open) || session.id != activeNodeId) {
        conv.unread += 1;
      }
    }
    notifyListeners();
  }

  String? _nameForPrefix(NodeSession session, Uint8List? prefix) {
    if (prefix == null) return null;
    for (final c in session.conversations) {
      final key = c.peerKey;
      if (key == null || key.length < prefix.length) continue;
      var ok = true;
      for (var i = 0; i < prefix.length; i++) {
        if (key[i] != prefix[i]) {
          ok = false;
          break;
        }
      }
      if (ok) return c.title;
    }
    final ctrl = session.companion;
    if (ctrl != null) {
      for (final c in ctrl.contacts) {
        if (c.publicKey.length < prefix.length) continue;
        var ok = true;
        for (var i = 0; i < prefix.length; i++) {
          if (c.publicKey[i] != prefix[i]) {
            ok = false;
            break;
          }
        }
        if (ok) return c.name;
      }
    }
    return null;
  }

  List<ChannelPeerAck> _acksForSend() {
    return contacts
        .where((c) => c.isChat)
        .map(
          (c) => ChannelPeerAck(
            keyHex: c.keyHex,
            name: c.name,
            state: _peerLikelyOnline(c)
                ? ChannelPeerState.live
                : ChannelPeerState.pending,
          ),
        )
        .toList();
  }

  bool _peerLikelyOnline(MeshContact c) {
    if (mode == AppMode.simulator) {
      for (final s in sessions.values) {
        final r = s.radio;
        if (r is SimRadio && _keyEq(r.identity.publicKey, c.publicKey)) {
          return r.reachable;
        }
      }
      return false;
    }
    final heard = c.lastHeard;
    if (heard == null) return false;
    return DateTime.now().difference(heard) < const Duration(minutes: 2);
  }

  Uint8List? _selfPrefix() {
    final key = self?.publicKey;
    if (key == null || key.isEmpty) return null;
    return Uint8List.fromList(key.take(6).toList());
  }

  Uint8List _selfPrefixOf(NodeSession session) {
    final self = session.companion?.self;
    final key = self?.publicKey;
    if (key == null || key.isEmpty) return Uint8List(6);
    return Uint8List.fromList(key.take(6).toList());
  }

  String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  MeshContact? _contactForPrefix(NodeSession session, Uint8List? prefix) {
    if (prefix == null) return null;
    for (final c in session.companion?.contacts ?? const <MeshContact>[]) {
      if (_keyEq(c.publicKey, prefix)) return c;
    }
    return null;
  }

  String? _keyHexForPrefix(NodeSession session, Uint8List? prefix) {
    if (prefix == null || prefix.isEmpty) return null;
    return _contactForPrefix(session, prefix)?.keyHex ?? _hex(prefix);
  }

  void _recordPingReply(NodeSession session, CompanionNotice n) {
    final prefix = n.pubkey == null ? null : Uint8List.fromList(n.pubkey!);
    final contact = _contactForPrefix(session, prefix);
    var key = contact?.keyHex ?? _keyHexForPrefix(session, prefix);
    if (key == null) {
      final flying = pings.entries.where((e) => e.value.inFlight).toList();
      if (flying.length == 1) key = flying.first.key;
    }
    if (key == null) return;
    final started = _pingStarted[key];
    final rtt = n.rttMs ??
        (started == null
            ? null
            : DateTime.now().difference(started).inMilliseconds);
    final noise = n.repeaterStatus?.noiseFloor;
    final prev = pings[key];
    pings[key] = PingResult(
      keyHex: key,
      name: contact?.name ?? prev?.name ?? 'Node',
      type: contact?.type ?? prev?.type ?? AdvType.chat,
      at: DateTime.now(),
      inFlight: false,
      ok: true,
      rttMs: rtt,
      snr: n.repeaterStatus?.lastSnr ?? prev?.snr,
      noiseFloor: noise ?? prev?.noiseFloor,
      rssi: n.repeaterStatus?.lastRssi ?? prev?.rssi,
      hops: contact?.hopCount ?? prev?.hops,
    );
    _pingTimers[key]?.cancel();
    if (noise != null) {
      noiseSamples.add(
        NoiseSample(dbm: noise, at: DateTime.now(), sourceName: contact?.name),
      );
      if (noiseSamples.length > 40) noiseSamples.removeAt(0);
    }
  }

  void _recordTracePing(CompanionNotice n) {
    final prefix = n.pubkey == null ? null : Uint8List.fromList(n.pubkey!);
    final key = _keyHexForPrefix(active, prefix);
    if (key == null) return;
    final prev = pings[key];
    if (prev == null) return;
    pings[key] = prev.copyWith(ok: true, inFlight: false);
    _pingTimers[key]?.cancel();
  }

  void _handleCatchUp(NodeSession session, TransferEvent e) {
    final pkt = e.catchUp!;
    if (pkt.isReceipt) {
      _applyReceipt(session, e);
      return;
    }
    if (pkt.isSyncReq) {
      final peer = _contactForPrefix(session, e.senderPrefix);
      if (peer != null && peer.isChat) {
        unawaited(_replayPendingTo(session, peer));
      }
      return;
    }
    _ingestCatchUpText(session, e);
  }

  void _ingestCatchUpText(NodeSession session, TransferEvent e) {
    final pkt = e.catchUp!;
    final conv = session.conversations
            .where((c) => c.isChannel && c.channelIdx == pkt.channelIdx)
            .firstOrNull ??
        session.conversations.where((c) => c.isChannel).firstOrNull;
    if (conv == null) return;
    final senderName = _nameForPrefix(session, e.senderPrefix) ??
        _nameForPrefix(session, pkt.senderPrefix);
    final dup = conv.messages.any((m) {
      if (m.catchUpId != null && m.catchUpId == pkt.msgId) return true;
      if (pkt.text != null &&
          pkt.text!.isNotEmpty &&
          m.text == pkt.text &&
          !m.outgoing) {
        final dt =
            (m.timestamp.millisecondsSinceEpoch ~/ 1000 - pkt.timestamp).abs();
        if (dt <= 300) return true;
      }
      return false;
    });
    if (!dup) {
      conv.messages.add(
        ChatMessage(
          id: 'cu-${pkt.msgId}',
          kind: ChatKind.text,
          outgoing: false,
          timestamp: DateTime.fromMillisecondsSinceEpoch(
            pkt.timestamp * 1000,
            isUtc: true,
          ).toLocal(),
          text: pkt.text,
          catchUpId: pkt.msgId,
          catchUp: true,
          senderName: senderName,
        ),
      );
      if (!identical(conv, _open) || session.id != activeNodeId) {
        conv.unread += 1;
      }
    }
    final dest = e.senderPrefix ?? pkt.senderPrefix;
    unawaited(_sendReceipt(session, dest, pkt));
    notifyListeners();
  }

  Future<void> _sendReceipt(
    NodeSession session,
    Uint8List destPrefix,
    CatchUpPacket orig,
  ) async {
    if (destPrefix.isEmpty) return;
    final pkt = CatchUpPacket(
      kind: CatchKind.receipt,
      channelIdx: orig.channelIdx,
      msgId: orig.msgId,
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      senderPrefix: _selfPrefixOf(session),
    );
    try {
      await session.engine.sendCatchUp(
        destination: RadioDestination.dm(destPrefix),
        packet: pkt,
      );
    } catch (_) {}
  }

  void _applyReceipt(NodeSession session, TransferEvent e) {
    final pkt = e.catchUp!;
    final fromHex = _keyHexForPrefix(session, e.senderPrefix);
    if (fromHex == null) return;
    var changed = false;
    for (final conv in session.conversations) {
      if (!conv.isChannel) continue;
      for (var i = 0; i < conv.messages.length; i++) {
        final m = conv.messages[i];
        if (!m.outgoing || m.catchUpId != pkt.msgId) continue;
        conv.messages[i] = m.withPeerAck(fromHex, ChannelPeerState.delivered);
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  Future<void> _replayPendingTo(NodeSession session, MeshContact peer) async {
    if (mode == AppMode.simulator && !_peerLikelyOnline(peer)) return;
    final dest = RadioDestination.dm(
      Uint8List.fromList(peer.publicKey.take(6).toList()),
      path: peer.hasPath ? Uint8List.fromList(peer.outPath!) : null,
    );
    var sent = 0;
    for (final conv in session.conversations) {
      if (!conv.isChannel) continue;
      for (var i = 0; i < conv.messages.length; i++) {
        if (sent >= 20) {
          notifyListeners();
          return;
        }
        final m = conv.messages[i];
        if (!m.outgoing || m.catchUpId == null || !m.hasChannelTracking) {
          continue;
        }
        ChannelPeerAck? ack;
        for (final a in m.channelAcks) {
          final hex = a.keyHex.toLowerCase();
          final needle = peer.keyHex.toLowerCase();
          if (hex.startsWith(needle) || needle.startsWith(hex)) {
            ack = a;
            break;
          }
        }
        if (ack == null ||
            ack.state == ChannelPeerState.delivered ||
            ack.state == ChannelPeerState.live) {
          continue;
        }
        final text = m.kind == ChatKind.image ? '📷 Bild' : (m.text ?? '');
        final pkt = CatchUpPacket(
          kind: CatchKind.text,
          channelIdx: conv.channelIdx ?? 0,
          msgId: m.catchUpId!,
          timestamp: m.timestamp.millisecondsSinceEpoch ~/ 1000,
          senderPrefix: _selfPrefixOf(session),
          text: text,
        );
        try {
          await session.engine.sendCatchUp(destination: dest, packet: pkt);
          conv.messages[i] =
              m.withPeerAck(peer.keyHex, ChannelPeerState.replayed);
          sent++;
        } catch (_) {}
      }
    }
    if (sent > 0) notifyListeners();
  }

  Future<void> _requestCatchUp(NodeSession session) async {
    final prefix = _selfPrefixOf(session);
    for (final c in session.companion?.contacts ?? const <MeshContact>[]) {
      if (!c.isChat) continue;
      if (!_peerLikelyOnline(c)) continue;
      final pkt = CatchUpPacket(
        kind: CatchKind.syncReq,
        channelIdx: 0,
        msgId: 0,
        timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        senderPrefix: prefix,
      );
      try {
        await session.engine.sendCatchUp(
          destination: RadioDestination.dm(
            Uint8List.fromList(c.publicKey.take(6).toList()),
          ),
          packet: pkt,
        );
      } catch (_) {}
    }
  }

  void _disposeSessions() {
    for (final s in sessions.values) {
      s.sub?.cancel();
      s.noticeSub?.cancel();
      s.engine.dispose();
      final r = s.radio;
      if (r is SimRadio) {
        r.dispose();
      }
    }
    sessions.clear();
    repeaterSessions.clear();
  }

  void _disconnectBle() {
    _bleClient?.dispose();
    _bleClient = null;
    _bleTransport = null;
  }

  @override
  void dispose() {
    for (final t in _pingTimers.values) {
      t.cancel();
    }
    _pingTimers.clear();
    _scanSub?.cancel();
    _disconnectBle();
    _disposeSessions();
    super.dispose();
  }
}
