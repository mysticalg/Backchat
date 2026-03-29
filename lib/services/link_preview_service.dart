import 'dart:async';

import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

class LinkPreviewData {
  const LinkPreviewData({
    required this.url,
    required this.title,
    this.description = '',
    this.imageUrl = '',
    this.siteName = '',
  });

  final Uri url;
  final String title;
  final String description;
  final String imageUrl;
  final String siteName;
}

class LinkPreviewService {
  LinkPreviewService({http.Client? client}) : _client = client ?? http.Client();

  static final RegExp _urlPattern =
      RegExp(r'https?://[^\s<>()]+', caseSensitive: false);

  final http.Client _client;
  final Map<String, Future<LinkPreviewData?>> _cache =
      <String, Future<LinkPreviewData?>>{};

  Uri? extractFirstUrl(String text) {
    for (final RegExpMatch match in _urlPattern.allMatches(text)) {
      final Uri? uri = _normalizeUrlMatch(match.group(0) ?? '');
      if (uri != null) {
        return uri;
      }
    }
    return null;
  }

  List<String> extractUrls(String text) {
    final List<String> urls = <String>[];
    for (final RegExpMatch match in _urlPattern.allMatches(text)) {
      final Uri? uri = _normalizeUrlMatch(match.group(0) ?? '');
      if (uri != null) {
        urls.add(uri.toString());
      }
    }
    return urls;
  }

  Future<LinkPreviewData?> fetchPreview(String rawUrl) {
    final Uri? uri = _normalizeUrlMatch(rawUrl);
    if (uri == null) {
      return Future<LinkPreviewData?>.value(null);
    }
    return _cache.putIfAbsent(uri.toString(), () => _fetchPreview(uri));
  }

  bool isDirectAudioUrl(String rawUrl) {
    return _hasKnownExtension(rawUrl, <String>[
      '.aac',
      '.flac',
      '.m4a',
      '.mp3',
      '.oga',
      '.ogg',
      '.wav',
    ]);
  }

  bool isDirectVideoUrl(String rawUrl) {
    return _hasKnownExtension(rawUrl, <String>[
      '.m3u8',
      '.m4v',
      '.mov',
      '.mp4',
      '.webm',
    ]);
  }

  Future<LinkPreviewData?> _fetchPreview(Uri uri) async {
    if (isDirectAudioUrl(uri.toString()) || isDirectVideoUrl(uri.toString())) {
      return LinkPreviewData(
        url: uri,
        title: _titleFromPath(uri),
        siteName: uri.host,
      );
    }

    try {
      final http.Response response =
          await _client.get(uri).timeout(const Duration(seconds: 8));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return LinkPreviewData(
          url: uri,
          title: _titleFromPath(uri),
          siteName: uri.host,
        );
      }

      final String contentType = response.headers['content-type'] ?? '';
      if (!contentType.toLowerCase().contains('text/html')) {
        return LinkPreviewData(
          url: uri,
          title: _titleFromPath(uri),
          siteName: uri.host,
        );
      }

      final document = html_parser.parse(response.body);
      final String title = _firstNonEmpty(<String>[
        _metaContent(document, 'property', 'og:title'),
        _metaContent(document, 'name', 'twitter:title'),
        document.querySelector('title')?.text ?? '',
        _titleFromPath(uri),
      ]);
      final String description = _firstNonEmpty(<String>[
        _metaContent(document, 'property', 'og:description'),
        _metaContent(document, 'name', 'twitter:description'),
        _metaContent(document, 'name', 'description'),
      ]);
      final String siteName = _firstNonEmpty(<String>[
        _metaContent(document, 'property', 'og:site_name'),
        uri.host,
      ]);
      final String imageUrl = _resolveUrl(
        uri,
        _firstNonEmpty(<String>[
          _metaContent(document, 'property', 'og:image'),
          _metaContent(document, 'name', 'twitter:image'),
          _faviconHref(document),
          _youtubeThumbnail(uri),
        ]),
      );

      return LinkPreviewData(
        url: uri,
        title: title,
        description: description,
        imageUrl: imageUrl,
        siteName: siteName,
      );
    } on TimeoutException {
      return LinkPreviewData(
        url: uri,
        title: _titleFromPath(uri),
        siteName: uri.host,
      );
    } catch (_) {
      return LinkPreviewData(
        url: uri,
        title: _titleFromPath(uri),
        siteName: uri.host,
      );
    }
  }

  Uri? _normalizeUrlMatch(String rawValue) {
    final String trimmed = rawValue.trim().replaceAll(RegExp(r'[.,!?;:]+$'), '');
    final Uri? uri = Uri.tryParse(trimmed);
    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    return uri;
  }

  bool _hasKnownExtension(String rawUrl, List<String> extensions) {
    final Uri? uri = Uri.tryParse(rawUrl.trim());
    if (uri == null || uri.pathSegments.isEmpty) {
      return false;
    }
    final String lastSegment = uri.pathSegments.last.toLowerCase();
    return extensions.any(lastSegment.endsWith);
  }

  String _metaContent(
    dynamic document,
    String attribute,
    String value,
  ) {
    final dynamic element = document.querySelector('meta[$attribute="$value"]');
    return element?.attributes['content']?.toString().trim() ?? '';
  }

  String _faviconHref(dynamic document) {
    final List<dynamic> elements = <dynamic>[
      document.querySelector('link[rel="apple-touch-icon"]'),
      document.querySelector('link[rel="icon"]'),
      document.querySelector('link[rel="shortcut icon"]'),
    ];
    for (final dynamic element in elements) {
      final String href = element?.attributes['href']?.toString().trim() ?? '';
      if (href.isNotEmpty) {
        return href;
      }
    }
    return '';
  }

  String _resolveUrl(Uri base, String rawValue) {
    final String trimmed = rawValue.trim();
    if (trimmed.isEmpty) {
      return '';
    }
    final Uri? resolved = Uri.tryParse(trimmed);
    if (resolved == null) {
      return '';
    }
    if (resolved.hasScheme) {
      return resolved.toString();
    }
    return base.resolveUri(resolved).toString();
  }

  String _titleFromPath(Uri uri) {
    if (uri.pathSegments.isEmpty) {
      return uri.host;
    }
    final String lastSegment = uri.pathSegments.last.replaceAll('-', ' ').trim();
    return lastSegment.isEmpty ? uri.host : lastSegment;
  }

  String _firstNonEmpty(List<String> values) {
    for (final String value in values) {
      if (value.trim().isNotEmpty) {
        return value.trim();
      }
    }
    return '';
  }

  String _youtubeThumbnail(Uri uri) {
    final String host = uri.host.toLowerCase();
    String? videoId;
    if (host.contains('youtu.be') && uri.pathSegments.isNotEmpty) {
      videoId = uri.pathSegments.first;
    } else if (host.contains('youtube.com')) {
      if (uri.pathSegments.contains('watch')) {
        videoId = uri.queryParameters['v'];
      } else if (uri.pathSegments.length >= 2 &&
          (uri.pathSegments.first == 'shorts' ||
              uri.pathSegments.first == 'embed')) {
        videoId = uri.pathSegments[1];
      }
    }
    if (videoId == null || videoId.trim().isEmpty) {
      return '';
    }
    return 'https://img.youtube.com/vi/$videoId/hqdefault.jpg';
  }
}
