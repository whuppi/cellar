/// Cross-platform object storage for Flutter.
///
/// Construct a `Cellar`, open it, use it. The same API works on every
/// platform — native filesystem on mobile/desktop, IndexedDB on web —
/// and your app code never branches on platform.
///
/// ```dart
/// import 'package:cellar/cellar.dart';
///
/// final cellar = Cellar(name: 'my_app');
/// await cellar.open();
///
/// await cellar.write('photos/sunset', bytes);
/// final stream = cellar.readStream('photos/sunset');
///
/// // Need a path/URL to hand to non-Dart code? Materialize it.
/// final handle = await cellar.materialize('photos/sunset');
/// // handle.localPath: filesystem path on native, blob URL on web
/// await handle.release();
///
/// await cellar.close();
/// ```
///
/// ## Multi-partition + lifecycle
///
/// ```dart
/// final cellar = Cellar(
///   name: 'my_app',
///   partitions: {
///     'main': PartitionConfig(),
///     'image_cache': PartitionConfig(
///       lifecycle: Lifecycle.cache(maxBytes: 100 * 1024 * 1024),
///     ),
///     'pending_uploads': PartitionConfig(
///       lifecycle: Lifecycle.scratch(),
///     ),
///   },
///   defaultPartition: 'main',
///   keyPrefix: 'user/$uid',
///   encryption: CellarEncryption(encryptor: myEncryptor),
/// );
/// await cellar.open();
///
/// await cellar.write('thumb/x', smallBytes, partition: 'image_cache');
/// ```
///
/// ## Custom native path
///
/// Use `Cellar.atPath` when you need a path the standard constructor
/// doesn't resolve itself (Downloads, external storage, iOS Library).
/// Native-only — throws on web.
///
/// ## Custom backend stacks
///
/// `import 'package:cellar/cellar_lowlevel.dart';` exposes the raw
/// backends and decorators (`FileSystemBackend`, `EncryptedBackend`,
/// `ChunkedBackend`, `StorageScope`). Compose your own stack and pass
/// it to `Cellar.withBackends`.
library;

// ── The class ──────────────────────────────────────────────────────
export 'src/cellar/cellar.dart' show Cellar;
export 'src/cellar/cellar_encryption.dart' show CellarEncryption;
export 'src/cellar/lifecycle.dart' show Lifecycle;
export 'src/cellar/lifecycle_runner.dart' show EvictionErrorCallback;
export 'src/cellar/storage_roots.dart';
export 'src/cellar/partition_config.dart'
    show PartitionConfig, defaultPartitionName;

// ── Result + handle types you'll touch in regular use ───────────────
export 'src/core/object_info.dart' show ObjectInfo;
export 'src/core/materialized_file.dart' show MaterializedFile;

// ── Bring-your-own interfaces (encryption is optional) ──────────────
export 'src/decorators/encrypted/file_encryptor.dart' show FileEncryptor;
export 'src/decorators/encrypted/encryption_key_resolver.dart'
    show EncryptionKeyResolver;

// ── Errors — typed, sealed; pattern-match in catch blocks ───────────
export 'src/core/errors.dart';

// ── Helpers apps may want ───────────────────────────────────────────
export 'src/core/key_validation.dart' show validateKey, validatePrefix;
