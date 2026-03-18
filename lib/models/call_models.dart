import 'app_user.dart';

enum CallKind { audio, video }

enum CallConnectionMode { auto, directPreferred, directOnly, relayOnly }

enum CallSignalType { offer, answer, candidate, ringing, rejected, ended, busy }

enum CallLifecycle { idle, outgoingRinging, incomingRinging, connecting, active, ended, failed }

enum IceCandidateRouteType { host, srflx, prflx, relay, unknown }

class CallSettings {
  const CallSettings({
    this.connectionMode = CallConnectionMode.auto,
    this.shareLocalCandidates = true,
    this.sharePublicCandidates = true,
    this.allowRelayFallback = true,
  });

  final CallConnectionMode connectionMode;
  final bool shareLocalCandidates;
  final bool sharePublicCandidates;
  final bool allowRelayFallback;

  static const CallSettings defaults = CallSettings();

  CallSettings copyWith({
    CallConnectionMode? connectionMode,
    bool? shareLocalCandidates,
    bool? sharePublicCandidates,
    bool? allowRelayFallback,
  }) {
    return CallSettings(
      connectionMode: connectionMode ?? this.connectionMode,
      shareLocalCandidates: shareLocalCandidates ?? this.shareLocalCandidates,
      sharePublicCandidates:
          sharePublicCandidates ?? this.sharePublicCandidates,
      allowRelayFallback: allowRelayFallback ?? this.allowRelayFallback,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'connectionMode': connectionMode.name,
      'shareLocalCandidates': shareLocalCandidates,
      'sharePublicCandidates': sharePublicCandidates,
      'allowRelayFallback': allowRelayFallback,
    };
  }

  factory CallSettings.fromJson(Map<String, dynamic> json) {
    final String rawMode =
        json['connectionMode']?.toString() ?? CallConnectionMode.auto.name;
    final CallConnectionMode mode = CallConnectionMode.values.firstWhere(
      (CallConnectionMode value) => value.name == rawMode,
      orElse: () => CallConnectionMode.auto,
    );
    return CallSettings(
      connectionMode: mode,
      shareLocalCandidates: json['shareLocalCandidates'] != false,
      sharePublicCandidates: json['sharePublicCandidates'] != false,
      allowRelayFallback: json['allowRelayFallback'] != false,
    );
  }
}

class CallIceServer {
  const CallIceServer({
    required this.urls,
    this.username = '',
    this.credential = '',
  });

  final List<String> urls;
  final String username;
  final String credential;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'urls': urls,
      if (username.isNotEmpty) 'username': username,
      if (credential.isNotEmpty) 'credential': credential,
    };
  }

  factory CallIceServer.fromJson(Map<String, dynamic> json) {
    final Object? urlsValue = json['urls'];
    final List<String> urls;
    if (urlsValue is List<dynamic>) {
      urls = urlsValue.map((Object? value) => value.toString()).toList();
    } else if (urlsValue != null) {
      urls = <String>[urlsValue.toString()];
    } else {
      urls = <String>[];
    }
    return CallIceServer(
      urls: urls.where((String value) => value.trim().isNotEmpty).toList(),
      username: json['username']?.toString() ?? '',
      credential: json['credential']?.toString() ?? '',
    );
  }
}

class CallServerConfig {
  const CallServerConfig({
    this.iceServers = const <CallIceServer>[],
    this.turnConfigured = false,
    this.recommendedPollInterval = const Duration(milliseconds: 750),
  });

  final List<CallIceServer> iceServers;
  final bool turnConfigured;
  final Duration recommendedPollInterval;
}

class CallSummary {
  const CallSummary({
    required this.id,
    required this.kind,
    required this.status,
    required this.settings,
    required this.peer,
    required this.createdAt,
    this.answeredAt,
    this.endedAt,
  });

  final int id;
  final CallKind kind;
  final String status;
  final CallSettings settings;
  final AppUser peer;
  final DateTime createdAt;
  final DateTime? answeredAt;
  final DateTime? endedAt;
}

class CallSignalEvent {
  const CallSignalEvent({
    required this.id,
    required this.callId,
    required this.type,
    required this.payload,
    required this.call,
    required this.createdAt,
  });

  final int id;
  final int callId;
  final CallSignalType type;
  final Map<String, dynamic> payload;
  final CallSummary call;
  final DateTime createdAt;
}

class PollCallSignalsResult {
  const PollCallSignalsResult({
    required this.nextSinceId,
    required this.signals,
  });

  final int nextSinceId;
  final List<CallSignalEvent> signals;
}

class CallDiagnostics {
  const CallDiagnostics({
    this.connectionState = 'idle',
    this.routeSummary = 'No active call',
    this.localHostAddresses = const <String>[],
    this.publicAddresses = const <String>[],
    this.relayAddresses = const <String>[],
    this.remoteCandidateTypes = const <String>[],
    this.turnConfigured = false,
  });

  final String connectionState;
  final String routeSummary;
  final List<String> localHostAddresses;
  final List<String> publicAddresses;
  final List<String> relayAddresses;
  final List<String> remoteCandidateTypes;
  final bool turnConfigured;

  CallDiagnostics copyWith({
    String? connectionState,
    String? routeSummary,
    List<String>? localHostAddresses,
    List<String>? publicAddresses,
    List<String>? relayAddresses,
    List<String>? remoteCandidateTypes,
    bool? turnConfigured,
  }) {
    return CallDiagnostics(
      connectionState: connectionState ?? this.connectionState,
      routeSummary: routeSummary ?? this.routeSummary,
      localHostAddresses: localHostAddresses ?? this.localHostAddresses,
      publicAddresses: publicAddresses ?? this.publicAddresses,
      relayAddresses: relayAddresses ?? this.relayAddresses,
      remoteCandidateTypes: remoteCandidateTypes ?? this.remoteCandidateTypes,
      turnConfigured: turnConfigured ?? this.turnConfigured,
    );
  }
}

class ActiveCallState {
  const ActiveCallState({
    required this.lifecycle,
    this.callId,
    this.peer,
    this.kind = CallKind.audio,
    this.isMuted = false,
    this.isVideoEnabled = false,
    this.hasRemoteVideo = false,
    this.statusText = '',
    this.errorMessage,
    this.diagnostics = const CallDiagnostics(),
  });

  final CallLifecycle lifecycle;
  final int? callId;
  final AppUser? peer;
  final CallKind kind;
  final bool isMuted;
  final bool isVideoEnabled;
  final bool hasRemoteVideo;
  final String statusText;
  final String? errorMessage;
  final CallDiagnostics diagnostics;

  bool get isIdle => lifecycle == CallLifecycle.idle;
  bool get isIncoming => lifecycle == CallLifecycle.incomingRinging;
  bool get isOutgoing => lifecycle == CallLifecycle.outgoingRinging;
  bool get isInProgress =>
      lifecycle == CallLifecycle.outgoingRinging ||
      lifecycle == CallLifecycle.incomingRinging ||
      lifecycle == CallLifecycle.connecting ||
      lifecycle == CallLifecycle.active;

  static const ActiveCallState idle = ActiveCallState(
    lifecycle: CallLifecycle.idle,
  );

  ActiveCallState copyWith({
    CallLifecycle? lifecycle,
    int? callId,
    bool clearCallId = false,
    AppUser? peer,
    bool clearPeer = false,
    CallKind? kind,
    bool? isMuted,
    bool? isVideoEnabled,
    bool? hasRemoteVideo,
    String? statusText,
    String? errorMessage,
    bool clearErrorMessage = false,
    CallDiagnostics? diagnostics,
  }) {
    return ActiveCallState(
      lifecycle: lifecycle ?? this.lifecycle,
      callId: clearCallId ? null : (callId ?? this.callId),
      peer: clearPeer ? null : (peer ?? this.peer),
      kind: kind ?? this.kind,
      isMuted: isMuted ?? this.isMuted,
      isVideoEnabled: isVideoEnabled ?? this.isVideoEnabled,
      hasRemoteVideo: hasRemoteVideo ?? this.hasRemoteVideo,
      statusText: statusText ?? this.statusText,
      errorMessage: clearErrorMessage ? null : (errorMessage ?? this.errorMessage),
      diagnostics: diagnostics ?? this.diagnostics,
    );
  }
}
