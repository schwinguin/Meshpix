import 'dart:async';
import 'dart:typed_data';

import '../codec/limits.dart';
import '../models/channel.dart';
import '../models/contact.dart';
import '../transfer/protocol.dart';

class SimIdentity {
  SimIdentity({required this.id, required this.name, required this.publicKey});
  final String id;
  final String name;
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
}

class SimRadio implements PacketRadio {
  SimRadio({required this.mesh, required this.identity}) {
    mesh.attach(this);
    contacts.addAll(
      mesh._radios.values
          .where((r) => r.identity.id != identity.id)
          .map(
            (r) => MeshContact(
              publicKey: r.identity.publicKey,
              name: r.identity.name,
              outPath: Uint8List.fromList([0x01]),
            ),
          ),
    );
    channels.add(MeshChannel(index: 0, name: 'Public'));
  }

  final SimMesh mesh;
  final SimIdentity identity;
  final contacts = <MeshContact>[];
  final channels = <MeshChannel>[];

  final _incoming = StreamController<IncomingPacket>.broadcast();

  @override
  Stream<IncomingPacket> get incoming => _incoming.stream;

  void refreshContacts() {
    contacts
      ..clear()
      ..addAll(
        mesh._radios.values
            .where((r) => r.identity.id != identity.id)
            .map(
              (r) => MeshContact(
                publicKey: r.identity.publicKey,
                name: r.identity.name,
                outPath: Uint8List.fromList([0x01]),
              ),
            ),
      );
  }

  @override
  Future<void> sendText({
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
    );
    _route(destination, packet);
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

  Future<void> dispose() async {
    mesh.detach(identity.id);
    await _incoming.close();
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
