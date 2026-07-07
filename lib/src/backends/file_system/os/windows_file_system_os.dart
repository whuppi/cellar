/// Windows quirk: files can't be deleted (or renamed over) while a
/// handle is open — `ERROR_SHARING_VIOLATION`, where POSIX would
/// succeed. Deletes rename to a tombstone first (rename-with-open-
/// handles IS allowed), then reap; leftovers are swept later.
library;

import 'dart:io';

import 'package:cellar/src/backends/file_system/os/file_system_os.dart';

/// See library doc — the delete/rename overrides.
class WindowsFileSystemOs extends DefaultFileSystemOs {
  /// Marker injected into a tombstoned file's name, followed by a
  /// microsecond timestamp so leftovers never collide with each other.
  /// Key validation rejects segments starting with `.`, so tombstones
  /// can't collide with real keys either.
  static const String tombstoneSuffix = '.cellar_tombstone.';

  String _tombstonePath(String filePath) {
    final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    return '$filePath$tombstoneSuffix$stamp';
  }

  @override
  Future<void> deleteFile(File file) async {
    if (!await file.exists()) return;
    // Rename to tombstone (allowed even with open handles), then try to
    // delete. If the delete fails (handle held), leave the tombstone
    // for the next sweep.
    final tombstone = File(_tombstonePath(file.path));
    try {
      await file.rename(tombstone.path);
    } on FileSystemException {
      // Even the rename failed — fall back to direct delete (may throw).
      await file.delete();
      return;
    }
    try {
      await tombstone.delete();
    } on FileSystemException {
      // Held — the next sweep will retry.
    }
  }

  @override
  Future<void> renameOver(File from, String toPath) async {
    // Windows refuses rename-over-existing; clear the destination first.
    await deleteFile(File(toPath));
    await from.rename(toPath);
  }

  @override
  Future<void> sweepTombstones(String baseDir) async {
    final root = Directory(baseDir);
    if (!await root.exists()) return;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (!entity.path.contains(tombstoneSuffix)) continue;
      try {
        await entity.delete();
      } on FileSystemException {
        // Still held by something. Try again next sweep.
      }
    }
  }
}
