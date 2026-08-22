import 'package:flutter_test/flutter_test.dart';
import 'package:meshpix/main.dart';

void main() {
  testWidgets('home starts on the BLE scan screen', (tester) async {
    await tester.pumpWidget(const MeshPixApp());
    await tester.pumpAndSettle();
    expect(find.text('MeshPix'), findsOneWidget);
    expect(find.textContaining('Suche MeshCore-Nodes'), findsOneWidget);
    expect(find.text('Simulator'), findsNothing);
  });
}
