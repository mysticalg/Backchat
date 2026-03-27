import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class ConversationBackgroundService {
  static const String _storageKey = 'conversation_backgrounds_v1';

  Future<String?> loadBackgroundUrl({
    required String currentUserId,
    required String contactUserId,
  }) async {
    final Map<String, dynamic> backgrounds = await _readAll();
    final String value =
        backgrounds[_key(currentUserId, contactUserId)]?.toString().trim() ??
            '';
    return value.isEmpty ? null : value;
  }

  Future<void> saveBackgroundUrl({
    required String currentUserId,
    required String contactUserId,
    required String url,
  }) async {
    final String cleanedUrl = url.trim();
    final Map<String, dynamic> backgrounds = await _readAll();
    if (cleanedUrl.isEmpty) {
      backgrounds.remove(_key(currentUserId, contactUserId));
    } else {
      backgrounds[_key(currentUserId, contactUserId)] = cleanedUrl;
    }
    await _writeAll(backgrounds);
  }

  Future<void> clearBackgroundUrl({
    required String currentUserId,
    required String contactUserId,
  }) async {
    final Map<String, dynamic> backgrounds = await _readAll();
    backgrounds.remove(_key(currentUserId, contactUserId));
    await _writeAll(backgrounds);
  }

  Future<Map<String, dynamic>> _readAll() async {
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
      // Ignore malformed storage and reset to empty.
    }
    return <String, dynamic>{};
  }

  Future<void> _writeAll(Map<String, dynamic> value) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, jsonEncode(value));
  }

  String _key(String currentUserId, String contactUserId) {
    return '$currentUserId|$contactUserId';
  }
}
