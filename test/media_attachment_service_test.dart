import 'dart:typed_data';

import 'package:backchat/models/chat_message_content.dart';
import 'package:backchat/services/media_attachment_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  test('builds GIF chat content for uploadable GIF files', () {
    final MediaAttachmentService service = MediaAttachmentService();

    final ChatMessageContent content = service.contentFromBytes(
      bytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
      nameHint: 'fun.gif',
      mimeTypeHint: 'image/gif',
    );

    expect(content.kind, ChatMessageContentKind.gif);
    expect(content.url.startsWith('data:image/gif;base64,'), isTrue);
  });

  test('rejects GIF files that exceed the upload limit', () {
    final MediaAttachmentService service = MediaAttachmentService();

    expect(
      () => service.contentFromBytes(
        bytes: Uint8List(MediaAttachmentService.maxAttachmentBytes + 1),
        nameHint: 'huge.gif',
        mimeTypeHint: 'image/gif',
      ),
      throwsA(isA<MediaAttachmentException>()),
    );
  });

  test('compresses oversized still images into inline image payloads', () {
    final MediaAttachmentService service = MediaAttachmentService();
    final img.Image image = img.Image(width: 1200, height: 1200);
    for (int y = 0; y < image.height; y += 1) {
      for (int x = 0; x < image.width; x += 1) {
        image.setPixelRgba(
          x,
          y,
          x % 256,
          y % 256,
          (x + y) % 256,
          255,
        );
      }
    }
    final Uint8List oversizedBmp = Uint8List.fromList(img.encodeBmp(image));
    expect(
      oversizedBmp.length,
      greaterThan(MediaAttachmentService.maxInlineBytes),
    );

    final ChatMessageContent content = service.contentFromBytes(
      bytes: oversizedBmp,
      nameHint: 'photo.bmp',
      mimeTypeHint: 'image/bmp',
    );

    expect(content.kind, ChatMessageContentKind.image);
    expect(content.url.startsWith('data:image/jpeg;base64,'), isTrue);
  });
}
