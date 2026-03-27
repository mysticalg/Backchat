import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_user.dart';
import '../models/call_models.dart';
import 'backchat_api_service.dart';
import 'call_settings_service.dart';

class CallService extends ChangeNotifier {
  CallService({
    BackchatApiClient? apiService,
    CallSettingsService? settingsService,
    CallSignalCursorStore? signalCursorStore,
  })  : _apiService = apiService ?? BackchatApiService(),
        _settingsService = settingsService ?? CallSettingsService(),
        _signalCursorStore = signalCursorStore ?? CallSignalCursorStore();

  static const CallServerConfig _fallbackServerConfig = CallServerConfig(
    iceServers: <CallIceServer>[
      CallIceServer(
        urls: <String>[
          'stun:stun.l.google.com:19302',
          'stun:stun1.l.google.com:19302',
        ],
      ),
    ],
  );

  final BackchatApiClient _apiService;
  final CallSettingsService _settingsService;
  final CallSignalCursorStore _signalCursorStore;

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();

  CallSettings _settings = CallSettings.defaults;
  CallServerConfig _serverConfig = _fallbackServerConfig;
  ActiveCallState _state = ActiveCallState.idle;

  AppUser? _currentUser;
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  CallSummary? _activeCall;
  RTCSessionDescription? _pendingRemoteOffer;

  final List<RTCIceCandidate> _pendingRemoteCandidates = <RTCIceCandidate>[];
  final List<Map<String, dynamic>> _bufferedOutboundCandidates =
      <Map<String, dynamic>>[];
  final Set<String> _sentCandidateFingerprints = <String>{};
  final Set<String> _localHostAddresses = <String>{};
  final Set<String> _publicAddresses = <String>{};
  final Set<String> _relayAddresses = <String>{};
  final Set<String> _remoteCandidateTypes = <String>{};

  Timer? _signalPollTimer;
  Timer? _idleResetTimer;
  bool _renderersReady = false;
  bool _isPollingSignals = false;
  bool _disposed = false;
  int _signalSinceId = 0;

  CallSettings get settings => _settings;
  CallServerConfig get serverConfig => _serverConfig;
  ActiveCallState get state => _state;

  Future<void> initialize() async {
    if (_renderersReady) {
      return;
    }
    await localRenderer.initialize();
    await remoteRenderer.initialize();
    _settings = await _settingsService.load();
    _renderersReady = true;
    _updateDiagnostics();
  }

  Future<void> activateForUser(AppUser user) async {
    await initialize();
    _currentUser = user;
    _signalSinceId = await _signalCursorStore.load(user.id);
    await refreshServerConfig();
    _restartSignalPolling();
    await _pollSignals();
  }

  Future<void> deactivate() async {
    _signalPollTimer?.cancel();
    _signalPollTimer = null;
    _idleResetTimer?.cancel();
    _idleResetTimer = null;
    _currentUser = null;
    _signalSinceId = 0;
    _pendingRemoteOffer = null;
    _activeCall = null;
    _pendingRemoteCandidates.clear();
    _bufferedOutboundCandidates.clear();
    _sentCandidateFingerprints.clear();
    _serverConfig = _fallbackServerConfig;
    await _teardownPeerResources();
    _clearDiagnostics();
    _updateDiagnostics();
    _setState(ActiveCallState.idle);
  }

  Future<void> refreshServerConfig() async {
    if (!_apiService.isConfigured || _currentUser == null) {
      _serverConfig = _fallbackServerConfig;
      _updateDiagnostics();
      return;
    }

    try {
      _serverConfig = await _apiService.fetchCallConfig();
    } catch (_) {
      _serverConfig = _fallbackServerConfig;
    }
    _updateDiagnostics();
    _restartSignalPolling();
    notifyListeners();
  }

  Future<void> updateSettings(CallSettings next) async {
    _settings = next;
    await _settingsService.save(next);
    _updateDiagnostics();
    notifyListeners();
  }

  Future<void> startOutgoingCall({
    required AppUser peer,
    required CallKind kind,
  }) async {
    if (_currentUser == null) {
      throw const BackchatApiException(
        status: 'unauthorized',
        message: 'Sign in before starting a call.',
      );
    }
    if (!_apiService.isConfigured) {
      throw const BackchatApiException(
        status: 'api_not_configured',
        message: 'Calling requires the shared backend.',
      );
    }
    if (_state.isInProgress) {
      throw const BackchatApiException(
        status: 'call_busy',
        message: 'Finish the current call before starting another one.',
      );
    }

    _idleResetTimer?.cancel();
    await _preparePeerConnection(kind: kind, createLocalMedia: true);

    try {
      final RTCSessionDescription offer =
          await _peerConnection!.createOffer(<String, dynamic>{
        'offerToReceiveAudio': 1,
        'offerToReceiveVideo': kind == CallKind.video ? 1 : 0,
      });
      await _peerConnection!.setLocalDescription(offer);

      final CallSummary call = await _apiService.startCall(
        toUsername: peer.username,
        kind: kind,
        offerType: offer.type ?? 'offer',
        offerSdp: offer.sdp ?? '',
        settings: _settings,
      );
      _activeCall = call;
      _setState(
        ActiveCallState(
          lifecycle: CallLifecycle.outgoingRinging,
          callId: call.id,
          peer: call.peer,
          kind: kind,
          isInitiator: true,
          isVideoEnabled: kind == CallKind.video,
          statusText: 'Calling ${call.peer.displayName}…',
          diagnostics: _buildDiagnostics(connectionState: 'new'),
        ),
      );
      await _flushBufferedOutboundCandidates();
    } catch (error) {
      await _teardownPeerResources();
      rethrow;
    }
  }

  Future<void> answerIncomingCall() async {
    final CallSummary? activeCall = _activeCall;
    final RTCSessionDescription? pendingRemoteOffer = _pendingRemoteOffer;
    if (activeCall == null || pendingRemoteOffer == null) {
      return;
    }

    _idleResetTimer?.cancel();
    await _preparePeerConnection(
      kind: activeCall.kind,
      createLocalMedia: true,
      preservePendingRemoteCandidates: true,
    );
    await _peerConnection!.setRemoteDescription(pendingRemoteOffer);
    await _flushPendingRemoteCandidates();

    final RTCSessionDescription answer =
        await _peerConnection!.createAnswer(<String, dynamic>{
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': activeCall.kind == CallKind.video ? 1 : 0,
    });
    await _peerConnection!.setLocalDescription(answer);
    await _apiService.sendCallSignal(
      callId: activeCall.id,
      type: CallSignalType.answer,
      payload: <String, dynamic>{
        'description': <String, dynamic>{
          'type': answer.type,
          'sdp': answer.sdp,
        },
      },
    );
    _pendingRemoteOffer = null;
    _setState(
      _state.copyWith(
        lifecycle: CallLifecycle.connecting,
        statusText: 'Connecting to ${activeCall.peer.displayName}…',
        diagnostics: _buildDiagnostics(connectionState: 'connecting'),
      ),
    );
    await _flushBufferedOutboundCandidates();
  }

  Future<void> rejectIncomingCall() async {
    if (_activeCall == null) {
      return;
    }
    await _apiService.sendCallSignal(
      callId: _activeCall!.id,
      type: CallSignalType.rejected,
      payload: const <String, dynamic>{'reason': 'declined'},
    );
    await _finishCall(
      lifecycle: CallLifecycle.ended,
      statusText: 'Call declined.',
    );
  }

  Future<void> endCall({bool notifyRemote = true}) async {
    final CallSummary? activeCall = _activeCall;
    if (activeCall != null && notifyRemote && _apiService.isConfigured) {
      try {
        await _apiService.sendCallSignal(
          callId: activeCall.id,
          type: CallSignalType.ended,
          payload: const <String, dynamic>{'reason': 'hangup'},
        );
      } catch (_) {
        // Tear down locally even if the remote notification fails.
      }
    }
    await _finishCall(
      lifecycle: CallLifecycle.ended,
      statusText: 'Call ended.',
    );
  }

  Future<void> toggleMute() async {
    final MediaStream? localStream = _localStream;
    if (localStream == null) {
      return;
    }
    final bool nextMuted = !_state.isMuted;
    for (final MediaStreamTrack track in localStream.getAudioTracks()) {
      track.enabled = !nextMuted;
    }
    _setState(_state.copyWith(isMuted: nextMuted));
  }

  Future<void> toggleVideoEnabled() async {
    if (_state.kind != CallKind.video) {
      return;
    }
    final MediaStream? localStream = _localStream;
    if (localStream == null) {
      return;
    }
    final bool nextEnabled = !_state.isVideoEnabled;
    for (final MediaStreamTrack track in localStream.getVideoTracks()) {
      track.enabled = nextEnabled;
    }
    _setState(_state.copyWith(isVideoEnabled: nextEnabled));
  }

  Future<void> clearEndedState() async {
    if (_state.isInProgress) {
      return;
    }
    _pendingRemoteOffer = null;
    _activeCall = null;
    _idleResetTimer?.cancel();
    _clearDiagnostics();
    _setState(ActiveCallState.idle);
  }

  Future<void> resumeForeground() async {
    if (_currentUser == null || !_apiService.isConfigured) {
      return;
    }

    _restartSignalPolling();
    await _pollSignals();
  }

  @override
  void dispose() {
    _disposed = true;
    _signalPollTimer?.cancel();
    _idleResetTimer?.cancel();
    unawaited(_teardownPeerResources());
    if (_renderersReady) {
      localRenderer.dispose();
      remoteRenderer.dispose();
    }
    super.dispose();
  }

  void _restartSignalPolling() {
    _signalPollTimer?.cancel();
    if (_currentUser == null || !_apiService.isConfigured) {
      return;
    }
    _signalPollTimer = Timer.periodic(
      _serverConfig.recommendedPollInterval,
      (_) => _pollSignals(),
    );
  }

  Future<void> _pollSignals() async {
    if (_isPollingSignals ||
        _currentUser == null ||
        !_apiService.isConfigured) {
      return;
    }
    final AppUser pollingUser = _currentUser!;

    _isPollingSignals = true;
    try {
      final PollCallSignalsResult result = await _apiService.pollCallSignals(
        sinceId: _signalSinceId,
      );
      if (_currentUser?.id != pollingUser.id) {
        return;
      }
      final int previousSinceId = _signalSinceId;
      _signalSinceId = result.nextSinceId;
      if (previousSinceId != _signalSinceId) {
        await _signalCursorStore.save(pollingUser.id, _signalSinceId);
      }
      for (final CallSignalEvent event in result.signals) {
        await _handleSignalEvent(event);
      }
    } catch (_) {
      // Keep the last known call state and try again on the next poll.
    } finally {
      _isPollingSignals = false;
    }
  }

  Future<void> _handleSignalEvent(CallSignalEvent event) async {
    switch (event.type) {
      case CallSignalType.offer:
        await _handleIncomingOffer(event);
        break;
      case CallSignalType.answer:
        await _handleIncomingAnswer(event);
        break;
      case CallSignalType.candidate:
        await _handleIncomingCandidate(event);
        break;
      case CallSignalType.ringing:
        if (_activeCall?.id == event.callId) {
          _setState(
            _state.copyWith(
              statusText: '${event.call.peer.displayName} is ringing…',
            ),
          );
        }
        break;
      case CallSignalType.rejected:
        if (_activeCall?.id == event.callId) {
          await _finishCall(
            lifecycle: CallLifecycle.ended,
            statusText: '${event.call.peer.displayName} declined the call.',
          );
        }
        break;
      case CallSignalType.busy:
        if (_activeCall?.id == event.callId) {
          await _finishCall(
            lifecycle: CallLifecycle.failed,
            statusText: '${event.call.peer.displayName} is already on a call.',
          );
        }
        break;
      case CallSignalType.ended:
        if (_activeCall?.id == event.callId) {
          await _finishCall(
            lifecycle: CallLifecycle.ended,
            statusText: '${event.call.peer.displayName} ended the call.',
          );
        }
        break;
    }
  }

  Future<void> _handleIncomingOffer(CallSignalEvent event) async {
    if (event.call.status != 'ringing') {
      return;
    }
    if (_state.isInProgress && _activeCall?.id != event.callId) {
      await _apiService.sendCallSignal(
        callId: event.callId,
        type: CallSignalType.busy,
        payload: const <String, dynamic>{'reason': 'busy'},
      );
      return;
    }

    final Object? descriptionPayload = event.payload['description'];
    if (descriptionPayload is! Map<String, dynamic>) {
      return;
    }
    final String type = descriptionPayload['type']?.toString() ?? '';
    final String sdp = descriptionPayload['sdp']?.toString() ?? '';
    if (type != 'offer' || sdp.isEmpty) {
      return;
    }

    _activeCall = event.call;
    _pendingRemoteOffer = RTCSessionDescription(sdp, type);
    _pendingRemoteCandidates.clear();
    _bufferedOutboundCandidates.clear();
    _sentCandidateFingerprints.clear();
    await _teardownPeerResources();
    _clearDiagnostics();
    _setState(
      ActiveCallState(
        lifecycle: CallLifecycle.incomingRinging,
        callId: event.callId,
        peer: event.call.peer,
        kind: event.call.kind,
        isInitiator: false,
        isVideoEnabled: event.call.kind == CallKind.video,
        statusText:
            'Incoming ${event.call.kind.name} call from ${event.call.peer.displayName}',
        diagnostics: _buildDiagnostics(connectionState: 'ringing'),
      ),
    );

    try {
      await _apiService.sendCallSignal(
        callId: event.callId,
        type: CallSignalType.ringing,
      );
    } catch (_) {
      // If the ringing acknowledgement fails, the incoming call can still proceed.
    }
  }

  Future<void> _handleIncomingAnswer(CallSignalEvent event) async {
    if (event.call.status != 'active') {
      return;
    }
    if (_activeCall?.id != event.callId || _peerConnection == null) {
      return;
    }
    final Object? descriptionPayload = event.payload['description'];
    if (descriptionPayload is! Map<String, dynamic>) {
      return;
    }
    final String type = descriptionPayload['type']?.toString() ?? '';
    final String sdp = descriptionPayload['sdp']?.toString() ?? '';
    if (type != 'answer' || sdp.isEmpty) {
      return;
    }

    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(sdp, type),
    );
    await _flushPendingRemoteCandidates();
    _setState(
      _state.copyWith(
        lifecycle: CallLifecycle.connecting,
        statusText: 'Connecting to ${event.call.peer.displayName}…',
      ),
    );
  }

  Future<void> _handleIncomingCandidate(CallSignalEvent event) async {
    if (_activeCall?.id != event.callId) {
      return;
    }

    final String candidateString = event.payload['candidate']?.toString() ?? '';
    if (candidateString.isEmpty) {
      return;
    }

    final IceCandidateRouteType type = _candidateTypeFor(candidateString);
    if (!_isCandidateAllowed(type, incoming: true)) {
      return;
    }

    final RTCIceCandidate candidate = RTCIceCandidate(
      candidateString,
      event.payload['sdpMid']?.toString(),
      event.payload['sdpMLineIndex'] is int
          ? event.payload['sdpMLineIndex'] as int
          : int.tryParse(event.payload['sdpMLineIndex']?.toString() ?? ''),
    );
    _recordRemoteCandidate(type);

    final RTCSessionDescription? remoteDescription =
        await _peerConnection?.getRemoteDescription();
    if (_peerConnection == null || remoteDescription == null) {
      _pendingRemoteCandidates.add(candidate);
      return;
    }

    await _peerConnection!.addCandidate(candidate);
  }

  Future<void> _preparePeerConnection({
    required CallKind kind,
    required bool createLocalMedia,
    bool preservePendingRemoteCandidates = false,
  }) async {
    await _teardownPeerResources(
      clearPendingRemoteCandidates: !preservePendingRemoteCandidates,
    );
    _clearDiagnostics();
    if (!preservePendingRemoteCandidates) {
      _pendingRemoteCandidates.clear();
    }
    _bufferedOutboundCandidates.clear();
    _sentCandidateFingerprints.clear();

    final Map<String, dynamic> configuration = <String, dynamic>{
      'sdpSemantics': 'unified-plan',
      'iceServers': _filteredIceServers()
          .map((CallIceServer server) => server.toJson())
          .toList(),
      'iceTransportPolicy': _iceTransportPolicy,
    };

    _peerConnection = await createPeerConnection(configuration);
    _peerConnection!.onConnectionState = (RTCPeerConnectionState state) {
      _handlePeerConnectionState(state);
    };
    _peerConnection!.onIceConnectionState = (RTCIceConnectionState state) {
      _setState(
        _state.copyWith(
          diagnostics: _buildDiagnostics(connectionState: state.name),
        ),
      );
    };
    _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
      if ((candidate.candidate ?? '').trim().isEmpty) {
        return;
      }
      unawaited(_handleLocalCandidate(candidate));
    };
    _peerConnection!.onTrack = (RTCTrackEvent event) {
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams.first;
        remoteRenderer.srcObject = _remoteStream;
      }
      _setState(
        _state.copyWith(
          hasRemoteVideo: _state.hasRemoteVideo ||
              (event.track.kind ?? '').toLowerCase() == 'video',
        ),
      );
    };

    if (createLocalMedia) {
      final Map<String, dynamic> mediaConstraints = <String, dynamic>{
        'audio': true,
        'video': kind == CallKind.video
            ? <String, dynamic>{'facingMode': 'user'}
            : false,
      };
      _localStream =
          await navigator.mediaDevices.getUserMedia(mediaConstraints);
      localRenderer.srcObject = _localStream;
      for (final MediaStreamTrack track in _localStream!.getTracks()) {
        await _peerConnection!.addTrack(track, _localStream!);
      }
    } else {
      localRenderer.srcObject = null;
    }
  }

  Future<void> _handleLocalCandidate(RTCIceCandidate candidate) async {
    final String candidateValue = candidate.candidate ?? '';
    final IceCandidateRouteType type = _candidateTypeFor(candidateValue);
    if (!_isCandidateAllowed(type, incoming: false)) {
      return;
    }

    _recordLocalCandidate(type, candidateValue);
    final Map<String, dynamic> payload = <String, dynamic>{
      'candidate': candidateValue,
      'sdpMid': candidate.sdpMid,
      'sdpMLineIndex': candidate.sdpMLineIndex,
      'candidateType': type.name,
    };
    final String fingerprint = [
      candidateValue,
      candidate.sdpMid ?? '',
      candidate.sdpMLineIndex?.toString() ?? '',
    ].join('|');
    if (!_sentCandidateFingerprints.add(fingerprint)) {
      return;
    }

    if (_activeCall == null) {
      _bufferedOutboundCandidates.add(payload);
      return;
    }

    await _sendBufferedCandidatePayload(payload);
  }

  Future<void> _flushBufferedOutboundCandidates() async {
    if (_activeCall == null || _bufferedOutboundCandidates.isEmpty) {
      return;
    }

    for (final Map<String, dynamic> payload
        in List<Map<String, dynamic>>.from(_bufferedOutboundCandidates)) {
      await _sendBufferedCandidatePayload(payload);
    }
    _bufferedOutboundCandidates.clear();
  }

  Future<void> _sendBufferedCandidatePayload(
      Map<String, dynamic> payload) async {
    final CallSummary? activeCall = _activeCall;
    if (activeCall == null) {
      return;
    }
    await _apiService.sendCallSignal(
      callId: activeCall.id,
      type: CallSignalType.candidate,
      payload: payload,
    );
  }

  Future<void> _flushPendingRemoteCandidates() async {
    final RTCPeerConnection? peerConnection = _peerConnection;
    if (peerConnection == null || _pendingRemoteCandidates.isEmpty) {
      return;
    }
    for (final RTCIceCandidate candidate
        in List<RTCIceCandidate>.from(_pendingRemoteCandidates)) {
      await peerConnection.addCandidate(candidate);
    }
    _pendingRemoteCandidates.clear();
  }

  Future<void> _finishCall({
    required CallLifecycle lifecycle,
    required String statusText,
  }) async {
    await _teardownPeerResources();
    _pendingRemoteOffer = null;
    _activeCall = null;
    _setState(
      _state.copyWith(
        lifecycle: lifecycle,
        statusText: statusText,
        callId: null,
        clearCallId: true,
        diagnostics: _buildDiagnostics(connectionState: 'closed'),
      ),
    );
    _scheduleIdleReset();
  }

  Future<void> _teardownPeerResources({
    bool clearPendingRemoteCandidates = true,
  }) async {
    if (clearPendingRemoteCandidates) {
      _pendingRemoteCandidates.clear();
    }
    _bufferedOutboundCandidates.clear();
    _sentCandidateFingerprints.clear();

    for (final MediaStreamTrack track
        in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      track.stop();
    }
    for (final MediaStreamTrack track
        in _remoteStream?.getTracks() ?? <MediaStreamTrack>[]) {
      track.stop();
    }

    await _peerConnection?.close();
    await _peerConnection?.dispose();
    _peerConnection = null;
    _localStream = null;
    _remoteStream = null;
    if (_renderersReady) {
      localRenderer.srcObject = null;
      remoteRenderer.srcObject = null;
    }
  }

  void _handlePeerConnectionState(RTCPeerConnectionState state) {
    if (_disposed) {
      return;
    }

    if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected ||
        state == RTCPeerConnectionState.RTCPeerConnectionStateConnecting) {
      final bool isConnected =
          state == RTCPeerConnectionState.RTCPeerConnectionStateConnected;
      _setState(
        _state.copyWith(
          lifecycle:
              isConnected ? CallLifecycle.active : CallLifecycle.connecting,
          statusText: isConnected ? 'Call connected.' : 'Connecting call…',
          diagnostics: _buildDiagnostics(connectionState: state.name),
        ),
      );
      return;
    }

    if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
      unawaited(
        _finishCall(
          lifecycle: CallLifecycle.failed,
          statusText:
              'Call failed. Check your network or try relay mode in advanced settings.',
        ),
      );
      return;
    }

    if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
      _setState(
        _state.copyWith(
          statusText: 'Connection interrupted…',
          diagnostics: _buildDiagnostics(connectionState: state.name),
        ),
      );
      return;
    }

    if (state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
      _setState(
        _state.copyWith(
          diagnostics: _buildDiagnostics(connectionState: state.name),
        ),
      );
      return;
    }

    _setState(
      _state.copyWith(
        diagnostics: _buildDiagnostics(connectionState: state.name),
      ),
    );
  }

  List<CallIceServer> _filteredIceServers() {
    final bool allowRelayServers =
        _settings.connectionMode != CallConnectionMode.directOnly &&
                _settings.connectionMode != CallConnectionMode.relayOnly
            ? _settings.allowRelayFallback
            : _settings.connectionMode == CallConnectionMode.relayOnly;

    final List<CallIceServer> servers = <CallIceServer>[];
    for (final CallIceServer server in _serverConfig.iceServers) {
      final bool isTurnServer = server.urls.any(
        (String value) => value.toLowerCase().startsWith('turn:'),
      );
      if (isTurnServer && !allowRelayServers) {
        continue;
      }
      if (!isTurnServer &&
          _settings.connectionMode == CallConnectionMode.relayOnly) {
        continue;
      }
      servers.add(server);
    }

    if (servers.isEmpty &&
        _settings.connectionMode != CallConnectionMode.relayOnly) {
      return _fallbackServerConfig.iceServers;
    }
    return servers;
  }

  String get _iceTransportPolicy {
    if (_settings.connectionMode == CallConnectionMode.relayOnly) {
      return 'relay';
    }
    return 'all';
  }

  bool _isCandidateAllowed(
    IceCandidateRouteType type, {
    required bool incoming,
  }) {
    switch (_settings.connectionMode) {
      case CallConnectionMode.relayOnly:
        return type == IceCandidateRouteType.relay;
      case CallConnectionMode.directOnly:
        if (type == IceCandidateRouteType.relay) {
          return false;
        }
        return _candidateAllowedByFlags(type);
      case CallConnectionMode.auto:
      case CallConnectionMode.directPreferred:
        if (type == IceCandidateRouteType.relay) {
          return _settings.allowRelayFallback || incoming;
        }
        return _candidateAllowedByFlags(type);
    }
  }

  bool _candidateAllowedByFlags(IceCandidateRouteType type) {
    switch (type) {
      case IceCandidateRouteType.host:
        return _settings.shareLocalCandidates;
      case IceCandidateRouteType.srflx:
      case IceCandidateRouteType.prflx:
        return _settings.sharePublicCandidates;
      case IceCandidateRouteType.relay:
        return _settings.allowRelayFallback;
      case IceCandidateRouteType.unknown:
        return true;
    }
  }

  IceCandidateRouteType _candidateTypeFor(String candidate) {
    final RegExp matchPattern = RegExp(
      r'candidate:\S+\s+\d+\s+\S+\s+\d+\s+\S+\s+\d+\s+typ\s+(\S+)',
      caseSensitive: false,
    );
    final RegExpMatch? match = matchPattern.firstMatch(candidate);
    final String rawType =
        match != null ? match.group(1)?.toLowerCase() ?? '' : '';
    return switch (rawType) {
      'host' => IceCandidateRouteType.host,
      'srflx' => IceCandidateRouteType.srflx,
      'prflx' => IceCandidateRouteType.prflx,
      'relay' => IceCandidateRouteType.relay,
      _ => IceCandidateRouteType.unknown,
    };
  }

  String? _candidateAddressFor(String candidate) {
    final RegExp matchPattern = RegExp(
      r'candidate:\S+\s+\d+\s+\S+\s+\d+\s+(\S+)\s+\d+\s+typ\s+\S+',
      caseSensitive: false,
    );
    return matchPattern.firstMatch(candidate)?.group(1);
  }

  void _recordLocalCandidate(
      IceCandidateRouteType type, String candidateValue) {
    final String? address = _candidateAddressFor(candidateValue);
    if (address == null || address.isEmpty) {
      _updateDiagnostics();
      return;
    }
    switch (type) {
      case IceCandidateRouteType.host:
        _localHostAddresses.add(address);
        break;
      case IceCandidateRouteType.srflx:
      case IceCandidateRouteType.prflx:
        _publicAddresses.add(address);
        break;
      case IceCandidateRouteType.relay:
        _relayAddresses.add(address);
        break;
      case IceCandidateRouteType.unknown:
        break;
    }
    _updateDiagnostics();
  }

  void _recordRemoteCandidate(IceCandidateRouteType type) {
    _remoteCandidateTypes.add(type.name);
    _updateDiagnostics();
  }

  void _clearDiagnostics() {
    _localHostAddresses.clear();
    _publicAddresses.clear();
    _relayAddresses.clear();
    _remoteCandidateTypes.clear();
    _updateDiagnostics();
  }

  void _updateDiagnostics() {
    _setState(
      _state.copyWith(
        diagnostics: _buildDiagnostics(
          connectionState: _state.diagnostics.connectionState,
        ),
      ),
      notify: true,
    );
  }

  CallDiagnostics _buildDiagnostics({required String connectionState}) {
    String routeSummary = 'No active call';
    if (_state.isInProgress) {
      if (_settings.connectionMode == CallConnectionMode.relayOnly) {
        routeSummary = _serverConfig.turnConfigured
            ? 'Relay-only mode through TURN'
            : 'Relay-only mode selected, but TURN is not configured';
      } else if (_relayAddresses.isNotEmpty &&
          (_settings.connectionMode == CallConnectionMode.auto ||
              _settings.connectionMode == CallConnectionMode.directPreferred)) {
        routeSummary = 'Relay fallback available';
      } else if (_localHostAddresses.isNotEmpty) {
        routeSummary = 'Direct LAN/VPN route available';
      } else if (_publicAddresses.isNotEmpty) {
        routeSummary = 'Direct internet route available';
      } else {
        routeSummary = 'Negotiating route…';
      }
    }

    return CallDiagnostics(
      connectionState: connectionState,
      routeSummary: routeSummary,
      localHostAddresses: _sortedValues(_localHostAddresses),
      publicAddresses: _sortedValues(_publicAddresses),
      relayAddresses: _sortedValues(_relayAddresses),
      remoteCandidateTypes: _sortedValues(_remoteCandidateTypes),
      turnConfigured: _serverConfig.turnConfigured,
    );
  }

  List<String> _sortedValues(Set<String> values) {
    final List<String> sorted = values.toList()..sort();
    return sorted;
  }

  void _setState(ActiveCallState next, {bool notify = true}) {
    _state = next;
    if (notify && !_disposed) {
      notifyListeners();
    }
  }

  void _scheduleIdleReset() {
    _idleResetTimer?.cancel();
    _idleResetTimer = Timer(const Duration(seconds: 5), () {
      if (_state.isInProgress) {
        return;
      }
      unawaited(clearEndedState());
    });
  }
}

class CallSignalCursorStore {
  static const String _storagePrefix = 'call_signal_since_v1_';

  Future<int> load(String userId) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_storageKeyForUser(userId)) ?? 0;
  }

  Future<void> save(String userId, int sinceId) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_storageKeyForUser(userId), sinceId);
  }

  String _storageKeyForUser(String userId) {
    final String encoded = base64Url.encode(utf8.encode(userId));
    return '$_storagePrefix$encoded';
  }
}
