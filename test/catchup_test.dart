import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshpix/codec/limits.dart';
import 'package:meshpix/models/chat.dart';
import 'package:meshpix/state/app_controller.dart';
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

  test('online channel flood still arrives without catch-up', () async {
    final app = AppController();
    addTearDown(app.dispose);
    app.open(app.sessions['anna']!.conversations.firstWhere((c) => c.isChannel));
    await app.sendText('beide online');

    final start = DateTime.now();
    List<ChatMessage> benMsgs() => app.sessions['ben']!
        .conversations
        .firstWhere((c) => c.isChannel)
        .messages;
    while (benMsgs().every((m) => m.text != 'beide online')) {
      if (DateTime.now().difference(start) > const Duration(seconds: 2)) {
        fail('Flood kam nicht an');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(benMsgs().where((m) => m.catchUp), isEmpty);
    final anna = app.sessions['anna']!
        .conversations
        .firstWhere((c) => c.isChannel)
        .messages
        .last;
    expect(
      anna.channelAcks.where((a) => a.name == 'Ben').first.state,
      ChannelPeerState.live,
    );
    expect(
      app.sessions['anna']!.conversations.firstWhere((c) => !c.isChannel).title,
      'Ben',
    );
  });

  test('off-grid peer misses flood and gets DM catch-up after advert', () async {
    final app = AppController();
    addTearDown(app.dispose);
    app.setSimReachable('ben', false);
    expect(app.isSimReachable('ben'), isFalse);

    app.open(app.sessions['anna']!.conversations.firstWhere((c) => c.isChannel));
    await app.sendText('Hallo Mesh');
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final benPub =
        app.sessions['ben']!.conversations.firstWhere((c) => c.isChannel);
    expect(benPub.messages.where((m) => m.text == 'Hallo Mesh'), isEmpty);

    final annaMsg = app.sessions['anna']!
        .conversations
        .firstWhere((c) => c.isChannel)
        .messages
        .last;
    expect(annaMsg.hasChannelTracking, isTrue);
    expect(
      annaMsg.channelAcks.any(
        (a) => a.name == 'Ben' && a.state == ChannelPeerState.pending,
      ),
      isTrue,
    );

    app.setSimReachable('ben', true);
    final start = DateTime.now();
    bool benHas() => benPub.messages.any((m) => m.text == 'Hallo Mesh');
    ChannelPeerState? benState() {
      final msg = app.sessions['anna']!
          .conversations
          .firstWhere((c) => c.isChannel)
          .messages
          .last;
      return msg.channelAcks
          .where((a) => a.name == 'Ben')
          .map((a) => a.state)
          .firstOrNull;
    }

    while (!benHas() ||
        (benState() != ChannelPeerState.delivered &&
            benState() != ChannelPeerState.replayed)) {
      if (DateTime.now().difference(start) > const Duration(seconds: 4)) {
        fail(
          'Catch-up kam nicht (benHas=${benHas()} state=${benState()})',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }

    expect(benHas(), isTrue);
    expect(benPub.messages.where((m) => m.text == 'Hallo Mesh').first.catchUp, isTrue);
    expect(
      benState() == ChannelPeerState.delivered ||
          benState() == ChannelPeerState.replayed,
      isTrue,
    );
    expect(
      app.sessions['ben']!.conversations
          .firstWhere((c) => !c.isChannel)
          .messages
          .where((m) => m.text == 'Hallo Mesh'),
      isEmpty,
      reason: 'Catch-up gehört in den Channel, nicht in den DM',
    );
  });
}
