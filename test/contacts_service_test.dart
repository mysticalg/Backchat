import 'package:backchat/models/app_user.dart';
import 'package:backchat/models/call_models.dart';
import 'package:backchat/services/auth_service.dart';
import 'package:backchat/services/backchat_api_service.dart';
import 'package:backchat/services/contacts_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _DisabledApiClient implements BackchatApiClient {
  @override
  bool get isConfigured => false;

  @override
  Future<void> clearToken() async {}

  @override
  Future<List<AppUser>> fetchContacts() {
    throw UnimplementedError();
  }

  @override
  Future<AppUser> fetchMyProfile() {
    throw UnimplementedError();
  }

  @override
  Future<Map<String, dynamic>> inviteByUsername(String username) {
    throw UnimplementedError();
  }

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
  }) {
    throw UnimplementedError();
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
  }) {
    throw UnimplementedError();
  }

  @override
  Future<CallServerConfig> fetchCallConfig() {
    throw UnimplementedError();
  }

  @override
  Future<PollCallSignalsResult> pollCallSignals({
    int sinceId = 0,
    int limit = 100,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> sendCallSignal({
    required int callId,
    required CallSignalType type,
    Map<String, dynamic>? payload,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<Map<String, dynamic>> signInOrCreateWithUsername({
    required String username,
    required String recoveryEmail,
  }) {
    throw UnimplementedError();
  }

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
  }) {
    throw UnimplementedError();
  }
}

void main() {
  late AuthService authService;
  late ContactsService contactsService;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    authService = AuthService(apiService: _DisabledApiClient());
    contactsService = ContactsService(apiService: _DisabledApiClient());
  });

  test('invite by username adds an existing user to contacts', () async {
    final alice = await authService.signInOrCreateWithUsername(
      username: 'alice_01',
      recoveryEmail: 'alice@example.com',
    );
    await authService.signInOrCreateWithUsername(
      username: 'bob_01',
      recoveryEmail: 'bob@example.com',
    );

    final invite = await contactsService.inviteByUsername(
      currentUser: alice.user!,
      username: 'bob_01',
      authService: authService,
    );
    final contacts = await contactsService.pullContactsFor(alice.user!);

    expect(invite.status, InviteByUsernameStatus.added);
    expect(contacts.length, 1);
    expect(contacts.first.displayName, 'bob_01');
  });

  test('invite by username prevents duplicate and self-invite', () async {
    final alice = await authService.signInOrCreateWithUsername(
      username: 'alice_01',
      recoveryEmail: 'alice@example.com',
    );
    await authService.signInOrCreateWithUsername(
      username: 'bob_01',
      recoveryEmail: 'bob@example.com',
    );

    await contactsService.inviteByUsername(
      currentUser: alice.user!,
      username: 'bob_01',
      authService: authService,
    );
    final duplicate = await contactsService.inviteByUsername(
      currentUser: alice.user!,
      username: 'bob_01',
      authService: authService,
    );
    final selfInvite = await contactsService.inviteByUsername(
      currentUser: alice.user!,
      username: 'alice_01',
      authService: authService,
    );

    expect(duplicate.status, InviteByUsernameStatus.alreadyContact);
    expect(selfInvite.status, InviteByUsernameStatus.selfInvite);
  });

  test('invite by username fails when username does not exist', () async {
    final alice = await authService.signInOrCreateWithUsername(
      username: 'alice_01',
      recoveryEmail: 'alice@example.com',
    );

    final invite = await contactsService.inviteByUsername(
      currentUser: alice.user!,
      username: 'missing_user',
      authService: authService,
    );

    expect(invite.status, InviteByUsernameStatus.notFound);
  });
}
