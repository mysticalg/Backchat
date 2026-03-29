enum LlmProviderKind {
  ollama,
  openAiCompatible,
}

class LlmProviderConfig {
  const LlmProviderConfig({
    required this.kind,
    this.enabled = false,
    this.handle = '',
    this.baseUrl = '',
    this.model = '',
    this.apiKey = '',
  });

  final LlmProviderKind kind;
  final bool enabled;
  final String handle;
  final String baseUrl;
  final String model;
  final String apiKey;

  static const LlmProviderConfig defaultOllama = LlmProviderConfig(
    kind: LlmProviderKind.ollama,
    baseUrl: 'http://127.0.0.1:11434',
    handle: 'ollama',
  );

  static const LlmProviderConfig defaultRemote = LlmProviderConfig(
    kind: LlmProviderKind.openAiCompatible,
    handle: 'remote',
  );

  String get normalizedHandle {
    final String explicit = LlmSettings.normalizeMention(handle);
    if (explicit.isNotEmpty) {
      return explicit;
    }
    return LlmSettings.suggestMentionFromModel(model);
  }

  bool get isConfigured {
    if (!enabled) {
      return false;
    }
    return normalizedHandle.isNotEmpty &&
        baseUrl.trim().isNotEmpty &&
        model.trim().isNotEmpty;
  }

  String get displayLabel {
    if (normalizedHandle.isNotEmpty) {
      return normalizedHandle;
    }
    if (model.trim().isNotEmpty) {
      return model.trim();
    }
    return kind == LlmProviderKind.ollama ? 'ollama' : 'remote';
  }

  LlmProviderConfig copyWith({
    bool? enabled,
    String? handle,
    String? baseUrl,
    String? model,
    String? apiKey,
  }) {
    return LlmProviderConfig(
      kind: kind,
      enabled: enabled ?? this.enabled,
      handle: handle ?? this.handle,
      baseUrl: baseUrl ?? this.baseUrl,
      model: model ?? this.model,
      apiKey: apiKey ?? this.apiKey,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'kind': kind.name,
      'enabled': enabled,
      'handle': handle,
      'baseUrl': baseUrl,
      'model': model,
      if (apiKey.isNotEmpty) 'apiKey': apiKey,
    };
  }

  factory LlmProviderConfig.fromJson(
    Map<String, dynamic> json, {
    required LlmProviderKind fallbackKind,
  }) {
    final String rawKind = json['kind']?.toString() ?? fallbackKind.name;
    final LlmProviderKind kind = LlmProviderKind.values.firstWhere(
      (LlmProviderKind value) => value.name == rawKind,
      orElse: () => fallbackKind,
    );
    return LlmProviderConfig(
      kind: kind,
      enabled: json['enabled'] == true,
      handle: json['handle']?.toString() ?? '',
      baseUrl: json['baseUrl']?.toString() ?? '',
      model: json['model']?.toString() ?? '',
      apiKey: json['apiKey']?.toString() ?? '',
    );
  }
}

class LlmSettings {
  const LlmSettings({
    this.ollama = LlmProviderConfig.defaultOllama,
    this.remote = LlmProviderConfig.defaultRemote,
    this.contextMessageCount = 6,
    this.defaultFactCheckHandle = '',
  });

  static const LlmSettings defaults = LlmSettings();

  final LlmProviderConfig ollama;
  final LlmProviderConfig remote;
  final int contextMessageCount;
  final String defaultFactCheckHandle;

  List<LlmProviderConfig> get configuredProviders {
    return <LlmProviderConfig>[
      if (ollama.isConfigured) ollama,
      if (remote.isConfigured) remote,
    ];
  }

  LlmProviderConfig? providerForMention(String mention) {
    final String normalized = normalizeMention(mention);
    if (normalized.isEmpty) {
      return null;
    }

    for (final LlmProviderConfig provider in <LlmProviderConfig>[
      ollama,
      remote,
    ]) {
      if (!provider.isConfigured) {
        continue;
      }
      if (provider.normalizedHandle == normalized) {
        return provider;
      }
      if (suggestMentionFromModel(provider.model) == normalized) {
        return provider;
      }
      if (normalizeMention(provider.model) == normalized) {
        return provider;
      }
    }
    return null;
  }

  LlmProviderConfig? get defaultFactCheckProvider {
    final LlmProviderConfig? explicit =
        providerForMention(defaultFactCheckHandle);
    if (explicit != null) {
      return explicit;
    }
    if (ollama.isConfigured) {
      return ollama;
    }
    if (remote.isConfigured) {
      return remote;
    }
    return null;
  }

  LlmSettings copyWith({
    LlmProviderConfig? ollama,
    LlmProviderConfig? remote,
    int? contextMessageCount,
    String? defaultFactCheckHandle,
  }) {
    return LlmSettings(
      ollama: ollama ?? this.ollama,
      remote: remote ?? this.remote,
      contextMessageCount: contextMessageCount ?? this.contextMessageCount,
      defaultFactCheckHandle:
          defaultFactCheckHandle ?? this.defaultFactCheckHandle,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'ollama': ollama.toJson(),
      'remote': remote.toJson(),
      'contextMessageCount': contextMessageCount,
      if (defaultFactCheckHandle.isNotEmpty)
        'defaultFactCheckHandle': defaultFactCheckHandle,
    };
  }

  factory LlmSettings.fromJson(Map<String, dynamic> json) {
    final Object? countValue = json['contextMessageCount'];
    final int parsedCount = countValue is int
        ? countValue
        : int.tryParse(countValue?.toString() ?? '') ??
            defaults.contextMessageCount;
    return LlmSettings(
      ollama: json['ollama'] is Map<String, dynamic>
          ? LlmProviderConfig.fromJson(
              json['ollama'] as Map<String, dynamic>,
              fallbackKind: LlmProviderKind.ollama,
            )
          : LlmProviderConfig.defaultOllama,
      remote: json['remote'] is Map<String, dynamic>
          ? LlmProviderConfig.fromJson(
              json['remote'] as Map<String, dynamic>,
              fallbackKind: LlmProviderKind.openAiCompatible,
            )
          : LlmProviderConfig.defaultRemote,
      contextMessageCount: parsedCount.clamp(2, 12) as int,
      defaultFactCheckHandle: json['defaultFactCheckHandle']?.toString() ?? '',
    );
  }

  static String normalizeMention(String value) {
    String normalized = value.trim().toLowerCase();
    if (normalized.startsWith('@')) {
      normalized = normalized.substring(1);
    }
    normalized = normalized.replaceAll(RegExp(r'[^a-z0-9._:-]+'), '-');
    normalized = normalized.replaceAll(RegExp(r'-{2,}'), '-');
    return normalized.replaceAll(RegExp(r'^-+|-+$'), '');
  }

  static String suggestMentionFromModel(String model) {
    final String normalizedModel = model.trim().toLowerCase();
    if (normalizedModel.isEmpty) {
      return '';
    }
    final String lastPathSegment = normalizedModel.split('/').last;
    final List<String> candidates = <String>[
      lastPathSegment.split(':').first,
      lastPathSegment,
      normalizedModel.split(':').first,
      normalizedModel,
    ];
    for (final String candidate in candidates) {
      final String normalized = normalizeMention(candidate);
      if (normalized.isNotEmpty) {
        return normalized;
      }
    }
    return '';
  }
}
