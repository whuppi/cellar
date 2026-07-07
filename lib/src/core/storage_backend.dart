import 'dart:typed_data';

import 'package:cellar/src/core/materialized_file.dart';
import 'package:cellar/src/core/object_info.dart';
import 'package:cellar/src/core/write_options.dart';

/// Platform-agnostic object storage interface.
///
/// Every backend in cellar (local filesystem, IndexedDB, plus the
/// `Encrypted` and `Chunked` decorators) implements this interface.
/// `Cellar` orchestrates one or more backends; backends themselves are
/// flat key/value stores that know nothing about partitions or scoping.
///
/// All keys are `/`-separated paths (e.g. `"user/u1/photos/sunset"`).
/// Each segment must match `[a-zA-Z0-9][a-zA-Z0-9._-]*`. No path
/// traversal (`.` or `..`), no leading or trailing `/`, no consecutive
/// `//`, no null bytes, no characters unsafe on Windows
/// (`\ : * ? " < > |`). See `validateKey` for the full rules.
///
/// Stream-first: [readStream] and [writeStream] are the primary paths;
/// [read] and [write] are convenience wrappers that buffer internally
/// for small files.
///
/// ## Cross-backend contract
///
/// Every method here MUST be implementable by every backend cellar
/// supports. If a feature can't honor that contract on every backend,
/// it doesn't belong on this interface — push it onto the concrete
/// backend or onto a decorator — never onto this interface.
///
/// When non-Dart code needs to consume stored bytes (FFI, OS file
/// pickers, browser APIs taking a URL, native plugins taking a `File`),
/// use [materialize]. It returns a platform-local handle — file path
/// on native, Blob URL on web — and works on every backend.
///
/// ## Concurrency
///
/// Backends do NOT provide internal locking. Concurrent writes to the
/// same key may corrupt the object. The caller is responsible for
/// serializing writes to the same key (e.g. via a mutex or queue).
/// Reads are safe to perform concurrently with other reads but not
/// with writes.
///
/// ## Method surface (13 methods)
///
/// ```
/// write / writeStream    — store bytes at a key
/// read / readStream      — retrieve bytes by key
/// readRange              — partial read (byte range)
/// head / exists          — metadata / presence without body
/// delete / deletePrefix  — remove by key or prefix
/// list                   — enumerate keys under prefix
/// copy                   — duplicate from one key to another
/// updateMetadata         — change content-type / metadata in place
/// materialize            — platform-local handle for non-Dart code
/// ```
///
/// Implementations shipped with cellar:
/// - `FileSystemBackend` — `dart:io` filesystem (native)
/// - `IndexedDbBackend` — IndexedDB (web)
/// - `EncryptedBackend` — transparent encryption decorator
/// - `ChunkedBackend` — chunk-and-manifest decorator
//
// DESIGN NOTES — read before modifying this interface.
//
// 1. No filesystem paths on regular CRUD. No resolveAbsolutePath(),
//    no getFilePath(). Paths leak the local backend's implementation
//    detail. IndexedDB has no paths; remote stores have none. When non-Dart
//    code needs to consume stored bytes, use [materialize] — it
//    returns a platform-local handle abstracted across every backend
//    (blob URL on web, original path on local files).
//
// 2. No disk-space queries. `availableDiskSpace()` was always a lie —
//    IndexedDB can't report it, and native answers vary by OS quota.
//    Callers should handle WriteError (disk full) instead.
//
// 3. Stream-first. `writeStream`/`readStream` are the primary paths.
//    `write`/`read` buffer internally and exist for small-file
//    convenience. Every method must work with constant memory — no
//    "read entire file to do X" hidden inside the backend.
//
// 4. WriteOptions, not implicit encryption. The old API parsed the key
//    string to decide whether to encrypt. That coupled the backend to
//    a specific key format. Now the caller says encrypt: true/false/null
//    explicitly. The backend never inspects the key string.
//
// 5. 13 methods, not more. Every method must be implementable by local
//    filesystem, IndexedDB, a remote store. If a method only works on one
//    backend, it doesn't belong here.
abstract interface class StorageBackend {
  // ── Write ──

  /// Write a byte stream with optional write options.
  ///
  /// Creates parent structure if needed. Replaces any existing object.
  /// Primary write path — [write] delegates to this.
  ///
  /// [options] controls encryption, content type, and metadata.
  Future<void> writeStream(
    String key,
    Stream<List<int>> byteStream, [
    WriteOptions options = const WriteOptions(),
  ]);

  /// Write bytes. Convenience wrapper over [writeStream].
  Future<void> write(
    String key,
    Uint8List bytes, [
    WriteOptions options = const WriteOptions(),
  ]);

  // ── Read ──

  /// Read as a byte stream. Primary read path.
  Stream<List<int>> readStream(String key);

  /// Read entire contents as bytes. Convenience wrapper over [readStream].
  Future<Uint8List> read(String key);

  /// Read a byte range.
  ///
  /// Returns bytes starting at [start] with the given [length]. For
  /// encrypted files, only the overlapping chunks are decrypted; for
  /// chunked files, only the overlapping chunk records are read.
  Future<Uint8List> readRange(
    String key, {
    required int start,
    required int length,
  });

  // ── Metadata ──

  /// Get object metadata without reading the body (HeadObject).
  ///
  /// Returns null if the key does not exist.
  Future<ObjectInfo?> head(String key);

  /// Check if a key exists. Convenience for `(await head(key)) != null`.
  Future<bool> exists(String key);

  // ── Delete ──

  /// Delete a single object.
  Future<void> delete(String key);

  /// Delete every object whose key starts with [prefix] (batch delete).
  ///
  /// Prefixes are RAW string prefixes, S3-style — the same rule on every
  /// backend. `deletePrefix('photos')` removes `photos/a` AND
  /// `photos_old/b` AND `photos2`; end the prefix with `/` to scope to a
  /// pseudo-directory: `deletePrefix('photos/')` removes only `photos/*`.
  /// The empty prefix deletes everything.
  Future<void> deletePrefix(String prefix);

  // ── List ──

  /// List every object whose key starts with [prefix], with full metadata.
  ///
  /// Same RAW string-prefix rule as [deletePrefix]: `list('photos')`
  /// matches `photos/a`, `photos_old/b`, and `photos2`; `list('photos/')`
  /// matches only `photos/*`. The empty prefix lists everything.
  Future<List<ObjectInfo>> list(String prefix);

  // ── Copy ──

  /// Copy an object, including its metadata.
  ///
  /// Local: filesystem-level copy. Encrypted: re-encrypts when the
  /// destination resolves to a different encryption key. Remote: server-
  /// side `CopyObject`. The metadata travels with the body.
  Future<void> copy(String sourceKey, String destKey);

  // ── Metadata update ──

  /// Update metadata for an existing object without touching its bytes.
  ///
  /// Used after streaming writes where some metadata field (e.g. the
  /// original-plaintext size for an encrypted file) is only known once
  /// the stream completes.
  ///
  /// - Local: rewrites the `.meta.json` sidecar.
  /// - IndexedDB: re-reads the record and writes it back with the
  ///   updated metadata fields.
  /// - A remote store: copy-to-itself with new metadata (when it has no
  ///   in-place metadata update).
  Future<void> updateMetadata(
    String key, {
    String? contentType,
    Map<String, String> metadata = const {},
  });

  // ── Materialize ──

  /// Make a stored object available as a platform-local accessible resource.
  ///
  /// Returns a [MaterializedFile] whose `localPath` is a filesystem
  /// path on native (usable for FFI, platform channels, native plugins
  /// taking a `File`/path, OS file dialogs, mmap) or a Blob URL on web
  /// (usable in `<audio>`/`<img>`/`<video>` `src`, `fetch()`, anchor
  /// downloads, Web Workers). The path is LOCAL to this device — it
  /// MUST NOT be persisted, synced, or shared across devices.
  ///
  /// ## Parameters
  ///
  /// [decrypt] — if `true` and the underlying file is encrypted, the
  /// materialized file contains plaintext. If `false`, the raw stored bytes
  /// (possibly ciphertext) are returned. For unencrypted files the flag has
  /// no effect. Default: `true` (callers usually want readable content).
  ///
  /// [exclusive] — if `true`, the caller gets a private copy they may
  /// modify or delete. If `false`, the caller gets shared access; on local
  /// backends this returns the original file path (zero copy). Default:
  /// `false`.
  ///
  /// ## Behavior matrix
  ///
  /// | Backend   | encrypted? | decrypt | exclusive | Result                        |
  /// |-----------|-----------|---------|-----------|-------------------------------|
  /// | Local     | no        | any     | false     | Original path (zero copy)     |
  /// | Local     | no        | any     | true      | Copy to temp                  |
  /// | Local     | yes       | true    | false     | Decrypt to cache (reusable)   |
  /// | Local     | yes       | true    | true      | Decrypt to temp (caller owns) |
  /// | Local     | yes       | false   | false     | Original encrypted path       |
  /// | Local     | yes       | false   | true      | Copy encrypted to temp        |
  /// | IndexedDB | no        | any     | any       | Blob URL                      |
  /// | IndexedDB | yes       | true    | any       | Decrypt + blob URL            |
  /// | IndexedDB | yes       | false   | any       | Raw blob URL                  |
  ///
  /// ## Lifecycle
  ///
  /// Call [MaterializedFile.release] when done.
  /// - Local, `exclusive: false`, unencrypted: no-op (original stays).
  /// - Local, `exclusive: false`, decrypted: cached; cleaned on eviction.
  /// - Local, `exclusive: true`: temp deleted.
  /// - IndexedDB: blob URL revoked.
  Future<MaterializedFile> materialize(
    String key, {
    bool decrypt = true,
    bool exclusive = false,
  });

  // ── Lifecycle ──

  /// Release the resources this backend itself constructed (database
  /// connections, HTTP clients). Idempotent — safe to call twice. Every
  /// method except [dispose] throws [StateError] afterwards.
  ///
  /// Ownership rule: a backend disposes ONLY what it created. Decorators
  /// (`EncryptedBackend`, `ChunkedBackend`) never dispose the backend
  /// they wrap — whoever constructed the inner backend disposes it.
  /// `Cellar.close()` follows the same rule: it disposes the backends it
  /// built, and leaves `Cellar.withBackends`-provided ones to the caller.
  Future<void> dispose();
}
