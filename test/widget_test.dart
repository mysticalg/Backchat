import 'package:backchat/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders username sign-in screen', (WidgetTester tester) async {
    await tester.pumpWidget(const BackchatApp());

    expect(find.text('Username sign in'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);
    expect(find.text('Recover username'), findsOneWidget);
  });
}
