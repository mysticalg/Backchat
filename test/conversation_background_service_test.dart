import 'package:backchat/services/conversation_background_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('persists conversation backgrounds per user and contact', () async {
    final ConversationBackgroundService service =
        ConversationBackgroundService();

    await service.saveBackgroundUrl(
      currentUserId: 'username:alice',
      contactUserId: 'username:bob',
      url: 'https://example.com/ocean.jpg',
    );

    final String? loaded = await service.loadBackgroundUrl(
      currentUserId: 'username:alice',
      contactUserId: 'username:bob',
    );
    final String? otherConversation = await service.loadBackgroundUrl(
      currentUserId: 'username:alice',
      contactUserId: 'username:carol',
    );

    expect(loaded, 'https://example.com/ocean.jpg');
    expect(otherConversation, isNull);
  });

  test('clears saved conversation backgrounds', () async {
    final ConversationBackgroundService service =
        ConversationBackgroundService();

    await service.saveBackgroundUrl(
      currentUserId: 'username:alice',
      contactUserId: 'username:bob',
      url: 'https://example.com/ocean.jpg',
    );
    await service.clearBackgroundUrl(
      currentUserId: 'username:alice',
      contactUserId: 'username:bob',
    );

    final String? loaded = await service.loadBackgroundUrl(
      currentUserId: 'username:alice',
      contactUserId: 'username:bob',
    );

    expect(loaded, isNull);
  });
}
