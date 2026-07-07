<!--
============================================================================
AUTO-GENERATED — DO NOT EDIT
============================================================================
This file is rendered by:
  /Users/deepanshu/personal1/whuppi/.claude/scripts/stamp-agents.sh
from:
  /Users/deepanshu/personal1/whuppi/AGENTS.template.md
  with per-repo data inlined in the stamper itself.

To change content:
  - Workspace-wide: edit AGENTS.template.md, then re-run the stamper.
  - One repo only:  edit the `repo_data` case for "cellar" in stamp-agents.sh,
                    then re-run the stamper.
Manual edits to this file will be overwritten on the next stamp.
============================================================================
-->

# cellar

> **Public AI agent contract** for cellar — read by Cursor, OpenAI Codex, Aider, Devin, JetBrains Junie, and any AI tool that follows the [agents.md](https://agents.md) convention.
>
> Claude Code reads the deeper workspace config at `whuppi/.claude/rules/` and `whuppi/.claude/memory/` automatically — this AGENTS.md exists for every *other* AI tool.
>
> Stamped from `whuppi/AGENTS.template.md`. Per-repo content lives in the placeholder sections; everything else is identical workspace-wide.

---

## What this tool does

Cellar is cross-platform object storage for Dart & Flutter — pure Dart,
no Flutter SDK, no plugins: the filesystem (native, dart:io) and
IndexedDB (web, package:web) behind one key/value `StorageBackend`
contract. Remote backends are
bring-your-own: implement `StorageBackend`, run the conformance
battery. On top of the backends
sit composable decorators (chunking for stores with per-record limits,
bring-your-own-crypto encryption) and a `Cellar` facade adding
partitions, key-prefix scoping, lifecycle eviction, and platform-local
materialization (file path on native, Blob URL on web). Native storage
roots are caller-supplied — the core never guesses locations; the
sibling `cellar_flutter` package resolves them for Flutter apps. No
app-domain concepts anywhere — keys in, bytes out.

This repo is one tool inside the **whuppi** workspace — a multi-tool monorepo. The workspace ships shared engineering standards, code conventions, brand identity, and build patterns that apply across every tool. They're documented in three layers:

- **Repo-specific architecture, design, reference:** `./docs/`
- **Workspace human-readable standards:** `../docs/` (when this repo is cloned as part of the whuppi workspace) — engineering principles, decision frameworks, secret/CI patterns
- **Workspace AI-only directives:** `../.claude/rules/` (Claude Code reads these automatically; other AI tools can read them as supplementary context)

If you're working on this tool standalone (cloned outside the workspace), the in-repo `./docs/` is your authority; ignore the workspace pointers.

---

## Build and test commands

Run these after every code change. A failing test or analyzer error means the task is not done — don't suppress with `// ignore:`, `# noqa`, or `--no-verify`. Fix the underlying issue.

```bash
make check          # full gate: format + analyze + floor + lint-shell +
                    # platforms + test-guards + VM tests + Chrome tests
make test-unit      # VM batteries + native platform suites (dart test)
make test-web       # every battery again in real Chrome (dart test -p chrome)
```

---

## Code style

Match the style of existing code in this repo first. Workspace-wide standards live at:

- **Engineering standards** (seven questions before every decision, env-blind code, twelve-factor checklist): `../docs/universal/development-standards.md`
- **Secrets and environments** (GitHub Environments, branch=env, security walls, files-not-env-vars): `../docs/universal/secrets-and-environments.md`
- **Python tools** (SDK/CLI/MCP three-layer pattern, ruff config, hatchling): `../.claude/rules/python-shared/sdk-cli-mcp-pattern.md`
- **Flutter packages** (opaque boundaries, async at edges, dependency flow): `../.claude/rules/flutter-shared/package-design.md`
- **Comments and doc-comments** (what earns a comment, what doesn't): `../.claude/rules/universal/comments.md`
- **Renaming anything** (sweep all references in one session): `../.claude/rules/universal/rename-hygiene.md`

When in doubt, read existing code in this repo and match it. Per-repo style consistency beats general-best-practice consistency.

---

## Tool-specific notes

- **The conformance battery is the contract.** Every `StorageBackend` —
  shipped or custom — must pass `test/batteries/conformance_battery.dart`
  identically, on the VM and in Chrome. A new backend's first test is one
  `runStorageBackendConformance` invocation in each runner.
- **Prefixes are RAW string prefixes, S3-style.** `list('photos')` matches
  `photos2`; end with `/` to scope to a pseudo-directory. ChunkedBackend's
  physical suffix keys depend on raw matching — do not "fix" this to
  segment-scoped.
- **Write atomicity is a contract.** A failed writeStream never leaves a
  torn object: FileSystemBackend stages to a temp + renames; ChunkedBackend
  writes generation-tagged chunks and swaps the manifest last.
- **Creator disposes.** Decorators never dispose the backend they wrap;
  `Cellar.close()` disposes only what it built.
- **Web tests use `dart test -p chrome test/runners/web_runner_test.dart`**,
  never `flutter test --platform chrome` (CanvasKit hang — see
  dart_test.yaml). No 64-bit ByteData accessors anywhere — dart2js has
  none; a guard rejects them.
- **The core never guesses storage locations.** No env reads, no
  conventions, no plugin asks — `roots:` / `atPath` are the only
  sources. Autos belong to `cellar_flutter`.
- **The package is app-blind.** No userId/profileId/domain concepts may
  enter the API. Apps build key schemes on top.

---

## Data, secrets, and gitignore

This repo's `.gitignore` is stamped from `../.gitignore.template` (workspace canonical). It already covers:

- `data/.env` and every other `.env` flavor (only `.env.example` / `.env.template` / `.env.sample` are committed)
- `data/auth/` (captured tokens, cookies, OAuth credentials)
- `data/db/*.sqlite*` (full app state — irreplaceable)
- `cookies*.json`, `*.token`, `*.pem`, `*.key`
- `output/`, `debug/`, `logs/`, `cache/`

Never commit a sensitive file even if it's somehow not gitignored — surface to the maintainer instead. The gitignore is defense-in-depth, not the only check.

---

## Working with AI agents

- **Run the test suite before claiming completion.** Always.
- **Don't add `TODO` comments as a substitute for fixing things.** If you found it, you own it — fix in this pass or surface to the maintainer.
- **Don't add backwards-compat shims** for code that hasn't shipped. Code assumes the latest schema and contracts; migrations handle old data once.
- **Don't refactor "for cleanliness" without a stated reason.** Surface the suggestion before changing surrounding code.
- **No co-authored-by AI in commits.** The maintainer is the author.
- **Never force-push protected branches** (`prod`, `main`, `dev`). Never skip pre-commit hooks.

For the engineering philosophy that informs every line of code in this workspace, see `../.claude/rules/universal/dc-engineering-philosophy.md` if available.

---

*This file is stamped from `whuppi/AGENTS.template.md`. The placeholder sections (`{{...}}`) are the only parts customized per repo. Re-stamping refreshes the shared content; per-repo placeholders are preserved.*
