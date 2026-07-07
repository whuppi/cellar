import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:cellar/cellar_lowlevel.dart';

import '../harness/in_memory_backend.dart';

/// StorageScope key-prefixing — pure, runs on every platform.
void runScopeBattery() {
  group('StorageScope', () {
    late InMemoryBackend backend;

    setUp(() {
      backend = InMemoryBackend();
    });

    group('keyPrefix', () {
      test('null keyPrefix → keys reach the backend unchanged', () async {
        final scope = StorageScope(backend);
        await scope.write('photos/sunset', Uint8List.fromList([1]));
        expect(await backend.exists('photos/sunset'), isTrue);
      });

      test(
        'with keyPrefix → keys are prefixed before reaching backend',
        () async {
          final scope = StorageScope(backend, keyPrefix: 'user/u1');
          await scope.write('photos/sunset', Uint8List.fromList([1]));
          expect(await backend.exists('user/u1/photos/sunset'), isTrue);
          expect(await backend.exists('photos/sunset'), isFalse);
        },
      );

      test('two scopes with different prefixes are isolated', () async {
        final alice = StorageScope(backend, keyPrefix: 'user/alice');
        final bob = StorageScope(backend, keyPrefix: 'user/bob');
        await alice.write('notes/draft', Uint8List.fromList([1]));
        await bob.write('notes/draft', Uint8List.fromList([2]));

        expect(await alice.read('notes/draft'), Uint8List.fromList([1]));
        expect(await bob.read('notes/draft'), Uint8List.fromList([2]));
      });

      test('two scopes with the same prefix share data', () async {
        final a = StorageScope(backend, keyPrefix: 'shared');
        final b = StorageScope(backend, keyPrefix: 'shared');
        await a.write('item', Uint8List.fromList([42]));
        expect(await b.read('item'), Uint8List.fromList([42]));
      });

      test('key() / prefix() helpers expose the prefixed form', () {
        final scoped = StorageScope(backend, keyPrefix: 'user/u1');
        expect(scoped.key('photos/sunset'), 'user/u1/photos/sunset');
        expect(scoped.prefix('photos/'), 'user/u1/photos/');

        final bare = StorageScope(backend);
        expect(bare.key('photos/sunset'), 'photos/sunset');
        expect(bare.prefix('photos/'), 'photos/');
      });
    });

    group('write + read', () {
      late StorageScope scope;
      setUp(() {
        scope = StorageScope(backend, keyPrefix: 'test');
      });

      test('write then read returns same bytes', () async {
        final data = Uint8List.fromList([10, 20, 30, 40, 50]);
        await scope.write('file', data);
        expect(await scope.read('file'), data);
      });

      test('writeStream then read returns concatenated bytes', () async {
        final chunks = [
          Uint8List.fromList([1, 2]),
          Uint8List.fromList([3, 4]),
        ];
        await scope.writeStream('streamed', Stream.fromIterable(chunks));
        expect(await scope.read('streamed'), Uint8List.fromList([1, 2, 3, 4]));
      });

      test('readStream yields the data', () async {
        await scope.write('file', Uint8List.fromList([5, 6, 7]));
        final out = <int>[];
        await for (final chunk in scope.readStream('file')) {
          out.addAll(chunk);
        }
        expect(out, [5, 6, 7]);
      });

      test('readRange returns the requested slice', () async {
        await scope.write(
          'data',
          Uint8List.fromList(List.generate(10, (i) => i)),
        );
        final slice = await scope.readRange('data', start: 3, length: 4);
        expect(slice, Uint8List.fromList([3, 4, 5, 6]));
      });

      test('write with WriteOptions passes contentType + metadata', () async {
        await scope.write(
          'doc',
          Uint8List.fromList([1]),
          const WriteOptions(
            contentType: 'text/plain',
            metadata: {'custom': 'value'},
          ),
        );
        final info = await scope.head('doc');
        expect(info, isNotNull);
        expect(info!.contentType, 'text/plain');
        expect(info.metadata['custom'], 'value');
      });
    });

    group('metadata + presence', () {
      late StorageScope scope;
      setUp(() {
        scope = StorageScope(backend, keyPrefix: 'test');
      });

      test('head returns null for missing', () async {
        expect(await scope.head('missing'), isNull);
      });

      test('exists tracks writes and deletes', () async {
        expect(await scope.exists('a'), isFalse);
        await scope.write('a', Uint8List.fromList([1]));
        expect(await scope.exists('a'), isTrue);
        await scope.delete('a');
        expect(await scope.exists('a'), isFalse);
      });
    });

    group('list + listKeys', () {
      late StorageScope scope;
      setUp(() async {
        scope = StorageScope(backend, keyPrefix: 'test');
        await scope.write('a', Uint8List.fromList([1]));
        await scope.write('b', Uint8List.fromList([2]));
        await scope.write('subdir/c', Uint8List.fromList([3]));
      });

      test('list returns ObjectInfo for matching keys', () async {
        final all = await scope.list('');
        expect(all.length, 3);
      });

      test('list filters by prefix and returns scope-relative keys', () async {
        final sub = await scope.list('subdir/');
        expect(sub.length, 1);
        expect(sub.first.key, 'subdir/c');
      });

      test('listKeys returns just the keys', () async {
        final keys = await scope.listKeys('');
        expect(keys.length, 3);
      });
    });

    group('copy + move', () {
      late StorageScope scope;
      setUp(() {
        scope = StorageScope(backend, keyPrefix: 'test');
      });

      test('copy duplicates bytes + metadata', () async {
        await scope.write(
          'a',
          Uint8List.fromList([1, 2, 3]),
          const WriteOptions(contentType: 'image/png'),
        );
        await scope.copy('a', 'b');
        expect(await scope.read('b'), Uint8List.fromList([1, 2, 3]));
        final info = await scope.head('b');
        expect(info!.contentType, 'image/png');
      });

      test('move copies then deletes source', () async {
        await scope.write('a', Uint8List.fromList([9]));
        await scope.move('a', 'b');
        expect(await scope.exists('a'), isFalse);
        expect(await scope.read('b'), Uint8List.fromList([9]));
      });
    });

    group('utilities', () {
      late StorageScope scope;
      setUp(() {
        scope = StorageScope(backend, keyPrefix: 'test');
      });

      test('totalSize sums file sizes under a prefix', () async {
        await scope.write('a', Uint8List(10));
        await scope.write('b', Uint8List(20));
        await scope.write('other/c', Uint8List(30));
        expect(await scope.totalSize(''), 60);
        expect(await scope.totalSize('other/'), 30);
      });

      test('fileSize returns the size of one file', () async {
        await scope.write('x', Uint8List(42));
        expect(await scope.fileSize('x'), 42);
      });

      test('fileSize returns 0 for missing', () async {
        expect(await scope.fileSize('missing'), 0);
      });
    });

    group('key validation', () {
      test('write rejects an invalid key', () async {
        final scope = StorageScope(backend);
        expect(
          () => scope.write('/leading-slash', Uint8List(0)),
          throwsA(isA<InvalidKeyError>()),
        );
      });

      test('read rejects an invalid key', () async {
        final scope = StorageScope(backend);
        expect(
          () => scope.read('../traverse'),
          throwsA(isA<InvalidKeyError>()),
        );
      });
    });
  });
  group('StorageScope result keys are scope-relative', () {
    test('listed keys round-trip into read unchanged', () async {
      final backend = InMemoryBackend();
      final scope = StorageScope(backend, keyPrefix: 'user/alice');
      await scope.write('photos/cat', Uint8List.fromList([1, 2, 3]));

      final listed = await scope.list('');
      expect(
        listed.single.key,
        'photos/cat',
        reason: 'the tenant prefix must not leak into results',
      );
      expect(await scope.read(listed.single.key), [1, 2, 3]);

      final keys = await scope.listKeys('');
      expect(keys, ['photos/cat']);

      final info = await scope.head('photos/cat');
      expect(info!.key, 'photos/cat');
    });

    test('unscoped scope passes keys through untouched', () async {
      final backend = InMemoryBackend();
      final scope = StorageScope(backend);
      await scope.write('a/b', Uint8List.fromList([9]));
      expect((await scope.list('')).single.key, 'a/b');
    });
  });
}
