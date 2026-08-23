import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshpix/models/chat.dart';
import 'package:meshpix/models/channel.dart';
import 'package:meshpix/models/contact.dart';
import 'package:meshpix/models/uri_card.dart';
import 'package:meshpix/state/app_controller.dart';
import 'package:meshpix/transfer/protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_companion.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  MeshContact contact(String name, int seed) => MeshContact(
    name: name,
    publicKey: List<int>.generate(32, (i) => (seed * 7 + i) & 0xFF),
  );

  test('deleteChannel frees the slot and clears mute state', () async {
    final fake = FakeCompanion();
    final app = AppController();
    addTearDown(app.dispose);
    app.attachSession(testSession(fake));
    await app.createChannel('Wald');
    expect(fake.channels.firstWhere((c) => c.name == 'Wald').index, 1);

    app.toggleMutedChannel('Wald');
    expect(app.mutedChannels, contains('Wald'));

    await app.deleteChannel(1);
    expect(fake.channels.any((c) => c.name == 'Wald'), isFalse);
    expect(
      app.session!.conversations.any((c) => c.isChannel && c.channelIdx == 1),
      isFalse,
    );
    expect(app.mutedChannels, isEmpty);

    // Der freigewordene Slot wird wieder vergeben.
    await app.createChannel('Tal');
    expect(fake.channels.firstWhere((c) => c.name == 'Tal').index, 1);
  });

  test('block and mute sets persist via LocalPrefs', () async {
    final app = AppController();
    addTearDown(app.dispose);
    app.toggleBlockedContact('aabb');
    app.toggleMutedContact('ccdd');
    app.toggleMutedChannel('Public');
    // Unawaited-Save absetzen lassen.
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final fresh = AppController();
    addTearDown(fresh.dispose);
    await fresh.init();
    expect(fresh.blockedContacts, contains('aabb'));
    expect(fresh.mutedContacts, contains('ccdd'));
    expect(fresh.mutedChannels, contains('Public'));

    app.toggleBlockedContact('aabb');
    expect(app.blockedContacts, isEmpty);
  });

  test('blocked sender is dropped, others still land', () async {
    final anna = contact('Anna', 1);
    final ben = contact('Ben', 2);
    final fake = FakeCompanion(
      contacts: [anna, ben],
      channels: [MeshChannel(index: 0, name: 'Public')],
    );
    final app = AppController();
    addTearDown(app.dispose);
    app.attachSession(
      testSession(
        fake,
        conversations: [
          Conversation(
            id: 'ch0',
            title: 'Public',
            isChannel: true,
            channelIdx: 0,
          ),
          Conversation(
            id: 'anna',
            title: 'Anna',
            isChannel: false,
            peerKey: Uint8List.fromList(anna.publicKey),
            peerType: AdvType.chat,
          ),
          Conversation(
            id: 'ben',
            title: 'Ben',
            isChannel: false,
            peerKey: Uint8List.fromList(ben.publicKey),
            peerType: AdvType.chat,
          ),
        ],
      ),
    );

    app.toggleBlockedContact(anna.keyHex);
    fake.emitPacket(
      IncomingPacket(
        kind: IncomingKind.text,
        fromChannel: false,
        senderPrefix: Uint8List.fromList(anna.publicKey.take(6).toList()),
        text: 'Hallo Block',
        timestamp: 1,
      ),
    );
    fake.emitPacket(
      IncomingPacket(
        kind: IncomingKind.text,
        fromChannel: false,
        senderPrefix: Uint8List.fromList(ben.publicKey.take(6).toList()),
        text: 'Hallo Ben',
        timestamp: 2,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final annaConv = app.session!.conversations.firstWhere(
      (c) => c.title == 'Anna',
    );
    final benConv = app.session!.conversations.firstWhere(
      (c) => c.title == 'Ben',
    );
    expect(annaConv.messages, isEmpty);
    expect(benConv.messages, hasLength(1));
    expect(benConv.messages.first.text, 'Hallo Ben');
  });

  test('DM from contact without convo creates named conversation', () async {
    final anna = contact('Anna', 3);
    final fake = FakeCompanion(
      contacts: [anna],
      channels: [MeshChannel(index: 0, name: 'Public')],
    );
    final app = AppController();
    addTearDown(app.dispose);
    app.attachSession(testSession(fake));
    fake.emitPacket(
      IncomingPacket(
        kind: IncomingKind.text,
        fromChannel: false,
        senderPrefix: Uint8List.fromList(anna.publicKey.take(6).toList()),
        text: 'Hi Anna-DM',
        timestamp: 100,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final dm = app.session!.conversations.where((c) => !c.isChannel).toList();
    expect(dm, hasLength(1));
    expect(dm.first.title, 'Anna');
    expect(dm.first.messages, hasLength(1));
    expect(dm.first.messages.first.text, 'Hi Anna-DM');
    final pub = app.session!.conversations.firstWhere((c) => c.isChannel);
    expect(pub.messages, isEmpty);
  });

  test('DM from unknown sender lands in prefix placeholder convo', () async {
    final fake = FakeCompanion(
      channels: [MeshChannel(index: 0, name: 'Public')],
    );
    final app = AppController();
    addTearDown(app.dispose);
    app.attachSession(testSession(fake));
    final prefix = [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01];
    fake.emitPacket(
      IncomingPacket(
        kind: IncomingKind.text,
        fromChannel: false,
        senderPrefix: Uint8List.fromList(prefix),
        text: 'Wen bin ich?',
        timestamp: 101,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final dm = app.session!.conversations.where((c) => !c.isChannel).toList();
    expect(dm, hasLength(1));
    expect(dm.first.title, 'deadbeef0001');
    expect(dm.first.messages.first.text, 'Wen bin ich?');
  });

  test('meshcore:// deep link imports contact when connected', () async {
    final fake = FakeCompanion(
      channels: [MeshChannel(index: 0, name: 'Public')],
    );
    final app = AppController();
    addTearDown(app.dispose);
    app.attachSession(testSession(fake));

    final key = List<int>.generate(32, (i) => (0x40 + i * 3) & 0xFF);
    final uri = MeshCoreUri.contact(name: 'Tiefenlink', publicKey: key);
    await app.handleContactUri(uri);

    final dm = app.session!.conversations
        .where((c) => !c.isChannel && c.title == 'Tiefenlink')
        .toList();
    expect(dm, hasLength(1));
    expect(app.status, 'Tiefenlink importiert');
  });

  test(
    'deep link before connection is buffered and applied on connect',
    () async {
      final app = AppController();
      addTearDown(app.dispose);
      // Noch keine Session (BLE nicht verbunden).
      final key = List<int>.generate(32, (i) => (0x70 + i) & 0xFF);
      final uri = MeshCoreUri.contact(name: 'Wartend', publicKey: key);
      await app.handleContactUri(uri);
      // Wird gepuffert, nicht importiert.
      expect(app.session, isNull);

      // Jetzt verbunden — Puffer muss freigegeben werden.
      final fake = FakeCompanion(
        channels: [MeshChannel(index: 0, name: 'Public')],
      );
      app.attachSession(testSession(fake));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final dm = app.session!.conversations
          .where((c) => !c.isChannel && c.title == 'Wartend')
          .toList();
      expect(dm, hasLength(1));
      expect(app.status, 'Wartend importiert');
    },
  );
}
