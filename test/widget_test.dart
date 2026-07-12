import 'package:flutter_test/flutter_test.dart';
import 'package:xctraining/main.dart';

void main() {
  testWidgets('App renders title', (WidgetTester tester) async {
    await tester.pumpWidget(const XCTrainingApp());
    expect(find.text('Chadwick XC Training'), findsOneWidget);
  });
}
