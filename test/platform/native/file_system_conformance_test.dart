/// The full StorageBackend contract over the REAL filesystem — the one
/// conformance run that needs a disk, so it lives in platform/native
/// instead of the runners.
library;

import 'dart:io';

import 'package:cellar/cellar_lowlevel.dart';
import 'package:test/test.dart';

import '../../batteries/conformance_battery.dart';
import '../../harness/temp_dir.dart';

void main() {
  late Directory tempRoot;
  var counter = 0;
  setUpAll(() async => tempRoot = await makeTempDir('conformance_fs_'));
  tearDownAll(() async {
    try {
      await tempRoot.delete(recursive: true);
    } on FileSystemException {
      // Best-effort cleanup; a leaked temp dir is the OS's problem, not
      // a test failure.
    }
  });

  runStorageBackendConformance(
    'FileSystemBackend',
    create: () => FileSystemBackend('${tempRoot.path}/${counter++}'),
    supportsMaterialize: true,
  );
}
