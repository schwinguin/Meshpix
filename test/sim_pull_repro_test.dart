import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshpix/codec/mp1.dart';
import 'package:meshpix/codec/rgba.dart';
import 'package:meshpix/sim/sim_mesh.dart';
import 'package:meshpix/transfer/engine.dart';
import 'package:meshpix/transfer/protocol.dart';

void main() {
  test('sim DM pull: Ben nachlaedt JPEG-Upgrade von Anna', () async {
    final mesh = SimMesh();
    final anna = SimRadio(
      mesh: mesh,
      identity: SimIdentity(id: 'anna', name: 'Anna', publicKey: keyFromSeed(11)),
    );
    final ben = SimRadio(
      mesh: mesh,
      identity: SimIdentity(id: 'ben', name: 'Ben', publicKey: keyFromSeed(23)),
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

    final previewEvt = Completer<TransferEvent>();
    final fullEvt = Completer<TransferEvent>();
    benEngine.events.listen((e) {
      if (e.image == null || e.outgoing) return;
      if (!previewEvt.isCompleted && e.image!.upgradeChunks > 0) {
        previewEvt.complete(e);
      } else if (!fullEvt.isCompleted && e.image!.upgradeChunks == 0 && e.image!.isPhoto) {
        fullEvt.complete(e);
      }
    });

    // Anna schickt ein DM mit JPEG-Nachzug (wie Composer: includeUpgrade+).
    final encoded = codec.encode(
      makeTestCard(96),
      options: const EncodeOptions(includeUpgrade: true, transferId: 42),
    );
    expect(encoded.chunks, isNotEmpty, reason: 'Upgrade-Chunks erwartet');

    final benContact = anna.contacts.firstWhere((c) => c.name == 'Ben');
    await annaEngine.sendImage(
      encoded: encoded,
      destination: RadioDestination.dm(Uint8List.fromList(benContact.publicKey)),
    );

    final prev = await previewEvt.future.timeout(const Duration(seconds: 2));
    debugPrint('Preview erhalten: ${prev.message} (senderPrefix=${prev.senderPrefix})');
    expect(prev.transferId, 42);

    // Ben laedt nach — Ziel wie AppController.pull: DM-Chatpartner des offenen Convers.
    final annaPrefix = prev.senderPrefix!;
    await benEngine.requestUpgrade(42, RadioDestination.dm(annaPrefix));

    try {
      final full = await fullEvt.future.timeout(const Duration(seconds: 5));
      debugPrint('Upgrade erhalten: ${full.message}');
      expect(full.image!.width, greaterThan(prev.image!.width));
    } on TimeoutException catch (e) {
      fail('Ben hat das Upgrade nicht erhalten (Timeout): $e');
    }

    await annaEngine.dispose();
    await benEngine.dispose();
    await anna.dispose();
    await ben.dispose();
  });
}
