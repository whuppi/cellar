/// Per-OS behavior seam for `FileSystemBackend`.
///
/// The backend body is OS-blind: every operation whose semantics differ
/// between operating systems goes through this interface. [DefaultFileSystemOs]
/// carries the common (POSIX) behavior; each OS class extends it and
/// overrides ONLY its own quirk. [FileSystemOs.current] is the single
/// runtime platform branch in the entire package.
///
/// `dart:io` only — imported solely by the native implementation.
library;

import 'dart:io';

import 'package:cellar/src/backends/file_system/os/ios_file_system_os.dart';
import 'package:cellar/src/backends/file_system/os/macos_file_system_os.dart';
import 'package:cellar/src/backends/file_system/os/windows_file_system_os.dart';

/// The operations whose semantics differ per operating system.
abstract interface class FileSystemOs {
  /// The implementation for the OS this process is running on.
  static FileSystemOs current() {
    if (Platform.isWindows) return WindowsFileSystemOs();
    if (Platform.isMacOS) return MacosFileSystemOs();
    if (Platform.isIOS) return IosFileSystemOs();
    return DefaultFileSystemOs();
  }

  /// Delete [file] with POSIX-equivalent semantics: succeeds even while
  /// another handle holds the file open. No-op when absent.
  Future<void> deleteFile(File file);

  /// Rename [from] onto [toPath], replacing any existing file — the
  /// promote step of an atomic write.
  Future<void> renameOver(File from, String toPath);

  /// Reap deferred-delete leftovers under [baseDir], if this OS produces
  /// any. Safe to call any time.
  Future<void> sweepTombstones(String baseDir);

  /// Exclude [directoryPath] from the OS backup mechanism (iCloud,
  /// Time Machine, …). Returns true when an exclusion was applied;
  /// false when this OS has no such concept.
  Future<bool> excludeFromBackup(String directoryPath);
}

/// The common behavior — POSIX semantics, no backup concept. Linux and
/// Android use it as-is; other OS classes extend it and override only
/// what their OS does differently.
class DefaultFileSystemOs implements FileSystemOs {
  @override
  Future<void> deleteFile(File file) async {
    // POSIX unlink succeeds with open handles; the file persists until
    // the last one closes.
    if (await file.exists()) await file.delete();
  }

  @override
  Future<void> renameOver(File from, String toPath) => from.rename(toPath); // POSIX rename replaces atomically.

  @override
  Future<void> sweepTombstones(String baseDir) async {
    // POSIX deletes never defer — nothing to reap.
  }

  @override
  Future<bool> excludeFromBackup(String directoryPath) async => false;
}
