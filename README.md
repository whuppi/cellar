<p align="center">
  <a href="https://pub.dev/packages/cellar"><img src="https://img.shields.io/pub/v/cellar.svg" alt="pub package"></a>
  <a href="https://pub.dev/packages/cellar/score"><img src="https://img.shields.io/pub/likes/cellar" alt="likes"></a>
  <a href="https://pub.dev/packages/cellar/score"><img src="https://img.shields.io/pub/points/cellar" alt="pub points"></a>
  <a href="https://github.com/whuppi/cellar"><img src="https://img.shields.io/github/stars/whuppi/cellar?style=flat&logo=github" alt="GitHub stars"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="license: MIT"></a>
</p>

Cross-platform object storage for Dart & Flutter. Bytes in, bytes out, by key — over the native filesystem, IndexedDB, or your own backend. Named partitions with self-cleaning lifecycle rules, tenant scoping, bring-your-own encryption, true streaming I/O, and platform-local handles for non-Dart consumers.

Pure Dart: no Flutter SDK, no plugins. The same package runs in a phone app, a desktop tool, a CLI, and a server. Writes are atomic, errors are typed values, streams never buffer a whole object, and nothing in your code ever branches on platform.

> **Building a Flutter app?** You want [`cellar_flutter`](https://github.com/whuppi/cellar_flutter) — one `openCellar()` call resolves the storage roots on every platform (Android's are only knowable that way) and re-exports this entire API.

> like it? a [⭐ star](https://github.com/whuppi/cellar) or [👍 like](https://pub.dev/packages/cellar) is the entire marketing budget. [Bugs & features →](https://github.com/whuppi/cellar/issues)

---

<details>
<summary><b>👀 Peek inside</b></summary>

- [Install](#install)
- [Quick start](#quick-start)
- [The model](#the-model)
  - [Keys](#keys)
  - [Partitions](#partitions)
  - [Tenant scoping with `keyPrefix`](#tenant-scoping-with-keyprefix)
- [Usage](#usage)
  - [Store](#store)
  - [Stream](#stream)
  - [Lifecycle](#lifecycle)
  - [Encrypt](#encrypt)
  - [Materialize](#materialize)
  - [Bring your own path — `Cellar.atPath`](#bring-your-own-path--cellaratpath)
  - [Bring your own backend](#bring-your-own-backend)
- [Error handling](#error-handling)
- [Platform support](#platform-support)
  - [Where the data lands](#where-the-data-lands)
- [Not in the box](#not-in-the-box)
- [Docs](#docs)

</details>

---

## Install

```yaml
dependencies:
  cellar:
```

Nothing else — no platform setup, no permissions, no per-platform Dart.

One rule to know up front: **the core never guesses where your data lives.** You tell it, explicitly — a `roots:` pair (or a single `atPath` directory) on native, nothing at all on web (IndexedDB). Flutter apps skip even that: [`cellar_flutter`](https://github.com/whuppi/cellar_flutter)'s `openCellar()` resolves the locations for you on every platform. No conventions, no environment guessing, no path that appeared on its own.

---

## Quick start

Construct, open, use, close — the whole lifecycle:

```dart
import 'package:cellar/cellar.dart';

final cellar = Cellar(
  name: 'my_tool',
  roots: StorageRoots(
    support: '/var/lib/my_tool',   // persistent partitions
    cache: '/var/cache/my_tool',   // evictable partitions
  ),
);
await cellar.open();

await cellar.write('photos/sunset', imageBytes, contentType: 'image/png');
final bytes = await cellar.read('photos/sunset');
final exists = await cellar.exists('photos/sunset');
await cellar.delete('photos/sunset');

await cellar.close(); // on shutdown, profile switch, etc.
```

That's the shape of every call: a `/`-separated key in, bytes or metadata out. `write`, `read`, `head`, `list`, `copy`, `move`, `materialize` — same shape, a different verb.

Same code on every platform: native lands in real files under the app's private directory, web lands in IndexedDB (large objects chunked automatically, so a 1 GB blob doesn't OOM the tab).

<details>
<summary><b>🧩 the four lifecycle stages, precisely</b></summary>

<br>

1. **Construct** — `Cellar(...)`. Synchronous. Validates the configuration, stores it. No IO.
2. **Open** — `await cellar.open()`. Creates partition directories, applies OS attributes (backup exclusion), sweeps Windows tombstones, runs `wipeOnOpen` rules, starts the lifecycle timer. Idempotent.
3. **Use** — every data method, all async.
4. **Close** — `await cellar.close()`. Stops the timer, disposes the backends it built. A closed cellar can't reopen — construct a new one.

Operations before `open()` or after `close()` throw `StateError` — the lifecycle can't be half-entered.

</details>

---

## The model

Two organizational concepts. Everything else is a feature attached to them.

### Keys

Keys are a grammar, not file paths: `/`-separated segments of `[a-zA-Z0-9][a-zA-Z0-9._-]*`. No traversal, no leading/trailing or doubled `/`, nothing Windows-unsafe. The same key works on every backend, and `validateKey` / `validatePrefix` are exported so you can pre-check user input.

Listing and bulk deletion use **raw string prefixes**, S3-style: `list('photos')` matches `photos/a` *and* `photos_old/b` — end with `/` to scope to a pseudo-directory.

### Partitions

A partition is a **named category of data with optional rules attached** — permanent vs cache vs scratch, backed-up vs excluded. Apps that don't need them just use the default partition implicitly.

```dart
final cellar = Cellar(
  name: 'my_app',
  roots: myRoots,   // your StorageRoots — see Quick start
  partitions: {
    'main': PartitionConfig(),                                    // permanent, backed up
    'image_cache': PartitionConfig(
      lifecycle: Lifecycle.cache(maxBytes: 100 * 1024 * 1024),    // 100 MB cap
      osBackup: false,                                            // skip iCloud / Time Machine
    ),
    'pending_uploads': PartitionConfig(lifecycle: Lifecycle.scratch()), // wipe on open
  },
  defaultPartition: 'main',
);
await cellar.open();

await cellar.write('messages/abc', bytes);                        // default partition
await cellar.write('thumb/abc', smallBytes, partition: 'image_cache');
await cellar.wipePartition('image_cache');                        // one atomic wipe
```

Cross-partition `copyAcrossPartitions` / `moveAcrossPartitions` stream through with metadata; `movePartition` migrates whole partitions (optionally filtered by key).

### Tenant scoping with `keyPrefix`

One string stamps a namespace onto every key in the cellar — per-user data, test isolation, migration prefixes:

```dart
final cellar = Cellar(name: 'my_app', roots: myRoots, keyPrefix: 'user/\$uid');

await cellar.write('photos/cat', bytes);   // stored at user/<uid>/photos/cat
final all = await cellar.list('');         // keys come back scope-relative: photos/cat
```

Results speak the same scope-relative keys you write with — a listed key round-trips into `read()` unchanged. The prefix exists only at rest.

<details>
<summary><b>🧩 partitions vs keyPrefix — which one do i want?</b></summary>

<br>

They're different axes. **Partitions** divide data by *kind* — what rules it lives under (does it expire? is it backed up? can I wipe it wholesale?). **keyPrefix** divides data by *owner* — whose data it is.

One cellar has one `keyPrefix`; all its partitions share it. Need multiple namespaces alive at once — per-user data AND device-wide data? Open multiple cellars; each is its own closed universe, and there's no API that can accidentally cross tenants:

```dart
final accountCellar = Cellar(name: 'my_app', roots: myRoots, keyPrefix: 'user/\$uid');
final deviceCellar = Cellar(name: 'my_app_device', roots: myRoots);
```

The one crossover: `wipePartition` ignores the prefix — wiping is a partition-level operation, across all tenants. Per-tenant cleanup is `deletePrefix('')`, which honors it. Cross-namespace transfers aren't built in — stream-read from one cellar, stream-write to the other.

</details>

---

## Usage

Highlights below; every method and full signature lives in the [API reference](https://pub.dev/documentation/cellar/latest/).

### Store

Bytes with optional content type and custom metadata; metadata reads never touch bodies:

```dart
await cellar.write(
  'docs/report',
  bytes,
  contentType: 'application/pdf',
  metadata: {'source': 'export', 'v': '2'},
);

final info = await cellar.head('docs/report');   // size, type, metadata, lastModified
final all = await cellar.list('docs/');          // ObjectInfo per key, body-free
await cellar.copy('docs/report', 'docs/report_backup');
await cellar.deletePrefix('docs/');              // bulk delete by prefix
```

`head` returns `null` for an absent key; `ObjectInfo.lastModified` is non-null on every backend.

The full facade, all the same shape: `write` / `writeStream`, `read` / `readStream` / `readRange`, `head`, `exists`, `list` / `listKeys`, `delete` / `deletePrefix`, `copy`, `move`, `copyAcrossPartitions` / `moveAcrossPartitions`, `wipePartition`, `movePartition`, `updateMetadata`, `materialize`, `totalSize`, `fileSize`.

> Doing several operations on related objects? Give them a shared key prefix — `list`, `listKeys`, and `deletePrefix` all work on it in one call.

### Stream

For audio, video, model weights, downloads — anything that shouldn't live in memory:

```dart
// Write from a stream — only one chunk in memory at a time.
await cellar.writeStream(
  'models/llama-7b.gguf',
  downloadStream,
  onProgress: (written, total) => updateBar(written),
);

// Read as a stream — playback, processing, forwarding.
await for (final chunk in cellar.readStream('models/llama-7b.gguf')) { /* … */ }

// Read just a byte range — seeking in media, header parsing.
final slice = await cellar.readRange('audio/song.mp3', start: 44100, length: 8192);
```

Memory stays constant regardless of object size, and `readRange` touches only the overlapping chunks — encrypted and chunked objects included, never a full-object read in disguise.

<details>
<summary><b>🧩 wait — what does "atomic" actually mean here?</b></summary>

<br>

A filesystem write goes to a temp file and is renamed into place; an IndexedDB chunked write tags every chunk with a generation and commits the manifest last. Either way: a crash mid-write leaves the **previous** object fully intact, and a reader never sees a torn file. A `writeStream` whose source stream fails leaves the previous object untouched too — pinned by the conformance suite on every backend.

The flip side you own: cellar takes no locks, so two concurrent writes to the *same key* can corrupt that object. Serialize same-key writes in your app; reads are always safe with reads.

</details>

### Lifecycle

Self-cleaning partitions. Rules run identically on every backend; a background timer per cellar evaluates them, and `runLifecycleNow()` runs a pass on demand:

```dart
'image_cache': PartitionConfig(
  lifecycle: Lifecycle.cache(maxBytes: 100 * 1024 * 1024),  // oldest evicted first
),
'downloads': PartitionConfig(
  lifecycle: Lifecycle(maxAge: Duration(days: 30), runInterval: Duration(hours: 6)),
),
'scratch': PartitionConfig(lifecycle: Lifecycle.scratch()), // wiped on every open()
```

Eviction failures surface through the cellar's `onEvictionError` callback and never wedge the pass — one stuck object can't stop the sweep.

<details>
<summary><b>🧩 the osManaged flag — letting the OS help</b></summary>

<br>

`Lifecycle.cache` defaults to `osManaged: true`: the partition is placed where the OS may *also* evict under storage pressure. That's real on iOS and Android (the cache directory's documented contract) and a documented no-op on desktop, web, and `Cellar.atPath` — desktop OSes don't sweep caches, IndexedDB evicts per-origin, and a path you brought is yours.

Your `maxBytes` / `maxAge` rules run everywhere regardless. OS eviction is a bonus on the two platforms that offer it — never the load-bearing story.

</details>

### Encrypt

Cellar ships **zero cryptography**. Implement two small interfaces over the library of your choice (libsodium, Web Crypto, a vetted Dart cipher) and every write is encrypted transparently — streaming chunks, per-chunk MACs:

```dart
final cellar = Cellar(
  name: 'my_app',
  roots: myRoots,
  encryption: CellarEncryption(
    encryptor: myEncryptor,        // your FileEncryptor
    keyResolver: myKeyResolver,    // your EncryptionKeyResolver
    encryptByDefault: true,
  ),
);
await cellar.open();

await cellar.write('diary/today', entryBytes);   // stored as ciphertext
final entry = await cellar.read('diary/today');  // decrypted automatically

// Per-write override — plaintext for things that don't need it:
await cellar.write('cache/thumb', data, encrypt: false);
```

<details>
<summary><b>🧩 what the encrypted format buys you</b></summary>

<br>

Encrypted objects are **self-describing** — a magic header carries the nonce, chunk size, and original size, so identifying and decrypting a file never consults external state. Chunks carry individual MACs, which is what makes three things possible: true streaming decrypt (no read-everything-then-verify), `readRange` that decrypts only the overlapping chunks, and tamper detection that names the exact chunk (`ChunkVerificationError.chunkIndex`).

A missing key at read time is `EncryptionKeyMissingError` — never silently-returned ciphertext. And `copy` re-encrypts when source and destination resolve to different keys, so a cross-tenant copy can't produce bytes the destination can't read.

The [example app](https://github.com/whuppi/cellar_flutter/tree/dev/example) contains a complete working `FileEncryptor` — what you see there is exactly what implementing the seam takes.

</details>

### Materialize

Some consumers need a real path or URL, not Dart bytes: native libraries via FFI, plugins that take a `File`, browser elements taking a `src`.

```dart
final handle = await cellar.materialize('models/llama-7b.gguf');

nativeLib.loadModel(handle.localPath);  // native: a real filesystem path
// audioElement.src = handle.localPath; // web: a Blob URL

await handle.release();                 // frees temps / revokes the URL
```

Decryption is transparent (pass `decrypt: false` for raw ciphertext); `exclusive: true` gets you a private copy you may modify or delete. On local unencrypted objects the handle is the original file — zero copy.

<details>
<summary><b>🧩 live handles vs deletion</b></summary>

<br>

Deleting a key never invalidates a live handle. POSIX systems give this for free (the file persists until the last descriptor closes). Windows doesn't allow deleting open files at all — so cellar renames the file to a tombstone (rename works with handles open), the delete reports success immediately, and the tombstone is swept on the next `open()`. Tombstones are invisible to `list`/`head` and can't collide with real keys. From your code's view, `delete()` behaves identically on every OS.

</details>

### Bring your own path — `Cellar.atPath`

For directories cellar doesn't resolve itself — Downloads, external storage, anything you obtained from the platform:

```dart
final cellar = Cellar.atPath(
  '/var/lib/my_service/data',
  name: 'exports',
  partitions: {'exports': PartitionConfig()},
  defaultPartition: 'exports',
);
await cellar.open();
```

Native-only by design — it throws `UnsupportedError` at `open()` on web, so cross-platform misuse fails loud, not weird.

### Bring your own backend

`package:cellar/cellar_lowlevel.dart` exposes the raw pieces for hand-rolled stacks — every backend and decorator implements the same 13-method `StorageBackend` interface:

```dart
import 'package:cellar/cellar.dart';
import 'package:cellar/cellar_lowlevel.dart';

final backend = EncryptedBackend(
  inner: ChunkedBackend(backing: FileSystemBackend('/var/data/main')),
  encryptor: myEncryptor,
  keyResolver: myKeyResolver,
);

final cellar = Cellar.withBackends(
  {'main': backend},
  defaultPartition: 'main',
  keyPrefix: 'user/alice',
);
await cellar.open();
```

A brand-new substrate (GCS, DynamoDB, an in-memory test double) is one class implementing `StorageBackend` — the whole facade (partitions, scoping, lifecycle, encryption) runs on top of it unchanged. The [example app](https://github.com/whuppi/cellar_flutter/tree/dev/example)'s Custom tab ships a complete in-memory backend; the conformance battery in `test/batteries/` is the contract a new backend must pass.

---

## Error handling

Failures are a sealed hierarchy — pattern-match the ones you can act on, and nothing is ever silently swallowed:

```dart
try {
  await cellar.read('missing');
} on FileNotFoundError catch (e) {
  print('missing key: ${e.key}');
} on ChunkVerificationError catch (e) {
  print('tampered chunk ${e.chunkIndex}');
} on StorageError catch (e) {
  print('storage error: $e');
}
```

| Error | Means |
|---|---|
| `FileNotFoundError` | Key doesn't exist |
| `EncryptionKeyMissingError` | Encrypted object, but the resolver returned no key — never silent ciphertext |
| `CorruptedFileError` | Body data unrecoverable |
| `CorruptedMetadataError` | Metadata present but broken, with no truth to rebuild from |
| `ChunkVerificationError` | A chunk's MAC failed — carries the chunk index |
| `InvalidHeaderError` | Encrypted-format header unparseable |
| `InvalidKeyError` | Key violates the grammar |
| `WriteError` | The write itself failed (disk full, quota) |

Recoverable situations recover silently instead of throwing: an unparseable metadata sidecar (the body is truth) is rebuilt on the next write; a failed backup-exclusion attribute degrades to the safe backed-up state.

Plain `throw`s are reserved for programmer error — `StateError` for using a closed cellar, `ArgumentError` for invalid configuration.

---

## Platform support

| iOS | Android | macOS | Windows | Linux | Web | Servers / CLI |
|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| ✅ | ✅ via [`cellar_flutter`](https://github.com/whuppi/cellar_flutter) | ✅ | ✅ | ✅ | ✅ IndexedDB | ✅ |

### Where the data lands

Exactly where you said. On native, `roots.support` holds persistent partitions and `roots.cache` holds `osManaged` ones (`<root>/<name>/<partition>/…`); `Cellar.atPath` puts everything under the one directory you gave. On web, storage is IndexedDB — one database per partition, no directories involved.

Flutter apps don't pick paths at all: [`cellar_flutter`](https://github.com/whuppi/cellar_flutter)'s `openCellar` supplies the app's official support and cache directories on every platform.

---

## Not in the box

What the shipped package doesn't do, and what to reach for in the meantime. Full per-capability status in the [capability roadmap](docs/CAPABILITY_ROADMAP.md).

- **Structured records / queries.** Cellar lists by key prefix — no indexes, no search. For records and queries use a database ([`drift`](https://pub.dev/packages/drift), [`hive`](https://pub.dev/packages/hive)); keep an index there that maps queries → cellar keys.
- **Key-value preferences.** For small string KV, [`shared_preferences`](https://pub.dev/packages/shared_preferences) is the right tool — cellar is for bytes.
- **Per-key TTL.** Lifecycle rules are per-partition. Give expiring data its own partition, or design key names so eviction can target by prefix.
- **User-visible files** (Files app, Downloads, share sheets, pickers). Cellar is an app-private store — for "give a file to the user" or "let the user pick one," use [`device_io`](https://pub.dev/packages/device_io); cellar stores the bytes those flows produce.
- **Sync, and first-party remote backends.** Two cellars don't auto-sync, and materialize's web URLs are local-session Blob URLs, not public links — serving assets to other users is CDN/server territory. Cellar deliberately ships no remote backend: `StorageBackend` + the conformance battery are the offering — implement one over your remote of choice and run the same exam the built-ins pass. A first-party remote satellite package returns if a real consumer's read/write patterns drive it.
- **Compression.** Deliberate: apps that store compressible data do it in two lines (`gzip.encode` before write) and own the trade, media is already compressed, and transparent compression would break the O(range) `readRange` promise. One rule to know: compress *before* encrypting — ciphertext doesn't compress.
- **Locking.** Same-key write serialization is your app's job; reads are concurrent-safe with reads.

---

## Docs

The README covers the everyday stuff. wanna go deeper?

| Doc | What's inside |
|---|---|
| [Architecture](docs/ARCHITECTURE.md) | How it's built: the contract, the tree, the platform seam, durability mechanics |
| [Capabilities](docs/CAPABILITY_ROADMAP.md) | What's shipped, what's planned, what won't happen |
| [Updating](docs/UPDATING.md) | Maintenance recipes and the pinned-behavior watchlist |
| [Contributing](CONTRIBUTING.md) | Setup, PR workflow, adding backends and decorators |

---

## License

MIT. See [LICENSE](LICENSE).
