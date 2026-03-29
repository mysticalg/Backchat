class SocialEmbedDescriptor {
  const SocialEmbedDescriptor({
    required this.provider,
    required this.sourceUrl,
    required this.embedUrl,
    required this.aspectRatio,
    required this.title,
  });

  final String provider;
  final Uri sourceUrl;
  final String embedUrl;
  final double aspectRatio;
  final String title;
}

class SocialEmbedService {
  const SocialEmbedService();

  SocialEmbedDescriptor? resolve(String rawUrl) {
    final Uri? uri = Uri.tryParse(rawUrl.trim());
    if (uri == null || !uri.hasScheme) {
      return null;
    }

    final String host = uri.host.toLowerCase();
    if (host.contains('youtube.com') || host.contains('youtu.be')) {
      final String? videoId = _youtubeVideoId(uri);
      if (videoId == null || videoId.isEmpty) {
        return null;
      }
      return SocialEmbedDescriptor(
        provider: 'youtube',
        sourceUrl: uri,
        embedUrl:
            'https://www.youtube.com/embed/$videoId?playsinline=1&rel=0&modestbranding=1',
        aspectRatio: 16 / 9,
        title: 'YouTube',
      );
    }

    if (host.contains('instagram.com')) {
      final List<String> segments = uri.pathSegments;
      if (segments.length >= 2 &&
          (segments.first == 'reel' ||
              segments.first == 'p' ||
              segments.first == 'tv')) {
        final String kind = segments.first;
        final String postId = segments[1];
        final bool isReel = kind == 'reel';
        return SocialEmbedDescriptor(
          provider: 'instagram',
          sourceUrl: uri,
          embedUrl:
              'https://www.instagram.com/$kind/$postId/embed/captioned/',
          aspectRatio: isReel ? (9 / 16) : 1,
          title: 'Instagram',
        );
      }
    }

    if (host.contains('twitter.com') || host.contains('x.com')) {
      final String? tweetId = _statusId(uri);
      if (tweetId == null || tweetId.isEmpty) {
        return null;
      }
      return SocialEmbedDescriptor(
        provider: 'x',
        sourceUrl: uri,
        embedUrl: 'https://platform.twitter.com/embed/Tweet.html?id=$tweetId',
        aspectRatio: 16 / 10,
        title: 'X',
      );
    }

    if (host.contains('facebook.com') || host.contains('fb.watch')) {
      final bool looksLikeReel = uri.pathSegments.contains('reel') ||
          uri.pathSegments.contains('reels') ||
          host.contains('fb.watch');
      return SocialEmbedDescriptor(
        provider: 'facebook',
        sourceUrl: uri,
        embedUrl:
            'https://www.facebook.com/plugins/video.php?href=${Uri.encodeComponent(uri.toString())}&show_text=false&autoplay=false',
        aspectRatio: looksLikeReel ? (9 / 16) : (16 / 9),
        title: 'Facebook',
      );
    }

    return null;
  }

  String buildEmbedHtml(SocialEmbedDescriptor descriptor) {
    final String safeTitle = _escapeHtml(descriptor.title);
    final String safeEmbedUrl = descriptor.embedUrl;
    return '''
<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
    <style>
      html, body {
        margin: 0;
        padding: 0;
        width: 100%;
        height: 100%;
        overflow: hidden;
        background: #000;
      }
      iframe {
        border: 0;
        width: 100%;
        height: 100%;
        background: #000;
      }
    </style>
  </head>
  <body>
    <iframe
      src="$safeEmbedUrl"
      title="$safeTitle"
      allow="autoplay; clipboard-write; encrypted-media; fullscreen; picture-in-picture"
      allowfullscreen
      referrerpolicy="origin-when-cross-origin">
    </iframe>
  </body>
</html>
''';
  }

  String? _youtubeVideoId(Uri uri) {
    final String host = uri.host.toLowerCase();
    if (host.contains('youtu.be') && uri.pathSegments.isNotEmpty) {
      return uri.pathSegments.first;
    }
    if (!host.contains('youtube.com')) {
      return null;
    }
    if (uri.pathSegments.contains('watch')) {
      return uri.queryParameters['v'];
    }
    if (uri.pathSegments.length >= 2 &&
        (uri.pathSegments.first == 'embed' ||
            uri.pathSegments.first == 'shorts')) {
      return uri.pathSegments[1];
    }
    return null;
  }

  String? _statusId(Uri uri) {
    final int statusIndex = uri.pathSegments.indexOf('status');
    if (statusIndex == -1 || statusIndex + 1 >= uri.pathSegments.length) {
      return null;
    }
    return uri.pathSegments[statusIndex + 1];
  }

  String _escapeHtml(String value) {
    return value
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }
}
