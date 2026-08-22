import 'dart:convert';
import 'dart:typed_data';

import '../codec/limits.dart';

class CatchKind {
  static const text = 0;
  static const receipt = 1;
  static const syncReq = 2;
}

class CatchUpPacket {
  CatchUpPacket({
    required this.kind,
    required this.channelIdx,
    required this.msgId,
    required this.timestamp,
    required this.senderPrefix,
    this.text,
  });

  final int kind;
  final int channelIdx;
  final int msgId;
  final int timestamp;
  final Uint8List senderPrefix;
  final String? text;

  bool get isReceipt => kind == CatchKind.receipt;
  bool get isSyncReq => kind == CatchKind.syncReq;
}

const _magic0 = 0x4D; // M
const _magic1 = 0x43; // C

bool looksLikeCatchUp(Uint8List payload) =>
    payload.length >= 19 && payload[0] == _magic0 && payload[1] == _magic1;

Uint8List encodeCatchUp(CatchUpPacket p) {
  final prefix = Uint8List(6);
  final n = p.senderPrefix.length < 6 ? p.senderPrefix.length : 6;
  prefix.setRange(0, n, p.senderPrefix);
  final text = utf8.encode(p.text ?? '');
  final maxText = kMaxDatagramPayload - 19;
  final clipped = text.length > maxText ? text.sublist(0, maxText) : text;
  return Uint8List.fromList([
    _magic0,
    _magic1,
    1,
    p.kind,
    p.channelIdx & 0xFF,
    p.msgId & 0xFF,
    (p.msgId >> 8) & 0xFF,
    (p.msgId >> 16) & 0xFF,
    (p.msgId >> 24) & 0xFF,
    p.timestamp & 0xFF,
    (p.timestamp >> 8) & 0xFF,
    (p.timestamp >> 16) & 0xFF,
    (p.timestamp >> 24) & 0xFF,
    ...prefix,
    ...clipped,
  ]);
}

CatchUpPacket? decodeCatchUp(Uint8List d) {
  if (!looksLikeCatchUp(d)) return null;
  final msgId = d[5] | (d[6] << 8) | (d[7] << 16) | (d[8] << 24);
  final ts = d[9] | (d[10] << 8) | (d[11] << 16) | (d[12] << 24);
  final prefix = d.sublist(13, 19);
  final text = d.length > 19
      ? utf8.decode(d.sublist(19), allowMalformed: true)
      : null;
  return CatchUpPacket(
    kind: d[3],
    channelIdx: d[4],
    msgId: msgId,
    timestamp: ts,
    senderPrefix: prefix,
    text: text == null || text.isEmpty ? null : text,
  );
}

int catchUpMsgId(String seed) {
  var h = 2166136261;
  for (final u in utf8.encode(seed)) {
    h ^= u;
    h = (h * 16777619) & 0xFFFFFFFF;
  }
  return h == 0 ? 1 : h;
}
