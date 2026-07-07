import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:cellar/cellar.dart';

import '../../harness/temp_dir.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await makeTempDir('cellar_atpath_');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  group('Cellar.atPath', () {
    test('default partition writes to {path}/default', () async {
      final cellar = Cellar.atPath(tempDir.path, name: 'exports');
      await cellar.open();

      await cellar.write('a', Uint8List.fromList([1, 2, 3]));
      expect(
        File('${tempDir.path}/default/a').existsSync(),
        isTrue,
        reason: 'default partition should land under {path}/default/',
      );

      await cellar.close();
    });

    test('multi-partition lays out as {path}/{partition}/...', () async {
      final cellar = Cellar.atPath(
        tempDir.path,
        name: 'exports',
        partitions: {
          'main': const PartitionConfig(),
          'cache': const PartitionConfig(),
        },
        defaultPartition: 'main',
      );
      await cellar.open();

      await cellar.write('a', Uint8List.fromList([1]));
      await cellar.write('b', Uint8List.fromList([2]), partition: 'cache');

      expect(File('${tempDir.path}/main/a').existsSync(), isTrue);
      expect(File('${tempDir.path}/cache/b').existsSync(), isTrue);

      await cellar.close();
    });

    test('keyPrefix prefixes keys in every partition', () async {
      final cellar = Cellar.atPath(
        tempDir.path,
        name: 'exports',
        partitions: {
          'main': const PartitionConfig(),
          'cache': const PartitionConfig(),
        },
        defaultPartition: 'main',
        keyPrefix: 'user/alice',
      );
      await cellar.open();

      await cellar.write('photos/x', Uint8List.fromList([1]));
      await cellar.write(
        'thumb/y',
        Uint8List.fromList([2]),
        partition: 'cache',
      );

      expect(
        File('${tempDir.path}/main/user/alice/photos/x').existsSync(),
        isTrue,
      );
      expect(
        File('${tempDir.path}/cache/user/alice/thumb/y').existsSync(),
        isTrue,
      );

      await cellar.close();
    });

    test('rejects unknown defaultPartition', () {
      expect(
        () => Cellar.atPath(
          tempDir.path,
          name: 'exports',
          partitions: {'main': const PartitionConfig()},
          defaultPartition: 'cache',
        ),
        throwsArgumentError,
      );
    });

    test('rejects invalid partition names', () {
      expect(
        () => Cellar.atPath(
          tempDir.path,
          name: 'exports',
          partitions: {'Main': const PartitionConfig()},
          defaultPartition: 'Main',
        ),
        throwsArgumentError,
      );
    });

    test('operations on unopened cellar throw StateError', () {
      final cellar = Cellar.atPath(tempDir.path, name: 'exports');
      expect(
        () => cellar.write('a', Uint8List.fromList([1])),
        throwsA(isA<StateError>()),
      );
    });

    test('open() is idempotent', () async {
      final cellar = Cellar.atPath(tempDir.path, name: 'exports');
      await cellar.open();
      await cellar.open(); // should be a no-op, not throw
      await cellar.write('a', Uint8List.fromList([1]));
      expect(File('${tempDir.path}/default/a').existsSync(), isTrue);
      await cellar.close();
    });

    test('close() prevents re-open', () async {
      final cellar = Cellar.atPath(tempDir.path, name: 'exports');
      await cellar.open();
      await cellar.close();
      expect(() => cellar.open(), throwsA(isA<StateError>()));
    });
  });
}
