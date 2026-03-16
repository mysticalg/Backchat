import 'dart:convert';

import 'package:backchat/services/encryption_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late EncryptionService encryptionService;

  setUp(() {
    encryptionService = EncryptionService();
  });

  Future<(String, dynamic, List<int>)> _buildEncryptedPayload() async {
    final local = await encryptionService.createIdentityKeyPair();
    final remote = await encryptionService.createIdentityKeyPair();
    final remotePublic = await remote.extractPublicKey();
    final secret = await encryptionService.deriveSharedSecret(
      localPrivateKey: local,
      remotePublicKey: remotePublic,
    );

    final aad = utf8.encode('alice|bob');
    final cipherText = await encryptionService.encryptText(
      plainText: 'hello secure world',
      sharedSecret: secret,
      associatedData: aad,
    );
    return (cipherText, secret, aad);
  }

  test('encryptText/decryptText round-trips plaintext', () async {
    final (cipherText, secret, aad) = await _buildEncryptedPayload();

    final clear = await encryptionService.decryptText(
      encodedPayload: cipherText,
      sharedSecret: secret,
      associatedData: aad,
    );

    expect(clear, 'hello secure world');
  });

  test('decryptText fails when associated data does not match', () async {
    final (cipherText, secret, _) = await _buildEncryptedPayload();

    expect(
      () => encryptionService.decryptText(
        encodedPayload: cipherText,
        sharedSecret: secret,
        associatedData: utf8.encode('alice|mallory'),
      ),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
  });

  test('decryptText fails on invalid payload version', () async {
    final (cipherText, secret, aad) = await _buildEncryptedPayload();
    final bytes = base64Decode(cipherText);
    bytes[0] = 99;
    final tampered = base64Encode(bytes);

    expect(
      () => encryptionService.decryptText(
        encodedPayload: tampered,
        sharedSecret: secret,
        associatedData: aad,
      ),
      throwsA(isA<FormatException>()),
    );
  });
}
