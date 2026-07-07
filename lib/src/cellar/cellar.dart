import 'dart:typed_data';

import 'package:cellar/src/cellar/default_backend/default_backend.dart';
import 'package:cellar/src/backends/file_system/file_system_backend.dart';
import 'package:cellar/src/core/materialized_file.dart';
import 'package:cellar/src/core/object_info.dart';
import 'package:cellar/src/core/storage_backend.dart';
import 'package:cellar/src/core/write_options.dart';
import 'package:cellar/src/decorators/encrypted/encrypted_backend.dart';
import 'package:cellar/src/cellar/cellar_encryption.dart';
import 'package:cellar/src/cellar/storage_roots.dart';
import 'package:cellar/src/cellar/storage_scope.dart';
import 'package:cellar/src/cellar/lifecycle.dart';
import 'package:cellar/src/cellar/lifecycle_runner.dart';
import 'package:cellar/src/cellar/partition_config.dart';

/// Cross-platform object storage.
///
/// ## Lifecycle
///
/// Cellar has an explicit, symmetric lifecycle:
///
/// 1. **Construct** — `Cellar(...)`. Synchronous. Validates args, stores
///    configuration. No IO.
/// 2. **Open** — `await cellar.open()`. Asynchronous. Sets up the
///    backend stack, creates partition directories, applies OS-level
///    hints (iCloud exclusion), runs `wipeOnOpen` lifecycle rules,
///    starts the lifecycle timer.
/// 3. **Use** — `cellar.write()`, `cellar.read()`, etc. All async.
///    Operations on an unopened cellar throw [StateError].
/// 4. **Close** — `await cellar.close()`. Stops the lifecycle timer
///    and releases resources. After close, the cellar is unusable.
///
/// ## Three constructors — one lifecycle
///
/// ```dart
/// // Standard: platform-default storage (filesystem on native, IndexedDB on web).
/// final cellar = Cellar(
///   name: 'my_app',
///   partitions: {
///     'main':  PartitionConfig(),
///     'cache': PartitionConfig(lifecycle: Lifecycle.cache(maxBytes: 100 << 20)),
///   },
///   defaultPartition: 'main',
///   keyPrefix: 'user/$uid',
///   encryption: myEncryption,
/// );
/// await cellar.open();
///
/// // Custom native path (Downloads, external storage, iOS Library, …).
/// // Native only; throws on web.
/// final cellar = Cellar.atPath(
///   '/Users/alice/Downloads',
///   name: 'exports',
/// );
/// await cellar.open();
///
/// // Pre-built backends (tests, DynamoDB, any substrate).
/// final cellar = Cellar.withBackends(
///   {'main': InMemoryBackend()},
///   defaultPartition: 'main',
/// );
/// await cellar.open();
/// ```
///
/// All three variants run the same [open] sequence — same lifecycle
/// initialization, same tombstone sweep, same xattr application. No
/// variant "skips" init.
///
/// ## Two structural concepts
///
/// - **Partition** — named data category. Each partition is a logically
///   separated storage area that can be wiped independently and may have
///   its own [Lifecycle] policy.
/// - **keyPrefix** — string stamped onto every key inside the cellar.
///   Most commonly used for tenant scoping (`'user/$uid'`), but the
///   mechanism is general (migration prefixes, test isolation, etc.).
///
/// One cellar has one `keyPrefix`; all partitions share it. For multiple
/// namespaces alive at once, open multiple cellars.
///
/// See `docs/architecture.md` for the full model.
class Cellar {
  /// Standard constructor — platform-default storage.
  ///
  /// Filesystem on native (`getApplicationSupportDirectory()` by default,
  /// `getApplicationCacheDirectory()` for partitions with
  /// `lifecycle.osManaged: true`). IndexedDB on web (one database per
  /// partition, named `${name}__${partition}`).
  Cellar({
    required this.name,
    Map<String, PartitionConfig>? partitions,
    String defaultPartition = defaultPartitionName,
    this.keyPrefix,
    CellarEncryption? encryption,
    this.onEvictionError,
    StorageRoots? roots,
  }) : _partitions = _resolvePartitions(partitions, defaultPartition),
       _defaultPartition = defaultPartition,
       _encryption = encryption,
       _origin = _Origin.platform,
       _providedBackends = null,
       _roots = roots,
       _atPath = null;

  /// Open at a dev-supplied native filesystem path.
  ///
  /// Use when you need a path that the standard [Cellar] constructor
  /// doesn't cover — Downloads, external storage, iOS Library, Photos
  /// directories, anything you got from the platform yourself.
  ///
  /// [path] is treated as the root; partitions become subdirectories
  /// (`$path/$partition`).
  ///
  /// Native-only by design. Throws [UnsupportedError] at [open] time
  /// on web (web has no filesystem concept).
  Cellar.atPath(
    String path, {
    required this.name,
    Map<String, PartitionConfig>? partitions,
    String defaultPartition = defaultPartitionName,
    this.keyPrefix,
    CellarEncryption? encryption,
    this.onEvictionError,
  }) : _partitions = _resolvePartitions(partitions, defaultPartition),
       _defaultPartition = defaultPartition,
       _encryption = encryption,
       _origin = _Origin.atPath,
       _providedBackends = null,
       _roots = null,
       _atPath = path;

  /// Open over a map of pre-built backends.
  ///
  /// Use for tests (in-memory backends) or for substrates the standard
  /// constructor doesn't cover (custom S3, DynamoDB, GCS without S3
  /// interop, your own server).
  ///
  /// Encryption and lifecycle are wrapped around your backends the same
  /// way the standard constructor does.
  Cellar.withBackends(
    Map<String, StorageBackend> backends, {
    required String defaultPartition,
    this.keyPrefix,
    CellarEncryption? encryption,
    Map<String, Lifecycle>? lifecycles,
    this.onEvictionError,
  }) : name = null,
       _partitions = _partitionConfigsFor(backends, lifecycles),
       _defaultPartition = defaultPartition,
       _encryption = encryption,
       _origin = _Origin.withBackends,
       _providedBackends = _validateBackends(backends, defaultPartition),
       _roots = null,
       _atPath = null;
  // ══════════════════════════════════════════════════════════════════════
  // CONSTRUCTION (sync)
  // ══════════════════════════════════════════════════════════════════════

  /// The cellar's storage area name. Used to derive partition directories
  /// on native and IndexedDB database names on web. Null for
  /// [Cellar.withBackends] — caller-supplied backends have no platform
  /// storage area to name.
  final String? name;

  /// Per-partition configuration (lifecycle, osBackup, …).
  final Map<String, PartitionConfig> _partitions;

  /// Partition used when a method is called without `partition:`.
  final String _defaultPartition;

  /// Namespace prefix stamped onto every key. Null = no namespace.
  final String? keyPrefix;

  /// Encryption config, or null for plaintext.
  final CellarEncryption? _encryption;

  /// Observer for lifecycle-eviction failures. Null = silent (failed
  /// victims still retry on the next tick). See [EvictionErrorCallback].
  final EvictionErrorCallback? onEvictionError;

  /// Internal variant — which origin this cellar was constructed with.
  final _Origin _origin;

  /// Pre-built backends, for [Cellar.withBackends]. Null otherwise.
  final Map<String, StorageBackend>? _providedBackends;

  /// Native filesystem root, for [Cellar.atPath]. Null otherwise.
  final String? _atPath;

  /// Caller-supplied native storage roots for the default constructor.
  /// Required on native at open() — the core never guesses locations.
  /// Web ignores roots (IndexedDB). Flutter apps use cellar_flutter's
  /// openCellar, which supplies them.
  final StorageRoots? _roots;

  /// Partition scopes built by [open]. Null before open, non-null after.
  Map<String, StorageScope>? _scopes;

  /// Raw backends (pre-encryption), built by [open]. Needed for
  /// `wipePartition` which bypasses `keyPrefix`.
  Map<String, StorageBackend>? _rawBackends;

  /// Lifecycle runner. Null if no partition has rules, or before open.
  LifecycleRunner? _lifecycleRunner;

  bool _opened = false;
  bool _closed = false;

  /// In-flight [open] call, shared by concurrent callers so backends and
  /// the lifecycle timer are only ever built once. Reset on failure so a
  /// failed open can be retried.
  Future<void>? _opening;

  // ══════════════════════════════════════════════════════════════════════
  // OPEN / CLOSE
  // ══════════════════════════════════════════════════════════════════════

  /// True once [open] has completed and before [close] has run.
  bool get isOpen => _opened && !_closed;

  /// Set up backends, apply OS hints, run `wipeOnOpen` lifecycle rules,
  /// and start the lifecycle timer.
  ///
  /// Idempotent — calling `open()` on an already-open cellar is a no-op.
  /// Calling `open()` after [close] throws [StateError].
  Future<void> open() async {
    if (_closed) {
      throw StateError('Cellar has been closed and cannot be reopened.');
    }
    if (_opened) return;

    // Concurrent open() calls share one build — otherwise both would pass
    // the _opened check and double-build backends (leaking the first
    // runner's timer).
    final inFlight = _opening;
    if (inFlight != null) return inFlight;
    final attempt = _openOnce();
    _opening = attempt;
    try {
      await attempt;
    } finally {
      _opening = null;
    }
  }

  Future<void> _openOnce() async {
    final rawBackends = <String, StorageBackend>{};
    final scopes = <String, StorageScope>{};
    final runner = LifecycleRunner(onEvictionError: onEvictionError);

    for (final entry in _partitions.entries) {
      final partitionName = entry.key;
      final cfg = entry.value;
      final osManaged = cfg.lifecycle?.osManaged ?? false;

      final raw = await _buildRawBackend(
        partition: partitionName,
        osManaged: osManaged,
        osBackup: cfg.osBackup,
      );
      rawBackends[partitionName] = raw;

      var backend = raw;
      final enc = _encryption;
      if (enc != null) {
        backend = EncryptedBackend(
          inner: backend,
          encryptor: enc.encryptor,
          keyResolver: enc.keyResolver,
          encryptByDefault: enc.encryptByDefault,
        );
      }
      scopes[partitionName] = StorageScope(backend, keyPrefix: keyPrefix);

      if (cfg.lifecycle != null) {
        runner.register(partitionName, scopes[partitionName]!, cfg.lifecycle!);
      }
    }

    // Scratch partitions wipe before we hand out the cellar.
    await runner.runWipeOnOpen();

    _rawBackends = rawBackends;
    _scopes = scopes;
    _lifecycleRunner = runner.currentInterval == null ? null : runner;
    _opened = true;
  }

  /// Stop the lifecycle runner, dispose the backends this cellar built,
  /// and release internal references. After close, the cellar cannot be
  /// reopened — construct a new one.
  ///
  /// Ownership rule: backends passed to [Cellar.withBackends] belong to
  /// the caller and are NOT disposed here — dispose them yourself when
  /// you're done with them.
  Future<void> close() async {
    if (_closed) return;
    _lifecycleRunner?.dispose();
    _lifecycleRunner = null;
    if (_origin != _Origin.withBackends) {
      for (final backend in _rawBackends?.values ?? const <StorageBackend>[]) {
        await backend.dispose();
      }
    }
    _scopes = null;
    _rawBackends = null;
    _closed = true;
  }

  // ══════════════════════════════════════════════════════════════════════
  // INTROSPECTION
  // ══════════════════════════════════════════════════════════════════════

  /// All configured partition names.
  List<String> get partitionNames => List.unmodifiable(_partitions.keys);

  /// The default partition name used when `partition:` is omitted.
  String get defaultPartition => _defaultPartition;

  // ══════════════════════════════════════════════════════════════════════
  // WRITE
  // ══════════════════════════════════════════════════════════════════════

  /// Write [bytes] at [key]. Replaces any existing object.
  ///
  /// Use [writeStream] for large files — [write] buffers the entire
  /// body in memory. Progress reporting is a [writeStream] feature: a
  /// buffered write has no intermediate states to report.
  Future<void> write(
    String key,
    Uint8List bytes, {
    String? partition,
    String? contentType,
    Map<String, String> metadata = const {},
    bool? encrypt,
  }) => _scopeFor(partition).write(
    key,
    bytes,
    WriteOptions(
      contentType: contentType,
      metadata: metadata,
      encrypt: encrypt,
    ),
  );

  /// Stream bytes into [key]. Constant memory regardless of total size.
  ///
  /// [onProgress] reports bytes consumed from [byteStream] as they are
  /// written; the total is null (a stream's length is unknown until it
  /// ends). Big-file upload UIs pair this with a caller-known size.
  Future<void> writeStream(
    String key,
    Stream<List<int>> byteStream, {
    String? partition,
    String? contentType,
    Map<String, String> metadata = const {},
    bool? encrypt,
    void Function(int bytesWritten, int? totalBytes)? onProgress,
  }) => _scopeFor(partition).writeStream(
    key,
    byteStream,
    WriteOptions(
      contentType: contentType,
      metadata: metadata,
      encrypt: encrypt,
      onProgress: onProgress,
    ),
  );

  // ══════════════════════════════════════════════════════════════════════
  // READ
  // ══════════════════════════════════════════════════════════════════════

  /// Read the full body at [key]. Throws `FileNotFoundError` if absent.
  Future<Uint8List> read(String key, {String? partition}) =>
      _scopeFor(partition).read(key);

  /// Stream the body at [key]. Constant memory; throws on missing key.
  Stream<List<int>> readStream(String key, {String? partition}) =>
      _scopeFor(partition).readStream(key);

  /// Read a byte range from [key]. For chunked or encrypted objects,
  /// only the chunks overlapping the range are touched.
  Future<Uint8List> readRange(
    String key, {
    required int start,
    required int length,
    String? partition,
  }) => _scopeFor(partition).readRange(key, start: start, length: length);

  // ══════════════════════════════════════════════════════════════════════
  // METADATA
  // ══════════════════════════════════════════════════════════════════════

  /// Metadata for [key]. Returns null if the key is absent.
  Future<ObjectInfo?> head(String key, {String? partition}) =>
      _scopeFor(partition).head(key);

  /// True if [key] exists in this partition.
  Future<bool> exists(String key, {String? partition}) =>
      _scopeFor(partition).exists(key);

  /// Update metadata for [key] without touching its bytes.
  Future<void> updateMetadata(
    String key, {
    String? contentType,
    Map<String, String> metadata = const {},
    String? partition,
  }) => _scopeFor(
    partition,
  ).updateMetadata(key, contentType: contentType, metadata: metadata);

  // ══════════════════════════════════════════════════════════════════════
  // DELETE
  // ══════════════════════════════════════════════════════════════════════

  /// Delete [key]. No-op if absent.
  Future<void> delete(String key, {String? partition}) =>
      _scopeFor(partition).delete(key);

  /// Delete every object whose key starts with [prefix] within the
  /// chosen partition (honors [keyPrefix]).
  Future<void> deletePrefix(String prefix, {String? partition}) =>
      _scopeFor(partition).deletePrefix(prefix);

  // ══════════════════════════════════════════════════════════════════════
  // LIST
  // ══════════════════════════════════════════════════════════════════════

  /// All objects in this partition whose key starts with [prefix],
  /// with metadata.
  Future<List<ObjectInfo>> list(String prefix, {String? partition}) =>
      _scopeFor(partition).list(prefix);

  /// Same as [list] but returns just the keys.
  Future<List<String>> listKeys(String prefix, {String? partition}) =>
      _scopeFor(partition).listKeys(prefix);

  // ══════════════════════════════════════════════════════════════════════
  // COPY / MOVE
  // ══════════════════════════════════════════════════════════════════════

  /// Copy within a single partition (honors keyPrefix).
  Future<void> copy(String fromKey, String toKey, {String? partition}) =>
      _scopeFor(partition).copy(fromKey, toKey);

  /// Move (copy + delete source) within a single partition.
  Future<void> move(String fromKey, String toKey, {String? partition}) =>
      _scopeFor(partition).move(fromKey, toKey);

  /// Copy from one partition to another (both honor keyPrefix).
  Future<void> copyAcrossPartitions({
    required String fromPartition,
    required String fromKey,
    required String toPartition,
    required String toKey,
  }) async {
    final src = _scopeFor(fromPartition);
    final dst = _scopeFor(toPartition);
    final stream = src.readStream(fromKey);
    final head = await src.head(fromKey);
    await dst.writeStream(
      toKey,
      stream,
      WriteOptions(
        contentType: head?.contentType,
        metadata: head?.metadata ?? const {},
      ),
    );
  }

  /// Move from one partition to another (copy + delete source).
  Future<void> moveAcrossPartitions({
    required String fromPartition,
    required String fromKey,
    required String toPartition,
    required String toKey,
  }) async {
    await copyAcrossPartitions(
      fromPartition: fromPartition,
      fromKey: fromKey,
      toPartition: toPartition,
      toKey: toKey,
    );
    await _scopeFor(fromPartition).delete(fromKey);
  }

  // ══════════════════════════════════════════════════════════════════════
  // PARTITION OPERATIONS
  // ══════════════════════════════════════════════════════════════════════

  /// Wipe the entire partition (every key, ignores [keyPrefix]).
  ///
  /// For per-tenant cleanup, use [deletePrefix] with the empty prefix
  /// instead (that honors keyPrefix).
  Future<void> wipePartition(String partition) async {
    final raw = _requirePartition(partition);
    await raw.deletePrefix('');
  }

  /// Migrate keys from one partition to another. Optional [filter]
  /// lets you move only matching keys (by unscoped key name).
  Future<void> movePartition({
    required String fromPartition,
    required String toPartition,
    bool Function(String key)? filter,
  }) async {
    final src = _scopeFor(fromPartition);
    final objects = await src.list('');
    final effectivePrefix = keyPrefix == null ? '' : '$keyPrefix/';
    for (final info in objects) {
      final userKey = info.key.startsWith(effectivePrefix)
          ? info.key.substring(effectivePrefix.length)
          : info.key;
      if (filter != null && !filter(userKey)) continue;
      await copyAcrossPartitions(
        fromPartition: fromPartition,
        fromKey: userKey,
        toPartition: toPartition,
        toKey: userKey,
      );
      await src.delete(userKey);
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  // MATERIALIZE
  // ══════════════════════════════════════════════════════════════════════

  /// Make [key] available as a platform-local handle: a filesystem path
  /// on native, a Blob URL on web. Pass it to FFI, native plugins, or
  /// browser APIs — anything outside Dart streams.
  ///
  /// See [StorageBackend.materialize] for the full per-backend behavior
  /// matrix and the meaning of [decrypt] / [exclusive]. Always call
  /// [MaterializedFile.release] when done.
  Future<MaterializedFile> materialize(
    String key, {
    String? partition,
    bool decrypt = true,
    bool exclusive = false,
  }) => _scopeFor(
    partition,
  ).materialize(key, decrypt: decrypt, exclusive: exclusive);

  // ══════════════════════════════════════════════════════════════════════
  // UTILITIES
  // ══════════════════════════════════════════════════════════════════════

  /// Sum of byte sizes for every object in this partition whose key
  /// starts with [prefix].
  Future<int> totalSize(String prefix, {String? partition}) =>
      _scopeFor(partition).totalSize(prefix);

  /// Byte size of one object. Returns 0 if the key is absent.
  Future<int> fileSize(String key, {String? partition}) =>
      _scopeFor(partition).fileSize(key);

  // ══════════════════════════════════════════════════════════════════════
  // TEST HOOKS
  // ══════════════════════════════════════════════════════════════════════

  /// Run lifecycle eviction for every partition immediately instead of
  /// waiting for the next timer tick — e.g. after a bulk import that
  /// blew past a cache cap. No-op when no partition has rules.
  Future<void> runLifecycleNow() async {
    await _lifecycleRunner?.evaluateNow();
  }

  // ══════════════════════════════════════════════════════════════════════
  // INTERNALS
  // ══════════════════════════════════════════════════════════════════════

  StorageScope _scopeFor(String? partition) {
    _assertOpen();
    final name = partition ?? _defaultPartition;
    final scope = _scopes![name];
    if (scope == null) {
      throw ArgumentError.value(
        partition,
        'partition',
        'unknown partition; configured: ${_scopes!.keys.join(", ")}',
      );
    }
    return scope;
  }

  StorageBackend _requirePartition(String partition) {
    _assertOpen();
    final raw = _rawBackends![partition];
    if (raw == null) {
      throw ArgumentError.value(
        partition,
        'partition',
        'unknown partition; configured: ${_rawBackends!.keys.join(", ")}',
      );
    }
    return raw;
  }

  void _assertOpen() {
    if (!_opened) {
      throw StateError(
        'Cellar not opened. Call `await cellar.open()` before using it.',
      );
    }
    if (_closed) {
      throw StateError('Cellar is closed.');
    }
  }

  /// Build the raw (pre-encryption) backend for a partition, dispatched
  /// on origin: platform-default, custom path, or caller-supplied.
  Future<StorageBackend> _buildRawBackend({
    required String partition,
    required bool osManaged,
    required bool osBackup,
  }) async {
    switch (_origin) {
      case _Origin.platform:
        return initBackendForPartition(
          // Non-null by construction: the platform origin's constructor
          // requires a name.
          name: name!,
          partition: partition,
          osManaged: osManaged,
          osBackup: osBackup,
          roots: _roots,
        );
      case _Origin.atPath:
        final local = FileSystemBackend(
          '$_atPath/$partition',
          osBackup: osBackup,
        );
        await local.sweepTombstones();
        return local;
      case _Origin.withBackends:
        return _providedBackends![partition]!;
    }
  }

  // ── Static helpers used only at construction time ──

  static Map<String, PartitionConfig> _resolvePartitions(
    Map<String, PartitionConfig>? partitions,
    String defaultPartition,
  ) {
    if (partitions == null) {
      validatePartitionName(defaultPartition);
      return {defaultPartition: const PartitionConfig()};
    }
    if (partitions.isEmpty) {
      throw ArgumentError('partitions map must not be empty');
    }
    partitions.keys.forEach(validatePartitionName);
    if (!partitions.containsKey(defaultPartition)) {
      throw ArgumentError.value(
        defaultPartition,
        'defaultPartition',
        'must be one of: ${partitions.keys.join(", ")}',
      );
    }
    return partitions;
  }

  static Map<String, StorageBackend> _validateBackends(
    Map<String, StorageBackend> backends,
    String defaultPartition,
  ) {
    if (backends.isEmpty) {
      throw ArgumentError('backends map must not be empty');
    }
    backends.keys.forEach(validatePartitionName);
    if (!backends.containsKey(defaultPartition)) {
      throw ArgumentError.value(
        defaultPartition,
        'defaultPartition',
        'must be one of: ${backends.keys.join(", ")}',
      );
    }
    return backends;
  }

  static Map<String, PartitionConfig> _partitionConfigsFor(
    Map<String, StorageBackend> backends,
    Map<String, Lifecycle>? lifecycles,
  ) {
    final out = <String, PartitionConfig>{};
    for (final name in backends.keys) {
      out[name] = PartitionConfig(lifecycle: lifecycles?[name]);
    }
    return out;
  }
}

/// Internal — which constructor a [Cellar] was made with.
enum _Origin { platform, atPath, withBackends }
