import 'package:backchat/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders startup sign-in options', (WidgetTester tester) async {
    await tester.pumpWidget(const BackchatApp());

    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Continue with Facebook'), findsOneWidget);
    expect(find.text('Continue with X'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);
    expect(find.text('Recover username'), findsOneWidget);
  });
}
