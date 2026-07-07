/// Backend assembly kit for cellar.
///
/// `package:cellar/cellar.dart`'s `Cellar` constructor handles the
/// standard platform + encryption case; this entrypoint exposes the
/// underlying backend pieces so you can compose stacks `Cellar` doesn't
/// cover, wire your own backend, or chunk an arbitrary backing store.
///
/// Example — encrypted, chunked-on-native storage rooted at a custom
/// directory, wired into a multi-partition Cellar:
///
/// ```dart
/// import 'package:cellar/cellar.dart';            // Cellar + facade types
/// import 'package:cellar/cellar_lowlevel.dart';   // backend pieces
///
/// final mainBackend = EncryptedBackend(
///   inner: ChunkedBackend(
///     backing: FileSystemBackend('/var/data/main'),
///   ),
///   encryptor: myEncryptor,
/// );
///
/// final cellar = Cellar.withBackends(
///   {'main': mainBackend},
///   defaultPartition: 'main',
///   keyPrefix: 'user/u1',
/// );
/// await cellar.open();
/// ```
///
/// To plug in a brand-new backend (DynamoDB, GCS without S3 interop,
/// an in-memory cache, …), implement `StorageBackend` and pass it to
/// `Cellar.withBackends`. The Cellar surface is identical regardless
/// of the backing store.
library;

// The contract every backend implements, plus the types its signatures
// use — a custom backend must be writable against this entrypoint alone.
export 'src/core/storage_backend.dart' show StorageBackend;
export 'src/core/object_info.dart' show ObjectInfo;
export 'src/core/materialized_file.dart' show MaterializedFile;
export 'src/core/dispose_guard.dart' show DisposeGuard;

// The typed errors every backend throws — part of the low-level contract.
// A caller assembling backends directly catches these (FileNotFoundError,
// ChunkVerificationError, InvalidHeaderError, …) without also importing
// the high-level cellar.dart entrypoint.
export 'src/core/errors.dart';

// Platform-default raw backend factory — for custom stacks that want a
// local cache layer (remote-backend compositions, test fixtures, etc.).
export 'src/cellar/default_backend/default_backend.dart'
    show initDefaultBackend;
export 'src/cellar/storage_roots.dart';

// Concrete backends. The platform-specific backends are exported via
// conditional re-exports — on the wrong platform they resolve to a
// throwing stub so this barrel is still loadable everywhere (e.g. for
// VM tests that exercise the chunking algorithm without touching JS).
export 'src/backends/file_system/file_system_backend.dart'
    show FileSystemBackend;
export 'src/backends/indexed_db/indexed_db_backend.dart' show IndexedDbBackend;

// Bring-your-own-crypto interfaces — implement these to plug encryption into
// EncryptedBackend (cipher_kit, or any crypto lib, provides implementations).
export 'src/decorators/encrypted/file_encryptor.dart' show FileEncryptor;
export 'src/decorators/encrypted/encryption_key_resolver.dart'
    show EncryptionKeyResolver;

// Decorators — wrap any backend.
export 'src/decorators/encrypted/encrypted_backend.dart' show EncryptedBackend;
export 'src/decorators/chunked/chunked_backend.dart'
    show ChunkedBackend, ChunkedManifest;

// Key scoping — Cellar uses one StorageScope per partition, but you
// can wire your own.
export 'src/cellar/storage_scope.dart' show StorageScope;

// Per-call write knobs (folded into Cellar.write's named params at
// the high level — exposed here for callers that go through the
// scope directly).
export 'src/core/write_options.dart' show WriteOptions;
