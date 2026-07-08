import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cellar/src/backends/file_system/os/file_system_os.dart';
import 'package:cellar/src/backends/file_system/os/windows_file_system_os.dart';
import 'package:cellar/src/core/storage_backend.dart';
import 'package:cellar/src/core/dispose_guard.dart';
import 'package:cellar/src/core/errors.dart';
import 'package:cellar/src/core/materialized_file.dart';
import 'package:cellar/src/core/object_info.dart';
import 'package:cellar/src/core/write_options.dart';

/// Native filesystem [StorageBackend] backed by `dart:io`.
///
/// Keys are `/`-separated paths resolved relative to a base directory:
/// `"device/model/abc/gguf"` → `"{baseDir}/device/model/abc/gguf"`.
///
/// Per-object metadata (content type, custom metadata) lives in sibling
/// `.meta.json` sidecar files next to each object. Sidecars travel with
/// the body on `copy`; no external database is involved.
///
/// `dart:io` only — this class never compiles on web. The web build
/// gets the throwing stub via the conditional re-export in
/// `file_system_backend.dart` (the plain-named switch is the import point).
///
/// ## Per-OS behavior
///
/// This class is OS-blind. Everything that differs between operating
/// systems (delete-while-open semantics, rename-over rules, backup
/// exclusion) goes through the [FileSystemOs] seam — common behavior in
/// [DefaultFileSystemOs], one subclass per OS overriding only its own
/// quirk. Inject a specific OS in tests to exercise its paths anywhere.
///
/// ## iCloud / Time Machine backup exclusion
///
/// Passing `osBackup: false` excludes `_baseDir` from the platform
/// backup: `kCFURLIsExcludedFromBackupKey` via CFURL on iOS (in-
/// sandbox — process spawning is forbidden there), `tmutil addexclusion`
/// on macOS (the supported Time Machine mechanism). On Android / Linux /
/// Windows the flag is a no-op. Applied lazily on the first write —
/// there's no async setup step in the constructor.
class FileSystemBackend with DisposeGuard implements StorageBackend {
  /// Create a backend rooted at `baseDir`.
  ///
  /// [osBackup] (default `true`) controls whether the directory
  /// participates in OS backup (iCloud on iOS, Time Machine on macOS).
  /// Pass `false` for partitions whose contents are regenerable (cache,
  /// scratch) so they don't waste the user's backup quota. No-op on
  /// platforms without the concept.
  /// [os] overrides the per-OS behavior seam — tests inject a specific
  /// OS to exercise its paths on any machine.
  FileSystemBackend(this._baseDir, {bool osBackup = true, FileSystemOs? os})
    : _osBackup = osBackup,
      _os = os ?? FileSystemOs.current();

  /// Suffix marking Windows delete-while-open leftovers — see
  /// [WindowsFileSystemOs], the quirk's home.
  static const String tombstoneSuffix = WindowsFileSystemOs.tombstoneSuffix;

  /// Suffix for in-flight streaming-write temp files. The temp is renamed
  /// over the destination only after the source stream completes, so a
  /// failed or interrupted write never leaves a readable partial object.
  /// Filtered from listings like tombstones; a crash leftover is inert.
  static const String writeTempSuffix = '.cellar_write.';

  @override
  String get disposeLabel => 'FileSystemBackend';

  final String _baseDir;
  final bool _osBackup;
  final FileSystemOs _os;
  bool _osBackupApplied = false;

  File _file(String key) => File('$_baseDir/$key');
  File _metaFile(String key) => File('$_baseDir/$key.meta.json');

  /// Apply the backup exclusion if needed. Called lazily from the first
  /// write so the constructor stays sync. Idempotent.
  ///
  /// Only does work when `osBackup: false` was passed AND the OS has a
  /// backup mechanism. Everywhere else this is a no-op marker flip.
  Future<void> _ensureBackupAttribute() async {
    if (_osBackupApplied) return;
    _osBackupApplied = true;

    // Backup is allowed (default) — nothing to do. OSes without the
    // concept answer false from the seam's default implementation.
    if (_osBackup) return;

    try {
      await Directory(_baseDir).create(recursive: true);
      await _os.excludeFromBackup(_baseDir);
    } catch (_) {
      // Best-effort: never fail a write because the backup flag couldn't
      // be set. The dev gets the safe (backed-up) outcome instead.
    }
  }

  /// Sweep up tombstone files (Windows delete-while-open leftovers).
  /// Safe to call any time; no-op on POSIX.
  Future<void> sweepTombstones() async {
    checkNotDisposed();
    await _os.sweepTombstones(_baseDir);
  }

  String _writeTempPath(String filePath) {
    final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    return '$filePath$writeTempSuffix$stamp';
  }

  // ── Write ──

  @override
  Future<void> writeStream(
    String key,
    Stream<List<int>> byteStream, [
    WriteOptions options = const WriteOptions(),
  ]) async {
    checkNotDisposed();
    await _ensureBackupAttribute();
    final file = _file(key);
    await file.parent.create(recursive: true);

    // Atomic write: stream into a sibling temp, promote by rename only
    // after the source completes. A stream that errors (or a crash) must
    // never leave a readable partial object at the key — a torn cache
    // fill or interrupted upload would otherwise be served as complete.
    final temp = File(_writeTempPath(file.path));
    final sink = temp.openWrite();
    var bytesWritten = 0;
    try {
      await for (final chunk in byteStream) {
        sink.add(chunk);
        bytesWritten += chunk.length;
        options.onProgress?.call(bytesWritten, null);
      }
      await sink.close();
    } catch (e) {
      try {
        await sink.close();
      } on FileSystemException {
        // The sink may already be broken; the temp delete below is what
        // matters.
      }
      await _os.deleteFile(temp);
      rethrow;
    }
    await _os.renameOver(temp, file.path);
    await _writeMeta(key, options.contentType, options.metadata);
  }

  @override
  Future<void> write(
    String key,
    Uint8List bytes, [
    WriteOptions options = const WriteOptions(),
  ]) async {
    checkNotDisposed();
    await _ensureBackupAttribute();
    final file = _file(key);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    await _writeMeta(key, options.contentType, options.metadata);
  }

  // ── Read ──

  @override
  Stream<List<int>> readStream(String key) async* {
    checkNotDisposed();
    final file = _file(key);
    if (!await file.exists()) throw FileNotFoundError(key);
    yield* file.openRead();
  }

  @override
  Future<Uint8List> read(String key) async {
    checkNotDisposed();
    try {
      return await _file(key).readAsBytes();
    } on FileSystemException {
      // Subtype varies by substrate (PathNotFoundException on the real
      // filesystem, base FileSystemException on dart:io-compatible
      // stand-ins) — decide not-found by existence, then rethrow.
      if (!await _file(key).exists()) throw FileNotFoundError(key);
      rethrow;
    }
  }

  @override
  Future<Uint8List> readRange(
    String key, {
    required int start,
    required int length,
  }) async {
    checkNotDisposed();
    final RandomAccessFile raf;
    try {
      raf = await _file(key).open(mode: FileMode.read);
    } on FileSystemException {
      // Same substrate-varying subtype as in read() — decide by existence.
      if (!await _file(key).exists()) throw FileNotFoundError(key);
      rethrow;
    }
    try {
      await raf.setPosition(start);
      return await raf.read(length);
    } finally {
      await raf.close();
    }
  }

  // ── Metadata ──

  @override
  Future<ObjectInfo?> head(String key) async {
    checkNotDisposed();
    final file = _file(key);
    if (!await file.exists()) return null;
    final stat = await file.stat();
    final meta = await _readMeta(key);
    return ObjectInfo(
      key: key,
      size: stat.size,
      // Tolerate a corrupt sidecar: non-string values degrade to absent
      // instead of throwing a TypeError out of head().
      contentType: meta?['contentType'] is String
          ? meta!['contentType'] as String
          : null,
      metadata: _castMetadata(meta?['metadata']),
      lastModified: stat.modified.toUtc(),
    );
  }

  @override
  Future<bool> exists(String key) {
    checkNotDisposed();
    return _file(key).exists();
  }

  // ── Delete ──

  @override
  Future<void> delete(String key) async {
    checkNotDisposed();
    await _os.deleteFile(_file(key));
    await _os.deleteFile(_metaFile(key));
  }

  @override
  Future<void> deletePrefix(String prefix) async {
    checkNotDisposed();
    // Empty prefix = wipe everything — but delete the CHILDREN, never
    // the base directory itself: the root carries OS attributes (the
    // backup exclusion) that a delete-and-recreate would silently lose.
    if (prefix.isEmpty) {
      final root = Directory(_baseDir);
      if (await root.exists()) {
        await for (final entity in root.list(followLinks: false)) {
          if (entity is File) {
            await _os.deleteFile(entity);
          } else if (entity is Directory) {
            await _deleteSubtree(entity);
          }
        }
      }
      return;
    }
    // '/'-terminated prefixes map exactly to a directory subtree —
    // recursive delete fast path.
    if (prefix.endsWith('/')) {
      await _deleteSubtree(Directory('$_baseDir/$prefix'));
      return;
    }
    // Bare prefix — RAW semantics: the object at `prefix` itself, the
    // subtree under `prefix/`, and every sibling entry sharing the
    // partial segment (photos → photos_old/, photos2, photos2.meta.json).
    final parent = Directory(
      '$_baseDir/${prefix.substring(0, prefix.lastIndexOf('/') + 1)}',
    );
    if (!await parent.exists()) return;
    final fullPrefix = _keyForm('$_baseDir/$prefix');
    await for (final entity in parent.list(followLinks: false)) {
      if (!_keyForm(entity.path).startsWith(fullPrefix)) continue;
      if (entity is File) {
        await _os.deleteFile(entity);
      } else if (entity is Directory) {
        await _deleteSubtree(entity);
      }
    }
  }

  /// Recursive directory delete honoring Windows tombstones: try the fast
  /// whole-tree delete; when held files block it (Windows), fall back to
  /// per-file safe deletes and a best-effort rmdir.
  Future<void> _deleteSubtree(Directory dir) async {
    if (!await dir.exists()) return;
    try {
      await dir.delete(recursive: true);
      return;
    } on FileSystemException {
      // Fall through to per-file deletion with tombstone fallback.
    }
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) await _os.deleteFile(entity);
    }
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // Some files may have been tombstoned and still hold the dir open.
      // Sweep will pick them up later.
    }
  }

  // ── List ──

  @override
  Future<List<ObjectInfo>> list(String prefix) async {
    checkNotDisposed();
    final keys = await _listKeys(prefix);
    final results = <ObjectInfo>[];
    for (final key in keys) {
      final info = await head(key);
      if (info != null) results.add(info);
    }
    return results;
  }

  // ── Copy ──

  @override
  Future<void> copy(String sourceKey, String destKey) async {
    checkNotDisposed();
    final dest = _file(destKey);
    await dest.parent.create(recursive: true);
    await _file(sourceKey).copy(dest.path);
    final srcMeta = _metaFile(sourceKey);
    if (await srcMeta.exists()) {
      await srcMeta.copy(_metaFile(destKey).path);
    }
  }

  // ── Metadata update ──

  @override
  Future<void> updateMetadata(
    String key, {
    String? contentType,
    Map<String, String> metadata = const {},
  }) async {
    checkNotDisposed();
    await _writeMeta(key, contentType, metadata);
  }

  // ── Internal: metadata sidecar ──

  Future<void> _writeMeta(
    String key,
    String? contentType,
    Map<String, String> metadata,
  ) async {
    if (contentType == null && metadata.isEmpty) {
      await _os.deleteFile(_metaFile(key));
      return;
    }
    final metaFile = _metaFile(key);
    await metaFile.parent.create(recursive: true);
    await metaFile.writeAsString(
      jsonEncode({'contentType': contentType, 'metadata': metadata}),
      flush: true,
    );
  }

  Future<Map<String, dynamic>?> _readMeta(String key) async {
    final metaFile = _metaFile(key);
    if (!await metaFile.exists()) return null;
    try {
      return jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      // Sidecar holds derived metadata; the body is the source of truth.
      // Delete the unparseable sidecar so the next write rebuilds it
      // cleanly, and treat this read as if no metadata existed.
      try {
        await metaFile.delete();
      } on FileSystemException {
        // Sidecar cleanup is best-effort; the next write overwrites it.
      }
      return null;
    }
  }

  Map<String, String> _castMetadata(Object? raw) {
    // Validate eagerly. A lazy `.cast<String, String>()` view would throw
    // a TypeError at some distant read site the first time a corrupt
    // sidecar carries a non-string value; dropping bad entries here keeps
    // corruption degradation local, like the rest of the sidecar handling.
    if (raw is! Map) return const {};
    return {
      for (final entry in raw.entries)
        if (entry.key is String && entry.value is String)
          entry.key as String: entry.value as String,
    };
  }

  // ── Internal: key listing (excludes .meta.json sidecars + tombstones) ──

  /// Platform path → key form. Directory.list returns `\`-separated
  /// paths on Windows; keys are always `/`-separated (the grammar forbids
  /// `\`), so both prefix filtering and key reconstruction compare in
  /// key form.
  String _keyForm(String path) => path.replaceAll('\\', '/');

  bool _isUserFile(String path) {
    if (path.endsWith('.meta.json')) return false;
    if (path.contains(tombstoneSuffix)) return false;
    if (path.contains(writeTempSuffix)) return false;
    return true;
  }

  Future<List<String>> _listKeys(String prefix) async {
    // RAW string-prefix contract: walk the deepest directory that fully
    // contains every candidate (the prefix's last full segment), filter by
    // raw path prefix. One pass covers subtree keys ('photos/'), siblings
    // sharing a partial segment ('photos' matching photos_old/x, photos2),
    // and arbitrarily deep keys under either.
    final parent = Directory(
      '$_baseDir/${prefix.substring(0, prefix.lastIndexOf('/') + 1)}',
    );
    if (!await parent.exists()) return [];
    final fullPrefix = _keyForm('$_baseDir/$prefix');
    final keys = <String>[];
    await for (final entity in parent.list(
      recursive: true,
      followLinks: false,
    )) {
      final path = _keyForm(entity.path);
      if (entity is File && path.startsWith(fullPrefix) && _isUserFile(path)) {
        keys.add(path.substring(fullPrefix.length - prefix.length));
      }
    }
    return keys;
  }

  // ── Materialize ──

  /// Materialize on the local filesystem.
  ///
  /// This backend stores raw bytes and knows nothing about encryption —
  /// the [decrypt] flag is accepted for interface compliance but has no
  /// effect here. When an `EncryptedBackend` wraps this backend it
  /// intercepts [materialize] and applies the decrypt semantics BEFORE
  /// delegating. Callers holding a bare [FileSystemBackend] always get the
  /// raw on-disk bytes back.
  @override
  Future<MaterializedFile> materialize(
    String key, {
    bool decrypt = true,
    bool exclusive = false,
  }) async {
    checkNotDisposed();
    final file = _file(key);
    if (!file.existsSync()) {
      throw FileNotFoundError(key);
    }

    if (!exclusive) {
      // Shared access — return the original path. Zero copy.
      return MaterializedFile(
        localPath: file.path,
        key: key,
        release: () async {}, // no-op — original stays
      );
    }

    // Exclusive — copy to a temp file the caller owns.
    final tempDir = await Directory.systemTemp.createTemp('cellar_');
    final tempFile = File('${tempDir.path}/${file.path.split('/').last}');
    await file.copy(tempFile.path);

    return MaterializedFile(
      localPath: tempFile.path,
      key: key,
      release: () async {
        // Best-effort: an undeletable temp is orphaned in systemTemp,
        // which the OS reclaims.
        try {
          await tempFile.delete();
        } on FileSystemException {
          return;
        }
        try {
          await tempDir.delete();
        } on FileSystemException {
          // Non-empty or held — the OS temp reaper owns it now.
        }
      },
    );
  }

  // ── Lifecycle ──

  @override
  Future<void> dispose() async {
    // The filesystem needs no releasing — dispose just arms the guard so
    // use-after-dispose fails fast instead of racing a torn-down owner.
    markDisposed();
  }
}
