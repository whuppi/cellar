/// macOS quirk: Time Machine backs up everything unless a directory
/// carries the sticky exclusion — set via `tmutil addexclusion`, the
/// supported, owner-callable mechanism. (iOS's
/// `kCFURLIsExcludedFromBackupKey` resource property is a concept Time
/// Machine ignores.)
library;

import 'dart:io';

import 'package:cellar/src/backends/file_system/os/file_system_os.dart';

/// See library doc — the backup-exclusion override.
class MacosFileSystemOs extends DefaultFileSystemOs {
  @override
  Future<bool> excludeFromBackup(String directoryPath) async {
    final result = await Process.run('tmutil', ['addexclusion', directoryPath]);
    return result.exitCode == 0;
  }
}
