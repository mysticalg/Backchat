import 'dart:convert';

import 'package:backchat/services/giphy_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('searches GIPHY and parses preview and send urls', () async {
    late Uri requestedUri;
    final MockClient client = MockClient((http.Request request) async {
      requestedUri = request.url;
      return http.Response(
        jsonEncode(<String, dynamic>{
          'data': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'abc123',
              'title': 'Happy Cat',
              'url': 'https://giphy.com/gifs/happy-cat-abc123',
              'images': <String, dynamic>{
                'fixed_width_downsampled': <String, dynamic>{
                  'url': 'https://media1.giphy.com/media/abc123/200w_d.gif',
                },
                'downsized_medium': <String, dynamic>{
                  'url': 'https://media1.giphy.com/media/abc123/giphy.gif',
                },
              },
            },
          ],
          'pagination': <String, dynamic>{
            'offset': 0,
            'count': 1,
            'total_count': 3,
          },
          'meta': <String, dynamic>{
            'status': 200,
            'msg': 'OK',
          },
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });

    final GiphyService service = GiphyService(
      client: client,
      apiKey: 'test-key',
    );
    final GiphyQueryResult result = await service.search(
      'happy cat',
      languageCode: 'en-GB',
    );

    expect(requestedUri.path, '/v1/gifs/search');
    expect(requestedUri.queryParameters['api_key'], 'test-key');
    expect(requestedUri.queryParameters['q'], 'happy cat');
    expect(requestedUri.queryParameters['lang'], 'en');
    expect(result.gifs, hasLength(1));
    expect(result.gifs.first.id, 'abc123');
    expect(
      result.gifs.first.previewUrl,
      'https://media1.giphy.com/media/abc123/200w_d.gif',
    );
    expect(
      result.gifs.first.sendUrl,
      'https://media1.giphy.com/media/abc123/giphy.gif',
    );
    expect(result.gifs.first.title, 'Happy Cat');
    expect(result.nextOffset, 1);
    expect(result.hasMore, isTrue);
  });

  test('falls back to trending when search query is blank', () async {
    late Uri requestedUri;
    final MockClient client = MockClient((http.Request request) async {
      requestedUri = request.url;
      return http.Response(
        jsonEncode(<String, dynamic>{
          'data': <Map<String, dynamic>>[],
          'pagination': <String, dynamic>{
            'offset': 0,
            'count': 0,
            'total_count': 0,
          },
          'meta': <String, dynamic>{
            'status': 200,
            'msg': 'OK',
          },
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });

    final GiphyService service = GiphyService(
      client: client,
      apiKey: 'test-key',
    );
    await service.search('   ');

    expect(requestedUri.path, '/v1/gifs/trending');
  });

  test('throws a friendly error when the api key is missing', () async {
    final GiphyService service = GiphyService(apiKey: '');

    expect(
      () => service.trending(),
      throwsA(
        isA<GiphyException>().having(
          (GiphyException error) => error.message,
          'message',
          'GIPHY search is not configured in this build.',
        ),
      ),
    );
  });
}
