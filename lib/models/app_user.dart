enum AuthProvider { username, google, facebook, x }

enum PresenceStatus { online, offline, busy }

class AppUser {
  const AppUser({
    required this.id,
    required this.displayName,
    required this.avatarUrl,
    required this.provider,
    this.username = '',
    this.quote = '',
    this.status = PresenceStatus.online,
    this.lastSeenAt,
    this.isBot = false,
    this.botHandle = '',
  });

  final String id;
  final String displayName;
  final String avatarUrl;
  final AuthProvider provider;
  final String username;
  final String quote;
  final PresenceStatus status;
  final DateTime? lastSeenAt;
  final bool isBot;
  final String botHandle;

  AppUser copyWith({
    String? displayName,
    String? avatarUrl,
    String? username,
    String? quote,
    PresenceStatus? status,
    DateTime? lastSeenAt,
    bool clearLastSeenAt = false,
    bool? isBot,
    String? botHandle,
  }) {
    return AppUser(
      id: id,
      displayName: displayName ?? this.displayName,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      provider: provider,
      username: username ?? this.username,
      quote: quote ?? this.quote,
      status: status ?? this.status,
      lastSeenAt: clearLastSeenAt ? null : (lastSeenAt ?? this.lastSeenAt),
      isBot: isBot ?? this.isBot,
      botHandle: botHandle ?? this.botHandle,
    );
  }
}
