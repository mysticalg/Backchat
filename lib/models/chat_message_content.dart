import 'dart:convert';

enum ChatMessageContentKind {
  text,
  image,
  gif,
  sticker,
  background,
  video,
  audio,
  file,
}

class ChatMessageContent {
  const ChatMessageContent({
    required this.kind,
    this.text = '',
    this.url = '',
    this.label = '',
  });

  static const String transportMode = 'message_payload_v1';

  final ChatMessageContentKind kind;
  final String text;
  final String url;
  final String label;

  factory ChatMessageContent.text(String value) {
    return ChatMessageContent(
      kind: ChatMessageContentKind.text,
      text: value,
    );
  }

  factory ChatMessageContent.image({
    required String url,
    String caption = '',
  }) {
    return ChatMessageContent(
      kind: ChatMessageContentKind.image,
      url: url,
      text: caption,
    );
  }

  factory ChatMessageContent.gif({
    required String url,
    String caption = '',
  }) {
    return ChatMessageContent(
      kind: ChatMessageContentKind.gif,
      url: url,
      text: caption,
    );
  }

  factory ChatMessageContent.sticker({
    required String emoji,
    String label = '',
  }) {
    return ChatMessageContent(
      kind: ChatMessageContentKind.sticker,
      text: emoji,
      label: label,
    );
  }

  factory ChatMessageContent.background({
    required String url,
    String label = '',
  }) {
    return ChatMessageContent(
      kind: ChatMessageContentKind.background,
      url: url,
      label: label,
    );
  }

  factory ChatMessageContent.video({
    required String url,
    String caption = '',
  }) {
    return ChatMessageContent(
      kind: ChatMessageContentKind.video,
      url: url,
      text: caption,
    );
  }

  factory ChatMessageContent.audio({
    required String url,
    String caption = '',
  }) {
    return ChatMessageContent(
      kind: ChatMessageContentKind.audio,
      url: url,
      text: caption,
    );
  }

  factory ChatMessageContent.file({
    required String url,
    String label = '',
    String caption = '',
  }) {
    return ChatMessageContent(
      kind: ChatMessageContentKind.file,
      url: url,
      label: label,
      text: caption,
    );
  }

  bool get hasUrl => url.trim().isNotEmpty;
  bool get hasText => text.trim().isNotEmpty;
  bool get hasLabel => label.trim().isNotEmpty;

  String get previewText {
    return switch (kind) {
      ChatMessageContentKind.text => text,
      ChatMessageContentKind.image => hasText ? 'Photo: $text' : 'Photo',
      ChatMessageContentKind.gif => hasText ? 'GIF: $text' : 'GIF',
      ChatMessageContentKind.sticker =>
        hasLabel ? 'Sticker: $label' : 'Sticker',
      ChatMessageContentKind.background =>
        hasLabel ? 'Background: $label' : 'Shared background',
      ChatMessageContentKind.video => hasText ? 'Video: $text' : 'Video',
      ChatMessageContentKind.audio => hasText ? 'Audio: $text' : 'Audio',
      ChatMessageContentKind.file =>
        hasLabel ? 'File: $label' : (hasText ? 'File: $text' : 'File'),
    };
  }

  String toTransportPayload() {
    return jsonEncode(<String, dynamic>{
      'mode': transportMode,
      'content': toJson(),
    });
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'kind': kind.name,
      if (text.isNotEmpty) 'text': text,
      if (url.isNotEmpty) 'url': url,
      if (label.isNotEmpty) 'label': label,
    };
  }

  factory ChatMessageContent.fromJson(Map<String, dynamic> json) {
    final String rawKind =
        json['kind']?.toString() ?? ChatMessageContentKind.text.name;
    final ChatMessageContentKind kind =
        ChatMessageContentKind.values.firstWhere(
      (ChatMessageContentKind value) => value.name == rawKind,
      orElse: () => ChatMessageContentKind.text,
    );
    return ChatMessageContent(
      kind: kind,
      text: json['text']?.toString() ?? '',
      url: json['url']?.toString() ?? '',
      label: json['label']?.toString() ?? '',
    );
  }

  static ChatMessageContent? tryFromTransportPayload(String payload) {
    try {
      final Object? decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic> ||
          decoded['mode'] != transportMode) {
        return null;
      }

      final Object? contentPayload = decoded['content'];
      if (contentPayload is! Map<String, dynamic>) {
        return null;
      }
      return ChatMessageContent.fromJson(contentPayload);
    } catch (_) {
      return null;
    }
  }

  static ChatMessageContent? tryFromLegacyPayload(String payload) {
    try {
      final Object? decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }

      if (decoded.containsKey('kind')) {
        return ChatMessageContent.fromJson(decoded);
      }

      final String text =
          decoded['text']?.toString() ?? decoded['message']?.toString() ?? '';
      if (text.isEmpty) {
        return null;
      }
      return ChatMessageContent.text(text);
    } catch (_) {
      return null;
    }
  }
}
