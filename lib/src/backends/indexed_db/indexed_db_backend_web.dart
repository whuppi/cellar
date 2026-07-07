import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'package:cellar/src/decorators/chunked/chunked_backend.dart';
import 'package:cellar/src/core/dispose_guard.dart';
import 'package:cellar/src/core/storage_backend.dart';
import 'package:cellar/src/core/materialized_file.dart';
import 'package:cellar/src/core/object_info.dart';
import 'package:cellar/src/core/write_options.dart';
import 'package:cellar/src/core/errors.dart';

/// Web file storage using IndexedDB.
///
/// Layered on [ChunkedBackend] (which owns the
/// chunk-and-manifest algorithm) over a thin [_RawIndexedDbBackend]
/// (which owns the JS-interop / IndexedDB primitives). This means:
///
/// - The chunking logic is shared with any other backend that wants
///   it; tests against `ChunkedBackend` over an in-memory
///   backing prove the algorithm without needing a browser.
/// - This file owns ONLY the web-specific bits: opening a database,
///   reading/writing single records, and producing Blob URLs from
///   chunked records (the only operation that genuinely cannot be
///   abstracted across native and web).
///
/// Default chunk size is 64 KiB — see [ChunkedBackend] for the
/// rationale; override via the constructor to change it.
class IndexedDbBackend extends ChunkedBackend {
  /// Create a backend over the IndexedDB database [dbName].
  IndexedDbBackend({
    required String dbName,
    super.chunkSize = ChunkedBackend.defaultChunkSize,
  }) : super(backing: _RawIndexedDbBackend(dbName: dbName));

  @override
  String get disposeLabel => 'IndexedDbBackend';

  @override
  Future<void> dispose() async {
    // This class constructed its raw backing, so it disposes it — that
    // closes the IDBDatabase connection, unblocking deleteDatabase and
    // version upgrades from other tabs.
    await backing.dispose();
    await super.dispose();
  }

  // ══════════════════════════════════════════════════════════════════════
  // MATERIALIZE — Blob URL from chunked records
  // ══════════════════════════════════════════════════════════════════════

  /// Materialize on IndexedDB — returns a **Blob URL**.
  ///
  /// Web has no filesystem, so [MaterializedFile.localPath] is an object
  /// URL (e.g. `blob:https://app.example.com/uuid`). Usable with most
  /// browser APIs (`<audio src=...>`, `<img src=...>`, `fetch(url)`,
  /// anchor downloads). NOT usable with native FFI — which doesn't run
  /// on web anyway.
  ///
  /// ## Memory
  ///
  /// Reads each chunk record once (O(chunk size) in JS heap per
  /// iteration) and hands it off to the `Blob` constructor as one of N
  /// parts. The browser keeps blob parts in IndexedDB-backed memory
  /// rather than concatenating them in the JS heap. End-to-end memory
  /// is O(chunk size), regardless of total file size.
  ///
  /// ## Decrypt + exclusive
  ///
  /// [decrypt] is a no-op at this layer — the
  /// `EncryptedBackend` decorator intercepts upstream. If
  /// this code is reached on encrypted bytes, the blob URL exposes the
  /// ciphertext.
  ///
  /// [exclusive] is also a no-op: every call creates a fresh blob URL
  /// pointing at independent buffers, so callers always get an
  /// independent handle. [MaterializedFile.release] revokes the URL.
  @override
  Future<MaterializedFile> materialize(
    String key, {
    bool decrypt = true,
    bool exclusive = false,
  }) async {
    final manifest = await manifestFor(key);
    if (manifest == null) throw FileNotFoundError(key);

    // Read each chunk via the backing's raw record API, building a
    // JSAny[] for the Blob constructor. Per the Blob spec, parts are
    // referenced — not concatenated — until the blob's bytes are
    // actually requested. End-to-end memory stays O(chunkSize).
    final parts = <JSAny>[];
    for (var i = 0; i < manifest.chunkCount; i++) {
      final bytes = await backing.read(
        chunkKeyFor(key, manifest.generation, i),
      );
      parts.add(bytes.toJS);
    }

    final blob = manifest.contentType != null
        ? web.Blob(parts.toJS, web.BlobPropertyBag(type: manifest.contentType!))
        : web.Blob(parts.toJS);

    final url = web.URL.createObjectURL(blob);

    return MaterializedFile(
      localPath: url,
      key: key,
      release: () async {
        web.URL.revokeObjectURL(url);
      },
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// Raw IndexedDB backend — single-record I/O over IndexedDB.
//
// Implements [StorageBackend] but ONLY for the simple key→bytes
// case. The chunking layer above ([ChunkedBackend]) is what
// makes this usable for arbitrary-size objects. Splitting the two lets
// the chunking algorithm be tested off-web against an in-memory
// backing — no JS runtime required for unit tests.
// ══════════════════════════════════════════════════════════════════════════

class _RawIndexedDbBackend with DisposeGuard implements StorageBackend {
  _RawIndexedDbBackend({required String dbName}) : _dbName = dbName;
  final String _dbName;
  static const _storeName = 'files';
  static const _dbVersion = 1;

  web.IDBDatabase? _db;

  @override
  String get disposeLabel => 'IndexedDbBackend';

  @override
  Future<void> dispose() async {
    markDisposed();
    _db?.close();
    _db = null;
  }

  Future<web.IDBDatabase> _getDb() async {
    // Every operation on this backend goes through _getDb — one guard
    // here covers the whole surface.
    checkNotDisposed();
    if (_db != null) return _db!;

    final completer = Completer<web.IDBDatabase>();
    final request = web.window.self.indexedDB.open(_dbName, _dbVersion);

    request.onupgradeneeded = (web.IDBVersionChangeEvent event) {
      final db = request.result as web.IDBDatabase;
      if (!db.objectStoreNames.contains(_storeName)) {
        db.createObjectStore(_storeName);
      }
    }.toJS;

    request.onsuccess = (web.Event event) {
      _db = request.result as web.IDBDatabase;
      completer.complete(_db!);
    }.toJS;

    request.onerror = (web.Event event) {
      completer.completeError(
        StateError(
          'Failed to open IndexedDB "$_dbName": ${request.error?.message}',
        ),
      );
    }.toJS;

    return completer.future;
  }

  Future<web.IDBObjectStore> _store(String mode) async {
    final db = await _getDb();
    final tx = db.transaction(_storeName.toJS, mode);
    return tx.objectStore(_storeName);
  }

  Future<JSAny?> _request(web.IDBRequest request) {
    final completer = Completer<JSAny?>();
    request.onsuccess = (web.Event event) {
      completer.complete(request.result);
    }.toJS;
    request.onerror = (web.Event event) {
      completer.completeError(
        StateError('IndexedDB request failed: ${request.error?.message}'),
      );
    }.toJS;
    return completer.future;
  }

  // ── Write ──

  @override
  Future<void> write(
    String key,
    Uint8List bytes, [
    WriteOptions options = const WriteOptions(),
  ]) async {
    final store = await _store('readwrite');
    final record = _buildRecord(bytes, options.contentType, options.metadata);
    await _request(store.put(record, key.toJS));
  }

  @override
  Future<void> writeStream(
    String key,
    Stream<List<int>> byteStream, [
    WriteOptions options = const WriteOptions(),
  ]) async {
    // Single-record backend — collect then write. The chunking layer
    // above breaks large inputs into many small records BEFORE they
    // reach this method, so the buffered size here is bounded by the
    // chunking layer's chunkSize (default 64 KiB).
    final chunks = <int>[];
    await for (final chunk in byteStream) {
      chunks.addAll(chunk);
    }
    await write(key, Uint8List.fromList(chunks), options);
  }

  // ── Read ──

  @override
  Future<Uint8List> read(String key) async {
    final store = await _store('readonly');
    final result = await _request(store.get(key.toJS));
    if (result == null) throw FileNotFoundError(key);
    return _extractBody(key, result);
  }

  @override
  Stream<List<int>> readStream(String key) async* {
    yield await read(key);
  }

  @override
  Future<Uint8List> readRange(
    String key, {
    required int start,
    required int length,
  }) async {
    final bytes = await read(key);
    final end = (start + length).clamp(0, bytes.length);
    return bytes.sublist(start, end);
  }

  // ── Metadata ──

  @override
  Future<ObjectInfo?> head(String key) async {
    final store = await _store('readonly');
    final result = await _request(store.get(key.toJS));
    if (result == null) return null;
    return _parseObjectInfo(key, result);
  }

  @override
  Future<bool> exists(String key) async {
    final store = await _store('readonly');
    final result = await _request(store.count(key.toJS));
    if (result == null) return false;
    return (result as JSNumber).toDartInt > 0;
  }

  // ── Delete ──

  @override
  Future<void> delete(String key) async {
    final store = await _store('readwrite');
    await _request(store.delete(key.toJS));
  }

  @override
  Future<void> deletePrefix(String prefix) async {
    final keyRange = web.IDBKeyRange.bound(prefix.toJS, '$prefix\uffff'.toJS);
    final store = await _store('readwrite');
    final cursorRequest = store.openKeyCursor(keyRange);

    final completer = Completer<void>();
    cursorRequest.onsuccess = (web.Event event) {
      final cursor = cursorRequest.result;
      if (cursor != null) {
        final keyCursor = cursor as web.IDBCursor;
        store.delete(keyCursor.key!);
        keyCursor.continue_();
      } else {
        completer.complete();
      }
    }.toJS;
    cursorRequest.onerror = (web.Event event) {
      completer.completeError(
        StateError('IndexedDB cursor failed: ${cursorRequest.error?.message}'),
      );
    }.toJS;
    await completer.future;
  }

  // ── List ──

  @override
  Future<List<ObjectInfo>> list(String prefix) async {
    final keyRange = web.IDBKeyRange.bound(prefix.toJS, '$prefix\uffff'.toJS);
    final store = await _store('readonly');
    final cursorRequest = store.openCursor(keyRange);

    final results = <ObjectInfo>[];
    final completer = Completer<List<ObjectInfo>>();

    cursorRequest.onsuccess = (web.Event event) {
      final cursor = cursorRequest.result;
      if (cursor != null) {
        final valueCursor = cursor as web.IDBCursorWithValue;
        final key = (valueCursor.key! as JSString).toDart;
        final value = valueCursor.value;
        if (value != null) {
          results.add(_parseObjectInfo(key, value));
        }
        valueCursor.continue_();
      } else {
        completer.complete(results);
      }
    }.toJS;
    cursorRequest.onerror = (web.Event event) {
      completer.completeError(
        StateError('IndexedDB cursor failed: ${cursorRequest.error?.message}'),
      );
    }.toJS;

    return completer.future;
  }

  // ── Copy ──

  @override
  Future<void> copy(String sourceKey, String destKey) async {
    final store = await _store('readonly');
    final result = await _request(store.get(sourceKey.toJS));
    if (result == null) throw FileNotFoundError(sourceKey);
    final writeStore = await _store('readwrite');
    await _request(writeStore.put(result, destKey.toJS));
  }

  // ── Metadata update ──

  @override
  Future<void> updateMetadata(
    String key, {
    String? contentType,
    Map<String, String> metadata = const {},
  }) async {
    final store = await _store('readonly');
    final result = await _request(store.get(key.toJS));
    if (result == null) throw FileNotFoundError(key);

    final bytes = _extractBody(key, result);
    final writeStore = await _store('readwrite');
    final record = _buildRecord(bytes, contentType, metadata);
    await _request(writeStore.put(record, key.toJS));
  }

  // ── Materialize — never called on this layer ──

  @override
  Future<MaterializedFile> materialize(
    String key, {
    bool decrypt = true,
    bool exclusive = false,
  }) {
    // The chunking layer above provides the real materialize. This raw
    // backend is internal and shouldn't be reached directly.
    throw UnsupportedError(
      '_RawIndexedDbBackend.materialize must not be called — go through '
      'IndexedDbBackend, which produces a Blob URL from chunks.',
    );
  }

  // ── Internal: compound record helpers ──

  JSObject _buildRecord(
    Uint8List bytes,
    String? contentType,
    Map<String, String> metadata,
  ) {
    return <String, Object?>{
          'body': bytes.toJS,
          'contentType': contentType?.toJS,
          'metadata': metadata.map((k, v) => MapEntry(k, v.toJS)).jsify(),
          // Cellar-maintained write timestamp. IndexedDB has no native
          // last-modified tracking; we write it on every put so ObjectInfo
          // can return a non-null lastModified on web. Stored as ms-since-epoch.
          'writtenAt': DateTime.now().toUtc().millisecondsSinceEpoch.toJS,
        }.jsify()
        as JSObject;
  }

  Uint8List _extractBody(String key, JSAny record) {
    final body = (record as _IdbRecord).body;
    // _buildRecord stores the body as a Uint8Array (`Uint8List.toJS`);
    // structured clone hands the same shape back. Accept a bare
    // ArrayBuffer too — records imported from other tooling often carry
    // one, and the bytes are identical either way.
    if (body.isA<JSUint8Array>()) {
      return (body! as JSUint8Array).toDart;
    }
    if (body.isA<JSArrayBuffer>()) {
      return (body! as JSArrayBuffer).toDart.asUint8List();
    }
    throw CorruptedFileError(key, cause: 'Unexpected record body format');
  }

  ObjectInfo _parseObjectInfo(String key, JSAny record) {
    final bytes = _extractBody(key, record);
    final rec = record as _IdbRecord;

    String? contentType;
    final ct = rec.contentType;
    if (ct.isA<JSString>()) {
      contentType = (ct! as JSString).toDart;
    }

    var metadata = const <String, String>{};
    final meta = rec.metadata;
    if (meta != null) {
      final dartMap = meta.dartify();
      if (dartMap is Map) {
        metadata = dartMap.cast<String, String>();
      }
    }

    DateTime? lastModified;
    final wa = rec.writtenAt;
    if (wa.isA<JSNumber>()) {
      lastModified = DateTime.fromMillisecondsSinceEpoch(
        (wa! as JSNumber).toDartInt,
        isUtc: true,
      );
    }

    if (lastModified == null) {
      // ObjectInfo.lastModified is non-null by contract. A record without
      // writtenAt was written by code that didn't maintain the field —
      // treat it as corruption, not a legacy compat case.
      throw CorruptedFileError(
        key,
        cause: 'IndexedDB record missing writtenAt — wipe and rewrite.',
      );
    }

    return ObjectInfo(
      key: key,
      size: bytes.length,
      contentType: contentType,
      metadata: metadata,
      lastModified: lastModified,
    );
  }
}

/// Typed view of the compound record [_RawIndexedDbBackend] stores.
///
/// External getters compile to direct property access under BOTH dart2js
/// and dart2wasm. Do not read record fields through `dynamic` — dynamic
/// member access on a JS value crashes at runtime under dart2wasm.
@JS()
extension type _IdbRecord._(JSObject _) implements JSObject {
  external JSAny? get body;
  external JSAny? get contentType;
  external JSObject? get metadata;
  external JSAny? get writtenAt;
}
