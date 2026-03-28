import 'package:backchat/services/conversation_session_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('persists the last selected contact per user', () async {
    final ConversationSessionService service = ConversationSessionService();

    await service.saveLastSelectedContactId(
      currentUserId: 'username:alice',
      contactUserId: 'username:bob',
    );
    await service.saveLastSelectedContactId(
      currentUserId: 'username:charlie',
      contactUserId: 'username:dana',
    );

    expect(
      await service.loadLastSelectedContactId(currentUserId: 'username:alice'),
      'username:bob',
    );
    expect(
      await service.loadLastSelectedContactId(
        currentUserId: 'username:charlie',
      ),
      'username:dana',
    );
  });

  test('clears the remembered conversation when selection is removed',
      () async {
    final ConversationSessionService service = ConversationSessionService();

    await service.saveLastSelectedContactId(
      currentUserId: 'username:alice',
      contactUserId: 'username:bob',
    );
    await service.saveLastSelectedContactId(
      currentUserId: 'username:alice',
      contactUserId: null,
    );

    expect(
      await service.loadLastSelectedContactId(currentUserId: 'username:alice'),
      isNull,
    );
  });
}
