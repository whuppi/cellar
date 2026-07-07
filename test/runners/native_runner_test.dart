/// Runs every platform-blind battery on the VM. The SAME batteries run
/// in real Chrome via web_runner_test.dart — one spec, two worlds, a
/// platform-dependent result is a red build, not an unknown.
///
/// Platform-bound suites (real filesystem, Blob URLs) are quarantined
/// in test/platform/ and never appear here.
library;

import '../batteries/cellar_battery.dart';
import '../batteries/chunked_battery.dart';
import '../batteries/conformance_battery.dart';
import '../batteries/core_battery.dart';
import '../batteries/encrypted_battery.dart';
import '../batteries/scope_battery.dart';
import '../batteries/stack_battery.dart';
import '../harness/fake_encryptor.dart';
import '../harness/in_memory_backend.dart';

import 'package:cellar/cellar_lowlevel.dart';

void main() {
  // ── The contract, over every pure backend ──
  runStorageBackendConformance('InMemoryBackend', create: InMemoryBackend.new);
  runStorageBackendConformance(
    'ChunkedBackend over InMemory',
    create: () =>
        ChunkedBackend(backing: InMemoryBackend(), chunkSize: 64 * 1024),
  );
  runStorageBackendConformance(
    'EncryptedBackend over InMemory',
    create: () => EncryptedBackend(
      inner: InMemoryBackend(),
      encryptor: FakeEncryptor(),
      keyResolver: const FixedKeyResolver('conformance-key'),
    ),
  );

  // ── The feature batteries ──
  runCoreBattery();
  runScopeBattery();
  runChunkedBattery();
  runEncryptedBattery();
  runCellarBattery();
  runStackBattery();
}
