import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_message.dart';
import 'backchat_api_service.dart';

class MessagingService {
  MessagingService({BackchatApiClient? apiService})
      : _apiService = apiService ?? BackchatApiService();

  static const String _storagePrefix = 'messages_v2_';

  final BackchatApiClient _apiService;
  final List<ChatMessage> _messages = <ChatMessage>[];
  final Set<String> _messageKeys = <String>{};

  String? _activeUserId;
  bool _hasLoadedState = false;
  int _remoteSinceId = 0;

  bool get isRemoteTransportEnabled => _apiService.isConfigured;

  void reset() {
    _messages.clear();
    _messageKeys.clear();
    _remoteSinceId = 0;
    _activeUserId = null;
    _hasLoadedState = false;
  }

  Future<void> activateForUser(String currentUserId) async {
    _messages.clear();
    _messageKeys.clear();
    _remoteSinceId = 0;
    _activeUserId = currentUserId;
    _hasLoadedState = true;

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_storageKeyForUser(currentUserId));
    if (raw == null || raw.isEmpty) {
      return;
    }

    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return;
      }

      final Object? remoteSinceValue = decoded['remoteSinceId'];
      _remoteSinceId = remoteSinceValue is int
          ? remoteSinceValue
          : int.tryParse(remoteSinceValue?.toString() ?? '') ?? 0;

      final List<dynamic> rows = decoded['messages'] is List<dynamic>
          ? decoded['messages'] as List<dynamic>
          : <dynamic>[];
      for (final Map<String, dynamic> row
          in rows.whereType<Map<String, dynamic>>()) {
        final ChatMessage message = ChatMessage.fromJson(row);
        if (message.localId.isEmpty ||
            message.fromUserId.isEmpty ||
            message.toUserId.isEmpty) {
          continue;
        }
        _rememberMessage(message);
      }
    } catch (_) {
      _messages.clear();
      _messageKeys.clear();
      _remoteSinceId = 0;
    }
  }

  Future<void> send(ChatMessage message) async {
    await _ensureLoaded(message.fromUserId);

    if (_apiService.isConfigured && !message.isLocalOnly) {
      await _apiService.sendMessage(
        toUsername: _usernameFromUserId(message.toUserId),
        cipherText: message.cipherText,
        clientMessageId: _buildClientMessageId(message),
      );
    }

    _rememberMessage(message.copyWith(isRead: true));
    await _persistState();
  }

  Future<void> storeLocalOnly({
    required String currentUserId,
    required ChatMessage message,
  }) async {
    await _ensureLoaded(currentUserId);
    _rememberMessage(message);
    await _persistState();
  }

  Future<List<ChatMessage>> syncIncoming(String currentUserId) async {
    await _ensureLoaded(currentUserId);
    if (!_apiService.isConfigured) {
      return <ChatMessage>[];
    }

    final PollMessagesResult result = await _apiService.pollMessages(
      sinceId: _remoteSinceId,
      currentUserId: currentUserId,
    );
    final int previousSinceId = _remoteSinceId;
    _remoteSinceId = result.nextSinceId;

    final List<ChatMessage> newMessages = <ChatMessage>[];
    for (final ChatMessage message in result.messages) {
      if (_rememberMessage(message)) {
        newMessages.add(message);
      }
    }

    if (newMessages.isNotEmpty || previousSinceId != _remoteSinceId) {
      await _persistState();
    }
    return newMessages;
  }

  Future<List<ChatMessage>> listForPair(String userA, String userB) async {
    await _ensureLoaded(userA);
    return _messages
        .where(
          (ChatMessage message) =>
              (message.fromUserId == userA && message.toUserId == userB) ||
              (message.fromUserId == userB && message.toUserId == userA) ||
              (message.threadContactId == userB &&
                  (message.fromUserId == userA || message.toUserId == userA)),
        )
        .toList()
      ..sort((ChatMessage a, ChatMessage b) => a.sentAt.compareTo(b.sentAt));
  }

  int unreadCountForContact({
    required String currentUserId,
    required String contactUserId,
  }) {
    if (_activeUserId != currentUserId || !_hasLoadedState) {
      return 0;
    }

    return _messages
        .where(
          (ChatMessage message) =>
              message.isIncomingFor(currentUserId) &&
              message.fromUserId == contactUserId &&
              !message.isRead,
        )
        .length;
  }

  int totalUnreadCountForUser(String currentUserId) {
    if (_activeUserId != currentUserId || !_hasLoadedState) {
      return 0;
    }

    return _messages
        .where(
          (ChatMessage message) =>
              message.isIncomingFor(currentUserId) && !message.isRead,
        )
        .length;
  }

  Future<bool> markConversationRead({
    required String currentUserId,
    required String contactUserId,
  }) async {
    await _ensureLoaded(currentUserId);

    bool changed = false;
    for (int i = 0; i < _messages.length; i++) {
      final ChatMessage message = _messages[i];
      if (message.isIncomingFor(currentUserId) &&
          message.fromUserId == contactUserId &&
          !message.isRead) {
        _messages[i] = message.copyWith(isRead: true);
        changed = true;
      }
    }

    if (changed) {
      await _persistState();
    }
    return changed;
  }

  bool _rememberMessage(ChatMessage message) {
    final String key = message.localId.isNotEmpty
        ? message.localId
        : _fallbackLocalId(message);
    if (!_messageKeys.add(key)) {
      return false;
    }

    _messages.add(
      message.localId.isEmpty ? message.copyWith(localId: key) : message,
    );
    return true;
  }

  Future<void> _ensureLoaded(String currentUserId) async {
    if (_activeUserId != currentUserId || !_hasLoadedState) {
      await activateForUser(currentUserId);
    }
  }

  Future<void> _persistState() async {
    final String? activeUserId = _activeUserId;
    if (activeUserId == null) {
      return;
    }

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String payload = jsonEncode(<String, dynamic>{
      'remoteSinceId': _remoteSinceId,
      'messages':
          _messages.map((ChatMessage message) => message.toJson()).toList(),
    });
    await prefs.setString(_storageKeyForUser(activeUserId), payload);
  }

  String _storageKeyForUser(String userId) {
    final String encoded = base64Url.encode(utf8.encode(userId));
    return '$_storagePrefix$encoded';
  }

  String _usernameFromUserId(String userId) {
    const String prefix = 'username:';
    if (userId.startsWith(prefix)) {
      return userId.substring(prefix.length);
    }
    return userId;
  }

  String _buildClientMessageId(ChatMessage message) {
    return [
      _usernameFromUserId(message.fromUserId),
      _usernameFromUserId(message.toUserId),
      message.sentAt.toUtc().microsecondsSinceEpoch.toString(),
    ].join('-');
  }

  String _fallbackLocalId(ChatMessage message) {
    if (message.remoteId != null) {
      return 'remote:${message.remoteId}';
    }
    return [
      message.fromUserId,
      message.toUserId,
      message.sentAt.toUtc().microsecondsSinceEpoch.toString(),
      message.cipherText.hashCode.toString(),
    ].join('|');
  }
}
