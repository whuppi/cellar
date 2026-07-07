# cellar — Architecture

How the package is wired. Two barrels, two backends, two decorators,
one facade; one conformance contract pinning them all, on the VM and in
real Chrome. For capability status see
[`CAPABILITY_ROADMAP.md`](CAPABILITY_ROADMAP.md); for maintenance
recipes see [`UPDATING.md`](UPDATING.md).

cellar is an app-private object store: bytes by key, one API on iOS,
Android, macOS, Windows, Linux, web — and servers. Pure Dart: no
Flutter SDK, no plugins (Flutter apps front it with
`package:cellar_flutter`, which resolves storage roots via
path_provider and re-exports this API). It is not a database (no
queries beyond prefix listing), not a file picker, not a sharing tool —
for "give a file to the user," use device_io.

---

## The contract

The load-bearing promises:

1. **One interface, every backend.** `StorageBackend` is 13 methods
   (write/writeStream · read/readStream/readRange · head/exists ·
   delete/deletePrefix · list · copy · updateMetadata · materialize,
   plus `dispose`). Every method is implementable by every backend —
   filesystem, IndexedDB, both decorators, and anything you implement.
   A capability that
   can't honor that lives on the concrete class, never the interface.
2. **Keys are a grammar, not paths.** `/`-separated segments matching
   `[a-zA-Z0-9][a-zA-Z0-9._-]*`; no traversal, no leading/trailing or
   doubled `/`, no Windows-unsafe characters. `validateKey` /
   `validatePrefix` (exported) are the single source of the rules.
   Backends never inspect the key string to make decisions — routing is
   by partition, encryption is per-write via `WriteOptions`.
3. **Prefixes are RAW string prefixes, S3-style.** `list('photos')`
   matches `photos/a` AND `photos_old/b`; end with `/` to scope to a
   pseudo-directory. Same rule on every backend, pinned by conformance.
4. **Stream-first, constant memory.** `writeStream`/`readStream` are
   the primary paths; buffered `write`/`read` are small-file sugar.
   `readRange` touches only the overlapping chunks (encrypted and
   chunked included). Nothing reads a whole object to do part of a job.
5. **Typed errors end to end.** The sealed `StorageError` family
   (`FileNotFoundError`, `EncryptionKeyMissingError`,
   `CorruptedFileError`, `CorruptedMetadataError`,
   `ChunkVerificationError`, `InvalidHeaderError`, `InvalidKeyError`,
   `WriteError`) is the only failure vocabulary. Not-found is decided
   by existence, not by exception subtype, so dart:io-compatible
   substrates behave identically. Nothing is silently swallowed.
6. **Writes are atomic.** Filesystem writes go temp + rename; IndexedDB
   chunked writes are generation-tagged so a torn write never mixes
   generations; a failed stream leaves the previous object fully intact
   (conformance-pinned). Metadata lives in sidecars so `head` and
   `list` never parse bodies.
7. **Creator disposes.** A backend disposes only what it constructed.
   Decorators never dispose the backend they wrap; `Cellar.close()`
   disposes the backends it built and leaves `withBackends`-provided
   ones to the caller. After `dispose`, every operation throws
   `StateError` (enforced by `DisposeGuard`).
8. **No cryptography shipped.** Encryption is a seam: the app
   implements `FileEncryptor` + `EncryptionKeyResolver`, and the
   `EncryptedBackend` decorator applies them with streaming chunks and
   per-chunk MACs. Encrypted files are self-describing (magic header);
   identifying a file never consults external state.
9. **No internal locking.** Concurrent writes to the same key may
   corrupt that object; the caller serializes same-key writes. Reads
   are safe with reads. Documented contract, not an accident.
10. **No `kIsWeb` in consumer code.** Every method works on every
    backend; where a platform genuinely can't deliver a behavior (e.g.
    `osManaged` on web), the parameter is accepted and the no-op is
    documented. The one exception is `Cellar.atPath` — native-only by
    definition (the dev brought a filesystem path), throwing
    `UnsupportedError` at `open()` on web so misuse fails loud.

---

## The file tree

Alpha-sorted as the IDE shows it; the order is the reading order.
Three entrypoints, no kitchen-sink barrel:

```
lib/
  cellar.dart                ← the Cellar facade (most apps import this)
  cellar_lowlevel.dart       ← backend assembly kit (compose your own stack)
  src/
    backends/                ← real substrates, nothing else
      file_system/
        file_system_backend.dart          ← conditional switch — import this
        file_system_backend_native.dart   ← the dart:io impl, OS-BLIND
        file_system_backend_stub.dart     ← web stub (mirrors the surface)
        os/                               ← the FileSystemOs seam (see The platform seam)
          file_system_os.dart             ← interface + POSIX default + current()
          ios_file_system_os.dart         ← backup exclusion via CFURL FFI
          macos_file_system_os.dart       ← backup exclusion via tmutil
          windows_file_system_os.dart     ← tombstoned deletes + rename-over
      indexed_db/
        indexed_db_backend.dart           ← switch · _web impl · _stub
    cellar/                   ← the product: facade + config + machinery
      default_backend/        ← what the plain Cellar() builds:
                                FileSystemBackend on native, IndexedDB on web
      cellar.dart             ← the facade (three constructors, one lifecycle)
      cellar_encryption.dart  ← encryption config form
      lifecycle.dart          ← eviction rules + factory shortcuts
      lifecycle_runner.dart   ← the timer + eviction pass
      partition_config.dart   ← per-partition config form + name validation
      storage_scope.dart      ← tenant prefixing; results are scope-relative
    core/                     ← the contract every backend implements
      dispose_guard.dart · errors.dart · key_validation.dart
      materialized_file.dart · object_info.dart · storage_backend.dart
      write_options.dart
    decorators/               ← wrap any backend
      chunked/                ← chunk-and-manifest (fixed-size records)
      encrypted/              ← transparent encryption + the two BYO interfaces
```

Tree story: **backends** (substrates) → **cellar** (the assembled
product) → **core** (the contract) → **decorators** (the wrappers).

Composition rules (inconsistencies are bugs):

- `core/` imports nothing internal — it's the vocabulary everything
  else speaks.
- `decorators/` and `cellar/` import only `core/` (plus, for the
  facade's default wiring, the backend switch files).
- Each backend folder is self-contained — sibling backends never
  import each other.
- Adding a backend = a sibling folder under `backends/` implementing
  `StorageBackend`, optionally a `lib/cellar_<name>.dart` barrel.
  `cellar/` and `core/` are never touched — that's what
  backend-agnostic means structurally.
- Decorators implement `StorageBackend` and wrap any backend; the
  facade is decorator-blind.

Decisions considered and rejected, kept so they aren't relitigated:
hoisting `cellar/cellar.dart` to `src/cellar.dart` (name-collides with
the entrypoint one level up); moving the crypto interfaces to `core/`
(they're the encryption contract, not the storage contract — one
folder is the entire seam); splitting `errors.dart` (a sealed hierarchy
must live in one library); a fixed `Shelf` enum instead of named
partitions (carried two dimensions in one enum and froze the taxonomy —
apps name their own partitions and migrate freely via `movePartition`).

---

## The platform seam

The word "platform" does not appear inside `lib/src/`. There are
exactly two runtime worlds: **native** (`dart.library.io`) and **web**
(`dart.library.js_interop`). Three rules wire them:

| Rule | Detail |
|---|---|
| Plain name = the switch | `x.dart` is the conditional re-export and the ONLY file anything outside the folder imports. `x_native.dart` / `x_web.dart` are the impls; `x_stub.dart` is the default target. Nothing outside a backend's folder imports a suffixed file. |
| Stub is the default target | pub.dev's analyzer attributes to every platform whatever the DEFAULT conditional target imports; a `dart:io` default silently drops web. Stubs mirror the impl's full cross-platform surface so the analyzer resolves real signatures. `make platforms` (pana) guards this. |
| Suffix trio → folders at three | A world's side holds at most two files as suffixed siblings. The day one side reaches three files, it graduates to `native/` / `web/` subfolders with plain filenames inside. `file_system/os/` is the shipped example of a graduated concern. |

**The FileSystemOs seam** is the one place OS identity exists:
`FileSystemOs.current()` holds the package's only `Platform.isX`
branches. The interface names the four quirk points (delete,
rename-over, tombstone sweep, backup exclusion); `DefaultFileSystemOs`
is the POSIX behavior; Windows/macOS/iOS subclasses override ONLY their
quirk. `FileSystemBackend` itself is OS-blind and takes `os:` for
cross-OS testing. A new OS quirk is a new override, never an inline
branch.

---

## Durability mechanics

| Mechanism | Where | Guarantee |
|---|---|---|
| Temp + rename | filesystem writes | A crash mid-write leaves the previous object; readers never see a torn file. |
| Generation tags | IndexedDB chunked records | A replaced object's stale chunks can't mix into a new read; the manifest record is written last for crash safety. |
| Tombstones | Windows deletes (`os/windows_…`) | Windows refuses `DeleteFile` on open handles, so `delete()` renames to `<key>.cellar_tombstone.<µs>` (rename works with handles open) and removes the tombstone when possible; `sweepTombstones` at the next `open()` retries leftovers. `list`/`head` skip tombstone paths, and the key grammar (no `.`-leading segments) makes collision with real keys impossible. From the caller's view, `delete()` always succeeds immediately on every OS, and live materialize handles keep working (POSIX semantics; Windows-equivalent via the rename). POSIX pays nothing — plain `File.delete()`. |
| Sidecar metadata | `.meta.json` (filesystem) / record fields (IndexedDB) | `head`/`list` are body-free and cheap. The body is the source of truth; an unparseable sidecar is deleted and rebuilt silently on the next write (`head` meanwhile returns empty metadata). Where metadata IS the body (an IndexedDB record missing required fields) there is no truth to rebuild from → `CorruptedFileError`. That's the package-wide convention: recover silently when truth exists, throw typed when it doesn't. |
| Backup exclusion | iOS (`kCFURLIsExcludedFromBackupKey` via CFURL FFI) · macOS (`tmutil addexclusion`) | `PartitionConfig(osBackup: false)` excludes the partition root; the attribute inherits to everything under it. Applied lazily on first write through the OS seam; a failure degrades to the safe backed-up state and never fails the write. No-op on Android (per-app manifest territory), Linux, Windows, web. `osBackup` lives on `PartitionConfig`, not `Lifecycle` — backup and eviction are independent axes (a permanent partition can be backup-excluded; a cache can be backed up). Default `true`: user data lands in iCloud without the dev thinking about it. |

### The IndexedDB record shape

Each partition is its own database (`{name}__{partition}`), so
`wipePartition` is one atomic `deleteDatabase`. Objects above the chunk
size split into chunk records + a manifest. Per-record fields: `body`
(ArrayBuffer), `contentType`, `metadata`, `writtenAt` (ms-epoch UTC,
stamped on every put — IndexedDB tracks no timestamps, and this is what
makes `ObjectInfo.lastModified` non-null on web; a record without it is
corruption, not a compat case). Schema changes bump `_dbVersion` with a
migration in `onupgradeneeded`; a new null-defaulting field needs none.

---

## The facade

`Cellar` composes everything. Construction is synchronous; `open()` is
the explicit async step that does the real IO (partition directories,
backup attributes, tombstone sweep, `wipeOnOpen`). Same lifecycle for
every constructor:

- **`Cellar(name, partitions, …)`** — the platform default backend per
  partition: `FileSystemBackend` on native, `IndexedDbBackend` on web
  (built by `default_backend/`). Native roots are CALLER-SUPPLIED via
  `roots: StorageRoots(support:, cache:)` — required at open(). The
  core never guesses locations: no HOME/XDG/APPDATA conventions, no
  plugin asks, no environment reads. A native open() without roots
  throws one teaching error (pointing at cellar_flutter for Flutter
  apps, explicit roots/atPath for everyone else). Web ignores roots —
  IndexedDB has no directories. Autos live in the sugar package
  (`cellar_flutter`'s openCellar via path_provider), never in the
  core.
- **`Cellar.atPath(path, …)`** — the dev brings a filesystem root
  (Downloads, external storage, anywhere path_provider doesn't reach).
  Native-only; also the plugin-free door tests use.
- **`Cellar.withBackends({...})`** — ready-made backends per partition
  (the low-level kit's entry; caller disposes what it provided).

Decorator application per constructor: `Cellar(name:)` and
`Cellar.atPath` apply only `EncryptedBackend` (when `encryption:` is
configured). Chunking is not applied on native — files go straight to
disk; on web, `IndexedDbBackend` chunks internally (records have a
practical size cap) and that chunking is invisible above it. Wanting
`ChunkedBackend` over any other backend means composing it yourself and
passing the stack to `Cellar.withBackends`.

The structural model — exactly two organizational concepts:

- **Partitions** divide data by category. A partition is a NAME with
  optional rules attached (`PartitionConfig`: lifecycle, encryption
  default, backup opt-out). Names match `[a-z][a-z0-9_]*`; `system_`
  is reserved; validated at construction. Backends know nothing about
  partitions — the facade holds one `StorageScope` per partition and
  routes by the optional `partition:` parameter (present on every data
  method; defaults to `defaultPartition`). Cross-partition operations
  (`copyAcrossPartitions`, `moveAcrossPartitions`, `movePartition`
  with optional key filter) stream through the facade, carrying
  metadata.
- **keyPrefix** applies one namespace across the whole cellar (tenant
  scoping: `'user/$uid'`). One cellar = one namespace; apps needing
  several open several cellars. `StorageScope` stamps the prefix on
  the way in and strips it on the way out — results speak the same
  scope-relative keys callers write with, so a listed key round-trips
  into `read()` unchanged. `wipePartition` deliberately ignores the
  prefix (wiping is a partition-level op; per-tenant cleanup is
  `deletePrefix('')`, which honors it).

**Lifecycle.** Per-partition `Lifecycle(maxBytes, maxAge, wipeOnOpen,
runInterval, osManaged)` with `Lifecycle.cache(...)` and
`Lifecycle.scratch()` shortcuts. One background timer per cellar
evaluates every partition; oldest objects evict first under a size cap;
`runLifecycleNow()` runs a pass on demand; eviction errors surface
through `onEvictionError` and never wedge the pass. `osManaged: true`
(the `cache` default) places the partition where the OS may also evict
— real on iOS/Android (cache vs support directory), accepted-but-no-op
on desktop, web, and `atPath` (documented, not faked). Cellar's own
rules run everywhere regardless; OS eviction is a bonus, never the
load-bearing story.

**Materialize.** `materialize(key)` returns the platform's notion of a
usable handle — real file path on native (zero-copy when unencrypted
and shared), Blob URL on web — with `decrypt`/`exclusive` axes and
`release()` as the caller's end of the deal. Deleting a key never
invalidates a live handle. The full per-backend behavior matrix lives
on `StorageBackend.materialize`'s doc comment.

Intentionally NOT in the facade: per-key TTL (design key names so
eviction can target by prefix), user-visible file storage (device_io's
job), queries beyond prefix listing, cross-cellar sync.

---

## Test architecture

Feature tests are written once as platform-blind **batteries**
(`test/batteries/`, no `_test` suffix, never run directly) and executed
by thin **runners** on every world — the batteries×runners shape exists
precisely for cellar's situation: ONE interface contract running under
many configurations.

```
test/
  batteries/    the specs: conformance (the StorageBackend contract,
                parameterized over any backend), core vocabulary, scope,
                chunked, encrypted, cellar facade, decorator stacks
  harness/      in-memory backend, forwarding backend, fake encryptor,
                temp dirs
  platform/
    native/     suites only a real disk can host: FileSystemBackend
                (+ its conformance run), the OS seam, atPath, the
                materialize matrix
    web/        suites only a browser can host: Blob-URL materialization
  runners/
    native_runner_test.dart   every battery on the VM
    web_runner_test.dart      the IDENTICAL batteries in real Chrome,
                              plus IndexedDB conformance + Blob suites
```

The same assertion runs on the VM and in Chrome; a result that differs
by platform is a red build, not an unknown. What's ALLOWED to differ is
quarantined in `platform/` where it can be listed by filename. A new
backend's first test is one `runStorageBackendConformance` invocation
in each runner. `make test-guards` mechanically enforces the shape:
browser imports only in the web runner + `platform/web/`; no `dart:ffi`
in tests (drive the OS seam, not syscalls); no 64-bit ByteData
accessors anywhere (dart2js has none); no empty dirs; no duplicate test
filenames.

This repo's `example/main.dart` is a runnable pure-Dart CLI walk of the
full lifecycle. The Flutter showcase — the seven-tab example app, its
host-VM journeys across six device profiles, and the per-platform
integration smokes through the real path_provider — lives in the
[cellar_flutter repo](https://github.com/whuppi/cellar_flutter), which
pins this one as a submodule. Real-OS legs for THIS repo (Windows
tombstones, real Chrome IndexedDB) run in its full-test CI matrix.

---

## The one-line summary

> **One 13-method contract, three substrates, two decorators, one
> facade. Keys are a grammar; prefixes are raw; streams never buffer;
> errors are typed values; writes are atomic; the creator disposes.
> Partitions are names with rules; keyPrefix is one namespace per
> cellar, invisible in results. Two worlds (native/web) behind
> plain-named switch files with stub defaults; OS quirks live behind
> one seam. The conformance battery IS the contract, and it runs
> identically on the VM and in real Chrome.**
