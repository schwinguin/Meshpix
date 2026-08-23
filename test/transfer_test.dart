import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshpix/codec/limits.dart';
import 'package:meshpix/codec/mp1.dart';
import 'package:meshpix/codec/rgba.dart';
import 'package:meshpix/companion/control.dart';
import 'package:meshpix/transfer/engine.dart';
import 'package:meshpix/transfer/protocol.dart';

class FakeRadio implements PacketRadio {
  FakeRadio();

  final _incoming = StreamController<IncomingPacket>.broadcast();
  final sentDatagrams = <Uint8List>[];
  final sentTexts = <String>[];
  final droppedSeqs = <int>{};

  @override
  Stream<IncomingPacket> get incoming => _incoming.stream;

  @override
  Future<TxReceipt?> sendText({
    required RadioDestination destination,
    required String text,
  }) async {
    sentTexts.add(text);
    return const TxReceipt();
  }

  @override
  Future<void> sendDatagram({
    required RadioDestination destination,
    required int dataType,
    required Uint8List payload,
  }) async {
    sentDatagrams.add(payload);
  }

  void inject(IncomingPacket packet) => _incoming.add(packet);

  Future<void> dispose() => _incoming.close();
}

IncomingPacket meshPix(
  Uint8List payload, {
  bool channel = false,
  Uint8List? from,
}) {
  return IncomingPacket(
    kind: IncomingKind.meshPix,
    fromChannel: channel,
    channelIdx: channel ? 0 : null,
    senderPrefix: from ?? Uint8List.fromList([1, 2, 3, 4, 5, 6]),
    dataType: kMeshPixDataType,
    payload: payload,
  );
}

void main() {
  test('public channel strips upgrade chunks', () async {
    final radio = FakeRadio();
    final engine = TransferEngine(
      radio: radio,
      codec: Mp1Codec(),
      budget: AirtimeBudget(airtimeFactor: 0),
    );
    final encoded = Mp1Codec().encode(
      makeTestCard(64),
      options: const EncodeOptions(includeUpgrade: true, transferId: 1),
    );
    expect(encoded.chunks, isNotEmpty);
    final sent = await engine.sendImage(
      encoded: encoded,
      destination: const RadioDestination.channel(0),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(sent.chunks, isEmpty);
    expect(radio.sentDatagrams.length, 1);
    final parsed =
        Mp1Codec().parse(radio.sentDatagrams.single) as PreviewPacket;
    expect(parsed.image.upgradeChunks, 0);
    await engine.dispose();
    await radio.dispose();
  });

  test('DM preview then pull reassembles chunks, NACK fills holes', () async {
    final aliceRadio = FakeRadio();
    final bobRadio = FakeRadio();
    final codec = Mp1Codec();
    final alice = TransferEngine(
      radio: aliceRadio,
      codec: codec,
      budget: AirtimeBudget(airtimeFactor: 0),
    );
    final bob = TransferEngine(
      radio: bobRadio,
      codec: codec,
      budget: AirtimeBudget(airtimeFactor: 0),
    );

    final bobEvents = <TransferEvent>[];
    bob.events.listen(bobEvents.add);

    final encoded = codec.encode(
      makeTestCard(80),
      options: const EncodeOptions(includeUpgrade: true, transferId: 77),
    );

    // Manually pipe datagrams Alice would send into Bob.
    Future<void> pumpAliceToBob({int? dropSeq}) async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      for (final payload in List<Uint8List>.from(aliceRadio.sentDatagrams)) {
        final parsed = codec.parse(payload);
        if (parsed is ChunkPacket && dropSeq != null && parsed.seq == dropSeq) {
          continue;
        }
        bobRadio.inject(
          meshPix(payload, from: Uint8List.fromList([9, 9, 9, 9, 9, 9])),
        );
      }
      aliceRadio.sentDatagrams.clear();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    await alice.sendImage(
      encoded: encoded,
      destination: RadioDestination.dm(Uint8List.fromList([1, 2, 3, 4, 5, 6])),
    );
    await pumpAliceToBob();
    expect(bobEvents.any((e) => e.image != null), isTrue);
    final preview = bobEvents.firstWhere((e) => e.image != null);
    expect(preview.image!.upgradeChunks, greaterThan(0));

    await bob.requestUpgrade(
      77,
      RadioDestination.dm(Uint8List.fromList([9, 9, 9, 9, 9, 9])),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    // Pull went to bobRadio.sent - need to inject into Alice
    for (final p in List<Uint8List>.from(bobRadio.sentDatagrams)) {
      aliceRadio.inject(
        meshPix(p, from: Uint8List.fromList([1, 2, 3, 4, 5, 6])),
      );
    }
    bobRadio.sentDatagrams.clear();
    await Future<void>.delayed(const Duration(milliseconds: 40));

    await pumpAliceToBob(dropSeq: 1);
    bob.nackMissing(77);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    for (final p in List<Uint8List>.from(bobRadio.sentDatagrams)) {
      aliceRadio.inject(
        meshPix(p, from: Uint8List.fromList([1, 2, 3, 4, 5, 6])),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await pumpAliceToBob();

    expect(
      bobEvents.any((e) => e.message.startsWith('Bild vollständig')),
      isTrue,
    );

    await alice.dispose();
    await bob.dispose();
    await aliceRadio.dispose();
    await bobRadio.dispose();
  });

  test('unknown data_type is ignored', () async {
    final radio = FakeRadio();
    final engine = TransferEngine(
      radio: radio,
      codec: Mp1Codec(),
      budget: AirtimeBudget(airtimeFactor: 0),
    );
    final events = <TransferEvent>[];
    engine.events.listen(events.add);
    radio.inject(
      IncomingPacket(
        kind: IncomingKind.unknown,
        fromChannel: true,
        dataType: 0x1234,
        payload: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(events, isEmpty);
    await engine.dispose();
    await radio.dispose();
  });

  test('text has its own send path', () async {
    final radio = FakeRadio();
    final engine = TransferEngine(
      radio: radio,
      codec: Mp1Codec(),
      budget: AirtimeBudget(airtimeFactor: 0),
    );
    await engine.sendText(const RadioDestination.channel(0), 'Hallo');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(radio.sentTexts, ['Hallo']);
    await engine.dispose();
    await radio.dispose();
  });
}
