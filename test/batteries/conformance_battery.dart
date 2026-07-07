import 'dart:convert';
import 'dart:typed_data';

import 'package:cellar/cellar_lowlevel.dart';
import 'package:test/test.dart';

/// The [StorageBackend] contract, as an executable specification.
///
/// Every backend cellar ships — Local, IndexedDb, Chunked, Encrypted, plus
/// any custom [StorageBackend] — must pass this suite identically. That
/// uniformity is the entire point of the interface: `on FileNotFoundError`,
/// prefix listing, metadata round-trips, and range reads must mean the same
/// thing on every substrate. Divergence is a bug in the backend, not a reason
/// to loosen the contract.
///
/// Invoke once per backend from a test file (see `conformance_test.dart` for
/// the VM backends and the web runner for IndexedDb).
///
/// [create] must return a fresh, empty backend for each test. [supportsMaterialize]
/// gates the platform-handle cases: an in-memory store and a bare
/// [ChunkedBackend] have no filesystem path or Blob URL to hand out, so they
/// pass `false`.
void runStorageBackendConformance(
  String label, {
  required StorageBackend Function() create,
  bool supportsMaterialize = false,
}) {
  group('StorageBackend conformance — $label', () {
    late StorageBackend backend;
    setUp(() => backend = create());

    Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));
    Uint8List sized(int n) =>
        Uint8List.fromList(List<int>.generate(n, (i) => i & 0xFF));

    Future<Uint8List> drain(Stream<List<int>> s) async {
      final out = BytesBuilder(copy: false);
      await for (final chunk in s) {
        out.add(chunk);
      }
      return out.takeBytes();
    }

    // ── Round-trip ──────────────────────────────────────────────────────
    group('round-trip', () {
      test('write then read returns the same bytes', () async {
        final data = bytes('hello world');
        await backend.write('a/b', data);
        expect(await backend.read('a/b'), equals(data));
      });

      test('empty object round-trips', () async {
        await backend.write('empty', Uint8List(0));
        expect(await backend.read('empty'), isEmpty);
        expect((await backend.head('empty'))!.size, 0);
      });

      test('multi-chunk object round-trips (200 KiB)', () async {
        final data = sized(200 * 1024);
        await backend.write('big', data);
        expect(await backend.read('big'), equals(data));
        expect((await backend.head('big'))!.size, data.length);
      });

      test('writeStream then readStream returns the same bytes', () async {
        final data = sized(200 * 1024);
        await backend.writeStream('s', Stream<List<int>>.value(data));
        expect(await drain(backend.readStream('s')), equals(data));
      });

      test('overwrite replaces the prior content', () async {
        await backend.write('k', bytes('first'));
        await backend.write('k', bytes('second'));
        expect(await backend.read('k'), equals(bytes('second')));
      });
    });

    // ── Concurrency + cancellation ──────────────────────────────────────
    group('concurrent and cancelled operations', () {
      test('parallel writes to distinct keys all land intact', () async {
        await Future.wait([
          for (var i = 0; i < 8; i++)
            backend.write('par/$i', sized(10 * 1024 + i)),
        ]);
        for (var i = 0; i < 8; i++) {
          expect(await backend.read('par/$i'), equals(sized(10 * 1024 + i)));
        }
      });

      test('cancelling a readStream mid-flight corrupts nothing', () async {
        final data = sized(200 * 1024);
        await backend.write('c', data);
        // Take the first event, then cancel the subscription.
        final first = await backend.readStream('c').first;
        expect(first, isNotEmpty);
        // The object must be fully readable afterwards.
        expect(await backend.read('c'), equals(data));
      });
    });

    // ── Write atomicity — a failed stream never leaves a torn object ────
    group('failed writeStream', () {
      Stream<List<int>> failingSource() async* {
        // Enough bytes to cross chunk boundaries on chunked stores.
        yield sized(100 * 1024);
        yield sized(60 * 1024);
        throw StateError('source died mid-stream');
      }

      test('leaves the previous object fully intact', () async {
        final original = sized(150 * 1024);
        await backend.write('w', original);
        await expectLater(
          backend.writeStream('w', failingSource()),
          throwsA(anything),
        );
        expect(
          await backend.read('w'),
          equals(original),
          reason:
              'a failed overwrite must serve the old object, never a '
              'torn mix of old and new bytes',
        );
        expect((await backend.head('w'))!.size, original.length);
      });

      test('leaves no readable object on a failed first write', () async {
        await expectLater(
          backend.writeStream('fresh', failingSource()),
          throwsA(anything),
        );
        expect(await backend.exists('fresh'), isFalse);
        expect(await backend.head('fresh'), isNull);
      });
    });

    // ── Typed errors on a missing key ───────────────────────────────────
    group('missing key', () {
      test('read throws FileNotFoundError', () {
        expect(backend.read('nope'), throwsA(isA<FileNotFoundError>()));
      });
      test('readStream throws FileNotFoundError', () {
        expect(
          drain(backend.readStream('nope')),
          throwsA(isA<FileNotFoundError>()),
        );
      });
      test('readRange throws FileNotFoundError', () {
        expect(
          backend.readRange('nope', start: 0, length: 1),
          throwsA(isA<FileNotFoundError>()),
        );
      });
      test('head returns null', () async {
        expect(await backend.head('nope'), isNull);
      });
      test('exists returns false', () async {
        expect(await backend.exists('nope'), isFalse);
      });
      test('delete of a missing key is a no-op', () async {
        await backend.delete('nope'); // must not throw
      });
    });

    // ── Metadata contract ───────────────────────────────────────────────
    group('metadata', () {
      test('head reports every non-null contract field', () async {
        await backend.write(
          'm',
          bytes('x'),
          const WriteOptions(contentType: 'text/plain', metadata: {'k': 'v'}),
        );
        final info = (await backend.head('m'))!;
        expect(info.key, 'm');
        expect(info.size, 1);
        expect(info.contentType, 'text/plain');
        expect(info.metadata['k'], 'v');
        // ObjectInfo.lastModified is documented as UTC on every backend.
        expect(
          info.lastModified.isUtc,
          isTrue,
          reason: 'ObjectInfo.lastModified must be UTC',
        );
      });

      test('contentType + metadata round-trip through list', () async {
        await backend.write(
          'p/1',
          bytes('a'),
          const WriteOptions(contentType: 'image/png', metadata: {'tag': 't'}),
        );
        final info = (await backend.list(
          'p/',
        )).firstWhere((o) => o.key == 'p/1');
        expect(info.contentType, 'image/png');
        expect(info.metadata['tag'], 't');
      });

      test('exists is true after write, false after delete', () async {
        await backend.write('e', bytes('x'));
        expect(await backend.exists('e'), isTrue);
        await backend.delete('e');
        expect(await backend.exists('e'), isFalse);
        expect(await backend.head('e'), isNull);
      });
    });

    // ── updateMetadata — replace semantics ──────────────────────────────
    group('updateMetadata', () {
      test('replaces contentType + metadata and leaves bytes intact', () async {
        await backend.write(
          'u',
          bytes('body'),
          const WriteOptions(contentType: 'a/a', metadata: {'old': '1'}),
        );
        await backend.updateMetadata(
          'u',
          contentType: 'b/b',
          metadata: {'new': '2'},
        );
        final info = (await backend.head('u'))!;
        expect(info.contentType, 'b/b');
        expect(info.metadata['new'], '2');
        expect(
          info.metadata.containsKey('old'),
          isFalse,
          reason: 'updateMetadata replaces, it does not merge',
        );
        expect(
          await backend.read('u'),
          equals(bytes('body')),
          reason: 'updateMetadata must not touch the object bytes',
        );
        // The bytes must stay reachable through EVERY read path after a
        // metadata update — on encrypted backends this catches an internal
        // flag being wiped, which would make readStream/head see ciphertext.
        expect(
          await drain(backend.readStream('u')),
          equals(bytes('body')),
          reason: 'readStream must survive a metadata update',
        );
        expect(
          (await backend.head('u'))!.size,
          bytes('body').length,
          reason: 'head must still report the original size after update',
        );
      });
    });

    // ── list + deletePrefix — RAW string-prefix contract (S3-style) ─────
    group('list and deletePrefix', () {
      test('list returns exactly the objects under a prefix', () async {
        await backend.write('d/1', bytes('1'));
        await backend.write('d/2', bytes('2'));
        await backend.write('other/3', bytes('3'));
        final keys = (await backend.list('d/')).map((o) => o.key).toSet();
        expect(keys, {'d/1', 'd/2'});
      });

      test('deletePrefix removes the whole subtree, nothing else', () async {
        await backend.write('x/1', bytes('1'));
        await backend.write('x/y/2', bytes('2'));
        await backend.write('keep/3', bytes('3'));
        await backend.deletePrefix('x/');
        expect(await backend.exists('x/1'), isFalse);
        expect(await backend.exists('x/y/2'), isFalse);
        expect(await backend.exists('keep/3'), isTrue);
      });
    });

    group('raw string-prefix contract', () {
      // Prefixes are raw string prefixes on every backend, S3-style: a
      // bare prefix crosses segment boundaries; a '/'-terminated prefix
      // scopes to the pseudo-directory. Divergence here is exactly the
      // cross-backend drift the contract exists to prevent.
      setUp(() async {
        await backend.write('pre/x', bytes('1'));
        await backend.write('pre2', bytes('2')); // single-segment sibling
        await backend.write('pre_old/y', bytes('3')); // partial-segment dir
        await backend.write('other/z', bytes('4'));
      });

      test('bare prefix matches every raw-prefixed key', () async {
        final keys = (await backend.list('pre')).map((o) => o.key).toSet();
        expect(keys, {'pre/x', 'pre2', 'pre_old/y'});
      });

      test('slash-terminated prefix scopes to the pseudo-directory', () async {
        final keys = (await backend.list('pre/')).map((o) => o.key).toSet();
        expect(keys, {'pre/x'});
      });

      test('empty prefix lists everything', () async {
        final keys = (await backend.list('')).map((o) => o.key).toSet();
        expect(keys, {'pre/x', 'pre2', 'pre_old/y', 'other/z'});
      });

      test('bare deletePrefix removes every raw match, nothing else', () async {
        await backend.deletePrefix('pre');
        expect(await backend.exists('pre/x'), isFalse);
        expect(await backend.exists('pre2'), isFalse);
        expect(await backend.exists('pre_old/y'), isFalse);
        expect(await backend.exists('other/z'), isTrue);
      });

      test('slash-terminated deletePrefix removes only the subtree', () async {
        await backend.deletePrefix('pre/');
        expect(await backend.exists('pre/x'), isFalse);
        expect(await backend.exists('pre2'), isTrue);
        expect(await backend.exists('pre_old/y'), isTrue);
      });
    });

    // ── copy ────────────────────────────────────────────────────────────
    group('copy', () {
      test('copies bytes + metadata; the source survives', () async {
        await backend.write(
          'src',
          bytes('payload'),
          const WriteOptions(contentType: 'c/t', metadata: {'m': '1'}),
        );
        await backend.copy('src', 'dst');
        expect(await backend.read('dst'), equals(bytes('payload')));
        expect(await backend.read('src'), equals(bytes('payload')));
        final info = (await backend.head('dst'))!;
        expect(info.contentType, 'c/t');
        expect(info.metadata['m'], '1');
      });
    });

    // ── readRange ───────────────────────────────────────────────────────
    group('readRange', () {
      final full = sized(300 * 1024); // spans several chunks on chunked stores
      setUp(() => backend.write('r', full));

      test('reads from the start', () async {
        expect(
          await backend.readRange('r', start: 0, length: 10),
          equals(full.sublist(0, 10)),
        );
      });
      test('reads a mid-file slice crossing a chunk boundary', () async {
        expect(
          await backend.readRange('r', start: 60 * 1024, length: 128 * 1024),
          equals(full.sublist(60 * 1024, 60 * 1024 + 128 * 1024)),
        );
      });
      test('reads the tail', () async {
        expect(
          await backend.readRange('r', start: full.length - 5, length: 5),
          equals(full.sublist(full.length - 5)),
        );
      });
      test('an over-length read clamps to the available bytes', () async {
        expect(
          await backend.readRange('r', start: full.length - 5, length: 1000),
          equals(full.sublist(full.length - 5)),
        );
      });
    });

    // ── materialize (only where the backend can hand out a handle) ───────
    if (supportsMaterialize) {
      group('materialize', () {
        test('a missing key throws FileNotFoundError', () {
          expect(
            backend.materialize('nope'),
            throwsA(isA<FileNotFoundError>()),
          );
        });
      });
    }

    // ── dispose lifecycle ────────────────────────────────────────────────
    group('dispose', () {
      test('is idempotent', () async {
        await backend.dispose();
        await backend.dispose();
      });

      test('every operation throws StateError afterwards', () async {
        await backend.write('d', bytes('x'));
        await backend.dispose();
        expect(() => backend.write('d', bytes('y')), throwsStateError);
        expect(() => backend.read('d'), throwsStateError);
        expect(backend.readStream('d').toList, throwsStateError);
        expect(
          () => backend.readRange('d', start: 0, length: 1),
          throwsStateError,
        );
        expect(() => backend.head('d'), throwsStateError);
        expect(() => backend.exists('d'), throwsStateError);
        expect(() => backend.delete('d'), throwsStateError);
        expect(() => backend.deletePrefix(''), throwsStateError);
        expect(() => backend.list(''), throwsStateError);
        expect(() => backend.copy('d', 'e'), throwsStateError);
        expect(() => backend.updateMetadata('d'), throwsStateError);
        expect(() => backend.materialize('d'), throwsStateError);
      });
    });
  });
}
