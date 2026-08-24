import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../codec/mp1.dart';
import '../codec/rgba.dart';
import '../companion/ble.dart';
import '../companion/client.dart';
import '../companion/control.dart';
import '../companion/local_prefs.dart';
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
import '../transfer/catchup.dart';
import '../transfer/engine.dart';
import '../transfer/protocol.dart';

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
  NodeSession? session;
  String? status;
  String? error;

  final codec = Mp1Codec();
  final bleHits = <BleScanHit>[];
  bool scanning = false;
  bool reconnecting = false;
  int homeTab = 0;

  /// Unter-Tab im Pfad (0 Ping, 1 Rauschen, 2 Sichtlinie, 3 Karte).
  int pathSubTab = 0;
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

  /// Freie A/B-Punkte für die LOS-Karte (lat/lon, ohne GPS-Advert).
  GeoPoint? mapPointA;
  GeoPoint? mapPointB;

  /// 0 = A wird gesetzt, 1 = B (Tap-Ziel auf der Karte).
  int mapTapTarget = 0;

  /// Kartenfokus: 'mesh' zeigt bekannte Nodes, 'los' zeigt die A/B-Route.
  String mapMode = 'mesh';

  CompanionClient? _bleClient;
  BleTransport? _bleTransport;
  BleScanner? _scanner;
  StreamSubscription<List<BleScanHit>>? _scanSub;
  bool _connecting = false;

  // --- Lokale Einstellungen (überleben Neustart, Gerät unabhängig) ---
  final Set<String> blockedContacts = {};
  final Set<String> mutedContacts = {};
  final Set<String> mutedChannels = {};
  bool _prefsLoaded = false;
  String? _lastDeviceId;
  String? _lastDeviceName;
  StreamSubscription<void>? _linkLostSub;
  bool _userDisconnected = false;
  int _reconnectAttempts = 0;
  static const _maxReconnectAttempts = 5;
  // Trace-Ping: tag -> Contact keyHex (nur wir senden die Tags).
  final _tracePingByTag = <int, String>{};
  int _traceTagSeq = 0;
  final _rng = Random.secure();

  NodeSession get active => session!;

  Conversation? _open;
  Conversation? get openConversation => _open;

  CompanionControl? get companion => session?.companion;

  List<MeshContact> get contacts => companion?.contacts ?? const [];

  DeviceSelf? get self => companion?.self;

  RadioSettings? get radioSettings => companion?.radio;

  BatteryInfo? get battery => companion?.battery;

  FirmwareInfo? get firmware => companion?.firmware;

  void selectTab(int index) {
    homeTab = index;
    notifyListeners();
  }

  List<Conversation> _convosFrom({
    required String idPrefix,
    required List<MeshChannel> channels,
    required List<MeshContact> contacts,
  }) {
    final convos = <Conversation>[];
    for (final ch in channels) {
      // Leere Slots (nie angelegt/beigetreten) haben keinen Chat.
      if (ch.index != 0 && ch.name.isEmpty) continue;
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
      // Repeater & Co. sind Infrastruktur: kein Chat, keine Konversation.
      if (!c.isChat) continue;
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

  /// Lädt lokale Einstellungen (Block/Mute, letztes Gerät) und versucht
  /// einen Auto-Reconnect. Einmalig — beim App-Start aufrufen.
  Future<void> init() async {
    if (_prefsLoaded) return;
    _prefsLoaded = true;
    blockedContacts
      ..clear()
      ..addAll(await LocalPrefs.readBlockedContacts());
    mutedContacts
      ..clear()
      ..addAll(await LocalPrefs.readMutedContacts());
    mutedChannels
      ..clear()
      ..addAll(await LocalPrefs.readMutedChannels());
    final dev = await LocalPrefs.readDevice();
    if (dev != null && session == null) {
      _lastDeviceId = dev.remoteId;
      _lastDeviceName = dev.name;
    } else if (session == null && await _bleAvailable()) {
      // Ersteinrichtung: kein vorheriges Gerät gespeichert — scannen.
      unawaited(startScan());
    }
  }

  /// Ob die BLE-Plattform verfügbar ist (Test-/Desktop-Environment
  /// werfen beim ersten Plattformzugriff).
  static Future<bool> _bleAvailable() async {
    try {
      await FlutterBluePlus.adapterState.first;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> startScan() async {
    error = null;
    _linkLostSub?.cancel();
    _linkLostSub = null;
    unawaited(_bleTransport?.close().catchError((_) {}));
    _disconnectBle();
    _disposeSession();
    _open = null;
    homeTab = 0;
    scanning = true;
    bleHits.clear();
    notifyListeners();
    _scanner = BleScanner();
    try {
      _scanSub = _scanner!.scan().listen(
        (hits) {
          bleHits
            ..clear()
            ..addAll(hits);
          notifyListeners();
        },
        onError: (Object e) {
          scanning = false;
          error = 'Bluetooth-Scan fehlgeschlagen: $e';
          notifyListeners();
        },
      );
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
    error = null;
    await stopScan();
    await _connectToDevice(hit.device, name: hit.name);
  }

  Future<bool> _connectToDevice(
    BluetoothDevice device, {
    String name = '',
  }) async {
    if (_connecting) return false;
    _connecting = true;
    _userDisconnected = false;
    final label = name.isEmpty ? 'Gerät' : name;
    status = 'Verbinde mit $label …';
    notifyListeners();
    // Beim ersten Pairing beantwortet der User einen System-PIN-Dialog;
    // solange blockiert das Gerät. Stattdessen einen Abbruch mit roter
    // Fehlermeldung zu zeigen, sagen wir, was zu tun ist.
    final pinHint = Timer(const Duration(seconds: 10), () {
      if (status == 'Verbinde mit $label …') {
        status = 'PIN-Dialog? PIN eingeben (0000 oder 1234)';
        notifyListeners();
      }
    });
    var ok = false;
    try {
      _bleTransport = BleTransport(device);
      await _bleTransport!.connect();
      _bleClient = CompanionClient(transport: _bleTransport!);
      await _bleClient!.handshake();
      _disposeSession();
      final engine = TransferEngine(
        radio: _bleClient!,
        codec: codec,
        budget: AirtimeBudget(),
      );
      final resolved = _bleClient!.self?.name ?? label;
      final newSession = NodeSession(
        id: 'ble',
        name: resolved,
        radio: _bleClient!,
        engine: engine,
        conversations: _convosFrom(
          idPrefix: 'ble',
          channels: _bleClient!.channels,
          contacts: _bleClient!.contacts,
        ),
      );
      newSession.sub = engine.events.listen((e) => _onEvent(newSession, e));
      newSession.noticeSub = _bleClient!.notices.listen(
        (n) => _onNotice(newSession, n),
      );
      session = newSession;
      _open = newSession.conversations.first;
      // Geräte-Erinnerung + Link-Loss-Beobachtung (Auto-Reconnect).
      _reconnectAttempts = 0;
      _linkLostSub?.cancel();
      _linkLostSub = _bleTransport!.linkLost.listen((_) => _onBleLinkLost());
      final remoteId = _bleTransport!.device.remoteId.str;
      _lastDeviceId = remoteId;
      _lastDeviceName = resolved;
      unawaited(LocalPrefs.saveDevice(remoteId, resolved));
      status = 'Verbunden mit $resolved';
      notifyListeners();
      unawaited(_processPendingContactUri());
      ok = true;
    } catch (e) {
      unawaited(_bleTransport?.close().catchError((_) {}));
      _disconnectBle();
      error = e.toString().contains('Timed out')
          ? 'Kopplung fehlgeschlagen: Timeout — PIN-Dialog unbeantwortet? Erneut versuchen.'
          : 'Kopplung fehlgeschlagen: $e';
      status = null;
      notifyListeners();
    } finally {
      pinHint.cancel();
      _connecting = false;
    }
    return ok;
  }

  /// Auto-Reconnect zum letzten Gerät (App-Start oder nach Link-Loss).
  Future<void> _autoConnectLast() async {
    final id = _lastDeviceId;
    if (id == null || session != null) return;
    reconnecting = true;
    status = 'Verbinde mit ${_lastDeviceName ?? id} …';
    notifyListeners();
    try {
      final device = await _deviceById(id);
      if (device == null) {
        _reconnectAttempts = 0;
        startScan();
        return;
      }
      final ok = await _connectToDevice(device, name: _lastDeviceName ?? id);
      if (!ok) {
        _reconnectAttempts = 0;
        startScan();
      }
    } catch (_) {
      // Gerät nicht sichtbar — normales Scannen anbieten.
      _reconnectAttempts = 0;
      startScan();
    } finally {
      reconnecting = false;
      notifyListeners();
    }
  }

  /// Gerät aus Remote-ID: Bond-Liste, aktueller Scan-Puffer,
  /// sonst kurzer gefilterter Scan.
  Future<BluetoothDevice?> _deviceById(String id) async {
    try {
      for (final d in await FlutterBluePlus.bondedDevices) {
        if (d.remoteId.str == id) return d;
      }
    } catch (_) {
      // bondedDevices existiert nur auf Android.
    }
    final found = Completer<BluetoothDevice>();
    final sub = FlutterBluePlus.scanResults.listen((batch) {
      for (final r in batch) {
        if (r.device.remoteId.str == id && !found.isCompleted) {
          found.complete(r.device);
          return;
        }
      }
    });
    final wasScanning = await FlutterBluePlus.isScanning.first;
    bool started = false;
    try {
      if (!wasScanning) {
        await FlutterBluePlus.startScan(
          withRemoteIds: [id],
          timeout: const Duration(seconds: 10),
        );
        started = true;
      }
      return await found.future.timeout(const Duration(seconds: 10));
    } catch (_) {
      return null;
    } finally {
      await sub.cancel();
      // Nur den eigenen Scan stoppen, nie einen laufenden
      // (benutzergestarteten) Scan.
      if (started) {
        unawaited(FlutterBluePlus.stopScan().catchError((_) {}));
      }
    }
  }

  void _onBleLinkLost() {
    _linkLostSub?.cancel();
    _linkLostSub = null;
    unawaited(_bleTransport?.close().catchError((_) {}));
    _disconnectBle();
    _disposeSession();
    _open = null;
    if (_userDisconnected) {
      notifyListeners();
      return;
    }
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      status = null;
      error = 'Verbindung verloren — Auto-Reconnect aufgegeben';
      notifyListeners();
      return;
    }
    final attempt = ++_reconnectAttempts;
    status =
        'Verbindung verloren — verbinde erneut '
        '($attempt/$_maxReconnectAttempts) …';
    notifyListeners();
    Timer(Duration(seconds: 2 * attempt), () => unawaited(_autoConnectLast()));
  }

  /// Testnaht: Session ohne BLE koppeln (Fake-Radio in Unit-Tests).
  @visibleForTesting
  void attachSession(NodeSession s) {
    _disposeSession();
    session = s;
    s.sub = s.engine.events.listen((e) => _onEvent(s, e));
    final c = s.companion;
    if (c != null) {
      s.noticeSub = c.notices.listen((n) => _onNotice(s, n));
    }
    _open = s.conversations.isNotEmpty ? s.conversations.first : null;
    notifyListeners();
    unawaited(_processPendingContactUri());
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

  /// Kanal auf dem Gerät anlegen: erster freier Slot 1–7, neues 16-Byte-Secret.
  Future<void> createChannel(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final control = companion;
    if (control == null) return;
    final used = control.channels
        .where((c) => c.index == 0 || c.name.isNotEmpty)
        .map((c) => c.index)
        .toSet();
    int? free;
    for (var i = 1; i <= 7; i++) {
      if (!used.contains(i)) {
        free = i;
        break;
      }
    }
    if (free == null) {
      error = 'Kein freier Kanalslot: 1–7 sind belegt.';
      notifyListeners();
      return;
    }
    status = 'Lege Kanal „$trimmed" an …';
    notifyListeners();
    final rnd = Random.secure();
    final secret = Uint8List(16);
    for (var i = 0; i < secret.length; i++) {
      secret[i] = rnd.nextInt(256);
    }
    try {
      await control.setChannel(free, trimmed, secret);
    } catch (e) {
      error = 'Kanal konnte nicht angelegt werden: $e';
      notifyListeners();
      return;
    }
    final session = active;
    if (!session.conversations.any(
      (c) => c.isChannel && c.channelIdx == free,
    )) {
      var i = 0;
      while (i < session.conversations.length &&
          session.conversations[i].isChannel &&
          (session.conversations[i].channelIdx ?? 0) < free) {
        i++;
      }
      session.conversations.insert(
        i,
        Conversation(
          id: '${session.id}-ch$free',
          title: trimmed,
          isChannel: true,
          channelIdx: free,
        ),
      );
    }
    error = null;
    status = 'Kanal „$trimmed" angelegt (Kanal $free)';
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

  /// Kanal löschen: leerer Name + Null-Secret macht den Slot zum Dead-Slot.
  Future<void> deleteChannel(int idx) async {
    final title = active.conversations
        .where((c) => c.isChannel && c.channelIdx == idx)
        .map((c) => c.title)
        .firstOrNull;
    try {
      await companion?.deleteChannel(idx);
    } catch (e) {
      error = 'Kanal konnte nicht gelöscht werden: $e';
      notifyListeners();
      return;
    }
    if (title != null) mutedChannels.remove(title);
    active.conversations.removeWhere((c) => c.isChannel && c.channelIdx == idx);
    error = null;
    status = title == null || title.isEmpty
        ? 'Kanal $idx gelöscht'
        : 'Kanal „$title" gelöscht';
    notifyListeners();
  }

  /// Nutzer-Trennung: kein Auto-Reconnect.
  void disconnect() {
    _userDisconnected = true;
    _reconnectAttempts = 0;
    unawaited(_bleTransport?.close().catchError((_) {}));
    _disconnectBle();
    _disposeSession();
    _open = null;
    status = null;
    error = null;
    notifyListeners();
  }

  /// Trennen + Geräte-Erinnerung löschen.
  void forgetDevice() {
    _lastDeviceId = null;
    _lastDeviceName = null;
    unawaited(LocalPrefs.clearDevice());
    disconnect();
  }

  /// Werksreset: Gerät startet neu und löst das BLE-Pairing.
  Future<void> factoryResetDevice() async {
    try {
      await companion?.factoryReset();
    } catch (_) {
      // Erwartebar: das Gerät trennt vor dem OK-Frame.
    }
    forgetDevice();
    status = 'Werksreset gestartet — Gerät startet neu';
    notifyListeners();
  }

  void showPath({MeshContact? focus}) {
    homeTab = 4;
    pathFocusKey = focus?.keyHex;
    if (focus != null) pathSubTab = 2;
    notifyListeners();
  }

  void setPathSubTab(int index) {
    pathSubTab = index;
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
    // Ein Round-Trip-Trace über 2–3 Hops (mit Re-Transmit-Verzögerungen)
    // kann mehrere Sekunden dauern — 15 s Geduld.
    _pingTimers[key] = Timer(const Duration(seconds: 15), () {
      final cur = pings[key];
      if (cur == null || !cur.inFlight) return;
      pings[key] = cur.copyWith(inFlight: false, ok: false);
      status = '${contact.name}: keine Antwort';
      notifyListeners();
    });
    try {
      if (contact.isAdminNode) {
        await companion?.requestStatus(contact);
      } else {
        final tag = _nextTraceTag();
        _tracePingByTag[tag] = key;
        await companion?.tracePath(
          contact,
          tag: tag,
          flags: _traceFlags(contact),
        );
      }
    } catch (e) {
      _pingTimers[key]?.cancel();
      pings[key] = pings[key]!.copyWith(inFlight: false, ok: false);
      status = 'Ping fehlgeschlagen: $e';
      notifyListeners();
    }
  }

  /// Trace-Flags: untere 2 Bits = log2(Path-Eintrag-Weite).
  static int _traceFlags(MeshContact c) => c.outPathEntrySize == 2
      ? 1
      : c.outPathEntrySize == 4
      ? 2
      : 0;

  int _nextTraceTag() {
    _traceTagSeq = (_traceTagSeq + 1 + _rng.nextInt(0xFFFF)) & 0x7fffffff;
    return _traceTagSeq;
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

  void toggleBlockedContact(String keyHex) {
    if (!blockedContacts.add(keyHex)) blockedContacts.remove(keyHex);
    notifyListeners();
    unawaited(LocalPrefs.saveBlockedContacts(blockedContacts));
  }

  void toggleMutedContact(String keyHex) {
    if (!mutedContacts.add(keyHex)) mutedContacts.remove(keyHex);
    notifyListeners();
    unawaited(LocalPrefs.saveMutedContacts(mutedContacts));
  }

  void toggleMutedChannel(String title) {
    if (!mutedChannels.add(title)) mutedChannels.remove(title);
    notifyListeners();
    unawaited(LocalPrefs.saveMutedChannels(mutedChannels));
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
    pathSubTab = 2;
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

  // ---- LOS-Karte: freie A/B-Punkte -------------------------------

  LosResult? lastLosMap;
  bool losMapBusy = false;

  void setMapTapTarget(int t) {
    mapTapTarget = t.clamp(0, 1);
    notifyListeners();
  }

  /// Karten-Tap: setzt A oder B je nach [mapTapTarget], rückt automatisch
  /// weiter und rechnet die Sichtlinie, sobald beide Enden stehen.
  void placeTapped(GeoPoint p) {
    if (!p.isValid) return;
    if (mapTapTarget == 0) {
      mapPointA = p;
      mapTapTarget = 1;
    } else {
      mapPointB = p;
    }
    notifyListeners();
    unawaited(computeLosMap());
  }

  void setMapPointA(GeoPoint? p) {
    mapPointA = p;
    if (p == null) mapTapTarget = 0;
    notifyListeners();
    unawaited(computeLosMap());
  }

  void setMapPointB(GeoPoint? p) {
    mapPointB = p;
    if (p == null) mapTapTarget = 1;
    notifyListeners();
    unawaited(computeLosMap());
  }

  void clearMapPoints() {
    mapPointA = null;
    mapPointB = null;
    mapTapTarget = 0;
    lastLosMap = null;
    losMapBusy = false;
    notifyListeners();
  }

  String _mapPointName(GeoPoint p) {
    final selfPt = selfPoint();
    final selfName = self?.name ?? 'Ich';
    if (selfPt != null && _isSameGeo(selfPt, p)) return selfName;
    for (final c in contacts) {
      final cp = pointFor(c);
      if (cp != null && _isSameGeo(cp, p)) return c.name;
    }
    return p == mapPointA ? 'Punkt A' : 'Punkt B';
  }

  bool _isSameGeo(GeoPoint a, GeoPoint b) {
    return (a.lat - b.lat).abs() < 1e-5 && (a.lon - b.lon).abs() < 1e-5;
  }

  Future<void> computeLosMap() async {
    final a = mapPointA;
    final b = mapPointB;
    if (a == null || b == null) {
      lastLosMap = null;
      losMapBusy = false;
      notifyListeners();
      return;
    }
    losMapBusy = true;
    notifyListeners();
    List<double> terrain;
    try {
      terrain = await elevationSource.along(a, b);
    } catch (_) {
      terrain = syntheticTerrain(a, b);
    }
    lastLosMap = analyzeLos(
      from: a,
      to: b,
      fromName: _mapPointName(a),
      toName: _mapPointName(b),
      freqMhz: radioSettings?.freqMhz ?? 869.525,
      terrainM: terrain,
    );
    losMapBusy = false;
    notifyListeners();
  }

  NoiseSample? get lastNoise => noiseSamples.isEmpty ? null : noiseSamples.last;

  int? get localNoiseFloor => lastNoise?.dbm;

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
    return MeshCoreUri.contact(
      name: me.name,
      publicKey: me.publicKey,
      type: me.type,
    );
  }

  String exportContactUri(MeshContact contact) => MeshCoreUri.contact(
    name: contact.name,
    publicKey: contact.publicKey,
    type: contact.type,
  );

  /// `meshcore://contact/add/…`-Deep-Links (QR-Scan oder geteilte Karten).
  /// Links, die vor der Geräteverbindung eintreffen, werden gepuffert und
  /// importiert, sobald eine Session aktiv ist.
  String? _pendingContactUri;

  Future<void> handleContactUri(String uri) async {
    _pendingContactUri = uri;
    if (session == null) {
      status = 'meshcore://-Kontakt erhalten — warte auf Verbindung …';
      notifyListeners();
    }
    await _processPendingContactUri();
  }

  Future<void> _processPendingContactUri() async {
    final uri = _pendingContactUri;
    if (uri == null || session == null || companion == null) return;
    _pendingContactUri = null;
    await importContactUri(uri);
  }

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
              CliLine(
                kind: CliLineKind.info,
                text: 'Login OK · ${login.roleLabel}',
              ),
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
          if (cli.lastCommand == 'logout' ||
              text.toLowerCase().contains('logout')) {
            cli.loggedIn = false;
            cli.isAdmin = false;
          }
        }
      case CompanionNoticeKind.trace:
        final t = n.trace;
        if (t != null) {
          _recordTracePing(t);
          final tr = _repeaterByPrefix(n.pubkey);
          if (tr != null) {
            tr.transcript.add(CliLine(kind: CliLineKind.info, text: t.summary));
          }
        }
    }
    notifyListeners();
  }

  void _markDelivered(NodeSession session, int? ack, int? rtt) {
    if (ack == null) return;
    for (final conv in session.conversations) {
      for (var i = 0; i < conv.messages.length; i++) {
        final m = conv.messages[i];
        if (m.outgoing &&
            m.ackCode == ack &&
            m.delivery != DeliveryStatus.delivered) {
          conv.messages[i] = m.copyWith(
            delivery: DeliveryStatus.delivered,
            rttMs: rtt,
          );
          return;
        }
      }
    }
  }

  void _ensureConvo(NodeSession session, MeshContact contact) {
    // Repeater & Co. sind Infrastruktur: kein Chat, nur Knoten-Tab.
    if (!contact.isChat) return;
    final existing = _findConvoFor(session, contact.publicKey);
    if (existing != null) {
      // Platzhalter eines unbekannten Absenders aufrüsten.
      if (existing.id.startsWith('prefix-') && contact.name.isNotEmpty) {
        existing.title = contact.name;
        existing.peerType = contact.type;
      }
      return;
    }
    session.conversations.add(_convoForContact(session.id, contact));
  }

  Conversation? _findConvoByPrefix(NodeSession session, Uint8List? prefix) {
    if (prefix == null || prefix.length < 6) return null;
    for (final c in session.conversations) {
      if (c.isChannel || c.peerKey == null) continue;
      if (_keyEq(c.peerKey!, prefix)) return c;
    }
    return null;
  }

  /// DM-Unterhaltungen erzeugen, falls noch keine existiert: bekannte
  /// Kontakte mit Namen, unbekannte Absender mit Prefix-Platzhalter.
  Conversation? _ensureConvoForPrefix(NodeSession session, Uint8List? prefix) {
    final found = _findConvoByPrefix(session, prefix);
    if (found != null) return found;
    if (prefix == null || prefix.length < 6) return null;
    for (final c in session.companion?.contacts ?? const <MeshContact>[]) {
      if (!_keyEq(c.publicKey, prefix)) continue;
      if (!c.isChat) return null;
      session.conversations.add(
        Conversation(
          id: 'convo-${c.keyHex}',
          title: c.name.isEmpty ? c.shortKey : c.name,
          isChannel: false,
          peerKey: Uint8List.fromList(c.publicKey),
          peerType: c.type,
          favourite: c.isFavourite,
        ),
      );
      return session.conversations.last;
    }
    final hex = prefix.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final conv = Conversation(
      id: 'prefix-$hex',
      title: hex,
      isChannel: false,
      peerKey: Uint8List.fromList(prefix),
      peerType: AdvType.none,
    );
    session.conversations.add(conv);
    return conv;
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
      final pre = e.senderPrefix;
      conv =
          _findConvoByPrefix(session, pre) ??
          _ensureConvoForPrefix(session, pre);
    }
    if (conv == null) return;
    // Lokale Filter: blockierte Absender werden verworfen, gedämpfte
    // Quellen zeigen kein Badge.
    final sender = _contactForPrefix(session, e.senderPrefix);
    final sKey = sender?.keyHex;
    if (sKey != null && blockedContacts.contains(sKey)) return;
    final muted =
        (conv.isChannel && mutedChannels.contains(conv.title)) ||
        (sKey != null && mutedContacts.contains(sKey));
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
        if (!identical(conv, _open) && !muted) {
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
              ? DateTime.fromMillisecondsSinceEpoch(
                  e.timestamp! * 1000,
                  isUtc: true,
                ).toLocal()
              : DateTime.now(),
          text: e.message,
          hopCount: e.hopCount,
          snr: e.snr,
          senderName: _nameForPrefix(session, e.senderPrefix),
        ),
      );
      if (!identical(conv, _open) && !muted) {
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
    final rtt =
        n.rttMs ??
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

  void _recordTracePing(TraceResult t) {
    final key = _tracePingByTag.remove(t.tag);
    if (key == null) return;
    final started = _pingStarted[key];
    final rttMs = started == null
        ? null
        : DateTime.now().difference(started).inMilliseconds;
    final prev = pings[key];
    if (prev == null) return;
    pings[key] = prev.copyWith(
      ok: true,
      inFlight: false,
      rttMs: rttMs,
      snr: t.finalSnrDb ?? t.worstSnrDb,
    );
    _pingTimers[key]?.cancel();
    status = '${prev.name} antwortet · ${t.summary}';
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
    final conv =
        session.conversations
            .where((c) => c.isChannel && c.channelIdx == pkt.channelIdx)
            .firstOrNull ??
        session.conversations.where((c) => c.isChannel).firstOrNull;
    if (conv == null) return;
    // Lokale Filter (gleiche Regel wie Live-Eingang).
    final sender = _contactForPrefix(
      session,
      e.senderPrefix ?? pkt.senderPrefix,
    );
    final sKey = sender?.keyHex;
    if (sKey != null && blockedContacts.contains(sKey)) return;
    final muted =
        (conv.isChannel && mutedChannels.contains(conv.title)) ||
        (sKey != null && mutedContacts.contains(sKey));
    final senderName =
        _nameForPrefix(session, e.senderPrefix) ??
        _nameForPrefix(session, pkt.senderPrefix);
    final dup = conv.messages.any((m) {
      if (m.catchUpId != null && m.catchUpId == pkt.msgId) return true;
      if (pkt.text != null &&
          pkt.text!.isNotEmpty &&
          m.text == pkt.text &&
          !m.outgoing) {
        final dt = (m.timestamp.millisecondsSinceEpoch ~/ 1000 - pkt.timestamp)
            .abs();
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
      if (!identical(conv, _open) && !muted) {
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
          conv.messages[i] = m.withPeerAck(
            peer.keyHex,
            ChannelPeerState.replayed,
          );
          sent++;
        } catch (_) {}
      }
    }
    if (sent > 0) notifyListeners();
  }

  void _disposeSession() {
    final s = session;
    if (s != null) {
      s.sub?.cancel();
      s.noticeSub?.cancel();
      s.engine.dispose();
    }
    session = null;
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
    _disposeSession();
    super.dispose();
  }
}
