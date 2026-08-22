import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshpix/codec/mp1.dart';
import 'package:meshpix/codec/rgba.dart';
import 'package:meshpix/sim/sim_mesh.dart';
import 'package:meshpix/transfer/engine.dart';
import 'package:meshpix/transfer/protocol.dart';

void main() {
  test('simulator loopback delivers a preview from Anna to Ben', () async {
    final mesh = SimMesh();
    final anna = SimRadio(
      mesh: mesh,
      identity: SimIdentity(id: 'anna', name: 'Anna', publicKey: keyFromSeed(1)),
    );
    final ben = SimRadio(
      mesh: mesh,
      identity: SimIdentity(id: 'ben', name: 'Ben', publicKey: keyFromSeed(2)),
    );
    anna.loadPeers();
    ben.loadPeers();

    final codec = Mp1Codec();
    final annaEngine = TransferEngine(
      radio: anna,
      codec: codec,
      budget: AirtimeBudget(airtimeFactor: 0),
    );
    final benEngine = TransferEngine(
      radio: ben,
      codec: codec,
      budget: AirtimeBudget(airtimeFactor: 0),
    );
    final events = <TransferEvent>[];
    final done = Completer<void>();
    benEngine.events.listen((e) {
      events.add(e);
      if (e.image != null && !done.isCompleted) done.complete();
    });

    final encoded = codec.encode(
      makeTestCard(48),
      options: const EncodeOptions(includeUpgrade: false, transferId: 3),
    );
    await annaEngine.sendImage(
      encoded: encoded,
      destination: const RadioDestination.channel(0),
    );
    await done.future.timeout(const Duration(seconds: 2));
    expect(events.single.image!.width, encoded.preview.image.width);

    await annaEngine.dispose();
    await benEngine.dispose();
    await anna.dispose();
    await ben.dispose();
  });
}
