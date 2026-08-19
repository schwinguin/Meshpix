import 'dart:convert';
import 'dart:typed_data';

import '../models/channel.dart';
import '../models/contact.dart';
import '../transfer/protocol.dart';
import 'constants.dart';
import 'frames.dart';

class DeviceSelf {
  DeviceSelf({required this.name, required this.publicKey, this.txPower});
  final String name;
  final Uint8List publicKey;
  final int? txPower;
}

class ParsedFrame {
  ParsedFrame(this.code, {this.self, this.contact, this.channel, this.incoming, this.errorCode});
  final int code;
  final DeviceSelf? self;
  final MeshContact? contact;
  final MeshChannel? channel;
  final IncomingPacket? incoming;
  final int? errorCode;
}

String _cstr(Uint8List d, int start, int maxLen) {
  final end = start + maxLen > d.length ? d.length : start + maxLen;
  var term = end;
  for (var i = start; i < end; i++) {
    if (d[i] == 0) {
      term = i;
      break;
    }
  }
  return utf8.decode(d.sublist(start, term), allowMalformed: true);
}

ParsedFrame? parseCompanionFrame(Uint8List d, {required int meshPixDataType}) {
  if (d.isEmpty) return null;
  final code = d[0];
  switch (code) {
    case Resp.ok:
    case Resp.msgSent:
    case Resp.noMoreMsgs:
    case Resp.contactsStart:
    case Resp.contactsEnd:
    case Resp.deviceInfo:
    case Resp.msgWaiting:
      return ParsedFrame(code);
    case Resp.error:
      return ParsedFrame(code, errorCode: d.length > 1 ? d[1] : null);
    case Resp.selfInfo:
      if (d.length < 1 + 1 + 1 + 1 + 32) return ParsedFrame(code);
      const keyOff = 4;
      final key = d.sublist(keyOff, keyOff + 32);
      // name is remainder after fixed fields; layout from companion wiki
      final nameOff = 4 + 32 + 4 + 4 + 1 + 1 + 1 + 1 + 4 + 4 + 1 + 1;
      final name = d.length > nameOff
          ? utf8.decode(d.sublist(nameOff), allowMalformed: true)
          : 'MeshCore';
      return ParsedFrame(
        code,
        self: DeviceSelf(name: name, publicKey: key, txPower: d[2]),
      );
    case Resp.contact:
      if (d.length < 1 + 32 + 1 + 1 + 1 + 64 + 32) return ParsedFrame(code);
      var o = 1;
      final key = d.sublist(o, o + 32);
      o += 32;
      o += 1; // type
      o += 1; // flags
      final pathLen = readI8(d[o]);
      o += 1;
      final path = d.sublist(o, o + 64);
      o += 64;
      final name = _cstr(d, o, 32);
      final outPath = pathLen > 0 && pathLen <= 64 ? path.sublist(0, pathLen) : Uint8List(0);
      return ParsedFrame(
        code,
        contact: MeshContact(
          publicKey: key,
          name: name,
          outPath: outPath,
        ),
      );
    case Resp.channelInfo:
      if (d.length < 3) return ParsedFrame(code);
      final idx = d[1];
      final name = d.length > 18
          ? _cstr(d, 18, 32)
          : 'Channel $idx';
      return ParsedFrame(
        code,
        channel: MeshChannel(index: idx, name: name.isEmpty ? 'Channel $idx' : name),
      );
    case Resp.contactMsgRecv:
    case Resp.contactMsgRecvV3:
      return ParsedFrame(code, incoming: _parseContactText(d, v3: code == Resp.contactMsgRecvV3));
    case Resp.channelMsgRecv:
    case Resp.channelMsgRecvV3:
      return ParsedFrame(code, incoming: _parseChannelText(d, v3: code == Resp.channelMsgRecvV3));
    case Resp.channelDataRecv:
      return ParsedFrame(
        code,
        incoming: _parseChannelData(d, meshPixDataType: meshPixDataType),
      );
    case Resp.rawData:
      return ParsedFrame(
        code,
        incoming: _parseRawData(d, meshPixDataType: meshPixDataType),
      );
    default:
      return ParsedFrame(code);
  }
}

IncomingPacket _parseContactText(Uint8List d, {required bool v3}) {
  var o = 1;
  double? snr;
  if (v3) {
    snr = readI8(d[o]) / 4.0;
    o += 1 + 2;
  }
  final prefix = d.sublist(o, o + 6);
  o += 6;
  final pathLen = d[o];
  o += 1;
  o += 1; // txt type
  o += 4; // timestamp
  final text = utf8.decode(d.sublist(o), allowMalformed: true);
  return IncomingPacket(
    kind: IncomingKind.text,
    fromChannel: false,
    senderPrefix: prefix,
    text: text,
    flooded: pathLen != 0xFF,
    snr: snr,
  );
}

IncomingPacket _parseChannelText(Uint8List d, {required bool v3}) {
  var o = 1;
  double? snr;
  if (v3) {
    snr = readI8(d[o]) / 4.0;
    o += 1 + 2;
  }
  final idx = d[o];
  o += 1;
  final pathLen = d[o];
  o += 1;
  o += 1;
  o += 4;
  final text = utf8.decode(d.sublist(o), allowMalformed: true);
  return IncomingPacket(
    kind: IncomingKind.text,
    fromChannel: true,
    channelIdx: idx,
    text: text,
    flooded: pathLen != 0xFF,
    snr: snr,
  );
}

IncomingPacket _parseChannelData(Uint8List d, {required int meshPixDataType}) {
  // [0x1B][snr][res x2][ch][path_len][data_type u16][len][payload]
  if (d.length < 9) {
    return IncomingPacket(kind: IncomingKind.unknown, fromChannel: true);
  }
  final snr = readI8(d[1]) / 4.0;
  final idx = d[4];
  final pathLen = d[5];
  final dataType = readU16(d, 6);
  final len = d[8];
  final payload = d.length >= 9 + len ? d.sublist(9, 9 + len) : d.sublist(9);
  final kind = dataType == meshPixDataType ? IncomingKind.meshPix : IncomingKind.unknown;
  return IncomingPacket(
    kind: kind,
    fromChannel: true,
    channelIdx: idx,
    dataType: dataType,
    payload: payload,
    flooded: pathLen != 0xFF,
    snr: snr,
  );
}

IncomingPacket _parseRawData(Uint8List d, {required int meshPixDataType}) {
  // [0x84][snr][rssi][0xFF][payload]
  if (d.length < 4) {
    return IncomingPacket(kind: IncomingKind.unknown, fromChannel: false);
  }
  final snr = readI8(d[1]) / 4.0;
  final payload = d.sublist(4);
  final looksMp = payload.length >= 2 && payload[0] == 0x4D && payload[1] == 0x50;
  return IncomingPacket(
    kind: looksMp ? IncomingKind.meshPix : IncomingKind.unknown,
    fromChannel: false,
    dataType: looksMp ? meshPixDataType : null,
    payload: payload,
    snr: snr,
  );
}
