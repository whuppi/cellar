import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
// Import the native impl directly (not via the barrel) so the test can
// reach FileSystemBackend's static constants. The barrel hides them on purpose.
import 'package:cellar/src/backends/file_system/file_system_backend.dart';

import '../../harness/temp_dir.dart';

/// Platform-specific behavior:
///   - Windows tombstone delete-while-open workaround
///   - iOS/macOS iCloud / Time Machine backup exclusion via xattr
///
/// Most of these can only be observed end-to-end on the right platform,
/// so the test asserts behavior we can verify on every platform (no
/// crashes, listings exclude tombstone files, sweepTombstones is safe
/// to call always).
void main() {
  late Directory tempDir;
  late FileSystemBackend backend;

  setUp(() async {
    tempDir = await makeTempDir('platform_');
    backend = FileSystemBackend(tempDir.path);
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  group('FileSystemBackend.sweepTombstones', () {
    test('is safe to call on a fresh directory', () async {
      await backend.sweepTombstones(); // does not throw
    });

    test(
      'is safe to call when there are real files but no tombstones',
      () async {
        await backend.write('a', Uint8List.fromList([1, 2, 3]));
        await backend.sweepTombstones();
        expect(await backend.exists('a'), isTrue);
      },
    );

    test('removes a leftover tombstone file when called', () async {
      // Drop a fake tombstone into the directory.
      final fake = File(
        '${tempDir.path}/leftover${FileSystemBackend.tombstoneSuffix}deadbeef',
      );
      await fake.writeAsBytes([0]);
      expect(await fake.exists(), isTrue);

      // Sweep on POSIX is a no-op; on Windows it deletes the tombstone.
      await backend.sweepTombstones();

      if (Platform.isWindows) {
        expect(await fake.exists(), isFalse);
      } else {
        // POSIX skips — tombstones are a Windows-only concept and the sweep
        // does nothing intentionally. The leftover survives.
        expect(await fake.exists(), isTrue);
      }
    });
  });

  group('listings exclude tombstone files', () {
    test('list does not return tombstone files as user objects', () async {
      // Write a real file and a fake tombstone in the same directory.
      await backend.write('real', Uint8List.fromList([1]));
      final fake = File(
        '${tempDir.path}/real${FileSystemBackend.tombstoneSuffix}deadbeef',
      );
      await fake.writeAsBytes([0]);

      final results = await backend.list('');
      final keys = results.map((i) => i.key).toList();
      expect(keys, contains('real'));
      for (final k in keys) {
        expect(
          k.contains(FileSystemBackend.tombstoneSuffix),
          isFalse,
          reason: 'tombstone leaked into list(): $k',
        );
      }
    });
  });

  group('osBackup flag', () {
    test('default constructor (osBackup: true) writes work normally', () async {
      final b = FileSystemBackend(tempDir.path); // osBackup defaults to true
      await b.write('a', Uint8List.fromList([1, 2, 3]));
      expect(await b.read('a'), Uint8List.fromList([1, 2, 3]));
    });

    test('osBackup: false writes work normally on every platform', () async {
      // The xattr is set best-effort on iOS/macOS. On other platforms it's
      // a documented no-op. Either way, normal operations succeed.
      final b = FileSystemBackend('${tempDir.path}/no_backup', osBackup: false);
      await b.write('a', Uint8List.fromList([1, 2, 3]));
      expect(await b.read('a'), Uint8List.fromList([1, 2, 3]));
    });

    test(
      'osBackup: false on macOS sets the Time Machine sticky exclusion',
      () async {
        // Only meaningful on macOS. Skip elsewhere.
        if (!Platform.isMacOS) return;

        final dir = '${tempDir.path}/no_backup_mac';
        final b = FileSystemBackend(dir, osBackup: false);
        // First write applies the exclusion lazily.
        await b.write('a', Uint8List.fromList([1]));

        // Read the STICKY exclusion attribute back through the OS —
        // `tmutil isexcluded` would also report inherited exclusions
        // (system temp dirs are excluded wholesale), which proves
        // nothing about our call.
        final result = await Process.run('xattr', [
          '-p',
          'com.apple.metadata:com_apple_backup_excludeItem',
          dir,
        ]);
        expect(
          result.exitCode,
          0,
          reason:
              'tmutil addexclusion must stamp the sticky exclusion attr '
              'on first write (stderr: ${result.stderr})',
        );
      },
    );

    test('osBackup default true sets NO exclusion on macOS', () async {
      if (!Platform.isMacOS) return;

      final dir = '${tempDir.path}/with_backup_mac';
      final b = FileSystemBackend(dir); // default osBackup: true
      await b.write('a', Uint8List.fromList([1]));

      final result = await Process.run('xattr', [
        '-p',
        'com.apple.metadata:com_apple_backup_excludeItem',
        dir,
      ]);
      // Non-zero means the attribute is absent — that's what we want.
      expect(result.exitCode, isNot(0));
    });
  });
}
