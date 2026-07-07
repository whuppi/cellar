import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:cellar/cellar_lowlevel.dart';

import '../../harness/temp_dir.dart';

void main() {
  late Directory tempDir;
  late FileSystemBackend backend;

  setUp(() async {
    tempDir = await makeTempDir('partial_state_');
    backend = FileSystemBackend(tempDir.path);
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  group('FileSystemBackend partial-state recovery', () {
    test(
      'body present, sidecar missing → head returns body with empty metadata',
      () async {
        await backend.write(
          'file',
          Uint8List.fromList([1, 2, 3]),
          const WriteOptions(contentType: 'text/plain'),
        );
        final metaFile = File('${tempDir.path}/file.meta.json');
        expect(await metaFile.exists(), isTrue);
        await metaFile.delete();

        final info = await backend.head('file');
        expect(info, isNotNull);
        expect(info!.size, 3);
        expect(info.contentType, isNull);
        expect(info.metadata, isEmpty);
        expect(info.lastModified, isNotNull);
      },
    );

    test('sidecar present, body missing → head returns null', () async {
      await backend.write(
        'file',
        Uint8List.fromList([1, 2, 3]),
        const WriteOptions(contentType: 'text/plain'),
      );
      final dataFile = File('${tempDir.path}/file');
      await dataFile.delete();

      expect(await backend.head('file'), isNull);
      expect(await backend.exists('file'), isFalse);
    });

    test(
      'writeStream that throws mid-way leaves a recoverable state',
      () async {
        final errorStream = () async* {
          yield Uint8List.fromList([1, 2, 3]);
          yield Uint8List.fromList([4, 5, 6]);
          throw Exception('simulated network error');
        }();

        try {
          await backend.writeStream('partial', errorStream);
        } catch (_) {
          // Expected.
        }
        // Caller can retry and overwrite the partial file.
        await backend.write('partial', Uint8List.fromList([99]));
        expect(await backend.read('partial'), Uint8List.fromList([99]));
      },
    );

    test('overwrite replaces both body and sidecar atomically', () async {
      await backend.write(
        'file',
        Uint8List.fromList([1]),
        const WriteOptions(contentType: 'text/plain', metadata: {'v': '1'}),
      );
      await backend.write(
        'file',
        Uint8List.fromList([2, 3]),
        const WriteOptions(contentType: 'image/png', metadata: {'v': '2'}),
      );
      expect(await backend.read('file'), Uint8List.fromList([2, 3]));
      final info = await backend.head('file');
      expect(info!.contentType, 'image/png');
      expect(info.metadata['v'], '2');
    });
  });
}
