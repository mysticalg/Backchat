import 'package:backchat/services/auth_service.dart';
import 'package:backchat/services/contacts_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late AuthService authService;
  late ContactsService contactsService;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    authService = AuthService();
    contactsService = ContactsService();
  });

  test('invite by username adds an existing user to contacts', () async {
    final alice = await authService.signInOrCreateWithUsername(
      username: 'alice_01',
      recoveryEmail: 'alice@example.com',
    );
    await authService.signInOrCreateWithUsername(
      username: 'bob_01',
      recoveryEmail: 'bob@example.com',
    );

    final invite = await contactsService.inviteByUsername(
      currentUser: alice.user!,
      username: 'bob_01',
      authService: authService,
    );
    final contacts = await contactsService.pullContactsFor(alice.user!);

    expect(invite.status, InviteByUsernameStatus.added);
    expect(contacts.length, 1);
    expect(contacts.first.displayName, 'bob_01');
  });

  test('invite by username prevents duplicate and self-invite', () async {
    final alice = await authService.signInOrCreateWithUsername(
      username: 'alice_01',
      recoveryEmail: 'alice@example.com',
    );
    await authService.signInOrCreateWithUsername(
      username: 'bob_01',
      recoveryEmail: 'bob@example.com',
    );

    await contactsService.inviteByUsername(
      currentUser: alice.user!,
      username: 'bob_01',
      authService: authService,
    );
    final duplicate = await contactsService.inviteByUsername(
      currentUser: alice.user!,
      username: 'bob_01',
      authService: authService,
    );
    final selfInvite = await contactsService.inviteByUsername(
      currentUser: alice.user!,
      username: 'alice_01',
      authService: authService,
    );

    expect(duplicate.status, InviteByUsernameStatus.alreadyContact);
    expect(selfInvite.status, InviteByUsernameStatus.selfInvite);
  });

  test('invite by username fails when username does not exist', () async {
    final alice = await authService.signInOrCreateWithUsername(
      username: 'alice_01',
      recoveryEmail: 'alice@example.com',
    );

    final invite = await contactsService.inviteByUsername(
      currentUser: alice.user!,
      username: 'missing_user',
      authService: authService,
    );

    expect(invite.status, InviteByUsernameStatus.notFound);
  });
}
