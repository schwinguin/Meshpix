import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../codec/mp1.dart';
import '../codec/palettes.dart';
import '../models/chat.dart';

/// Persistiert die Chat-Verläufe lokal: ein JSON-File pro Knoten unter
/// `<App-Documente>/chat/<nodeKey>.json`.
///
/// Das Funkgerät behält den Verlauf nicht für die App vor — ohne lokalen
/// Speicher wären alle Unterhaltungen nach jedem App-Neustart leer. Gespeichert
/// wird bei jeder Änderung (Debounced), wiederhergestellt bei jeder
/// Verbindung. Transiente Zustände (Delivery, Pull-Fortschritt) werden nicht
/// übernommen.
class ChatStore {
  ChatStore({this.dir});

  final Directory? dir;

  /// Max. Nachrichten pro Konversation (die ältesten werden verworfen).
  static const maxMessagesPerConvo = 400;

  /// Budget (in Base64-Zeichen) für Bild-Data im File; ältere Bilder werden
  /// ohne Pixel-Data als Text-Platzhalter gespeichert.
  static const maxImageBudget = 1_000_000;

  static String safeKey(String key) =>
      key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  Future<Directory> _base() async {
    final root = dir ?? await getApplicationDocumentsDirectory();
    final sub = Directory('${root.path}/chat');
    await sub.create(recursive: true);
    return sub;
  }

  Future<File> _file(String nodeKey) async =>
      File('${(await _base()).path}/${safeKey(nodeKey)}.json');

  Future<void> save(List<Conversation> convos, String nodeKey) async {
    final file = await _file(nodeKey);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(_encode(convos)));
    await tmp.rename(file.path);
  }

  Future<List<Conversation>> load(String nodeKey) async {
    final file = await _file(nodeKey);
    if (!await file.exists()) return const [];
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map<String, Object?>) return const [];
      return _decode(raw);
    } catch (_) {
      return const [];
    }
  }

  // --- Serialize -----------------------------------------------------------

  Map<String, Object?> _encode(List<Conversation> convos) {
    final budget = [maxImageBudget];
    return {
      'v': 1,
      'convos': [for (final c in convos) _encodeConvo(c, budget)],
    };
  }

  Map<String, Object?> _encodeConvo(Conversation c, List<int> budget) {
    final msgs = c.messages.length > maxMessagesPerConvo
        ? c.messages.sublist(c.messages.length - maxMessagesPerConvo)
        : c.messages;
    final encoded = List<Map<String, Object?>>.filled(msgs.length, {});
    // Neueste zuerst: das Bild-Budget gilt für die jüngsten Nachrichten.
    for (var i = msgs.length - 1; i >= 0; i--) {
      encoded[i] = _encodeMsg(msgs[i], budget);
    }
    return {
      if (c.isChannel && c.channelIdx != null) 'ch': c.channelIdx,
      if (!c.isChannel && c.peerKey != null) 'key': _hex(c.peerKey!),
      'title': c.title,
      if (c.peerType != null) 'type': c.peerType,
      if (c.favourite) 'fav': true,
      'msgs': encoded,
    };
  }

  Map<String, Object?> _encodeMsg(ChatMessage m, List<int> budget) {
    final doc = <String, Object?>{
      'id': m.id,
      'k': m.kind.index,
      'out': m.outgoing,
      'ts': m.timestamp.millisecondsSinceEpoch,
    };
    final text = m.text;
    if (text != null && text.isNotEmpty) doc['t'] = text;
    if (m.kind == ChatKind.image && m.canPull) doc['cp'] = true;
    final img = m.image;
    if (img != null) {
      final enc = _encodeImage(img, budget);
      if (enc != null) doc['img'] = enc;
    }
    if (m.ackCode != null) doc['ack'] = m.ackCode;
    if (m.rttMs != null) doc['rtt'] = m.rttMs;
    if (m.hopCount != null) doc['hop'] = m.hopCount;
    if (m.snr != null) doc['snr'] = m.snr;
    if (m.senderName != null) doc['sn'] = m.senderName;
    if (m.catchUpId != null) doc['cu'] = m.catchUpId;
    if (m.catchUp) doc['cuf'] = true;
    if (m.channelAcks.isNotEmpty) {
      doc['acks'] = [
        for (final a in m.channelAcks)
          {'k': a.keyHex, 'n': a.name, 's': a.state.index},
      ];
    }
    return doc;
  }

  Map<String, Object?>? _encodeImage(DecodedImage img, List<int> budget) {
    final doc = <String, Object?>{
      'w': img.width,
      'h': img.height,
      'ch': img.upgradeChunks,
    };
    final argb = img.argb;
    if (argb != null) {
      final b64 = base64Encode(Uint8List.view(argb.buffer));
      if (budget[0] < b64.length) return null;
      budget[0] -= b64.length;
      doc['a'] = b64;
      return doc;
    }
    doc['pal'] = [for (final c in img.palette.colors) c.argb];
    doc['idx'] = img.indices;
    doc['d'] = img.dithered;
    return doc;
  }

  // --- Deserialize ---------------------------------------------------------

  List<Conversation> _decode(Map<String, Object?> raw) {
    final out = <Conversation>[];
    final convos = raw['convos'];
    if (convos is! List) return out;
    for (final o in convos) {
      if (o is! Map<String, Object?>) continue;
      final chIdx = o['ch'];
      final keyHex = o['key'] is String ? o['key'] as String : null;
      final conv = Conversation(
        id: chIdx is int ? 'ch$chIdx' : 'dm-${keyHex ?? '?'}',
        title: o['title'] is String ? o['title'] as String : '',
        isChannel: chIdx is int,
        channelIdx: chIdx is int ? chIdx : null,
        peerKey: keyHex != null ? _fromHex(keyHex) : null,
        peerType: o['type'] is int ? o['type'] as int : null,
        favourite: o['fav'] == true,
      );
      final msgs = o['msgs'];
      if (msgs is List) {
        for (final m in msgs) {
          final decoded = _decodeMsg(m);
          if (decoded != null) conv.messages.add(decoded);
        }
      }
      out.add(conv);
    }
    return out;
  }

  ChatMessage? _decodeMsg(Object? o) {
    if (o is! Map<String, Object?>) return null;
    final id = o['id'];
    if (id is! String) return null;
    final imgRaw = o['img'];
    DecodedImage? image;
    if (imgRaw is Map<String, Object?>) image = _decodeImage(imgRaw);
    return ChatMessage(
      id: id,
      kind: o['k'] == 1 ? ChatKind.image : ChatKind.text,
      outgoing: o['out'] == true,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        o['ts'] is int ? o['ts'] as int : 0,
      ),
      text: o['t'] is String ? o['t'] as String : null,
      image: image,
      canPull: o['cp'] == true,
      ackCode: o['ack'] is int ? o['ack'] as int : null,
      rttMs: o['rtt'] is int ? o['rtt'] as int : null,
      hopCount: o['hop'] is int ? o['hop'] as int : null,
      snr: o['snr'] is num ? (o['snr'] as num).toDouble() : null,
      senderName: o['sn'] is String ? o['sn'] as String : null,
      catchUpId: o['cu'] is int ? o['cu'] as int : null,
      catchUp: o['cuf'] == true,
      channelAcks: [
        if (o['acks'] is List)
          for (final a in o['acks'] as List)
            if (a is Map<String, Object?> && a['k'] is String && a['s'] is int)
              ChannelPeerAck(
                keyHex: a['k'] as String,
                name: a['n'] is String ? a['n'] as String : '',
                state:
                    ChannelPeerState.values[(a['s'] as int).clamp(
                      0,
                      ChannelPeerState.values.length - 1,
                    )],
              ),
      ],
    );
  }

  DecodedImage? _decodeImage(Map<String, Object?> o) {
    final w = o['w'] is int ? o['w'] as int : 0;
    final h = o['h'] is int ? o['h'] as int : 0;
    final chunks = o['ch'] is int ? o['ch'] as int : 0;
    if (w <= 0 || h <= 0) return null;
    final a = o['a'];
    if (a is String) {
      try {
        final bytes = base64Decode(a);
        if (bytes.length != w * h * 4) return null;
        return DecodedImage(
          width: w,
          height: h,
          palette: const Palette(id: -1, name: 'argb', colors: []),
          indices: const [],
          dithered: false,
          upgradeChunks: chunks,
          argb: Uint32List.view(Uint8List.fromList(bytes).buffer, 0, w * h),
        );
      } catch (_) {
        return null;
      }
    }
    final pal = o['pal'] is List
        ? [
            for (final c in o['pal'] as List)
              if (c is int) Rgb((c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF),
          ]
        : <Rgb>[];
    final idx = o['idx'] is List
        ? [
            for (final i in o['idx'] as List)
              if (i is int) i,
          ]
        : <int>[];
    if (pal.isEmpty || idx.length != w * h) return null;
    return DecodedImage(
      width: w,
      height: h,
      palette: Palette(id: -1, name: 'stored', colors: pal),
      indices: idx,
      dithered: o['d'] == true,
      upgradeChunks: chunks,
    );
  }

  // --- Helpers -------------------------------------------------------------

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List? _fromHex(String hex) {
    if (hex.isEmpty || hex.length.isOdd) return null;
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      final v = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
      if (v == null) return null;
      out[i] = v;
    }
    return out;
  }
}
