import 'dart:convert';
import 'dart:typed_data';

import 'constants.dart';

Uint8List _u32(int v) =>
    Uint8List.fromList([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);

Uint8List cmdDeviceQuery({int appTargetVer = 8}) =>
    Uint8List.fromList([Cmd.deviceQuery, appTargetVer]);

Uint8List cmdAppStart({String appName = 'MeshPix', int appVer = 1}) {
  return Uint8List.fromList([
    Cmd.appStart,
    appVer,
    0,
    0,
    0,
    0,
    0,
    0,
    ...utf8.encode(appName),
  ]);
}

Uint8List cmdGetContacts() => Uint8List.fromList([Cmd.getContacts]);

Uint8List cmdGetChannel(int idx) => Uint8List.fromList([Cmd.getChannel, idx]);

Uint8List cmdSyncNextMessage() => Uint8List.fromList([Cmd.syncNextMessage]);

Uint8List cmdSendTxtMsg({
  required Uint8List pubkeyPrefix,
  required String text,
  int timestamp = 0,
  int attempt = 0,
}) {
  final prefix = Uint8List(6);
  final n = pubkeyPrefix.length < 6 ? pubkeyPrefix.length : 6;
  prefix.setRange(0, n, pubkeyPrefix);
  return Uint8List.fromList([
    Cmd.sendTxtMsg,
    0, // plain
    attempt,
    ..._u32(timestamp),
    ...prefix,
    ...utf8.encode(text),
  ]);
}

Uint8List cmdSendChannelTxtMsg({
  required int channelIdx,
  required String text,
  int timestamp = 0,
}) {
  return Uint8List.fromList([
    Cmd.sendChannelTxtMsg,
    0,
    channelIdx,
    ..._u32(timestamp),
    ...utf8.encode(text),
  ]);
}

/// Channel binary datagram. [pathLen] 0xFF = flood.
Uint8List cmdSendChannelData({
  required int channelIdx,
  required int dataType,
  required Uint8List payload,
  int pathLen = 0xFF,
  Uint8List? path,
}) {
  final out = BytesBuilder(copy: false);
  out.addByte(Cmd.sendChannelData);
  out.addByte(channelIdx);
  out.addByte(pathLen);
  if (pathLen != 0xFF && path != null) {
    out.add(path);
  }
  out.addByte(dataType & 0xFF);
  out.addByte((dataType >> 8) & 0xFF);
  out.add(payload);
  return out.takeBytes();
}

Uint8List cmdSendRawData({
  required Uint8List payload,
  Uint8List? path,
}) {
  final p = path ?? Uint8List(0);
  return Uint8List.fromList([Cmd.sendRawData, p.length, ...p, ...payload]);
}

int readU32(Uint8List d, int o) =>
    d[o] | (d[o + 1] << 8) | (d[o + 2] << 16) | (d[o + 3] << 24);

int readU16(Uint8List d, int o) => d[o] | (d[o + 1] << 8);

int readI8(int b) => b > 127 ? b - 256 : b;
