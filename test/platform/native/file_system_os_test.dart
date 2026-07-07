import 'dart:typed_data';

// White-box test of the NATIVE impl: imports the suffixed file directly
// (the switch's analyzer view resolves to the web stub, which cannot
// carry the io-typed `os:` parameter).
import 'dart:io';

import 'package:cellar/src/backends/file_system/file_system_backend_native.dart';
import 'package:cellar/src/backends/file_system/os/file_system_os.dart';
import 'package:cellar/src/backends/file_system/os/ios_file_system_os.dart';
import 'package:cellar/src/backends/file_system/os/windows_file_system_os.dart';
import 'package:test/test.dart';

import '../../harness/temp_dir.dart';

// The seam's payoff: any OS's code paths run on any machine by
// injection. (POSIX can't simulate Windows' sharing violations, so
// these prove the happy paths and the wiring — the violation branch is
// covered by the Windows CI leg.)
void main() {
  group('FileSystemOs injection', () {
    test('Windows tombstone delete executes anywhere and leaves no '
        'residue when nothing holds the file', () async {
      final dir = await makeTempDir('os_seam_');
      addTearDown(() => dir.delete(recursive: true));
      final backend = FileSystemBackend(dir.path, os: WindowsFileSystemOs());

      await backend.write('doc', Uint8List.fromList([1, 2, 3]));
      await backend.delete('doc');

      expect(await backend.exists('doc'), isFalse);
      // The rename→delete dance completed: no tombstone left behind.
      final leftovers = await dir
          .list(recursive: true)
          .where((e) => e.path.contains(WindowsFileSystemOs.tombstoneSuffix))
          .toList();
      expect(leftovers, isEmpty);
    });

    test('Windows renameOver replaces an existing object on write', () async {
      final dir = await makeTempDir('os_seam_');
      addTearDown(() => dir.delete(recursive: true));
      final backend = FileSystemBackend(dir.path, os: WindowsFileSystemOs());

      await backend.write('k', Uint8List.fromList([1]));
      await backend.writeStream('k', Stream.value(Uint8List.fromList([9, 9])));
      expect(await backend.read('k'), Uint8List.fromList([9, 9]));
    });

    test(
      'iOS exclusion round-trips through the CFURL resource layer',
      () async {
        final dir = await makeTempDir('os_seam_ios_');
        addTearDown(() => dir.delete(recursive: true));
        final os = IosFileSystemOs();

        // Before: the system reports not-excluded.
        expect(await os.isExcludedFromBackup(dir.path), isFalse);

        // Set through CFURLSetResourcePropertyForKey (the modern
        // NSURLIsExcludedFromBackupKey face — the deprecated raw
        // com.apple.MobileBackup xattr must never come back)...
        expect(await os.excludeFromBackup(dir.path), isTrue);

        // ...and the system's own resource layer reports it back.
        expect(await os.isExcludedFromBackup(dir.path), isTrue);
      },
      skip: !Platform.isMacOS
          ? 'CoreFoundation round-trip needs an Apple host'
          : false,
    );

    test(
      'backup exclusion survives a full-prefix wipe (the wipePartition '
      'path) — the partition root keeps its attribute',
      () async {
        final dir = await makeTempDir('os_seam_wipe_');
        addTearDown(() => dir.delete(recursive: true));
        final os = IosFileSystemOs();
        final backend = FileSystemBackend(dir.path, osBackup: false, os: os);

        // First write applies the exclusion lazily.
        await backend.write('a/b', Uint8List.fromList([1]));
        expect(await os.isExcludedFromBackup(dir.path), isTrue);

        // Wiping everything must NOT delete the attributed root itself.
        await backend.deletePrefix('');
        expect(await backend.list(''), isEmpty);
        expect(
          await os.isExcludedFromBackup(dir.path),
          isTrue,
          reason: 'wipe must never cost the partition its backup exclusion',
        );

        // And the store still works after.
        await backend.write('c', Uint8List.fromList([2]));
        expect(await backend.read('c'), Uint8List.fromList([2]));
      },
      skip: !Platform.isMacOS
          ? 'CoreFoundation round-trip needs an Apple host'
          : false,
    );

    test('current() returns the default on Linux-like fallthrough', () {
      // On the machine running this suite, current() must return SOME
      // implementation without throwing.
      expect(FileSystemOs.current(), isA<FileSystemOs>());
    });
  });
}
