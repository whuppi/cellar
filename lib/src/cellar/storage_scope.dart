import 'dart:typed_data';

import 'package:cellar/src/core/storage_backend.dart';
import 'package:cellar/src/core/key_validation.dart';
import 'package:cellar/src/core/materialized_file.dart';
import 'package:cellar/src/core/object_info.dart';
import 'package:cellar/src/core/write_options.dart';

/// Tenant-scoping wrapper around a [StorageBackend].
///
/// `Cellar` builds one `StorageScope` per partition and routes calls
/// through it. The scope's only job: prepend [keyPrefix] to every key
/// before delegating to the backend, and validate the key.
///
/// ```dart
/// // Unscoped — keys pass straight through:
/// final scope = StorageScope(backend);
/// scope.write('photos/sunset', bytes); // backend key: "photos/sunset"
///
/// // Scoped — every key gets the tenant prefix:
/// final scope = StorageScope(backend, keyPrefix: 'user/u1');
/// scope.write('photos/sunset', bytes); // backend key: "user/u1/photos/sunset"
///
/// // Two scopes, two tenants, one shared backend:
/// final alice = StorageScope(backend, keyPrefix: 'user/alice');
/// final bob   = StorageScope(backend, keyPrefix: 'user/bob');
/// ```
///
/// ## Key structure
///
/// The scope does not impose any structure on keys past the prefix.
/// Paths are `/`-separated strings; apps choose their own conventions.
///
/// ## Encryption
///
/// Encryption is per-write via [WriteOptions]. The scope passes
/// `WriteOptions` through to the backend unchanged; encryption is
/// applied (or not) by an `EncryptedBackend` decorator further down
/// the stack.
//
// DESIGN NOTE — the scope is deliberately thin.
//
// One job: validate keys + prepend the tenant prefix. No encryption
// decisions, no key resolution, no content-type guessing. Those live
// in decorators (EncryptedBackend, ChunkedBackend) or in the caller.
// If you're tempted to add behavior here, it almost always belongs in
// a new decorator instead.
class StorageScope {
  /// Create a scoped view over [backend].
  ///
  /// [keyPrefix] is an optional tenant prefix prepended to every key.
  /// Use it to isolate data contexts (per-user, per-profile, per-device).
  /// Pass null for no prefixing (keys used as-is).
  StorageScope(this._backend, {this.keyPrefix});
  final StorageBackend _backend;

  /// Optional tenant prefix applied to every key. Null = no prefix.
  ///
  /// When set, every operation goes to the backend at
  /// `'$keyPrefix/$path'`. When null, paths reach the backend unchanged.
  final String? keyPrefix;

  /// The underlying backend (for advanced or raw operations that need
  /// to bypass the prefix layer).
  StorageBackend get backend => _backend;

  /// Build the prefixed key for a user-supplied path. No-op when
  /// [keyPrefix] is null.
  String key(String path) => keyPrefix != null ? '$keyPrefix/$path' : path;

  /// Build the prefixed prefix for list/delete operations. Same logic
  /// as [key] — exposed separately for readability at call sites.
  String prefix(String path) => keyPrefix != null ? '$keyPrefix/$path' : path;

  /// Strip the tenant prefix off a backend-returned [ObjectInfo], so
  /// results speak the same scope-relative keys callers write with —
  /// a listed key must round-trip into [read] unchanged. No-op when
  /// [keyPrefix] is null.
  ObjectInfo _unscoped(ObjectInfo info) {
    final p = keyPrefix;
    if (p == null) return info;
    final scoped = '$p/';
    return info.key.startsWith(scoped)
        ? info.copyWith(key: info.key.substring(scoped.length))
        : info;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // WRITE
  // ══════════════════════════════════════════════════════════════════════════

  /// Validate [path], apply the prefix, write [bytes] at the scoped key.
  Future<void> write(
    String path,
    Uint8List bytes, [
    WriteOptions options = const WriteOptions(),
  ]) {
    validateKey(path);
    return _backend.write(key(path), bytes, options);
  }

  /// Streaming variant of [write] — constant memory for any size.
  Future<void> writeStream(
    String path,
    Stream<List<int>> byteStream, [
    WriteOptions options = const WriteOptions(),
  ]) {
    validateKey(path);
    return _backend.writeStream(key(path), byteStream, options);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // READ
  // ══════════════════════════════════════════════════════════════════════════

  /// Read the full body at the scoped key. Throws `FileNotFoundError`
  /// when absent.
  Future<Uint8List> read(String path) {
    validateKey(path);
    return _backend.read(key(path));
  }

  /// Streaming variant of [read].
  Stream<List<int>> readStream(String path) {
    validateKey(path);
    return _backend.readStream(key(path));
  }

  /// Read [length] bytes starting at [start] from the scoped key.
  Future<Uint8List> readRange(
    String path, {
    required int start,
    required int length,
  }) {
    validateKey(path);
    return _backend.readRange(key(path), start: start, length: length);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // METADATA
  // ══════════════════════════════════════════════════════════════════════════

  /// Metadata without the body; null when the scoped key is absent.
  Future<ObjectInfo?> head(String path) async {
    validateKey(path);
    final info = await _backend.head(key(path));
    return info == null ? null : _unscoped(info);
  }

  /// Whether the scoped key exists.
  Future<bool> exists(String path) {
    validateKey(path);
    return _backend.exists(key(path));
  }

  /// Replace contentType + metadata at the scoped key, bytes untouched.
  Future<void> updateMetadata(
    String path, {
    String? contentType,
    Map<String, String> metadata = const {},
  }) {
    validateKey(path);
    return _backend.updateMetadata(
      key(path),
      contentType: contentType,
      metadata: metadata,
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // DELETE
  // ══════════════════════════════════════════════════════════════════════════

  /// Delete the scoped key. No-op when absent.
  Future<void> delete(String path) {
    validateKey(path);
    return _backend.delete(key(path));
  }

  /// Delete every scoped key under [pathPrefix] (raw string prefix).
  Future<void> deletePrefix(String pathPrefix) {
    validatePrefix(pathPrefix);
    return _backend.deletePrefix(prefix(pathPrefix));
  }

  // ══════════════════════════════════════════════════════════════════════════
  // LIST
  // ══════════════════════════════════════════════════════════════════════════

  /// List every scoped key under [pathPrefix] (raw string prefix).
  Future<List<ObjectInfo>> list(String pathPrefix) async {
    validatePrefix(pathPrefix);
    final objects = await _backend.list(prefix(pathPrefix));
    return objects.map(_unscoped).toList();
  }

  /// Like [list] but returns just the keys.
  Future<List<String>> listKeys(String pathPrefix) async {
    validatePrefix(pathPrefix);
    final objects = await list(pathPrefix);
    return objects.map((o) => o.key).toList();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // COPY
  // ══════════════════════════════════════════════════════════════════════════

  /// Copy within this scope, metadata included.
  Future<void> copy(String sourcePath, String destPath) {
    validateKey(sourcePath);
    validateKey(destPath);
    return _backend.copy(key(sourcePath), key(destPath));
  }

  /// Copy then delete the source. Not atomic across the two steps.
  Future<void> move(String sourcePath, String destPath) async {
    validateKey(sourcePath);
    validateKey(destPath);
    await _backend.copy(key(sourcePath), key(destPath));
    await _backend.delete(key(sourcePath));
  }

  /// Copy into another scope — the backends must share a
  /// substrate (same underlying store) for the raw copy to land.
  Future<void> copyToScope(
    String sourcePath,
    StorageScope dest,
    String destPath,
  ) {
    validateKey(sourcePath);
    validateKey(destPath);
    return _backend.copy(key(sourcePath), dest.key(destPath));
  }

  // ══════════════════════════════════════════════════════════════════════════
  // UTILITIES
  // ══════════════════════════════════════════════════════════════════════════

  /// Total size in bytes of all files under a path prefix.
  Future<int> totalSize(String pathPrefix) async {
    final objects = await _backend.list(prefix(pathPrefix));
    var total = 0;
    for (final o in objects) {
      total += o.size;
    }
    return total;
  }

  /// File size in bytes (0 if not found).
  Future<int> fileSize(String path) async {
    final info = await _backend.head(key(path));
    return info?.size ?? 0;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // MATERIALIZE
  // ══════════════════════════════════════════════════════════════════════════

  /// Materialize a stored object as a platform-local handle.
  ///
  /// See [StorageBackend.materialize] for the full behavior matrix
  /// across backends.
  Future<MaterializedFile> materialize(
    String path, {
    bool decrypt = true,
    bool exclusive = false,
  }) {
    validateKey(path);
    return _backend.materialize(
      key(path),
      decrypt: decrypt,
      exclusive: exclusive,
    );
  }
}
