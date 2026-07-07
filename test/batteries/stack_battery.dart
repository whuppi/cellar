import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:cellar/cellar.dart';
import 'package:cellar/cellar_lowlevel.dart';

import '../harness/fake_encryptor.dart';
import '../harness/in_memory_backend.dart';

/// Decorator composition tests. These exercise:
///   - Encrypted-over-chunked
///   - Chunked-over-encrypted
///   - Both combinations stay byte-correct under various sizes
///   - The Cellar facade wraps these stacks transparently
/// Full decorator compositions — pure, runs on every platform.
void runStackBattery() {
  group('Decorator stacks', () {
    Uint8List seq(int n) =>
        Uint8List.fromList(List.generate(n, (i) => i % 256));

    group('Encrypted over Chunked', () {
      late InMemoryBackend backing;
      late StorageBackend stack;

      setUp(() {
        backing = InMemoryBackend();
        stack = EncryptedBackend(
          inner: ChunkedBackend(backing: backing, chunkSize: 64),
          encryptor: FakeEncryptor(),
          keyResolver: const FixedKeyResolver('test-key'),
          encryptByDefault: true,
        );
      });

      test('round-trips bytes across boundary sizes', () async {
        for (final size in [0, 1, 63, 64, 65, 200, 1024]) {
          final plain = seq(size);
          await stack.write('size-$size', plain);
          expect(await stack.read('size-$size'), plain, reason: 'size=$size');
        }
      });

      test(
        'inner backend stores chunked ciphertext (multiple records)',
        () async {
          await stack.write('a', seq(200));
          // 200 bytes plaintext → encrypted (slightly larger) → chunked into
          // 64-byte records. Expect more than one underlying record.
          expect(backing.objectCount, greaterThan(1));
        },
      );
    });

    group('Chunked over Encrypted', () {
      late InMemoryBackend backing;
      late StorageBackend stack;

      setUp(() {
        backing = InMemoryBackend();
        stack = ChunkedBackend(
          backing: EncryptedBackend(
            inner: backing,
            encryptor: FakeEncryptor(),
            keyResolver: const FixedKeyResolver('test-key'),
            encryptByDefault: true,
          ),
          chunkSize: 64,
        );
      });

      test('round-trips bytes across boundary sizes', () async {
        for (final size in [0, 1, 63, 64, 65, 200, 1024]) {
          final plain = seq(size);
          await stack.write('size-$size', plain);
          expect(await stack.read('size-$size'), plain, reason: 'size=$size');
        }
      });
    });

    group('Cellar facade wraps the stack transparently', () {
      late InMemoryBackend backing;
      late Cellar cellar;

      setUp(() async {
        backing = InMemoryBackend();
        final stack = EncryptedBackend(
          inner: ChunkedBackend(backing: backing, chunkSize: 64),
          encryptor: FakeEncryptor(),
          keyResolver: const FixedKeyResolver('test-key'),
          encryptByDefault: true,
        );
        cellar = Cellar.withBackends(
          {'main': stack},
          defaultPartition: 'main',
          keyPrefix: 'user/alice',
        );
        await cellar.open();
      });

      test(
        'Cellar.write + Cellar.read round-trips through encrypt+chunk',
        () async {
          final plain = seq(500);
          await cellar.write('photos/sunset', plain);
          expect(await cellar.read('photos/sunset'), plain);
        },
      );

      test('keyPrefix lands on the inner backend (after encryption)', () async {
        await cellar.write('a', seq(10));
        // Backing has chunked records keyed under 'user/alice/a__manifest' etc.
        final keys = (await backing.list('')).map((i) => i.key).toList();
        for (final k in keys) {
          expect(k, startsWith('user/alice/a'));
        }
      });
    });
  });
}
