import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../codec/limits.dart';
import '../companion/control.dart';
import '../models/channel.dart';
import '../models/contact.dart';
import '../models/device.dart';
import '../transfer/protocol.dart';

class SimIdentity {
  SimIdentity({required this.id, required this.name, required this.publicKey});
  final String id;
  String name;
  final Uint8List publicKey;
}

class SimMesh {
  final _radios = <String, SimRadio>{};

  void attach(SimRadio radio) => _radios[radio.identity.id] = radio;

  void detach(String id) => _radios.remove(id);

  void deliver({
    required String fromId,
    required IncomingPacket packet,
    String? toId,
  }) {
    for (final radio in _radios.values) {
      if (radio.identity.id == fromId) continue;
      if (toId != null && radio.identity.id != toId) continue;
      radio._emit(packet);
    }
  }

  void floodAdvert(SimRadio from) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    for (final radio in _radios.values) {
      if (radio.identity.id == from.identity.id) continue;
      radio._hearAdvert(
        MeshContact(
          publicKey: from.identity.publicKey,
          name: from.identity.name,
          type: AdvType.chat,
          lastAdvert: now,
          outPath: Uint8List.fromList([0x01]),
        ),
      );
    }
  }
}

class SimRadio implements PacketRadio, CompanionControl {
  SimRadio({
    required this.mesh,
    required this.identity,
    RadioSettings? radio,
    BatteryInfo? battery,
  })  : radio = radio ?? RadioPreset.all.first.settings,
        battery = battery ?? const BatteryInfo(milliVolts: 3920) {
    mesh.attach(this);
    firmware = const FirmwareInfo(
      firmwareVer: 8,
      semanticVersion: 'sim',
      model: 'MeshPix Simulator',
      maxContacts: 32,
      maxChannels: 8,
    );
    contacts.addAll(
      mesh._radios.values
          .where((r) => r.identity.id != identity.id)
          .map(_contactFor),
    );
    channels.add(MeshChannel(index: 0, name: 'Public'));
  }

  final SimMesh mesh;
  final SimIdentity identity;
  @override
  final contacts = <MeshContact>[];
  @override
  final channels = <MeshChannel>[];
  @override
  RadioSettings radio;
  @override
  BatteryInfo? battery;
  @override
  FirmwareInfo? firmware;

  final _incoming = StreamController<IncomingPacket>.broadcast();
  final _notices = StreamController<CompanionNotice>.broadcast();
  final _rng = Random();

  @override
  Stream<IncomingPacket> get incoming => _incoming.stream;

  @override
  Stream<CompanionNotice> get notices => _notices.stream;

  @override
  DeviceSelf get self => DeviceSelf(
        name: identity.name,
        publicKey: identity.publicKey,
        radio: radio,
        txPower: radio.txPowerDbm,
      );

  void loadPeers() {
    contacts
      ..clear()
      ..addAll(
        mesh._radios.values
            .where((r) => r.identity.id != identity.id)
            .map(_contactFor),
      );
  }

  MeshContact _contactFor(SimRadio r) {
    final existing = contacts.cast<MeshContact?>().firstWhere(
          (c) => c != null && _prefixEq(
            Uint8List.fromList(c.publicKey),
            r.identity.publicKey,
          ),
          orElse: () => null,
        );
    return MeshContact(
      publicKey: r.identity.publicKey,
      name: r.identity.name,
      type: AdvType.chat,
      flags: existing?.flags ?? 0,
      outPath: existing?.outPath ?? Uint8List.fromList([0x01]),
      lastAdvert: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
  }

  @override
  Future<TxReceipt?> sendText({
    required RadioDestination destination,
    required String text,
  }) async {
    final packet = IncomingPacket(
      kind: IncomingKind.text,
      fromChannel: destination.isPublicChannel,
      channelIdx: destination.channelIdx,
      senderPrefix: identity.publicKey.sublist(0, 6),
      text: text,
      flooded: destination.isPublicChannel,
      hopCount: destination.isPublicChannel ? 1 : 0,
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      snr: 6.5,
    );
    _route(destination, packet);
    final ack = destination.isPublicChannel ? null : _rng.nextInt(0x7fffffff);
    if (ack != null) {
      Future<void>.delayed(const Duration(milliseconds: 40), () {
        if (!_notices.isClosed) {
          _notices.add(CompanionNotice.ack(ackCode: ack, rttMs: 40));
        }
      });
    }
    return TxReceipt(
      expectedAck: ack,
      flooded: destination.isPublicChannel,
      timeoutMs: 4000,
    );
  }

  @override
  Future<void> sendDatagram({
    required RadioDestination destination,
    required int dataType,
    required Uint8List payload,
  }) async {
    final kind = dataType == kMeshPixDataType
        ? IncomingKind.meshPix
        : IncomingKind.unknown;
    final packet = IncomingPacket(
      kind: kind,
      fromChannel: destination.isPublicChannel,
      channelIdx: destination.channelIdx,
      senderPrefix: identity.publicKey.sublist(0, 6),
      dataType: dataType,
      payload: payload,
      flooded: destination.isPublicChannel,
      hopCount: destination.isPublicChannel ? 1 : 0,
    );
    _route(destination, packet);
  }

  void _route(RadioDestination destination, IncomingPacket packet) {
    String? toId;
    if (!destination.isPublicChannel && destination.pubkeyPrefix != null) {
      for (final r in mesh._radios.values) {
        final pre = r.identity.publicKey.sublist(0, 6);
        if (_prefixEq(pre, destination.pubkeyPrefix!)) {
          toId = r.identity.id;
          break;
        }
      }
    }
    mesh.deliver(fromId: identity.id, packet: packet, toId: toId);
  }

  void _emit(IncomingPacket packet) {
    if (!_incoming.isClosed) _incoming.add(packet);
  }

  void _hearAdvert(MeshContact contact) {
    final idx = contacts.indexWhere(
      (c) => _prefixEq(Uint8List.fromList(c.publicKey), Uint8List.fromList(contact.publicKey)),
    );
    if (idx >= 0) {
      contacts[idx] = contact.copyWith(flags: contacts[idx].flags);
    } else {
      contacts.add(contact);
    }
    if (!_notices.isClosed) {
      _notices.add(CompanionNotice.advert(contact));
    }
  }

  @override
  Future<void> sendSelfAdvert({bool flood = false}) async {
    mesh.floodAdvert(this);
  }

  @override
  Future<void> setAdvertName(String name) async {
    identity.name = name;
  }

  @override
  Future<void> applyRadio(RadioSettings settings) async {
    radio = settings;
  }

  @override
  Future<BatteryInfo?> refreshBattery() async => battery;

  @override
  Future<void> setFavourite(MeshContact contact, bool favourite) async {
    final flags = favourite
        ? (contact.flags | ContactFlags.favourite)
        : (contact.flags & ~ContactFlags.favourite);
    await addOrUpdateContact(contact.copyWith(flags: flags));
  }

  @override
  Future<void> addOrUpdateContact(MeshContact contact) async {
    contacts.removeWhere(
      (c) => _prefixEq(Uint8List.fromList(c.publicKey), Uint8List.fromList(contact.publicKey)),
    );
    contacts.add(contact);
  }

  @override
  Future<void> removeContact(MeshContact contact) async {
    contacts.removeWhere(
      (c) => _prefixEq(Uint8List.fromList(c.publicKey), Uint8List.fromList(contact.publicKey)),
    );
  }

  @override
  Future<void> ping(MeshContact contact) async {
    _notices.add(
      CompanionNotice.status(
        prefix: contact.publicKey.take(6).toList(),
        statusSummary: 'Ping OK · ${12 + _rng.nextInt(30)} ms · ${contact.hopCount} Hop',
      ),
    );
  }

  @override
  Future<void> shareContactZeroHop(MeshContact contact) async {
    mesh.floodAdvert(this);
  }

  @override
  Future<void> resetPath(MeshContact contact) async {
    await addOrUpdateContact(contact.copyWith(outPath: Uint8List(0)));
  }

  @override
  Future<void> refreshContacts() async {
    loadPeers();
  }

  Future<void> dispose() async {
    mesh.detach(identity.id);
    await _incoming.close();
    await _notices.close();
  }
}

bool _prefixEq(Uint8List a, Uint8List b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Uint8List keyFromSeed(int seed) {
  return Uint8List.fromList(List<int>.generate(32, (i) => (seed * 17 + i * 13) & 0xFF));
}
