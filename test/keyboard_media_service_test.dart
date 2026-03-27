import 'dart:typed_data';

import 'package:backchat/models/chat_message_content.dart';
import 'package:backchat/services/keyboard_media_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final KeyboardMediaService service = KeyboardMediaService();

  test('builds gif chat content from inline bytes', () {
    final ChatMessageContent content = service.contentFromBytes(
      bytes: Uint8List.fromList(<int>[71, 73, 70, 56, 57, 97]),
      mimeType: 'image/gif',
    );

    expect(content.kind, ChatMessageContentKind.gif);
    expect(content.url.startsWith('data:image/gif;base64,'), isTrue);
  });

  test('decodes data urls created for keyboard media', () {
    final Uint8List bytes = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);
    final String dataUrl = service.buildDataUrl(
      bytes: bytes,
      mimeType: 'image/webp',
    );

    expect(service.isDataUrl(dataUrl), isTrue);
    expect(service.tryDecodeDataUrl(dataUrl), bytes);
  });
}
