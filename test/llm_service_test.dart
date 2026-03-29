import 'dart:convert';

import 'package:backchat/models/llm_settings.dart';
import 'package:backchat/services/llm_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('parses @model commands against configured providers', () {
    const LlmSettings settings = LlmSettings(
      ollama: LlmProviderConfig(
        kind: LlmProviderKind.ollama,
        enabled: true,
        handle: 'ollama-3',
        baseUrl: 'http://127.0.0.1:11434',
        model: 'llama3.2',
      ),
    );
    final LlmService service = LlmService(client: MockClient((_) async {
      throw UnimplementedError();
    }));

    final LlmPromptCommand? command = service.parseCommand(
      rawText: '@ollama-3 is this true?',
      settings: settings,
    );

    expect(command, isNotNull);
    expect(command!.provider.kind, LlmProviderKind.ollama);
    expect(command.prompt, 'is this true?');
    expect(command.isLikelyFactCheck, isTrue);
  });

  test('fetches Ollama models from the tags endpoint', () async {
    final LlmService service = LlmService(
      client: MockClient((http.Request request) async {
        expect(request.url.toString(), 'http://127.0.0.1:11434/api/tags');
        return http.Response(
          jsonEncode(<String, dynamic>{
            'models': <Map<String, String>>[
              <String, String>{'name': 'llama3.2'},
              <String, String>{'name': 'mistral'},
            ],
          }),
          200,
        );
      }),
    );

    final List<String> models =
        await service.fetchOllamaModels('http://127.0.0.1:11434');

    expect(models, <String>['llama3.2', 'mistral']);
  });

  test('uses the configured Ollama timeout for local model replies', () async {
    final LlmService service = LlmService(
      client: MockClient((http.Request request) async {
        if (request.url.path == '/api/chat') {
          await Future<void>.delayed(const Duration(seconds: 2));
        }
        return http.Response(
          jsonEncode(<String, dynamic>{
            'message': <String, String>{'content': 'late'},
          }),
          200,
        );
      }),
    );

    await expectLater(
      service.generateReply(
        provider: const LlmProviderConfig(
          kind: LlmProviderKind.ollama,
          enabled: true,
          handle: 'ollama-3',
          baseUrl: 'http://127.0.0.1:11434',
          model: 'llama3.2',
          timeoutSeconds: 1,
        ),
        prompt: 'hello',
        contextLines: const <LlmContextLine>[],
      ),
      throwsA(
        isA<LlmServiceException>().having(
          (LlmServiceException e) => e.message,
          'message',
          contains('1 second'),
        ),
      ),
    );
  });

  test('includes fetched news context in Ollama fact-check prompts', () async {
    String capturedBody = '';
    final LlmService service = LlmService(
      client: MockClient((http.Request request) async {
        if (request.url.host == 'news.google.com') {
          return http.Response(
            '''
<rss>
  <channel>
    <item>
      <title>BBC Verify checks the rumour</title>
      <link>https://news.google.com/articles/test-1</link>
      <source>BBC News</source>
      <pubDate>Sat, 29 Mar 2026 10:00:00 GMT</pubDate>
      <description><![CDATA[Officials said the claim was false.]]></description>
    </item>
  </channel>
</rss>
''',
            200,
            headers: <String, String>{
              'content-type': 'application/rss+xml',
            },
          );
        }
        if (request.url.path == '/api/chat') {
          capturedBody = request.body;
          return http.Response(
            jsonEncode(<String, dynamic>{
              'message': <String, String>{
                'content': 'False. Recent reporting does not support it.',
              },
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      }),
    );

    final String reply = await service.generateReply(
      provider: const LlmProviderConfig(
        kind: LlmProviderKind.ollama,
        enabled: true,
        handle: 'ollama-3',
        baseUrl: 'http://127.0.0.1:11434',
        model: 'llama3.2',
      ),
      prompt: 'is this true?',
      contextLines: const <LlmContextLine>[
        LlmContextLine(
          speaker: 'Alice',
          text: 'America just got bombed.',
        ),
      ],
      factCheck: true,
      factCheckQuery: 'America just got bombed',
      contactName: 'Alice',
    );

    expect(reply, 'False. Recent reporting does not support it.');
    expect(
        capturedBody, contains('Recent news/web context gathered by the app'));
    expect(capturedBody, contains('BBC Verify checks the rumour'));
    expect(capturedBody, contains('Officials said the claim was false.'));
  });

  test('posts remote requests to the OpenAI-compatible chat endpoint',
      () async {
    Uri? capturedUri;
    String? capturedAuthorization;
    final LlmService service = LlmService(
      client: MockClient((http.Request request) async {
        capturedUri = request.url;
        capturedAuthorization = request.headers['Authorization'];
        return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, String>{
                  'content': 'Checked.',
                },
              },
            ],
          }),
          200,
        );
      }),
    );

    final String reply = await service.generateReply(
      provider: const LlmProviderConfig(
        kind: LlmProviderKind.openAiCompatible,
        enabled: true,
        handle: 'remote-ai',
        baseUrl: 'https://api.example.com',
        model: 'gpt-4.1-mini',
        apiKey: 'test-key',
      ),
      prompt: 'Summarize this thread.',
      contextLines: const <LlmContextLine>[
        LlmContextLine(
          speaker: 'You',
          text: 'Can you summarize this?',
        ),
      ],
      contactName: 'Alice',
    );

    expect(reply, 'Checked.');
    expect(
      capturedUri.toString(),
      'https://api.example.com/v1/chat/completions',
    );
    expect(capturedAuthorization, 'Bearer test-key');
  });
}
