class ChatMessage {
  const ChatMessage({
    required this.localId,
    required this.fromUserId,
    required this.toUserId,
    required this.cipherText,
    required this.sentAt,
    this.remoteId,
    this.isRead = false,
    this.threadContactId = '',
    this.senderLabel = '',
    this.isLocalOnly = false,
  });

  final String localId;
  final String fromUserId;
  final String toUserId;
  final String cipherText;
  final DateTime sentAt;
  final int? remoteId;
  final bool isRead;
  final String threadContactId;
  final String senderLabel;
  final bool isLocalOnly;

  bool isIncomingFor(String currentUserId) => toUserId == currentUserId;

  String otherUserId(String currentUserId) {
    return fromUserId == currentUserId ? toUserId : fromUserId;
  }

  ChatMessage copyWith({
    String? localId,
    int? remoteId,
    bool? isRead,
    String? threadContactId,
    String? senderLabel,
    bool? isLocalOnly,
  }) {
    return ChatMessage(
      localId: localId ?? this.localId,
      fromUserId: fromUserId,
      toUserId: toUserId,
      cipherText: cipherText,
      sentAt: sentAt,
      remoteId: remoteId ?? this.remoteId,
      isRead: isRead ?? this.isRead,
      threadContactId: threadContactId ?? this.threadContactId,
      senderLabel: senderLabel ?? this.senderLabel,
      isLocalOnly: isLocalOnly ?? this.isLocalOnly,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'localId': localId,
      'fromUserId': fromUserId,
      'toUserId': toUserId,
      'cipherText': cipherText,
      'sentAtUtc': sentAt.toUtc().toIso8601String(),
      'remoteId': remoteId,
      'isRead': isRead,
      if (threadContactId.isNotEmpty) 'threadContactId': threadContactId,
      if (senderLabel.isNotEmpty) 'senderLabel': senderLabel,
      if (isLocalOnly) 'isLocalOnly': isLocalOnly,
    };
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final Object? remoteIdValue = json['remoteId'];
    return ChatMessage(
      localId: json['localId']?.toString() ?? '',
      fromUserId: json['fromUserId']?.toString() ?? '',
      toUserId: json['toUserId']?.toString() ?? '',
      cipherText: json['cipherText']?.toString() ?? '',
      sentAt:
          DateTime.tryParse(json['sentAtUtc']?.toString() ?? '')?.toLocal() ??
              DateTime.now(),
      remoteId: remoteIdValue is int
          ? remoteIdValue
          : int.tryParse(remoteIdValue?.toString() ?? ''),
      isRead: json['isRead'] == true,
      threadContactId: json['threadContactId']?.toString() ?? '',
      senderLabel: json['senderLabel']?.toString() ?? '',
      isLocalOnly: json['isLocalOnly'] == true,
    );
  }
}
