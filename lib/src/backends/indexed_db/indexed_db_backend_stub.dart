// Stub for IndexedDbBackend on platforms without dart:js_interop
// (native VM tests, native production builds). Conditional imports
// resolve to the real implementation on web.
//
// The stub extends [ChunkedBackend] to match the real backend's
// type hierarchy — `backend is ChunkedBackend` returns the same answer
// on every platform. The constructor throws, so the stub is observable
// as "wrong platform" the moment you try to instantiate it; every
// method on it also throws.

import 'dart:typed_data';

import 'package:cellar/src/decorators/chunked/chunked_backend.dart';
import 'package:cellar/src/core/storage_backend.dart';
import 'package:cellar/src/core/materialized_file.dart';
import 'package:cellar/src/core/object_info.dart';
import 'package:cellar/src/core/write_options.dart';

/// Native stub for the web-only IndexedDB backend — constructor throws.
class IndexedDbBackend extends ChunkedBackend {
  /// Throws [UnsupportedError]: IndexedDB requires a browser.
  IndexedDbBackend({
    required String dbName,
    super.chunkSize = ChunkedBackend.defaultChunkSize,
  }) : super(backing: const _UnreachableBacking()) {
    throw UnsupportedError(
      'IndexedDbBackend("$dbName") requires dart:js_interop and is web-only. '
      'On native, construct a Cellar with the default constructor — it '
      'selects the correct backend automatically — or use FileSystemBackend '
      'directly from cellar_lowlevel.dart.',
    );
  }

  @override
  Future<MaterializedFile> materialize(
    String key, {
    bool decrypt = true,
    bool exclusive = false,
  }) => throw UnsupportedError('IndexedDbBackend is web-only.');

  @override
  Future<void> dispose() =>
      throw UnsupportedError('IndexedDbBackend is web-only.');
}

/// A StorageBackend that throws on every call. Exists solely to
/// satisfy the `ChunkedBackend(backing: ...)` requirement in
/// the stub's super-call; the stub's own constructor throws before any
/// method on this could be reached.
class _UnreachableBacking implements StorageBackend {
  const _UnreachableBacking();

  Never _unreachable() => throw StateError(
    'IndexedDbBackend stub backing should never be reached.',
  );

  @override
  Future<void> write(
    String key,
    Uint8List bytes, [
    WriteOptions options = const WriteOptions(),
  ]) => _unreachable();
  @override
  Future<void> writeStream(
    String key,
    Stream<List<int>> byteStream, [
    WriteOptions options = const WriteOptions(),
  ]) => _unreachable();
  @override
  Stream<List<int>> readStream(String key) => _unreachable();
  @override
  Future<Uint8List> read(String key) => _unreachable();
  @override
  Future<Uint8List> readRange(
    String key, {
    required int start,
    required int length,
  }) => _unreachable();
  @override
  Future<ObjectInfo?> head(String key) => _unreachable();
  @override
  Future<bool> exists(String key) => _unreachable();
  @override
  Future<void> delete(String key) => _unreachable();
  @override
  Future<void> deletePrefix(String prefix) => _unreachable();
  @override
  Future<List<ObjectInfo>> list(String prefix) => _unreachable();
  @override
  Future<void> copy(String sourceKey, String destKey) => _unreachable();
  @override
  Future<void> updateMetadata(
    String key, {
    String? contentType,
    Map<String, String> metadata = const {},
  }) => _unreachable();
  @override
  Future<MaterializedFile> materialize(
    String key, {
    bool decrypt = true,
    bool exclusive = false,
  }) => _unreachable();
  @override
  Future<void> dispose() => _unreachable();
}
