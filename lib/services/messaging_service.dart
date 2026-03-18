import '../models/chat_message.dart';
import 'backchat_api_service.dart';

class MessagingService {
  MessagingService({BackchatApiClient? apiService})
      : _apiService = apiService ?? BackchatApiService();

  final BackchatApiClient _apiService;
  final List<ChatMessage> _messages = <ChatMessage>[];
  final Set<String> _messageKeys = <String>{};
  int _remoteSinceId = 0;

  bool get isRemoteTransportEnabled => _apiService.isConfigured;

  void reset() {
    _messages.clear();
    _messageKeys.clear();
    _remoteSinceId = 0;
  }

  Future<void> send(ChatMessage message) async {
    if (_apiService.isConfigured) {
      await _apiService.sendMessage(
        toUsername: _usernameFromUserId(message.toUserId),
        cipherText: message.cipherText,
        clientMessageId: _buildClientMessageId(message),
      );
    }

    _rememberMessage(message);
  }

  Future<List<ChatMessage>> syncIncoming(String currentUserId) async {
    if (!_apiService.isConfigured) {
      return <ChatMessage>[];
    }

    final PollMessagesResult result = await _apiService.pollMessages(
      sinceId: _remoteSinceId,
      currentUserId: currentUserId,
    );
    _remoteSinceId = result.nextSinceId;

    final List<ChatMessage> newMessages = <ChatMessage>[];
    for (final ChatMessage message in result.messages) {
      if (_rememberMessage(message)) {
        newMessages.add(message);
      }
    }
    return newMessages;
  }

  Future<List<ChatMessage>> listForPair(String userA, String userB) async {
    return _messages
        .where(
          (ChatMessage m) =>
              (m.fromUserId == userA && m.toUserId == userB) ||
              (m.fromUserId == userB && m.toUserId == userA),
        )
        .toList()
      ..sort((ChatMessage a, ChatMessage b) => a.sentAt.compareTo(b.sentAt));
  }

  bool _rememberMessage(ChatMessage message) {
    final String key = [
      message.fromUserId,
      message.toUserId,
      message.sentAt.toUtc().microsecondsSinceEpoch.toString(),
      message.cipherText,
    ].join('|');

    if (!_messageKeys.add(key)) {
      return false;
    }

    _messages.add(message);
    return true;
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
}
