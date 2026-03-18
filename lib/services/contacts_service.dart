import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_user.dart';
import 'auth_service.dart';
import 'backchat_api_service.dart';

enum InviteByUsernameStatus {
  added,
  alreadyContact,
  selfInvite,
  notFound,
  invalidUsername,
  serverUnavailable,
}

class InviteByUsernameResult {
  const InviteByUsernameResult({
    required this.status,
    this.contact,
  });

  final InviteByUsernameStatus status;
  final AppUser? contact;
}

class ContactsService {
  ContactsService({BackchatApiClient? apiService})
      : _apiService = apiService ?? BackchatApiService();

  static const String _contactsStoragePrefix = 'contacts_v1_';
  final BackchatApiClient _apiService;

  Future<List<AppUser>> pullContactsFor(AppUser currentUser) async {
    if (_apiService.isConfigured) {
      try {
        final List<AppUser> contacts = await _apiService.fetchContacts();
        await _writeContactsFor(currentUser.id, contacts);
        return contacts;
      } catch (_) {
        // Fall back to local contact cache if API is unavailable.
      }
    }

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_contactsKeyForUser(currentUser.id));
    if (raw == null || raw.isEmpty) {
      return <AppUser>[];
    }

    final Object? decoded = jsonDecode(raw);
    if (decoded is! List<dynamic>) {
      return <AppUser>[];
    }

    return decoded
        .whereType<Map<String, dynamic>>()
        .map(_appUserFromJson)
        .where((AppUser user) => user.id.isNotEmpty)
        .toList();
  }

  Future<InviteByUsernameResult> inviteByUsername({
    required AppUser currentUser,
    required String username,
    required AuthService authService,
  }) async {
    bool useLocalFallback = false;
    if (_apiService.isConfigured) {
      try {
        final Map<String, dynamic> payload =
            await _apiService.inviteByUsername(username);
        final String status = payload['status']?.toString() ?? '';
        final AppUser? contact = payload['contact'] is Map<String, dynamic>
            ? _appUserFromJson(payload['contact'] as Map<String, dynamic>)
            : null;

        if (status == 'added') {
          return InviteByUsernameResult(
            status: InviteByUsernameStatus.added,
            contact: contact,
          );
        }
        if (status == 'already_contact') {
          return InviteByUsernameResult(
            status: InviteByUsernameStatus.alreadyContact,
            contact: contact,
          );
        }
        return const InviteByUsernameResult(
          status: InviteByUsernameStatus.serverUnavailable,
        );
      } on BackchatApiException catch (e) {
        if (e.status == 'invalid_username') {
          return const InviteByUsernameResult(
            status: InviteByUsernameStatus.invalidUsername,
          );
        }
        if (e.status == 'not_found') {
          return const InviteByUsernameResult(
            status: InviteByUsernameStatus.notFound,
          );
        }
        if (e.status == 'self_invite') {
          return const InviteByUsernameResult(
            status: InviteByUsernameStatus.selfInvite,
          );
        }
        useLocalFallback = true;
      } catch (_) {
        useLocalFallback = true;
      }
    }

    if (useLocalFallback) {
      // Continue to local fallback path below.
    }

    final String cleaned = username.trim();
    if (!authService.isValidUsernameFormat(cleaned)) {
      return const InviteByUsernameResult(
        status: InviteByUsernameStatus.invalidUsername,
      );
    }

    final AppUser? found = await authService.findUserByUsername(cleaned);
    if (found == null) {
      return const InviteByUsernameResult(
          status: InviteByUsernameStatus.notFound);
    }

    if (found.id == currentUser.id) {
      return const InviteByUsernameResult(
          status: InviteByUsernameStatus.selfInvite);
    }

    final List<AppUser> contacts = await pullContactsFor(currentUser);
    final bool alreadyExists = contacts.any((AppUser c) => c.id == found.id);
    if (alreadyExists) {
      return InviteByUsernameResult(
        status: InviteByUsernameStatus.alreadyContact,
        contact: found,
      );
    }

    contacts.add(found);
    await _writeContactsFor(currentUser.id, contacts);
    return InviteByUsernameResult(
      status: InviteByUsernameStatus.added,
      contact: found,
    );
  }

  Future<void> _writeContactsFor(
      String currentUserId, List<AppUser> contacts) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String payload = jsonEncode(
      contacts.map((AppUser contact) => _appUserToJson(contact)).toList(),
    );
    await prefs.setString(_contactsKeyForUser(currentUserId), payload);
  }

  String _contactsKeyForUser(String userId) {
    final String encoded = base64Url.encode(utf8.encode(userId));
    return '$_contactsStoragePrefix$encoded';
  }

  Map<String, dynamic> _appUserToJson(AppUser user) {
    return <String, dynamic>{
      'id': user.id,
      'username': user.username,
      'displayName': user.displayName,
      'avatarUrl': user.avatarUrl,
      'provider': user.provider.name,
      'status': user.status.name,
      'lastSeenAtUtc': user.lastSeenAt?.toUtc().toIso8601String(),
    };
  }

  AppUser _appUserFromJson(Map<String, dynamic> json) {
    final String providerName =
        json['provider']?.toString() ?? AuthProvider.username.name;
    final String statusName =
        json['status']?.toString() ?? PresenceStatus.online.name;

    final AuthProvider provider = AuthProvider.values.firstWhere(
      (AuthProvider value) => value.name == providerName,
      orElse: () => AuthProvider.username,
    );
    final PresenceStatus status = PresenceStatus.values.firstWhere(
      (PresenceStatus value) => value.name == statusName,
      orElse: () => PresenceStatus.online,
    );

    return AppUser(
      id: json['id']?.toString() ?? '',
      username: json['username']?.toString() ?? '',
      displayName:
          json['displayName']?.toString() ?? json['username']?.toString() ?? '',
      avatarUrl: json['avatarUrl']?.toString() ?? '',
      provider: provider,
      status: status,
      lastSeenAt: DateTime.tryParse(
        json['lastSeenAtUtc']?.toString() ?? '',
      )?.toLocal(),
    );
  }
}
