/// The Cellar facade: open/close, partitions, config forms, lifecycle
/// eviction — pure, runs on every platform.
library;

import '../harness/forwarding_backend.dart';
import '../harness/in_memory_backend.dart';
import 'dart:typed_data';
import 'package:cellar/cellar.dart';
import 'package:cellar/cellar_lowlevel.dart';
import 'package:test/test.dart';

void runCellarBattery() {
  _facade();
  _partitionConfig();
  _lifecycleConfig();
  _lifecycleEviction();
}

/// Test helper: construct + open an in-memory Cellar in one await.
Future<Cellar> _build({
  Map<String, StorageBackend>? backends,
  String defaultPartition = 'default',
  String? keyPrefix,
  Map<String, Lifecycle>? lifecycles,
}) async {
  final cellar = Cellar.withBackends(
    backends ?? {'default': InMemoryBackend()},
    defaultPartition: defaultPartition,
    keyPrefix: keyPrefix,
    lifecycles: lifecycles,
  );
  await cellar.open();
  return cellar;
}

void _facade() {
  group('Cellar', () {
    group('introspection', () {
      test('partitionNames lists every partition', () async {
        final cellar = await _build(
          backends: {'main': InMemoryBackend(), 'cache': InMemoryBackend()},
          defaultPartition: 'main',
        );
        expect(cellar.partitionNames.toSet(), {'main', 'cache'});
      });

      test('defaultPartition is what was passed', () async {
        final cellar = await _build(
          backends: {'a': InMemoryBackend(), 'b': InMemoryBackend()},
          defaultPartition: 'b',
        );
        expect(cellar.defaultPartition, 'b');
      });

      test('keyPrefix is null when unset', () async {
        final cellar = await _build();
        expect(cellar.keyPrefix, isNull);
      });

      test('keyPrefix is what was passed', () async {
        final cellar = await _build(keyPrefix: 'user/u1');
        expect(cellar.keyPrefix, 'user/u1');
      });
    });

    group('partition routing', () {
      late InMemoryBackend mainB;
      late InMemoryBackend cacheB;
      late Cellar cellar;
      setUp(() async {
        mainB = InMemoryBackend();
        cacheB = InMemoryBackend();
        cellar = await _build(
          backends: {'main': mainB, 'cache': cacheB},
          defaultPartition: 'main',
        );
      });

      test('write without partition goes to defaultPartition', () async {
        await cellar.write('k', Uint8List.fromList([1]));
        expect(await mainB.exists('k'), isTrue);
        expect(await cacheB.exists('k'), isFalse);
      });

      test('write with partition goes to that partition', () async {
        await cellar.write('k', Uint8List.fromList([2]), partition: 'cache');
        expect(await mainB.exists('k'), isFalse);
        expect(await cacheB.exists('k'), isTrue);
      });

      test('read with partition reads from that partition', () async {
        await cellar.write('k', Uint8List.fromList([3]), partition: 'cache');
        final out = await cellar.read('k', partition: 'cache');
        expect(out, Uint8List.fromList([3]));
      });

      test('reading from the wrong partition misses', () async {
        await cellar.write('k', Uint8List.fromList([4]), partition: 'cache');
        expect(
          () => cellar.read('k'), // default partition is 'main'
          throwsA(isA<FileNotFoundError>()),
        );
      });

      test('unknown partition throws ArgumentError', () async {
        expect(
          () =>
              cellar.write('k', Uint8List.fromList([1]), partition: 'missing'),
          throwsArgumentError,
        );
      });
    });

    group('keyPrefix tenant isolation', () {
      test('two Cellars with different keyPrefix see different data', () async {
        final shared = InMemoryBackend();
        final alice = await _build(
          backends: {'main': shared},
          defaultPartition: 'main',
          keyPrefix: 'user/alice',
        );
        final bob = await _build(
          backends: {'main': shared},
          defaultPartition: 'main',
          keyPrefix: 'user/bob',
        );
        await alice.write('notes/draft', Uint8List.fromList([1]));
        await bob.write('notes/draft', Uint8List.fromList([2]));

        expect(await alice.read('notes/draft'), Uint8List.fromList([1]));
        expect(await bob.read('notes/draft'), Uint8List.fromList([2]));
        // The shared backend has both keys with the prefixed names.
        expect(shared.objectCount, 2);
      });

      test('keyPrefix applies inside every partition', () async {
        final mainB = InMemoryBackend();
        final cacheB = InMemoryBackend();
        final cellar = await _build(
          backends: {'main': mainB, 'cache': cacheB},
          defaultPartition: 'main',
          keyPrefix: 'user/alice',
        );
        await cellar.write('a', Uint8List.fromList([1]));
        await cellar.write('b', Uint8List.fromList([2]), partition: 'cache');

        expect(await mainB.exists('user/alice/a'), isTrue);
        expect(await cacheB.exists('user/alice/b'), isTrue);
      });
    });

    group('list + listKeys honor keyPrefix and partition', () {
      late InMemoryBackend mainB;
      late Cellar alice;
      setUp(() async {
        mainB = InMemoryBackend();
        alice = await _build(
          backends: {'main': mainB},
          defaultPartition: 'main',
          keyPrefix: 'user/alice',
        );
        await alice.write('photos/a', Uint8List(1));
        await alice.write('photos/b', Uint8List(1));

        // Bob writes to the same backend; he must NOT show up in alice's list.
        final bob = await _build(
          backends: {'main': mainB},
          defaultPartition: 'main',
          keyPrefix: 'user/bob',
        );
        await bob.write('photos/c', Uint8List(1));
      });

      test('list returns only this tenants keys', () async {
        final results = await alice.list('photos/');
        // The tenant prefix exists at rest but must not leak into results
        // — a listed key round-trips into read() unchanged.
        expect(results.length, 2);
        for (final info in results) {
          expect(info.key, startsWith('photos/'));
          expect(info.key, isNot(contains('user/alice')));
        }
      });

      test('listKeys returns only this tenants keys', () async {
        final keys = await alice.listKeys('photos/');
        expect(keys.length, 2);
      });
    });

    group('cross-partition operations', () {
      late InMemoryBackend mainB;
      late InMemoryBackend cacheB;
      late Cellar cellar;
      setUp(() async {
        mainB = InMemoryBackend();
        cacheB = InMemoryBackend();
        cellar = await _build(
          backends: {'main': mainB, 'cache': cacheB},
          defaultPartition: 'main',
        );
      });

      test('copyAcrossPartitions duplicates bytes', () async {
        await cellar.write(
          'thumb/x',
          Uint8List.fromList([7, 8, 9]),
          partition: 'cache',
        );
        await cellar.copyAcrossPartitions(
          fromPartition: 'cache',
          fromKey: 'thumb/x',
          toPartition: 'main',
          toKey: 'final/x',
        );
        expect(await cellar.read('final/x'), Uint8List.fromList([7, 8, 9]));
        // Source still exists.
        expect(await cellar.exists('thumb/x', partition: 'cache'), isTrue);
      });

      test('moveAcrossPartitions copies then deletes source', () async {
        await cellar.write(
          'thumb/x',
          Uint8List.fromList([1, 2]),
          partition: 'cache',
        );
        await cellar.moveAcrossPartitions(
          fromPartition: 'cache',
          fromKey: 'thumb/x',
          toPartition: 'main',
          toKey: 'final/x',
        );
        expect(await cellar.exists('thumb/x', partition: 'cache'), isFalse);
        expect(await cellar.read('final/x'), Uint8List.fromList([1, 2]));
      });

      test('cross-partition operations preserve metadata', () async {
        await cellar.write(
          'src',
          Uint8List.fromList([1]),
          contentType: 'image/png',
          metadata: {'k': 'v'},
          partition: 'cache',
        );
        await cellar.copyAcrossPartitions(
          fromPartition: 'cache',
          fromKey: 'src',
          toPartition: 'main',
          toKey: 'dst',
        );
        final info = await cellar.head('dst');
        expect(info!.contentType, 'image/png');
        expect(info.metadata['k'], 'v');
      });
    });

    group('wipePartition + movePartition', () {
      test(
        'wipePartition clears a partition entirely (cross-tenant)',
        () async {
          final shared = InMemoryBackend();
          final alice = await _build(
            backends: {'cache': shared},
            defaultPartition: 'cache',
            keyPrefix: 'user/alice',
          );
          final bob = await _build(
            backends: {'cache': shared},
            defaultPartition: 'cache',
            keyPrefix: 'user/bob',
          );
          await alice.write('thumb/a', Uint8List(1));
          await bob.write('thumb/b', Uint8List(1));
          expect(shared.objectCount, 2);

          await alice.wipePartition('cache');
          // Bob's key is gone too — wipe ignores keyPrefix.
          expect(shared.objectCount, 0);
        },
      );

      test('deletePrefix honors keyPrefix (per-tenant cleanup)', () async {
        final shared = InMemoryBackend();
        final alice = await _build(
          backends: {'cache': shared},
          defaultPartition: 'cache',
          keyPrefix: 'user/alice',
        );
        final bob = await _build(
          backends: {'cache': shared},
          defaultPartition: 'cache',
          keyPrefix: 'user/bob',
        );
        await alice.write('thumb/a', Uint8List(1));
        await bob.write('thumb/b', Uint8List(1));

        await alice.deletePrefix('');
        // Alice's data is gone, Bob's remains.
        expect(await alice.exists('thumb/a'), isFalse);
        expect(await bob.exists('thumb/b'), isTrue);
      });

      test('movePartition migrates every key', () async {
        final src = InMemoryBackend();
        final dst = InMemoryBackend();
        final cellar = await _build(
          backends: {'src': src, 'dst': dst},
          defaultPartition: 'src',
        );
        await cellar.write('a', Uint8List.fromList([1]), partition: 'src');
        await cellar.write('b', Uint8List.fromList([2]), partition: 'src');

        await cellar.movePartition(fromPartition: 'src', toPartition: 'dst');
        expect(src.objectCount, 0);
        expect(dst.objectCount, 2);
        expect(
          await cellar.read('a', partition: 'dst'),
          Uint8List.fromList([1]),
        );
        expect(
          await cellar.read('b', partition: 'dst'),
          Uint8List.fromList([2]),
        );
      });

      test('movePartition with filter migrates only matching keys', () async {
        final src = InMemoryBackend();
        final dst = InMemoryBackend();
        final cellar = await _build(
          backends: {'src': src, 'dst': dst},
          defaultPartition: 'src',
        );
        await cellar.write('img/a', Uint8List.fromList([1]), partition: 'src');
        await cellar.write('img/b', Uint8List.fromList([2]), partition: 'src');
        await cellar.write(
          'audio/c',
          Uint8List.fromList([3]),
          partition: 'src',
        );

        await cellar.movePartition(
          fromPartition: 'src',
          toPartition: 'dst',
          filter: (key) => key.startsWith('img/'),
        );
        expect(await cellar.exists('img/a', partition: 'src'), isFalse);
        expect(await cellar.exists('img/b', partition: 'src'), isFalse);
        expect(await cellar.exists('audio/c', partition: 'src'), isTrue);
        expect(dst.objectCount, 2);
      });
    });

    group('within-partition copy / move via the facade', () {
      late InMemoryBackend backend;
      late Cellar cellar;
      setUp(() async {
        backend = InMemoryBackend();
        cellar = await _build(
          backends: {'main': backend},
          defaultPartition: 'main',
          keyPrefix: 'user/alice',
        );
      });

      test('copy duplicates within the partition + honors keyPrefix', () async {
        await cellar.write('photos/sunset', Uint8List.fromList([1, 2, 3]));
        await cellar.copy('photos/sunset', 'photos/sunset.bak');

        expect(
          await cellar.read('photos/sunset'),
          Uint8List.fromList([1, 2, 3]),
        );
        expect(
          await cellar.read('photos/sunset.bak'),
          Uint8List.fromList([1, 2, 3]),
        );
        // Both keys land under the keyPrefix on the underlying backend.
        expect(await backend.exists('user/alice/photos/sunset'), isTrue);
        expect(await backend.exists('user/alice/photos/sunset.bak'), isTrue);
      });

      test('copy preserves contentType + metadata', () async {
        await cellar.write(
          'a',
          Uint8List.fromList([1]),
          contentType: 'image/png',
          metadata: {'k': 'v'},
        );
        await cellar.copy('a', 'b');
        final info = await cellar.head('b');
        expect(info!.contentType, 'image/png');
        expect(info.metadata['k'], 'v');
      });

      test('move copies then deletes source', () async {
        await cellar.write('src', Uint8List.fromList([42]));
        await cellar.move('src', 'dst');
        expect(await cellar.exists('src'), isFalse);
        expect(await cellar.read('dst'), Uint8List.fromList([42]));
      });

      test('move into another partition is NOT what move does', () async {
        // `move` is within-partition only. Cross-partition is a separate
        // method (moveAcrossPartitions). This test documents the boundary.
        await cellar.write('src', Uint8List.fromList([1]));
        // No way to express cross-partition via `move`; the partition: param
        // applies to BOTH src and dst.
        await cellar.move('src', 'dst', partition: 'main');
        expect(await cellar.exists('src'), isFalse);
        expect(await cellar.exists('dst'), isTrue);
      });
    });

    group('updateMetadata via the facade', () {
      late InMemoryBackend backend;
      late Cellar cellar;
      setUp(() async {
        backend = InMemoryBackend();
        cellar = await _build(
          backends: {'main': backend},
          defaultPartition: 'main',
          keyPrefix: 'user/alice',
        );
      });

      test('rewrites contentType + metadata without touching body', () async {
        final body = Uint8List.fromList([1, 2, 3]);
        await cellar.write(
          'doc',
          body,
          contentType: 'text/plain',
          metadata: {'v': '1'},
        );
        await cellar.updateMetadata(
          'doc',
          contentType: 'application/json',
          metadata: {'v': '2', 'edited': '2026-01-01'},
        );
        // Body unchanged.
        expect(await cellar.read('doc'), body);
        // Metadata replaced (not merged).
        final info = await cellar.head('doc');
        expect(info!.contentType, 'application/json');
        expect(info.metadata['v'], '2');
        expect(info.metadata['edited'], '2026-01-01');
      });

      test('updateMetadata routes through the partition + keyPrefix', () async {
        await cellar.write('a', Uint8List.fromList([1]));
        await cellar.updateMetadata(
          'a',
          contentType: 'image/png',
          metadata: const {},
        );
        // The backend received the prefixed key.
        final info = await backend.head('user/alice/a');
        expect(info!.contentType, 'image/png');
      });
    });

    group('construction validation', () {
      test('withBackends rejects empty backend map', () {
        expect(
          () => Cellar.withBackends(const {}, defaultPartition: 'x'),
          throwsArgumentError,
        );
      });

      test('withBackends rejects unknown defaultPartition', () {
        expect(
          () => Cellar.withBackends({
            'main': InMemoryBackend(),
          }, defaultPartition: 'cache'),
          throwsArgumentError,
        );
      });
    });

    group('writeStream onProgress', () {
      test('facade forwards progress from a chunked stack', () async {
        final cellar = Cellar.withBackends({
          'default': ChunkedBackend(backing: InMemoryBackend()),
        }, defaultPartition: 'default');
        await cellar.open();
        final calls = <int>[];
        final payload = List<int>.generate(300, (i) => i & 0xFF);
        await cellar.writeStream(
          'big',
          Stream<List<int>>.fromIterable([
            payload.sublist(0, 120),
            payload.sublist(120),
          ]),
          onProgress: (written, total) {
            calls.add(written);
            expect(total, isNull, reason: 'stream totals are unknown');
          },
        );
        expect(calls, isNotEmpty);
        expect(calls.last, payload.length);
        expect(await cellar.read('big'), payload);
      });
    });

    group('open', () {
      test('concurrent open() calls share a single build', () async {
        // wipeOnOpen gives open() an observable side effect: exactly one
        // deletePrefix('') per real build. Unguarded concurrent opens
        // would both pass the _opened check and wipe (and build) twice.
        final counting = _DeleteCountingBackend(InMemoryBackend());
        final cellar = Cellar.withBackends(
          {'scratch': counting},
          defaultPartition: 'scratch',
          lifecycles: {'scratch': const Lifecycle(wipeOnOpen: true)},
        );
        await Future.wait([cellar.open(), cellar.open(), cellar.open()]);
        expect(counting.deletePrefixCalls, 1);
        expect(cellar.isOpen, isTrue);
      });

      test('open() after close throws StateError', () async {
        final cellar = await _build();
        await cellar.close();
        expect(cellar.open, throwsStateError);
      });
    });

    group('close', () {
      test('close on a Cellar without lifecycle is a no-op', () async {
        final cellar = await _build();
        await cellar.close();
      });

      test('close does NOT dispose caller-provided backends', () async {
        // Ownership rule: withBackends backends belong to the caller.
        final mine = InMemoryBackend();
        final cellar = await _build(backends: {'default': mine});
        await cellar.close();
        await mine.write('still-mine', Uint8List.fromList([1]));
        expect(await mine.exists('still-mine'), isTrue);
      });

      test('close stops the lifecycle runner', () async {
        final cellar = await _build(
          backends: {'cache': InMemoryBackend()},
          defaultPartition: 'cache',
          lifecycles: {
            'cache': const Lifecycle(
              maxBytes: 1024,
              runInterval: Duration(milliseconds: 100),
            ),
          },
        );
        await cellar.close();
        // Subsequent runLifecycleNow doesn't crash (runner is null).
        await cellar.runLifecycleNow();
      });
    });
  });
}

/// Counts deletePrefix calls — the observable side effect of a wipeOnOpen
/// build, used to prove concurrent open() shares one build.
class _DeleteCountingBackend extends ForwardingBackend {
  _DeleteCountingBackend(super.inner);

  int deletePrefixCalls = 0;

  @override
  Future<void> deletePrefix(String prefix) {
    deletePrefixCalls++;
    return super.deletePrefix(prefix);
  }
}

void _partitionConfig() {
  group('PartitionConfig', () {
    test('default constructor produces no lifecycle', () {
      const cfg = PartitionConfig();
      expect(cfg.lifecycle, isNull);
    });

    test('accepts a lifecycle', () {
      const cfg = PartitionConfig(lifecycle: Lifecycle.cache(maxBytes: 100));
      expect(cfg.lifecycle, isNotNull);
      expect(cfg.lifecycle!.maxBytes, 100);
    });
  });

  group('defaultPartitionName', () {
    test('is "default"', () {
      expect(defaultPartitionName, 'default');
    });
  });

  // Partition-name rules are enforced at Cellar construction time.
  // Cellar.withBackends is the cheapest surface to exercise them.
  group('partition name validation', () {
    test('accepts valid lowercase + digits + underscores', () {
      expect(
        () => Cellar.withBackends({
          'main': InMemoryBackend(),
          'image_cache': InMemoryBackend(),
          'cache_v2': InMemoryBackend(),
          'a': InMemoryBackend(),
        }, defaultPartition: 'main'),
        returnsNormally,
      );
    });

    test('rejects empty name', () {
      expect(
        () =>
            Cellar.withBackends({'': InMemoryBackend()}, defaultPartition: ''),
        throwsArgumentError,
      );
    });

    test('rejects uppercase', () {
      expect(
        () => Cellar.withBackends({
          'Main': InMemoryBackend(),
        }, defaultPartition: 'Main'),
        throwsArgumentError,
      );
    });

    test('rejects leading digit', () {
      expect(
        () => Cellar.withBackends({
          '1main': InMemoryBackend(),
        }, defaultPartition: '1main'),
        throwsArgumentError,
      );
    });

    test('rejects leading underscore', () {
      expect(
        () => Cellar.withBackends({
          '_main': InMemoryBackend(),
        }, defaultPartition: '_main'),
        throwsArgumentError,
      );
    });

    test('rejects hyphen', () {
      expect(
        () => Cellar.withBackends({
          'image-cache': InMemoryBackend(),
        }, defaultPartition: 'image-cache'),
        throwsArgumentError,
      );
    });

    test('rejects space', () {
      expect(
        () => Cellar.withBackends({
          'image cache': InMemoryBackend(),
        }, defaultPartition: 'image cache'),
        throwsArgumentError,
      );
    });

    test('rejects reserved "system_*" prefix', () {
      expect(
        () => Cellar.withBackends({
          'system_internal': InMemoryBackend(),
        }, defaultPartition: 'system_internal'),
        throwsArgumentError,
      );
    });
  });
}

void _lifecycleConfig() {
  group('Lifecycle', () {
    test('default constructor — no rules', () {
      const l = Lifecycle();
      expect(l.maxBytes, isNull);
      expect(l.maxAge, isNull);
      expect(l.wipeOnOpen, isFalse);
      expect(l.osManaged, isFalse);
      expect(l.runInterval, const Duration(hours: 1));
      expect(l.hasRules, isFalse);
    });

    test('hasRules: true when any rule is set', () {
      expect(const Lifecycle(maxBytes: 1).hasRules, isTrue);
      expect(const Lifecycle(maxAge: Duration(seconds: 1)).hasRules, isTrue);
      expect(const Lifecycle(wipeOnOpen: true).hasRules, isTrue);
    });

    group('Lifecycle.cache factory', () {
      test('osManaged defaults to true', () {
        const l = Lifecycle.cache();
        expect(l.osManaged, isTrue);
        expect(l.wipeOnOpen, isFalse);
      });

      test('honors maxBytes / maxAge / runInterval / osManaged: false', () {
        const l = Lifecycle.cache(
          maxBytes: 100,
          maxAge: Duration(days: 7),
          runInterval: Duration(minutes: 30),
          osManaged: false,
        );
        expect(l.maxBytes, 100);
        expect(l.maxAge, const Duration(days: 7));
        expect(l.runInterval, const Duration(minutes: 30));
        expect(l.osManaged, isFalse);
        expect(l.wipeOnOpen, isFalse);
      });

      test('hasRules false with no maxBytes / maxAge', () {
        const l = Lifecycle.cache();
        expect(l.hasRules, isFalse);
      });
    });

    group('Lifecycle.scratch factory', () {
      test('wipeOnOpen is true', () {
        const l = Lifecycle.scratch();
        expect(l.wipeOnOpen, isTrue);
        expect(l.hasRules, isTrue);
      });

      test('osManaged defaults to true; can be overridden', () {
        const a = Lifecycle.scratch();
        expect(a.osManaged, isTrue);
        const b = Lifecycle.scratch(osManaged: false);
        expect(b.osManaged, isFalse);
      });

      test('no maxBytes or maxAge', () {
        const l = Lifecycle.scratch();
        expect(l.maxBytes, isNull);
        expect(l.maxAge, isNull);
      });
    });
  });
}

void _lifecycleEviction() {
  group('Lifecycle rules', () {
    group('maxBytes eviction', () {
      test('evicts oldest items until under cap', () async {
        final backend = InMemoryBackend();
        final cellar = Cellar.withBackends(
          {'cache': backend},
          defaultPartition: 'cache',
          lifecycles: {'cache': const Lifecycle(maxBytes: 100)},
        );
        await cellar.open();

        // Write 5 items × 50 bytes = 250 bytes total. Max is 100 → 3 must evict.
        for (var i = 0; i < 5; i++) {
          await cellar.write('item-$i', Uint8List(50));
          // Stagger ages so eviction is deterministic.
          backend.setLastModified('item-$i', DateTime.utc(2026, 1, 1, 0, 0, i));
        }
        expect(backend.totalBytes, 250);

        await cellar.runLifecycleNow();

        // Oldest items (0, 1, 2) should be evicted; (3, 4) survive at 100 bytes.
        expect(backend.totalBytes, lessThanOrEqualTo(100));
        expect(await cellar.exists('item-3'), isTrue);
        expect(await cellar.exists('item-4'), isTrue);
        expect(await cellar.exists('item-0'), isFalse);

        await cellar.close();
      });

      test('no eviction when under cap', () async {
        final backend = InMemoryBackend();
        final cellar = Cellar.withBackends(
          {'cache': backend},
          defaultPartition: 'cache',
          lifecycles: {'cache': const Lifecycle(maxBytes: 1000)},
        );
        await cellar.open();

        await cellar.write('a', Uint8List(50));
        await cellar.runLifecycleNow();

        expect(await cellar.exists('a'), isTrue);
        await cellar.close();
      });
    });

    group('maxAge eviction', () {
      test('evicts items older than maxAge', () async {
        final backend = InMemoryBackend();
        final cellar = Cellar.withBackends(
          {'cache': backend},
          defaultPartition: 'cache',
          lifecycles: {'cache': const Lifecycle(maxAge: Duration(days: 7))},
        );
        await cellar.open();

        await cellar.write('old', Uint8List(1));
        await cellar.write('new', Uint8List(1));

        // Force one item to be 30 days old, the other to be fresh.
        final now = DateTime.now().toUtc();
        backend.setLastModified('old', now.subtract(const Duration(days: 30)));
        backend.setLastModified('new', now);

        await cellar.runLifecycleNow();

        expect(await cellar.exists('old'), isFalse);
        expect(await cellar.exists('new'), isTrue);

        await cellar.close();
      });

      test('no eviction when all items younger than maxAge', () async {
        final backend = InMemoryBackend();
        final cellar = Cellar.withBackends(
          {'cache': backend},
          defaultPartition: 'cache',
          lifecycles: {'cache': const Lifecycle(maxAge: Duration(days: 7))},
        );
        await cellar.open();

        await cellar.write('a', Uint8List(1));
        await cellar.write('b', Uint8List(1));
        await cellar.runLifecycleNow();

        expect(await cellar.exists('a'), isTrue);
        expect(await cellar.exists('b'), isTrue);

        await cellar.close();
      });
    });

    group('wipeOnOpen', () {
      test('wipes the partition during cellar.open()', () async {
        final backend = InMemoryBackend();
        // Pre-populate the backend before opening the Cellar.
        await backend.write('leftover', Uint8List(1));
        expect(backend.objectCount, 1);

        final cellar = Cellar.withBackends(
          {'scratch': backend},
          defaultPartition: 'scratch',
          lifecycles: {'scratch': const Lifecycle(wipeOnOpen: true)},
        );
        // open() runs wipeOnOpen before any user calls land.
        await cellar.open();

        expect(backend.objectCount, 0);

        await cellar.close();
      });
    });

    group('multiple partitions', () {
      test('only partitions with rules are evaluated', () async {
        final cacheB = InMemoryBackend();
        final mainB = InMemoryBackend();
        final cellar = Cellar.withBackends(
          {'cache': cacheB, 'main': mainB},
          defaultPartition: 'main',
          lifecycles: {
            // Only 'cache' has a lifecycle.
            'cache': const Lifecycle(maxBytes: 50),
          },
        );
        await cellar.open();

        await cellar.write('a', Uint8List(100), partition: 'cache');
        await cellar.write('b', Uint8List(100), partition: 'main');

        await cellar.runLifecycleNow();

        // Cache was over cap → evicted. Main has no rules → untouched.
        expect(cacheB.objectCount, 0);
        expect(mainB.objectCount, 1);

        await cellar.close();
      });
    });

    group('runLifecycleNow on a cellar with no rules', () {
      test('is a safe no-op', () async {
        final cellar = Cellar.withBackends({
          'main': InMemoryBackend(),
        }, defaultPartition: 'main');
        await cellar.open();

        await cellar.runLifecycleNow(); // does not throw

        await cellar.close();
      });
    });
  });

  group('lifecycle eviction', () {
    Uint8List sized(int n) => Uint8List.fromList(List<int>.filled(n, 7));

    test('age eviction removes only objects older than maxAge', () async {
      final backing = InMemoryBackend();
      final cellar = Cellar.withBackends(
        {'cache': backing},
        defaultPartition: 'cache',
        lifecycles: {
          'cache': const Lifecycle(
            maxAge: Duration(days: 7),
            runInterval: Duration(days: 1),
          ),
        },
      );
      await cellar.open();

      await cellar.write('old', sized(10));
      await cellar.write('fresh', sized(10));
      // Back-date one object past the cutoff — no real waits, no fake
      // sleeps; the runner compares against lastModified.
      backing.setLastModified(
        'old',
        DateTime.now().toUtc().subtract(const Duration(days: 8)),
      );

      await cellar.runLifecycleNow();
      expect(await cellar.exists('old'), isFalse);
      expect(await cellar.exists('fresh'), isTrue);
    });

    test('size eviction removes oldest first until under the cap', () async {
      final backing = InMemoryBackend();
      final cellar = Cellar.withBackends(
        {'cache': backing},
        defaultPartition: 'cache',
        lifecycles: {
          'cache': const Lifecycle(
            maxBytes: 25,
            runInterval: Duration(days: 1),
          ),
        },
      );
      await cellar.open();

      await cellar.write('a', sized(10));
      await cellar.write('b', sized(10));
      await cellar.write('c', sized(10));
      backing.setLastModified('a', DateTime.utc(2020));
      backing.setLastModified('b', DateTime.utc(2021));
      backing.setLastModified('c', DateTime.utc(2022));

      await cellar.runLifecycleNow();
      // 30 bytes > 25 → evict 'a' (oldest) → 20 ≤ 25, stop.
      expect(await cellar.exists('a'), isFalse);
      expect(await cellar.exists('b'), isTrue);
      expect(await cellar.exists('c'), isTrue);
    });

    test('a stuck victim is skipped, reported, and does not shield newer '
        'objects from the cap', () async {
      final backing = _StickyKeyBackend(InMemoryBackend(), stuckKey: 'b');
      final errors = <(String, String?, Object)>[];
      final cellar = Cellar.withBackends(
        {'cache': backing},
        defaultPartition: 'cache',
        lifecycles: {
          'cache': const Lifecycle(maxBytes: 5, runInterval: Duration(days: 1)),
        },
        onEvictionError: (partition, key, error) =>
            errors.add((partition, key, error)),
      );
      await cellar.open();

      await cellar.write('a', sized(10));
      await cellar.write('b', sized(10));
      await cellar.write('c', sized(10));
      backing.setLastModified2('a', DateTime.utc(2020));
      backing.setLastModified2('b', DateTime.utc(2021));
      backing.setLastModified2('c', DateTime.utc(2022));

      await cellar.runLifecycleNow();
      // Cap 5 needs everything gone; 'b' refuses. Without skip-and-
      // continue, the old break-on-failure left 'c' untouched too.
      expect(await cellar.exists('a'), isFalse);
      expect(await cellar.exists('b'), isTrue);
      expect(await cellar.exists('c'), isFalse);

      expect(errors, hasLength(1));
      expect(errors.single.$1, 'cache');
      expect(errors.single.$2, 'b');
    });
  });
}

/// Refuses to delete one specific key — models a held/locked object.
class _StickyKeyBackend extends ForwardingBackend {
  _StickyKeyBackend(InMemoryBackend super.inner, {required this.stuckKey});

  final String stuckKey;

  /// Forwarded test hook (the scope wraps this backend, hiding the
  /// in-memory helper's own).
  void setLastModified2(String key, DateTime when) =>
      (inner as InMemoryBackend).setLastModified(key, when);

  @override
  Future<void> delete(String key) {
    if (key == stuckKey) throw StateError('object is held');
    return super.delete(key);
  }
}
