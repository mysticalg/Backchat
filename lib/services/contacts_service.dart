import '../models/app_user.dart';

class ContactsService {
  Future<List<AppUser>> pullContactsFor(AppUser currentUser) async {
    // Provider APIs often restrict raw friend/contact access.
    // Replace with real provider-specific import flows where allowed.
    return <AppUser>[
      AppUser(
        id: 'demo-contact-1',
        displayName: 'Encrypted Echo',
        avatarUrl: '',
        provider: currentUser.provider,
      ),
      AppUser(
        id: 'demo-contact-2',
        displayName: 'Cipher Friend',
        avatarUrl: '',
        provider: currentUser.provider,
      ),
    ];
  }
}
