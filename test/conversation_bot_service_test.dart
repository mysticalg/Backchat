import 'package:backchat/services/conversation_bot_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('persists enabled bot user ids per conversation', () async {
    final ConversationBotService service = ConversationBotService();

    await service.saveEnabledBotUserIds(
      currentUserId: 'username:alice',
      contactUserId: 'username:bob',
      botUserIds: const <String>['llm:atlas', 'llm:scout'],
    );
    await service.saveEnabledBotUserIds(
      currentUserId: 'username:alice',
      contactUserId: 'username:charlie',
      botUserIds: const <String>['llm:atlas'],
    );

    expect(
      await service.loadEnabledBotUserIds(
        currentUserId: 'username:alice',
        contactUserId: 'username:bob',
      ),
      <String>['llm:atlas', 'llm:scout'],
    );
    expect(
      await service.loadEnabledBotUserIds(
        currentUserId: 'username:alice',
        contactUserId: 'username:charlie',
      ),
      <String>['llm:atlas'],
    );
  });

  test('clears bot memberships when an empty selection is saved', () async {
    final ConversationBotService service = ConversationBotService();

    await service.saveEnabledBotUserIds(
      currentUserId: 'username:alice',
      contactUserId: 'username:bob',
      botUserIds: const <String>['llm:atlas'],
    );
    await service.saveEnabledBotUserIds(
      currentUserId: 'username:alice',
      contactUserId: 'username:bob',
      botUserIds: const <String>[],
    );

    expect(
      await service.loadEnabledBotUserIds(
        currentUserId: 'username:alice',
        contactUserId: 'username:bob',
      ),
      isEmpty,
    );
  });
}
