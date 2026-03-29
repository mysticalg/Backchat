import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_user.dart';
import '../models/call_models.dart';
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

class UploadedMedia {
  const UploadedMedia({
    required this.url,
    required this.mimeType,
    required this.kind,
    required this.sizeBytes,
  });

  final String url;
  final String mimeType;
  final String kind;
  final int sizeBytes;
}

abstract class BackchatApiClient {
  bool get isConfigured;

  Future<Map<String, dynamic>> signInOrCreateWithUsername({
    required String username,
    required String recoveryEmail,
    required String password,
  });

  Future<String?> recoverUsernameForEmail(String recoveryEmail);

  Future<List<AppUser>> fetchContacts();

  Future<AppUser> fetchMyProfile();

  Future<AppUser> updateProfile({
    required String avatarUrl,
    required String quote,
  });

  Future<Map<String, dynamic>> inviteByUsername(String username);

  Future<SocialOAuthStartResult> startSocialOAuth(String provider);

  Future<SocialOAuthPollResult> pollSocialOAuth(String state);

  Future<SocialOAuthProbeResult> probeSocialOAuth();

  Future<void> sendMessage({
    required String toUsername,
    required String cipherText,
    String? clientMessageId,
  });

  Future<UploadedMedia> uploadMedia({
    required Uint8List bytes,
    required String mimeType,
    String? filename,
    void Function(double progress)? onProgress,
  });

  Future<CallServerConfig> fetchCallConfig();

  Future<CallSummary> startCall({
    required String toUsername,
    required CallKind kind,
    required String offerType,
    required String offerSdp,
    required CallSettings settings,
  });

  Future<void> sendCallSignal({
    required int callId,
    required CallSignalType type,
    Map<String, dynamic>? payload,
  });

  Future<PollCallSignalsResult> pollCallSignals({
    int sinceId,
    int limit,
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
      'https://d2axmspob6mqyx.cloudfront.net';
  static const int _chunkedUploadMaxBytes = 4096;
  static const int _preferChunkedUploadThresholdBytes = 4096;
  static const String _configuredApiBaseUrl =
      String.fromEnvironment('BACKCHAT_API_BASE_URL');
  static const Duration _requestTimeout = Duration(seconds: 8);
  static String? _sharedCachedToken;

  final http.Client _client;

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
    required String password,
  }) async {
    final Map<String, dynamic> payload = await _postJson(
      '/auth_username.php',
      <String, dynamic>{
        'username': username,
        'recoveryEmail': recoveryEmail,
        'password': password,
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
  Future<AppUser> fetchMyProfile() async {
    final Map<String, dynamic> payload = await _getJson('/profile.php');
    final Object? userPayload = payload['user'];
    if (userPayload is! Map<String, dynamic>) {
      throw const BackchatApiException(
        status: 'profile_invalid',
        message: 'Profile response is missing the user payload.',
      );
    }
    return _appUserFromApiMap(userPayload);
  }

  @override
  Future<AppUser> updateProfile({
    required String avatarUrl,
    required String quote,
  }) async {
    final Map<String, dynamic> payload = await _postJson(
      '/profile.php',
      <String, dynamic>{
        'avatarUrl': avatarUrl,
        'quote': quote,
      },
    );
    final Object? userPayload = payload['user'];
    if (userPayload is! Map<String, dynamic>) {
      throw const BackchatApiException(
        status: 'profile_invalid',
        message: 'Profile update response is missing the user payload.',
      );
    }
    return _appUserFromApiMap(userPayload);
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
    final String authorizationUrl =
        payload['authorizationUrl']?.toString() ?? '';
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
  Future<UploadedMedia> uploadMedia({
    required Uint8List bytes,
    required String mimeType,
    String? filename,
    void Function(double progress)? onProgress,
  }) async {
    if (!isConfigured) {
      throw const BackchatApiException(
        status: 'api_not_configured',
        message: 'BACKCHAT_API_BASE_URL is not configured.',
      );
    }
    if (bytes.isEmpty) {
      throw const BackchatApiException(
        status: 'invalid_media',
        message: 'That GIF or image could not be read.',
      );
    }

    onProgress?.call(0);
    if (_shouldPreferChunkedUpload(bytes.length)) {
      return _uploadMediaInChunks(
        bytes: bytes,
        mimeType: mimeType,
        filename: filename,
        onProgress: onProgress,
      );
    }

    try {
      return await _uploadMediaMultipart(
        bytes: bytes,
        mimeType: mimeType,
        filename: filename,
        onProgress: onProgress,
      );
    } on BackchatApiException catch (e) {
      if (_shouldRetryChunkedUpload(e)) {
        return _uploadMediaInChunks(
          bytes: bytes,
          mimeType: mimeType,
          filename: filename,
          onProgress: onProgress,
        );
      }
      rethrow;
    }
  }

  Future<UploadedMedia> _uploadMediaMultipart({
    required Uint8List bytes,
    required String mimeType,
    String? filename,
    void Function(double progress)? onProgress,
  }) async {
    final Uri uri = Uri.parse('${_apiBaseUrl.trim()}/upload_media.php');
    final http.MultipartRequest request = http.MultipartRequest('POST', uri)
      ..headers.addAll(await _buildHeaders(requiresAuth: true))
      ..fields['mimeType'] = mimeType.trim()
      ..files.add(
        http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: _normalizedFilename(filename, mimeType),
        ),
      );

    if (filename != null && filename.trim().isNotEmpty) {
      request.fields['filename'] = filename.trim();
    }

    late final http.Response response;
    try {
      final http.StreamedResponse streamed =
          await _client.send(request).timeout(_requestTimeout);
      onProgress?.call(0.85);
      response = await http.Response.fromStream(streamed).timeout(
        _requestTimeout,
      );
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

    final Map<String, dynamic> decoded = _decodeJsonResponse(uri, response);
    if (response.statusCode >= 400) {
      throw BackchatApiException(
        status: decoded['status']?.toString() ?? 'api_error',
        message: decoded['message']?.toString() ?? 'API request failed.',
        payload: decoded,
      );
    }

    final Object? mediaPayload = decoded['media'];
    if (mediaPayload is! Map<String, dynamic>) {
      throw const BackchatApiException(
        status: 'upload_invalid',
        message: 'Media upload response is missing the media payload.',
      );
    }

    final String url = mediaPayload['url']?.toString() ?? '';
    final String resolvedMimeType = mediaPayload['mimeType']?.toString() ?? '';
    final String kind = mediaPayload['kind']?.toString() ?? '';
    final int sizeBytes = mediaPayload['sizeBytes'] is int
        ? mediaPayload['sizeBytes'] as int
        : int.tryParse(mediaPayload['sizeBytes']?.toString() ?? '') ?? 0;
    if (url.isEmpty || resolvedMimeType.isEmpty || kind.isEmpty) {
      throw const BackchatApiException(
        status: 'upload_invalid',
        message: 'Media upload response is missing fields.',
      );
    }

    onProgress?.call(1);
    return UploadedMedia(
      url: url,
      mimeType: resolvedMimeType,
      kind: kind,
      sizeBytes: sizeBytes,
    );
  }

  Future<UploadedMedia> _uploadMediaInChunks({
    required Uint8List bytes,
    required String mimeType,
    String? filename,
    void Function(double progress)? onProgress,
  }) async {
    final Map<String, dynamic> startPayload = await _postJson(
      '/upload_media.php',
      <String, dynamic>{
        'mode': 'chunked_start',
        'mimeType': mimeType.trim(),
        if (filename != null && filename.trim().isNotEmpty)
          'filename': filename.trim(),
      },
    );

    final Object? uploadPayload = startPayload['upload'];
    if (uploadPayload is! Map<String, dynamic>) {
      throw const BackchatApiException(
        status: 'upload_invalid',
        message: 'Media upload session did not start correctly.',
      );
    }

    final String uploadToken = uploadPayload['token']?.toString() ?? '';
    final int serverChunkBytes = uploadPayload['maxChunkBytes'] is int
        ? uploadPayload['maxChunkBytes'] as int
        : int.tryParse(uploadPayload['maxChunkBytes']?.toString() ?? '') ?? 0;
    final int chunkBytes = serverChunkBytes > 0 && serverChunkBytes <= _chunkedUploadMaxBytes
        ? serverChunkBytes
        : _chunkedUploadMaxBytes;
    if (uploadToken.isEmpty || chunkBytes <= 0) {
      throw const BackchatApiException(
        status: 'upload_invalid',
        message: 'Media upload session did not provide chunk settings.',
      );
    }

    for (int offset = 0; offset < bytes.length; offset += chunkBytes) {
      final int end = offset + chunkBytes > bytes.length
          ? bytes.length
          : offset + chunkBytes;
      final String chunkBase64 = base64Encode(bytes.sublist(offset, end));
      await _postJson(
        '/upload_media.php',
        <String, dynamic>{
          'mode': 'chunked_append',
          'uploadToken': uploadToken,
          'chunkBase64': chunkBase64,
        },
      );
      onProgress?.call(end / bytes.length);
    }

    final Map<String, dynamic> finishPayload = await _postJson(
      '/upload_media.php',
      <String, dynamic>{
        'mode': 'chunked_finish',
        'uploadToken': uploadToken,
      },
    );

    final Object? mediaPayload = finishPayload['media'];
    if (mediaPayload is! Map<String, dynamic>) {
      throw const BackchatApiException(
        status: 'upload_invalid',
        message: 'Media upload response is missing the media payload.',
      );
    }

    final String url = mediaPayload['url']?.toString() ?? '';
    final String resolvedMimeType = mediaPayload['mimeType']?.toString() ?? '';
    final String kind = mediaPayload['kind']?.toString() ?? '';
    final int sizeBytes = mediaPayload['sizeBytes'] is int
        ? mediaPayload['sizeBytes'] as int
        : int.tryParse(mediaPayload['sizeBytes']?.toString() ?? '') ?? 0;
    if (url.isEmpty || resolvedMimeType.isEmpty || kind.isEmpty) {
      throw const BackchatApiException(
        status: 'upload_invalid',
        message: 'Media upload response is missing fields.',
      );
    }

    onProgress?.call(1);
    return UploadedMedia(
      url: url,
      mimeType: resolvedMimeType,
      kind: kind,
      sizeBytes: sizeBytes,
    );
  }

  @override
  Future<CallServerConfig> fetchCallConfig() async {
    final Map<String, dynamic> payload = await _getJson('/call_config.php');
    final List<dynamic> rows = payload['iceServers'] is List<dynamic>
        ? payload['iceServers'] as List<dynamic>
        : <dynamic>[];
    return CallServerConfig(
      iceServers: rows
          .whereType<Map<String, dynamic>>()
          .map(CallIceServer.fromJson)
          .where((CallIceServer server) => server.urls.isNotEmpty)
          .toList(),
      turnConfigured: payload['turnConfigured'] == true,
      recommendedPollInterval: Duration(
        milliseconds: payload['recommendedPollIntervalMs'] is int
            ? payload['recommendedPollIntervalMs'] as int
            : int.tryParse(
                    payload['recommendedPollIntervalMs']?.toString() ?? '') ??
                750,
      ),
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
    final Map<String, dynamic> payload = await _postJson(
      '/start_call.php',
      <String, dynamic>{
        'toUsername': toUsername,
        'kind': kind.name,
        'offer': <String, dynamic>{
          'type': offerType,
          'sdp': offerSdp,
        },
        'settings': settings.toJson(),
      },
    );
    final Object? callPayload = payload['call'];
    if (callPayload is! Map<String, dynamic>) {
      throw const BackchatApiException(
        status: 'call_invalid',
        message: 'Call start response is missing the call payload.',
      );
    }
    return _callSummaryFromApiMap(callPayload);
  }

  @override
  Future<void> sendCallSignal({
    required int callId,
    required CallSignalType type,
    Map<String, dynamic>? payload,
  }) async {
    await _postJson(
      '/send_call_signal.php',
      <String, dynamic>{
        'callId': callId,
        'type': type.name,
        if (payload != null) 'payload': payload,
      },
    );
  }

  @override
  Future<PollCallSignalsResult> pollCallSignals({
    int sinceId = 0,
    int limit = 100,
  }) async {
    final int safeLimit = limit < 1 ? 1 : (limit > 200 ? 200 : limit);
    final Map<String, dynamic> payload = await _getJson(
      '/poll_call_signals.php?sinceId=$sinceId&limit=$safeLimit',
    );
    final List<dynamic> rows = payload['signals'] is List<dynamic>
        ? payload['signals'] as List<dynamic>
        : <dynamic>[];
    return PollCallSignalsResult(
      nextSinceId: payload['nextSinceId'] is int
          ? payload['nextSinceId'] as int
          : int.tryParse(payload['nextSinceId']?.toString() ?? '') ?? sinceId,
      signals: rows
          .whereType<Map<String, dynamic>>()
          .map(_callSignalEventFromApiMap)
          .toList(),
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
            localId: _localIdForRemoteMessage(row),
            fromUserId: row['fromUserId']?.toString() ?? '',
            toUserId: currentUserId,
            cipherText: row['cipherText']?.toString() ?? '',
            sentAt: _parseApiUtcDateTime(
              row['sentAtUtc']?.toString(),
            ),
            remoteId: row['id'] is int
                ? row['id'] as int
                : int.tryParse(row['id']?.toString() ?? ''),
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
    _sharedCachedToken = null;
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
    final Map<String, String> headers = await _buildHeaders(
      requiresAuth: requiresAuth,
      includeJsonContentType: true,
    );

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

    final Map<String, dynamic> decoded = _decodeJsonResponse(uri, response);

    if (response.statusCode >= 400) {
      throw BackchatApiException(
        status: decoded['status']?.toString() ?? 'api_error',
        message: decoded['message']?.toString() ?? 'API request failed.',
        payload: decoded,
      );
    }
    return decoded;
  }

  Future<Map<String, String>> _buildHeaders({
    required bool requiresAuth,
    bool includeJsonContentType = false,
  }) async {
    final Map<String, String> headers = <String, String>{};
    if (includeJsonContentType) {
      headers['Content-Type'] = 'application/json';
    }

    if (!requiresAuth) {
      return headers;
    }

    final String? token = await _readToken();
    if (token == null || token.isEmpty) {
      throw const BackchatApiException(
        status: 'unauthorized',
        message: 'Missing auth token.',
      );
    }
    headers['Authorization'] = 'Bearer $token';
    headers['X-Auth-Token'] = token;
    return headers;
  }

  Map<String, dynamic> _decodeJsonResponse(Uri uri, http.Response response) {
    Map<String, dynamic> decoded = <String, dynamic>{};
    if (response.body.isEmpty) {
      return decoded;
    }

    try {
      final Object? parsed = jsonDecode(response.body);
      if (parsed is Map<String, dynamic>) {
        decoded = parsed;
      }
      return decoded;
    } on FormatException {
      throw BackchatApiException(
        status: 'invalid_api_response',
        message: _nonJsonApiResponseMessage(uri, response),
      );
    }
  }

  String _normalizedFilename(String? filename, String mimeType) {
    final String trimmed = filename?.trim() ?? '';
    if (trimmed.isNotEmpty) {
      return trimmed;
    }

    final String extension = switch (mimeType.trim().toLowerCase()) {
      'image/gif' => 'gif',
      'image/png' => 'png',
      'image/webp' => 'webp',
      _ => 'jpg',
    };
    return 'backchat-media.$extension';
  }

  bool _shouldPreferChunkedUpload(int byteLength) {
    final String host = Uri.tryParse(_apiBaseUrl.trim())?.host.toLowerCase() ?? '';
    return host.endsWith('cloudfront.net') &&
        byteLength > _preferChunkedUploadThresholdBytes;
  }

  bool _shouldRetryChunkedUpload(BackchatApiException error) {
    final String message = error.message.toLowerCase();
    return error.status == 'invalid_api_response' &&
        message.contains('returned html') &&
        message.contains('/upload_media.php');
  }

  String _nonJsonApiResponseMessage(Uri uri, http.Response response) {
    final String body = response.body;
    final String contentType =
        response.headers['content-type']?.toLowerCase() ?? '';

    final String loweredBody = body.toLowerCase();
    final bool looksLikeAntiBotInterstitial = loweredBody.contains('/aes.js') ||
        loweredBody.contains('site requires javascript to work') ||
        loweredBody.contains('__test=');

    if (looksLikeAntiBotInterstitial) {
      return 'API returned a JavaScript anti-bot/interstitial page instead of JSON at $uri. '
          'This host blocks app HTTP clients, so social login cannot start. '
          'Move the API to a host without this protection.';
    }

    final bool looksLikeHtml = contentType.contains('text/html') ||
        loweredBody.trimLeft().startsWith('<');
    if (looksLikeHtml) {
      return 'API returned HTML instead of JSON at $uri. '
          'Check BACKCHAT_API_BASE_URL and ensure it points to the API root URL '
          '(for example https://d2axmspob6mqyx.cloudfront.net).';
    }

    return 'API did not return JSON at $uri.';
  }

  Future<void> _saveToken(String token) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenStorageKey, token);
    _sharedCachedToken = token;
  }

  Future<String?> _readToken() async {
    if (_sharedCachedToken != null) return _sharedCachedToken;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    _sharedCachedToken = prefs.getString(_tokenStorageKey);
    return _sharedCachedToken;
  }

  AppUser _appUserFromApiMap(Map<String, dynamic> json) {
    final String username =
        json['username']?.toString() ?? json['displayName']?.toString() ?? '';
    final String displayName =
        json['displayName']?.toString() ?? json['username']?.toString() ?? '';
    final String normalizedUsername = username.toLowerCase();
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
      id: json['id']?.toString() ?? 'username:$normalizedUsername',
      username: username,
      displayName: displayName,
      avatarUrl: json['avatarUrl']?.toString() ?? '',
      provider: provider,
      quote: json['quote']?.toString() ?? '',
      status: status,
      lastSeenAt: _tryParseApiUtcDateTime(
        json['lastSeenAtUtc']?.toString(),
      ),
    );
  }

  CallSummary _callSummaryFromApiMap(Map<String, dynamic> json) {
    final String kindName = json['kind']?.toString() ?? CallKind.audio.name;
    final CallKind kind = CallKind.values.firstWhere(
      (CallKind value) => value.name == kindName,
      orElse: () => CallKind.audio,
    );
    final Object? peerPayload = json['peer'];
    if (peerPayload is! Map<String, dynamic>) {
      throw const BackchatApiException(
        status: 'call_peer_missing',
        message: 'Call summary is missing peer information.',
      );
    }
    final Object? settingsPayload = json['settings'];
    return CallSummary(
      id: json['id'] is int
          ? json['id'] as int
          : int.tryParse(json['id']?.toString() ?? '') ?? 0,
      kind: kind,
      status: json['status']?.toString() ?? 'ringing',
      settings: settingsPayload is Map<String, dynamic>
          ? CallSettings.fromJson(settingsPayload)
          : CallSettings.defaults,
      peer: _appUserFromApiMap(peerPayload),
      createdAt: _parseApiUtcDateTime(json['createdAtUtc']?.toString()),
      answeredAt: _tryParseApiUtcDateTime(json['answeredAtUtc']?.toString()),
      endedAt: _tryParseApiUtcDateTime(json['endedAtUtc']?.toString()),
    );
  }

  CallSignalEvent _callSignalEventFromApiMap(Map<String, dynamic> json) {
    final String typeName =
        json['type']?.toString() ?? CallSignalType.candidate.name;
    final CallSignalType type = CallSignalType.values.firstWhere(
      (CallSignalType value) => value.name == typeName,
      orElse: () => CallSignalType.candidate,
    );
    final Object? callPayload = json['call'];
    if (callPayload is! Map<String, dynamic>) {
      throw const BackchatApiException(
        status: 'call_signal_invalid',
        message: 'Call signal is missing the call summary.',
      );
    }
    return CallSignalEvent(
      id: json['id'] is int
          ? json['id'] as int
          : int.tryParse(json['id']?.toString() ?? '') ?? 0,
      callId: json['callId'] is int
          ? json['callId'] as int
          : int.tryParse(json['callId']?.toString() ?? '') ?? 0,
      type: type,
      payload: json['payload'] is Map<String, dynamic>
          ? json['payload'] as Map<String, dynamic>
          : <String, dynamic>{},
      call: _callSummaryFromApiMap(callPayload),
      createdAt: _parseApiUtcDateTime(json['createdAtUtc']?.toString()),
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

  DateTime? _tryParseApiUtcDateTime(String? value) {
    final String normalized = (value ?? '').trim();
    if (normalized.isEmpty) {
      return null;
    }
    try {
      return DateTime.parse('${normalized.replaceFirst(' ', 'T')}Z').toLocal();
    } on FormatException {
      return null;
    }
  }

  String _localIdForRemoteMessage(Map<String, dynamic> row) {
    final int? remoteId = row['id'] is int
        ? row['id'] as int
        : int.tryParse(row['id']?.toString() ?? '');
    if (remoteId != null) {
      return 'remote:$remoteId';
    }

    final String fromUserId = row['fromUserId']?.toString() ?? '';
    final String sentAt = row['sentAtUtc']?.toString() ?? '';
    final String cipherText = row['cipherText']?.toString() ?? '';
    return 'remote:$fromUserId:$sentAt:${cipherText.hashCode}';
  }
}
