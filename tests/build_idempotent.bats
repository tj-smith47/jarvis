#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

load helper

# Verifies that `task build` honours Task's checksum-based incremental-build
# contract:
#   1. Cold build produces all three stub binaries.
#   2. A second immediate build is a no-op (binary mtimes unchanged).
#   3. Touching a jarvis-state source forces ONLY build:state to re-run;
#      build:cal and build:when stay untouched.
#
# Idempotency check is by binary mtime rather than parsing Task's stdout —
# the root Taskfile sets `silent: true` so "up to date" messages are
# suppressed by default and `--verbose` interacts poorly with `--output=prefixed`.

JARVIS_DIR=
TASK=

setup() {
  # Pre-resolve JARVIS_DIR via BATS_TEST_DIRNAME (no HOME dependency).
  JARVIS_DIR="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  REAL_HOME="$HOME"        # save before jarvis_common_setup redirects
  jarvis_common_setup
  TASK="$(command -v task)"
}

teardown() {
  jarvis_common_teardown
  # Purge Task's checksum cache so each test gets a clean dirty/clean
  # decision, but leave bin/ alone — downstream test files (doctor.bats's
  # --reap-focus-orphans path, status.bats, etc.) source lib/native/clock.sh
  # which execs bin/jarvis-when. Deleting it here would strand them.
  # Each @test rebuilds via _run_build so the freshness invariant is local.
  rm -rf "$JARVIS_DIR/.task"
}

_run_build() {
  # Run with the REAL home so cargo/rustup/go can find their toolchains.
  # The redirected jarvis_common_setup HOME is restored after `run` returns.
  run bash -c "
    cd '$JARVIS_DIR'
    export HOME='$REAL_HOME'
    export FRAMEWORK_DIR='$CLIFT_FRAMEWORK_DIR'
    export CLI_DIR='$JARVIS_DIR'
    export CLI_NAME=jarvis
    export CLI_VERSION=test
    '$TASK' build 2>&1
  "
}

_mtime_ns() {
  # Portable mtime in nanoseconds; falls back to seconds on BSD stat.
  stat -c '%Y%N' "$1" 2>/dev/null || stat -f '%m000000000' "$1"
}

@test "cold build: all three stub binaries are produced" {
  # Hermetic cold-build assertion: nuke binaries + Task checksum cache
  # for THIS test only. The file-level teardown deliberately leaves bin/
  # populated so downstream test files (doctor.bats reap, status.bats, …)
  # find a working bin/jarvis-when.
  rm -f "$JARVIS_DIR/bin/jarvis-state" \
        "$JARVIS_DIR/bin/jarvis-cal" \
        "$JARVIS_DIR/bin/jarvis-when"
  rm -rf "$JARVIS_DIR/.task"

  _run_build
  [ "$status" -eq 0 ] || { echo "build failed: $output"; return 1; }
  [ -x "$JARVIS_DIR/bin/jarvis-state" ]
  [ -x "$JARVIS_DIR/bin/jarvis-cal" ]
  [ -x "$JARVIS_DIR/bin/jarvis-when" ]
}

@test "second build is a no-op: binary mtimes unchanged" {
  _run_build
  [ "$status" -eq 0 ] || { echo "first build failed: $output"; return 1; }
  local mt_state mt_cal mt_when
  mt_state="$(_mtime_ns "$JARVIS_DIR/bin/jarvis-state")"
  mt_cal="$(_mtime_ns "$JARVIS_DIR/bin/jarvis-cal")"
  mt_when="$(_mtime_ns "$JARVIS_DIR/bin/jarvis-when")"

  sleep 1   # ensure any rebuild would produce a distinguishable mtime
  _run_build
  [ "$status" -eq 0 ] || { echo "second build failed: $output"; return 1; }

  [ "$(_mtime_ns "$JARVIS_DIR/bin/jarvis-state")" = "$mt_state" ]
  [ "$(_mtime_ns "$JARVIS_DIR/bin/jarvis-cal")"   = "$mt_cal"   ]
  [ "$(_mtime_ns "$JARVIS_DIR/bin/jarvis-when")"  = "$mt_when"  ]
}

@test "touching jarvis-state source forces only build:state to rebuild" {
  _run_build
  [ "$status" -eq 0 ] || { echo "cold build failed: $output"; return 1; }
  local src="$JARVIS_DIR/jarvis-state/main.go"
  [ -f "$src" ] || skip "jarvis-state/main.go not present"

  local mt_cal mt_when
  mt_cal="$(_mtime_ns "$JARVIS_DIR/bin/jarvis-cal")"
  mt_when="$(_mtime_ns "$JARVIS_DIR/bin/jarvis-when")"

  # Hermetic mutation: remember original, append marker, restore in teardown.
  local original
  original="$(cat "$src")"

  sleep 1
  printf '\n// touched-by-bats\n' >> "$src"

  _run_build
  local rc=$status
  # Restore source first so a failure mid-test still cleans up.
  printf '%s' "$original" > "$src"
  rm -rf "$JARVIS_DIR/.task"   # purge the dirty checksum

  [ "$rc" -eq 0 ] || { echo "rebuild failed: $output"; return 1; }
  # cal and when must NOT have been rebuilt.
  [ "$(_mtime_ns "$JARVIS_DIR/bin/jarvis-cal")"  = "$mt_cal"  ]
  [ "$(_mtime_ns "$JARVIS_DIR/bin/jarvis-when")" = "$mt_when" ]
}

# Regression guard: this file's teardown MUST leave bin/ populated, otherwise
# downstream test files (doctor.bats's --reap-focus-orphans path,
# status.bats, standup.bats, ...) source lib/native/clock.sh, which execs
# bin/jarvis-when and silently misbehaves when the binary is missing —
# the doctor reap loop falls through `|| continue` and reports "reaped 0".
# Asserts bin/ is populated entering this test. If a preceding test's
# teardown deletes the binaries (the bug this commit fixes), this
# assertion fires before the leak strands later suites.
@test "teardown does not strand bin/ for downstream test files" {
  [ -x "$JARVIS_DIR/bin/jarvis-state" ]
  [ -x "$JARVIS_DIR/bin/jarvis-cal" ]
  [ -x "$JARVIS_DIR/bin/jarvis-when" ]
}
