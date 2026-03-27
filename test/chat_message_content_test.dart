import 'package:backchat/models/chat_message_content.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('round-trips structured transport payloads', () {
    final ChatMessageContent original = ChatMessageContent.gif(
      url: 'https://example.com/fun.gif',
      caption: 'Weekend mood',
    );

    final ChatMessageContent? decoded =
        ChatMessageContent.tryFromTransportPayload(
      original.toTransportPayload(),
    );

    expect(decoded, isNotNull);
    expect(decoded!.kind, ChatMessageContentKind.gif);
    expect(decoded.url, 'https://example.com/fun.gif');
    expect(decoded.text, 'Weekend mood');
  });

  test('builds useful previews for non-text messages', () {
    expect(
      ChatMessageContent.sticker(
        emoji: '🎉',
        label: 'Celebrate',
      ).previewText,
      'Sticker: Celebrate',
    );
    expect(
      ChatMessageContent.file(
        url: 'https://example.com/file.pdf',
        label: 'Spec PDF',
      ).previewText,
      'File: Spec PDF',
    );
    expect(
      ChatMessageContent.background(
        url: 'https://example.com/wallpaper.jpg',
        label: 'Ocean blue',
      ).previewText,
      'Background: Ocean blue',
    );
  });
}
