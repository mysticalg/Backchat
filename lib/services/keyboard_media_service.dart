import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/chat_message_content.dart';
import 'media_attachment_service.dart';

class KeyboardMediaException implements Exception {
  const KeyboardMediaException(this.message);

  final String message;

  @override
  String toString() => 'KeyboardMediaException($message)';
}

class KeyboardMediaService {
  static const MethodChannel _channel = MethodChannel('backchat/media_import');
  static const int maxImportedBytes = MediaAttachmentService.maxAttachmentBytes;
  static const List<String> supportedMimeTypes = <String>[
    'image/gif',
    'image/png',
    'image/jpeg',
    'image/jpg',
    'image/webp',
    'image/heic',
    'image/heif',
  ];

  Future<ChatMessageContent> contentFromInsertedContent(
    KeyboardInsertedContent content,
  ) async {
    final _ResolvedKeyboardMedia resolved = await _resolve(content);
    final String dataUrl = buildDataUrl(
      bytes: resolved.bytes,
      mimeType: resolved.mimeType,
    );
    if (_isGifMimeType(resolved.mimeType)) {
      return ChatMessageContent.gif(url: dataUrl);
    }
    return ChatMessageContent.image(url: dataUrl);
  }

  ChatMessageContent contentFromBytes({
    required Uint8List bytes,
    required String mimeType,
  }) {
    final String normalizedMimeType = _normalizeMimeType(mimeType);
    final String dataUrl = buildDataUrl(
      bytes: bytes,
      mimeType: normalizedMimeType,
    );
    if (_isGifMimeType(normalizedMimeType)) {
      return ChatMessageContent.gif(url: dataUrl);
    }
    return ChatMessageContent.image(url: dataUrl);
  }

  String buildDataUrl({
    required Uint8List bytes,
    required String mimeType,
  }) {
    final String normalizedMimeType = _normalizeMimeType(mimeType);
    return 'data:$normalizedMimeType;base64,${base64Encode(bytes)}';
  }

  bool isDataUrl(String value) {
    return value.trimLeft().toLowerCase().startsWith('data:');
  }

  Uint8List? tryDecodeDataUrl(String value) {
    final String trimmed = value.trim();
    final int markerIndex = trimmed.indexOf(';base64,');
    if (!trimmed.toLowerCase().startsWith('data:') || markerIndex <= 5) {
      return null;
    }

    final String encoded = trimmed.substring(markerIndex + ';base64,'.length);
    try {
      return Uint8List.fromList(base64Decode(encoded));
    } catch (_) {
      return null;
    }
  }

  String? tryExtractDataUrlMimeType(String value) {
    final String trimmed = value.trim();
    final int markerIndex = trimmed.indexOf(';base64,');
    if (!trimmed.toLowerCase().startsWith('data:') || markerIndex <= 5) {
      return null;
    }

    final String mimeType = trimmed.substring(5, markerIndex);
    final String normalized = _normalizeMimeType(mimeType);
    return normalized.isEmpty ? null : normalized;
  }

  Future<_ResolvedKeyboardMedia> _resolve(
      KeyboardInsertedContent content) async {
    final _PlatformKeyboardMediaPayload? platformPayload =
        content.hasData ? null : await _readPlatformPayload(content.uri);
    final Uint8List? bytes =
        content.hasData ? content.data : platformPayload?.bytes;
    if (bytes == null || bytes.isEmpty) {
      throw const KeyboardMediaException(
        'Could not read the GIF or image from your keyboard.',
      );
    }
    if (bytes.length > maxImportedBytes) {
      throw const KeyboardMediaException(
        'That GIF or image is too large to send. Try one under 8 MB or share a link instead.',
      );
    }

    final String mimeType = _bestMimeType(
      preferredMimeType: content.mimeType,
      fallbackMimeType: platformPayload?.mimeType,
      uri: content.uri,
    );
    return _ResolvedKeyboardMedia(bytes: bytes, mimeType: mimeType);
  }

  Future<_PlatformKeyboardMediaPayload?> _readPlatformPayload(
      String uri) async {
    try {
      final Map<Object?, Object?>? payload =
          await _channel.invokeMapMethod<Object?, Object?>(
        'readInsertedContent',
        <String, dynamic>{'uri': uri},
      );
      if (payload == null) {
        return null;
      }
      final Object? bytesValue = payload['data'];
      final Uint8List? bytes = switch (bytesValue) {
        Uint8List typed => typed,
        List<int> values => Uint8List.fromList(values),
        _ => null,
      };
      return _PlatformKeyboardMediaPayload(
        bytes: bytes,
        mimeType: payload['mimeType']?.toString() ?? '',
      );
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  String _bestMimeType({
    required String preferredMimeType,
    String? fallbackMimeType,
    required String uri,
  }) {
    final List<String> candidates = <String>[
      preferredMimeType,
      if (fallbackMimeType != null) fallbackMimeType,
      _mimeTypeFromUri(uri),
    ];
    for (final String candidate in candidates) {
      if (candidate.trim().isEmpty) {
        continue;
      }
      final String normalized = _normalizeMimeType(candidate);
      if (normalized.startsWith('image/')) {
        return normalized;
      }
    }
    throw const KeyboardMediaException(
      'This keyboard item is not a supported GIF or image.',
    );
  }

  String _mimeTypeFromUri(String uri) {
    final String lowerValue = uri.toLowerCase();
    if (lowerValue.contains('.gif')) {
      return 'image/gif';
    }
    if (lowerValue.contains('.webp')) {
      return 'image/webp';
    }
    if (lowerValue.contains('.png')) {
      return 'image/png';
    }
    if (lowerValue.contains('.jpg') || lowerValue.contains('.jpeg')) {
      return 'image/jpeg';
    }
    if (lowerValue.contains('.heic')) {
      return 'image/heic';
    }
    if (lowerValue.contains('.heif')) {
      return 'image/heif';
    }
    return '';
  }

  String _normalizeMimeType(String mimeType) {
    final String lowerValue = mimeType.trim().toLowerCase();
    if (lowerValue == 'image/jpg') {
      return 'image/jpeg';
    }
    return lowerValue;
  }

  bool _isGifMimeType(String mimeType) {
    return _normalizeMimeType(mimeType) == 'image/gif';
  }
}

class _ResolvedKeyboardMedia {
  const _ResolvedKeyboardMedia({
    required this.bytes,
    required this.mimeType,
  });

  final Uint8List bytes;
  final String mimeType;
}

class _PlatformKeyboardMediaPayload {
  const _PlatformKeyboardMediaPayload({
    required this.bytes,
    required this.mimeType,
  });

  final Uint8List? bytes;
  final String mimeType;
}
