import 'package:cellar/src/backends/file_system/file_system_backend.dart';
import 'package:cellar/src/cellar/storage_roots.dart';
import 'package:cellar/src/core/storage_backend.dart';

/// Create a native (dart:io) [StorageBackend] for one partition.
///
/// [name] — the cellar's storage area name (e.g. `'my_app'`).
/// [partition] — the partition name within that area (e.g. `'main'`,
/// `'image_cache'`).
/// [osManaged] — when true, place the partition under [StorageRoots.cache]
/// (iOS/Android may evict there). When false, use [StorageRoots.support].
/// [osBackup] — when false on iOS/macOS, exclude the partition's
/// directory from iCloud backup (iOS) and Time Machine (macOS) via the
/// `kCFURLIsExcludedFromBackupKey` resource property. No-op elsewhere.
/// [roots] — the caller-supplied directories. REQUIRED on native: the
/// core never guesses storage locations (no HOME/XDG/APPDATA
/// conventions, no plugin asks). Flutter apps get them resolved by
/// `package:cellar_flutter`'s `openCellar`; servers and CLIs pass their
/// configured paths.
Future<StorageBackend> initBackendForPartition({
  required String name,
  required String partition,
  required bool osManaged,
  bool osBackup = true,
  StorageRoots? roots,
}) async {
  if (roots == null) {
    throw StateError(
      'cellar: Cellar(name:) on native platforms needs roots. Flutter '
      'apps: use package:cellar_flutter — openCellar() resolves them. '
      'Servers/CLIs: pass Cellar(roots: StorageRoots(support: ..., '
      "cache: ...)) with your configured data directories, or use "
      'Cellar.atPath.',
    );
  }
  final root = osManaged ? roots.cache : roots.support;
  final backend = FileSystemBackend(
    '$root/$name/$partition',
    osBackup: osBackup,
  );
  // Best-effort sweep of any tombstones left by a prior session
  // (Windows delete-while-open workaround). No-op on POSIX.
  await backend.sweepTombstones();
  return backend;
}

/// Return a platform-default [StorageBackend] suitable for consumers
/// that need a bare local backend with no partitions — e.g. as the
/// local-cache layer of a custom remote-backend composition.
///
/// Native: a [FileSystemBackend] under `roots.support/$name` — [roots]
/// is required here for the same no-guessing rule as
/// [initBackendForPartition].
/// Web (via the conditional import): an `IndexedDbBackend` named
/// [name]; roots are not consulted.
Future<StorageBackend> initDefaultBackend({
  required String name,
  StorageRoots? roots,
}) async {
  if (roots == null) {
    throw StateError(
      'cellar: initDefaultBackend on native platforms needs roots — '
      'pass StorageRoots(support: ..., cache: ...).',
    );
  }
  final backend = FileSystemBackend('${roots.support}/$name');
  await backend.sweepTombstones();
  return backend;
}
