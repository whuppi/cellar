import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:cellar/cellar_lowlevel.dart';

import '../../harness/temp_dir.dart';

void main() {
  late Directory tempDir;
  late FileSystemBackend backend;

  setUp(() async {
    tempDir = await makeTempDir();
    backend = FileSystemBackend(tempDir.path);
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('FileSystemBackend', () {
    group('write + read', () {
      test('write then read returns same bytes', () async {
        final data = Uint8List.fromList([1, 2, 3, 4, 5]);
        await backend.write('test/file', data);
        expect(await backend.read('test/file'), data);
      });

      test('write creates parent directories', () async {
        await backend.write('deep/nested/path/file', Uint8List.fromList([1]));
        expect(await backend.exists('deep/nested/path/file'), isTrue);
      });

      test('write with WriteOptions stores contentType + metadata', () async {
        await backend.write(
          'doc',
          Uint8List.fromList([1]),
          const WriteOptions(
            contentType: 'text/plain',
            metadata: {'tag': 'v1'},
          ),
        );
        final info = await backend.head('doc');
        expect(info, isNotNull);
        expect(info!.contentType, 'text/plain');
        expect(info.metadata['tag'], 'v1');
      });

      test('writeStream then read returns concatenated bytes', () async {
        final chunks = [
          Uint8List.fromList([1, 2]),
          Uint8List.fromList([3, 4]),
        ];
        await backend.writeStream('streamed', Stream.fromIterable(chunks));
        expect(
          await backend.read('streamed'),
          Uint8List.fromList([1, 2, 3, 4]),
        );
      });

      test('read on a missing key throws FileNotFoundError', () async {
        expect(
          () => backend.read('missing'),
          throwsA(isA<FileNotFoundError>()),
        );
      });
    });

    group('readStream', () {
      test('returns file contents as a stream', () async {
        await backend.write('file', Uint8List.fromList([5, 6, 7]));
        final out = <int>[];
        await for (final chunk in backend.readStream('file')) {
          out.addAll(chunk);
        }
        expect(out, [5, 6, 7]);
      });
    });

    group('readRange', () {
      test('returns the requested byte range', () async {
        await backend.write(
          'data',
          Uint8List.fromList(List.generate(10, (i) => i)),
        );
        expect(
          await backend.readRange('data', start: 3, length: 4),
          Uint8List.fromList([3, 4, 5, 6]),
        );
      });

      test('returns the first bytes', () async {
        await backend.write('data', Uint8List.fromList([10, 20, 30]));
        expect(
          await backend.readRange('data', start: 0, length: 2),
          Uint8List.fromList([10, 20]),
        );
      });
    });

    group('head', () {
      test('returns file info with non-null lastModified', () async {
        await backend.write(
          'file',
          Uint8List.fromList([1, 2, 3]),
          const WriteOptions(contentType: 'image/png'),
        );
        final info = await backend.head('file');
        expect(info, isNotNull);
        expect(info!.key, 'file');
        expect(info.size, 3);
        expect(info.contentType, 'image/png');
        expect(info.lastModified, isNotNull);
      });

      test('returns null for missing key', () async {
        expect(await backend.head('missing'), isNull);
      });
    });

    group('exists', () {
      test('true for existing, false for missing', () async {
        await backend.write('file', Uint8List.fromList([1]));
        expect(await backend.exists('file'), isTrue);
        expect(await backend.exists('nope'), isFalse);
      });
    });

    group('delete', () {
      test('removes the file', () async {
        await backend.write('file', Uint8List.fromList([1]));
        await backend.delete('file');
        expect(await backend.exists('file'), isFalse);
      });

      test('removes the sidecar metadata file too', () async {
        await backend.write(
          'file',
          Uint8List.fromList([1]),
          const WriteOptions(contentType: 'text/plain'),
        );
        await backend.delete('file');
        final metaFile = File('${tempDir.path}/file.meta.json');
        expect(await metaFile.exists(), isFalse);
      });

      test('deleting missing file does not throw', () async {
        await backend.delete('nonexistent');
      });
    });

    group('deletePrefix', () {
      test('removes everything under the prefix', () async {
        await backend.write('photos/a', Uint8List.fromList([1]));
        await backend.write('photos/b', Uint8List.fromList([2]));
        await backend.write('docs/c', Uint8List.fromList([3]));

        await backend.deletePrefix('photos/');
        expect(await backend.exists('photos/a'), isFalse);
        expect(await backend.exists('photos/b'), isFalse);
        expect(await backend.exists('docs/c'), isTrue);
      });
    });

    group('list', () {
      test('returns ObjectInfo for matching keys', () async {
        await backend.write('dir/a', Uint8List.fromList([1]));
        await backend.write('dir/b', Uint8List.fromList([2, 3]));
        await backend.write('other/c', Uint8List.fromList([4]));

        final results = await backend.list('dir/');
        expect(results.length, 2);
        expect(results.map((o) => o.key).toSet(), {'dir/a', 'dir/b'});
      });

      test('list excludes sidecar .meta.json files', () async {
        await backend.write(
          'file',
          Uint8List.fromList([1]),
          const WriteOptions(contentType: 'text/plain'),
        );
        final results = await backend.list('');
        for (final info in results) {
          expect(info.key, isNot(endsWith('.meta.json')));
        }
      });

      test('every result has non-null lastModified', () async {
        await backend.write('a', Uint8List.fromList([1]));
        await backend.write('b', Uint8List.fromList([2]));
        for (final info in await backend.list('')) {
          expect(info.lastModified, isNotNull);
        }
      });
    });

    group('copy', () {
      test('duplicates bytes and metadata', () async {
        await backend.write(
          'src',
          Uint8List.fromList([1, 2, 3]),
          const WriteOptions(contentType: 'image/png', metadata: {'tag': 'v1'}),
        );
        await backend.copy('src', 'dest');
        expect(await backend.read('dest'), Uint8List.fromList([1, 2, 3]));
        final info = await backend.head('dest');
        expect(info!.contentType, 'image/png');
        expect(info.metadata['tag'], 'v1');
      });
    });

    group('updateMetadata', () {
      test('rewrites sidecar without touching the body', () async {
        final data = Uint8List.fromList([1, 2, 3]);
        await backend.write(
          'file',
          data,
          const WriteOptions(contentType: 'text/plain'),
        );
        await backend.updateMetadata(
          'file',
          contentType: 'application/json',
          metadata: {'version': '2'},
        );
        expect(await backend.read('file'), data);
        final info = await backend.head('file');
        expect(info!.contentType, 'application/json');
        expect(info.metadata['version'], '2');
      });
    });

    group('sidecar self-heal', () {
      test(
        'an unparseable sidecar is deleted; head returns empty metadata',
        () async {
          await backend.write(
            'file',
            Uint8List.fromList([1]),
            const WriteOptions(contentType: 'image/png'),
          );
          final metaFile = File('${tempDir.path}/file.meta.json');
          await metaFile.writeAsString('not valid json!!!');

          final info = await backend.head('file');
          expect(info, isNotNull);
          expect(info!.size, 1);
          expect(info.contentType, isNull);
          expect(info.metadata, isEmpty);

          // Self-heal: corrupt sidecar deleted.
          expect(await metaFile.exists(), isFalse);
        },
      );

      test('next write after self-heal rebuilds the sidecar', () async {
        await backend.write(
          'file',
          Uint8List.fromList([1]),
          const WriteOptions(contentType: 'image/png'),
        );
        final metaFile = File('${tempDir.path}/file.meta.json');
        await metaFile.writeAsString('not valid json!!!');
        await backend.head('file'); // triggers self-heal

        await backend.write(
          'file',
          Uint8List.fromList([1]),
          const WriteOptions(contentType: 'image/jpeg'),
        );
        expect(await metaFile.exists(), isTrue);
        final info = await backend.head('file');
        expect(info!.contentType, 'image/jpeg');
      });
    });

    group('materialize', () {
      test('exclusive: false returns the original path (zero copy)', () async {
        await backend.write('a', Uint8List.fromList([1, 2, 3]));
        final handle = await backend.materialize('a', exclusive: false);
        expect(handle.localPath, '${tempDir.path}/a');
        expect(File(handle.localPath).existsSync(), isTrue);
        await handle.release();
        // Original still exists (release was a no-op).
        expect(File('${tempDir.path}/a').existsSync(), isTrue);
      });

      test(
        'exclusive: true returns a temp copy that release deletes',
        () async {
          await backend.write('a', Uint8List.fromList([1, 2, 3]));
          final handle = await backend.materialize('a', exclusive: true);
          expect(handle.localPath, isNot('${tempDir.path}/a'));
          expect(File(handle.localPath).existsSync(), isTrue);
          await handle.release();
          expect(File(handle.localPath).existsSync(), isFalse);
        },
      );

      test('throws FileNotFoundError on a missing key', () async {
        expect(
          () => backend.materialize('missing'),
          throwsA(isA<FileNotFoundError>()),
        );
      });
    });
  });
}
