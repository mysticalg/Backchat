import 'dart:convert';

import 'package:http/http.dart' as http;

class OpenAiService {
  OpenAiService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<String> generatePrompt({
    required String apiKey,
    required String userInput,
    String model = 'gpt-4.1-mini',
    int maxOutputTokens = 300,
  }) async {
    final Uri responsesUri = Uri.parse('https://api.openai.com/v1/responses');

    final http.Response responsesResult = await _client.post(
      responsesUri,
      headers: _headers(apiKey),
      body: jsonEncode(<String, dynamic>{
        'model': model,
        'input': userInput,
        'max_output_tokens': maxOutputTokens,
      }),
    );

    if (responsesResult.statusCode >= 200 && responsesResult.statusCode < 300) {
      return _extractTextFromResponsesApi(responsesResult.body);
    }

    final bool shouldFallbackToChatCompletions = responsesResult.statusCode == 404;
    if (shouldFallbackToChatCompletions) {
      return _generateViaChatCompletions(
        apiKey: apiKey,
        userInput: userInput,
        model: model,
        maxOutputTokens: maxOutputTokens,
      );
    }

    throw Exception('OpenAI request failed: ${responsesResult.statusCode} ${responsesResult.body}');
  }

  Future<String> _generateViaChatCompletions({
    required String apiKey,
    required String userInput,
    required String model,
    required int maxOutputTokens,
  }) async {
    final Uri completionsUri = Uri.parse('https://api.openai.com/v1/chat/completions');

    final http.Response completionResult = await _client.post(
      completionsUri,
      headers: _headers(apiKey),
      body: jsonEncode(<String, dynamic>{
        'model': model,
        'messages': <Map<String, String>>[
          <String, String>{'role': 'user', 'content': userInput},
        ],
        'max_completion_tokens': maxOutputTokens,
      }),
    );

    if (completionResult.statusCode >= 200 && completionResult.statusCode < 300) {
      return _extractTextFromChatCompletionsApi(completionResult.body);
    }

    throw Exception('OpenAI request failed: ${completionResult.statusCode} ${completionResult.body}');
  }

  Map<String, String> _headers(String apiKey) {
    return <String, String>{
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $apiKey',
    };
  }

  String _extractTextFromResponsesApi(String responseBody) {
    final Map<String, dynamic> decoded = jsonDecode(responseBody) as Map<String, dynamic>;
    final String? directOutput = decoded['output_text'] as String?;
    if (directOutput != null && directOutput.isNotEmpty) {
      return directOutput;
    }

    final List<dynamic>? output = decoded['output'] as List<dynamic>?;
    if (output == null) {
      throw const FormatException('Responses API payload did not include output text.');
    }

    for (final dynamic item in output) {
      if (item is! Map<String, dynamic>) continue;
      final List<dynamic>? content = item['content'] as List<dynamic>?;
      if (content == null) continue;

      for (final dynamic entry in content) {
        if (entry is! Map<String, dynamic>) continue;
        final String? text = entry['text'] as String?;
        if (text != null && text.isNotEmpty) {
          return text;
        }
      }
    }

    throw const FormatException('Responses API payload did not include output text.');
  }

  String _extractTextFromChatCompletionsApi(String responseBody) {
    final Map<String, dynamic> decoded = jsonDecode(responseBody) as Map<String, dynamic>;
    final List<dynamic>? choices = decoded['choices'] as List<dynamic>?;
    if (choices == null || choices.isEmpty) {
      throw const FormatException('Chat Completions payload did not include choices.');
    }

    final Map<String, dynamic>? firstChoice = choices.first as Map<String, dynamic>?;
    final Map<String, dynamic>? message = firstChoice?['message'] as Map<String, dynamic>?;
    final String? content = message?['content'] as String?;

    if (content == null || content.isEmpty) {
      throw const FormatException('Chat Completions payload did not include message content.');
    }

    return content;
  }
}
