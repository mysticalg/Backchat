import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class ConversationSessionService {
  static const String _storagePrefix = 'conversation_session_v1_';

  Future<String?> loadLastSelectedContactId({
    required String currentUserId,
  }) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? rawValue = prefs.getString(_storageKeyForUser(currentUserId));
    final String trimmed = rawValue?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }

  Future<void> saveLastSelectedContactId({
    required String currentUserId,
    required String? contactUserId,
  }) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String key = _storageKeyForUser(currentUserId);
    final String normalized = contactUserId?.trim() ?? '';
    if (normalized.isEmpty) {
      await prefs.remove(key);
      return;
    }
    await prefs.setString(key, normalized);
  }

  String _storageKeyForUser(String userId) {
    final String encoded = base64Url.encode(utf8.encode(userId));
    return '$_storagePrefix$encoded';
  }
}
