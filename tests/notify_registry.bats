#!/usr/bin/env bats
# Tests for lib/notify/registry.sh — channel registration
# and the uniform _notify_log helper that all channels emit through.

bats_require_minimum_version 1.5.0

load 'helper'

setup() {
  jarvis_common_setup
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/state/profile.sh"
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/state/lock.sh"
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/notify/registry.sh"
  state_ensure_tree
}

teardown() {
  jarvis_common_teardown
}

# ---------- notify_register / notify_channels ----------

@test "register one channel then list it" {
  fake_fn() { :; }
  notify_register foo fake_fn
  run notify_channels
  [ "$status" -eq 0 ]
  [ "$output" = "foo" ]
}

@test "register multiple channels — list sorted" {
  fake_fn() { :; }
  notify_register zeta fake_fn
  notify_register alpha fake_fn
  notify_register mu fake_fn
  run notify_channels
  [ "$status" -eq 0 ]
  [ "$output" = "alpha
mu
zeta" ]
}

@test "double register is idempotent (no duplicates)" {
  fake_fn() { :; }
  notify_register foo fake_fn
  notify_register foo fake_fn
  run notify_channels
  [ "$output" = "foo" ]
}

@test "register without args errors" {
  run notify_register
  [ "$status" -eq 2 ]
}

@test "notify_channels with empty registry returns empty" {
  run notify_channels
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------- _notify_log ----------

@test "_notify_log writes one parseable JSON line" {
  _notify_log "local" "true" "hello"
  log="$JARVIS_HOME/test/notify.log"
  [ -f "$log" ]
  count="$(wc -l < "$log")"
  [ "$count" -eq 1 ]
  ch="$(jq -r '.channel' < "$log")"
  ok="$(jq -r '.ok' < "$log")"
  msg="$(jq -r '.message' < "$log")"
  [ "$ch" = "local" ]
  [ "$ok" = "true" ]
  [ "$msg" = "hello" ]
}

@test "_notify_log includes error field when given" {
  _notify_log "gotify" "false" "hello" "500 from server"
  log="$JARVIS_HOME/test/notify.log"
  err="$(jq -r '.error' < "$log")"
  [ "$err" = "500 from server" ]
}

@test "_notify_log omits error field when not given" {
  _notify_log "local" "true" "hello"
  log="$JARVIS_HOME/test/notify.log"
  has_err="$(jq 'has("error")' < "$log")"
  [ "$has_err" = "false" ]
}

@test "_notify_log appends across multiple calls" {
  _notify_log "local" "true" "first"
  _notify_log "gotify" "false" "second" "boom"
  log="$JARVIS_HOME/test/notify.log"
  count="$(wc -l < "$log")"
  [ "$count" -eq 2 ]
}

@test "_notify_log honors explicit profile arg (no env mutation)" {
  mkdir -p "$JARVIS_HOME/work"
  before="$JARVIS_PROFILE"
  _notify_log "local" "true" "hello" "" "work"
  log="$JARVIS_HOME/work/notify.log"
  [ -f "$log" ]
  [ "$JARVIS_PROFILE" = "$before" ]
}
