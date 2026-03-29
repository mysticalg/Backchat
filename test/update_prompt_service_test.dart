import 'package:backchat/services/update_prompt_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('prompts immediately for a new update key', () async {
    final UpdatePromptService service = UpdatePromptService();

    final bool shouldPrompt = await service.shouldPromptForUpdate(
      updateKey: '0.1.0+15',
      now: DateTime.parse('2026-03-29T12:00:00Z'),
    );

    expect(shouldPrompt, isTrue);
  });

  test('suppresses repeat prompts for the same update within one day', () async {
    final UpdatePromptService service = UpdatePromptService();
    final DateTime initialTime = DateTime.parse('2026-03-29T12:00:00Z');

    await service.markPromptShown(
      updateKey: '0.1.0+15',
      now: initialTime,
    );

    expect(
      await service.shouldPromptForUpdate(
        updateKey: '0.1.0+15',
        now: initialTime.add(const Duration(hours: 8)),
      ),
      isFalse,
    );
    expect(
      await service.shouldPromptForUpdate(
        updateKey: '0.1.0+15',
        now: initialTime.add(const Duration(days: 1, minutes: 1)),
      ),
      isTrue,
    );
  });

  test('prompts immediately when a newer update key appears', () async {
    final UpdatePromptService service = UpdatePromptService();
    final DateTime initialTime = DateTime.parse('2026-03-29T12:00:00Z');

    await service.markPromptShown(
      updateKey: '0.1.0+15',
      now: initialTime,
    );

    final bool shouldPrompt = await service.shouldPromptForUpdate(
      updateKey: '0.1.0+16',
      now: initialTime.add(const Duration(hours: 2)),
    );

    expect(shouldPrompt, isTrue);
  });
}
