import 'dart:convert';

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
}
