import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshpix/codec/rgba.dart';
import 'package:meshpix/state/app_controller.dart';

/// Exakter App-Flow im Simulator: Anna schickt DM-Bild mit JPEG-Nachzug,
/// Ben tippt "Nachladen" — mit dem echten Sim-Airtime-Budget (0.25, 2400bps).
void main() {
  test('app-level: Nachladen im Simulator liefert das Foto', () async {
    final app = AppController();
    addTearDown(app.dispose);

    // Anna öffnet DM mit Ben und schickt Testbild (Composer-Default: Upgrade an).
    app.open(app.sessions['anna']!.conversations.firstWhere((c) => !c.isChannel));
    final encoded = await app.previewEncode(
      makeTestCard(96),
      includeUpgrade: true,
      fourColor: true,
    );
    expect(encoded.chunks, isNotEmpty, reason: 'Upgrade-Chunks erwartet');
    await app.sendEncoded(encoded);
    debugPrint('Anna gesendet: ${encoded.stats.summaryDe}, '
        '${encoded.stats.chunkCount} Chunks');

    // Ben: auf das Preview-Event warten (mit canPull).
    final start = DateTime.now();
    while (true) {
      final conv = app.sessions['ben']!.conversations.firstWhere((c) => !c.isChannel);
      final msg = conv.messages
          .where((m) => m.transferId == encoded.transferId)
          .toList();
      if (msg.isNotEmpty) break;
      if (DateTime.now().difference(start) > const Duration(seconds: 5)) {
        fail('Ben hat kein Preview erhalten');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final previewMsg = app.sessions['ben']!
        .conversations
        .firstWhere((c) => !c.isChannel)
        .messages
        .firstWhere((m) => m.transferId == encoded.transferId);
    debugPrint('Ben Preview: ${previewMsg.text}, canPull=${previewMsg.canPull}');
    expect(previewMsg.canPull, isTrue);

    // Ben tippt "Nachladen" (Controller-Pfad, inkl. destFor(openConversation)).
    app.switchNode('ben');
    app.open(app.sessions['ben']!.conversations.firstWhere((c) => !c.isChannel));
    await app.pull(previewMsg);
    debugPrint('Pull um ${DateTime.now()} gestartet, warte auf das Foto …');

    // Sofort nach dem Tipp muss das UI den Pull anzeigen (kein toter Button).
    final convBen = () => app.sessions['ben']!.conversations.firstWhere((c) => !c.isChannel);
    final pulledMsg = convBen().messages
        .firstWhere((m) => m.transferId == encoded.transferId);
    expect(pulledMsg.isPulling, isTrue,
        reason: 'Nach Tipp auf Nachladen muss Fortschritt sichtbar sein');
    expect(pulledMsg.pullTotal, encoded.chunks.length);
    expect(pulledMsg.pullReceived, 0);
    final pullStart = DateTime.now();
    while (true) {
      final conv = app.sessions['ben']!.conversations.firstWhere((c) => !c.isChannel);
      final msg = conv.messages
          .where((m) => m.transferId == encoded.transferId)
          .toList();
      if (msg.isNotEmpty && msg.single.image!.isPhoto) {
        final elapsed = DateTime.now().difference(pullStart);
        debugPrint('Upgrade fertig nach ${elapsed.inMilliseconds} ms: '
            '${msg.single.image!.width}x${msg.single.image!.height}');
        expect(elapsed, lessThan(const Duration(seconds: 60)));
        return;
      }
      if (DateTime.now().difference(pullStart) > const Duration(seconds: 60)) {
        fail('Upgrade kam nach 60s nicht an (letzter Text: '
            '${msg.isNotEmpty ? msg.single.text : 'keine Nachricht'})');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  });
}
