import 'dart:async';
import 'dart:convert';

import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../models/llm_settings.dart';

class LlmContextLine {
  const LlmContextLine({
    required this.speaker,
    required this.text,
  });

  final String speaker;
  final String text;
}

class LlmPromptCommand {
  const LlmPromptCommand({
    required this.provider,
    required this.prompt,
    required this.rawMention,
    required this.isLikelyFactCheck,
  });

  final LlmProviderConfig provider;
  final String prompt;
  final String rawMention;
  final bool isLikelyFactCheck;
}

class LlmNewsSource {
  const LlmNewsSource({
    required this.title,
    required this.url,
    this.source = '',
    this.summary = '',
    this.publishedLabel = '',
  });

  final String title;
  final String url;
  final String source;
  final String summary;
  final String publishedLabel;
}

class LlmServiceException implements Exception {
  const LlmServiceException(this.message);

  final String message;

  @override
  String toString() => 'LlmServiceException($message)';
}

class LlmService {
  LlmService({http.Client? client}) : _client = client ?? http.Client();

  static final RegExp _commandPattern =
      RegExp(r'^\s*@([A-Za-z0-9._:-]+)\s+(.+)$', dotAll: true);
  static const Duration _requestTimeout = Duration(seconds: 30);

  final http.Client _client;

  LlmPromptCommand? parseCommand({
    required String rawText,
    required LlmSettings settings,
  }) {
    final RegExpMatch? match = _commandPattern.firstMatch(rawText);
    if (match == null) {
      return null;
    }

    final String rawMention = match.group(1)?.trim() ?? '';
    final String prompt = match.group(2)?.trim() ?? '';
    if (rawMention.isEmpty || prompt.isEmpty) {
      return null;
    }

    final LlmProviderConfig? provider = settings.providerForMention(rawMention);
    if (provider == null) {
      return null;
    }

    return LlmPromptCommand(
      provider: provider,
      prompt: prompt,
      rawMention: rawMention,
      isLikelyFactCheck: looksLikeFactCheck(prompt),
    );
  }

  bool looksLikeFactCheck(String prompt) {
    final String normalized = prompt.trim().toLowerCase();
    if (normalized.isEmpty) {
      return false;
    }
    return normalized.contains('fact check') ||
        normalized.contains('fact-check') ||
        normalized.contains('is this true') ||
        normalized.contains('is that true') ||
        normalized.contains('is it true') ||
        normalized.contains('check the news') ||
        normalized.contains('verify') ||
        normalized.startsWith('true?');
  }

  Future<List<String>> fetchOllamaModels(String baseUrl) async {
    final Uri uri = _resolveOllamaUri(baseUrl, 'tags');
    http.Response response;
    try {
      response = await _client.get(uri).timeout(_requestTimeout);
    } on TimeoutException {
      throw const LlmServiceException(
        'The Ollama server took too long to respond.',
      );
    } catch (_) {
      throw const LlmServiceException(
        'Could not reach the Ollama server.',
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw LlmServiceException(
        'Ollama returned HTTP ${response.statusCode} while listing models.',
      );
    }

    try {
      final Object? decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const LlmServiceException(
          'Ollama returned an invalid model list.',
        );
      }
      final List<dynamic> rows = decoded['models'] is List<dynamic>
          ? decoded['models'] as List<dynamic>
          : <dynamic>[];
      final List<String> models = rows
          .whereType<Map<String, dynamic>>()
          .map((Map<String, dynamic> row) => row['name']?.toString() ?? '')
          .where((String name) => name.trim().isNotEmpty)
          .toList()
        ..sort();
      return models;
    } catch (e) {
      if (e is LlmServiceException) {
        rethrow;
      }
      throw const LlmServiceException(
        'Could not parse the Ollama model list.',
      );
    }
  }

  Future<String> generateReply({
    required LlmProviderConfig provider,
    required String prompt,
    required List<LlmContextLine> contextLines,
    bool factCheck = false,
    String factCheckQuery = '',
    String contactName = '',
    String assistantName = '',
    bool participantMode = false,
  }) async {
    if (!provider.isConfigured) {
      throw const LlmServiceException(
        'This model is not configured yet.',
      );
    }

    final bool shouldFetchNews = factCheck || factCheckQuery.trim().isNotEmpty;
    final List<LlmNewsSource> newsSources = shouldFetchNews
        ? await _fetchNewsSources(
            factCheckQuery.trim().isNotEmpty ? factCheckQuery : prompt,
          )
        : const <LlmNewsSource>[];
    final String systemPrompt = _buildSystemPrompt(
      factCheck: shouldFetchNews,
      participantMode: participantMode,
      assistantName: assistantName,
    );
    final String userPrompt = _buildUserPrompt(
      prompt: prompt,
      contextLines: contextLines,
      newsSources: newsSources,
      contactName: contactName,
      factCheck: shouldFetchNews,
      participantMode: participantMode,
    );

    return switch (provider.kind) {
      LlmProviderKind.ollama => _chatWithOllama(
          provider: provider,
          systemPrompt: systemPrompt,
          userPrompt: userPrompt,
        ),
      LlmProviderKind.openAiCompatible => _chatWithOpenAiCompatible(
          provider: provider,
          systemPrompt: systemPrompt,
          userPrompt: userPrompt,
        ),
    };
  }

  Future<String> _chatWithOllama({
    required LlmProviderConfig provider,
    required String systemPrompt,
    required String userPrompt,
  }) async {
    final Uri uri = _resolveOllamaUri(provider.baseUrl, 'chat');
    http.Response response;
    try {
      response = await _client
          .post(
            uri,
            headers: const <String, String>{
              'Content-Type': 'application/json',
            },
            body: jsonEncode(<String, dynamic>{
              'model': provider.model.trim(),
              'stream': false,
              'messages': <Map<String, String>>[
                <String, String>{
                  'role': 'system',
                  'content': systemPrompt,
                },
                <String, String>{
                  'role': 'user',
                  'content': userPrompt,
                },
              ],
            }),
          )
          .timeout(provider.requestTimeout);
    } on TimeoutException {
      throw LlmServiceException(
        'The Ollama model took longer than ${_formatDurationLabel(provider.requestTimeout)} to respond.',
      );
    } catch (_) {
      throw const LlmServiceException(
        'Could not contact the Ollama server.',
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw LlmServiceException(
        'Ollama returned HTTP ${response.statusCode} for that chat request.',
      );
    }

    try {
      final Object? decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const LlmServiceException('Ollama returned an invalid reply.');
      }
      final Object? messagePayload = decoded['message'];
      if (messagePayload is Map<String, dynamic>) {
        final String content =
            messagePayload['content']?.toString().trim() ?? '';
        if (content.isNotEmpty) {
          return content;
        }
      }
      final String fallback = decoded['response']?.toString().trim() ?? '';
      if (fallback.isNotEmpty) {
        return fallback;
      }
    } catch (e) {
      if (e is LlmServiceException) {
        rethrow;
      }
      throw const LlmServiceException('Could not read the Ollama reply.');
    }

    throw const LlmServiceException(
        'The Ollama model returned an empty reply.');
  }

  Future<String> _chatWithOpenAiCompatible({
    required LlmProviderConfig provider,
    required String systemPrompt,
    required String userPrompt,
  }) async {
    final Uri uri = _resolveOpenAiChatUri(provider.baseUrl);
    final Map<String, String> headers = <String, String>{
      'Content-Type': 'application/json',
    };
    if (provider.apiKey.trim().isNotEmpty) {
      headers['Authorization'] = 'Bearer ${provider.apiKey.trim()}';
    }

    http.Response response;
    try {
      response = await _client
          .post(
            uri,
            headers: headers,
            body: jsonEncode(<String, dynamic>{
              'model': provider.model.trim(),
              'temperature': 0.2,
              'messages': <Map<String, String>>[
                <String, String>{
                  'role': 'system',
                  'content': systemPrompt,
                },
                <String, String>{
                  'role': 'user',
                  'content': userPrompt,
                },
              ],
            }),
          )
          .timeout(_requestTimeout);
    } on TimeoutException {
      throw const LlmServiceException(
        'The remote model took too long to respond.',
      );
    } catch (_) {
      throw const LlmServiceException(
        'Could not contact the remote model endpoint.',
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw LlmServiceException(
        _openAiErrorMessage(response.body, response.statusCode),
      );
    }

    try {
      final Object? decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const LlmServiceException(
          'The remote model returned an invalid reply.',
        );
      }
      final List<dynamic> choices = decoded['choices'] is List<dynamic>
          ? decoded['choices'] as List<dynamic>
          : <dynamic>[];
      if (choices.isEmpty) {
        throw const LlmServiceException(
          'The remote model returned an empty reply.',
        );
      }
      final Object? firstChoice = choices.first;
      if (firstChoice is! Map<String, dynamic>) {
        throw const LlmServiceException(
          'The remote model returned an invalid reply.',
        );
      }
      final Object? message = firstChoice['message'];
      final String content = _extractContentFromChatPayload(message);
      if (content.isNotEmpty) {
        return content;
      }
    } catch (e) {
      if (e is LlmServiceException) {
        rethrow;
      }
      throw const LlmServiceException(
        'Could not read the remote model reply.',
      );
    }

    throw const LlmServiceException(
      'The remote model returned an empty reply.',
    );
  }

  String _buildSystemPrompt({
    required bool factCheck,
    required bool participantMode,
    required String assistantName,
  }) {
    final String identityInstruction = assistantName.trim().isEmpty
        ? ''
        : ' Your display name in the app is ${assistantName.trim()}.';
    if (factCheck) {
      return 'You are a careful fact-checking assistant inside a messaging app. '
          '$identityInstruction'
          'Use the recent thread context and any supplied news/web sources. '
          'Separate confirmed facts from rumors, mention uncertainty clearly, '
          'and cite useful sources with markdown links.';
    }
    final String roleInstruction = participantMode
        ? 'Write exactly one natural chat reply as a participant in the conversation, not as a narrator or analyst. '
        : '';
    return 'You are a concise assistant inside a messaging app.'
        '$identityInstruction '
        'Use the recent thread context when it matters, answer directly, '
        'and avoid pretending to know things that are not supported. '
        '$roleInstruction';
  }

  String _buildUserPrompt({
    required String prompt,
    required List<LlmContextLine> contextLines,
    required List<LlmNewsSource> newsSources,
    required String contactName,
    required bool factCheck,
    required bool participantMode,
  }) {
    final StringBuffer buffer = StringBuffer();
    if (contactName.trim().isNotEmpty) {
      buffer.writeln('Conversation partner: ${contactName.trim()}');
      buffer.writeln();
    }
    buffer.writeln('Recent thread context:');
    if (contextLines.isEmpty) {
      buffer.writeln('- No recent messages were available.');
    } else {
      for (final LlmContextLine line in contextLines) {
        final String speaker =
            line.speaker.trim().isEmpty ? 'Unknown' : line.speaker.trim();
        final String text =
            line.text.trim().isEmpty ? '[empty]' : line.text.trim();
        buffer.writeln('- $speaker: $text');
      }
    }
    if (factCheck) {
      buffer.writeln();
      buffer.writeln('Recent news/web context gathered by the app:');
      if (newsSources.isEmpty) {
        buffer.writeln(
          '- No fresh news results were retrieved, so say clearly if live verification is limited.',
        );
      } else {
        for (final LlmNewsSource source in newsSources) {
          final List<String> meta = <String>[
            if (source.source.trim().isNotEmpty) source.source.trim(),
            if (source.publishedLabel.trim().isNotEmpty)
              source.publishedLabel.trim(),
          ];
          final String metaLabel = meta.isEmpty ? '' : ' (${meta.join(' | ')})';
          buffer.writeln('- [${source.title}](${source.url})$metaLabel');
          if (source.summary.trim().isNotEmpty) {
            buffer.writeln('  Summary: ${source.summary.trim()}');
          }
        }
      }
    }
    buffer.writeln();
    buffer.writeln('User request:');
    buffer.writeln(prompt.trim());
    buffer.writeln();
    buffer.writeln(
      factCheck
          ? 'Reply with a short verdict first, then the reasoning and sources.'
          : participantMode
              ? 'Reply naturally as a participant in this thread.'
              : 'Reply naturally as the assistant in this thread.',
    );
    return buffer.toString().trim();
  }

  Future<List<LlmNewsSource>> _fetchNewsSources(
    String rawQuery, {
    int limit = 4,
  }) async {
    final String query = rawQuery.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (query.isEmpty) {
      return const <LlmNewsSource>[];
    }

    final Uri uri = Uri.https(
      'news.google.com',
      '/rss/search',
      <String, String>{
        'q': query,
        'hl': 'en-GB',
        'gl': 'GB',
        'ceid': 'GB:en',
      },
    );

    try {
      final http.Response response =
          await _client.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return const <LlmNewsSource>[];
      }

      final RegExp itemPattern =
          RegExp(r'<item\b[^>]*>([\s\S]*?)</item>', caseSensitive: false);
      final Iterable<RegExpMatch> matches =
          itemPattern.allMatches(response.body).take(limit);
      final List<LlmNewsSource> results = <LlmNewsSource>[];
      for (final RegExpMatch match in matches) {
        final String itemXml = match.group(1)?.trim() ?? '';
        final String title = _rssTagValue(itemXml, 'title');
        final String url = _rssTagValue(itemXml, 'link');
        if (title.isEmpty || url.isEmpty) {
          continue;
        }
        final String source = _rssTagValue(itemXml, 'source');
        final String published = _rssTagValue(itemXml, 'pubDate');
        final String rawDescription = _rssTagValue(itemXml, 'description');
        final String summary =
            html_parser.parseFragment(rawDescription).text?.trim() ?? '';
        results.add(
          LlmNewsSource(
            title: title,
            url: url,
            source: source,
            publishedLabel: published,
            summary: summary,
          ),
        );
      }
      return results;
    } catch (_) {
      return const <LlmNewsSource>[];
    }
  }

  String _rssTagValue(String xml, String tagName) {
    final RegExp tagPattern = RegExp(
      '<$tagName\\b[^>]*>([\\s\\S]*?)</$tagName>',
      caseSensitive: false,
    );
    final RegExpMatch? match = tagPattern.firstMatch(xml);
    if (match == null) {
      return '';
    }
    String value = match.group(1)?.trim() ?? '';
    value = value.replaceAll(RegExp(r'<!\[CDATA\[|\]\]>'), '');
    return html_parser.parseFragment(value).text?.trim() ?? '';
  }

  Uri _resolveOllamaUri(String baseUrl, String action) {
    final Uri base = _parseBaseUri(baseUrl);
    final String path = base.path.toLowerCase().endsWith('/api') ||
            base.path.toLowerCase() == '/api'
        ? _joinPath(base.path, action)
        : _joinPath(base.path, 'api/$action');
    return base.replace(path: path);
  }

  Uri _resolveOpenAiChatUri(String baseUrl) {
    final Uri base = _parseBaseUri(baseUrl);
    final String lowerPath = base.path.toLowerCase();
    if (lowerPath.endsWith('/chat/completions')) {
      return base;
    }
    if (lowerPath.endsWith('/v1') || lowerPath == '/v1') {
      return base.replace(path: _joinPath(base.path, 'chat/completions'));
    }
    return base.replace(path: _joinPath(base.path, 'v1/chat/completions'));
  }

  Uri _parseBaseUri(String baseUrl) {
    final String trimmed = baseUrl.trim();
    if (trimmed.isEmpty) {
      throw const LlmServiceException('Enter a model server URL first.');
    }
    final String normalized =
        trimmed.contains('://') ? trimmed : 'http://$trimmed';
    final Uri? uri = Uri.tryParse(normalized);
    if (uri == null || !uri.hasScheme || uri.host.trim().isEmpty) {
      throw const LlmServiceException('Enter a valid model server URL.');
    }
    return uri;
  }

  String _joinPath(String left, String right) {
    final String cleanedLeft = left.replaceAll(RegExp(r'/+$'), '');
    final String cleanedRight = right.replaceAll(RegExp(r'^/+'), '');
    if (cleanedLeft.isEmpty) {
      return '/$cleanedRight';
    }
    return '$cleanedLeft/$cleanedRight';
  }

  String _extractContentFromChatPayload(Object? payload) {
    if (payload is! Map<String, dynamic>) {
      return '';
    }
    final Object? content = payload['content'];
    if (content is String) {
      return content.trim();
    }
    if (content is List<dynamic>) {
      final String joined = content
          .whereType<Map<String, dynamic>>()
          .map((Map<String, dynamic> part) => part['text']?.toString() ?? '')
          .where((String value) => value.trim().isNotEmpty)
          .join('\n')
          .trim();
      return joined;
    }
    return '';
  }

  String _openAiErrorMessage(String body, int statusCode) {
    try {
      final Object? decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final Object? error = decoded['error'];
        if (error is Map<String, dynamic>) {
          final String message = error['message']?.toString().trim() ?? '';
          if (message.isNotEmpty) {
            return message;
          }
        }
      }
    } catch (_) {
      // Ignore malformed error bodies.
    }
    return 'The remote model returned HTTP $statusCode.';
  }

  String _formatDurationLabel(Duration duration) {
    final int totalSeconds = duration.inSeconds;
    if (totalSeconds % 60 == 0) {
      final int minutes = totalSeconds ~/ 60;
      if (minutes == 1) {
        return '1 minute';
      }
      return '$minutes minutes';
    }
    if (totalSeconds == 1) {
      return '1 second';
    }
    return '$totalSeconds seconds';
  }
}
