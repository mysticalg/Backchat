import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class ConversationBotService {
  static const String _storageKey = 'conversation_bots_v1';

  Future<List<String>> loadEnabledBotUserIds({
    required String currentUserId,
    required String contactUserId,
  }) async {
    final Map<String, dynamic> payload = await _loadPayload();
    final Object? rawValue = payload[_key(currentUserId, contactUserId)];
    if (rawValue is! List<dynamic>) {
      return <String>[];
    }
    return rawValue
        .map((Object? value) => value?.toString().trim() ?? '')
        .where((String value) => value.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
  }

  Future<void> saveEnabledBotUserIds({
    required String currentUserId,
    required String contactUserId,
    required Iterable<String> botUserIds,
  }) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final Map<String, dynamic> payload = await _loadPayload();
    final List<String> cleaned = botUserIds
        .map((String value) => value.trim())
        .where((String value) => value.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    final String storageKey = _key(currentUserId, contactUserId);
    if (cleaned.isEmpty) {
      payload.remove(storageKey);
    } else {
      payload[storageKey] = cleaned;
    }
    await prefs.setString(_storageKey, jsonEncode(payload));
  }

  Future<Map<String, dynamic>> _loadPayload() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) {
      return <String, dynamic>{};
    }
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      // Ignore malformed persisted state and rebuild it from scratch.
    }
    return <String, dynamic>{};
  }

  String _key(String currentUserId, String contactUserId) {
    final String raw = '$currentUserId|$contactUserId';
    return base64Url.encode(utf8.encode(raw));
  }
}
