import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Handles end-to-end message encryption primitives used by the chat flow.
///
/// Payload format (all bytes before Base64 encoding):
/// - byte 0: version (currently 1)
/// - bytes 1-12: AES-GCM nonce
/// - bytes 13..n-17: ciphertext
/// - bytes n-16..n-1: authentication tag (MAC)
class EncryptionService {
  static const int _payloadVersion = 1;
  static const int _nonceLength = 12;
  static const int _macLength = 16;
  static const int _minPayloadLength = 1 + _nonceLength + _macLength;

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

  /// Encrypts text and returns a compact Base64 payload.
  ///
  /// [associatedData] allows binding metadata (for example sender/receiver IDs)
  /// to the ciphertext so tampering with that metadata causes decrypt failure.
  Future<String> encryptText({
    required String plainText,
    required SecretKey sharedSecret,
    List<int> associatedData = const <int>[],
  }) async {
    final List<int> nonce = _cipher.newNonce();
    final SecretBox secretBox = await _cipher.encrypt(
      utf8.encode(plainText),
      secretKey: sharedSecret,
      nonce: nonce,
      aad: associatedData,
    );

    final Uint8List payload = Uint8List.fromList(<int>[
      _payloadVersion,
      ...secretBox.nonce,
      ...secretBox.cipherText,
      ...secretBox.mac.bytes,
    ]);

    return base64Encode(payload);
  }

  Future<String> decryptText({
    required String encodedPayload,
    required SecretKey sharedSecret,
    List<int> associatedData = const <int>[],
  }) async {
    final Uint8List payload = base64Decode(encodedPayload);

    if (payload.length < _minPayloadLength) {
      throw const FormatException('Encrypted payload is too short.');
    }

    final int version = payload[0];
    if (version != _payloadVersion) {
      throw FormatException('Unsupported encrypted payload version: $version');
    }

    final int nonceStart = 1;
    final int cipherStart = nonceStart + _nonceLength;
    final int macStart = payload.length - _macLength;

    if (macStart <= cipherStart) {
      throw const FormatException('Encrypted payload has invalid cipher/mac boundaries.');
    }

    final List<int> nonce = payload.sublist(nonceStart, cipherStart);
    final List<int> cipherText = payload.sublist(cipherStart, macStart);
    final List<int> macBytes = payload.sublist(macStart);

    final SecretBox secretBox = SecretBox(
      cipherText,
      nonce: nonce,
      mac: Mac(macBytes),
    );

    final List<int> clear = await _cipher.decrypt(
      secretBox,
      secretKey: sharedSecret,
      aad: associatedData,
    );
    return utf8.decode(clear);
  }
}
