import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/app_user.dart';
import 'backchat_api_service.dart';

enum BrowserLaunchPlatform {
  web,
  windows,
  macos,
  linux,
  other,
}

typedef BrowserUrlLauncher = Future<bool> Function(Uri uri, LaunchMode mode);
typedef BrowserProcessLauncher = Future<bool> Function(
  String executable,
  List<String> arguments,
);

class SocialOAuthLaunchException implements Exception {
  const SocialOAuthLaunchException({
    required this.provider,
    required this.authorizationUri,
  });

  final String provider;
  final Uri authorizationUri;

  String get message =>
      'Could not open browser for ${provider[0].toUpperCase()}${provider.substring(1)} sign-in.';

  @override
  String toString() =>
      'SocialOAuthLaunchException(provider: $provider, authorizationUri: $authorizationUri)';
}

enum UsernameSignInStatus {
  signedIn,
  created,
  passwordSet,
  invalidUsername,
  usernameNeedsRecoveryEmail,
  invalidRecoveryEmail,
  invalidPassword,
  passwordRequired,
  passwordIncorrect,
  passwordSetupNeedsRecoveryEmail,
  recoveryEmailMismatch,
  recoveryEmailAlreadyInUse,
  serverUnavailable,
}

class UsernameSignInResult {
  const UsernameSignInResult({
    required this.status,
    this.user,
    this.linkedUsername,
  });

  final UsernameSignInStatus status;
  final AppUser? user;
  final String? linkedUsername;
}

class RememberedUsernameAccount {
  const RememberedUsernameAccount({
    required this.username,
    required this.normalizedUsername,
    required this.recoveryEmail,
    required this.hasPassword,
    this.lastUsedAt,
  });

  final String username;
  final String normalizedUsername;
  final String recoveryEmail;
  final bool hasPassword;
  final DateTime? lastUsedAt;
}

class _UsernameAccount {
  const _UsernameAccount({
    required this.username,
    required this.normalizedUsername,
    required this.recoveryEmail,
    required this.passwordHash,
    required this.lastUsedAtEpochMs,
  });

  final String username;
  final String normalizedUsername;
  final String recoveryEmail;
  final String passwordHash;
  final int lastUsedAtEpochMs;

  factory _UsernameAccount.fromJson(Map<String, dynamic> json) {
    return _UsernameAccount(
      username: json['username']?.toString() ?? '',
      normalizedUsername: json['normalizedUsername']?.toString() ?? '',
      recoveryEmail: json['recoveryEmail']?.toString() ?? '',
      passwordHash: json['passwordHash']?.toString() ?? '',
      lastUsedAtEpochMs: _parseEpochMs(json['lastUsedAtEpochMs']),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'username': username,
      'normalizedUsername': normalizedUsername,
      'recoveryEmail': recoveryEmail,
      'passwordHash': passwordHash,
      'lastUsedAtEpochMs': lastUsedAtEpochMs,
    };
  }

  _UsernameAccount copyWith({
    String? username,
    String? normalizedUsername,
    String? recoveryEmail,
    String? passwordHash,
    int? lastUsedAtEpochMs,
  }) {
    return _UsernameAccount(
      username: username ?? this.username,
      normalizedUsername: normalizedUsername ?? this.normalizedUsername,
      recoveryEmail: recoveryEmail ?? this.recoveryEmail,
      passwordHash: passwordHash ?? this.passwordHash,
      lastUsedAtEpochMs: lastUsedAtEpochMs ?? this.lastUsedAtEpochMs,
    );
  }

  RememberedUsernameAccount toRememberedAccount() {
    return RememberedUsernameAccount(
      username: username,
      normalizedUsername: normalizedUsername,
      recoveryEmail: recoveryEmail,
      hasPassword: passwordHash.isNotEmpty,
      lastUsedAt: lastUsedAtEpochMs > 0
          ? DateTime.fromMillisecondsSinceEpoch(lastUsedAtEpochMs, isUtc: true)
          : null,
    );
  }

  static int _parseEpochMs(Object? rawValue) {
    if (rawValue is int) {
      return rawValue;
    }
    return int.tryParse(rawValue?.toString() ?? '') ?? 0;
  }
}

class _PendingOAuthSession {
  const _PendingOAuthSession({
    required this.provider,
    required this.state,
    required this.startedAt,
  });

  final String provider;
  final String state;
  final DateTime startedAt;
}

class AuthService {
  AuthService({
    BackchatApiClient? apiService,
    BrowserUrlLauncher? urlLauncher,
    BrowserProcessLauncher? processLauncher,
    BrowserLaunchPlatform? browserPlatform,
  })  : _apiService = apiService ?? BackchatApiService(),
        _urlLauncher = urlLauncher ?? _defaultUrlLauncher,
        _processLauncher = processLauncher ?? _defaultProcessLauncher,
        _browserPlatform = browserPlatform ?? _detectBrowserLaunchPlatform();

  static const String _usernameAccountsStorageKey = 'username_accounts_v1';
  static const String _authenticatedUserStorageKey = 'authenticated_user_v1';
  static const String _pendingOAuthStateStorageKey = 'pending_oauth_state_v1';
  static const String _pendingOAuthProviderStorageKey =
      'pending_oauth_provider_v1';
  static const String _pendingOAuthStartedAtStorageKey =
      'pending_oauth_started_at_v1';
  static final RegExp _usernamePattern = RegExp(r'^[a-zA-Z0-9_]{3,24}$');
  static final RegExp _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
  static const Duration _oauthPollInterval = Duration(seconds: 2);
  static const int _oauthMaxPollAttempts = 90;
  static const int _oauthResumePollAttempts = 6;
  static const Duration _pendingOAuthLifetime = Duration(minutes: 12);

  final BackchatApiClient _apiService;
  final BrowserUrlLauncher _urlLauncher;
  final BrowserProcessLauncher _processLauncher;
  final BrowserLaunchPlatform _browserPlatform;

  bool get isRemoteApiEnabled => _apiService.isConfigured;

  Future<AppUser?> tryRestoreAuthenticatedUser() async {
    final AppUser? cachedUser = await _readAuthenticatedUser();
    if (!_apiService.isConfigured) {
      return cachedUser;
    }

    try {
      final AppUser user = await _apiService.fetchMyProfile();
      await rememberAuthenticatedUser(user);
      return user;
    } on BackchatApiException catch (e) {
      if (e.status == 'unauthorized') {
        await clearRememberedAuthenticatedUser();
        return null;
      }
      return cachedUser;
    } catch (_) {
      return cachedUser;
    }
  }

  Future<AppUser?> tryResumePendingSocialSignIn() async {
    if (!_apiService.isConfigured) {
      return null;
    }

    final _PendingOAuthSession? pending = await _readPendingOAuthSession();
    if (pending == null) {
      return null;
    }

    final DateTime expiresAt =
        pending.startedAt.toUtc().add(_pendingOAuthLifetime);
    if (DateTime.now().toUtc().isAfter(expiresAt)) {
      await _clearPendingOAuthSession();
      return null;
    }

    try {
      final AppUser? user = await _pollSocialOAuthState(
        pending.state,
        maxAttempts: _oauthResumePollAttempts,
      );
      if (user != null) {
        await rememberAuthenticatedUser(user);
        await _clearPendingOAuthSession();
      }
      return user;
    } on BackchatApiException catch (e) {
      if (e.status == 'failed' ||
          e.status == 'expired' ||
          e.status == 'oauth_state_not_found' ||
          e.status == 'oauth_timeout') {
        await _clearPendingOAuthSession();
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  bool isValidUsernameFormat(String username) {
    return _usernamePattern.hasMatch(username.trim());
  }

  Future<List<RememberedUsernameAccount>>
      loadRememberedUsernameAccounts() async {
    final List<_UsernameAccount> accounts = await _readUsernameAccounts();
    return accounts
        .map((_UsernameAccount account) => account.toRememberedAccount())
        .toList(growable: false);
  }

  Future<UsernameSignInResult> signInOrCreateWithUsername({
    required String username,
    required String recoveryEmail,
    required String password,
  }) async {
    final String cleanedUsername = username.trim();
    final String cleanedRecoveryEmail = recoveryEmail.trim();
    final String submittedPassword = password;
    if (_apiService.isConfigured) {
      try {
        final Map<String, dynamic> response =
            await _apiService.signInOrCreateWithUsername(
          username: cleanedUsername,
          recoveryEmail: cleanedRecoveryEmail,
          password: submittedPassword,
        );
        final String status = response['status']?.toString() ?? '';
        final AppUser? user = response['user'] is Map<String, dynamic>
            ? _apiUserToAppUser(response['user'] as Map<String, dynamic>)
            : null;
        if (status == 'signed_in') {
          await _rememberUsernameAccount(
            username: user?.username.isNotEmpty == true
                ? user!.username
                : cleanedUsername,
            recoveryEmail: cleanedRecoveryEmail,
            password: submittedPassword,
          );
          if (user != null) {
            await rememberAuthenticatedUser(user);
          }
          return UsernameSignInResult(
            status: UsernameSignInStatus.signedIn,
            user: user,
          );
        }
        if (status == 'password_set') {
          await _rememberUsernameAccount(
            username: user?.username.isNotEmpty == true
                ? user!.username
                : cleanedUsername,
            recoveryEmail: cleanedRecoveryEmail,
            password: submittedPassword,
          );
          if (user != null) {
            await rememberAuthenticatedUser(user);
          }
          return UsernameSignInResult(
            status: UsernameSignInStatus.passwordSet,
            user: user,
          );
        }
        if (status == 'created') {
          await _rememberUsernameAccount(
            username: user?.username.isNotEmpty == true
                ? user!.username
                : cleanedUsername,
            recoveryEmail: cleanedRecoveryEmail,
            password: submittedPassword,
          );
          if (user != null) {
            await rememberAuthenticatedUser(user);
          }
          return UsernameSignInResult(
            status: UsernameSignInStatus.created,
            user: user,
          );
        }
        return _signInOrCreateWithUsernameLocal(
          username: cleanedUsername,
          recoveryEmail: cleanedRecoveryEmail,
          password: submittedPassword,
        );
      } on BackchatApiException catch (e) {
        if (e.status == 'invalid_username') {
          return const UsernameSignInResult(
            status: UsernameSignInStatus.invalidUsername,
          );
        }
        if (e.status == 'username_needs_recovery_email') {
          return const UsernameSignInResult(
            status: UsernameSignInStatus.usernameNeedsRecoveryEmail,
          );
        }
        if (e.status == 'invalid_recovery_email') {
          return const UsernameSignInResult(
            status: UsernameSignInStatus.invalidRecoveryEmail,
          );
        }
        if (e.status == 'invalid_password') {
          return const UsernameSignInResult(
            status: UsernameSignInStatus.invalidPassword,
          );
        }
        if (e.status == 'password_required') {
          return const UsernameSignInResult(
            status: UsernameSignInStatus.passwordRequired,
          );
        }
        if (e.status == 'password_incorrect') {
          return const UsernameSignInResult(
            status: UsernameSignInStatus.passwordIncorrect,
          );
        }
        if (e.status == 'password_setup_needs_recovery_email') {
          return const UsernameSignInResult(
            status: UsernameSignInStatus.passwordSetupNeedsRecoveryEmail,
          );
        }
        if (e.status == 'recovery_email_mismatch') {
          return const UsernameSignInResult(
            status: UsernameSignInStatus.recoveryEmailMismatch,
          );
        }
        if (e.status == 'recovery_email_already_in_use') {
          return UsernameSignInResult(
            status: UsernameSignInStatus.recoveryEmailAlreadyInUse,
            linkedUsername: e.payload?['linkedUsername']?.toString(),
          );
        }
        return _signInOrCreateWithUsernameLocal(
          username: cleanedUsername,
          recoveryEmail: cleanedRecoveryEmail,
          password: submittedPassword,
        );
      } catch (_) {
        return _signInOrCreateWithUsernameLocal(
          username: cleanedUsername,
          recoveryEmail: cleanedRecoveryEmail,
          password: submittedPassword,
        );
      }
    }

    return _signInOrCreateWithUsernameLocal(
      username: cleanedUsername,
      recoveryEmail: cleanedRecoveryEmail,
      password: submittedPassword,
    );
  }

  Future<UsernameSignInResult> _signInOrCreateWithUsernameLocal({
    required String username,
    required String recoveryEmail,
    required String password,
  }) async {
    final String cleanedUsername = username.trim();
    final String normalizedUsername = cleanedUsername.toLowerCase();
    if (!_usernamePattern.hasMatch(cleanedUsername)) {
      return const UsernameSignInResult(
          status: UsernameSignInStatus.invalidUsername);
    }

    final List<_UsernameAccount> accounts = await _readUsernameAccounts();
    _UsernameAccount? existing;
    for (final _UsernameAccount account in accounts) {
      if (account.normalizedUsername == normalizedUsername) {
        existing = account;
        break;
      }
    }
    if (existing != null) {
      if (existing.passwordHash.isNotEmpty) {
        if (password.isEmpty) {
          return const UsernameSignInResult(
            status: UsernameSignInStatus.passwordRequired,
          );
        }
        if (!bcValidatePassword(password)) {
          return const UsernameSignInResult(
            status: UsernameSignInStatus.invalidPassword,
          );
        }
        final String submittedHash =
            await _localPasswordHash(normalizedUsername, password);
        if (submittedHash != existing.passwordHash) {
          return const UsernameSignInResult(
            status: UsernameSignInStatus.passwordIncorrect,
          );
        }
        await _rememberUsernameAccount(
          username: existing.username,
          recoveryEmail: existing.recoveryEmail,
          password: password,
        );
        final AppUser user = _toAppUser(existing);
        await rememberAuthenticatedUser(user);
        return UsernameSignInResult(
          status: UsernameSignInStatus.signedIn,
          user: user,
        );
      }

      if (password.isNotEmpty) {
        if (!bcValidatePassword(password)) {
          return const UsernameSignInResult(
            status: UsernameSignInStatus.invalidPassword,
          );
        }
        final String cleanedEmail = recoveryEmail.trim();
        if (cleanedEmail.isEmpty) {
          return const UsernameSignInResult(
            status: UsernameSignInStatus.passwordSetupNeedsRecoveryEmail,
          );
        }
        if (!_emailPattern.hasMatch(cleanedEmail)) {
          return const UsernameSignInResult(
            status: UsernameSignInStatus.invalidRecoveryEmail,
          );
        }
        if (cleanedEmail.toLowerCase() !=
            existing.recoveryEmail.toLowerCase()) {
          return const UsernameSignInResult(
            status: UsernameSignInStatus.recoveryEmailMismatch,
          );
        }
        await _rememberUsernameAccount(
          username: existing.username,
          recoveryEmail: existing.recoveryEmail,
          password: password,
        );
        final AppUser user = _toAppUser(existing);
        await rememberAuthenticatedUser(user);
        return UsernameSignInResult(
          status: UsernameSignInStatus.passwordSet,
          user: user,
        );
      }

      await _rememberUsernameAccount(
        username: existing.username,
        recoveryEmail: existing.recoveryEmail,
        password: '',
      );
      final AppUser user = _toAppUser(existing);
      await rememberAuthenticatedUser(user);
      return UsernameSignInResult(
        status: UsernameSignInStatus.signedIn,
        user: user,
      );
    }

    final String cleanedEmail = recoveryEmail.trim();
    if (cleanedEmail.isEmpty) {
      return const UsernameSignInResult(
          status: UsernameSignInStatus.usernameNeedsRecoveryEmail);
    }
    if (!_emailPattern.hasMatch(cleanedEmail)) {
      return const UsernameSignInResult(
          status: UsernameSignInStatus.invalidRecoveryEmail);
    }
    if (password.isNotEmpty && !bcValidatePassword(password)) {
      return const UsernameSignInResult(
        status: UsernameSignInStatus.invalidPassword,
      );
    }

    final String normalizedEmail = cleanedEmail.toLowerCase();
    _UsernameAccount? existingForEmail;
    for (final _UsernameAccount account in accounts) {
      if (account.recoveryEmail.toLowerCase() == normalizedEmail) {
        existingForEmail = account;
        break;
      }
    }
    if (existingForEmail != null) {
      return UsernameSignInResult(
        status: UsernameSignInStatus.recoveryEmailAlreadyInUse,
        linkedUsername: existingForEmail.username,
      );
    }

    final _UsernameAccount created = _UsernameAccount(
      username: cleanedUsername,
      normalizedUsername: normalizedUsername,
      recoveryEmail: cleanedEmail,
      passwordHash: password.isNotEmpty
          ? await _localPasswordHash(normalizedUsername, password)
          : '',
      lastUsedAtEpochMs: DateTime.now().toUtc().millisecondsSinceEpoch,
    );
    await _rememberUsernameAccount(
      username: created.username,
      recoveryEmail: created.recoveryEmail,
      password: password,
    );
    final AppUser user = _toAppUser(created);
    await rememberAuthenticatedUser(user);

    return UsernameSignInResult(
      status: UsernameSignInStatus.created,
      user: user,
    );
  }

  Future<String?> recoverUsernameForEmail(String email) async {
    if (_apiService.isConfigured) {
      try {
        return await _apiService.recoverUsernameForEmail(email);
      } catch (_) {
        // Fall through to local recovery cache.
      }
    }

    return _recoverUsernameForEmailLocal(email);
  }

  Future<String?> _recoverUsernameForEmailLocal(String email) async {
    final String cleaned = email.trim().toLowerCase();
    if (!_emailPattern.hasMatch(cleaned)) return null;

    final List<_UsernameAccount> accounts = await _readUsernameAccounts();
    _UsernameAccount? account;
    for (final _UsernameAccount current in accounts) {
      if (current.recoveryEmail.toLowerCase() == cleaned) {
        account = current;
        break;
      }
    }
    return account?.username;
  }

  Future<AppUser?> findUserByUsername(String username) async {
    if (_apiService.isConfigured) return null;
    final String cleanedUsername = username.trim();
    final String normalizedUsername = cleanedUsername.toLowerCase();
    if (!isValidUsernameFormat(cleanedUsername)) {
      return null;
    }

    final List<_UsernameAccount> accounts = await _readUsernameAccounts();
    for (final _UsernameAccount account in accounts) {
      if (account.normalizedUsername == normalizedUsername) {
        return _toAppUser(account);
      }
    }
    return null;
  }

  Future<AppUser?> signInWithGoogle() async {
    return _signInWithSocialProvider('google');
  }

  Future<AppUser?> signInWithFacebook() async {
    return _signInWithSocialProvider('facebook');
  }

  Future<AppUser?> signInWithX() async {
    return _signInWithSocialProvider('x');
  }

  Future<String?> socialOAuthStartupWarning() async {
    if (!_apiService.isConfigured) {
      return 'Social login needs BACKCHAT_API_BASE_URL configured in this build.';
    }
    try {
      final SocialOAuthProbeResult probe = await _apiService.probeSocialOAuth();
      if (probe.oauthReady) return null;
      return probe.message;
    } on BackchatApiException catch (e) {
      return e.message;
    } catch (_) {
      return 'Could not verify social login readiness.';
    }
  }

  Future<void> signOut(AppUser user) async {
    await _apiService.clearToken();
    await _clearPendingOAuthSession();
    await clearRememberedAuthenticatedUser();
  }

  Future<void> rememberAuthenticatedUser(AppUser user) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _authenticatedUserStorageKey,
      jsonEncode(_appUserToJson(user)),
    );
  }

  Future<void> clearRememberedAuthenticatedUser() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_authenticatedUserStorageKey);
  }

  Future<List<_UsernameAccount>> _readUsernameAccounts() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_usernameAccountsStorageKey);
    if (raw == null || raw.isEmpty) return <_UsernameAccount>[];

    final Object? decoded = jsonDecode(raw);
    if (decoded is! List<dynamic>) return <_UsernameAccount>[];

    return decoded
        .whereType<Map<String, dynamic>>()
        .map(_UsernameAccount.fromJson)
        .where(
          (_UsernameAccount account) =>
              account.username.isNotEmpty &&
              account.normalizedUsername.isNotEmpty &&
              account.recoveryEmail.isNotEmpty,
        )
        .toList()
      ..sort(
        (_UsernameAccount a, _UsernameAccount b) =>
            b.lastUsedAtEpochMs.compareTo(a.lastUsedAtEpochMs),
      );
  }

  Future<void> _writeUsernameAccounts(List<_UsernameAccount> accounts) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String payload = jsonEncode(
      accounts.map((_UsernameAccount account) => account.toJson()).toList(),
    );
    await prefs.setString(_usernameAccountsStorageKey, payload);
  }

  Future<void> _rememberUsernameAccount({
    required String username,
    required String recoveryEmail,
    required String password,
  }) async {
    final String cleanedUsername = username.trim();
    final String normalizedUsername = cleanedUsername.toLowerCase();
    if (!_usernamePattern.hasMatch(cleanedUsername)) {
      return;
    }

    final List<_UsernameAccount> accounts = await _readUsernameAccounts();
    final int existingIndex = accounts.indexWhere(
      (_UsernameAccount account) =>
          account.normalizedUsername == normalizedUsername,
    );
    final String cleanedEmail = recoveryEmail.trim();
    final int nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    String? nextPasswordHash;
    if (password.isNotEmpty && bcValidatePassword(password)) {
      nextPasswordHash = await _localPasswordHash(normalizedUsername, password);
    }

    if (existingIndex >= 0) {
      final _UsernameAccount existing = accounts.removeAt(existingIndex);
      accounts.insert(
        0,
        existing.copyWith(
          username: cleanedUsername,
          normalizedUsername: normalizedUsername,
          recoveryEmail:
              cleanedEmail.isNotEmpty ? cleanedEmail : existing.recoveryEmail,
          passwordHash: nextPasswordHash ?? existing.passwordHash,
          lastUsedAtEpochMs: nowMs,
        ),
      );
      await _writeUsernameAccounts(accounts);
      return;
    }

    if (!_emailPattern.hasMatch(cleanedEmail)) {
      return;
    }

    accounts.insert(
      0,
      _UsernameAccount(
        username: cleanedUsername,
        normalizedUsername: normalizedUsername,
        recoveryEmail: cleanedEmail,
        passwordHash: nextPasswordHash ?? '',
        lastUsedAtEpochMs: nowMs,
      ),
    );
    await _writeUsernameAccounts(accounts);
  }

  bool bcValidatePassword(String password) {
    return password.length >= 8 && password.length <= 72;
  }

  Future<String> _localPasswordHash(
    String normalizedUsername,
    String password,
  ) async {
    final HashAlgorithm hashAlgorithm = Sha256();
    final Hash digest = await hashAlgorithm.hash(
      utf8.encode('backchat-local:$normalizedUsername:$password'),
    );
    return base64UrlEncode(digest.bytes);
  }

  AppUser _toAppUser(_UsernameAccount account) {
    return AppUser(
      id: 'username:${account.normalizedUsername}',
      displayName: account.username,
      avatarUrl: '',
      provider: AuthProvider.username,
      username: account.username,
      quote: '',
    );
  }

  AppUser _apiUserToAppUser(Map<String, dynamic> json) {
    final String username =
        json['username']?.toString() ?? json['displayName']?.toString() ?? '';
    final String displayName =
        json['displayName']?.toString() ?? json['username']?.toString() ?? '';
    final String normalizedUsername = username.toLowerCase();
    final String providerName =
        json['provider']?.toString() ?? AuthProvider.username.name;
    final AuthProvider provider = AuthProvider.values.firstWhere(
      (AuthProvider value) => value.name == providerName,
      orElse: () => AuthProvider.username,
    );
    return AppUser(
      id: json['id']?.toString() ?? 'username:$normalizedUsername',
      displayName: displayName,
      avatarUrl: json['avatarUrl']?.toString() ?? '',
      provider: provider,
      username: username,
      quote: json['quote']?.toString() ?? '',
      status: PresenceStatus.online,
    );
  }

  Map<String, dynamic> _appUserToJson(AppUser user) {
    return <String, dynamic>{
      'id': user.id,
      'displayName': user.displayName,
      'avatarUrl': user.avatarUrl,
      'provider': user.provider.name,
      'username': user.username,
      'quote': user.quote,
      'status': user.status.name,
      'lastSeenAtUtc': user.lastSeenAt?.toUtc().toIso8601String(),
    };
  }

  AppUser _appUserFromJson(Map<String, dynamic> json) {
    final String providerName =
        json['provider']?.toString() ?? AuthProvider.username.name;
    final String statusName =
        json['status']?.toString() ?? PresenceStatus.online.name;
    final AuthProvider provider = AuthProvider.values.firstWhere(
      (AuthProvider value) => value.name == providerName,
      orElse: () => AuthProvider.username,
    );
    final PresenceStatus status = PresenceStatus.values.firstWhere(
      (PresenceStatus value) => value.name == statusName,
      orElse: () => PresenceStatus.online,
    );
    return AppUser(
      id: json['id']?.toString() ?? '',
      displayName: json['displayName']?.toString() ?? '',
      avatarUrl: json['avatarUrl']?.toString() ?? '',
      provider: provider,
      username: json['username']?.toString() ?? '',
      quote: json['quote']?.toString() ?? '',
      status: status,
      lastSeenAt:
          DateTime.tryParse(json['lastSeenAtUtc']?.toString() ?? '')?.toLocal(),
    );
  }

  Future<AppUser?> _signInWithSocialProvider(String provider) async {
    if (!_apiService.isConfigured) {
      throw const BackchatApiException(
        status: 'api_not_configured',
        message: 'Social login requires BACKCHAT_API_BASE_URL in this build.',
      );
    }
    final SocialOAuthStartResult start =
        await _apiService.startSocialOAuth(provider);
    await _writePendingOAuthSession(
      provider: provider,
      state: start.state,
    );
    final Uri uri = Uri.parse(start.authorizationUrl);
    final bool launched = await _launchBrowser(uri);
    if (!launched) {
      throw SocialOAuthLaunchException(
        provider: provider,
        authorizationUri: uri,
      );
    }

    try {
      final AppUser? user = await _pollSocialOAuthState(start.state);
      await _clearPendingOAuthSession();
      if (user != null) {
        await rememberAuthenticatedUser(user);
      }
      return user;
    } on BackchatApiException catch (e) {
      if (e.status == 'failed' ||
          e.status == 'expired' ||
          e.status == 'oauth_timeout') {
        await _clearPendingOAuthSession();
      }
      rethrow;
    }
  }

  Future<AppUser?> _pollSocialOAuthState(
    String state, {
    int maxAttempts = _oauthMaxPollAttempts,
  }) async {
    for (int i = 0; i < maxAttempts; i++) {
      await Future<void>.delayed(_oauthPollInterval);
      final SocialOAuthPollResult poll =
          await _apiService.pollSocialOAuth(state);
      if (poll.status == 'authorized') {
        return poll.user;
      }
      if (poll.status == 'failed' || poll.status == 'expired') {
        throw BackchatApiException(
          status: poll.status,
          message: poll.error ?? 'OAuth sign-in failed.',
        );
      }
      if (poll.status == 'pending') {
        continue;
      }
      throw BackchatApiException(
        status: 'oauth_unexpected_status',
        message: 'Unexpected OAuth poll status: ${poll.status}',
      );
    }

    throw const BackchatApiException(
      status: 'oauth_timeout',
      message: 'OAuth login timed out before completion.',
    );
  }

  Future<void> _writePendingOAuthSession({
    required String provider,
    required String state,
  }) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pendingOAuthProviderStorageKey, provider);
    await prefs.setString(_pendingOAuthStateStorageKey, state);
    await prefs.setInt(
      _pendingOAuthStartedAtStorageKey,
      DateTime.now().toUtc().millisecondsSinceEpoch,
    );
  }

  Future<_PendingOAuthSession?> _readPendingOAuthSession() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String provider =
        prefs.getString(_pendingOAuthProviderStorageKey)?.trim() ?? '';
    final String state =
        prefs.getString(_pendingOAuthStateStorageKey)?.trim() ?? '';
    final int startedAtEpochMs =
        prefs.getInt(_pendingOAuthStartedAtStorageKey) ?? 0;
    if (provider.isEmpty || state.isEmpty || startedAtEpochMs <= 0) {
      return null;
    }

    return _PendingOAuthSession(
      provider: provider,
      state: state,
      startedAt:
          DateTime.fromMillisecondsSinceEpoch(startedAtEpochMs, isUtc: true),
    );
  }

  Future<void> _clearPendingOAuthSession() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingOAuthProviderStorageKey);
    await prefs.remove(_pendingOAuthStateStorageKey);
    await prefs.remove(_pendingOAuthStartedAtStorageKey);
  }

  Future<AppUser?> _readAuthenticatedUser() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_authenticatedUserStorageKey);
    if (raw == null || raw.isEmpty) {
      return null;
    }

    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      return _appUserFromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  Future<bool> _launchBrowser(Uri uri) async {
    switch (_browserPlatform) {
      case BrowserLaunchPlatform.windows:
        if (await _urlLauncher(uri, LaunchMode.externalApplication)) {
          return true;
        }
        if (await _processLauncher('rundll32.exe', <String>[
          'url.dll,FileProtocolHandler',
          uri.toString(),
        ])) {
          return true;
        }
        if (await _processLauncher('explorer.exe', <String>[uri.toString()])) {
          return true;
        }
        return false;
      case BrowserLaunchPlatform.macos:
        if (await _processLauncher('open', <String>[uri.toString()])) {
          return true;
        }
        break;
      case BrowserLaunchPlatform.linux:
        if (await _processLauncher('xdg-open', <String>[uri.toString()])) {
          return true;
        }
        break;
      case BrowserLaunchPlatform.web:
      case BrowserLaunchPlatform.other:
        break;
    }

    return _urlLauncher(uri, LaunchMode.externalApplication);
  }

  static BrowserLaunchPlatform _detectBrowserLaunchPlatform() {
    if (kIsWeb) {
      return BrowserLaunchPlatform.web;
    }
    if (Platform.isWindows) {
      return BrowserLaunchPlatform.windows;
    }
    if (Platform.isMacOS) {
      return BrowserLaunchPlatform.macos;
    }
    if (Platform.isLinux) {
      return BrowserLaunchPlatform.linux;
    }
    return BrowserLaunchPlatform.other;
  }

  static Future<bool> _defaultUrlLauncher(Uri uri, LaunchMode mode) {
    return launchUrl(uri, mode: mode);
  }

  static Future<bool> _defaultProcessLauncher(
    String executable,
    List<String> arguments,
  ) async {
    try {
      await Process.start(executable, arguments);
      return true;
    } catch (_) {
      return false;
    }
  }
}
