import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshpix/codec/limits.dart';
import 'package:meshpix/companion/constants.dart';
import 'package:meshpix/companion/frames.dart';
import 'package:meshpix/companion/parser.dart';

void main() {
  test('channel data command stays within datagram budget framing', () {
    final payload = Uint8List.fromList(List<int>.filled(20, 0xAB));
    final frame = cmdSendChannelData(
      channelIdx: 1,
      dataType: kMeshPixDataType,
      payload: payload,
    );
    expect(frame[0], Cmd.sendChannelData);
    expect(frame[1], 1);
    expect(frame[2], 0xFF);
    expect(readU16(frame, 3), kMeshPixDataType);
    expect(frame.sublist(5), payload);
  });

  test('raw data command prefixes path length', () {
    final frame = cmdSendRawData(payload: Uint8List.fromList([1, 2, 3, 4, 5]));
    expect(frame[0], Cmd.sendRawData);
    expect(frame[1], 0);
    expect(frame.sublist(2), [1, 2, 3, 4, 5]);
  });

  test('unknown channel data_type is parsed as unknown', () {
    final frame = Uint8List.fromList([
      Resp.channelDataRecv,
      0, 0, 0,
      0, // ch
      0x05, // flooded path_len
      0x34, 0x12, // data_type 0x1234
      4,
      1, 2, 3, 4,
    ]);
    final parsed = parseCompanionFrame(frame, meshPixDataType: kMeshPixDataType);
    expect(parsed?.incoming?.kind.toString(), contains('unknown'));
  });

  test('meshpix channel datagram is recognized', () {
    final frame = Uint8List.fromList([
      Resp.channelDataRecv,
      8, 0, 0,
      0,
      0xFF,
      kMeshPixDataType & 0xFF,
      (kMeshPixDataType >> 8) & 0xFF,
      2,
      0x4D, 0x50,
    ]);
    final parsed = parseCompanionFrame(frame, meshPixDataType: kMeshPixDataType);
    expect(parsed?.incoming?.kind.toString(), contains('meshPix'));
  });

  test('set channel frame encodes cmd, idx, padded name, secret', () {
    final secret = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));
    final frame = cmdSetChannel(3, 'Wald', secret);
    expect(frame[0], Cmd.setChannel);
    expect(frame[1], 3);
    expect(frame.length, 2 + 32 + 16);
    expect(utf8.decode(frame.sublist(2, 6)), 'Wald');
    expect(frame[6], 0); // null-gepadet
    expect(frame.sublist(34), secret);
  });

  test('channel info without name stays unnamed (empty slot)', () {
    final d = Uint8List(51);
    d[0] = Resp.channelInfo;
    d[1] = 5; // idx
    // Name (Bytes 2..33) leer, Secret (34..49) vorgeneriert.
    d.setRange(34, 50, List<int>.generate(16, (i) => i));
    final parsed = parseCompanionFrame(d, meshPixDataType: kMeshPixDataType);
    expect(parsed?.channel, isNotNull);
    expect(parsed!.channel!.index, 5);
    expect(parsed.channel!.name, '');
    expect(parsed.channel!.secret, isNotNull);
  });
}
