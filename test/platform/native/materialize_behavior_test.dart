// Behavior matrix for `StorageBackend.materialize` per the
// cellar_reimagination.md spec.
//
// Covers every row of the (backend × encrypted × decrypt × exclusive)
// matrix that's runnable off-device:
//
// - Local, unencrypted, exclusive=false → original path (zero copy)
// - Local, unencrypted, exclusive=true  → copy to temp (caller owns)
// - Encrypted + decrypt=true, exclusive=false → decrypt to cache; reused
// - Encrypted + decrypt=true, exclusive=true  → decrypt fresh; release cleans
// - Encrypted + decrypt=false → raw ciphertext path (no decryption)
//
// IndexedDB is web-only; tested by interface contract conformance
// when a web test harness is wired up. Not exercised here.

import 'dart:io';
import 'dart:typed_data';

import 'package:cellar/cellar_lowlevel.dart';
import 'package:test/test.dart';

import '../../harness/forwarding_backend.dart';

// ══════════════════════════════════════════════════════════════════════════
// Helpers
// ══════════════════════════════════════════════════════════════════════════

Future<Directory> _makeTempDir(String prefix) =>
    Directory.systemTemp.createTemp('cellar_matrix_$prefix');

/// Minimal fake encryptor with identifiable "ENC{...}" wrapping — sufficient
/// to prove the encrypted path decrypts vs. not. Does NOT implement real
/// cryptography; tests are about the materialize plumbing, not crypto
/// correctness (that's covered by the real EncryptedBackend tests).
class _FakeFileEncryptor implements FileEncryptor {
  static final _magic = Uint8List.fromList('ENC{'.codeUnits);
  static final _close = Uint8List.fromList('}'.codeUnits);

  @override
  int get headerSize => _magic.length;

  @override
  int get chunkMacSize => 0;

  @override
  bool isEncrypted(Uint8List bytes) {
    if (bytes.length < _magic.length) return false;
    for (var i = 0; i < _magic.length; i++) {
      if (bytes[i] != _magic[i]) return false;
    }
    return true;
  }

  @override
  Future<Uint8List> encryptBytes(
    Uint8List plain,
    Object key, {
    int chunkSize = 262144,
  }) async {
    return Uint8List.fromList([..._magic, ...plain, ..._close]);
  }

  @override
  Future<Uint8List> decryptBytes(Uint8List bytes, Object key) async {
    return Uint8List.fromList(
      bytes.sublist(_magic.length, bytes.length - _close.length),
    );
  }

  @override
  Stream<List<int>> encryptStream(
    Stream<List<int>> plain,
    Object key, {
    int chunkSize = 262144,
  }) async* {
    yield _magic;
    await for (final chunk in plain) {
      yield chunk;
    }
    yield _close;
  }

  @override
  Stream<List<int>> decryptStream(
    Stream<List<int>> ciphertext,
    Object key,
  ) async* {
    // The encrypted adapter uses readRange + decryptChunk, not this
    // method. Unused in tests; kept to satisfy the interface.
    final builder = BytesBuilder();
    await for (final chunk in ciphertext) {
      builder.add(chunk);
    }
    yield (await decryptBytes(builder.takeBytes(), key)).toList();
  }

  @override
  Future<Uint8List> decryptChunk(
    Uint8List chunk,
    Object key,
    Uint8List nonce,
    int index,
  ) async => chunk;

  @override
  ({
    int chunkSize,
    int originalSize,
    Uint8List nonce,
    int headerSize,
    int chunkCount,
  })
  parseHeader(Uint8List headerBytes) => (
    originalSize: 0,
    chunkSize: 1 << 20,
    chunkCount: 0,
    nonce: Uint8List(0),
    headerSize: _magic.length,
  );
}

class _FixedKeyResolver implements EncryptionKeyResolver {
  @override
  Future<Object?> resolveKey(String key) async => 'test-key';
  @override
  void clearCache() {}
}

/// Counts writeStream calls — used to prove single-flight cache fills.
class _CountingBackend extends ForwardingBackend {
  _CountingBackend(super.inner);

  int writeStreamCalls = 0;

  @override
  Future<void> writeStream(
    String key,
    Stream<List<int>> byteStream, [
    WriteOptions options = const WriteOptions(),
  ]) {
    writeStreamCalls++;
    return super.writeStream(key, byteStream, options);
  }
}

// ══════════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════════

void main() {
  group('materialize behavior matrix', () {
    // ────────────────────────────────────────────────────────────────────
    // Local, unencrypted
    // ────────────────────────────────────────────────────────────────────
    group('Local + unencrypted', () {
      late Directory baseDir;
      late FileSystemBackend adapter;

      setUp(() async {
        baseDir = await _makeTempDir('local');
        adapter = FileSystemBackend(baseDir.path);
        await adapter.write('hello', Uint8List.fromList('world'.codeUnits));
      });

      tearDown(() async {
        try {
          await baseDir.delete(recursive: true);
        } catch (_) {}
      });

      test(
        'exclusive=false returns the original file path (zero copy)',
        () async {
          final handle = await adapter.materialize('hello', exclusive: false);
          expect(handle.localPath, '${baseDir.path}/hello');
          await handle.release();
          // Release is a no-op; the original must still exist.
          expect(await File('${baseDir.path}/hello').exists(), isTrue);
        },
      );

      test('exclusive=true returns a temp copy, release deletes it', () async {
        final handle = await adapter.materialize('hello', exclusive: true);
        expect(handle.localPath, isNot('${baseDir.path}/hello'));
        expect(await File(handle.localPath).exists(), isTrue);

        // Contents match
        final bytes = await File(handle.localPath).readAsBytes();
        expect(bytes, Uint8List.fromList('world'.codeUnits));

        await handle.release();
        expect(await File(handle.localPath).exists(), isFalse);
      });
    });

    // ────────────────────────────────────────────────────────────────────
    // Encrypted (wraps local)
    // ────────────────────────────────────────────────────────────────────
    group('Encrypted + fake encryptor', () {
      late Directory dataDir;
      late Directory cacheDir;
      late FileSystemBackend innerAdapter;
      late FileSystemBackend cacheAdapter;
      late EncryptedBackend encryptedWithCache;
      late EncryptedBackend encryptedNoCache;

      setUp(() async {
        dataDir = await _makeTempDir('enc_data');
        cacheDir = await _makeTempDir('enc_cache');
        innerAdapter = FileSystemBackend(dataDir.path);
        cacheAdapter = FileSystemBackend(cacheDir.path);

        encryptedWithCache = EncryptedBackend(
          inner: innerAdapter,
          encryptor: _FakeFileEncryptor(),
          keyResolver: _FixedKeyResolver(),
          decryptCache: cacheAdapter,
        );
        encryptedNoCache = EncryptedBackend(
          inner: innerAdapter,
          encryptor: _FakeFileEncryptor(),
          keyResolver: _FixedKeyResolver(),
        );

        // Write encrypted content via the encrypted decorator (the bytes
        // on disk are ciphertext: "ENC{plaintext}").
        await encryptedWithCache.write(
          'secret',
          Uint8List.fromList('plaintext'.codeUnits),
          const WriteOptions(encrypt: true),
        );
      });

      tearDown(() async {
        try {
          await dataDir.delete(recursive: true);
        } catch (_) {}
        try {
          await cacheDir.delete(recursive: true);
        } catch (_) {}
      });

      test(
        'decrypt=true + exclusive=false caches plaintext; reused on repeat',
        () async {
          final h1 = await encryptedWithCache.materialize(
            'secret',
            decrypt: true,
          );
          final bytes1 = await File(h1.localPath).readAsBytes();
          expect(bytes1, Uint8List.fromList('plaintext'.codeUnits));
          // Path lives inside the cache dir — not the original ciphertext
          // location.
          expect(h1.localPath.startsWith(cacheDir.path), isTrue);
          await h1.release();
          // Release is a no-op for cache entries; the cached plaintext
          // must still exist for reuse.
          expect(await File(h1.localPath).exists(), isTrue);

          // Second call hits the cache — same path, no re-decrypt.
          final h2 = await encryptedWithCache.materialize(
            'secret',
            decrypt: true,
          );
          expect(h2.localPath, h1.localPath);
          await h2.release();
        },
      );

      test('decrypt=true + exclusive=true writes fresh plaintext; release '
          'deletes it', () async {
        final h = await encryptedWithCache.materialize(
          'secret',
          decrypt: true,
          exclusive: true,
        );
        expect(
          await File(h.localPath).readAsBytes(),
          Uint8List.fromList('plaintext'.codeUnits),
        );
        await h.release();
        expect(await File(h.localPath).exists(), isFalse);
      });

      test(
        'decrypt=false returns the raw ciphertext path (no decryption)',
        () async {
          final h = await encryptedWithCache.materialize(
            'secret',
            decrypt: false,
          );
          final raw = await File(h.localPath).readAsBytes();
          // Must START with the magic sentinel; decryption has NOT happened.
          expect(raw.sublist(0, 4), Uint8List.fromList('ENC{'.codeUnits));
          await h.release();
        },
      );

      test(
        'no cache wired: decrypt=true works, fresh plaintext each call',
        () async {
          final h = await encryptedNoCache.materialize('secret', decrypt: true);
          expect(
            await File(h.localPath).readAsBytes(),
            Uint8List.fromList('plaintext'.codeUnits),
          );
          await h.release();
          // No cache, so the fresh plaintext sibling gets cleaned on release.
          expect(await File(h.localPath).exists(), isFalse);
        },
      );
    });

    // ────────────────────────────────────────────────────────────────────
    // Decrypt-cache architecture — key escaping, version reaping,
    // single-flight fills, temp hygiene
    // ────────────────────────────────────────────────────────────────────
    group('decrypt cache architecture', () {
      late Directory dataDir;
      late Directory cacheDir;
      late FileSystemBackend innerAdapter;
      late FileSystemBackend cacheAdapter;

      EncryptedBackend build({StorageBackend? cache}) => EncryptedBackend(
        inner: innerAdapter,
        encryptor: _FakeFileEncryptor(),
        keyResolver: _FixedKeyResolver(),
        decryptCache: cache,
      );

      setUp(() async {
        dataDir = await _makeTempDir('dec_data');
        cacheDir = await _makeTempDir('dec_cache');
        innerAdapter = FileSystemBackend(dataDir.path);
        cacheAdapter = FileSystemBackend(cacheDir.path);
      });

      tearDown(() async {
        for (final d in [dataDir, cacheDir]) {
          try {
            await d.delete(recursive: true);
          } catch (_) {}
        }
      });

      test('colliding keys a/b and a_b get distinct cache entries', () async {
        final enc = build(cache: cacheAdapter);
        final contentSlash = Uint8List.fromList('slash-content'.codeUnits);
        final contentUnder = Uint8List.fromList('under'.codeUnits);
        await enc.write('a/b', contentSlash);
        await enc.write('a_b', contentUnder);

        final hSlash = await enc.materialize('a/b');
        final hUnder = await enc.materialize('a_b');
        expect(await File(hSlash.localPath).readAsBytes(), contentSlash);
        expect(await File(hUnder.localPath).readAsBytes(), contentUnder);

        // The injective escape keeps the two namespaces apart:
        // a/b → a_sb.dec.*, a_b → a__b.dec.*
        final cacheKeys = (await cacheAdapter.list('')).map((o) => o.key);
        expect(cacheKeys.where((k) => k.startsWith('a_sb.dec.')), hasLength(1));
        expect(cacheKeys.where((k) => k.startsWith('a__b.dec.')), hasLength(1));
        await hSlash.release();
        await hUnder.release();
      });

      test('rewriting an object reaps its superseded cache entries', () async {
        final enc = build(cache: cacheAdapter);
        await enc.write('k', Uint8List.fromList(List.filled(100, 1)));
        final h1 = await enc.materialize('k');
        await h1.release();

        // Different length → different version tag, deterministically.
        final v2 = Uint8List.fromList(List.filled(40, 2));
        await enc.write('k', v2);
        final h2 = await enc.materialize('k');
        expect(await File(h2.localPath).readAsBytes(), v2);
        await h2.release();

        final entries = (await cacheAdapter.list(
          '',
        )).where((o) => o.key.startsWith('k.dec.')).toList();
        expect(
          entries,
          hasLength(1),
          reason: 'the v1 entry must be reaped, not orphaned forever',
        );
      });

      test('concurrent materialize misses share a single cache fill', () async {
        final counting = _CountingBackend(cacheAdapter);
        final enc = build(cache: counting);
        final content = Uint8List.fromList(List<int>.generate(64, (i) => i));
        await enc.write('shared', content);

        final handles = await Future.wait([
          enc.materialize('shared'),
          enc.materialize('shared'),
          enc.materialize('shared'),
        ]);
        for (final h in handles) {
          expect(await File(h.localPath).readAsBytes(), content);
          await h.release();
        }
        expect(
          counting.writeStreamCalls,
          1,
          reason: 'three concurrent misses must not race three fills',
        );
      });

      test('exclusive materialize with a cache keeps plaintext out of the '
          'primary store', () async {
        final enc = build(cache: cacheAdapter);
        await enc.write('k', Uint8List.fromList('data'.codeUnits));
        final h = await enc.materialize('k', exclusive: true);
        expect(h.localPath.startsWith(cacheDir.path), isTrue);
        expect(
          (await innerAdapter.list(
            '',
          )).where((o) => o.key.contains(EncryptedBackend.decryptTempMarker)),
          isEmpty,
          reason: 'plaintext temps belong in the designated cache store',
        );
        await h.release();
        expect(await File(h.localPath).exists(), isFalse);
      });

      test('cacheless temps are hidden from list() while held', () async {
        final enc = build();
        await enc.write('k', Uint8List.fromList('data'.codeUnits));
        final h = await enc.materialize('k', exclusive: true);

        // The temp physically exists in the inner store…
        expect(
          (await innerAdapter.list(
            '',
          )).where((o) => o.key.contains(EncryptedBackend.decryptTempMarker)),
          hasLength(1),
        );
        // …but the decorator never shows it as a user object.
        expect(
          (await enc.list(
            '',
          )).where((o) => o.key.contains(EncryptedBackend.decryptTempMarker)),
          isEmpty,
        );
        await h.release();
      });

      test('crash leftovers are swept on the next materialize', () async {
        final enc = build();
        await enc.write('k', Uint8List.fromList('data'.codeUnits));
        // Simulate a crashed process: a temp whose release() never ran.
        await innerAdapter.write(
          'ghost${EncryptedBackend.decryptTempMarker}123-0',
          Uint8List.fromList('stale plaintext'.codeUnits),
        );

        final fresh = build(); // new instance = new process
        final h = await fresh.materialize('k', exclusive: true);
        await h.release();

        expect(
          (await innerAdapter.list(
            '',
          )).where((o) => o.key.contains(EncryptedBackend.decryptTempMarker)),
          isEmpty,
          reason: 'the ghost temp and the call\'s own temp must both be gone',
        );
      });
    });

    // ────────────────────────────────────────────────────────────────────
  });
}
