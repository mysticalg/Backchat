import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_user.dart';
import '../models/chat_message.dart';

class BackchatApiException implements Exception {
  const BackchatApiException({
    required this.status,
    required this.message,
    this.payload,
  });

  final String status;
  final String message;
  final Map<String, dynamic>? payload;

  @override
  String toString() =>
      'BackchatApiException(status: $status, message: $message)';
}

class SocialOAuthStartResult {
  const SocialOAuthStartResult({
    required this.state,
    required this.authorizationUrl,
  });

  final String state;
  final String authorizationUrl;
}

class SocialOAuthPollResult {
  const SocialOAuthPollResult({
    required this.status,
    this.user,
    this.error,
  });

  final String status;
  final AppUser? user;
  final String? error;
}

class SocialOAuthProbeResult {
  const SocialOAuthProbeResult({
    required this.oauthReady,
    required this.message,
    required this.curlAvailable,
    required this.schemaReady,
    required this.googleConfigured,
    required this.facebookConfigured,
    required this.xConfigured,
  });

  final bool oauthReady;
  final String message;
  final bool curlAvailable;
  final bool schemaReady;
  final bool googleConfigured;
  final bool facebookConfigured;
  final bool xConfigured;
}

class PollMessagesResult {
  const PollMessagesResult({
    required this.nextSinceId,
    required this.messages,
  });

  final int nextSinceId;
  final List<ChatMessage> messages;
}

abstract class BackchatApiClient {
  bool get isConfigured;

  Future<Map<String, dynamic>> signInOrCreateWithUsername({
    required String username,
    required String recoveryEmail,
  });

  Future<String?> recoverUsernameForEmail(String recoveryEmail);

  Future<List<AppUser>> fetchContacts();

  Future<Map<String, dynamic>> inviteByUsername(String username);

  Future<SocialOAuthStartResult> startSocialOAuth(String provider);

  Future<SocialOAuthPollResult> pollSocialOAuth(String state);

  Future<SocialOAuthProbeResult> probeSocialOAuth();

  Future<void> sendMessage({
    required String toUsername,
    required String cipherText,
    String? clientMessageId,
  });

  Future<PollMessagesResult> pollMessages({
    int sinceId,
    int limit,
    required String currentUserId,
  });

  Future<void> clearToken();
}

class BackchatApiService implements BackchatApiClient {
  BackchatApiService({http.Client? client}) : _client = client ?? http.Client();

  static const String _tokenStorageKey = 'backchat_api_token_v1';
  static const String _defaultApiBaseUrl =
      'http://backchat-env.eba-2eqqcpgj.eu-west-2.elasticbeanstalk.com';
  static const String _configuredApiBaseUrl =
      String.fromEnvironment('BACKCHAT_API_BASE_URL');
  static const Duration _requestTimeout = Duration(seconds: 8);

  final http.Client _client;
  String? _cachedToken;

  String get _apiBaseUrl {
    final String configured = _configuredApiBaseUrl.trim();
    if (configured.isNotEmpty) {
      return configured;
    }
    return _defaultApiBaseUrl;
  }

  @override
  bool get isConfigured => _apiBaseUrl.trim().isNotEmpty;

  @override
  Future<Map<String, dynamic>> signInOrCreateWithUsername({
    required String username,
    required String recoveryEmail,
  }) async {
    final Map<String, dynamic> payload = await _postJson(
      '/auth_username.php',
      <String, dynamic>{
        'username': username,
        'recoveryEmail': recoveryEmail,
      },
      requiresAuth: false,
    );

    final String? token = payload['token']?.toString();
    if (token != null && token.isNotEmpty) {
      await _saveToken(token);
    }
    return payload;
  }

  @override
  Future<String?> recoverUsernameForEmail(String recoveryEmail) async {
    final Map<String, dynamic> payload = await _postJson(
      '/recover_username.php',
      <String, dynamic>{'recoveryEmail': recoveryEmail},
      requiresAuth: false,
    );
    return payload['username']?.toString();
  }

  @override
  Future<List<AppUser>> fetchContacts() async {
    final Map<String, dynamic> payload = await _getJson('/contacts.php');
    final List<dynamic> rows = payload['contacts'] is List<dynamic>
        ? payload['contacts'] as List<dynamic>
        : <dynamic>[];
    return rows
        .whereType<Map<String, dynamic>>()
        .map(_appUserFromApiMap)
        .toList();
  }

  @override
  Future<Map<String, dynamic>> inviteByUsername(String username) {
    return _postJson(
      '/invite_by_username.php',
      <String, dynamic>{'username': username},
      requiresAuth: true,
    );
  }

  @override
  Future<SocialOAuthStartResult> startSocialOAuth(String provider) async {
    final Map<String, dynamic> payload = await _postJson(
      '/auth_oauth_start.php',
      <String, dynamic>{'provider': provider},
      requiresAuth: false,
    );
    final String state = payload['state']?.toString() ?? '';
    final String authorizationUrl = payload['authorizationUrl']?.toString() ?? '';
    if (state.isEmpty || authorizationUrl.isEmpty) {
      throw const BackchatApiException(
        status: 'oauth_start_invalid',
        message: 'OAuth start response is missing fields.',
      );
    }
    return SocialOAuthStartResult(
      state: state,
      authorizationUrl: authorizationUrl,
    );
  }

  @override
  Future<SocialOAuthPollResult> pollSocialOAuth(String state) async {
    final Map<String, dynamic> payload = await _postJson(
      '/auth_oauth_poll.php',
      <String, dynamic>{'state': state},
      requiresAuth: false,
    );
    final String status = payload['status']?.toString() ?? '';
    if (status == 'authorized') {
      final String token = payload['token']?.toString() ?? '';
      if (token.isNotEmpty) {
        await _saveToken(token);
      }
      final AppUser? user = payload['user'] is Map<String, dynamic>
          ? _appUserFromApiMap(payload['user'] as Map<String, dynamic>)
          : null;
      return SocialOAuthPollResult(status: status, user: user);
    }

    return SocialOAuthPollResult(
      status: status,
      error: payload['error']?.toString(),
    );
  }

  @override
  Future<SocialOAuthProbeResult> probeSocialOAuth() async {
    final Map<String, dynamic> payload = await _getJson(
      '/oauth_probe.php',
      requiresAuth: false,
    );
    final Map<String, dynamic> runtime =
        payload['runtime'] is Map<String, dynamic>
            ? payload['runtime'] as Map<String, dynamic>
            : <String, dynamic>{};
    final Map<String, dynamic> providers =
        payload['providers'] is Map<String, dynamic>
            ? payload['providers'] as Map<String, dynamic>
            : <String, dynamic>{};

    bool configuredFor(String provider) {
      final Object? row = providers[provider];
      if (row is Map<String, dynamic>) {
        return row['configured'] == true;
      }
      return false;
    }

    return SocialOAuthProbeResult(
      oauthReady: payload['oauthReady'] == true,
      message: payload['message']?.toString() ?? 'OAuth probe complete.',
      curlAvailable: runtime['curlAvailable'] == true,
      schemaReady: runtime['schemaReady'] == true,
      googleConfigured: configuredFor('google'),
      facebookConfigured: configuredFor('facebook'),
      xConfigured: configuredFor('x'),
    );
  }

  @override
  Future<void> sendMessage({
    required String toUsername,
    required String cipherText,
    String? clientMessageId,
  }) async {
    await _postJson(
      '/send_message.php',
      <String, dynamic>{
        'toUsername': toUsername,
        'cipherText': cipherText,
        if (clientMessageId != null && clientMessageId.isNotEmpty)
          'clientMessageId': clientMessageId,
      },
    );
  }

  @override
  Future<PollMessagesResult> pollMessages({
    int sinceId = 0,
    int limit = 100,
    required String currentUserId,
  }) async {
    final int safeLimit = limit < 1 ? 1 : (limit > 200 ? 200 : limit);
    final Map<String, dynamic> payload = await _getJson(
      '/poll_messages.php?sinceId=$sinceId&limit=$safeLimit',
    );

    final List<dynamic> rows = payload['messages'] is List<dynamic>
        ? payload['messages'] as List<dynamic>
        : <dynamic>[];
    final List<ChatMessage> messages = rows
        .whereType<Map<String, dynamic>>()
        .map(
          (Map<String, dynamic> row) => ChatMessage(
            fromUserId: row['fromUserId']?.toString() ?? '',
            toUserId: currentUserId,
            cipherText: row['cipherText']?.toString() ?? '',
            sentAt: _parseApiUtcDateTime(
              row['sentAtUtc']?.toString(),
            ),
          ),
        )
        .where(
          (ChatMessage message) =>
              message.fromUserId.isNotEmpty && message.cipherText.isNotEmpty,
        )
        .toList();

    return PollMessagesResult(
      nextSinceId: payload['nextSinceId'] is int
          ? payload['nextSinceId'] as int
          : int.tryParse(payload['nextSinceId']?.toString() ?? '') ?? sinceId,
      messages: messages,
    );
  }

  @override
  Future<void> clearToken() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenStorageKey);
    _cachedToken = null;
  }

  Future<Map<String, dynamic>> _getJson(String path,
      {bool requiresAuth = true}) async {
    return _requestJson(
      method: 'GET',
      path: path,
      body: null,
      requiresAuth: requiresAuth,
    );
  }

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, dynamic> body, {
    bool requiresAuth = true,
  }) async {
    return _requestJson(
      method: 'POST',
      path: path,
      body: body,
      requiresAuth: requiresAuth,
    );
  }

  Future<Map<String, dynamic>> _requestJson({
    required String method,
    required String path,
    required Map<String, dynamic>? body,
    required bool requiresAuth,
  }) async {
    if (!isConfigured) {
      throw const BackchatApiException(
        status: 'api_not_configured',
        message: 'BACKCHAT_API_BASE_URL is not configured.',
      );
    }

    final Uri uri = Uri.parse('${_apiBaseUrl.trim()}$path');
    final Map<String, String> headers = <String, String>{
      'Content-Type': 'application/json',
    };

    if (requiresAuth) {
      final String? token = await _readToken();
      if (token == null || token.isEmpty) {
        throw const BackchatApiException(
          status: 'unauthorized',
          message: 'Missing auth token.',
        );
      }
      headers['Authorization'] = 'Bearer $token';
      headers['X-Auth-Token'] = token;
    }

    late final http.Response response;
    try {
      if (method == 'GET') {
        response =
            await _client.get(uri, headers: headers).timeout(_requestTimeout);
      } else {
        response = await _client
            .post(
              uri,
              headers: headers,
              body: jsonEncode(body ?? <String, dynamic>{}),
            )
            .timeout(_requestTimeout);
      }
    } on TimeoutException {
      throw const BackchatApiException(
        status: 'timeout',
        message: 'API request timed out.',
      );
    } catch (_) {
      throw const BackchatApiException(
        status: 'network_error',
        message: 'Could not connect to API.',
      );
    }

    Map<String, dynamic> decoded = <String, dynamic>{};
    if (response.body.isNotEmpty) {
      try {
        final Object? parsed = jsonDecode(response.body);
        if (parsed is Map<String, dynamic>) {
          decoded = parsed;
        }
      } on FormatException {
        throw BackchatApiException(
          status: 'invalid_api_response',
          message: _nonJsonApiResponseMessage(uri, response),
        );
      }
    }

    if (response.statusCode >= 400) {
      throw BackchatApiException(
        status: decoded['status']?.toString() ?? 'api_error',
        message: decoded['message']?.toString() ?? 'API request failed.',
        payload: decoded,
      );
    }
    return decoded;
  }

  String _nonJsonApiResponseMessage(Uri uri, http.Response response) {
    final String body = response.body;
    final String contentType = response.headers['content-type']?.toLowerCase() ?? '';

    final String loweredBody = body.toLowerCase();
    final bool looksLikeAntiBotInterstitial =
        loweredBody.contains('/aes.js') ||
        loweredBody.contains('site requires javascript to work') ||
        loweredBody.contains('__test=');

    if (looksLikeAntiBotInterstitial) {
      return 'API returned a JavaScript anti-bot/interstitial page instead of JSON at $uri. '
          'This host blocks app HTTP clients, so social login cannot start. '
          'Move the API to a host without this protection.';
    }

    final bool looksLikeHtml =
        contentType.contains('text/html') || loweredBody.trimLeft().startsWith('<');
    if (looksLikeHtml) {
      return 'API returned HTML instead of JSON at $uri. '
          'Check BACKCHAT_API_BASE_URL and ensure it points to the API root URL '
          '(for example http://backchat-env.eba-2eqqcpgj.eu-west-2.elasticbeanstalk.com).';
    }

    return 'API did not return JSON at $uri.';
  }

  Future<void> _saveToken(String token) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenStorageKey, token);
    _cachedToken = token;
  }

  Future<String?> _readToken() async {
    if (_cachedToken != null) return _cachedToken;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    _cachedToken = prefs.getString(_tokenStorageKey);
    return _cachedToken;
  }

  AppUser _appUserFromApiMap(Map<String, dynamic> json) {
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
      status: PresenceStatus.online,
    );
  }

  DateTime _parseApiUtcDateTime(String? value) {
    final String normalized = (value ?? '').trim();
    if (normalized.isEmpty) {
      return DateTime.now().toUtc();
    }

    try {
      return DateTime.parse('${normalized.replaceFirst(' ', 'T')}Z').toLocal();
    } on FormatException {
      return DateTime.now();
    }
  }
}
