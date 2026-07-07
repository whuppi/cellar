import 'dart:typed_data';

import 'package:cellar/cellar_lowlevel.dart';

/// In-memory [StorageBackend] for tests. No disk, no IndexedDB.
///
/// Implements the full StorageBackend contract. `materialize` throws —
/// in-memory has no filesystem, so use a real FileSystemBackend in tests
/// that exercise materialize.
class InMemoryBackend with DisposeGuard implements StorageBackend {
  final Map<String, Uint8List> _data = {};
  final Map<String, Map<String, String>> _metadata = {};
  final Map<String, String?> _contentType = {};
  final Map<String, DateTime> _lastModified = {};

  @override
  String get disposeLabel => 'InMemoryBackend';

  /// Test hook: total bytes currently stored.
  int get totalBytes => _data.values.fold(0, (a, b) => a + b.length);

  /// Test hook: number of objects currently stored.
  int get objectCount => _data.length;

  /// Test hook: set the lastModified timestamp for an existing key.
  /// Used to simulate aged objects in lifecycle tests.
  void setLastModified(String key, DateTime when) {
    if (_data.containsKey(key)) _lastModified[key] = when.toUtc();
  }

  @override
  Future<void> write(
    String key,
    Uint8List bytes, [
    WriteOptions options = const WriteOptions(),
  ]) async {
    checkNotDisposed();
    _data[key] = Uint8List.fromList(bytes);
    _contentType[key] = options.contentType;
    _metadata[key] = Map.of(options.metadata);
    _lastModified[key] = DateTime.now().toUtc();
  }

  @override
  Future<void> writeStream(
    String key,
    Stream<List<int>> byteStream, [
    WriteOptions options = const WriteOptions(),
  ]) async {
    checkNotDisposed();
    final builder = BytesBuilder();
    await for (final chunk in byteStream) {
      builder.add(chunk);
    }
    await write(key, builder.takeBytes(), options);
  }

  @override
  Future<Uint8List> read(String key) async {
    checkNotDisposed();
    final data = _data[key];
    if (data == null) throw FileNotFoundError(key);
    return Uint8List.fromList(data);
  }

  @override
  Stream<List<int>> readStream(String key) async* {
    checkNotDisposed();
    yield await read(key);
  }

  @override
  Future<Uint8List> readRange(
    String key, {
    required int start,
    required int length,
  }) async {
    checkNotDisposed();
    final data = await read(key);
    final end = (start + length).clamp(0, data.length);
    if (end <= start) return Uint8List(0);
    return Uint8List.sublistView(data, start, end);
  }

  @override
  Future<ObjectInfo?> head(String key) async {
    checkNotDisposed();
    final data = _data[key];
    if (data == null) return null;
    return ObjectInfo(
      key: key,
      size: data.length,
      contentType: _contentType[key],
      metadata: _metadata[key] ?? const {},
      lastModified: _lastModified[key]!,
    );
  }

  @override
  Future<bool> exists(String key) async {
    checkNotDisposed();
    return _data.containsKey(key);
  }

  @override
  Future<void> delete(String key) async {
    checkNotDisposed();
    _data.remove(key);
    _metadata.remove(key);
    _contentType.remove(key);
    _lastModified.remove(key);
  }

  @override
  Future<void> deletePrefix(String prefix) async {
    checkNotDisposed();
    final victims = _data.keys.where((k) => k.startsWith(prefix)).toList();
    for (final k in victims) {
      await delete(k);
    }
  }

  @override
  Future<List<ObjectInfo>> list(String prefix) async {
    checkNotDisposed();
    final results = <ObjectInfo>[];
    for (final key in _data.keys) {
      if (!key.startsWith(prefix)) continue;
      results.add((await head(key))!);
    }
    return results;
  }

  @override
  Future<void> copy(String sourceKey, String destKey) async {
    checkNotDisposed();
    final src = _data[sourceKey];
    if (src == null) throw FileNotFoundError(sourceKey);
    _data[destKey] = Uint8List.fromList(src);
    _contentType[destKey] = _contentType[sourceKey];
    _metadata[destKey] = Map.of(_metadata[sourceKey] ?? const {});
    _lastModified[destKey] = DateTime.now().toUtc();
  }

  @override
  Future<void> updateMetadata(
    String key, {
    String? contentType,
    Map<String, String> metadata = const {},
  }) async {
    checkNotDisposed();
    if (!_data.containsKey(key)) {
      throw FileNotFoundError(key);
    }
    _contentType[key] = contentType;
    _metadata[key] = Map.of(metadata);
    _lastModified[key] = DateTime.now().toUtc();
  }

  @override
  Future<MaterializedFile> materialize(
    String key, {
    bool decrypt = true,
    bool exclusive = false,
  }) {
    checkNotDisposed();
    throw UnsupportedError(
      'InMemoryBackend.materialize: in-memory has no filesystem. Use '
      'FileSystemBackend or wrap this in a backend that provides a real handle.',
    );
  }

  @override
  Future<void> dispose() async {
    markDisposed();
    _data.clear();
    _metadata.clear();
    _contentType.clear();
    _lastModified.clear();
  }
}
