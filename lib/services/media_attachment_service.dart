import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:image/image.dart' as img;

import '../models/chat_message_content.dart';

class MediaAttachmentException implements Exception {
  const MediaAttachmentException(this.message);

  final String message;

  @override
  String toString() => 'MediaAttachmentException($message)';
}

class MediaAttachmentService {
  static const int maxInlineBytes = 384 * 1024;
  static const int maxAttachmentBytes = 8 * 1024 * 1024;
  static const int _maxStillImageDimension = 2048;
  static const int _minStillImageDimension = 960;
  static const XTypeGroup _visualMediaTypeGroup = XTypeGroup(
    label: 'Images and GIFs',
    extensions: <String>[
      'gif',
      'jpg',
      'jpeg',
      'png',
      'webp',
      'heic',
      'heif',
    ],
    mimeTypes: <String>[
      'image/gif',
      'image/jpeg',
      'image/png',
      'image/webp',
      'image/heic',
      'image/heif',
    ],
  );

  Future<ChatMessageContent?> pickVisualMedia() async {
    final XFile? file = await openFile(
      acceptedTypeGroups: <XTypeGroup>[_visualMediaTypeGroup],
      confirmButtonText: 'Send',
    );
    if (file == null) {
      return null;
    }
    return contentFromFile(file);
  }

  Future<ChatMessageContent> contentFromFile(XFile file) async {
    final Uint8List bytes = await file.readAsBytes();
    return contentFromBytes(
      bytes: bytes,
      nameHint: file.name,
      mimeTypeHint: _mimeTypeFromName(file.name),
    );
  }

  ChatMessageContent contentFromBytes({
    required Uint8List bytes,
    required String nameHint,
    required String mimeTypeHint,
  }) {
    if (bytes.isEmpty) {
      throw const MediaAttachmentException(
        'That image or GIF could not be read.',
      );
    }

    final String mimeType = _normalizeMimeType(
      mimeTypeHint.isNotEmpty ? mimeTypeHint : _mimeTypeFromName(nameHint),
    );
    if (_isGifMimeType(mimeType)) {
      if (bytes.length > maxAttachmentBytes) {
        throw const MediaAttachmentException(
          'That GIF is too large to send. Try one under 8 MB or share a link instead.',
        );
      }
      return ChatMessageContent.gif(
        url: _buildDataUrl(bytes: bytes, mimeType: mimeType),
      );
    }

    final _NormalizedStillImage normalized = _normalizeStillImage(
      bytes: bytes,
      preferredMimeType: mimeType,
    );
    return ChatMessageContent.image(
      url: _buildDataUrl(
        bytes: normalized.bytes,
        mimeType: normalized.mimeType,
      ),
    );
  }

  String _buildDataUrl({
    required Uint8List bytes,
    required String mimeType,
  }) {
    return 'data:$mimeType;base64,${base64Encode(bytes)}';
  }

  _NormalizedStillImage _normalizeStillImage({
    required Uint8List bytes,
    required String preferredMimeType,
  }) {
    final String normalizedMimeType = _normalizeMimeType(preferredMimeType);
    if (bytes.length <= maxAttachmentBytes &&
        _canSendStillImageWithoutNormalization(normalizedMimeType)) {
      return _NormalizedStillImage(
        bytes: bytes,
        mimeType:
            normalizedMimeType.isEmpty ? 'image/jpeg' : normalizedMimeType,
      );
    }

    final img.Image? decoded = img.decodeImage(bytes);
    if (decoded == null) {
      throw const MediaAttachmentException(
        'That image could not be prepared for sending. Try a JPEG, PNG, or WebP image instead.',
      );
    }

    for (int maxDimension = _maxStillImageDimension;
        maxDimension >= _minStillImageDimension;
        maxDimension = (maxDimension * 0.75).round()) {
      final img.Image candidate = _resizeForMaxDimension(
        decoded,
        maxDimension: maxDimension,
      );
      for (final int quality in <int>[86, 78, 70, 62, 54, 46]) {
        final Uint8List encoded = Uint8List.fromList(
          img.encodeJpg(candidate, quality: quality),
        );
        if (encoded.length <= maxAttachmentBytes) {
          return _NormalizedStillImage(
            bytes: encoded,
            mimeType: 'image/jpeg',
          );
        }
      }
      if (maxDimension == _minStillImageDimension) {
        break;
      }
    }

    throw const MediaAttachmentException(
      'That image is too large to send. Try one under 8 MB or share a link instead.',
    );
  }

  img.Image _resizeForMaxDimension(img.Image source,
      {required int maxDimension}) {
    if (source.width <= maxDimension && source.height <= maxDimension) {
      return source;
    }

    if (source.width >= source.height) {
      final int width = maxDimension;
      final int height = (source.height * (maxDimension / source.width))
          .round()
          .clamp(1, 10000);
      return img.copyResize(source, width: width, height: height);
    }

    final int height = maxDimension;
    final int width =
        (source.width * (maxDimension / source.height)).round().clamp(1, 10000);
    return img.copyResize(source, width: width, height: height);
  }

  String _mimeTypeFromName(String name) {
    final String lowerValue = name.trim().toLowerCase();
    if (lowerValue.endsWith('.gif')) {
      return 'image/gif';
    }
    if (lowerValue.endsWith('.png')) {
      return 'image/png';
    }
    if (lowerValue.endsWith('.webp')) {
      return 'image/webp';
    }
    if (lowerValue.endsWith('.heic')) {
      return 'image/heic';
    }
    if (lowerValue.endsWith('.heif')) {
      return 'image/heif';
    }
    if (lowerValue.endsWith('.jpg') || lowerValue.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    return '';
  }

  String _normalizeMimeType(String value) {
    final String lowerValue = value.trim().toLowerCase();
    if (lowerValue == 'image/jpg') {
      return 'image/jpeg';
    }
    return lowerValue;
  }

  bool _isGifMimeType(String value) {
    return _normalizeMimeType(value) == 'image/gif';
  }

  bool _canSendStillImageWithoutNormalization(String value) {
    final String normalized = _normalizeMimeType(value);
    return normalized == 'image/jpeg' ||
        normalized == 'image/png' ||
        normalized == 'image/webp';
  }
}

class _NormalizedStillImage {
  const _NormalizedStillImage({
    required this.bytes,
    required this.mimeType,
  });

  final Uint8List bytes;
  final String mimeType;
}
