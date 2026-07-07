/// Options for write operations.
///
/// Controls encryption behavior, content type, and custom metadata.
///
/// ## Encryption control
///
/// The [encrypt] field gives callers explicit per-write control:
/// - `true`: always encrypt. Fails if no encryptor is configured.
/// - `false`: always plaintext, even when encryption is configured.
/// - `null` (default): defer to the `EncryptedBackend.encryptByDefault`
///   decorator's policy, which in turn comes from
///   `CellarEncryption.encryptByDefault` passed to the `Cellar`
///   constructor.
///
/// ## Examples
///
/// ```dart
/// // Encrypt explicitly (fails if encryption not configured):
/// backend.write(key, bytes, WriteOptions(encrypt: true));
///
/// // Plaintext, regardless of default:
/// backend.write(key, bytes, const WriteOptions.plaintext());
///
/// // Defer to the configured default:
/// backend.write(key, bytes);
/// ```
//
// DESIGN NOTE — encryption is per-write, not per-backend or per-scope.
//
// An earlier API had the backend parse the key string to decide whether
// to encrypt (e.g. keys containing "media/" were encrypted). That
// coupled the backend to a specific key-naming convention and made it
// impossible to write a plaintext cache file under a "media/" prefix.
// Now the caller decides explicitly. `encrypt: null` defers to the
// EncryptedBackend's `encryptByDefault`, so apps that encrypt
// everything don't need to pass WriteOptions on every call.
class WriteOptions {
  /// Defaults: defer encryption to the backend policy, no content type,
  /// no metadata, no progress reporting.
  const WriteOptions({
    this.encrypt,
    this.encryptionKey,
    this.contentType,
    this.metadata = const {},
    this.onProgress,
  });

  /// Write as plaintext — explicitly no encryption.
  const WriteOptions.plaintext({
    this.contentType,
    this.metadata = const {},
    this.onProgress,
  }) : encrypt = false,
       encryptionKey = null;

  /// Write encrypted — explicitly request encryption with resolved key.
  const WriteOptions.encrypted({
    this.contentType,
    this.metadata = const {},
    this.onProgress,
  }) : encrypt = true,
       encryptionKey = null;

  /// Whether to encrypt this object.
  ///
  /// - `true`: always encrypt. Throws if no encryptor / key resolver is
  ///   available.
  /// - `false`: always plaintext.
  /// - `null`: defer to the `EncryptedBackend`'s default policy. If no
  ///   `EncryptedBackend` is in the stack at all, this is plaintext.
  final bool? encrypt;

  /// Explicit per-call encryption key.
  ///
  /// When null (the default), the `EncryptedBackend` looks the key up
  /// via its `EncryptionKeyResolver`. Only meaningful when this write
  /// will be encrypted (either [encrypt] is `true` or the default
  /// resolves to encrypt).
  final Object? encryptionKey;

  /// Content type (MIME type, e.g. "image/png", "audio/mpeg").
  final String? contentType;

  /// Custom metadata to store alongside the file.
  final Map<String, String> metadata;

  /// Optional progress callback for streaming writes.
  ///
  /// Called periodically with the bytes written so far and the total when
  /// known — `totalBytes` is null while the total is unknown (streaming
  /// input has no length until it ends).
  ///
  /// Progress is reported in the CALLER's byte space: an encrypted write
  /// reports plaintext bytes consumed, not ciphertext bytes landed, so a
  /// progress bar over the source size stays accurate.
  ///
  /// Only meaningful for `StorageBackend.writeStream`.
  /// Ignored for `StorageBackend.write` (single buffer, no progress).
  final void Function(int bytesWritten, int? totalBytes)? onProgress;
}
