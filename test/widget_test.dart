import 'package:flutter_test/flutter_test.dart';
import 'package:my_rehbar/main.dart';

void main() {
  testWidgets('App launches and shows Module Selection screen',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MyRehbarApp());
    expect(find.text('Select a Knowledge Base Module:'), findsOneWidget);
  });
}
