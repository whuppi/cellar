import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:cellar/cellar_lowlevel.dart';

import '../harness/fake_encryptor.dart';
import '../harness/in_memory_backend.dart';

/// EncryptedBackend with the fake encryptor — pure, runs on every platform.
void runEncryptedBattery() {
  group('EncryptedBackend', () {
    late InMemoryBackend inner;
    late EncryptedBackend enc;

    setUp(() {
      inner = InMemoryBackend();
      enc = EncryptedBackend(
        inner: inner,
        encryptor: FakeEncryptor(),
        keyResolver: const FixedKeyResolver('test-key'),
        encryptByDefault: true,
      );
    });

    group('round-trip', () {
      test('write encrypted then read returns original bytes', () async {
        final plain = Uint8List.fromList(List.generate(100, (i) => i));
        await enc.write('a', plain);

        // Inner backend has ciphertext (different bytes, magic header).
        final raw = await inner.read('a');
        expect(raw, isNot(equals(plain)));

        // Read through the decorator returns plaintext.
        expect(await enc.read('a'), plain);
      });

      test('write plaintext (encrypt:false) then read returns same', () async {
        final plain = Uint8List.fromList([1, 2, 3, 4, 5]);
        await enc.write('a', plain, const WriteOptions(encrypt: false));

        // Inner has plaintext exactly.
        expect(await inner.read('a'), plain);
        // Read through the decorator passes through.
        expect(await enc.read('a'), plain);
      });

      test(
        'encryptByDefault honored when WriteOptions.encrypt is null',
        () async {
          await enc.write('a', Uint8List.fromList([1, 2, 3]));
          // Default is true → ciphertext on disk.
          final raw = await inner.read('a');
          expect(raw[0], 0x46); // 'F' from FAKE magic
        },
      );

      test('encryptByDefault: false leaves writes plaintext', () async {
        final encOff = EncryptedBackend(
          inner: inner,
          encryptor: FakeEncryptor(),
          keyResolver: const FixedKeyResolver('k'),
          encryptByDefault: false,
        );
        await encOff.write('a', Uint8List.fromList([1, 2, 3]));
        // No magic — bytes are plaintext.
        expect(await inner.read('a'), Uint8List.fromList([1, 2, 3]));
      });

      test('mixing encrypted and plaintext objects works', () async {
        await enc.write('e', Uint8List.fromList([1]));
        await enc.write(
          'p',
          Uint8List.fromList([2]),
          const WriteOptions(encrypt: false),
        );

        expect(await enc.read('e'), Uint8List.fromList([1]));
        expect(await enc.read('p'), Uint8List.fromList([2]));
      });

      test('different sizes round-trip correctly', () async {
        final sizes = [0, 1, 64, 256, 1024, 4096, 65537];
        for (final size in sizes) {
          final plain = Uint8List.fromList(List.generate(size, (i) => i % 256));
          await enc.write('size-$size', plain);
          expect(await enc.read('size-$size'), plain, reason: 'size=$size');
        }
      });
    });

    group('head and list', () {
      test('head reports original size for encrypted file', () async {
        final plain = Uint8List(100);
        await enc.write('a', plain);
        final info = await enc.head('a');
        expect(info, isNotNull);
        expect(info!.size, 100); // original, not ciphertext size
      });

      test('head reports actual size for plaintext file', () async {
        await enc.write('a', Uint8List(50), const WriteOptions(encrypt: false));
        final info = await enc.head('a');
        expect(info!.size, 50);
      });

      test('list reports original sizes for encrypted files', () async {
        await enc.write('a', Uint8List(123));
        await enc.write('b', Uint8List(456));
        final results = await enc.list('');
        final aInfo = results.firstWhere((i) => i.key == 'a');
        final bInfo = results.firstWhere((i) => i.key == 'b');
        expect(aInfo.size, 123);
        expect(bInfo.size, 456);
      });
    });

    group('exists / delete / deletePrefix', () {
      test('exists returns true for stored keys', () async {
        await enc.write('a', Uint8List.fromList([1]));
        expect(await enc.exists('a'), isTrue);
        expect(await enc.exists('missing'), isFalse);
      });

      test('delete removes the key', () async {
        await enc.write('a', Uint8List.fromList([1]));
        await enc.delete('a');
        expect(await enc.exists('a'), isFalse);
      });

      test('deletePrefix removes everything under a prefix', () async {
        await enc.write('photos/a', Uint8List(1));
        await enc.write('photos/b', Uint8List(1));
        await enc.write('docs/c', Uint8List(1));

        await enc.deletePrefix('photos/');
        expect(await enc.exists('photos/a'), isFalse);
        expect(await enc.exists('photos/b'), isFalse);
        expect(await enc.exists('docs/c'), isTrue);
      });
    });

    group('errors', () {
      test('readRange throws FileNotFoundError for missing key', () async {
        expect(
          () => enc.readRange('missing', start: 0, length: 10),
          throwsA(isA<FileNotFoundError>()),
        );
      });

      test(
        'encrypt:true with no key resolver throws EncryptionKeyMissingError',
        () async {
          final encNoResolver = EncryptedBackend(
            inner: InMemoryBackend(),
            encryptor: FakeEncryptor(),
            encryptByDefault: false,
          );
          expect(
            () => encNoResolver.write(
              'a',
              Uint8List.fromList([1]),
              const WriteOptions(encrypt: true),
            ),
            throwsA(isA<EncryptionKeyMissingError>()),
          );
        },
      );
    });

    group('encrypted object with no resolvable key', () {
      // Write an encrypted object, then read it through a decorator whose
      // resolver can't produce a key. The bytes on disk are ciphertext;
      // handing them back as plaintext would be a silent data-integrity hole,
      // so every read path must throw EncryptionKeyMissingError instead.
      late EncryptedBackend locked;
      setUp(() async {
        await enc.write(
          'secret',
          Uint8List.fromList(List<int>.generate(300, (i) => i & 0xFF)),
        );
        locked = EncryptedBackend(
          inner: inner,
          encryptor: FakeEncryptor(),
          keyResolver: const _NullKeyResolver(),
        );
      });

      test('read throws EncryptionKeyMissingError', () {
        expect(
          locked.read('secret'),
          throwsA(isA<EncryptionKeyMissingError>()),
        );
      });
      test('readStream throws EncryptionKeyMissingError', () {
        expect(
          locked.readStream('secret').toList(),
          throwsA(isA<EncryptionKeyMissingError>()),
        );
      });
      test('readRange throws EncryptionKeyMissingError', () {
        expect(
          locked.readRange('secret', start: 0, length: 10),
          throwsA(isA<EncryptionKeyMissingError>()),
        );
      });
    });

    group('tamper detection', () {
      test('a flipped ciphertext byte fails MAC verification', () async {
        final plain = Uint8List.fromList(
          List<int>.generate(300, (i) => i & 0xFF),
        );
        await enc.write('t', plain);

        // Corrupt one byte INSIDE a chunk body (past the header).
        final cipher = await inner.read('t');
        cipher[FakeEncryptor().headerSize + 5] ^= 0xFF;
        await inner.write(
          't',
          cipher,
          WriteOptions(metadata: (await inner.head('t'))!.metadata),
        );

        expect(enc.read('t'), throwsA(isA<ChunkVerificationError>()));
        expect(
          enc.readStream('t').toList(),
          throwsA(isA<ChunkVerificationError>()),
        );
      });
    });

    group('crash-window geometry (streamed write, sidecar patch lost)', () {
      // A streamed write leaves a provisional header (originalSize=0);
      // the true size normally lands in the sidecar patch that ends
      // writeStream. If a crash strips that patch, the geometry must be
      // reconstructed from the ciphertext length alone — the object is
      // fully readable, not silently empty.
      late EncryptedBackend small;
      final plain = Uint8List.fromList(
        List<int>.generate(200, (i) => i & 0xFF),
      );

      setUp(() async {
        small = EncryptedBackend(
          inner: inner,
          encryptor: FakeEncryptor(streamChunkSize: 64),
          keyResolver: const FixedKeyResolver('test-key'),
        );
        await small.writeStream('s', Stream<List<int>>.value(plain));
        // Simulate the crash: keep only the flag — the exact state after
        // writeStream's byte write, before its metadata patch.
        await inner.updateMetadata('s', metadata: {'encrypted': 'true'});
      });

      test('readStream yields the full plaintext', () async {
        final out = BytesBuilder();
        await for (final c in small.readStream('s')) {
          out.add(c);
        }
        expect(out.takeBytes(), plain);
      });

      test('read returns the full plaintext', () async {
        expect(await small.read('s'), plain);
      });

      test('head reports the true plaintext size', () async {
        expect((await small.head('s'))!.size, plain.length);
      });

      test('readRange crossing chunk boundaries decrypts', () async {
        expect(
          await small.readRange('s', start: 60, length: 80),
          plain.sublist(60, 140),
        );
      });
    });

    group('onProgress', () {
      test('streamed encrypted write reports plaintext-space bytes', () async {
        final plain = List<int>.generate(150, (i) => i & 0xFF);
        final calls = <(int, int?)>[];
        await enc.writeStream(
          'p',
          Stream<List<int>>.fromIterable([
            plain.sublist(0, 100),
            plain.sublist(100),
          ]),
          WriteOptions(
            onProgress: (written, total) => calls.add((written, total)),
          ),
        );
        expect(calls, isNotEmpty);
        expect(
          calls.last.$1,
          plain.length,
          reason:
              'progress is plaintext bytes, not ciphertext '
              '(header/MAC overhead would overshoot the source size)',
        );
        expect(calls.map((c) => c.$2), everyElement(isNull));
      });
    });

    group('copy key-resolution matrix', () {
      // copy() of an encrypted object behaves per how the resolver covers
      // the two sides: both → re-encrypt; neither → locked byte copy;
      // exactly one → throw (a byte copy would mis-key the destination).
      final plain = Uint8List.fromList(
        List<int>.generate(300, (i) => i & 0xFF),
      );

      Future<EncryptedBackend> seeded(EncryptionKeyResolver resolver) async {
        final backend = EncryptedBackend(
          inner: inner,
          encryptor: FakeEncryptor(),
          keyResolver: resolver,
        );
        await enc.write('src', plain); // written with enc's 'test-key'
        return backend;
      }

      test('both sides resolve: re-encrypted, dest readable', () async {
        final backend = await seeded(
          const MapKeyResolver({'src': 'test-key', 'dst': 'other-key'}),
        );
        await backend.copy('src', 'dst');
        expect(await backend.read('dst'), plain);
        // Ciphertexts differ — dest was re-encrypted under its own key,
        // not byte-copied.
        expect(await inner.read('dst'), isNot(equals(await inner.read('src'))));
      });

      test(
        'neither side resolves: locked byte copy, still ciphertext',
        () async {
          final backend = await seeded(const MapKeyResolver({}));
          await backend.copy('src', 'dst');
          expect(await inner.read('dst'), equals(await inner.read('src')));
          // The copy is intact but locked — reading it without a key throws
          // rather than leaking ciphertext.
          expect(
            backend.read('dst'),
            throwsA(isA<EncryptionKeyMissingError>()),
          );
        },
      );

      test('only source resolves: throws for the destination', () async {
        final backend = await seeded(const MapKeyResolver({'src': 'test-key'}));
        expect(
          backend.copy('src', 'dst'),
          throwsA(
            isA<EncryptionKeyMissingError>().having((e) => e.key, 'key', 'dst'),
          ),
        );
        expect(await inner.exists('dst'), isFalse);
      });

      test('only destination resolves: throws for the source', () async {
        final backend = await seeded(
          const MapKeyResolver({'dst': 'other-key'}),
        );
        expect(
          backend.copy('src', 'dst'),
          throwsA(
            isA<EncryptionKeyMissingError>().having((e) => e.key, 'key', 'src'),
          ),
        );
        expect(await inner.exists('dst'), isFalse);
      });
    });
  });
}

/// A resolver that never produces a key — models a locked profile or a mapping
/// that doesn't cover this key. Reads of encrypted objects through it must fail
/// rather than leak ciphertext.
class _NullKeyResolver implements EncryptionKeyResolver {
  const _NullKeyResolver();

  @override
  Future<Object?> resolveKey(String storageKey) async => null;

  @override
  void clearCache() {}
}
