/// Resolves encryption keys for file operations.
///
/// The app provides the implementation backed by its own data store.
/// The resolver maps a storage key to an encryption key.
///
/// ## How it works
///
/// The `EncryptedBackend` calls [resolveKey] with the full
/// storage key string (e.g. "user/u1/photos/sunset"). The resolver
/// decides how to interpret the key — it might parse it to extract an
/// entity ID, or use a fixed key for all files, or anything else.
///
/// This is maximally flexible: the resolver is not coupled to any
/// particular key format or database schema.
///
/// ## Example implementation
///
/// ```dart
/// class MyKeyResolver implements EncryptionKeyResolver {
///   final MyDatabase db;
///
///   @override
///   Future<Object?> resolveKey(String storageKey) async {
///     // Parse the entity ID from the key
///     final parts = storageKey.split('/');
///     if (parts.length < 4) return null;
///     final entityId = parts[3];
///
///     // Look up encryption key from database
///     final entity = await db.findEntity(entityId);
///     return entity?.encryptionKey;
///   }
///
///   @override
///   void clearCache() { _cache.clear(); }
/// }
/// ```
//
// DESIGN NOTE — the resolver takes the full key string, not parsed parts.
//
// The old API split keys into domain/entityId/purpose and passed those
// as separate params. That coupled the resolver to a specific key format.
// Now it gets the raw string and decides how to interpret it. An app
// that uses "user/u1/photos/sunset" can parse on "/", an app that uses
// UUIDs as flat keys can look them up directly. The package doesn't care.
abstract interface class EncryptionKeyResolver {
  /// Resolve the encryption key for a storage key.
  ///
  /// [storageKey] is the full key string as it reaches the backend
  /// (e.g. `"user/u1/photos/sunset"`).
  ///
  /// Returns the encryption key, or null if encryption is not available
  /// for this key. The return type is `Object?` on purpose — cellar
  /// doesn't care what kind of key your `FileEncryptor` expects.
  Future<Object?> resolveKey(String storageKey);

  /// Clear cached keys (call on user lock/switch). Implement as a no-op
  /// if your resolver doesn't cache.
  void clearCache();
}
