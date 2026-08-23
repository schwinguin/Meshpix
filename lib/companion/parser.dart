import 'dart:convert';
import 'dart:typed_data';

import '../models/channel.dart';
import '../models/contact.dart';
import '../models/device.dart';
import '../codec/limits.dart';
import '../models/repeater.dart';
import '../transfer/catchup.dart';
import '../models/signal.dart';
import '../transfer/protocol.dart';
import 'constants.dart';
import 'control.dart';
import 'frames.dart';

class ParsedFrame {
  ParsedFrame(
    this.code, {
    this.self,
    this.contact,
    this.channel,
    this.incoming,
    this.errorCode,
    this.receipt,
    this.ackCode,
    this.rttMs,
    this.battery,
    this.firmware,
    this.advertKey,
    this.exportCard,
    this.statusSummary,
    this.repeaterStatus,
    this.loginOk,
    this.isAdmin,
    this.permissions,
    this.trace,
  });

  final int code;
  final DeviceSelf? self;
  final MeshContact? contact;
  final MeshChannel? channel;
  final IncomingPacket? incoming;
  final int? errorCode;
  final TxReceipt? receipt;
  final int? ackCode;
  final int? rttMs;
  final BatteryInfo? battery;
  final FirmwareInfo? firmware;
  final Uint8List? advertKey;
  final Uint8List? exportCard;
  final String? statusSummary;
  final RepeaterStatus? repeaterStatus;
  final bool? loginOk;
  final bool? isAdmin;
  final int? permissions;
  final TraceResult? trace;
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
    case Resp.noMoreMsgs:
    case Resp.contactsStart:
    case Resp.contactsEnd:
    case Resp.currTime:
    case Resp.msgWaiting:
      return ParsedFrame(code);
    case Resp.error:
      return ParsedFrame(code, errorCode: d.length > 1 ? d[1] : null);
    case Resp.msgSent:
      return ParsedFrame(code, receipt: _parseSent(d));
    case Resp.sendConfirmed:
      if (d.length < 9) return ParsedFrame(code);
      return ParsedFrame(code, ackCode: readU32(d, 1), rttMs: readU32(d, 5));
    case Resp.deviceInfo:
      return ParsedFrame(code, firmware: _parseDeviceInfo(d));
    case Resp.selfInfo:
      return ParsedFrame(code, self: _parseSelf(d));
    case Resp.contact:
    case Resp.newAdvert:
      return ParsedFrame(code, contact: _parseContact(d));
    case Resp.advert:
    case Resp.pathUpdated:
      if (d.length < 33) return ParsedFrame(code);
      return ParsedFrame(code, advertKey: d.sublist(1, 33));
    case Resp.battAndStorage:
      if (d.length < 3) return ParsedFrame(code);
      return ParsedFrame(
        code,
        battery: BatteryInfo(
          milliVolts: readU16(d, 1),
          usedKb: d.length >= 7 ? readU32(d, 3) : null,
          totalKb: d.length >= 11 ? readU32(d, 7) : null,
        ),
      );
    case Resp.exportContact:
      return ParsedFrame(
        code,
        exportCard: d.length > 1 ? d.sublist(1) : Uint8List(0),
      );
    case Resp.channelInfo:
      return ParsedFrame(code, channel: _parseChannel(d));
    case Resp.contactMsgRecv:
    case Resp.contactMsgRecvV3:
      return ParsedFrame(
        code,
        incoming: _parseContactText(d, v3: code == Resp.contactMsgRecvV3),
      );
    case Resp.channelMsgRecv:
    case Resp.channelMsgRecvV3:
      return ParsedFrame(
        code,
        incoming: _parseChannelText(d, v3: code == Resp.channelMsgRecvV3),
      );
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
    case Resp.statusResponse:
    case Resp.telemetryResponse:
      final status = _parseRepeaterStatusFrame(d);
      return ParsedFrame(
        code,
        statusSummary: status.summary,
        repeaterStatus: status,
        advertKey: d.length >= 8 ? d.sublist(2, 8) : null,
      );
    case Resp.loginSuccess:
      return ParsedFrame(
        code,
        loginOk: true,
        isAdmin: d.length > 1 ? (d[1] & 0x01) == 1 : false,
        permissions: d.length > 12 ? d[12] : (d.length > 1 ? d[1] : 0),
        advertKey: d.length >= 8 ? d.sublist(2, 8) : null,
      );
    case Resp.loginFail:
      return ParsedFrame(
        code,
        loginOk: false,
        advertKey: d.length >= 8 ? d.sublist(2, 8) : null,
      );
    case Resp.traceData:
      return ParsedFrame(code, trace: _parseTraceFrame(d));
    default:
      return ParsedFrame(code);
  }
}

TxReceipt _parseSent(Uint8List d) {
  if (d.length < 10) return const TxReceipt();
  return TxReceipt(
    flooded: d[1] == 1,
    expectedAck: readU32(d, 2),
    timeoutMs: readU32(d, 6),
  );
}

FirmwareInfo _parseDeviceInfo(Uint8List d) {
  if (d.length < 2) return const FirmwareInfo();
  return FirmwareInfo(
    firmwareVer: d[1],
    maxContacts: d.length > 2 ? d[2] * 2 : null,
    maxChannels: d.length > 3 ? d[3] : null,
    buildDate: d.length > 19 ? _cstr(d, 8, 12) : null,
    model: d.length > 59 ? _cstr(d, 20, 40) : null,
    semanticVersion: d.length > 79 ? _cstr(d, 60, 20) : null,
  );
}

DeviceSelf _parseSelf(Uint8List d) {
  if (d.length < 5) {
    return DeviceSelf(name: 'MeshCore', publicKey: Uint8List(32));
  }
  const keyOff = 4;
  final key = d.length >= keyOff + 32
      ? d.sublist(keyOff, keyOff + 32)
      : Uint8List(32);
  double? lat;
  double? lon;
  RadioSettings? radio;
  if (d.length >= 44) {
    final li = readI32(d, 36);
    final lo = readI32(d, 40);
    if (li != 0 || lo != 0) {
      lat = li / 1e6;
      lon = lo / 1e6;
    }
  }
  if (d.length >= 58) {
    radio = RadioSettings(
      freqMhz: readU32(d, 48) / 1000.0,
      bwKhz: readU32(d, 52) / 1000.0,
      spreadingFactor: d[56],
      codingRate: d[57],
      txPowerDbm: d[2],
      maxTxPowerDbm: d[3],
    );
  }
  const nameOff = 58;
  final name = d.length > nameOff
      ? utf8
            .decode(d.sublist(nameOff), allowMalformed: true)
            .replaceAll('\u0000', '')
            .trim()
      : 'MeshCore';
  return DeviceSelf(
    name: name.isEmpty ? 'MeshCore' : name,
    publicKey: key,
    type: d.length > 1 ? d[1] : AdvType.chat,
    txPower: d.length > 2 ? d[2] : null,
    maxTxPower: d.length > 3 ? d[3] : null,
    lat: lat,
    lon: lon,
    radio: radio,
    manualAddContacts: d.length > 47 ? d[47] == 1 : false,
  );
}

MeshContact? _parseContact(Uint8List d) {
  if (d.length < 1 + 32 + 1 + 1 + 1 + 64 + 32) return null;
  var o = 1;
  final key = d.sublist(o, o + 32);
  o += 32;
  final type = d[o];
  o += 1;
  final flags = d[o];
  o += 1;
  final rawPath = d[o] & 0xFF;
  o += 1;
  final path = d.sublist(o, o + 64);
  o += 64;
  final name = _cstr(d, o, 32);
  o += 32;
  int? lastAdvert;
  double? lat;
  double? lon;
  int? lastmod;
  if (d.length >= o + 4) {
    lastAdvert = readU32(d, o);
    o += 4;
  }
  if (d.length >= o + 8) {
    final li = readI32(d, o);
    final lo = readI32(d, o + 4);
    if (li != 0 || lo != 0) {
      lat = li / 1e6;
      lon = lo / 1e6;
    }
    o += 8;
  }
  if (d.length >= o + 4) {
    lastmod = readU32(d, o);
  }
  // 0xFF = OUT_PATH_UNKNOWN (Sentinel). Sonst: count & 63 | ((size-1) << 6).
  var outPath = <int>[];
  var outPathEntrySize = 1;
  if (rawPath != 0xFF) {
    outPathEntrySize = (rawPath >> 6) + 1;
    final count = rawPath & 0x3F;
    final bytes = (count * outPathEntrySize).clamp(0, 64);
    outPath = path.sublist(0, bytes);
  }
  return MeshContact(
    publicKey: key,
    name: name,
    type: type,
    flags: flags,
    outPath: outPath,
    outPathEntrySize: outPathEntrySize,
    lastAdvert: lastAdvert,
    lat: lat,
    lon: lon,
    alt: null,
    lastmod: lastmod,
  );
}

MeshChannel _parseChannel(Uint8List d) {
  if (d.length < 2) return MeshChannel(index: 0, name: 'Public');
  final idx = d[1];
  var name = 'Channel $idx';
  Uint8List? secret;
  if (d.length >= 50) {
    name = _cstr(d, 2, 32);
    secret = d.sublist(34, 50);
  } else if (d.length > 18) {
    name = _cstr(d, 18, 32);
  } else {
    name = 'Channel $idx';
  }
  return MeshChannel(
    index: idx,
    // Unbenannte Slots existieren nicht (nie angelegt/beigetreten) —
    // der Parser erfindet für sie keinen Namen.
    name: name.isEmpty ? (idx == 0 ? 'Public' : '') : name,
    // Kanal 0 ist per Definition öffentlich — Secret ignorieren.
    secret: idx == 0 ? null : secret,
  );
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
  final txtType = d[o];
  o += 1;
  final ts = d.length >= o + 4 ? readU32(d, o) : 0;
  o += 4;
  final text = utf8.decode(d.sublist(o), allowMalformed: true);
  return IncomingPacket(
    kind: IncomingKind.text,
    fromChannel: false,
    senderPrefix: prefix,
    text: text,
    flooded: pathLen != 0xFF,
    hopCount: pathLen == 0xFF ? 0 : pathLen,
    timestamp: ts == 0 ? null : ts,
    snr: snr,
    txtType: txtType,
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
  final ts = d.length >= o + 4 ? readU32(d, o) : 0;
  o += 4;
  final text = utf8.decode(d.sublist(o), allowMalformed: true);
  return IncomingPacket(
    kind: IncomingKind.text,
    fromChannel: true,
    channelIdx: idx,
    text: text,
    flooded: pathLen != 0xFF,
    hopCount: pathLen == 0xFF ? 0 : pathLen,
    timestamp: ts == 0 ? null : ts,
    snr: snr,
  );
}

IncomingPacket _parseChannelData(Uint8List d, {required int meshPixDataType}) {
  if (d.length < 9) {
    return IncomingPacket(kind: IncomingKind.unknown, fromChannel: true);
  }
  final snr = readI8(d[1]) / 4.0;
  final idx = d[4];
  final pathLen = d[5];
  final dataType = readU16(d, 6);
  final len = d[8];
  final payload = d.length >= 9 + len ? d.sublist(9, 9 + len) : d.sublist(9);
  final kind = dataType == meshPixDataType
      ? IncomingKind.meshPix
      : dataType == kMeshPixCatchType
      ? IncomingKind.catchUp
      : IncomingKind.unknown;
  return IncomingPacket(
    kind: kind,
    fromChannel: true,
    channelIdx: idx,
    dataType: dataType,
    payload: payload,
    flooded: pathLen != 0xFF,
    hopCount: pathLen == 0xFF ? 0 : pathLen,
    snr: snr,
  );
}

IncomingPacket _parseRawData(Uint8List d, {required int meshPixDataType}) {
  if (d.length < 4) {
    return IncomingPacket(kind: IncomingKind.unknown, fromChannel: false);
  }
  final snr = readI8(d[1]) / 4.0;
  final rssi = readI8(d[2]);
  final payload = d.sublist(4);
  final looksMp =
      payload.length >= 2 && payload[0] == 0x4D && payload[1] == 0x50;
  final looksCatch = looksLikeCatchUp(payload);
  return IncomingPacket(
    kind: looksCatch
        ? IncomingKind.catchUp
        : looksMp
        ? IncomingKind.meshPix
        : IncomingKind.unknown,
    fromChannel: false,
    dataType: looksCatch
        ? kMeshPixCatchType
        : looksMp
        ? meshPixDataType
        : null,
    payload: payload,
    snr: snr,
    rssi: rssi,
  );
}

RepeaterStatus _parseRepeaterStatusFrame(Uint8List d) {
  if (d.length < 8)
    return const RepeaterStatus(rawSummary: 'Antwort empfangen');
  return parseRepeaterStatus(d.sublist(8));
}

/// `RepeaterStats` from MeshCore simple_repeater (little-endian).
RepeaterStatus parseRepeaterStatus(Uint8List data) {
  if (data.isEmpty) return const RepeaterStatus(rawSummary: 'Status OK');
  if (data.length < 24) {
    if (data.length >= 2) {
      final mv = readU16(data, 0);
      if (mv > 2000 && mv < 5000) {
        return RepeaterStatus(
          milliVolts: mv,
          rawSummary: 'Status · ${(mv / 1000).toStringAsFixed(2)} V',
        );
      }
    }
    return RepeaterStatus(rawSummary: 'Status · ${data.length} Byte');
  }
  return RepeaterStatus(
    milliVolts: readU16(data, 0),
    queueLen: readU16(data, 2),
    noiseFloor: readI16(data, 4),
    lastRssi: readI16(data, 6),
    packetsRecv: data.length >= 12 ? readU32(data, 8) : null,
    packetsSent: data.length >= 16 ? readU32(data, 12) : null,
    airtimeSecs: data.length >= 20 ? readU32(data, 16) : null,
    uptimeSecs: data.length >= 24 ? readU32(data, 20) : null,
    sentFlood: data.length >= 28 ? readU32(data, 24) : null,
    sentDirect: data.length >= 32 ? readU32(data, 28) : null,
    recvFlood: data.length >= 36 ? readU32(data, 32) : null,
    recvDirect: data.length >= 40 ? readU32(data, 36) : null,
    lastSnr: data.length >= 44 ? readI16(data, 42) / 4.0 : null,
  );
}

/// PUSH_CODE_TRACE_DATA (0x89):
/// `[0x89, 0, path_len, flags, tag(4), auth(4), hashes(path_len),
/// snrs(path_len >> (flags&3)), final_snr]`.
TraceResult? _parseTraceFrame(Uint8List d) {
  if (d.length < 13) return null;
  final pathLen = d[2] & 0xFF;
  final flags = d[3] & 0xFF;
  final tag = readU32(d, 4);
  final w = 1 << (flags & 0x03);
  var o = 12;
  final hashes = pathLen > 0 ? d.sublist(o, o + pathLen) : <int>[];
  o += pathLen;
  final n = pathLen == 0 ? 0 : (pathLen / w).round();
  final snrs = n > 0 && d.length >= o + n ? d.sublist(o, o + n) : <int>[];
  o += n;
  int? finalSnr;
  if (d.length > o) finalSnr = d[o] & 0xFF;
  return TraceResult(
    tag: tag,
    flags: flags,
    hashes: hashes,
    snrs: snrs,
    finalSnr: finalSnr,
  );
}
