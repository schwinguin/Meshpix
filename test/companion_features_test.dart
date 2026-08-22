import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshpix/codec/limits.dart';
import 'package:meshpix/companion/constants.dart';
import 'package:meshpix/companion/frames.dart';
import 'package:meshpix/companion/parser.dart';
import 'package:meshpix/models/chat.dart';
import 'package:meshpix/models/contact.dart';
import 'package:meshpix/models/device.dart';
import 'package:meshpix/models/uri_card.dart';
import 'package:meshpix/state/app_controller.dart';

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

  test('simulator DM gets delivered ACK like MeshCore One', () async {
    final app = AppController();
    addTearDown(app.dispose);
    app.open(app.sessions['anna']!.conversations.firstWhere((c) => !c.isChannel));
    await app.sendText('ping von Anna');

    final start = DateTime.now();
    ChatMessage msg() => app.sessions['anna']!
        .conversations
        .firstWhere((c) => !c.isChannel)
        .messages
        .last;
    while (msg().delivery != DeliveryStatus.delivered) {
      if (DateTime.now().difference(start) > const Duration(seconds: 2)) {
        fail('ACK kam nicht (status=${msg().delivery})');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(msg().text, 'ping von Anna');
    expect(msg().rttMs, isNotNull);

    final ben = app.sessions['ben']!.conversations.firstWhere((c) => !c.isChannel);
    expect(ben.messages.where((m) => m.text == 'ping von Anna'), isNotEmpty);
  });

  test('advert from Anna appears as contact notice on Ben', () async {
    final app = AppController();
    addTearDown(app.dispose);
    await app.sendAdvert(flood: true);
    expect(app.sessions['ben']!.companion!.contacts.any((c) => c.name == 'Anna'), isTrue);
  });

  test('EU preset matches MeshCore One numbers', () {
    final eu = RadioPreset.all.firstWhere((p) => p.id == 'eu868');
    expect(eu.settings.freqMhz, 869.525);
    expect(eu.settings.spreadingFactor, 11);
    expect(eu.settings.bwKhz, 250);
  });
}
