import 'package:backchat/models/app_user.dart';
import 'package:backchat/services/auth_service.dart';
import 'package:backchat/services/backchat_api_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FailingConfiguredApiClient implements BackchatApiClient {
  @override
  bool get isConfigured => true;

  @override
  Future<void> clearToken() async {}

  @override
  Future<List<AppUser>> fetchContacts() async {
    throw const BackchatApiException(status: 'api_error', message: 'offline');
  }

  @override
  Future<Map<String, dynamic>> inviteByUsername(String username) async {
    throw const BackchatApiException(status: 'api_error', message: 'offline');
  }

  @override
  Future<SocialOAuthPollResult> pollSocialOAuth(String state) async {
    throw const BackchatApiException(status: 'api_error', message: 'offline');
  }

  @override
  Future<PollMessagesResult> pollMessages({
    int sinceId = 0,
    int limit = 100,
    required String currentUserId,
  }) async {
    throw const BackchatApiException(status: 'api_error', message: 'offline');
  }

  @override
  Future<SocialOAuthProbeResult> probeSocialOAuth() async {
    throw const BackchatApiException(status: 'api_error', message: 'offline');
  }

  @override
  Future<String?> recoverUsernameForEmail(String recoveryEmail) async {
    throw const BackchatApiException(status: 'api_error', message: 'offline');
  }

  @override
  Future<Map<String, dynamic>> signInOrCreateWithUsername({
    required String username,
    required String recoveryEmail,
  }) async {
    throw const BackchatApiException(status: 'api_error', message: 'offline');
  }

  @override
  Future<void> sendMessage({
    required String toUsername,
    required String cipherText,
    String? clientMessageId,
  }) async {
    throw const BackchatApiException(status: 'api_error', message: 'offline');
  }

  @override
  Future<SocialOAuthStartResult> startSocialOAuth(String provider) async {
    throw const BackchatApiException(status: 'api_error', message: 'offline');
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test(
      'falls back to local username auth when API is configured but unavailable',
      () async {
    final AuthService authService =
        AuthService(apiService: _FailingConfiguredApiClient());

    final created = await authService.signInOrCreateWithUsername(
      username: 'fallback_user',
      recoveryEmail: 'fallback_user@example.com',
    );
    final signedIn = await authService.signInOrCreateWithUsername(
      username: 'fallback_user',
      recoveryEmail: '',
    );

    expect(created.status, UsernameSignInStatus.created);
    expect(created.user?.displayName, 'fallback_user');
    expect(signedIn.status, UsernameSignInStatus.signedIn);
    expect(signedIn.user?.displayName, 'fallback_user');
  });

  test('falls back to local recovery when API is configured but unavailable',
      () async {
    final AuthService authService =
        AuthService(apiService: _FailingConfiguredApiClient());

    await authService.signInOrCreateWithUsername(
      username: 'recover_user',
      recoveryEmail: 'recover_user@example.com',
    );
    final String? recovered =
        await authService.recoverUsernameForEmail('recover_user@example.com');

    expect(recovered, 'recover_user');
  });
}
