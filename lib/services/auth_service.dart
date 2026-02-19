import 'package:flutter_facebook_auth/flutter_facebook_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../models/app_user.dart';

class AuthService {
  final GoogleSignIn _googleSignIn = GoogleSignIn(scopes: <String>['email', 'profile']);

  Future<AppUser?> signInWithGoogle() async {
    final GoogleSignInAccount? account = await _googleSignIn.signIn();
    if (account == null) return null;

    return AppUser(
      id: account.id,
      displayName: account.displayName ?? 'Google User',
      avatarUrl: account.photoUrl ?? '',
      provider: AuthProvider.google,
    );
  }

  Future<AppUser?> signInWithFacebook() async {
    final LoginResult result = await FacebookAuth.instance.login();
    if (result.status != LoginStatus.success) return null;

    final Map<String, dynamic> profile = await FacebookAuth.instance.getUserData(
      fields: 'id,name,picture.width(200)',
    );

    final Map<String, dynamic>? picture = profile['picture'] as Map<String, dynamic>?;
    final Map<String, dynamic>? pictureData = picture?['data'] as Map<String, dynamic>?;

    return AppUser(
      id: profile['id']?.toString() ?? '',
      displayName: profile['name']?.toString() ?? 'Facebook User',
      avatarUrl: pictureData?['url']?.toString() ?? '',
      provider: AuthProvider.facebook,
    );
  }

  Future<void> signOut(AppUser user) async {
    if (user.provider == AuthProvider.google) {
      await _googleSignIn.signOut();
      return;
    }
    await FacebookAuth.instance.logOut();
  }
}
