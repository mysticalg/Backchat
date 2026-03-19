import 'package:backchat/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders startup sign-in options', (WidgetTester tester) async {
    await tester.pumpWidget(const BackchatApp());

    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Username sign-in'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);
    expect(find.text('Or continue with'), findsOneWidget);
    expect(find.text('Google'), findsOneWidget);
    expect(find.text('Facebook'), findsOneWidget);
    expect(find.text('X'), findsOneWidget);
    expect(find.text('Recover username by email'), findsOneWidget);
    expect(find.text('Recover username'), findsOneWidget);
  });
}
