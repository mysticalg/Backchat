import 'package:backchat/services/social_embed_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const SocialEmbedService service = SocialEmbedService();

  test('builds youtube embed urls', () {
    final SocialEmbedDescriptor? descriptor = service.resolve(
      'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
    );

    expect(descriptor, isNotNull);
    expect(descriptor!.provider, 'youtube');
    expect(
      descriptor.embedUrl,
      contains('https://www.youtube.com/embed/dQw4w9WgXcQ'),
    );
  });

  test('builds x tweet embed urls', () {
    final SocialEmbedDescriptor? descriptor = service.resolve(
      'https://x.com/backchat/status/1234567890',
    );

    expect(descriptor, isNotNull);
    expect(descriptor!.provider, 'x');
    expect(
      descriptor.embedUrl,
      'https://platform.twitter.com/embed/Tweet.html?id=1234567890',
    );
  });

  test('builds instagram reel embed urls', () {
    final SocialEmbedDescriptor? descriptor = service.resolve(
      'https://www.instagram.com/reel/C8abc123xyz/',
    );

    expect(descriptor, isNotNull);
    expect(descriptor!.provider, 'instagram');
    expect(
      descriptor.embedUrl,
      'https://www.instagram.com/reel/C8abc123xyz/embed/captioned/',
    );
  });

  test('builds facebook plugin embed urls', () {
    final SocialEmbedDescriptor? descriptor = service.resolve(
      'https://www.facebook.com/reel/1234567890/',
    );

    expect(descriptor, isNotNull);
    expect(descriptor!.provider, 'facebook');
    expect(descriptor.embedUrl, contains('facebook.com/plugins/video.php'));
  });
}
