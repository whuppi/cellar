import 'package:cellar/src/decorators/encrypted/encryption_key_resolver.dart';
import 'package:cellar/src/decorators/encrypted/file_encryptor.dart';

/// Encryption configuration for a `Cellar`.
///
/// Pass an [encryptor] (your [FileEncryptor] implementation) and an
/// optional [keyResolver] (resolves per-key encryption keys; required
/// for any backend that needs key lookups). [encryptByDefault] is the
/// fallback policy when a write's `encrypt:` parameter is null.
class CellarEncryption {
  /// Bundle the BYO-crypto pieces; [encryptByDefault] sets the policy
  /// for writes that don't pass an explicit `encrypt:` option.
  const CellarEncryption({
    required this.encryptor,
    this.keyResolver,
    this.encryptByDefault = true,
  });

  /// The encryption algorithm. Bring your own (e.g. AES via
  /// `cipher_kit`, libsodium, WebCrypto, …) or implement [FileEncryptor]
  /// over any other library.
  final FileEncryptor encryptor;

  /// Per-key encryption key lookup. Required if your encryptor needs a
  /// key per object; optional for global-key configurations.
  final EncryptionKeyResolver? keyResolver;

  /// Default encryption decision when a write's `encrypt:` is null.
  /// `true` (default) means "encrypt unless the caller asks for plaintext".
  /// Set `false` for opt-in encryption.
  final bool encryptByDefault;
}
