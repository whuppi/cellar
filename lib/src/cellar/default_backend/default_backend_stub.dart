import 'package:cellar/src/cellar/storage_roots.dart';
import 'package:cellar/src/core/storage_backend.dart';

/// Stub — should never be reached. Conditional imports resolve to
/// native or web before this is used.
Future<StorageBackend> initBackendForPartition({
  required String name,
  required String partition,
  required bool osManaged,
  bool osBackup = true,
  StorageRoots? roots,
}) {
  throw UnsupportedError('Platform not supported');
}

/// Fallback stub — throws on platforms with neither `dart:io` nor
/// `dart:js_interop`.
Future<StorageBackend> initDefaultBackend({
  required String name,
  StorageRoots? roots,
}) {
  throw UnsupportedError('Platform not supported');
}
