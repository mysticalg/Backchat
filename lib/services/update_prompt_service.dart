import 'package:shared_preferences/shared_preferences.dart';

class UpdatePromptService {
  static const String _storageKeyUpdateKey = 'update_prompt_v1_key';
  static const String _storageKeyShownAt = 'update_prompt_v1_shown_at_utc';
  static const Duration promptInterval = Duration(days: 1);

  Future<bool> shouldPromptForUpdate({
    required String updateKey,
    DateTime? now,
  }) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String storedKey = prefs.getString(_storageKeyUpdateKey) ?? '';
    final DateTime? shownAt = DateTime.tryParse(
      prefs.getString(_storageKeyShownAt) ?? '',
    );
    if (storedKey != updateKey || shownAt == null) {
      return true;
    }
    final DateTime effectiveNow = (now ?? DateTime.now()).toUtc();
    return effectiveNow.difference(shownAt.toUtc()) >= promptInterval;
  }

  Future<void> markPromptShown({
    required String updateKey,
    DateTime? now,
  }) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKeyUpdateKey, updateKey);
    await prefs.setString(
      _storageKeyShownAt,
      (now ?? DateTime.now()).toUtc().toIso8601String(),
    );
  }

  Future<void> clear() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKeyUpdateKey);
    await prefs.remove(_storageKeyShownAt);
  }
}
