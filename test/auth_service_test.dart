import 'package:backchat/models/app_user.dart';
import 'package:backchat/models/call_models.dart';
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
    required String password,
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
  Future<CallServerConfig> fetchCallConfig() async {
    throw const BackchatApiException(status: 'api_error', message: 'offline');
  }

  @override
  Future<PollCallSignalsResult> pollCallSignals({
    int sinceId = 0,
    int limit = 100,
  }) async {
    throw const BackchatApiException(status: 'api_error', message: 'offline');
  }

  @override
  Future<void> sendCallSignal({
    required int callId,
    required CallSignalType type,
    Map<String, dynamic>? payload,
  }) async {
    throw const BackchatApiException(status: 'api_error', message: 'offline');
  }

  @override
  Future<CallSummary> startCall({
    required String toUsername,
    required CallKind kind,
    required String offerType,
    required String offerSdp,
    required CallSettings settings,
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
  Future<Map<String, dynamic>> signInOrCreateWithUsername({
    required String username,
    required String recoveryEmail,
    required String password,
  }) async =>
      <String, dynamic>{};

  @override
  Future<SocialOAuthStartResult> startSocialOAuth(String provider) async {
    return const SocialOAuthStartResult(
      state: 'test-state',
      authorizationUrl: 'https://example.com/oauth/start',
    );
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

class _RestorableRemoteSessionApiClient extends _SuccessfulSocialOAuthApiClient {
  @override
  Future<AppUser> fetchMyProfile() async {
    return AppUser(
      id: 'username:google_user',
      username: 'google_user',
      displayName: 'Google User',
      avatarUrl: '',
      provider: AuthProvider.google,
    );
  }
}

class _ResumableSocialOAuthApiClient extends _SuccessfulSocialOAuthApiClient {
  int pollCount = 0;

  @override
  Future<SocialOAuthPollResult> pollSocialOAuth(String state) async {
    pollCount += 1;
    return SocialOAuthPollResult(
      status: 'authorized',
      user: AppUser(
        id: 'username:google_resume',
        username: 'google_resume',
        displayName: 'Google Resume',
        avatarUrl: '',
        provider: AuthProvider.google,
      ),
    );
  }
}

class _SuccessfulUsernameApiClient implements BackchatApiClient {
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
    throw UnimplementedError();
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
    throw UnimplementedError();
  }

  @override
  Future<String?> recoverUsernameForEmail(String recoveryEmail) async => null;

  @override
  Future<Map<String, dynamic>> signInOrCreateWithUsername({
    required String username,
    required String recoveryEmail,
    required String password,
  }) async {
    return <String, dynamic>{
      'status': password.isNotEmpty ? 'password_set' : 'signed_in',
      'user': <String, dynamic>{
        'id': 'username:${username.toLowerCase()}',
        'username': username,
        'displayName': username,
        'avatarUrl': '',
        'provider': 'username',
        'quote': '',
      },
    };
  }

  @override
  Future<void> sendMessage({
    required String toUsername,
    required String cipherText,
    String? clientMessageId,
  }) async {}

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
  Future<CallSummary> startCall({
    required String toUsername,
    required CallKind kind,
    required String offerType,
    required String offerSdp,
    required CallSettings settings,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<SocialOAuthStartResult> startSocialOAuth(String provider) async {
    throw UnimplementedError();
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
      password: '',
    );
    final signedIn = await authService.signInOrCreateWithUsername(
      username: 'fallback_user',
      recoveryEmail: '',
      password: '',
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
      password: '',
    );
    final String? recovered =
        await authService.recoverUsernameForEmail('recover_user@example.com');

    expect(recovered, 'recover_user');
  });

  test('remembers API-backed username sign-ins for autofill', () async {
    final AuthService authService =
        AuthService(apiService: _SuccessfulUsernameApiClient());

    final UsernameSignInResult result =
        await authService.signInOrCreateWithUsername(
      username: 'api_user',
      recoveryEmail: 'api_user@example.com',
      password: '',
    );
    final List<RememberedUsernameAccount> remembered =
        await authService.loadRememberedUsernameAccounts();

    expect(result.status, UsernameSignInStatus.signedIn);
    expect(remembered, hasLength(1));
    expect(remembered.first.username, 'api_user');
    expect(remembered.first.recoveryEmail, 'api_user@example.com');
  });

  test(
      'keeps remembered recovery email when API sign-in happens without retyping it',
      () async {
    final AuthService authService =
        AuthService(apiService: _SuccessfulUsernameApiClient());

    await authService.signInOrCreateWithUsername(
      username: 'api_user',
      recoveryEmail: 'api_user@example.com',
      password: '',
    );
    await authService.signInOrCreateWithUsername(
      username: 'api_user',
      recoveryEmail: '',
      password: '',
    );
    final List<RememberedUsernameAccount> remembered =
        await authService.loadRememberedUsernameAccounts();

    expect(remembered, hasLength(1));
    expect(remembered.first.username, 'api_user');
    expect(remembered.first.recoveryEmail, 'api_user@example.com');
  });

  test('local password-protected username requires a password later', () async {
    final AuthService authService =
        AuthService(apiService: _FailingConfiguredApiClient());

    final UsernameSignInResult created =
        await authService.signInOrCreateWithUsername(
      username: 'secure_user',
      recoveryEmail: 'secure_user@example.com',
      password: 'correct horse battery',
    );
    final UsernameSignInResult missingPassword =
        await authService.signInOrCreateWithUsername(
      username: 'secure_user',
      recoveryEmail: '',
      password: '',
    );
    final UsernameSignInResult wrongPassword =
        await authService.signInOrCreateWithUsername(
      username: 'secure_user',
      recoveryEmail: '',
      password: 'wrongpass1',
    );
    final UsernameSignInResult signedIn =
        await authService.signInOrCreateWithUsername(
      username: 'secure_user',
      recoveryEmail: '',
      password: 'correct horse battery',
    );

    expect(created.status, UsernameSignInStatus.created);
    expect(missingPassword.status, UsernameSignInStatus.passwordRequired);
    expect(wrongPassword.status, UsernameSignInStatus.passwordIncorrect);
    expect(signedIn.status, UsernameSignInStatus.signedIn);
  });

  test(
      'existing passwordless username can be upgraded with a password and matching recovery email',
      () async {
    final AuthService authService =
        AuthService(apiService: _FailingConfiguredApiClient());

    await authService.signInOrCreateWithUsername(
      username: 'legacy_user',
      recoveryEmail: 'legacy_user@example.com',
      password: '',
    );
    final UsernameSignInResult upgraded =
        await authService.signInOrCreateWithUsername(
      username: 'legacy_user',
      recoveryEmail: 'legacy_user@example.com',
      password: 'legacypass1',
    );
    final UsernameSignInResult signedIn =
        await authService.signInOrCreateWithUsername(
      username: 'legacy_user',
      recoveryEmail: '',
      password: 'legacypass1',
    );

    expect(upgraded.status, UsernameSignInStatus.passwordSet);
    expect(signedIn.status, UsernameSignInStatus.signedIn);
  });

  test('api-backed password sign-ins remember that the account is secured',
      () async {
    final AuthService authService =
        AuthService(apiService: _SuccessfulUsernameApiClient());

    final UsernameSignInResult result =
        await authService.signInOrCreateWithUsername(
      username: 'api_secure',
      recoveryEmail: 'api_secure@example.com',
      password: 'apisecure1',
    );
    final List<RememberedUsernameAccount> remembered =
        await authService.loadRememberedUsernameAccounts();

    expect(result.status, UsernameSignInStatus.passwordSet);
    expect(remembered, hasLength(1));
    expect(remembered.first.hasPassword, isTrue);
  });

  test('restores an authenticated remote user from the saved API session',
      () async {
    final AuthService authService = AuthService(
      apiService: _RestorableRemoteSessionApiClient(),
    );

    final AppUser? user = await authService.tryRestoreAuthenticatedUser();

    expect(user?.username, 'google_user');
    expect(user?.provider, AuthProvider.google);
  });

  test('resumes a pending social sign-in after the app returns', () async {
    final _ResumableSocialOAuthApiClient apiClient =
        _ResumableSocialOAuthApiClient();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString('pending_oauth_provider_v1', 'google');
    await prefs.setString('pending_oauth_state_v1', 'resume-state');
    await prefs.setInt(
      'pending_oauth_started_at_v1',
      DateTime.now().toUtc().millisecondsSinceEpoch,
    );

    final AuthService authService = AuthService(apiService: apiClient);

    final AppUser? user = await authService.tryResumePendingSocialSignIn();

    expect(user?.username, 'google_resume');
    expect(user?.provider, AuthProvider.google);
    expect(apiClient.pollCount, greaterThan(0));
    expect(prefs.getString('pending_oauth_state_v1'), isNull);
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
