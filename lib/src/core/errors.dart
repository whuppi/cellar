/// Typed error hierarchy for storage operations.
///
/// Every storage error is a sealed subtype of [StorageError] and carries
/// the storage [key] that caused it (when applicable). Pattern-match on
/// the concrete type for granular handling; catch [StorageError] as a
/// final fallback.
///
/// ```dart
/// try {
///   await cellar.read('missing/key');
/// } on FileNotFoundError catch (e) {
///   print('Not found: ${e.key}');
/// } on CorruptedFileError catch (e) {
///   print('Corrupted: ${e.key}, cause: ${e.cause}');
/// } on StorageError catch (e) {
///   print('Storage error: ${e.message}');
/// }
/// ```
sealed class StorageError implements Exception {
  const StorageError(this.message, {this.key});

  /// Human-readable error description.
  final String message;

  /// The storage key involved in the error (null for non-key-specific errors).
  final String? key;

  @override
  String toString() =>
      key != null ? 'StorageError($key): $message' : 'StorageError: $message';
}

/// File/object not found at the given key.
class FileNotFoundError extends StorageError {
  /// [key] is the missing object's key.
  const FileNotFoundError(String key) : super('File not found', key: key);

  @override
  String toString() => 'FileNotFoundError($key)';
}

/// Encryption was requested but no key could be resolved.
class EncryptionKeyMissingError extends StorageError {
  /// [key] is the object whose encryption key failed to resolve.
  const EncryptionKeyMissingError(String key)
    : super('Encryption requested but no key available', key: key);

  @override
  String toString() => 'EncryptionKeyMissingError($key)';
}

/// File is corrupted — cannot be read or decrypted.
class CorruptedFileError extends StorageError {
  /// [key] is the unreadable object; [cause] the underlying evidence.
  const CorruptedFileError(String key, {this.cause})
    : super('File corrupted or unreadable', key: key);

  /// The underlying error that revealed the corruption.
  final Object? cause;

  @override
  String toString() =>
      'CorruptedFileError($key${cause != null ? ', cause: $cause' : ''})';
}

/// Sidecar metadata is corrupted or unreadable.
///
/// The file data may still be intact. Metadata can be reconstructed
/// by re-reading the file header (for encrypted files) or re-writing
/// the metadata.
class CorruptedMetadataError extends StorageError {
  /// [key] is the object whose sidecar failed to parse.
  const CorruptedMetadataError(String key, {this.cause})
    : super('Metadata corrupted', key: key);

  /// The parse failure that revealed the corruption.
  final Object? cause;

  @override
  String toString() => 'CorruptedMetadataError($key)';
}

/// Per-chunk MAC verification failed — chunk has been tampered with
/// or the wrong key was used.
class ChunkVerificationError extends StorageError {
  /// [key] is the object; [chunkIndex] the chunk that failed its MAC.
  const ChunkVerificationError(String key, this.chunkIndex)
    : super('Chunk MAC verification failed', key: key);

  /// The 0-based index of the chunk that failed verification.
  final int chunkIndex;

  @override
  String toString() => 'ChunkVerificationError($key, chunk $chunkIndex)';
}

/// The encrypted file header is invalid or from an unsupported version.
class InvalidHeaderError extends StorageError {
  /// [key] is the object with the bad header (or a placeholder when the
  /// key isn't known at parse time).
  const InvalidHeaderError(String key, {this.cause})
    : super('Invalid or unsupported encryption header', key: key);

  /// What made the header unreadable.
  final Object? cause;

  @override
  String toString() =>
      'InvalidHeaderError($key${cause != null ? ', cause: $cause' : ''})';
}

/// The storage key contains invalid characters or structure.
///
/// Valid keys: segments separated by `/`. Each segment matches
/// `[a-zA-Z0-9][a-zA-Z0-9._-]*`. No path traversal (`.` or `..`),
/// no leading/trailing `/`, no consecutive `//`, no null bytes.
class InvalidKeyError extends StorageError {
  /// [key] is the rejected key; `reason` names the violated rule.
  const InvalidKeyError(String key, super.reason) : super(key: key);

  @override
  String toString() => 'InvalidKeyError($key): $message';
}

/// A write operation failed (disk full, permission denied, etc.).
class WriteError extends StorageError {
  /// [key] is the object whose write failed; [cause] the transport or
  /// filesystem error underneath.
  const WriteError(String key, {this.cause}) : super('Write failed', key: key);

  /// The underlying failure.
  final Object? cause;

  @override
  String toString() =>
      'WriteError($key${cause != null ? ', cause: $cause' : ''})';
}
