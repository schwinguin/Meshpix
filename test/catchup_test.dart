import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshpix/codec/limits.dart';
import 'package:meshpix/transfer/catchup.dart';

void main() {
  test('catch-up packet encode/decode round-trips', () {
    final pkt = CatchUpPacket(
      kind: CatchKind.text,
      channelIdx: 0,
      msgId: 0x1234ABCD,
      timestamp: 1710000000,
      senderPrefix: Uint8List.fromList([1, 2, 3, 4, 5, 6]),
      text: 'Hallo Mesh',
    );
    final bytes = encodeCatchUp(pkt);
    expect(looksLikeCatchUp(bytes), isTrue);
    expect(bytes[0], 0x4D);
    expect(bytes[1], 0x43);
    final back = decodeCatchUp(bytes);
    expect(back, isNotNull);
    expect(back!.kind, CatchKind.text);
    expect(back.channelIdx, 0);
    expect(back.msgId, 0x1234ABCD);
    expect(back.timestamp, 1710000000);
    expect(back.senderPrefix, [1, 2, 3, 4, 5, 6]);
    expect(back.text, 'Hallo Mesh');
    expect(kMeshPixCatchType, 0xFF51);
  });

  test('receipt and sync_req kinds survive the wire', () {
    final receipt = decodeCatchUp(
      encodeCatchUp(
        CatchUpPacket(
          kind: CatchKind.receipt,
          channelIdx: 0,
          msgId: 99,
          timestamp: 10,
          senderPrefix: Uint8List(6),
        ),
      ),
    );
    expect(receipt!.isReceipt, isTrue);
    expect(receipt.msgId, 99);

    final sync = decodeCatchUp(
      encodeCatchUp(
        CatchUpPacket(
          kind: CatchKind.syncReq,
          channelIdx: 0,
          msgId: 0,
          timestamp: 11,
          senderPrefix: Uint8List(6),
        ),
      ),
    );
    expect(sync!.isSyncReq, isTrue);
  });
}
