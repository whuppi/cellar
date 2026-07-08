# ═══════════════════════════════════════════════════════════════════
# SDK resolution
#
# Uses fvm by default (.fvmrc pins the version). Contributors without
# fvm can override:  make check DART=dart FLUTTER=flutter
# ═══════════════════════════════════════════════════════════════════

DART    ?= fvm dart
FLUTTER ?= fvm flutter
TEST_RESULTS_DIR ?= test-results
TIMEOUT := $(if $(CI),--timeout=30x,)
VERBOSE := $(if $(CI),--verbose,)

.PHONY: check hooks \
        analyze analyze-floor lint-shell platforms format test-guards \
        test test-unit test-web \
        clean

# ═══════════════════════════════════════════════════════════════════
# § 1 — Gate
#
# make check    Full local gate before PR.
# make hooks    Activate the repo's git hooks (commit-msg, pre-commit).
#               Run once after cloning — they stay dormant otherwise.
#               Idempotent.
# ═══════════════════════════════════════════════════════════════════

check: format analyze analyze-floor lint-shell platforms test-guards test

hooks:
	@git config core.hooksPath .githooks
	@echo "✓ git hooks active (core.hooksPath → .githooks)"

# ═══════════════════════════════════════════════════════════════════
# § 2 — Analyze
#
# make format         Formatter in check mode — fails on unformatted files
#                     (CI is never the first place the formatter runs).
# make analyze        Static analysis via the shared analyze_core.sh (canonical
#                     in whuppi/ci, stamped into tool/) — a suppression-comment
#                     ban + dart/flutter analyze --fatal-infos over lib, test,
#                     tool, and example; an INFO fails like an error.
# make analyze-floor  Resolve to the OLDEST in-range dependencies and
#                     analyze the shipped code (lib only). The lower bounds
#                     are only honest if the code analyzes against them.
#                     Snapshots and restores the lock so a local run leaves
#                     the tree clean.
# make platforms      Gate pub.dev platform support via the shared
#                     platforms_gate.sh: pana (pinned in tool/versions.env)
#                     must report all six platforms — a regression like an
#                     unconditional dart:io import silently drops web (the
#                     conditional re-exports in backends/ are what it
#                     protects).
# make lint-shell     Shell portability gate via the shared lint_shell.sh:
#                     shellcheck + a bash-3.2 + BSD scan over every tracked
#                     script and workflow run block.
# ═══════════════════════════════════════════════════════════════════

format:
	$(DART) format --output=none --set-exit-if-changed .

analyze:
	@DART="$(DART)" FLUTTER="$(FLUTTER)" bash tool/analyze_core.sh

analyze-floor:
	@cp pubspec.lock .pubspec.lock.floor-backup
	$(DART) pub downgrade
	$(DART) analyze lib
	@mv .pubspec.lock.floor-backup pubspec.lock
	@$(DART) pub get >/dev/null
	@echo "✓ floor analyze clean (lockfile restored)"

platforms:
	@DART="$(DART)" EXPECTED_PLATFORMS="android ios linux macos windows web" bash tool/platforms_gate.sh

lint-shell:
	@bash tool/lint_shell.sh

# ═══════════════════════════════════════════════════════════════════
# § 2b — Test-suite guards
#
# make test-guards   Mechanical rules over the suite itself:
#                    - package:web / dart:js_interop only under
#                      test/platform/web/ or the web runner (the VM
#                      suites must compile without a browser target)
#                    - no dart:ffi anywhere in test/ — FFI stays behind
#                      the FileSystemOs seam; tests drive the seam, not
#                      the syscalls
#                    - no empty directories in lib/ or test/ —
#                      incomplete or superseded work
#                    - no 64-bit ByteData accessors anywhere — dart2js
#                      has none, and the suite runs in real Chrome
#                    - no same-named test files in different
#                      directories — merge at the location mirroring
#                      lib/
# ═══════════════════════════════════════════════════════════════════

test-guards:
	@bad=$$(grep -rln "package:web/\|dart:js_interop" test/ --include="*.dart" \
	  | grep -v "^test/runners/web_runner_test.dart" \
	  | grep -v "^test/platform/web/" || true); \
	if [ -n "$$bad" ]; then \
	  echo "browser-only import outside test/platform/web/ or the web"; \
	  echo "runner — everything else must compile without a browser:"; \
	  echo "$$bad"; exit 1; fi
	@bad=$$(grep -rln "dart:ffi" test/ --include="*.dart" || true); \
	if [ -n "$$bad" ]; then \
	  echo "dart:ffi in a test — FFI stays behind the FileSystemOs seam:"; \
	  echo "$$bad"; exit 1; fi
	@empty=$$(find lib test -type d -empty); \
	if [ -n "$$empty" ]; then \
	  echo "empty directories — incomplete or superseded work, delete them:"; \
	  echo "$$empty"; exit 1; fi
	@bad=$$(grep -rln "etUint64\|etInt64" lib/ example/lib test/ --include="*.dart" || true); \
	if [ -n "$$bad" ]; then \
	  echo "64-bit ByteData accessors — dart2js has none; use two 32-bit"; \
	  echo "halves (~/ and % 0x100000000):"; \
	  echo "$$bad"; exit 1; fi
	@dupes=$$(find test -name "*_test.dart" -exec basename {} \; | sort | uniq -d); \
	if [ -n "$$dupes" ]; then \
	  echo "same-named test files in different directories — merge at the"; \
	  echo "location mirroring lib/:"; \
	  echo "$$dupes"; exit 1; fi
	@echo "✓ test guards clean"

# ═══════════════════════════════════════════════════════════════════
# § 3 — Test
#
# make test        Unit (VM) + the same batteries in Chrome.
# make test-unit   Every battery + conformance + the native-only
#                  suites (real filesystem, OS seam) on the VM.
# make test-web    The SAME batteries in real Chrome, plus the browser-
#                  only suites (IndexedDB, Blob URLs) — `dart test`, NOT
#                  `flutter test --platform chrome` (CanvasKit hang; see
#                  dart_test.yaml).
# ═══════════════════════════════════════════════════════════════════

test: test-unit test-web

test-unit:
	@echo "=== Unit: VM (batteries + conformance + native suites) ==="
	@mkdir -p $(TEST_RESULTS_DIR)
	$(DART) test $(TIMEOUT) -p vm --file-reporter json:$(TEST_RESULTS_DIR)/unit.json

# The example is the integration surface for a pure-Dart package: run it
# as a real program on a real OS (int tier), and prove a shipping binary
# links against the package (verify tier). CI runs both on Linux, macOS,
# and Windows runners.
test-example:
	@$(DART) example/main.dart
	@echo "✓ CLI example ran clean"

verify-example:
	@mkdir -p build
	@case "$$(uname -s)" in MINGW*|MSYS*|CYGWIN*) out=build/example_cli.exe ;; *) out=build/example_cli ;; esac; \
	$(DART) compile exe example/main.dart -o "$$out" >/dev/null && "./$$out" >/dev/null && \
	echo "✓ compiled release executable runs against cellar ($$out)"

test-web:
	@echo "=== Web: batteries + IndexedDB + Blob in real Chrome (dart test) ==="
	@mkdir -p $(TEST_RESULTS_DIR)
	@if [ "$$(uname -s)" = "Linux" ] && [ -n "$$CI" ]; then \
	  base="$${CHROME_EXECUTABLE:-$$(command -v google-chrome-stable || command -v google-chrome || command -v chromium)}"; \
	  printf '#!/bin/sh\nexec "%s" --no-sandbox --disable-gpu "$$@"\n' "$$base" > $(TEST_RESULTS_DIR)/chrome-ci; \
	  chmod +x $(TEST_RESULTS_DIR)/chrome-ci; \
	  export CHROME_EXECUTABLE="$$PWD/$(TEST_RESULTS_DIR)/chrome-ci"; \
	fi; \
	$(DART) test $(TIMEOUT) -p chrome test/runners/web_runner_test.dart --concurrency=1 --file-reporter json:$(TEST_RESULTS_DIR)/web.json

# ═══════════════════════════════════════════════════════════════════
# § 4 — Clean
# ═══════════════════════════════════════════════════════════════════

clean:
	rm -rf .dart_tool $(TEST_RESULTS_DIR)
