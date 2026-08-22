import 'dart:async';

import 'package:flutter/foundation.dart';

import '../codec/mp1.dart';
import '../codec/rgba.dart';
import '../companion/ble.dart';
import '../companion/client.dart';
import '../companion/control.dart';
import '../models/channel.dart';
import '../models/chat.dart';
import '../models/contact.dart';
import '../models/device.dart';
import '../models/uri_card.dart';
import '../sim/sim_mesh.dart';
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

  CompanionClient? _bleClient;
  BleTransport? _bleTransport;
  BleScanner? _scanner;
  StreamSubscription<List<BleScanHit>>? _scanSub;

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
    mode = AppMode.simulator;
    final anna = SimIdentity(
      id: 'anna',
      name: 'Anna',
      publicKey: keyFromSeed(11),
    );
    final ben = SimIdentity(
      id: 'ben',
      name: 'Ben',
      publicKey: keyFromSeed(23),
    );
    final annaRadio = SimRadio(mesh: mesh, identity: anna);
    final benRadio = SimRadio(mesh: mesh, identity: ben);
    annaRadio.loadPeers();
    benRadio.loadPeers();
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
    final msg = ChatMessage(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      kind: ChatKind.text,
      outgoing: true,
      timestamp: DateTime.now(),
      text: text.trim(),
      delivery: conv.isChannel ? DeliveryStatus.sent : DeliveryStatus.sending,
    );
    conv.messages.add(msg);
    notifyListeners();
    try {
      final receipt = await active.engine.sendText(destFor(conv), text.trim());
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
      ),
    );
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

  Future<void> ping(MeshContact contact) async {
    status = 'Ping an ${contact.name} …';
    notifyListeners();
    await companion?.ping(contact);
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
        }
      case CompanionNoticeKind.status:
        status = n.statusSummary;
      case CompanionNoticeKind.pathUpdated:
        status = 'Pfad aktualisiert';
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
  }

  void _disconnectBle() {
    _bleClient?.dispose();
    _bleClient = null;
    _bleTransport = null;
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _disconnectBle();
    _disposeSessions();
    super.dispose();
  }
}
