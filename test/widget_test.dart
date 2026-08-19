import 'package:flutter_test/flutter_test.dart';
import 'package:meshpix/main.dart';

void main() {
  testWidgets('home shows MeshPix simulator', (tester) async {
    await tester.pumpWidget(const MeshPixApp());
    await tester.pumpAndSettle();
    expect(find.text('MeshPix'), findsOneWidget);
    expect(find.text('Simulator'), findsOneWidget);
    expect(find.text('Public'), findsOneWidget);
    expect(find.text('Ben'), findsWidgets);
  });
}
