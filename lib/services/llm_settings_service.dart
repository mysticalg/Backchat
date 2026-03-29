import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/llm_settings.dart';

class LlmSettingsService {
  static const String _storageKey = 'llm_settings_v1';

  Future<LlmSettings> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) {
      return LlmSettings.defaults;
    }

    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return LlmSettings.fromJson(decoded);
      }
    } catch (_) {
      // Ignore malformed settings and fall back to defaults.
    }
    return LlmSettings.defaults;
  }

  Future<void> save(LlmSettings settings) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, jsonEncode(settings.toJson()));
  }
}
