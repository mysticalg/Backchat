import 'dart:typed_data';

import 'package:backchat/models/app_user.dart';
import 'package:backchat/models/call_models.dart';
import 'package:backchat/models/chat_message.dart';
import 'package:backchat/services/backchat_api_service.dart';
import 'package:backchat/services/messaging_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeApiClient implements BackchatApiClient {
  _FakeApiClient({
    List<PollMessagesResult>? pollResults,
  }) : _pollResults = pollResults ?? <PollMessagesResult>[];

  final List<PollMessagesResult> _pollResults;
  final List<Map<String, String?>> sentMessages = <Map<String, String?>>[];

  @override
  bool get isConfigured => true;

  @override
  Future<void> clearToken() async {}

  @override
  Future<List<AppUser>> fetchContacts() async => <AppUser>[];

  @override
  Future<AppUser> fetchMyProfile() {
    throw UnimplementedError();
  }

  @override
  Future<Map<String, dynamic>> inviteByUsername(String username) async =>
      <String, dynamic>{};

  @override
  Future<AppUser> updateProfile({
    required String avatarUrl,
    required String quote,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<SocialOAuthPollResult> pollSocialOAuth(String state) {
    throw UnimplementedError();
  }

  @override
  Future<PollMessagesResult> pollMessages({
    int sinceId = 0,
    int limit = 100,
    required String currentUserId,
  }) async {
    if (_pollResults.isEmpty) {
      return PollMessagesResult(
        nextSinceId: sinceId,
        messages: const <ChatMessage>[],
      );
    }
    return _pollResults.removeAt(0);
  }

  @override
  Future<SocialOAuthProbeResult> probeSocialOAuth() {
    throw UnimplementedError();
  }

  @override
  Future<String?> recoverUsernameForEmail(String recoveryEmail) {
    throw UnimplementedError();
  }

  @override
  Future<void> sendMessage({
    required String toUsername,
    required String cipherText,
    String? clientMessageId,
  }) async {
    sentMessages.add(<String, String?>{
      'toUsername': toUsername,
      'cipherText': cipherText,
      'clientMessageId': clientMessageId,
    });
  }

  @override
  Future<UploadedMedia> uploadMedia({
    required Uint8List bytes,
    required String mimeType,
    String? filename,
    void Function(double progress)? onProgress,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<Map<String, dynamic>> signInOrCreateWithUsername({
    required String username,
    required String recoveryEmail,
    required String password,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<CallServerConfig> fetchCallConfig() async => const CallServerConfig();

  @override
  Future<PollCallSignalsResult> pollCallSignals({
    int sinceId = 0,
    int limit = 100,
  }) async {
    return const PollCallSignalsResult(
      nextSinceId: 0,
      signals: <CallSignalEvent>[],
    );
  }

  @override
  Future<void> sendCallSignal({
    required int callId,
    required CallSignalType type,
    Map<String, dynamic>? payload,
  }) async {}

  @override
  Future<SocialOAuthStartResult> startSocialOAuth(String provider) {
    throw UnimplementedError();
  }

  @override
  Future<CallSummary> startCall({
    required String toUsername,
    required CallKind kind,
    required String offerType,
    required String offerSdp,
    required CallSettings settings,
  }) async {
    throw UnimplementedError();
  }
}

void main() {
  const String aliceId = 'username:alice';
  const String bobId = 'username:bob';

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('persists sent messages locally across service instances', () async {
    final _FakeApiClient apiClient = _FakeApiClient();
    final MessagingService service = MessagingService(apiService: apiClient);
    final DateTime sentAt = DateTime.parse('2026-03-18T12:00:00Z').toLocal();

    await service.activateForUser(aliceId);
    await service.send(
      ChatMessage(
        localId: 'local:alice:bob:1',
        fromUserId: aliceId,
        toUserId: bobId,
        cipherText: 'hello',
        sentAt: sentAt,
        isRead: true,
      ),
    );

    final List<ChatMessage> sentMessages = await service.listForPair(
      aliceId,
      bobId,
    );
    expect(sentMessages, hasLength(1));
    expect(sentMessages.single.cipherText, 'hello');
    expect(apiClient.sentMessages.single['toUsername'], 'bob');

    final MessagingService restored = MessagingService(
      apiService: _FakeApiClient(),
    );
    await restored.activateForUser(aliceId);

    final List<ChatMessage> restoredMessages = await restored.listForPair(
      aliceId,
      bobId,
    );
    expect(restoredMessages, hasLength(1));
    expect(restoredMessages.single.localId, 'local:alice:bob:1');
    expect(restoredMessages.single.sentAt, sentAt);
  });

  test('tracks unread incoming messages until conversation is opened',
      () async {
    final MessagingService service = MessagingService(
      apiService: _FakeApiClient(
        pollResults: <PollMessagesResult>[
          PollMessagesResult(
            nextSinceId: 42,
            messages: <ChatMessage>[
              ChatMessage(
                localId: 'remote:42',
                fromUserId: bobId,
                toUserId: aliceId,
                cipherText: 'incoming',
                sentAt: DateTime.parse('2026-03-18T12:01:00Z').toLocal(),
              ),
            ],
          ),
        ],
      ),
    );

    await service.activateForUser(aliceId);
    final List<ChatMessage> newMessages = await service.syncIncoming(aliceId);

    expect(newMessages, hasLength(1));
    expect(
      service.unreadCountForContact(
        currentUserId: aliceId,
        contactUserId: bobId,
      ),
      1,
    );

    await service.markConversationRead(
      currentUserId: aliceId,
      contactUserId: bobId,
    );
    expect(
      service.unreadCountForContact(
        currentUserId: aliceId,
        contactUserId: bobId,
      ),
      0,
    );

    final MessagingService restored = MessagingService(
      apiService: _FakeApiClient(),
    );
    await restored.activateForUser(aliceId);
    expect(
      restored.unreadCountForContact(
        currentUserId: aliceId,
        contactUserId: bobId,
      ),
      0,
    );
  });
}
