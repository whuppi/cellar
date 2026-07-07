import 'dart:typed_data';

import 'package:cellar/cellar_lowlevel.dart';

/// A [StorageBackend] decorator that forwards every call to [inner].
///
/// The base class for test observers: subclass and override just the
/// methods you need to count, fail, delay, or record. Keeps each test's
/// instrumentation to a few lines instead of 13 boilerplate overrides.
class ForwardingBackend implements StorageBackend {
  ForwardingBackend(this.inner);

  /// The backend every call is forwarded to.
  final StorageBackend inner;

  @override
  Future<void> write(
    String key,
    Uint8List bytes, [
    WriteOptions options = const WriteOptions(),
  ]) => inner.write(key, bytes, options);

  @override
  Future<void> writeStream(
    String key,
    Stream<List<int>> byteStream, [
    WriteOptions options = const WriteOptions(),
  ]) => inner.writeStream(key, byteStream, options);

  @override
  Stream<List<int>> readStream(String key) => inner.readStream(key);

  @override
  Future<Uint8List> read(String key) => inner.read(key);

  @override
  Future<Uint8List> readRange(
    String key, {
    required int start,
    required int length,
  }) => inner.readRange(key, start: start, length: length);

  @override
  Future<ObjectInfo?> head(String key) => inner.head(key);

  @override
  Future<bool> exists(String key) => inner.exists(key);

  @override
  Future<void> delete(String key) => inner.delete(key);

  @override
  Future<void> deletePrefix(String prefix) => inner.deletePrefix(prefix);

  @override
  Future<List<ObjectInfo>> list(String prefix) => inner.list(prefix);

  @override
  Future<void> copy(String sourceKey, String destKey) =>
      inner.copy(sourceKey, destKey);

  @override
  Future<void> updateMetadata(
    String key, {
    String? contentType,
    Map<String, String> metadata = const {},
  }) => inner.updateMetadata(key, contentType: contentType, metadata: metadata);

  @override
  Future<MaterializedFile> materialize(
    String key, {
    bool decrypt = true,
    bool exclusive = false,
  }) => inner.materialize(key, decrypt: decrypt, exclusive: exclusive);

  @override
  Future<void> dispose() => inner.dispose();
}
