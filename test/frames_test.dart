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
}
