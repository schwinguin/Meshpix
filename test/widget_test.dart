import 'package:flutter_test/flutter_test.dart';
import 'package:meshpix/main.dart';

void main() {
  testWidgets('home starts on the BLE scan screen', (tester) async {
    await tester.pumpWidget(const MeshPixApp());
    await tester.pumpAndSettle();
    expect(find.text('MeshPix'), findsOneWidget);
    expect(find.text('Kein MeshCore-Node gefunden'), findsOneWidget);
    expect(find.text('Scannen'), findsOneWidget);
    expect(find.text('Simulator'), findsNothing);
  });
}
