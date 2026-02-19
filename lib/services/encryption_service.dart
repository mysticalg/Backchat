import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

class EncryptionService {
  final X25519 _keyExchange = X25519();
  final AesGcm _cipher = AesGcm.with256bits();

  Future<SimpleKeyPair> createIdentityKeyPair() => _keyExchange.newKeyPair();

  Future<SecretKey> deriveSharedSecret({
    required SimpleKeyPair localPrivateKey,
    required SimplePublicKey remotePublicKey,
  }) {
    return _keyExchange.sharedSecretKey(
      keyPair: localPrivateKey,
      remotePublicKey: remotePublicKey,
    );
  }

  Future<String> encryptText({
    required String plainText,
    required SecretKey sharedSecret,
  }) async {
    final List<int> nonce = _cipher.newNonce();
    final SecretBox secretBox = await _cipher.encrypt(
      utf8.encode(plainText),
      secretKey: sharedSecret,
      nonce: nonce,
    );

    final Uint8List payload = Uint8List.fromList(<int>[
      ...secretBox.nonce,
      ...secretBox.cipherText,
      ...secretBox.mac.bytes,
    ]);

    return base64Encode(payload);
  }

  Future<String> decryptText({
    required String encodedPayload,
    required SecretKey sharedSecret,
  }) async {
    final Uint8List payload = base64Decode(encodedPayload);
    const int nonceLength = 12;
    const int macLength = 16;

    final List<int> nonce = payload.sublist(0, nonceLength);
    final List<int> cipherText = payload.sublist(nonceLength, payload.length - macLength);
    final List<int> macBytes = payload.sublist(payload.length - macLength);

    final SecretBox secretBox = SecretBox(
      cipherText,
      nonce: nonce,
      mac: Mac(macBytes),
    );

    final List<int> clear = await _cipher.decrypt(secretBox, secretKey: sharedSecret);
    return utf8.decode(clear);
  }
}
