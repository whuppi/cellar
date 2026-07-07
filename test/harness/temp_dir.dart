import 'dart:io';

/// Create a fresh temp directory for a test. Caller is responsible for
/// deleting it (use `addTearDown` in the test).
Future<Directory> makeTempDir([String prefix = 'cellar_test_']) {
  return Directory.systemTemp.createTemp(prefix);
}
