class ChatMessage {
  const ChatMessage({
    required this.fromUserId,
    required this.toUserId,
    required this.cipherText,
    required this.sentAt,
  });

  final String fromUserId;
  final String toUserId;
  final String cipherText;
  final DateTime sentAt;
}
