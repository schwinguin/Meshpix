import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshpix/codec/limits.dart';
import 'package:meshpix/companion/constants.dart';
import 'package:meshpix/companion/frames.dart';
import 'package:meshpix/companion/parser.dart';
import 'package:meshpix/models/contact.dart';
import 'package:meshpix/models/device.dart';
import 'package:meshpix/models/repeater.dart';
import 'package:meshpix/models/uri_card.dart';
import 'package:meshpix/state/app_controller.dart';

import 'fake_companion.dart';

void main() {
  test('meshcore:// contact URI round-trips like MeshCore One', () {
    final key = List<int>.generate(32, (i) => i + 1);
    final uri = MeshCoreUri.contact(name: 'Anna Funk', publicKey: key, type: AdvType.repeater);
    expect(uri, startsWith('meshcore://'));
    final parsed = MeshCoreUri.parseContact(uri);
    expect(parsed, isNotNull);
    expect(parsed!.name, 'Anna Funk');
    expect(parsed.type, AdvType.repeater);
    expect(parsed.publicKey, key);
  });

  test('self-info and contact frames parse radio + last heard', () {
    final key = Uint8List.fromList(List<int>.generate(32, (i) => 0xA0 + (i % 16)));
    final self = BytesBuilder()
      ..addByte(Resp.selfInfo)
      ..addByte(AdvType.chat)
      ..addByte(22) // tx
      ..addByte(22) // max tx
      ..add(key)
      ..add(Uint8List(4)) // lat
      ..add(Uint8List(4)) // lon
      ..addByte(0)
      ..addByte(0)
      ..addByte(0)
      ..addByte(0)
      ..add([869525 & 0xFF, (869525 >> 8) & 0xFF, (869525 >> 16) & 0xFF, 0])
      ..add([250000 & 0xFF, (250000 >> 8) & 0xFF, (250000 >> 16) & 0xFF, 0])
      ..addByte(11)
      ..addByte(5)
      ..add('Heltec'.codeUnits);
    final parsed = parseCompanionFrame(self.takeBytes(), meshPixDataType: kMeshPixDataType);
    expect(parsed?.self?.name, 'Heltec');
    expect(parsed?.self?.radio?.spreadingFactor, 11);
    expect(parsed?.self?.radio?.freqMhz, closeTo(869.525, 0.001));

    final contact = BytesBuilder()
      ..addByte(Resp.contact)
      ..add(key)
      ..addByte(AdvType.repeater)
      ..addByte(ContactFlags.favourite)
      ..addByte(2) // path len
      ..add(Uint8List(64)
        ..[0] = 0x11
        ..[1] = 0x22)
      ..add(Uint8List(32)..setAll(0, 'Relay1'.codeUnits))
      ..add([0x64, 0x00, 0x00, 0x00]) // last advert
      ..add(Uint8List(4))
      ..add(Uint8List(4))
      ..add([0x65, 0x00, 0x00, 0x00]);
    final c = parseCompanionFrame(contact.takeBytes(), meshPixDataType: kMeshPixDataType)?.contact;
    expect(c?.name, 'Relay1');
    expect(c?.type, AdvType.repeater);
    expect(c?.isFavourite, isTrue);
    expect(c?.hopCount, 2);
    expect(c?.lastAdvert, 0x64);
  });

  test('ACK and battery frames', () {
    final ack = Uint8List.fromList([
      Resp.sendConfirmed,
      0x11, 0x22, 0x33, 0x44,
      0x2C, 0x01, 0x00, 0x00, // 300 ms
    ]);
    final p = parseCompanionFrame(ack, meshPixDataType: kMeshPixDataType);
    expect(p?.ackCode, 0x44332211);
    expect(p?.rttMs, 300);

    final batt = Uint8List.fromList([
      Resp.battAndStorage,
      0x4C, 0x0F, // 3916 mV
    ]);
    final b = parseCompanionFrame(batt, meshPixDataType: kMeshPixDataType)?.battery;
    expect(b?.milliVolts, 3916);
    expect(b?.percent, inInclusiveRange(1, 100));
  });

  test('radio param command encoding', () {
    const s = RadioSettings(
      freqMhz: 869.525,
      bwKhz: 250,
      spreadingFactor: 11,
      codingRate: 5,
      txPowerDbm: 22,
    );
    final frame = cmdSetRadioParams(s);
    expect(frame[0], Cmd.setRadioParams);
    expect(readU32(frame, 1), 869525);
    expect(readU32(frame, 5), 250000);
    expect(frame[9], 11);
    expect(frame[10], 5);
  });

  test('EU preset matches MeshCore One numbers', () {
    final eu = RadioPreset.all.firstWhere((p) => p.id == 'eu868');
    expect(eu.settings.freqMhz, 869.525);
    expect(eu.settings.spreadingFactor, 11);
    expect(eu.settings.bwKhz, 250);
  });

  test('repeater status blob matches RepeaterStats layout', () {
    final data = Uint8List(48);
    data[0] = 0xB8;
    data[1] = 0x0F; // 4024 mV
    data[2] = 3;
    data[3] = 0; // queue
    data[4] = 0x9E;
    data[5] = 0xFF; // noise -98
    data[6] = 0xA6;
    data[7] = 0xFF; // rssi -90
    final recv = 1280;
    data[8] = recv & 0xFF;
    data[9] = (recv >> 8) & 0xFF;
    data[20] = 0x10;
    data[21] = 0x0E;
    data[22] = 0;
    data[23] = 0; // uptime 3600
    data[42] = 26;
    data[43] = 0; // snr 6.5
    final s = parseRepeaterStatus(data);
    expect(s.milliVolts, 4024);
    expect(s.queueLen, 3);
    expect(s.noiseFloor, -98);
    expect(s.lastRssi, -90);
    expect(s.packetsRecv, 1280);
    expect(s.uptimeSecs, 3600);
    expect(s.lastSnr, closeTo(6.5, 0.01));
  });

  test('neighbors CLI lines parse like MeshCore One', () {
    final list = parseNeighborsReply('a1b2c3:1710000000:24\nd4e5f6:1710000100:10\n');
    expect(list, hasLength(2));
    expect(list.first.prefixHex, 'a1b2c3');
    expect(list.first.snr, 6.0);
    expect(isDangerCli('reboot'), isTrue);
    expect(isDangerCli('get reboot.interval'), isFalse);
  });

  test('login + CLI stay out of the chat log', () async {
    final fake = FakeCompanion(
      contacts: [
        MeshContact(
          publicKey: List<int>.generate(32, (i) => i + 1),
          name: 'Relay1',
          type: AdvType.repeater,
        ),
      ],
    );
    final app = AppController();
    addTearDown(app.dispose);
    app.attachSession(testSession(fake));
    final relay = app.contacts.firstWhere((c) => c.name == 'Relay1');
    expect(relay.type, AdvType.repeater);

    await app.loginRepeater(relay, 'wrong');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(app.repeaterSession(relay).loggedIn, isFalse);

    await app.loginRepeater(relay, 'password');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(app.repeaterSession(relay).loggedIn, isTrue);
    expect(app.repeaterSession(relay).isAdmin, isTrue);

    await app.sendCli(relay, 'ver');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    final session = app.repeaterSession(relay);
    expect(session.transcript.any((l) => l.text.contains('v1.8.0')), isTrue);

    await app.sendCli(relay, 'neighbors');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(session.neighbors, isNotEmpty);

    expect(
      app.session!.conversations.any((c) => c.title == 'Relay1'),
      isFalse,
      reason: 'CLI darf nicht in den Chat',
    );
  });

  test('login and CLI frames encode', () {
    final key = List<int>.generate(32, (i) => i);
    final login = cmdSendLogin(publicKey: key, password: 'password');
    expect(login[0], Cmd.sendLogin);
    expect(login.sublist(1, 33), key);
    expect(String.fromCharCodes(login.sublist(33)), 'password');

    final cli = cmdSendTxtMsg(
      pubkeyPrefix: Uint8List.fromList(key.take(6).toList()),
      text: 'ver',
      txtType: TxtType.cli,
    );
    expect(cli[1], TxtType.cli);

    final ok = parseCompanionFrame(
      Uint8List.fromList([Resp.loginSuccess, 1, ...key.take(6)]),
      meshPixDataType: kMeshPixDataType,
    );
    expect(ok?.loginOk, isTrue);
    expect(ok?.isAdmin, isTrue);
  });

  test('channel creation uses first free slot and appears in chats', () async {
    final fake = FakeCompanion();
    final app = AppController();
    addTearDown(app.dispose);
    app.attachSession(testSession(fake));
    expect(app.session!.companion!.channels, hasLength(1)); // nur Public

    await app.createChannel('Wald');
    final ch = fake.channels.firstWhere((c) => c.name == 'Wald');
    expect(ch.index, 1);
    expect(ch.secret, hasLength(16));
    expect(
      app.session!.conversations.any((c) => c.isChannel && c.channelIdx == 1),
      isTrue,
    );

    await app.createChannel('Tal');
    expect(fake.channels.firstWhere((c) => c.name == 'Tal').index, 2);
  });

  test('createChannel refuses when all private slots are used', () async {
    final fake = FakeCompanion();
    for (var i = 1; i <= 7; i++) {
      await fake.setChannel(i, 'K$i', Uint8List(16));
    }
    final app = AppController();
    addTearDown(app.dispose);
    app.attachSession(testSession(fake));
    await app.createChannel('Noch einer');
    expect(app.error, contains('Kein freier Kanalslot'));
    expect(fake.channels.any((c) => c.name == 'Noch einer'), isFalse);
  });
}
