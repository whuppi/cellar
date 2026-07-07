# Contributing

Contributions are welcome.

---

## Setup

```bash
git clone https://github.com/whuppi/cellar.git
cd cellar
make hooks               # activates commit-msg + pre-commit (run once)
fvm install              # downloads the SDK version pinned in .fvmrc
fvm dart pub get
fvm dart test            # pure Dart — no native toolchain, nothing to compile
```

**Requires:** [FVM](https://fvm.app) (`.fvmrc` pins the exact SDK
version) and Chrome (the web suite runs the same batteries in a real
browser).

**Without FVM:** all Makefile commands accept `DART` and `FLUTTER`
overrides:

```bash
make check DART=dart FLUTTER=flutter
```

---

## Before submitting a PR

```bash
make check
```

Runs `format` + `analyze` + `analyze-floor` (lowest allowed deps) +
`lint-shell` + `platforms` (pana attribution) + `test-guards`
(mechanical test-suite rules) + `test` (VM + real-Chrome batteries).
Must pass. Don't suppress with `// ignore:` — fix the underlying
issue.

Touching `cellar_flutter` too? It consumes this repo as a pinned
submodule — after your change lands here, bump the pin there and run
its `make check` as well.

---

## PR workflow

All PRs target `dev`. That's the only branch contributors touch.

```
your fork / feature branch ──PR──► dev
                                    ↓ CI: make targets via the make-target action
                                    ↓ PR title: Conventional Commits (feat: / fix: / etc.)
                                    ↓ squash-merge when green
                                    ↓ Full test suite via "ready-to-test" label
                                      (batteries × OS matrix, real Chrome, real Windows)
```

CI calls Makefile targets — same commands locally and in CI.

You don't write changelog entries, bump versions, or touch `prod`.
The maintainer handles releases.

---

## Code style

- Match existing code in the repo.
- No `dart:io` reachable from `lib/cellar.dart` on web — the barrel
  stays web-safe via the conditional exports in `default_backend/`
  and the backend split. `dart:io` code lives behind `*_native.dart`
  / `*_io.dart` files only.
- **The core never guesses storage locations.** No environment reads,
  no conventions, no plugin asks. Locations arrive via `roots:` /
  `atPath` — autos belong to `cellar_flutter`.
- Backends implement `StorageBackend` completely and pass the
  conformance battery — behavior is pinned there, not in per-backend
  tests. Platform-bound quirks go in `test/platform/`.
- Tests are platform-blind batteries invoked by runners — read the
  test-architecture section of
  [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) before adding any.
- No 64-bit `ByteData` accessors (`setUint64` / `getUint64`) —
  dart2js has none; write two 32-bit halves (a guard enforces this).

---

## Adding backends, decorators, facade methods

Step-by-step checklists in [`docs/UPDATING.md`](docs/UPDATING.md).

---

## Releases

Handled by the maintainer. Details in [`docs/UPDATING.md`](docs/UPDATING.md).
