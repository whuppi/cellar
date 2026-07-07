import 'dart:async';
import 'dart:typed_data';

import 'package:cellar/src/decorators/encrypted/file_encryptor.dart';
import 'package:cellar/src/decorators/encrypted/encryption_key_resolver.dart';
import 'package:cellar/src/core/errors.dart';
import 'package:cellar/src/core/storage_backend.dart';
import 'package:cellar/src/core/dispose_guard.dart';
import 'package:cellar/src/core/materialized_file.dart';
import 'package:cellar/src/core/object_info.dart';
import 'package:cellar/src/core/write_options.dart';

/// Transparent encryption decorator for [StorageBackend].
///
/// Wraps any backend. Per-write encryption decisions come from
/// [WriteOptions]:
/// - `encrypt: true` → encrypt (fails if no key resolves)
/// - `encrypt: false` → plaintext passthrough
/// - `encrypt: null` → fall back to [encryptByDefault]
///
/// The decorator never inspects the key string to decide encryption —
/// the caller is in charge.
///
/// ## Read behavior
///
/// Reads auto-detect encrypted bytes by checking the magic header. No
/// WriteOptions needed at read time; the file format is self-describing.
///
/// ## Streaming
///
/// Write and read paths are truly streaming. Memory is O(chunkSize),
/// not O(fileSize). Safe for arbitrarily large files.
//
// DESIGN NOTES.
//
// 1. writeStream patches metadata AFTER the stream completes. During
//    streaming encrypt, the original (plaintext) size isn't known
//    until every chunk has been processed. The file header gets a
//    provisional originalSize=0; once the stream finishes,
//    updateMetadata writes the real size into the sidecar. readStream
//    checks both header and sidecar, preferring sidecar when the
//    header shows 0. Not a hack — it's how streaming encryption works
//    when total size isn't known upfront.
//
// 2. Reads auto-detect encryption via magic header bytes, not via
//    metadata. So a file encrypted on one backend is readable on any
//    other backend that returns the same bytes — no external state
//    needed to decide "is this encrypted." The sidecar is
//    supplementary (carries originalSize for streamed writes); it is
//    not authoritative for the encrypted/plaintext decision.
//
// 3. copy() re-encrypts when source and destination resolve to
//    different encryption keys (cross-tenant copies, key rotation).
//    Same-key copies fall through to a raw byte copy.
class EncryptedBackend with DisposeGuard implements StorageBackend {
  /// Wrap [inner] with transparent encryption via [encryptor], resolving
  /// per-object keys through [keyResolver] (or explicit per-write keys).
  EncryptedBackend({
    required StorageBackend inner,
    required FileEncryptor encryptor,
    EncryptionKeyResolver? keyResolver,
    StorageBackend? decryptCache,
    this.encryptByDefault = true,
  }) : _inner = inner,
       _encryptor = encryptor,
       _keyResolver = keyResolver,
       _decryptCache = decryptCache;

  /// Reserved marker for one-shot plaintext temps written by [materialize].
  /// Keys containing this marker are hidden from [list] and swept on the
  /// first materialize after a crash — do not use it in your own key names
  /// (same reservation idea as ChunkedBackend's `__manifest` suffix).
  static const String decryptTempMarker = '.__decrypted.';

  /// Marker separating the escaped object key from the version tag in
  /// reusable decrypt-cache entries.
  static const String _cacheEntryMarker = '.dec.';

  /// Sidecar-metadata keys this decorator maintains. Constants because a
  /// typo in one of the ten-plus sites would silently break encryption
  /// detection or size reporting.
  static const String _metaEncrypted = 'encrypted';
  static const String _metaOriginalSize = 'originalSize';

  /// Monotonic disambiguator so concurrent fresh decrypts of the same key
  /// in the same microsecond never collide.
  static int _freshCounter = 0;

  final StorageBackend _inner;
  final FileEncryptor _encryptor;
  final EncryptionKeyResolver? _keyResolver;

  /// In-flight decrypt-cache fills keyed by cache key. Concurrent
  /// materialize calls for the same object version share one decrypt
  /// instead of racing writes to the same cache entry (a torn read for
  /// whoever materializes the half-written entry).
  final Map<String, Future<void>> _cacheFills = {};

  /// Memoized crash-leftover sweep — see [_sweepDecryptTemps].
  Future<void>? _tempSweep;

  /// Optional cache for decrypted plaintext. When provided,
  /// [materialize] with `decrypt: true, exclusive: false` writes the
  /// decrypted bytes here keyed by `{key}+{mtime}` so repeated calls
  /// for the same file version reuse the cached entry (no re-decrypt).
  /// When null, every materialize call decrypts fresh into a temp
  /// via the inner backend.
  ///
  /// The cache is itself a [StorageBackend] — typically a
  /// `FileSystemBackend` rooted at a cache directory on native, or a
  /// dedicated `IndexedDbBackend` database on web.
  final StorageBackend? _decryptCache;

  /// Default encryption policy when [WriteOptions.encrypt] is null.
  final bool encryptByDefault;

  // ── Write ──

  @override
  Future<void> write(
    String key,
    Uint8List bytes, [
    WriteOptions options = const WriteOptions(),
  ]) async {
    checkNotDisposed();
    final shouldEncrypt = options.encrypt ?? encryptByDefault;

    if (!shouldEncrypt) {
      return _inner.write(key, bytes, options);
    }

    final encKey = await _resolveKey(key, options);
    final encrypted = await _encryptor.encryptBytes(bytes, encKey);

    final encOptions = WriteOptions(
      contentType: options.contentType,
      metadata: {
        ...options.metadata,
        _metaEncrypted: 'true',
        _metaOriginalSize: bytes.length.toString(),
      },
    );
    return _inner.write(key, encrypted, encOptions);
  }

  @override
  Future<void> writeStream(
    String key,
    Stream<List<int>> byteStream, [
    WriteOptions options = const WriteOptions(),
  ]) async {
    checkNotDisposed();
    final shouldEncrypt = options.encrypt ?? encryptByDefault;

    if (!shouldEncrypt) {
      return _inner.writeStream(key, byteStream, options);
    }

    final encKey = await _resolveKey(key, options);

    // True streaming encrypt — per-chunk MACs, never buffers whole file.
    // Track original plaintext size by counting input bytes BEFORE encryption.
    // Progress is reported here, in plaintext space — the inner backend
    // only sees ciphertext counts (header + MAC overhead), which would
    // skew a progress bar sized to the source.
    var totalPlainSize = 0;
    final countingStream = byteStream.map((chunk) {
      totalPlainSize += chunk.length;
      options.onProgress?.call(totalPlainSize, null);
      return chunk;
    });

    final encryptedStream = _encryptor.encryptStream(countingStream, encKey);

    // Write encrypted stream to the inner backend.
    // Initial metadata has _metaEncrypted flag but not originalSize
    // (we don't know it yet — the stream hasn't been fully consumed).
    // onProgress is deliberately absent: the counting stream above
    // already reports it in plaintext space.
    final encOptions = WriteOptions(
      contentType: options.contentType,
      metadata: {...options.metadata, _metaEncrypted: 'true'},
    );

    await _inner.writeStream(key, encryptedStream, encOptions);

    // Stream is fully consumed now — totalPlainSize is final.
    // Patch the sidecar metadata with the correct originalSize.
    // updateMetadata only touches the .meta.json sidecar (native)
    // or the metadata fields of the IndexedDB record (web).
    // It does NOT re-read or re-write the file bytes.
    await _inner.updateMetadata(
      key,
      contentType: options.contentType,
      metadata: {
        ...options.metadata,
        _metaEncrypted: 'true',
        _metaOriginalSize: totalPlainSize.toString(),
      },
    );
  }

  // ── Read ──

  @override
  Future<Uint8List> read(String key) async {
    checkNotDisposed();
    final raw = await _inner.read(key);
    if (!_encryptor.isEncrypted(raw)) return raw;

    final encKey = await _keyResolver?.resolveKey(key);
    // The object is encrypted but no key resolved. Returning the ciphertext
    // here would hand a caller raw encrypted bytes as if they were plaintext —
    // a silent data-integrity hole. Fail loudly instead.
    if (encKey == null) throw EncryptionKeyMissingError(key);

    // A streaming write leaves a provisional header (originalSize == 0); the
    // true size lives in the sidecar. decryptBytes trusts only the header, so
    // for provisional headers decrypt via the streaming path — it reconciles
    // the size from metadata the way readRange/readStream do. Skipping this
    // returns an empty result for every streaming-written (or copied) object.
    if (_encryptor.parseHeader(raw).originalSize > 0) {
      return _encryptor.decryptBytes(raw, encKey);
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in readStream(key)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  @override
  Stream<List<int>> readStream(String key) async* {
    checkNotDisposed();
    final info = await _inner.head(key);
    if (info == null) throw FileNotFoundError(key);

    if (info.metadata[_metaEncrypted] != 'true') {
      yield* _inner.readStream(key);
      return;
    }

    final encKey = await _keyResolver?.resolveKey(key);
    if (encKey == null) throw EncryptionKeyMissingError(key);

    final g = await _resolveGeometry(key, info);
    if (g.chunkCount == 0 || g.originalSize == 0) return;

    // Stream decrypt chunk by chunk
    for (var i = 0; i < g.chunkCount; i++) {
      final isLastChunk = i == g.chunkCount - 1;
      final dataSize = isLastChunk
          ? g.originalSize - (i * g.chunkSize)
          : g.chunkSize;
      final chunkTotalSize = dataSize + _encryptor.chunkMacSize;
      final chunkStart =
          g.headerSize + (i * (g.chunkSize + _encryptor.chunkMacSize));

      final chunkData = await _inner.readRange(
        key,
        start: chunkStart,
        length: chunkTotalSize,
      );

      yield await _encryptor.decryptChunk(chunkData, encKey, g.nonce, i);
    }
  }

  @override
  Future<Uint8List> readRange(
    String key, {
    required int start,
    required int length,
  }) async {
    checkNotDisposed();
    final info = await _inner.head(key);
    if (info == null) throw FileNotFoundError(key);

    if (info.metadata[_metaEncrypted] != 'true') {
      return _inner.readRange(key, start: start, length: length);
    }

    final encKey = await _keyResolver?.resolveKey(key);
    if (encKey == null) throw EncryptionKeyMissingError(key);

    final g = await _resolveGeometry(key, info);

    // Chunk-aware range read — only decrypt overlapping chunks
    final firstChunk = start ~/ g.chunkSize;
    final lastChunk = (start + length - 1) ~/ g.chunkSize;

    final buffer = BytesBuilder(copy: false);
    for (var i = firstChunk; i <= lastChunk && i < g.chunkCount; i++) {
      final isLastChunk = i == g.chunkCount - 1;
      final dataSize = isLastChunk
          ? g.originalSize - (i * g.chunkSize)
          : g.chunkSize;
      final chunkTotalSize = dataSize + _encryptor.chunkMacSize;
      final chunkStart =
          g.headerSize + (i * (g.chunkSize + _encryptor.chunkMacSize));

      final chunkData = await _inner.readRange(
        key,
        start: chunkStart,
        length: chunkTotalSize,
      );

      final decrypted = await _encryptor.decryptChunk(
        chunkData,
        encKey,
        g.nonce,
        i,
      );
      buffer.add(decrypted);
    }

    // Slice to the exact requested range. Clamp the end so an over-length
    // request returns the available bytes instead of throwing — matching the
    // clamping every other backend does.
    final chunkAlignedStart = firstChunk * g.chunkSize;
    final offsetInFirstChunk = start - chunkAlignedStart;
    final fullDecrypted = buffer.takeBytes();
    final end = (offsetInFirstChunk + length).clamp(0, fullDecrypted.length);

    return Uint8List.sublistView(fullDecrypted, offsetInFirstChunk, end);
  }

  // ── Metadata ──

  @override
  Future<ObjectInfo?> head(String key) async {
    checkNotDisposed();
    final info = await _inner.head(key);
    if (info == null) return null;

    // For encrypted files, report the PLAINTEXT size — ObjectInfo.size is
    // a logical-size guarantee. Sidecar first (no byte reads); otherwise
    // resolve from the header / ciphertext framing. A header that can't
    // even parse means the object can't be decrypted at all — surface
    // that as corruption instead of quietly reporting ciphertext size.
    if (info.metadata[_metaEncrypted] == 'true') {
      final sidecarSize = int.tryParse(info.metadata[_metaOriginalSize] ?? '');
      if (sidecarSize != null) {
        return info.copyWith(size: sidecarSize);
      }
      final g = await _resolveGeometry(key, info);
      return info.copyWith(size: g.originalSize);
    }

    return info;
  }

  @override
  Future<bool> exists(String key) {
    checkNotDisposed();
    return _inner.exists(key);
  }

  // ── Delete ──

  @override
  Future<void> delete(String key) {
    checkNotDisposed();
    return _inner.delete(key);
  }

  @override
  Future<void> deletePrefix(String prefix) {
    checkNotDisposed();
    return _inner.deletePrefix(prefix);
  }

  // ── List ──

  /// Lists with PLAINTEXT sizes where the sidecar carries them.
  ///
  /// Unlike [head], list() never probes file headers — one byte-read per
  /// entry would make directory listings O(total content). The rare
  /// crash-window entry whose sidecar size is missing reports its
  /// ciphertext size here; call [head] on it for the derived exact size.
  @override
  Future<List<ObjectInfo>> list(String prefix) async {
    checkNotDisposed();
    final objects = await _inner.list(prefix);

    return objects
        // One-shot plaintext temps are internal bookkeeping, not user
        // objects — a crash can leave one behind until the next sweep.
        .where((info) => !info.key.contains(decryptTempMarker))
        // Correct sizes for encrypted files using sidecar metadata.
        .map((info) {
          if (info.metadata[_metaEncrypted] == 'true') {
            final originalSize = int.tryParse(
              info.metadata[_metaOriginalSize] ?? '',
            );
            if (originalSize != null) {
              return info.copyWith(size: originalSize);
            }
          }
          return info;
        })
        .toList();
  }

  // ── Copy ──

  @override
  Future<void> copy(String sourceKey, String destKey) async {
    checkNotDisposed();
    final info = await _inner.head(sourceKey);
    if (info == null) throw FileNotFoundError(sourceKey);

    if (info.metadata[_metaEncrypted] != 'true') {
      // Not encrypted — simple copy
      return _inner.copy(sourceKey, destKey);
    }

    // Encrypted — re-encrypt with the destination key
    // This ensures cross-profile copies work correctly
    final sourceEncKey = await _keyResolver?.resolveKey(sourceKey);
    final destEncKey = await _keyResolver?.resolveKey(destKey);

    if (sourceEncKey == null && destEncKey == null) {
      // Locked copy — neither side resolves (e.g. a locked profile).
      // A byte copy keeps the object intact and still encrypted with its
      // original key: nothing is exposed, nothing is mis-keyed.
      return _inner.copy(sourceKey, destKey);
    }
    if (sourceEncKey == null || destEncKey == null) {
      // Exactly one side resolves. A byte copy here would stamp the
      // destination with ciphertext its own key can't decrypt (MAC
      // failures later, far from the cause); re-keying silently is worse.
      throw EncryptionKeyMissingError(
        sourceEncKey == null ? sourceKey : destKey,
      );
    }

    // Read-decrypt source → write-encrypt dest, carrying the user metadata
    // across. writeStream re-derives the internal _metaEncrypted/_metaOriginalSize
    // flags for the destination, so passing them straight through is harmless.
    final plainStream = readStream(sourceKey);
    await writeStream(
      destKey,
      plainStream,
      WriteOptions(
        encrypt: true,
        encryptionKey: destEncKey,
        contentType: info.contentType,
        metadata: info.metadata,
      ),
    );
  }

  // ── Metadata update ──

  @override
  Future<void> updateMetadata(
    String key, {
    String? contentType,
    Map<String, String> metadata = const {},
  }) async {
    checkNotDisposed();
    // Preserve the internal encryption flags. metadata is REPLACED, not merged,
    // so passing only user metadata would strip _metaEncrypted/_metaOriginalSize —
    // leaving readStream, readRange, and head unable to tell the object is
    // encrypted, handing back ciphertext as plaintext.
    final info = await _inner.head(key);
    if (info == null || info.metadata[_metaEncrypted] != 'true') {
      return _inner.updateMetadata(
        key,
        contentType: contentType,
        metadata: metadata,
      );
    }
    final originalSize = info.metadata[_metaOriginalSize];
    return _inner.updateMetadata(
      key,
      contentType: contentType,
      metadata: {
        ...metadata,
        _metaEncrypted: 'true',
        _metaOriginalSize: ?originalSize,
      },
    );
  }

  // ── Private helpers ──

  /// Resolve the chunk geometry (plaintext size + chunk count) of the
  /// encrypted object at [key]. [info] is the INNER head — `info.size`
  /// is the ciphertext size.
  ///
  /// Truth chain:
  /// 1. The file header's `originalSize`, when > 0 (buffered writes).
  /// 2. The sidecar's `originalSize` (streamed writes, after the
  ///    metadata patch that ends writeStream).
  /// 3. Derived from the ciphertext length alone — the crash window
  ///    where a streamed write finished its bytes but the sidecar patch
  ///    never ran. The framing is header + N×(chunk + MAC) with a short
  ///    final unit, so the length determines the geometry exactly.
  ///    (This is why FileEncryptor.parseHeader's chunkSize and nonce
  ///    must be final at stream start — only the size may be
  ///    provisional.)
  Future<
    ({
      int originalSize,
      int chunkCount,
      int chunkSize,
      int headerSize,
      Uint8List nonce,
    })
  >
  _resolveGeometry(String key, ObjectInfo info) async {
    final headerBytes = await _inner.readRange(
      key,
      start: 0,
      length: _encryptor.headerSize,
    );
    final header = _encryptor.parseHeader(headerBytes);

    var originalSize = header.originalSize > 0
        ? header.originalSize
        : int.tryParse(info.metadata[_metaOriginalSize] ?? '') ?? 0;
    var chunkCount = originalSize > 0
        ? (originalSize + header.chunkSize - 1) ~/ header.chunkSize
        : header.chunkCount;

    if (originalSize == 0 && header.chunkSize > 0) {
      final payload = info.size - header.headerSize;
      final unit = header.chunkSize + _encryptor.chunkMacSize;
      if (payload > 0) {
        chunkCount = (payload + unit - 1) ~/ unit;
        final lastUnit = payload - (chunkCount - 1) * unit;
        // The final unit must carry at least one data byte beyond its
        // MAC — anything less means the ciphertext is shorter than its
        // own framing.
        if (lastUnit <= _encryptor.chunkMacSize) {
          throw CorruptedFileError(
            key,
            cause: 'ciphertext shorter than its own framing',
          );
        }
        originalSize =
            (chunkCount - 1) * header.chunkSize +
            (lastUnit - _encryptor.chunkMacSize);
      }
    }

    return (
      originalSize: originalSize,
      chunkCount: chunkCount,
      chunkSize: header.chunkSize,
      headerSize: header.headerSize,
      nonce: header.nonce,
    );
  }

  Future<Object> _resolveKey(String key, WriteOptions options) async {
    final encKey = options.encryptionKey ?? await _keyResolver?.resolveKey(key);
    if (encKey == null) {
      throw EncryptionKeyMissingError(key);
    }
    return encKey;
  }

  @override
  Future<MaterializedFile> materialize(
    String key, {
    bool decrypt = true,
    bool exclusive = false,
  }) async {
    checkNotDisposed();
    final info = await _inner.head(key);
    if (info == null) throw FileNotFoundError(key);

    final isEncrypted = info.metadata[_metaEncrypted] == 'true';

    // Unencrypted or caller wants raw ciphertext — pass through.
    // `decrypt: false` on an encrypted file is a deliberate "give me the
    // ciphertext bytes" request; callers handle their own decryption or
    // simply need the raw blob for re-upload.
    if (!isEncrypted || !decrypt) {
      return _inner.materialize(key, decrypt: decrypt, exclusive: exclusive);
    }

    // Encrypted + decrypt=true. Plaintext doesn't live on disk — we must
    // stream-decrypt to a platform-local location. Two paths:
    //
    // 1. _decryptCache present → shared entries are content-addressed by
    //    {key, mtime, size} and reused across calls; exclusive entries are
    //    one-shot keys the caller owns, deleted on release. Either way the
    //    plaintext lands in the cache — the one store the app designated
    //    for plaintext-at-rest — never in the primary store.
    //
    // 2. _decryptCache absent → one-shot plaintext temp in the INNER
    //    backend under the reserved [decryptTempMarker] namespace (hidden
    //    from list(), crash leftovers swept on the next materialize).
    //    Every call re-decrypts. Correct, just not reused.
    final cache = _decryptCache;
    if (cache != null && !exclusive) {
      return _materializeViaCache(cache, key, info);
    }
    return _materializeFresh(key);
  }

  /// Stream-decrypt into [cache] at a content-addressed key and materialize
  /// from the cache. Subsequent calls for the same {key, mtime, size}
  /// return the cached materialization directly — no re-decrypt.
  Future<MaterializedFile> _materializeViaCache(
    StorageBackend cache,
    String key,
    ObjectInfo info,
  ) async {
    final cacheKey = _decryptCacheKey(key, info);
    if (!await cache.exists(cacheKey)) {
      // Single-flight: concurrent misses for the same version share one
      // fill. Without this, the second caller can see exists() flip true
      // while the first is still streaming and materialize a torn entry.
      await (_cacheFills[cacheKey] ??=
          _fillDecryptCache(
            cache,
            key,
            cacheKey,
            // The cleanup must not hand the removed future back to
            // whenComplete: whenComplete AWAITS a future returned by its
            // callback, and Map.remove returns the very future being
            // completed — this future would wait on itself, forever.
          ).whenComplete(() {
            unawaited(_cacheFills.remove(cacheKey));
          }));
    }
    // Shared cache entry — release is a no-op; entries age out under the
    // eviction policy of the cache backend the app wired in.
    final handle = await cache.materialize(cacheKey, exclusive: false);
    return MaterializedFile(
      localPath: handle.localPath,
      key: key,
      release: handle.release,
    );
  }

  /// Reap superseded cache entries for [key], then stream-decrypt the
  /// current version into [cacheKey].
  ///
  /// The reap is what bounds cache growth: the version tag changes on
  /// every rewrite of the object, and nothing else ever deletes the
  /// entries for older versions.
  Future<void> _fillDecryptCache(
    StorageBackend cache,
    String key,
    String cacheKey,
  ) async {
    await cache.deletePrefix(_decryptCacheNamespace(key));
    await cache.writeStream(
      cacheKey,
      readStream(key), // transparent decrypt
      const WriteOptions(encrypt: false, metadata: {'source': 'decrypt-cache'}),
    );
  }

  /// Stream-decrypt into a one-shot plaintext entry the caller owns.
  /// On release, the plaintext is deleted so no decrypted bytes linger.
  ///
  /// The entry goes to the decrypt cache when one is configured (the
  /// app's designated plaintext area); only when there is no cache does
  /// it fall back to the inner store, under the reserved
  /// [decryptTempMarker] namespace.
  Future<MaterializedFile> _materializeFresh(String key) async {
    final store = _decryptCache ?? _inner;
    await _sweepDecryptTemps(store);
    final freshKey = _freshDecryptKey(key, flat: _decryptCache != null);
    await store.writeStream(
      freshKey,
      readStream(key),
      const WriteOptions(encrypt: false, metadata: {'source': 'decrypt-fresh'}),
    );
    // Zero-copy handle: freshKey is unique and known only to this call, so
    // the entry is exclusive by construction — asking the store for an
    // exclusive materialize would just write the plaintext to disk a
    // second time.
    final handle = await store.materialize(
      freshKey,
      decrypt: false, // we just wrote plaintext directly
      exclusive: false,
    );
    return MaterializedFile(
      localPath: handle.localPath,
      key: key,
      release: () async {
        await handle.release();
        // Always clean up the plaintext. These are one-shot temps never
        // meant to outlive the caller's use; if this delete fails the
        // sweep on the next materialize reclaims it.
        try {
          await store.delete(freshKey);
        } on StorageError {
          // Best-effort — the crash sweep is the safety net.
        }
      },
    );
  }

  /// Delete crash leftovers under the [decryptTempMarker] namespace.
  ///
  /// Runs once per backend instance, on the first materialize (apps that
  /// never materialize pay nothing). Memoized as a future so a concurrent
  /// first-materialize waits for the sweep instead of racing it — a temp
  /// written mid-sweep could otherwise be reclaimed while still in use.
  Future<void> _sweepDecryptTemps(StorageBackend store) =>
      _tempSweep ??= () async {
        final leftovers = await store.list('');
        for (final obj in leftovers) {
          if (!obj.key.contains(decryptTempMarker)) continue;
          try {
            await store.delete(obj.key);
          } on StorageError {
            // Best-effort — an undeletable leftover is retried on the
            // next instance's sweep.
          }
        }
      }();

  /// Content-addressed cache key — stable across calls for the same file
  /// version, superseded (and reaped) when the file is rewritten.
  ///
  /// The object key is folded into a single flat segment via an injective
  /// escape (`_` → `__`, then `/` → `_s`): distinct keys can never share
  /// a cache entry (`a/b` → `a_sb`, `a_b` → `a__b`), and all versions of
  /// one key share a reap-able namespace prefix.
  String _decryptCacheKey(String key, ObjectInfo info) {
    final version = '${info.lastModified.microsecondsSinceEpoch}-${info.size}';
    return '${_decryptCacheNamespace(key)}$version';
  }

  /// The cache-key prefix shared by every version of [key]'s entries.
  String _decryptCacheNamespace(String key) =>
      '${_escapeKey(key)}$_cacheEntryMarker';

  /// Injective flat-segment escape. `__` in the output can only come from
  /// a literal `_`, and `_s` only from `/`, so decoding is unambiguous —
  /// no two storage keys map to the same escaped form.
  String _escapeKey(String key) =>
      key.replaceAll('_', '__').replaceAll('/', '_s');

  /// Unique one-shot plaintext key for a single materialize call.
  ///
  /// [flat] callers (decrypt cache) get the escaped single-segment form;
  /// inner-store temps stay a sibling of the original key so they live
  /// next to it on disk.
  String _freshDecryptKey(String key, {required bool flat}) {
    final base = flat ? _escapeKey(key) : key;
    final ts = DateTime.now().microsecondsSinceEpoch;
    return '$base$decryptTempMarker$ts-${_freshCounter++}';
  }

  // ── Lifecycle ──

  @override
  String get disposeLabel => 'EncryptedBackend';

  @override
  Future<void> dispose() async {
    // Ownership rule: inner and decryptCache are caller-provided, so
    // their creators dispose them — this layer only arms its own guard.
    markDisposed();
    _cacheFills.clear();
  }
}
