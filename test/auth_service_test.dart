import 'package:backchat/models/app_user.dart';
import 'package:backchat/models/chat_message.dart';
import 'package:backchat/services/auth_service.dart';
import 'package:backchat/services/backchat_api_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

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
  Future<AppUser> fetchMyProfile() async {
    throw const BackchatApiException(status: 'api_error', message: 'offline');
  }

  @override
  Future<Map<String, dynamic>> inviteByUsername(String username) async {
    throw const BackchatApiException(status: 'api_error', message: 'offline');
  }

  @override
  Future<AppUser> updateProfile({
    required String avatarUrl,
    required String quote,
  }) async {
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

class _SuccessfulSocialOAuthApiClient implements BackchatApiClient {
  @override
  bool get isConfigured => true;

  @override
  Future<void> clearToken() async {}

  @override
  Future<List<AppUser>> fetchContacts() async => <AppUser>[];

  @override
  Future<AppUser> fetchMyProfile() async {
    throw UnimplementedError();
  }

  @override
  Future<Map<String, dynamic>> inviteByUsername(String username) async =>
      <String, dynamic>{};

  @override
  Future<AppUser> updateProfile({
    required String avatarUrl,
    required String quote,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<SocialOAuthPollResult> pollSocialOAuth(String state) async {
    return SocialOAuthPollResult(
      status: 'authorized',
      user: AppUser(
        id: 'username:social_user',
        displayName: 'social_user',
        avatarUrl: '',
        provider: AuthProvider.google,
      ),
    );
  }

  @override
  Future<PollMessagesResult> pollMessages({
    int sinceId = 0,
    int limit = 100,
    required String currentUserId,
  }) async {
    return const PollMessagesResult(
      nextSinceId: 0,
      messages: <ChatMessage>[],
    );
  }

  @override
  Future<SocialOAuthProbeResult> probeSocialOAuth() async {
    return const SocialOAuthProbeResult(
      oauthReady: true,
      message: 'ready',
      curlAvailable: true,
      schemaReady: true,
      googleConfigured: true,
      facebookConfigured: true,
      xConfigured: true,
    );
  }

  @override
  Future<String?> recoverUsernameForEmail(String recoveryEmail) async => null;

  @override
  Future<void> sendMessage({
    required String toUsername,
    required String cipherText,
    String? clientMessageId,
  }) async {}

  @override
  Future<Map<String, dynamic>> signInOrCreateWithUsername({
    required String username,
    required String recoveryEmail,
  }) async =>
      <String, dynamic>{};

  @override
  Future<SocialOAuthStartResult> startSocialOAuth(String provider) async {
    return const SocialOAuthStartResult(
      state: 'test-state',
      authorizationUrl: 'https://example.com/oauth/start',
    );
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

  test('social auth uses desktop process launcher on Windows first', () async {
    String? launchedExecutable;
    List<String>? launchedArguments;

    final AuthService authService = AuthService(
      apiService: _SuccessfulSocialOAuthApiClient(),
      browserPlatform: BrowserLaunchPlatform.windows,
      processLauncher: (String executable, List<String> arguments) async {
        launchedExecutable = executable;
        launchedArguments = arguments;
        return true;
      },
      urlLauncher: (Uri uri, LaunchMode mode) async {
        fail(
            'url_launcher fallback should not run when process launch succeeds');
      },
    );

    final AppUser? user = await authService.signInWithGoogle();

    expect(user?.displayName, 'social_user');
    expect(launchedExecutable, 'explorer.exe');
    expect(launchedArguments, <String>['https://example.com/oauth/start']);
  });

  test('social auth falls back to url_launcher when process launch fails',
      () async {
    Uri? launchedUri;
    LaunchMode? launchedMode;

    final AuthService authService = AuthService(
      apiService: _SuccessfulSocialOAuthApiClient(),
      browserPlatform: BrowserLaunchPlatform.windows,
      processLauncher: (String executable, List<String> arguments) async {
        return false;
      },
      urlLauncher: (Uri uri, LaunchMode mode) async {
        launchedUri = uri;
        launchedMode = mode;
        return true;
      },
    );

    final AppUser? user = await authService.signInWithGoogle();

    expect(user?.displayName, 'social_user');
    expect(launchedUri, Uri.parse('https://example.com/oauth/start'));
    expect(launchedMode, LaunchMode.externalApplication);
  });
}
