import 'dart:async';

import 'package:flutter/foundation.dart';

import '../codec/mp1.dart';
import '../codec/palettes.dart';
import '../codec/rgba.dart';
import '../companion/ble.dart';
import '../companion/client.dart';
import '../models/chat.dart';
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

  final String id;
  final String name;
  final PacketRadio radio;
  final TransferEngine engine;
  final List<Conversation> conversations;
  StreamSubscription<TransferEvent>? sub;
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

  CompanionClient? _bleClient;
  BleTransport? _bleTransport;
  BleScanner? _scanner;
  StreamSubscription<List<BleScanHit>>? _scanSub;

  NodeSession get active => sessions[activeNodeId]!;

  Conversation? _open;
  Conversation? get openConversation => _open;

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
    annaRadio.refreshContacts();
    benRadio.refreshContacts();
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
    final convos = <Conversation>[
      Conversation(
        id: '${radio.identity.id}-ch0',
        title: 'Public',
        isChannel: true,
        channelIdx: 0,
      ),
    ];
    for (final c in radio.contacts) {
      convos.add(
        Conversation(
          id: '${radio.identity.id}-${c.name}',
          title: c.name,
          isChannel: false,
          peerKey: Uint8List.fromList(c.publicKey),
        ),
      );
    }
    final session = NodeSession(
      id: radio.identity.id,
      name: radio.identity.name,
      radio: radio,
      engine: engine,
      conversations: convos,
    );
    session.sub = engine.events.listen((e) => _onEvent(session, e));
    return session;
  }

  void switchNode(String id) {
    if (!sessions.containsKey(id)) return;
    activeNodeId = id;
    _open = active.conversations.first;
    notifyListeners();
  }

  void open(Conversation c) {
    _open = c;
    notifyListeners();
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
      final convos = <Conversation>[
        Conversation(
          id: 'ch0',
          title: 'Public',
          isChannel: true,
          channelIdx: 0,
        ),
      ];
      for (final ch in _bleClient!.channels) {
        if (ch.index == 0) {
          convos[0] = Conversation(
            id: 'ch${ch.index}',
            title: ch.name,
            isChannel: true,
            channelIdx: ch.index,
          );
        } else {
          convos.add(
            Conversation(
              id: 'ch${ch.index}',
              title: ch.name,
              isChannel: true,
              channelIdx: ch.index,
            ),
          );
        }
      }
      for (final c in _bleClient!.contacts) {
        convos.add(
          Conversation(
            id: 'dm-${c.name}',
            title: c.name,
            isChannel: false,
            peerKey: Uint8List.fromList(c.publicKey),
          ),
        );
      }
      final name = _bleClient!.self?.name ?? hit.name;
      sessions['ble'] = NodeSession(
        id: 'ble',
        name: name,
        radio: _bleClient!,
        engine: engine,
        conversations: convos,
      )..sub = engine.events.listen((e) => _onEvent(sessions['ble']!, e));
      activeNodeId = 'ble';
      _open = convos.first;
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
    return RadioDestination.dm(c.peerKey ?? Uint8List(6));
  }

  Future<void> sendText(String text) async {
    final conv = _open;
    if (conv == null || text.trim().isEmpty) return;
    conv.messages.add(
      ChatMessage(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        kind: ChatKind.text,
        outgoing: true,
        timestamp: DateTime.now(),
        text: text.trim(),
      ),
    );
    notifyListeners();
    await active.engine.sendText(destFor(conv), text.trim());
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
    // The sender has the original — their own bubble shows it at full quality,
    // not the quantized preview that goes over the air.
    final local = _fullResImage(source) ?? sent.preview.image;
    conv.messages.add(
      ChatMessage(
        id: 'out-${sent.transferId}',
        kind: ChatKind.image,
        outgoing: true,
        timestamp: DateTime.now(),
        image: local,
        transferId: sent.transferId,
        text: sent.stats.summaryDe,
      ),
    );
    notifyListeners();
  }

  /// Full-quality local render of the original (center-cropped square, no upscale).
  DecodedImage? _fullResImage(RgbaImage? source) {
    if (source == null) return null;
    final side = source.width < source.height ? source.width : source.height;
    final sq = source.square(side);
    return DecodedImage(
      width: sq.width,
      height: sq.height,
      palette: mesh16,
      indices: const [],
      dithered: false,
      upgradeChunks: 0,
      argb: sq.toArgb(),
    );
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

  void _onEvent(NodeSession session, TransferEvent e) {
    if (e.outgoing && e.image != null) {
      // already added locally on send
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
        text: e.message,
        canPull: (e.image?.upgradeChunks ?? 0) > 0 && !e.fromChannel,
      );
      if (existing >= 0) {
        conv.messages[existing] = msg;
      } else {
        conv.messages.add(msg);
      }
    } else if (e.isText) {
      conv.messages.add(
        ChatMessage(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          kind: ChatKind.text,
          outgoing: false,
          timestamp: DateTime.now(),
          text: e.message,
        ),
      );
    }
    notifyListeners();
  }

  void _disposeSessions() {
    for (final s in sessions.values) {
      s.sub?.cancel();
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
