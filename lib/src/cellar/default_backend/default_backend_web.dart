import 'package:cellar/src/cellar/storage_roots.dart';
import 'package:cellar/src/core/storage_backend.dart';
import 'package:cellar/src/backends/indexed_db/indexed_db_backend.dart';

/// Create a web (IndexedDB) [StorageBackend] for one partition.
///
/// Each partition gets its own IndexedDB database named `{name}__{partition}`,
/// so the browser tracks partitions as separate storage units. (Note:
/// `Cellar.wipePartition` currently clears records via `deletePrefix('')`
/// rather than `indexedDB.deleteDatabase` — same end state, done through
/// the backend interface.)
///
/// `osManaged` is accepted for API uniformity with native but is a no-op
/// on web — IndexedDB quota is origin-wide, not per-DB.
/// `osBackup` is also a no-op on web — there's no iCloud/Time Machine
/// equivalent for IndexedDB.
Future<StorageBackend> initBackendForPartition({
  required String name,
  required String partition,
  required bool osManaged,
  bool osBackup = true,
  StorageRoots? roots,
}) async {
  return IndexedDbBackend(dbName: '${name}__$partition');
}

/// Return a platform-default [StorageBackend] suitable for consumers
/// that need a bare local backend with no partitions — e.g. as the
/// local-cache layer of a custom remote-backend composition.
///
/// On web this is an [IndexedDbBackend] named [name].
Future<StorageBackend> initDefaultBackend({
  required String name,
  StorageRoots? roots,
}) async {
  return IndexedDbBackend(dbName: name);
}
