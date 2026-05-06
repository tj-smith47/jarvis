#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

load helper

setup() {
  jarvis_common_setup
  source "$JARVIS_DIR/lib/state/lock.sh"
  export LOCK_TARGET="$JARVIS_HOME/test/guarded.json"
  mkdir -p "$JARVIS_HOME/test"
}
teardown() { jarvis_common_teardown; }

@test "state_with_lock runs callback and releases lock" {
  state_with_lock "$LOCK_TARGET" 'printf hello > "$LOCK_TARGET"'
  [ "$(< "$LOCK_TARGET")" = "hello" ]
}

@test "state_with_lock serializes concurrent writers" {
  (state_with_lock "$LOCK_TARGET" 'sleep 0.2; printf A >> "$LOCK_TARGET"') &
  pid1=$!
  sleep 0.05
  (state_with_lock "$LOCK_TARGET" 'printf B >> "$LOCK_TARGET"') &
  pid2=$!
  wait "$pid1" "$pid2"
  # A must land before B due to serialization
  [ "$(< "$LOCK_TARGET")" = "AB" ]
}

@test "state_with_lock returns callback exit status" {
  run state_with_lock "$LOCK_TARGET" 'exit 7'
  [ "$status" -eq 7 ]
}

@test "state_with_lock body \`exit\` does not kill the caller script" {
  # The bats `run` form forks a subshell which masks the bug — exit
  # inside { ... } would kill the run subshell, not the test process.
  # Drive a fresh bash that calls the function inline so we observe the
  # caller's behaviour after the locked block exits non-zero.
  bash <<EOF >"$JARVIS_HOME/caller.out" 2>&1
set -uo pipefail
source "$JARVIS_DIR/lib/state/lock.sh"
state_with_lock "$LOCK_TARGET" 'exit 2' || rc=\$?
printf 'after-block rc=%s\n' "\${rc:-0}"
EOF
  run cat "$JARVIS_HOME/caller.out"
  [ "$status" -eq 0 ]
  [[ "$output" == *"after-block rc=2"* ]]
}
