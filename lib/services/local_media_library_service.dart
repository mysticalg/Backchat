import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_message_content.dart';
import 'keyboard_media_service.dart';

class LocalMediaLibraryService {
  LocalMediaLibraryService({
    http.Client? client,
    KeyboardMediaService? keyboardMediaService,
  })  : _client = client ?? http.Client(),
        _keyboardMediaService = keyboardMediaService ?? KeyboardMediaService();

  static const String _savedImagePrefix = 'saved_image_message_v1_';

  final http.Client _client;
  final KeyboardMediaService _keyboardMediaService;

  Future<File?> saveImageMessage({
    required String messageId,
    required ChatMessageContent content,
  }) async {
    if (kIsWeb ||
        content.kind != ChatMessageContentKind.image ||
        !content.hasUrl) {
      return null;
    }

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String storageKey = _storageKeyForMessage(messageId);
    final String? existingPath = prefs.getString(storageKey);
    if (existingPath != null && existingPath.trim().isNotEmpty) {
      return File(existingPath);
    }

    final _ResolvedImageAsset? asset = await _resolveImageAsset(content);
    if (asset == null || asset.bytes.isEmpty) {
      return null;
    }

    final Directory? picturesDirectory = await _resolvePicturesDirectory();
    if (picturesDirectory == null) {
      return null;
    }

    final Directory targetDirectory = Directory(
      '${picturesDirectory.path}${Platform.pathSeparator}Backchat',
    );
    await targetDirectory.create(recursive: true);

    final String extension = _preferredExtension(
      mimeType: asset.mimeType,
      url: content.url,
    );
    final String filename = [
      'backchat',
      DateTime.now().toUtc().millisecondsSinceEpoch,
      _stableShortHash(messageId),
    ].join('-');
    final File file = File(
      '${targetDirectory.path}${Platform.pathSeparator}$filename.$extension',
    );
    await file.writeAsBytes(asset.bytes, flush: true);
    await prefs.setString(storageKey, file.path);
    return file;
  }

  String _storageKeyForMessage(String messageId) {
    return '$_savedImagePrefix${base64Url.encode(utf8.encode(messageId))}';
  }

  Future<_ResolvedImageAsset?> _resolveImageAsset(
    ChatMessageContent content,
  ) async {
    if (_keyboardMediaService.isDataUrl(content.url)) {
      final Uint8List? bytes =
          _keyboardMediaService.tryDecodeDataUrl(content.url);
      final String? mimeType =
          _keyboardMediaService.tryExtractDataUrlMimeType(content.url);
      if (bytes == null || bytes.isEmpty) {
        return null;
      }
      return _ResolvedImageAsset(
        bytes: bytes,
        mimeType: mimeType ?? '',
      );
    }

    final Uri? uri = Uri.tryParse(content.url.trim());
    if (uri == null || !uri.hasScheme) {
      return null;
    }

    final http.Response response = await _client.get(uri);
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        response.bodyBytes.isEmpty) {
      return null;
    }

    return _ResolvedImageAsset(
      bytes: response.bodyBytes,
      mimeType: response.headers['content-type'] ?? '',
    );
  }

  Future<Directory?> _resolvePicturesDirectory() async {
    if (kIsWeb) {
      return null;
    }
    if (Platform.isWindows) {
      final List<String> candidates = <String>[
        if ((Platform.environment['OneDrive'] ?? '').trim().isNotEmpty)
          '${Platform.environment['OneDrive']}\\Pictures',
        if ((Platform.environment['USERPROFILE'] ?? '').trim().isNotEmpty)
          '${Platform.environment['USERPROFILE']}\\Pictures',
      ];
      for (final String candidate in candidates) {
        final Directory directory = Directory(candidate);
        if (directory.existsSync()) {
          return directory;
        }
      }
      if (candidates.isNotEmpty) {
        return Directory(candidates.last);
      }
      return null;
    }

    final String homeDirectory =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
    if (homeDirectory.trim().isEmpty) {
      return null;
    }
    return Directory('$homeDirectory${Platform.pathSeparator}Pictures');
  }

  String _preferredExtension({
    required String mimeType,
    required String url,
  }) {
    final String normalizedMimeType = mimeType.trim().toLowerCase();
    if (normalizedMimeType.contains('png')) {
      return 'png';
    }
    if (normalizedMimeType.contains('webp')) {
      return 'webp';
    }
    if (normalizedMimeType.contains('gif')) {
      return 'gif';
    }
    if (normalizedMimeType.contains('heic')) {
      return 'heic';
    }
    if (normalizedMimeType.contains('heif')) {
      return 'heif';
    }
    final Uri? uri = Uri.tryParse(url.trim());
    final String lastSegment = uri != null && uri.pathSegments.isNotEmpty
        ? uri.pathSegments.last.toLowerCase()
        : '';
    for (final String extension
        in <String>['png', 'webp', 'gif', 'heic', 'heif', 'jpg', 'jpeg']) {
      if (lastSegment.endsWith('.$extension')) {
        return extension == 'jpeg' ? 'jpg' : extension;
      }
    }
    return 'jpg';
  }

  String _stableShortHash(String value) {
    int hash = 0x811c9dc5;
    for (final int byte in utf8.encode(value)) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toUnsigned(32).toRadixString(16).padLeft(8, '0');
  }
}

class _ResolvedImageAsset {
  const _ResolvedImageAsset({
    required this.bytes,
    required this.mimeType,
  });

  final Uint8List bytes;
  final String mimeType;
}
