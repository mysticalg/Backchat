import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_user.dart';

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

abstract class BackchatApiClient {
  bool get isConfigured;

  Future<Map<String, dynamic>> signInOrCreateWithUsername({
    required String username,
    required String recoveryEmail,
  });

  Future<String?> recoverUsernameForEmail(String recoveryEmail);

  Future<List<AppUser>> fetchContacts();

  Future<Map<String, dynamic>> inviteByUsername(String username);

  Future<void> clearToken();
}

class BackchatApiService implements BackchatApiClient {
  BackchatApiService({http.Client? client}) : _client = client ?? http.Client();

  static const String _tokenStorageKey = 'backchat_api_token_v1';
  static const String _apiBaseUrl =
      String.fromEnvironment('BACKCHAT_API_BASE_URL');
  static const Duration _requestTimeout = Duration(seconds: 8);

  final http.Client _client;
  String? _cachedToken;

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
      final Object? parsed = jsonDecode(response.body);
      if (parsed is Map<String, dynamic>) {
        decoded = parsed;
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
    final String normalizedUsername = username.toLowerCase();
    return AppUser(
      id: json['id']?.toString() ?? 'username:$normalizedUsername',
      displayName: username,
      avatarUrl: json['avatarUrl']?.toString() ?? '',
      provider: AuthProvider.username,
      status: PresenceStatus.online,
    );
  }
}
