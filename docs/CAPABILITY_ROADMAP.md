# Capability Roadmap

Every capability the package offers or plans, with status. Nothing ships
while an active row sits un-resolved. Statuses: **DONE** · **BUILDING** ·
**PLANNED** · **WONT_DO**.

**WONT_DO is a design decision, not a backlog.** Each such row is a
capability cellar could technically ship but refuses to, because it
would break a contract rule, lie on some platform, or do another
layer's job (the app's, the OS's, or a sibling package's). Every row
names the reason and what to use instead — so the next maintainer
doesn't "helpfully" re-add it.

**The storage contract — non-negotiable.** Every backend passes the same
conformance battery (VM and real Chrome); every DONE row below holds on
every platform its surface supports. And the core never guesses storage
locations — locations are caller-supplied, autos live in
`cellar_flutter`. A capability that would break either rule is WONT_DO
by definition.

For the architecture see [`ARCHITECTURE.md`](ARCHITECTURE.md). For
maintenance recipes see [`UPDATING.md`](UPDATING.md).

---

## The contract — `StorageBackend`

| Capability | Status | Notes |
|---|---|---|
| 13-method interface, conformance-pinned | DONE | The conformance battery runs against every backend on the VM AND in real Chrome; a new backend's first test is one invocation per runner |
| Raw string-prefix semantics (list / deletePrefix) | DONE | S3-style; pinned by dedicated conformance cases |
| Typed `StorageError` family end to end | DONE | Not-found decided by existence, not exception subtype — dart:io-compatible substrates behave identically |
| Dispose guards on every backend + facade | DONE | Idempotent `dispose`; every op throws `StateError` after; creator-disposes ownership rule |
| Internal locking | WONT_DO | Only the app knows its write topology — a lock inside the package would serialize every caller to protect the few who race, and cross-isolate/cross-process races would still escape it. The atomic-write rule keeps crash-safety regardless; serialize same-key writes at the app layer |
| Disk-space queries | WONT_DO | A faker method: IndexedDB can't report space at all, and native answers vary by OS quota policy — the same call would mean five different things and `null` on web. The honest contract is reactive: write, and handle the typed `WriteError` (disk full / quota) |
| Filesystem paths on regular CRUD | WONT_DO | Paths are one backend's implementation detail — IndexedDB and remote objects have none, so a `path` getter would be null-on-web API poison and would invite direct-file mutation behind the store's back. `materialize` is the deliberate door: a real path on native, a Blob URL on web, released when done |

## FileSystemBackend (native)

| Capability | Status | Notes |
|---|---|---|
| Atomic writes (temp + rename) | DONE | Crash mid-write leaves the previous object |
| Sidecar metadata (`.meta.json`) with silent rebuild | DONE | Body is truth; unparseable sidecar deleted + rebuilt on next write |
| Windows tombstoned deletes + `sweepTombstones` | DONE | Real-OS leg in the CI matrix; `delete()` succeeds immediately on every OS |
| Backup exclusion (iOS `kCFURLIsExcludedFromBackupKey` via CFURL FFI · macOS tmutil) | DONE | Via the `FileSystemOs` seam; survives `wipePartition` (the wipe deletes children, never the attributed root); failures degrade to backed-up, never fail a write |
| OS seam (`FileSystemOs` + per-OS overrides, injectable) | DONE | The package's only `Platform.isX` branches live in `current()` |
| Time Machine exclusion observed end-to-end (macOS) | DONE | Observed on real hardware at a real `~/Library` path: `osBackup: false` partition → `tmutil isexcluded` reports **Excluded**, control partition **Included**. `isexcluded` queries the same state backupd consults — the arbiter itself |
| iCloud backup exclusion observed on the iOS runtime | DONE | Observed on the iOS 26.5 simulator via the integration smoke: the `osBackup: false` partition reads back excluded from the OS resource layer — after a wipe. The observation caught two real bugs on arrival (the deprecated `com.apple.MobileBackup` mechanism, and wipe deleting the attributed root) |
| Physical-device backup-size observation (iOS) | DONE | Observed on a real iPhone through real iCloud backup cycles, A/B: with ~8 MiB in the `osBackup: false` partition the app was ABSENT from the backup app list; with ~8 MiB added to the backed-up partition (excluded data still on device) the app appeared at 8.1 MB — exactly the included set. The excluded bytes never entered a backup. Probe targets: `cellar_flutter` example `integration_test/backup_size_probe*_test.dart`; recipe in `UPDATING.md` S7 |

## IndexedDbBackend (web)

| Capability | Status | Notes |
|---|---|---|
| One database per partition; atomic `wipePartition` | DONE | `deleteDatabase` per partition |
| Chunked records + manifest-last crash safety | DONE | Generation-tagged so torn writes never mix generations |
| `writtenAt` stamping (`lastModified` non-null on web) | DONE | Missing field = corruption, not compat |
| Full conformance + Blob materialization in real Chrome | DONE | `make test-web`; Blob URLs verified via actual fetch |

## Remote backends

| Capability | Status | Notes |
|---|---|---|
| First-party remote backend (S3 or otherwise) | WONT_DO | The seam is the product: `StorageBackend` + the conformance battery let anyone implement their remote of choice and run the same exam the built-ins pass. A first-party remote satellite package (family repo) returns only if a real consumer's read/write patterns drive it — an experimental half-implementation shipped for years with zero consumers and was deleted (git history keeps it). Lesson kept: a device-local `Lifecycle` must never delete shared remote data — mirror-only eviction; remote-side lifecycle belongs to the remote's own rules |

## Decorators

| Capability | Status | Notes |
|---|---|---|
| `ChunkedBackend` (chunk + manifest over any backend) | DONE | Range reads touch only overlapping chunk records |
| `EncryptedBackend` (BYO `FileEncryptor` + `EncryptionKeyResolver`) | DONE | Streaming chunks, per-chunk MACs, self-describing header, range reads decrypt only overlapping chunks, cross-key `copy` re-encrypts |
| Compression decorator | WONT_DO | Apps that store compressible data do it in two lines (`gzip.encode` before write) and own the trade; media is already compressed (~0% gain for the main payload class); transparent compression breaks the O(range) `readRange` promise unless cellar grows a block-compression format forever; S3/GCS made the same refusal. One rule to know: compress BEFORE encrypting — ciphertext doesn't compress |

## The facade — `Cellar`

| Capability | Status | Notes |
|---|---|---|
| Three constructors (default / `atPath` / `withBackends`) | DONE | Sync construction, explicit async `open()` |
| Pure-Dart package (no Flutter SDK, no plugins) | DONE | Native roots are caller-supplied (`roots:` / `atPath`) — the core never guesses; Flutter apps route through `cellar_flutter` |
| Named partitions + `PartitionConfig` | DONE | Name grammar validated at construction; `system_` reserved |
| `keyPrefix` tenant scoping, scope-relative results | DONE | Listed keys round-trip into `read()` unchanged |
| Lifecycle (maxBytes / maxAge / wipeOnOpen / runInterval / osManaged) | DONE | Eviction-error resilience via `onEvictionError`; `runLifecycleNow()` on demand; injectable clock |
| Cross-partition copy / move / `movePartition` filter | DONE | Streams through, metadata carried |
| Materialize with `decrypt` / `exclusive` axes | DONE | Path on native, Blob URL on web; live handles survive deletes |
| `totalSize` / `fileSize` accounting | DONE | |
| Key queries / secondary indexes | WONT_DO | Cellar lists by raw prefix, nothing more — search needs an index, an index needs a schema, and that's a database's job. Keep the query→key mapping in your DB (drift/hive) and fetch bytes here |
| Per-key TTL | WONT_DO | Per-key expiry means a metadata scan (or an index) on every sweep and a second expiry vocabulary beside partitions — cost forever, for a need partitions already answer: give expiring data its own partition (`maxAge`), or key it under a prefix and evict by prefix |
| User-visible file storage (Files app, Downloads) | WONT_DO | A different product with different physics: user-visible files need OS dialogs, permissions, share sheets, and survive-the-app semantics. That's `device_io`'s whole job. Cellar is the app-private store; pipe bytes between them at the app layer |
| Cross-cellar sync | WONT_DO | Sync is a distributed-systems product (conflict resolution, identity, transport, retry) that would dwarf the storage engine and force every consumer to carry it. Cellar stays a local store; sync layers compose ON TOP of the byte contract |

## Infrastructure

| Capability | Status | Notes |
|---|---|---|
| Strict lints + zero-issue analyzer | DONE | `analyze_core.sh` with `--fatal-infos`; suppression comments banned |
| Makefile gates (format / analyze / analyze-floor / platforms / lint-shell / test-guards) | DONE | Shared gate scripts stamped from whuppi/ci |
| Batteries × runners test suite | DONE | 385 VM + 325 real-Chrome executions; shape in `ARCHITECTURE.md`, the test-architecture section |
| Runnable pure-Dart example (`example/main.dart`) | DONE | Full lifecycle as a CLI run; CI runs it (int) and its `dart compile exe` build (verify) per OS; the 7-tab Flutter showcase (journeys + smoke) lives with `cellar_flutter` |
| CI via the shared workflow repo | BUILDING | Stock single-package callers (fast PR gate + label-triggered full-test + release lanes); first real run happens at repo go-live |
| Repo go-live (GitHub whuppi/cellar, branch protection, release train) | DONE | Live: dev (default) + prod, device_io-parity protection (2 approvals + codeowners + the three required checks), dev/prod environments (prod release gated on maintainer review), labels seeded, maintainer + slopfairy team access. cellar_flutter is its own live repo pinning this one as a submodule |
| Publish to pub.dev | PLANNED | Maintainer-gated; plausibly clears the publication bar (cellar_flutter publishes from its own repo) |
| README banner image | DONE | Dark/light `<picture>` pair in `assets/` with the pub.dev flatten comment |
