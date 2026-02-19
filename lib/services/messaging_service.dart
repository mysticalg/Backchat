import '../models/chat_message.dart';

class MessagingService {
  final List<ChatMessage> _messages = <ChatMessage>[];

  Future<void> send(ChatMessage message) async {
    _messages.add(message);
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
}
