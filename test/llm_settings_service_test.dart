import 'package:backchat/models/llm_settings.dart';
import 'package:backchat/services/llm_settings_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('loads defaults when no settings were saved', () async {
    final LlmSettingsService service = LlmSettingsService();

    final LlmSettings settings = await service.load();

    expect(settings.contextMessageCount, 6);
    expect(settings.ollama.baseUrl, 'http://127.0.0.1:11434');
    expect(settings.ollama.timeoutSeconds, 30);
    expect(settings.remote.enabled, isFalse);
  });

  test('persists ollama and remote settings', () async {
    final LlmSettingsService service = LlmSettingsService();
    const LlmSettings settings = LlmSettings(
      contextMessageCount: 8,
      defaultFactCheckHandle: 'local-news',
      ollama: LlmProviderConfig(
        kind: LlmProviderKind.ollama,
        enabled: true,
        handle: 'local-news',
        baseUrl: 'http://localhost:11434',
        model: 'llama3.2',
        timeoutSeconds: 300,
      ),
      remote: LlmProviderConfig(
        kind: LlmProviderKind.openAiCompatible,
        enabled: true,
        handle: 'remote-pro',
        baseUrl: 'https://api.example.com/v1',
        model: 'gpt-4.1-mini',
        apiKey: 'secret-key',
      ),
    );

    await service.save(settings);
    final LlmSettings restored = await service.load();

    expect(restored.contextMessageCount, 8);
    expect(restored.defaultFactCheckHandle, 'local-news');
    expect(restored.ollama.enabled, isTrue);
    expect(restored.ollama.model, 'llama3.2');
    expect(restored.ollama.timeoutSeconds, 300);
    expect(restored.remote.enabled, isTrue);
    expect(restored.remote.baseUrl, 'https://api.example.com/v1');
    expect(restored.remote.apiKey, 'secret-key');
  });

  test('clamps saved local timeout to ten minutes', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'llm_settings_v1':
          '{"ollama":{"kind":"ollama","enabled":true,"baseUrl":"http://127.0.0.1:11434","model":"llama3.2","timeoutSeconds":9999}}',
    });
    final LlmSettingsService service = LlmSettingsService();

    final LlmSettings settings = await service.load();

    expect(settings.ollama.timeoutSeconds, 600);
    expect(settings.ollama.requestTimeout, const Duration(minutes: 10));
  });
}
