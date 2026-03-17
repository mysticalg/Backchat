import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_user.dart';
import 'backchat_api_service.dart';

enum UsernameSignInStatus {
  signedIn,
  created,
  invalidUsername,
  usernameNeedsRecoveryEmail,
  invalidRecoveryEmail,
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

class _UsernameAccount {
  const _UsernameAccount({
    required this.username,
    required this.normalizedUsername,
    required this.recoveryEmail,
  });

  final String username;
  final String normalizedUsername;
  final String recoveryEmail;

  factory _UsernameAccount.fromJson(Map<String, dynamic> json) {
    return _UsernameAccount(
      username: json['username']?.toString() ?? '',
      normalizedUsername: json['normalizedUsername']?.toString() ?? '',
      recoveryEmail: json['recoveryEmail']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'username': username,
      'normalizedUsername': normalizedUsername,
      'recoveryEmail': recoveryEmail,
    };
  }
}

class AuthService {
  AuthService({BackchatApiClient? apiService})
      : _apiService = apiService ?? BackchatApiService();

  static const String _usernameAccountsStorageKey = 'username_accounts_v1';
  static final RegExp _usernamePattern = RegExp(r'^[a-zA-Z0-9_]{3,24}$');
  static final RegExp _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  final GoogleSignIn _googleSignIn =
      GoogleSignIn(scopes: <String>['email', 'profile']);
  final BackchatApiClient _apiService;

  bool get isRemoteApiEnabled => _apiService.isConfigured;

  bool isValidUsernameFormat(String username) {
    return _usernamePattern.hasMatch(username.trim());
  }

  Future<UsernameSignInResult> signInOrCreateWithUsername({
    required String username,
    required String recoveryEmail,
  }) async {
    if (_apiService.isConfigured) {
      try {
        final Map<String, dynamic> response =
            await _apiService.signInOrCreateWithUsername(
          username: username,
          recoveryEmail: recoveryEmail,
        );
        final String status = response['status']?.toString() ?? '';
        final AppUser? user = response['user'] is Map<String, dynamic>
            ? _apiUserToAppUser(response['user'] as Map<String, dynamic>)
            : null;
        if (status == 'signed_in') {
          return UsernameSignInResult(
            status: UsernameSignInStatus.signedIn,
            user: user,
          );
        }
        if (status == 'created') {
          return UsernameSignInResult(
            status: UsernameSignInStatus.created,
            user: user,
          );
        }
        return _signInOrCreateWithUsernameLocal(
          username: username,
          recoveryEmail: recoveryEmail,
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
        if (e.status == 'recovery_email_already_in_use') {
          return UsernameSignInResult(
            status: UsernameSignInStatus.recoveryEmailAlreadyInUse,
            linkedUsername: e.payload?['linkedUsername']?.toString(),
          );
        }
        return _signInOrCreateWithUsernameLocal(
          username: username,
          recoveryEmail: recoveryEmail,
        );
      } catch (_) {
        return _signInOrCreateWithUsernameLocal(
          username: username,
          recoveryEmail: recoveryEmail,
        );
      }
    }

    return _signInOrCreateWithUsernameLocal(
      username: username,
      recoveryEmail: recoveryEmail,
    );
  }

  Future<UsernameSignInResult> _signInOrCreateWithUsernameLocal({
    required String username,
    required String recoveryEmail,
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
      return UsernameSignInResult(
        status: UsernameSignInStatus.signedIn,
        user: _toAppUser(existing),
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
    );
    accounts.add(created);
    await _writeUsernameAccounts(accounts);

    return UsernameSignInResult(
      status: UsernameSignInStatus.created,
      user: _toAppUser(created),
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
    try {
      final GoogleSignInAccount? account = await _googleSignIn.signIn();
      if (account == null) return null;

      return AppUser(
        id: account.id,
        displayName: account.displayName ?? 'Google User',
        avatarUrl: account.photoUrl ?? '',
        provider: AuthProvider.google,
      );
    } catch (_) {
      if (!_isDesktop) rethrow;
      return _desktopDemoUser(provider: AuthProvider.google);
    }
  }

  Future<AppUser?> signInWithFacebook() async {
    return _desktopDemoUser(provider: AuthProvider.facebook);
  }

  Future<void> signOut(AppUser user) async {
    await _apiService.clearToken();
    if (user.provider == AuthProvider.google) {
      await _googleSignIn.signOut();
    }
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
        .toList();
  }

  Future<void> _writeUsernameAccounts(List<_UsernameAccount> accounts) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String payload = jsonEncode(
      accounts.map((_UsernameAccount account) => account.toJson()).toList(),
    );
    await prefs.setString(_usernameAccountsStorageKey, payload);
  }

  AppUser _toAppUser(_UsernameAccount account) {
    return AppUser(
      id: 'username:${account.normalizedUsername}',
      displayName: account.username,
      avatarUrl: '',
      provider: AuthProvider.username,
    );
  }

  AppUser _apiUserToAppUser(Map<String, dynamic> json) {
    final String username =
        json['username']?.toString() ?? json['displayName']?.toString() ?? '';
    final String normalizedUsername = username.toLowerCase();
    return AppUser(
      id: json['id']?.toString() ?? 'username:$normalizedUsername',
      displayName: username,
      avatarUrl: json['avatarUrl']?.toString() ?? '',
      provider: AuthProvider.username,
      status: PresenceStatus.online,
    );
  }

  bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  AppUser _desktopDemoUser({required AuthProvider provider}) {
    final String name = provider == AuthProvider.google
        ? 'Google Demo User'
        : 'Facebook Demo User';
    final String id = provider == AuthProvider.google
        ? 'demo-google-user'
        : 'demo-facebook-user';
    return AppUser(
        id: id, displayName: name, avatarUrl: '', provider: provider);
  }
}
