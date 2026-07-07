// Stub for FileSystemBackend on platforms without dart:io (web).
// Conditional imports resolve to the real implementation on native.

import 'package:cellar/src/core/dispose_guard.dart';
import 'package:cellar/src/core/storage_backend.dart';
import 'package:cellar/src/core/materialized_file.dart';
import 'package:cellar/src/core/object_info.dart';
import 'package:cellar/src/core/write_options.dart';
import 'dart:typed_data';

/// Web stub for the native-only filesystem backend — constructor throws.
///
/// Mirrors the io variant's CROSS-PLATFORM public surface (statics
/// included) so code compiled for both targets analyzes against one
/// shape — the analyzer resolves conditional exports through this
/// default branch. The one deliberate gap: the native constructor's
/// `os:` seam parameter (its types are dart:io-typed and cannot compile
/// here); white-box tests of the native impl import it directly.
class FileSystemBackend with DisposeGuard implements StorageBackend {
  /// Throws [UnsupportedError]: the filesystem requires `dart:io`.
  FileSystemBackend(String baseDir, {bool osBackup = true}) {
    throw UnsupportedError(
      'FileSystemBackend($baseDir, osBackup: $osBackup) requires dart:io and is '
      'not available on web.',
    );
  }

  /// Mirrors the io variant's constant — see it for semantics.
  static const String tombstoneSuffix = '.cellar_tombstone.';

  /// Mirrors the io variant's constant — see it for semantics.
  static const String writeTempSuffix = '.cellar_write.';

  @override
  String get disposeLabel => 'FileSystemBackend';

  /// Throws [UnsupportedError] — see the io variant.
  Future<void> sweepTombstones() async {
    throw UnsupportedError('stub');
  }

  @override
  Future<void> write(
    String key,
    Uint8List bytes, [
    WriteOptions options = const WriteOptions(),
  ]) => throw UnsupportedError('stub');
  @override
  Future<void> writeStream(
    String key,
    Stream<List<int>> byteStream, [
    WriteOptions options = const WriteOptions(),
  ]) => throw UnsupportedError('stub');
  @override
  Stream<List<int>> readStream(String key) => throw UnsupportedError('stub');
  @override
  Future<Uint8List> read(String key) => throw UnsupportedError('stub');
  @override
  Future<Uint8List> readRange(
    String key, {
    required int start,
    required int length,
  }) => throw UnsupportedError('stub');
  @override
  Future<ObjectInfo?> head(String key) => throw UnsupportedError('stub');
  @override
  Future<bool> exists(String key) => throw UnsupportedError('stub');
  @override
  Future<void> delete(String key) => throw UnsupportedError('stub');
  @override
  Future<void> deletePrefix(String prefix) => throw UnsupportedError('stub');
  @override
  Future<List<ObjectInfo>> list(String prefix) =>
      throw UnsupportedError('stub');
  @override
  Future<void> copy(String sourceKey, String destKey) =>
      throw UnsupportedError('stub');
  @override
  Future<void> updateMetadata(
    String key, {
    String? contentType,
    Map<String, String> metadata = const {},
  }) => throw UnsupportedError('stub');
  @override
  Future<MaterializedFile> materialize(
    String key, {
    bool decrypt = true,
    bool exclusive = false,
  }) => throw UnsupportedError('stub');
  @override
  Future<void> dispose() => throw UnsupportedError('stub');
}
