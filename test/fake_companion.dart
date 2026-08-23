import 'dart:async';
import 'dart:typed_data';

import 'package:meshpix/codec/mp1.dart';
import 'package:meshpix/companion/control.dart';
import 'package:meshpix/models/channel.dart';
import 'package:meshpix/models/chat.dart';
import 'package:meshpix/models/contact.dart';
import 'package:meshpix/models/device.dart';
import 'package:meshpix/state/app_controller.dart';
import 'package:meshpix/transfer/engine.dart';
import 'package:meshpix/transfer/protocol.dart';

/// CompanionControl + PacketRadio für Controller-Tests ohne BLE.
///
/// Reagiert wie ein echtes Gerät: Login nur mit dem korrekten Passwort,
/// CLI-Antworten auf `ver`/`neighbors`, Kanäle über setChannel.
class FakeCompanion implements PacketRadio, CompanionControl {
  FakeCompanion({
    List<MeshContact>? contacts,
    List<MeshChannel>? channels,
  })  : contacts = contacts ?? <MeshContact>[],
        channels = channels ?? [
          MeshChannel(index: 0, name: 'Public'),
        ];

  final _incoming = StreamController<IncomingPacket>.broadcast();
  final _notices = StreamController<CompanionNotice>.broadcast();

  @override
  final List<MeshContact> contacts;
  @override
  final List<MeshChannel> channels;

  @override
  DeviceSelf? self;

  @override
  Stream<IncomingPacket> get incoming => _incoming.stream;

  @override
  Stream<CompanionNotice> get notices => _notices.stream;

  void emit(CompanionNotice n) => _notices.add(n);

  void emitPacket(IncomingPacket p) => _incoming.add(p);

  @override
  Future<TxReceipt?> sendText({
    required RadioDestination destination,
    required String text,
  }) async =>
      const TxReceipt(flooded: true);

  @override
  Future<void> sendDatagram({
    required RadioDestination destination,
    required int dataType,
    required Uint8List payload,
  }) async {}

  Uint8List prefixOf(MeshContact contact) =>
      Uint8List.fromList(contact.publicKey.take(6).toList());

  @override
  Future<void> loginRepeater(MeshContact contact, String password) async {
    final prefix = prefixOf(contact);
    if (password == 'password') {
      emit(
        CompanionNotice.login(
          prefix: prefix,
          ok: true,
          isAdmin: true,
          permissions: 3,
        ),
      );
    } else {
      emit(CompanionNotice.login(prefix: prefix, ok: false));
    }
  }

  @override
  Future<void> sendCli(MeshContact contact, String command) async {
    final prefix = prefixOf(contact);
    final reply = switch (command) {
      'ver' => 'MeshCore v1.8.0 (build 42)',
      'neighbors' => 'a1b2c3:1710000000:44\ndeef00:1710000005:36',
      _ => '',
    };
    emit(CompanionNotice.cli(prefix: prefix, cliText: reply));
  }

  // -- No-Op-Reste des Interfaces ------------------------------------

  @override
  RadioSettings? get radio => null;

  @override
  BatteryInfo? get battery => null;

  @override
  FirmwareInfo? get firmware => null;

  @override
  Future<void> sendSelfAdvert({bool flood = false}) async {}

  @override
  Future<void> setAdvertName(String name) async {}

  @override
  Future<void> applyRadio(RadioSettings settings) async {}

  @override
  Future<BatteryInfo?> refreshBattery() async => null;

  @override
  Future<void> setFavourite(MeshContact contact, bool favourite) async {}

  @override
  Future<void> removeContact(MeshContact contact) async {}

  @override
  Future<void> addOrUpdateContact(MeshContact contact) async {}

  @override
  Future<void> ping(MeshContact contact) async {}

  @override
  Future<void> shareContactZeroHop(MeshContact contact) async {}

  @override
  Future<void> resetPath(MeshContact contact) async {}

  @override
  Future<void> refreshContacts() async {}

  @override
  Future<void> logoutRepeater(MeshContact contact) async {}

  @override
  Future<void> requestStatus(MeshContact contact) async {}

  @override
  Future<void> requestTelemetry(MeshContact contact) async {}

  @override
  Future<void> tracePath(MeshContact contact, {int? tag, int? flags}) async {}

  @override
  Future<void> setChannel(int idx, String name, Uint8List secret) async {
    if (name.isEmpty) {
      channels.removeWhere((c) => c.index == idx);
      return;
    }
    final i = channels.indexWhere((c) => c.index == idx);
    final ch = MeshChannel(index: idx, name: name, secret: List<int>.from(secret));
    if (i >= 0) {
      channels[i] = ch;
    } else {
      channels.add(ch);
    }
  }

  @override
  Future<void> deleteChannel(int idx) async {
    channels.removeWhere((c) => c.index == idx);
  }

  @override
  Future<void> factoryReset() async {}

  Future<void> dispose() async {
    await _incoming.close();
    await _notices.close();
  }
}

/// Baut eine NodeSession wie connectBle sie auf, aber mit Fake-Radio.
NodeSession testSession(FakeCompanion fake, {List<Conversation>? conversations}) {
  final engine = TransferEngine(
    radio: fake,
    codec: Mp1Codec(),
    budget: AirtimeBudget(),
  );
  return NodeSession(
    id: 'test',
    name: 'TestNode',
    radio: fake,
    engine: engine,
    conversations: conversations ??
        [
          Conversation(
            id: 'test-ch0',
            title: 'Public',
            isChannel: true,
            channelIdx: 0,
          ),
        ],
  );
}
