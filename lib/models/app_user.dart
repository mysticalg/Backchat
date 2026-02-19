enum AuthProvider { google, facebook }

enum PresenceStatus { online, offline, busy }

class AppUser {
  const AppUser({
    required this.id,
    required this.displayName,
    required this.avatarUrl,
    required this.provider,
    this.status = PresenceStatus.online,
  });

  final String id;
  final String displayName;
  final String avatarUrl;
  final AuthProvider provider;
  final PresenceStatus status;

  AppUser copyWith({PresenceStatus? status}) {
    return AppUser(
      id: id,
      displayName: displayName,
      avatarUrl: avatarUrl,
      provider: provider,
      status: status ?? this.status,
    );
  }
}
