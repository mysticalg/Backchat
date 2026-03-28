import 'dart:convert';

import 'package:http/http.dart' as http;

class GiphyException implements Exception {
  const GiphyException(this.message);

  final String message;

  @override
  String toString() => 'GiphyException($message)';
}

class GiphyGif {
  const GiphyGif({
    required this.id,
    required this.previewUrl,
    required this.sendUrl,
    required this.title,
    required this.pageUrl,
  });

  final String id;
  final String previewUrl;
  final String sendUrl;
  final String title;
  final String pageUrl;
}

class GiphyQueryResult {
  const GiphyQueryResult({
    required this.gifs,
    required this.nextOffset,
    required this.hasMore,
  });

  final List<GiphyGif> gifs;
  final int nextOffset;
  final bool hasMore;
}

class GiphyService {
  GiphyService({
    http.Client? client,
    String apiKey = _configuredApiKey,
  })  : _client = client ?? http.Client(),
        _apiKey = apiKey.trim();

  static const String _configuredApiKey =
      String.fromEnvironment('BACKCHAT_GIPHY_API_KEY');
  static const String _baseUrl = 'https://api.giphy.com/v1/gifs';
  static const Duration _requestTimeout = Duration(seconds: 8);

  final http.Client _client;
  final String _apiKey;

  bool get isConfigured => _apiKey.isNotEmpty;

  Future<GiphyQueryResult> trending({
    int limit = 24,
    int offset = 0,
    String rating = 'g',
    String? languageCode,
  }) {
    return _load(
      path: '/trending',
      queryParameters: <String, String>{
        'limit': limit.toString(),
        'offset': offset.toString(),
        'rating': rating,
        if (_normalizedLanguageCode(languageCode).isNotEmpty)
          'lang': _normalizedLanguageCode(languageCode),
      },
    );
  }

  Future<GiphyQueryResult> search(
    String query, {
    int limit = 24,
    int offset = 0,
    String rating = 'g',
    String? languageCode,
  }) {
    final String normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) {
      return trending(
        limit: limit,
        offset: offset,
        rating: rating,
        languageCode: languageCode,
      );
    }

    return _load(
      path: '/search',
      queryParameters: <String, String>{
        'q': normalizedQuery,
        'limit': limit.toString(),
        'offset': offset.toString(),
        'rating': rating,
        if (_normalizedLanguageCode(languageCode).isNotEmpty)
          'lang': _normalizedLanguageCode(languageCode),
      },
    );
  }

  Future<GiphyQueryResult> _load({
    required String path,
    required Map<String, String> queryParameters,
  }) async {
    if (!isConfigured) {
      throw const GiphyException(
        'GIPHY search is not configured in this build.',
      );
    }

    final Uri uri = Uri.parse('$_baseUrl$path').replace(
      queryParameters: <String, String>{
        'api_key': _apiKey,
        ...queryParameters,
      },
    );

    http.Response response;
    try {
      response = await _client.get(uri).timeout(_requestTimeout);
    } catch (_) {
      throw const GiphyException(
        'Could not reach GIPHY right now. Check your connection and try again.',
      );
    }

    Map<String, dynamic> payload;
    try {
      final Object? decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Expected GIPHY response map');
      }
      payload = decoded;
    } catch (_) {
      throw const GiphyException(
        'GIPHY returned an unreadable response. Try again in a moment.',
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final String message =
          payload['message']?.toString() ??
          (payload['meta'] is Map<String, dynamic>
              ? (payload['meta'] as Map<String, dynamic>)['msg']?.toString()
              : null) ??
          'Could not load GIFs from GIPHY right now.';
      throw GiphyException(message);
    }

    final List<dynamic> rows = payload['data'] is List<dynamic>
        ? payload['data'] as List<dynamic>
        : <dynamic>[];
    final List<GiphyGif> gifs = rows
        .whereType<Map<String, dynamic>>()
        .map(_gifFromApiMap)
        .whereType<GiphyGif>()
        .toList(growable: false);

    final Map<String, dynamic> pagination =
        payload['pagination'] is Map<String, dynamic>
            ? payload['pagination'] as Map<String, dynamic>
            : <String, dynamic>{};
    final int offset = _asInt(pagination['offset']);
    final int count = _asInt(pagination['count']);
    final int totalCount = _asInt(pagination['total_count']);
    final int nextOffset = offset + count;

    return GiphyQueryResult(
      gifs: gifs,
      nextOffset: nextOffset,
      hasMore: nextOffset < totalCount,
    );
  }

  GiphyGif? _gifFromApiMap(Map<String, dynamic> row) {
    final Map<String, dynamic> images =
        row['images'] is Map<String, dynamic>
            ? row['images'] as Map<String, dynamic>
            : <String, dynamic>{};
    final String previewUrl = _firstNonEmpty(<String>[
      _nestedString(images, <String>['fixed_width_downsampled', 'url']),
      _nestedString(images, <String>['fixed_width', 'url']),
      _nestedString(images, <String>['preview_gif', 'url']),
      _nestedString(images, <String>['downsized', 'url']),
      _nestedString(images, <String>['original', 'url']),
    ]);
    final String sendUrl = _firstNonEmpty(<String>[
      _nestedString(images, <String>['downsized_medium', 'url']),
      _nestedString(images, <String>['downsized', 'url']),
      _nestedString(images, <String>['original', 'url']),
      previewUrl,
    ]);
    if (previewUrl.isEmpty || sendUrl.isEmpty) {
      return null;
    }

    final String title = _firstNonEmpty(<String>[
      row['title']?.toString() ?? '',
      row['slug']?.toString() ?? '',
      row['id']?.toString() ?? '',
    ]);
    return GiphyGif(
      id: row['id']?.toString() ?? sendUrl,
      previewUrl: previewUrl,
      sendUrl: sendUrl,
      title: title,
      pageUrl: row['url']?.toString() ?? '',
    );
  }

  String _nestedString(Map<String, dynamic> source, List<String> path) {
    Object? current = source;
    for (final String segment in path) {
      if (current is Map<String, dynamic>) {
        current = current[segment];
        continue;
      }
      return '';
    }
    return current?.toString().trim() ?? '';
  }

  String _firstNonEmpty(List<String> values) {
    for (final String value in values) {
      final String normalized = value.trim();
      if (normalized.isNotEmpty) {
        return normalized;
      }
    }
    return '';
  }

  int _asInt(Object? rawValue) {
    if (rawValue is int) {
      return rawValue;
    }
    return int.tryParse(rawValue?.toString() ?? '') ?? 0;
  }

  String _normalizedLanguageCode(String? rawValue) {
    final String value = (rawValue ?? '').trim().toLowerCase();
    if (value.isEmpty) {
      return '';
    }
    final RegExp simpleCode = RegExp(r'^[a-z]{2,5}$');
    if (simpleCode.hasMatch(value)) {
      return value;
    }
    final int separatorIndex = value.indexOf(RegExp(r'[-_]'));
    if (separatorIndex > 0) {
      final String base = value.substring(0, separatorIndex);
      if (simpleCode.hasMatch(base)) {
        return base;
      }
    }
    return '';
  }
}
