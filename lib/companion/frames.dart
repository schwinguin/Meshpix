import 'dart:convert';
import 'dart:typed_data';

import '../models/contact.dart';
import '../models/device.dart';
import 'constants.dart';

Uint8List _u32(int v) =>
    Uint8List.fromList([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);

Uint8List _i32(int v) => _u32(v);

Uint8List _pad(List<int> src, int len) {
  final out = Uint8List(len);
  final n = src.length < len ? src.length : len;
  out.setRange(0, n, src);
  return out;
}

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

Uint8List cmdGetContacts({int? since}) {
  if (since == null) return Uint8List.fromList([Cmd.getContacts]);
  return Uint8List.fromList([Cmd.getContacts, ..._u32(since)]);
}

Uint8List cmdGetChannel(int idx) => Uint8List.fromList([Cmd.getChannel, idx]);

/// Kanal anlegen/aktualisieren: `[0x20, idx, name (32B), secret (16B)]`.
/// Index 0 = Public (Secret null), 1–7 = private Kanäle.
Uint8List cmdSetChannel(int idx, String name, Uint8List secret) =>
    Uint8List.fromList([
      Cmd.setChannel,
      idx,
      ..._pad(utf8.encode(name), 32),
      ..._pad(secret, 16),
    ]);

Uint8List cmdSyncNextMessage() => Uint8List.fromList([Cmd.syncNextMessage]);

Uint8List cmdSetDeviceTime(int epochSecs) =>
    Uint8List.fromList([Cmd.setDeviceTime, ..._u32(epochSecs)]);

Uint8List cmdSendSelfAdvert({bool flood = false}) =>
    Uint8List.fromList([Cmd.sendSelfAdvert, flood ? 1 : 0]);

Uint8List cmdSetAdvertName(String name) =>
    Uint8List.fromList([Cmd.setAdvertName, ...utf8.encode(name)]);

Uint8List cmdGetBattAndStorage() => Uint8List.fromList([Cmd.getBattAndStorage]);

Uint8List cmdSetRadioParams(RadioSettings s) => Uint8List.fromList([
      Cmd.setRadioParams,
      ..._u32(s.freqWire),
      ..._u32(s.bwWire),
      s.spreadingFactor,
      s.codingRate,
      s.repeatMode ? 1 : 0,
    ]);

Uint8List cmdSetRadioTxPower(int dbm) =>
    Uint8List.fromList([Cmd.setRadioTxPower, dbm & 0xFF]);

Uint8List cmdAddUpdateContact(MeshContact c) {
  final path = _pad(c.outPath ?? const [], 64);
  final name = _pad(utf8.encode(c.name), 32);
  final lat = ((c.lat ?? 0) * 1e6).round();
  final lon = ((c.lon ?? 0) * 1e6).round();
  // path_len = count & 63 | ((entrySize-1) << 6), cf. Packet::writePath.
  final pathLen = c.hasPath
      ? (c.hopCount & 63) | ((c.outPathEntrySize - 1) << 6)
      : 0;
  return Uint8List.fromList([
    Cmd.addUpdateContact,
    ..._pad(c.publicKey, 32),
    c.type,
    c.flags,
    pathLen,
    ...path,
    ...name,
    ..._u32(c.lastAdvert ?? 0),
    ..._i32(lat),
    ..._i32(lon),
  ]);
}

Uint8List cmdRemoveContact(List<int> publicKey) =>
    Uint8List.fromList([Cmd.removeContact, ..._pad(publicKey, 32)]);

/// Factory reset: `[0x33, "reset"]`. Kein OK-Frame — das Gerät deaktiviert
/// die serielle Schnittstelle (BLE) direkt vor dem Reset.
Uint8List cmdFactoryReset() => Uint8List.fromList([
      Cmd.factoryReset,
      0x72, // 'r'
      0x65, // 'e'
      0x73, // 's'
      0x65, // 'e'
      0x74, // 't'
    ]);

Uint8List cmdShareContact(List<int> publicKey) =>
    Uint8List.fromList([Cmd.shareContact, ..._pad(publicKey, 32)]);

Uint8List cmdResetPath(List<int> publicKey) =>
    Uint8List.fromList([Cmd.resetPath, ..._pad(publicKey, 32)]);

Uint8List cmdSendStatusReq(List<int> publicKey) =>
    Uint8List.fromList([Cmd.sendStatusReq, ..._pad(publicKey, 32)]);

Uint8List cmdSendTelemetryReq(List<int> publicKey) =>
    Uint8List.fromList([Cmd.sendTelemetryReq, 0, 0, 0, ..._pad(publicKey, 32)]);

Uint8List cmdExportContact([List<int>? publicKey]) {
  if (publicKey == null) return Uint8List.fromList([Cmd.exportContact]);
  return Uint8List.fromList([Cmd.exportContact, ..._pad(publicKey, 32)]);
}

Uint8List cmdImportContact(Uint8List card) =>
    Uint8List.fromList([Cmd.importContact, ...card]);

Uint8List cmdSendLogin({
  required List<int> publicKey,
  required String password,
}) {
  return Uint8List.fromList([
    Cmd.sendLogin,
    ..._pad(publicKey, 32),
    ...utf8.encode(password),
  ]);
}

Uint8List cmdSendTracePath({
  required List<int> path,
  int tag = 1,
  int authCode = 0,
  int flags = 0,
}) {
  return Uint8List.fromList([
    Cmd.sendTracePath,
    ..._u32(tag),
    ..._u32(authCode),
    flags,
    ...path,
  ]);
}

Uint8List cmdSendTxtMsg({
  required Uint8List pubkeyPrefix,
  required String text,
  int timestamp = 0,
  int attempt = 0,
  int txtType = TxtType.plain,
}) {
  final prefix = Uint8List(6);
  final n = pubkeyPrefix.length < 6 ? pubkeyPrefix.length : 6;
  prefix.setRange(0, n, pubkeyPrefix);
  return Uint8List.fromList([
    Cmd.sendTxtMsg,
    txtType,
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
    TxtType.plain,
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

int readI32(Uint8List d, int o) {
  final u = readU32(d, o);
  return u > 0x7FFFFFFF ? u - 0x100000000 : u;
}

int readU16(Uint8List d, int o) => d[o] | (d[o + 1] << 8);

int readI8(int b) => b > 127 ? b - 256 : b;

int readI16(Uint8List d, int o) {
  final u = readU16(d, o);
  return u > 0x7FFF ? u - 0x10000 : u;
}
