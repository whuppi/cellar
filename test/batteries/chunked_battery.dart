import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:cellar/cellar_lowlevel.dart';

import '../harness/in_memory_backend.dart';

/// ChunkedBackend over an in-memory backing — pure, runs on every platform.
void runChunkedBattery() {
  group('ChunkedBackend', () {
    late InMemoryBackend backing;
    late ChunkedBackend chunked;
    const chunkSize = 64;

    setUp(() {
      backing = InMemoryBackend();
      chunked = ChunkedBackend(backing: backing, chunkSize: chunkSize);
    });

    Uint8List seq(int n) =>
        Uint8List.fromList(List.generate(n, (i) => i % 256));

    group('overwrite reclaims orphan chunks', () {
      test('write shrink deletes the tail chunks', () async {
        await chunked.write('k', seq(200)); // 4 chunks + manifest = 5 records
        expect(backing.objectCount, 5);
        await chunked.write('k', seq(10)); // shrinks to 1 chunk + manifest
        expect(
          backing.objectCount,
          2,
          reason: 'stale chunks from the larger write must be reclaimed',
        );
        expect(await chunked.read('k'), seq(10));
      });

      test('writeStream shrink deletes the tail chunks', () async {
        await chunked.writeStream('k', Stream.value(seq(200)));
        expect(backing.objectCount, 5);
        await chunked.writeStream('k', Stream.value(seq(10)));
        expect(
          backing.objectCount,
          2,
          reason:
              'stale chunks from the larger streamed write must be reclaimed',
        );
        expect(await chunked.read('k'), seq(10));
      });
    });

    group('round-trip', () {
      test('write then read returns identical bytes', () async {
        final data = seq(200);
        await chunked.write('a', data);
        expect(await chunked.read('a'), data);
      });

      test('writeStream produces the same content as write', () async {
        final data = seq(200);
        await chunked.writeStream('a', Stream.value(data));
        expect(await chunked.read('a'), data);
      });

      test('round-trips across boundary sizes', () async {
        for (final size in [
          0,
          1,
          chunkSize - 1,
          chunkSize,
          chunkSize + 1,
          chunkSize * 3,
          chunkSize * 10 + 7,
        ]) {
          final data = seq(size);
          await chunked.write('size-$size', data);
          expect(await chunked.read('size-$size'), data, reason: 'size=$size');
        }
      });
    });

    group('readRange', () {
      setUp(() async {
        await chunked.write('data', seq(200));
      });

      test('returns exact bytes inside one chunk', () async {
        expect(
          await chunked.readRange('data', start: 5, length: 10),
          Uint8List.fromList(List.generate(10, (i) => 5 + i)),
        );
      });

      test('returns exact bytes across two chunks', () async {
        // chunkSize=64; range 60..68 spans chunks 0 and 1.
        expect(
          await chunked.readRange('data', start: 60, length: 8),
          Uint8List.fromList(List.generate(8, (i) => 60 + i)),
        );
      });

      test('returns exact bytes across three chunks', () async {
        // 60..132 spans chunks 0, 1, 2.
        expect(
          await chunked.readRange('data', start: 60, length: 72),
          Uint8List.fromList(List.generate(72, (i) => 60 + i)),
        );
      });

      test('clamps when length runs past end', () async {
        // Total is 200; ask for 50 starting at 180 → only 20 bytes available.
        final out = await chunked.readRange('data', start: 180, length: 50);
        expect(out.length, 20);
      });

      test('returns empty for zero length', () async {
        expect(
          (await chunked.readRange('data', start: 0, length: 0)).length,
          0,
        );
      });

      test('throws FileNotFoundError on missing key', () async {
        expect(
          () => chunked.readRange('missing', start: 0, length: 1),
          throwsA(isA<FileNotFoundError>()),
        );
      });
    });

    group('atomicity', () {
      test('manifest written last makes partial writes invisible', () async {
        // ChunkedBackend writes chunks, then the manifest. After we yank
        // the manifest record out (simulating a crash mid-write), the key
        // should look like it never existed to head/exists/list/read.
        final data = seq(200);
        await chunked.write('a', data);

        // Find and delete the manifest record from the backing store.
        final all = await backing.list('');
        final manifestKey = all
            .firstWhere((info) => info.key.endsWith('__manifest'))
            .key;
        await backing.delete(manifestKey);

        expect(await chunked.exists('a'), isFalse);
        expect(await chunked.head('a'), isNull);
        expect(() => chunked.read('a'), throwsA(isA<FileNotFoundError>()));
      });

      test(
        'subsequent write to same key works after orphaned chunks',
        () async {
          final data = seq(200);
          await chunked.write('a', data);

          // Yank manifest.
          final manifestKey = (await backing.list(
            '',
          )).firstWhere((i) => i.key.endsWith('__manifest')).key;
          await backing.delete(manifestKey);

          // Write again — orphaned chunks should be cleaned up implicitly.
          await chunked.write('a', seq(50));
          expect(await chunked.read('a'), seq(50));
        },
      );
    });

    group('delete', () {
      test('delete removes manifest + all chunks', () async {
        await chunked.write('a', seq(200));
        final beforeCount = backing.objectCount;
        expect(beforeCount, greaterThan(1)); // multiple records

        await chunked.delete('a');
        expect(await chunked.exists('a'), isFalse);
        expect(backing.objectCount, 0);
      });

      test('deletePrefix removes chunked objects under the prefix', () async {
        await chunked.write('photos/a', seq(100));
        await chunked.write('photos/b', seq(100));
        await chunked.write('docs/c', seq(100));

        await chunked.deletePrefix('photos/');
        expect(await chunked.exists('photos/a'), isFalse);
        expect(await chunked.exists('photos/b'), isFalse);
        expect(await chunked.exists('docs/c'), isTrue);
      });
    });

    group('list + head', () {
      test('list returns one entry per logical key (not per chunk)', () async {
        await chunked.write('a', seq(200)); // 4 chunks
        await chunked.write('b', seq(50)); // 1 chunk

        final results = await chunked.list('');
        expect(results.length, 2);
        expect(results.map((i) => i.key).toSet(), {'a', 'b'});
      });

      test('head returns logical size (sum of chunks)', () async {
        await chunked.write('a', seq(200));
        final info = await chunked.head('a');
        expect(info!.size, 200);
      });

      test('lastModified is non-null on chunked head', () async {
        await chunked.write('a', seq(200));
        final info = await chunked.head('a');
        expect(info!.lastModified, isNotNull);
      });
    });
  });
}
