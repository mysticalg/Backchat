import 'dart:convert';
import 'dart:typed_data';

import 'package:backchat/services/backchat_api_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('shares auth tokens across api service instances after account switch',
      () async {
    final List<String?> authHeaders = <String?>[];
    final MockClient client = MockClient((http.Request request) async {
      if (request.url.path.endsWith('/auth_username.php')) {
        final Map<String, dynamic> body =
            jsonDecode(request.body) as Map<String, dynamic>;
        final String username = body['username']?.toString() ?? '';
        final String token =
            username == 'funkymonk' ? 'token-funkymonk' : 'token-previous-user';
        return http.Response(
          jsonEncode(<String, dynamic>{
            'ok': true,
            'status': 'signed_in',
            'token': token,
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }

      if (request.url.path.endsWith('/contacts.php')) {
        authHeaders.add(request.headers['authorization']);
        return http.Response(
          jsonEncode(<String, dynamic>{
            'ok': true,
            'status': 'ok',
            'contacts': <Map<String, dynamic>>[],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }

      throw StateError('Unexpected request to ${request.url}');
    });

    final BackchatApiService firstService = BackchatApiService(client: client);
    final BackchatApiService secondService = BackchatApiService(client: client);

    await firstService.signInOrCreateWithUsername(
      username: 'previous_user',
      recoveryEmail: 'previous@example.com',
      password: '',
    );
    await firstService.fetchContacts();

    await secondService.signInOrCreateWithUsername(
      username: 'funkymonk',
      recoveryEmail: 'funky@example.com',
      password: '',
    );
    await firstService.fetchContacts();

    expect(
      authHeaders,
      <String?>['Bearer token-previous-user', 'Bearer token-funkymonk'],
    );
  });

  test('uploads media in JSON chunks for cloudfront-hosted api uploads',
      () async {
    final List<String> modes = <String>[];
    final List<int> chunkLengths = <int>[];
    final MockClient client = MockClient((http.Request request) async {
      if (!request.url.path.endsWith('/upload_media.php')) {
        throw StateError('Unexpected request to ${request.url}');
      }

      expect(request.headers['authorization'], 'Bearer token-media');
      final Map<String, dynamic> body =
          jsonDecode(request.body) as Map<String, dynamic>;
      final String mode = body['mode']?.toString() ?? '';
      modes.add(mode);

      switch (mode) {
        case 'chunked_start':
          return http.Response(
            jsonEncode(<String, dynamic>{
              'ok': true,
              'status': 'chunked_upload_started',
              'upload': <String, dynamic>{
                'token': 'upload-123',
                'maxChunkBytes': 4096,
              },
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        case 'chunked_append':
          final String encodedChunk = body['chunkBase64']?.toString() ?? '';
          chunkLengths.add(base64Decode(encodedChunk).length);
          expect(body['uploadToken'], 'upload-123');
          return http.Response(
            jsonEncode(<String, dynamic>{
              'ok': true,
              'status': 'chunked_upload_appended',
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        case 'chunked_finish':
          expect(body['uploadToken'], 'upload-123');
          return http.Response(
            jsonEncode(<String, dynamic>{
              'ok': true,
              'status': 'uploaded',
              'media': <String, dynamic>{
                'url': 'https://example.com/media.gif',
                'mimeType': 'image/gif',
                'kind': 'gif',
                'sizeBytes': 9000,
              },
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
      }

      throw StateError('Unexpected upload mode: $mode');
    });

    final BackchatApiService service = BackchatApiService(client: client);
    await service.clearToken();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString('backchat_api_token_v1', 'token-media');
    final UploadedMedia uploadedMedia = await service.uploadMedia(
      bytes: Uint8List.fromList(List<int>.filled(9000, 1)),
      mimeType: 'image/gif',
      filename: 'party.gif',
    );

    expect(
      modes,
      <String>[
        'chunked_start',
        'chunked_append',
        'chunked_append',
        'chunked_append',
        'chunked_finish',
      ],
    );
    expect(chunkLengths, <int>[4096, 4096, 808]);
    expect(uploadedMedia.url, 'https://example.com/media.gif');
    expect(uploadedMedia.mimeType, 'image/gif');
    expect(uploadedMedia.kind, 'gif');
    expect(uploadedMedia.sizeBytes, 9000);
  });
}
