import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/call_models.dart';

class CallSettingsService {
  static const String _storageKey = 'call_settings_v1';

  Future<CallSettings> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) {
      return CallSettings.defaults;
    }

    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return CallSettings.fromJson(decoded);
      }
    } catch (_) {
      // Ignore invalid local settings and fall back to defaults.
    }
    return CallSettings.defaults;
  }

  Future<void> save(CallSettings settings) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, jsonEncode(settings.toJson()));
  }
}
