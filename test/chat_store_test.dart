import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshpix/codec/mp1.dart';
import 'package:meshpix/codec/palettes.dart';
import 'package:meshpix/models/chat.dart';
import 'package:meshpix/state/chat_store.dart';

Conversation _ch(int idx, String title, {List<ChatMessage> msgs = const []}) {
  final c = Conversation(
    id: 'ble-ch$idx',
    title: title,
    isChannel: true,
    channelIdx: idx,
  );
  c.messages.addAll(msgs);
  return c;
}

Conversation _dm(
  List<int> key,
  String title, {
  bool fav = false,
  List<ChatMessage> msgs = const [],
}) {
  final c = Conversation(
    id: 'ble-dm-${key.map((b) => b.toRadixString(16)).join()}',
    title: title,
    isChannel: false,
    peerKey: Uint8List.fromList(key),
    peerType: 1,
    favourite: fav,
  );
  c.messages.addAll(msgs);
  return c;
}

ChatMessage _text(
  String id,
  String body, {
  bool outgoing = false,
  int? ack,
  int? rtt,
  int? hop,
  double? snr,
  String? sender,
  int? cuId,
  bool cu = false,
  List<ChannelPeerAck>? acks,
}) {
  return ChatMessage(
    id: id,
    kind: ChatKind.text,
    outgoing: outgoing,
    timestamp: DateTime.fromMillisecondsSinceEpoch(
      1755000000000 + id.length * 1000,
    ),
    text: body,
    delivery: outgoing ? DeliveryStatus.delivered : DeliveryStatus.sent,
    ackCode: ack,
    rttMs: rtt,
    hopCount: hop,
    snr: snr,
    senderName: sender,
    catchUpId: cuId,
    catchUp: cu,
    channelAcks: acks,
  );
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('meshpix_store'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('Roundtrip: Texte, Bilder, Ack, Catchup-Data', () async {
    final store = ChatStore(dir: tmp);
    final photo = Uint32List.fromList([0xFF112233, 0xFF445566]);
    final convos = [
      _ch(
        0,
        'Public',
        msgs: [
          _text(
            '1',
            'Hallo',
            outgoing: true,
            ack: 7,
            rtt: 42,
            acks: [
              ChannelPeerAck(
                keyHex: 'aabbcc',
                name: 'Ben',
                state: ChannelPeerState.pending,
              ),
            ],
          ),
          _text(
            '2',
            'Hey',
            sender: 'Anna',
            hop: 2,
            snr: 12.5,
            cuId: 99,
            cu: true,
          ),
        ],
      ),
      _ch(1, 'Werkstatt'),
      _dm(
        [0x01, 0x02, 0x03, 0x04, 0x05, 0x06],
        'Ben',
        fav: true,
        msgs: [
          _text('3', 'Bild-Platzhalter'),
          ChatMessage(
            id: 'img-1',
            kind: ChatKind.image,
            outgoing: false,
            timestamp: DateTime.fromMillisecondsSinceEpoch(1755000003000),
            image: DecodedImage(
              width: 2,
              height: 1,
              palette: mesh4,
              indices: const [0, 3],
              dithered: true,
              upgradeChunks: 4,
            ),
            canPull: true,
          ),
          ChatMessage(
            id: 'img-2',
            kind: ChatKind.image,
            outgoing: true,
            timestamp: DateTime.fromMillisecondsSinceEpoch(1755000004000),
            image: DecodedImage(
              width: 1,
              height: 2,
              palette: const Palette(id: -1, name: 'x', colors: []),
              indices: const [],
              dithered: false,
              upgradeChunks: 0,
              argb: photo,
            ),
          ),
        ],
      ),
    ];

    await store.save(convos, '3C:0F:02:EB:02:F5');
    final loaded = await store.load('3C:0F:02:EB:02:F5');

    expect(loaded.length, 3);

    final ch0 = loaded.firstWhere((c) => c.isChannel && c.channelIdx == 0);
    expect(ch0.title, 'Public');
    expect(ch0.messages.length, 2);
    final t1 = ch0.messages[0];
    expect(t1.text, 'Hallo');
    expect(t1.outgoing, isTrue);
    // Transienter Delivery-Zustand wird nicht übernommen.
    expect(t1.delivery, DeliveryStatus.sent);
    expect(t1.ackCode, 7);
    expect(t1.rttMs, 42);
    expect(t1.channelAcks.length, 1);
    expect(t1.channelAcks[0].state, ChannelPeerState.pending);
    expect(t1.channelAcks[0].keyHex, 'aabbcc');
    final t2 = ch0.messages[1];
    expect(t2.senderName, 'Anna');
    expect(t2.hopCount, 2);
    expect(t2.snr, 12.5);
    expect(t2.catchUpId, 99);
    expect(t2.catchUp, isTrue);

    final ch1 = loaded.firstWhere((c) => c.isChannel && c.channelIdx == 1);
    expect(ch1.messages, isEmpty);

    final dm = loaded.firstWhere((c) => !c.isChannel);
    expect(dm.peerKey, [1, 2, 3, 4, 5, 6]);
    expect(dm.favourite, isTrue);
    expect(dm.peerType, 1);
    final img1 = dm.messages[1].image!;
    expect(img1.width, 2);
    expect(img1.palette.colors[0].argb, mesh4.colors[0].argb);
    expect(img1.indices, [0, 3]);
    expect(img1.dithered, isTrue);
    expect(img1.upgradeChunks, 4);
    expect(dm.messages[1].canPull, isTrue);
    final img2 = dm.messages[2].image!;
    expect(img2.argb, photo);
  });

  test('Leer und defekte Dateien: leere Ergebnisliste', () async {
    final store = ChatStore(dir: tmp);
    expect(await store.load('kein-geraet'), isEmpty);
    final f = Directory('${tmp.path}/chat');
    await f.create(recursive: true);
    await File('${f.path}/kaputt.json').writeAsString('das ist kein json');
    expect(await store.load('kaputt'), isEmpty);
  });

  test('Max. Nachrichten pro Konversation (älteste weg)', () async {
    final store = ChatStore(dir: tmp);
    final many = <ChatMessage>[
      for (var i = 0; i < 500; i++) _text('m$i', 'Nachricht $i'),
    ];
    await store.save([_ch(0, 'Public', msgs: many)], 'node');
    final loaded = await store.load('node');
    final msgs = loaded.single.messages;
    expect(msgs.length, ChatStore.maxMessagesPerConvo);
    expect(msgs.first.text, 'Nachricht 100');
    expect(msgs.last.text, 'Nachricht 499');
  });

  test('Bild-Budget: jüngste behalten, älteste nur als Platzhalter', () async {
    final store = ChatStore(dir: tmp);
    // 96×96-Foto: 36 864 Byte -> 49 152 Base64-Zeichen; 25 Fotos > 1-MB-Budget.
    Uint32List photo() => Uint32List.fromList(List.filled(96 * 96, 0xFF123456));
    final many = <ChatMessage>[
      for (var i = 0; i < 25; i++)
        ChatMessage(
          id: 'p$i',
          kind: ChatKind.image,
          outgoing: false,
          timestamp: DateTime.fromMillisecondsSinceEpoch(1755000000000 + i),
          image: DecodedImage(
            width: 96,
            height: 96,
            palette: const Palette(id: -1, name: 'x', colors: []),
            indices: const [],
            dithered: false,
            upgradeChunks: 0,
            argb: photo(),
          ),
        ),
    ];
    await store.save([_ch(0, 'Public', msgs: many)], 'node');
    final loaded = await store.load('node');
    final msgs = loaded.single.messages;
    expect(msgs.last.image, isNotNull);
    expect(msgs.first.image, isNull);
    final kept = msgs.where((m) => m.image != null).length;
    expect(kept, lessThan(25));
    expect(kept, greaterThan(0));
  });

  test('Anderer Knoten: getrennte Verläufe', () async {
    final store = ChatStore(dir: tmp);
    await store.save([
      _ch(0, 'Public', msgs: [_text('1', 'A')]),
    ], 'node-a');
    await store.save([
      _ch(0, 'Public', msgs: [_text('2', 'B')]),
    ], 'node-b');
    expect((await store.load('node-a')).single.messages.single.text, 'A');
    expect((await store.load('node-b')).single.messages.single.text, 'B');
  });
}
