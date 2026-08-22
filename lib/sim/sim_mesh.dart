import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../codec/limits.dart';
import '../companion/control.dart';
import '../models/channel.dart';
import '../models/contact.dart';
import '../models/device.dart';
import '../models/repeater.dart';
import '../transfer/protocol.dart';

class SimIdentity {
  SimIdentity({required this.id, required this.name, required this.publicKey});
  final String id;
  String name;
  final Uint8List publicKey;
}

class SimVirtualRepeater {
  SimVirtualRepeater({
    required this.contact,
    this.password = 'password',
  }) : name = contact.name;

  final MeshContact contact;
  String password;
  String name;
  final acl = <String, int>{};
  int uptimeSecs = 4 * 3600 + 13 * 60;
  int milliVolts = 4012;
  final neighbors = <RepeaterNeighbor>[
    RepeaterNeighbor(
      prefixHex: 'a1b2c3',
      heard: DateTime.now().subtract(const Duration(minutes: 2)),
      snr: 7.5,
    ),
    RepeaterNeighbor(
      prefixHex: 'd4e5f6',
      heard: DateTime.now().subtract(const Duration(minutes: 11)),
      snr: 3.25,
    ),
  ];

  bool isAuthed(String radioId) => acl.containsKey(radioId);
}

class SimMesh {
  final _radios = <String, SimRadio>{};
  SimVirtualRepeater? repeater;

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
    final extras = contacts.where((c) => !c.isChat).toList();
    contacts
      ..clear()
      ..addAll(
        mesh._radios.values
            .where((r) => r.identity.id != identity.id)
            .map(_contactFor),
      )
      ..addAll(extras);
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
  Future<void> ping(MeshContact contact) => requestStatus(contact);

  @override
  Future<void> requestStatus(MeshContact contact) async {
    final status = RepeaterStatus(
      milliVolts: mesh.repeater?.milliVolts ?? 3920,
      queueLen: 1,
      noiseFloor: -98,
      lastRssi: -91,
      packetsRecv: 1280,
      packetsSent: 940,
      airtimeSecs: 180,
      uptimeSecs: mesh.repeater?.uptimeSecs ?? 3600,
      sentFlood: 400,
      sentDirect: 540,
      recvFlood: 700,
      recvDirect: 580,
      lastSnr: 6.5,
    );
    _notices.add(
      CompanionNotice.status(
        prefix: contact.publicKey.take(6).toList(),
        statusSummary: '${status.summary} · ${12 + _rng.nextInt(30)} ms',
        repeaterStatus: status,
      ),
    );
  }

  @override
  Future<void> requestTelemetry(MeshContact contact) => requestStatus(contact);

  @override
  Future<void> loginRepeater(MeshContact contact, String password) async {
    final node = mesh.repeater;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final ok = node != null &&
        _prefixEq(Uint8List.fromList(node.contact.publicKey), Uint8List.fromList(contact.publicKey)) &&
        password == node.password;
    if (ok) {
      node.acl[identity.id] = 3;
    }
    _notices.add(
      CompanionNotice.login(
        prefix: contact.publicKey.take(6).toList(),
        ok: ok,
        isAdmin: ok,
        permissions: ok ? 3 : 0,
      ),
    );
  }

  @override
  Future<void> logoutRepeater(MeshContact contact) async {
    mesh.repeater?.acl.remove(identity.id);
    _notices.add(
      CompanionNotice.cli(
        prefix: contact.publicKey.take(6).toList(),
        cliText: 'OK',
      ),
    );
  }

  @override
  Future<void> sendCli(MeshContact contact, String command) async {
    await Future<void>.delayed(const Duration(milliseconds: 15));
    final node = mesh.repeater;
    final prefix = contact.publicKey.take(6).toList();
    if (node == null ||
        !_prefixEq(Uint8List.fromList(node.contact.publicKey), Uint8List.fromList(contact.publicKey))) {
      _notices.add(CompanionNotice.cli(prefix: prefix, cliText: 'ERR: unknown node'));
      return;
    }
    if (!node.isAuthed(identity.id) && command.trim() != 'logout') {
      _notices.add(CompanionNotice.cli(prefix: prefix, cliText: 'ERR: not logged in'));
      return;
    }
    _notices.add(
      CompanionNotice.cli(prefix: prefix, cliText: _cliReply(node, command.trim())),
    );
  }

  String _cliReply(SimVirtualRepeater node, String command) {
    final parts = command.split(RegExp(r'\s+'));
    final verb = parts.isEmpty ? '' : parts.first.toLowerCase();
    switch (verb) {
      case 'ver':
        return 'v1.8.0 sim-repeater';
      case 'board':
        return 'MeshPix Simulator';
      case 'clock':
        if (parts.length > 1 && parts[1] == 'sync') return 'OK time synced';
        return DateTime.now().toUtc().toIso8601String();
      case 'get':
        if (parts.length < 2) return 'ERR: get <name>';
        switch (parts[1]) {
          case 'name':
            return node.name;
          case 'radio':
            return '869.525,250,11,5';
          case 'tx':
            return '22';
          default:
            return 'ERR: unknown';
        }
      case 'set':
        if (parts.length >= 3 && parts[1] == 'name') {
          node.name = parts.sublist(2).join(' ');
          return 'OK';
        }
        if (parts.length >= 3 && parts[1] == 'perm' || parts.first == 'setperm') {
          return 'OK';
        }
        return 'OK';
      case 'setperm':
        return 'OK';
      case 'neighbors':
        return node.neighbors
            .map((n) {
              final epoch = (n.heard ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
              final snr4 = ((n.snr ?? 0) * 4).round();
              return '${n.prefixHex}:$epoch:$snr4';
            })
            .join('\n');
      case 'advert':
        return 'OK';
      case 'advert.zerohop':
        return 'OK';
      case 'reboot':
      case 'clkreboot':
        node.acl.clear();
        return 'OK';
      case 'logout':
        node.acl.remove(identity.id);
        return 'OK';
      case 'help':
        return repeaterQuickActions.join('\n');
      default:
        return 'ERR: unknown cmd';
    }
  }

  @override
  Future<void> tracePath(MeshContact contact) async {
    final hops = contact.hopCount;
    _notices.add(
      CompanionNotice.trace(
        prefix: contact.publicKey.take(6).toList(),
        traceSummary: hops == 0 ? 'Trace · direkt' : 'Trace · $hops Hops',
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
