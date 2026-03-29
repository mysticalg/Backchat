import 'package:backchat/services/link_preview_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('extracts the first http url from text', () {
    final LinkPreviewService service = LinkPreviewService();

    final Uri? url = service.extractFirstUrl(
      'See this https://backchatapp.co.uk/#downloads right now.',
    );

    expect(url, isNotNull);
    expect(url.toString(), 'https://backchatapp.co.uk/#downloads');
  });

  test('extracts scheme-less urls from text', () {
    final LinkPreviewService service = LinkPreviewService();

    final Uri? url = service.extractFirstUrl(
      'Watch this youtu.be/dQw4w9WgXcQ?si=abc123 right now.',
    );

    expect(url, isNotNull);
    expect(url.toString(), 'https://youtu.be/dQw4w9WgXcQ?si=abc123');
  });

  test('recognizes direct audio and video links by extension', () {
    final LinkPreviewService service = LinkPreviewService();

    expect(service.isDirectAudioUrl('https://example.com/clip.mp3'), isTrue);
    expect(service.isDirectAudioUrl('https://example.com/clip.wav'), isTrue);
    expect(service.isDirectVideoUrl('https://example.com/movie.mp4'), isTrue);
    expect(service.isDirectVideoUrl('https://example.com/movie.webm'), isTrue);
    expect(
      service.isDirectVideoUrl('https://www.youtube.com/watch?v=abc123'),
      isFalse,
    );
  });
}
