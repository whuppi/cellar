import 'dart:typed_data';

import 'package:cellar/src/core/storage_backend.dart';
import 'package:cellar/src/core/dispose_guard.dart';
import 'package:cellar/src/core/materialized_file.dart';
import 'package:cellar/src/core/object_info.dart';
import 'package:cellar/src/core/write_options.dart';
import 'package:cellar/src/core/errors.dart';

/// Generic chunked storage layer.
///
/// Wraps a backing [StorageBackend] (any platform — local files,
/// IndexedDB, a remote store, in-memory) and stores each logical key as N+1
/// records, with the chunk records tagged by a write generation:
///
/// ```
/// {key}__manifest      → { generation, chunkCount, totalSize,
///                          contentType, metadata }
/// {key}__g{G}__c0      → { body: Uint8List (≤ chunkSize) }
/// {key}__g{G}__c1      → { body: Uint8List (≤ chunkSize) }
/// ...
/// {key}__g{G}__c{N-1}  → { body: Uint8List (≤ chunkSize) }
/// ```
///
/// The chunking algorithm lives here; the storage primitives live in
/// the backing backend. This separation keeps the algorithm
/// platform-independent (testable on any VM) and means individual
/// backends don't reinvent it.
///
/// ## What this layer guarantees
///
/// - `writeStream` is true streaming — buffers one [chunkSize]
///   chunk at a time, flushes, then writes the manifest LAST.
/// - `readStream` yields chunk-by-chunk — O(chunkSize) memory.
/// - `head`/`exists`/`list` use the manifest only — no body reads.
/// - `readRange` decodes only the chunks that overlap the requested
///   range.
/// - A crash mid-FIRST-write leaves the manifest absent →
///   `head`/`exists`/`list`/`read` all behave as if the key never
///   existed.
/// - A crash (or stream failure) mid-OVERWRITE leaves the previous
///   object fully intact: each write lands its chunks under a fresh
///   generation, swaps the manifest last, and only then reclaims the
///   previous generation's chunks. Without generations, an overwrite
///   would clobber the old chunk records in place and a mid-write
///   failure would serve a torn mix of old and new bytes.
/// - Orphaned chunks from a failed write share the generation number
///   the NEXT write of that key will use, so they're overwritten and
///   reclaimed naturally; a failed first write is reaped by the
///   defensive sweep in `delete`/`deletePrefix`.
///
/// ## Atomicity caveats
///
/// The backing backend is not assumed to provide multi-key
/// transactions. Two callers writing to the SAME key concurrently can
/// interleave each other's chunk writes; that's a caller-side
/// serialization concern (the [StorageBackend] interface already
/// notes this on every backend).
///
/// ## materialize
///
/// Not implemented at this layer because how to materialize an
/// arbitrarily-large object as a platform-local handle is
/// platform-specific (filesystem path on native, Blob URL on web).
/// Subclasses or wrapping decorators provide it.
class ChunkedBackend with DisposeGuard implements StorageBackend {
  /// Wrap [backing], splitting every object into [chunkSize]-byte records.
  ChunkedBackend({
    required StorageBackend backing,
    this.chunkSize = defaultChunkSize,
  }) : _backing = backing;

  /// Default chunk size — 64 KiB.
  ///
  /// Picked to balance three things on web (the most constrained
  /// backend): IndexedDB record overhead per write, JS heap pressure
  /// per chunk in flight, and the typical encryption chunk size used
  /// by streaming AEAD constructions (which lets a chunked-then-
  /// encrypted pipeline align without re-buffering). Override via the
  /// constructor for workloads with different trade-offs.
  static const int defaultChunkSize = 64 * 1024;

  /// Suffix for the per-key manifest record. Distinct from the chunk
  /// markers, short, obvious in any storage browser.
  static const String manifestSuffix = '__manifest';

  /// Generation marker in a chunk record's key. The write generation
  /// follows it; `__c{index}` follows the generation.
  static const String generationPrefix = '__g';

  /// Per-chunk record marker. The chunk index follows it.
  static const String chunkPrefix = '__c';

  /// Manifest-metadata keys this layer maintains. Constants because the
  /// writer and the decoder must never drift.
  static const String _metaGeneration = 'generation';
  static const String _metaChunkCount = 'chunkCount';
  static const String _metaTotalSize = 'totalSize';

  final StorageBackend _backing;

  /// Plaintext bytes per chunk record.
  final int chunkSize;

  /// The backing backend — exposed for subclasses that need to add
  /// platform-specific operations (e.g. [materialize]) on top.
  StorageBackend get backing => _backing;

  /// The manifest for [key], or null when the object doesn't exist.
  /// For subclasses whose [materialize] reads chunk records directly.
  Future<ChunkedManifest?> manifestFor(String key) => _readManifest(key);

  /// The backing-record key of chunk [index] in [generation] of [key].
  /// For subclasses whose [materialize] reads chunk records directly —
  /// pair with [manifestFor] to get the current generation.
  String chunkKeyFor(String key, int generation, int index) =>
      '$key$generationPrefix$generation$chunkPrefix$index';

  // Internal record key builders.
  String _manifestKey(String key) => '$key$manifestSuffix';

  // ══════════════════════════════════════════════════════════════════════
  // WRITE
  // ══════════════════════════════════════════════════════════════════════

  @override
  Future<void> write(
    String key,
    Uint8List bytes, [
    WriteOptions options = const WriteOptions(),
  ]) async {
    checkNotDisposed();
    final previous = await _readManifest(key);
    // No manifest can still mean orphaned chunks from a failed first
    // write — they'd share generation 0 with this write, and a shorter
    // object would leave their tail behind forever. Chunks are written
    // sequentially, so any such orphans include chunk 0: one point
    // lookup gates the sweep instead of a prefix scan on every fresh
    // write.
    if (previous == null && await _backing.exists(chunkKeyFor(key, 0, 0))) {
      await _backing.deletePrefix('$key$generationPrefix');
    }
    final generation = (previous?.generation ?? -1) + 1;
    final chunkCount = await _writeChunksFromBytes(key, generation, bytes);
    await _writeManifest(
      key,
      generation: generation,
      chunkCount: chunkCount,
      totalSize: bytes.length,
      contentType: options.contentType,
      metadata: options.metadata,
    );
    await _deleteGeneration(key, previous);
  }

  @override
  Future<void> writeStream(
    String key,
    Stream<List<int>> byteStream, [
    WriteOptions options = const WriteOptions(),
  ]) async {
    checkNotDisposed();
    final previous = await _readManifest(key);
    // Same failed-first-write sweep as [write].
    if (previous == null && await _backing.exists(chunkKeyFor(key, 0, 0))) {
      await _backing.deletePrefix('$key$generationPrefix');
    }
    final generation = (previous?.generation ?? -1) + 1;
    var index = 0;
    var totalSize = 0;
    final buffer = BytesBuilder(copy: false);

    Future<void> flush() async {
      if (buffer.isEmpty) return;
      final chunk = buffer.takeBytes();
      await _putChunk(key, generation, index, chunk);
      index++;
    }

    await for (final chunk in byteStream) {
      var offset = 0;
      while (offset < chunk.length) {
        final remaining = chunkSize - buffer.length;
        final take = (chunk.length - offset) < remaining
            ? chunk.length - offset
            : remaining;
        buffer.add(chunk.sublist(offset, offset + take));
        offset += take;
        totalSize += take;
        if (buffer.length == chunkSize) await flush();
      }
      // Logical-bytes progress, once per source chunk. _putChunk builds
      // its own per-record options, so the backing never double-reports.
      options.onProgress?.call(totalSize, null);
    }
    await flush(); // final partial chunk (may be empty for empty input)

    await _writeManifest(
      key,
      generation: generation,
      chunkCount: index,
      totalSize: totalSize,
      contentType: options.contentType,
      metadata: options.metadata,
    );
    await _deleteGeneration(key, previous);
  }

  Future<int> _writeChunksFromBytes(
    String key,
    int generation,
    Uint8List bytes,
  ) async {
    if (bytes.isEmpty) return 0;
    var i = 0;
    var offset = 0;
    while (offset < bytes.length) {
      final end = (offset + chunkSize) > bytes.length
          ? bytes.length
          : offset + chunkSize;
      await _putChunk(
        key,
        generation,
        i,
        Uint8List.sublistView(bytes, offset, end),
      );
      i++;
      offset = end;
    }
    return i;
  }

  // ══════════════════════════════════════════════════════════════════════
  // READ
  // ══════════════════════════════════════════════════════════════════════

  @override
  Future<Uint8List> read(String key) async {
    checkNotDisposed();
    final manifest = await _readManifest(key);
    if (manifest == null) throw FileNotFoundError(key);
    final builder = BytesBuilder(copy: false);
    for (var i = 0; i < manifest.chunkCount; i++) {
      builder.add(await _readChunk(key, manifest.generation, i));
    }
    return builder.takeBytes();
  }

  @override
  Stream<List<int>> readStream(String key) async* {
    checkNotDisposed();
    final manifest = await _readManifest(key);
    if (manifest == null) throw FileNotFoundError(key);
    for (var i = 0; i < manifest.chunkCount; i++) {
      yield await _readChunk(key, manifest.generation, i);
    }
  }

  @override
  Future<Uint8List> readRange(
    String key, {
    required int start,
    required int length,
  }) async {
    checkNotDisposed();
    final manifest = await _readManifest(key);
    if (manifest == null) throw FileNotFoundError(key);

    final end = (start + length).clamp(0, manifest.totalSize);
    if (end <= start) return Uint8List(0);

    final firstChunk = start ~/ chunkSize;
    final lastChunk = (end - 1) ~/ chunkSize;

    final builder = BytesBuilder(copy: false);
    for (var i = firstChunk; i <= lastChunk; i++) {
      final chunk = await _readChunk(key, manifest.generation, i);
      final chunkStart = i * chunkSize;
      final sliceStart = (start > chunkStart) ? start - chunkStart : 0;
      final sliceEnd = (end < chunkStart + chunk.length)
          ? end - chunkStart
          : chunk.length;
      builder.add(chunk.sublist(sliceStart, sliceEnd));
    }
    return builder.takeBytes();
  }

  // ══════════════════════════════════════════════════════════════════════
  // METADATA
  // ══════════════════════════════════════════════════════════════════════

  @override
  Future<ObjectInfo?> head(String key) async {
    checkNotDisposed();
    final manifest = await _readManifest(key);
    if (manifest == null) return null;
    return ObjectInfo(
      key: key,
      size: manifest.totalSize,
      contentType: manifest.contentType,
      metadata: manifest.metadata,
      lastModified: manifest.lastModified,
    );
  }

  @override
  Future<bool> exists(String key) {
    checkNotDisposed();
    return _backing.exists(_manifestKey(key));
  }

  // ══════════════════════════════════════════════════════════════════════
  // DELETE
  // ══════════════════════════════════════════════════════════════════════

  @override
  Future<void> delete(String key) async {
    checkNotDisposed();
    final manifest = await _readManifest(key);
    if (manifest != null) {
      // Fast path: manifest tells us exactly which chunks exist.
      await _deleteGeneration(key, manifest);
    } else {
      // Defensive sweep: no manifest, but orphaned chunks (from a failed
      // first write) might exist under any generation.
      await _backing.deletePrefix('$key$generationPrefix');
    }
    await _backing.delete(_manifestKey(key));
  }

  /// Reclaim the chunks of a superseded (or deleted) generation. Called
  /// after the manifest swap, so a failure here can only leave orphans —
  /// never a torn object — and the next write of the same key reuses and
  /// overwrites the orphaned generation number anyway.
  Future<void> _deleteGeneration(String key, ChunkedManifest? manifest) async {
    if (manifest == null) return;
    for (var i = 0; i < manifest.chunkCount; i++) {
      await _backing.delete(chunkKeyFor(key, manifest.generation, i));
    }
  }

  @override
  Future<void> deletePrefix(String prefix) async {
    checkNotDisposed();
    // Nuke EVERY backing record under the prefix — manifests AND chunks.
    await _backing.deletePrefix(prefix);
  }

  // ══════════════════════════════════════════════════════════════════════
  // LIST
  // ══════════════════════════════════════════════════════════════════════

  @override
  Future<List<ObjectInfo>> list(String prefix) async {
    checkNotDisposed();
    final all = await _backing.list(prefix);
    final results = <ObjectInfo>[];
    for (final info in all) {
      // Only manifest records contribute; chunks are skipped.
      if (!info.key.endsWith(manifestSuffix)) continue;
      final logicalKey = info.key.substring(
        0,
        info.key.length - manifestSuffix.length,
      );
      final manifest = await _readManifest(logicalKey);
      if (manifest == null) continue; // race with delete
      results.add(
        ObjectInfo(
          key: logicalKey,
          size: manifest.totalSize,
          contentType: manifest.contentType,
          metadata: manifest.metadata,
          lastModified: info.lastModified,
        ),
      );
    }
    return results;
  }

  // ══════════════════════════════════════════════════════════════════════
  // COPY
  // ══════════════════════════════════════════════════════════════════════

  @override
  Future<void> copy(String sourceKey, String destKey) async {
    checkNotDisposed();
    final manifest = await _readManifest(sourceKey);
    if (manifest == null) throw FileNotFoundError(sourceKey);

    final destPrevious = await _readManifest(destKey);
    final destGeneration = (destPrevious?.generation ?? -1) + 1;
    for (var i = 0; i < manifest.chunkCount; i++) {
      final chunk = await _readChunk(sourceKey, manifest.generation, i);
      await _putChunk(destKey, destGeneration, i, chunk);
    }
    await _writeManifest(
      destKey,
      generation: destGeneration,
      chunkCount: manifest.chunkCount,
      totalSize: manifest.totalSize,
      contentType: manifest.contentType,
      metadata: manifest.metadata,
    );
    await _deleteGeneration(destKey, destPrevious);
  }

  // ══════════════════════════════════════════════════════════════════════
  // METADATA UPDATE
  // ══════════════════════════════════════════════════════════════════════

  @override
  Future<void> updateMetadata(
    String key, {
    String? contentType,
    Map<String, String> metadata = const {},
  }) async {
    checkNotDisposed();
    final manifest = await _readManifest(key);
    if (manifest == null) throw FileNotFoundError(key);
    await _writeManifest(
      key,
      generation: manifest.generation,
      chunkCount: manifest.chunkCount,
      totalSize: manifest.totalSize,
      contentType: contentType,
      metadata: metadata,
    );
  }

  // ══════════════════════════════════════════════════════════════════════
  // MATERIALIZE — platform-specific, must be provided by subclass
  // ══════════════════════════════════════════════════════════════════════

  @override
  Future<MaterializedFile> materialize(
    String key, {
    bool decrypt = true,
    bool exclusive = false,
  }) {
    checkNotDisposed();
    throw UnimplementedError(
      'ChunkedBackend does not implement materialize directly. '
      'Subclass it with a platform-specific materialize (Blob URL on '
      'web, file path on native) or wrap it in a decorator.',
    );
  }

  // ══════════════════════════════════════════════════════════════════════
  // INTERNAL — chunk + manifest record I/O via the backing adapter
  // ══════════════════════════════════════════════════════════════════════

  Future<void> _putChunk(
    String key,
    int generation,
    int index,
    Uint8List bytes,
  ) => _backing.write(chunkKeyFor(key, generation, index), bytes);

  Future<Uint8List> _readChunk(String key, int generation, int index) async {
    try {
      return await _backing.read(chunkKeyFor(key, generation, index));
    } on FileNotFoundError {
      throw CorruptedFileError(
        key,
        cause: 'Missing chunk $index referenced by manifest',
      );
    }
  }

  Future<void> _writeManifest(
    String key, {
    required int generation,
    required int chunkCount,
    required int totalSize,
    String? contentType,
    Map<String, String> metadata = const {},
  }) async {
    // Manifest is encoded into the metadata of an empty backing record.
    // Backings store metadata via WriteOptions — same path everything else
    // already goes through. Reading is symmetric: head() returns the
    // metadata back out.
    await _backing.write(
      _manifestKey(key),
      Uint8List(0),
      WriteOptions(
        contentType: contentType,
        metadata: {
          _metaGeneration: '$generation',
          _metaChunkCount: '$chunkCount',
          _metaTotalSize: '$totalSize',
          ...metadata,
        },
      ),
    );
  }

  Future<ChunkedManifest?> _readManifest(String key) async {
    final info = await _backing.head(_manifestKey(key));
    if (info == null) return null;
    return _decodeManifest(info);
  }

  ChunkedManifest _decodeManifest(ObjectInfo info) {
    final raw = info.metadata;
    final generation = int.tryParse(raw[_metaGeneration] ?? '') ?? 0;
    final chunkCount = int.tryParse(raw[_metaChunkCount] ?? '') ?? 0;
    final totalSize = int.tryParse(raw[_metaTotalSize] ?? '') ?? 0;
    final userMeta = Map<String, String>.from(raw)
      ..remove(_metaGeneration)
      ..remove(_metaChunkCount)
      ..remove(_metaTotalSize);
    return ChunkedManifest(
      generation: generation,
      chunkCount: chunkCount,
      totalSize: totalSize,
      contentType: info.contentType,
      metadata: userMeta,
      lastModified: info.lastModified,
    );
  }

  // ── Lifecycle ──

  @override
  String get disposeLabel => 'ChunkedBackend';

  @override
  Future<void> dispose() async {
    // Ownership rule: the backing backend is caller-provided, so its
    // creator disposes it — this layer only arms its own guard.
    markDisposed();
  }
}

/// In-memory representation of a manifest record.
class ChunkedManifest {
  /// In-memory decode of one manifest record.
  const ChunkedManifest({
    required this.generation,
    required this.chunkCount,
    required this.totalSize,
    required this.contentType,
    required this.metadata,
    required this.lastModified,
  });

  /// Write generation whose chunk records this manifest points at. Each
  /// overwrite bumps it, so an in-flight write never touches the records
  /// a reader may be following.
  final int generation;

  /// Number of chunk records in [generation].
  final int chunkCount;

  /// Logical object size in bytes (the sum of all chunks).
  final int totalSize;

  /// Stored content type, if any.
  final String? contentType;

  /// User metadata (the manifest's own bookkeeping keys stripped).
  final Map<String, String> metadata;

  /// The manifest record's own timestamp — when the object last changed.
  final DateTime lastModified;
}
