# Updating cellar

Maintenance recipes. For architecture see
[`ARCHITECTURE.md`](ARCHITECTURE.md). For capability status see
[`CAPABILITY_ROADMAP.md`](CAPABILITY_ROADMAP.md).

---

## The pinned-behavior watchlist

cellar leans on behaviors that are not part of anyone's semver-stable
API. Every dependency or SDK bump re-verifies the affected rows against
the NEW version's source (read the source in the pub cache — never
trust memory or docs):

| Pinned behavior | Where it's relied on | Re-verify when |
|---|---|---|
| Native roots are caller-supplied — `initBackendForPartition` throws without them; the core reads no environment | `default_backend_native.dart` | if anyone proposes re-adding convention guessing: autos live in cellar_flutter, never here |
| `package:web` IndexedDB surface (`indexedDB.open/deleteDatabase`, request event model) | `indexed_db_backend_web.dart` | any package:web major |
| `kCFURLIsExcludedFromBackupKey` via `CFURLSetResourcePropertyForKey` (iOS, FFI) and `tmutil addexclusion` (macOS) as the backup-exclusion mechanism — the raw `com.apple.MobileBackup` xattr is deprecated since iOS 5.1 and must never come back | `os/ios_…` + `os/macos_…` | OS majors; both halves are observed end-to-end (roadmap) |
| Windows `DeleteFile` sharing-violation + rename-with-open-handles behavior | `os/windows_file_system_os.dart` tombstones | never expected to change; the CI Windows leg would catch it |
| dart2js has NO 64-bit ByteData accessors | everywhere — `make test-guards` rejects `get/setUint64/Int64` in lib, example, and test | Dart SDK majors (if dart2js ever grows them, the guard can relax) |
| `dart test -p chrome`, never `flutter test --platform chrome` | `make test-web` | flutter_test bumps — CanvasKit hangs headless Chrome (see dart_test.yaml) |

## S1 — Upgrade a dependency

1. Read the changelog between current and target (pub cache:
   `~/.pub-cache/hosted/pub.dev/<pkg>-<version>/CHANGELOG.md`).
2. Re-verify every watchlist row for that package against the new
   source.
3. `make check` — the floor gate (`analyze-floor`) proves the lower
   bounds stay honest; bump them if the new code needs newer APIs.

## S2 — Add a backend

1. New sibling folder under `lib/src/backends/<name>/` implementing
   `StorageBackend`. Platform-variant code follows the seam rules
   (`ARCHITECTURE.md`, the platform-seam section): plain-named switch, `_native`/`_web` impls,
   stub default that mirrors the full surface.
2. `cellar/` and `core/` are not touched. If the backend needs a
   BYO seam (a transport or client interface), the interface lives in the backend's
   own folder.
3. Entrypoint: export from `cellar_lowlevel.dart`, or give it its own
   `lib/cellar_<name>.dart` barrel when its deps shouldn't ride along
   (the `lib/cellar_<name>.dart` pattern).
4. **Its first test is one `runStorageBackendConformance` invocation in
   EACH runner** (`test/runners/`). Backend-specific behavior gets its
   own battery; anything genuinely platform-bound goes under
   `test/platform/`.
5. `make platforms` — a new dependency can silently drop platforms
   from pana's walk; check its pubspec and barrel imports BEFORE
   importing it.
6. Roadmap section + changelog entry.

## S3 — Add a decorator

Same as a backend but under `lib/src/decorators/<name>/`: implement
`StorageBackend`, wrap `inner`, never dispose what you didn't create.
Conformance-run it over `InMemoryBackend` in both runners (the
chunked/encrypted invocations are the template). If it composes with
others, add a stack to `stack_battery.dart`.

## S4 — Add a facade method

1. If it belongs to the per-backend contract, it goes on
   `StorageBackend` — and then it must be implementable by EVERY
   backend, with conformance cases pinning it. If only some backends
   can honor it, it goes on the concrete class instead.
2. Facade-level orchestration (cross-partition, lifecycle, scoping)
   goes on `Cellar`, routed through `StorageScope`. Results must speak
   scope-relative keys (`storage_scope.dart` `_unscoped` is the rule).
3. Battery coverage in `cellar_battery.dart` (or `scope_battery.dart`),
   which runs on both worlds automatically.
4. Consider the example: if the capability is user-visible, it earns an
   op button on the matching tab + a journey step.

## S5 — Add an OS quirk

One new override on the `FileSystemOs` subclass for that OS (or a new
subclass wired into `current()` — the package's only `Platform.isX`
site). Never an inline branch in `file_system_backend_native.dart`.
White-box tests import the native file directly and inject `os:`;
cross-OS behavior is testable from any host that way, with the real-OS
CI leg as the final proof.

## S6 — Release

Versions, tags, and publishing belong to the reusable `whuppi/ci`
release workflow (`.github/workflows/release.yml` calls it):
`version: 0.0.0` in pubspec is a placeholder stamped at publish time
from the changelog's top untagged heading. You only write the changelog
summary — one untagged version max per lane file (`CHANGELOG.pre.md`
for dev/prereleases, `CHANGELOG.md` for prod/stable).

The pipeline itself — gate → discover → publish across the two lanes,
and the GitHub environment approval that gates every pub.dev push — is
the shared engine; see whuppi/ci's architecture doc, "The release
surface".

---

## S7 — Device backup-size observation (iOS) — OBSERVED

Done on a real iPhone (see the roadmap row for the verdict). The A/B
that proved it, reproducible any time:

1. Build + install the probe (plants ~8 MiB in an `osBackup: false`
   partition + a 16 KiB control in a backed-up one; sanity-asserts the
   exclusion via the OS resource layer on the way out):
   `fvm flutter build ios --release -t integration_test/backup_size_probe_test.dart`
   then `xcrun devicectl device install app --device <id>
   build/ios/iphoneos/Runner.app`, from the `cellar_flutter` example.
   Launch the app once by tapping its icon (the probe runs at launch).
2. Settings → iCloud → Back Up Now; then Manage Account Storage →
   Backups → this iPhone: the app should be absent or tiny (dev apps
   only appear once they carry backup-eligible bytes).
3. The control round: same steps with
   `backup_size_probe_control_test.dart` (adds ~8 MiB to the BACKED-UP
   partition). After another backup the app appears at ~8 MB — proving
   dev apps do show in that list, so step 2's absence was the exclusion
   working, and the excluded bytes (still on device) never entered.
4. Clean up by uninstalling the app.

Notes for reruns: the phone needs Developer Mode on; wireless install
works but `flutter drive` uninstalls the app afterwards — use the
build + `devicectl install` + manual-launch path above so the data
survives the backup cycle.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Web runner fails with `Uint64 accessor not supported by dart2js` | A 64-bit `ByteData` accessor slipped in | Write the value as two 32-bit halves; the `test-guards` target rejects `setUint64`/`getUint64` before Chrome ever sees them |
| `StateError: cellar: Cellar(name:) on native platforms needs roots` | The default constructor opened without `roots:` | By design — pass `StorageRoots(support:, cache:)`, use `Cellar.atPath`, or (Flutter apps) `package:cellar_flutter`'s `openCellar` |
| A battery passes on VM but fails on Chrome | Backend behavior diverged between worlds | The conformance battery is the contract — fix the backend, never fork the battery per platform |
| `git mv` of a case-only rename does nothing on macOS | Case-insensitive filesystem | Two-step rename: `git mv name tmp && git mv tmp Name` |
| `make analyze` clean locally, red in CI | Analysis ran against a stale `.dart_tool` | `dart pub get` first; `make check` does this ordering for you |
