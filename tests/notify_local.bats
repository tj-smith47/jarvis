#!/usr/bin/env bats
# Tests for lib/notify/local.sh — osascript / notify-send
# auto-detection plus dryrun mode.

bats_require_minimum_version 1.5.0

load 'helper'
load 'shim_helper'

setup() {
  jarvis_common_setup
  shim_setup
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/state/profile.sh"
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/state/lock.sh"
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/notify/registry.sh"
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/notify/local.sh"
  state_ensure_tree
}

teardown() {
  jarvis_common_teardown
}

# Mask any real osascript / notify-send binary by installing a deliberately
# failing shim. Tests that want a working notifier override after this.
_mask_real_notifiers() {
  shim_install osascript 'exit 127'
  shim_install notify-send 'exit 127'
}

# ---------- registration ----------

@test "local channel auto-registers via notify_register" {
  run notify_channels
  [ "$status" -eq 0 ]
  [ "$output" = "local" ]
}

# ---------- dryrun ----------

@test "dryrun → notify.log row + exit 0 (no notifier needed)" {
  _mask_real_notifiers   # proves dryrun does not touch real binaries
  JARVIS_NOTIFY_DRYRUN=1 run notify_local "stand up"
  [ "$status" -eq 0 ]
  log="$JARVIS_HOME/test/notify.log"
  [ -f "$log" ]
  ok="$(jq -r '.ok' < "$log")"
  msg="$(jq -r '.message' < "$log")"
  [ "$ok" = "true" ]
  [ "$msg" = "stand up" ]
}

@test "dryrun honors profile arg" {
  mkdir -p "$JARVIS_HOME/work"
  JARVIS_NOTIFY_DRYRUN=1 run notify_local "test" "work"
  [ "$status" -eq 0 ]
  [ -f "$JARVIS_HOME/work/notify.log" ]
}

# ---------- empty message ----------

@test "empty message logs failure + exit 1" {
  JARVIS_NOTIFY_DRYRUN=1 run notify_local ""
  [ "$status" -eq 1 ]
  log="$JARVIS_HOME/test/notify.log"
  ok="$(jq -r '.ok' < "$log")"
  err="$(jq -r '.error' < "$log")"
  [ "$ok" = "false" ]
  [ "$err" = "empty message" ]
}

# ---------- real notifier path ----------

@test "osascript path: success → ok=true" {
  shim_install osascript 'exit 0'
  shim_install notify-send 'exit 127'   # ensure osascript is preferred
  run notify_local "hi"
  [ "$status" -eq 0 ]
  log="$JARVIS_HOME/test/notify.log"
  ok="$(jq -r '.ok' < "$log")"
  [ "$ok" = "true" ]
}

@test "osascript failure → ok=false + osascript-named error" {
  shim_install osascript 'exit 1'
  shim_install notify-send 'exit 127'
  run notify_local "hi"
  [ "$status" -eq 1 ]
  log="$JARVIS_HOME/test/notify.log"
  ok="$(jq -r '.ok' < "$log")"
  err="$(jq -r '.error' < "$log")"
  [ "$ok" = "false" ]
  [[ "$err" == *"osascript"* ]]
}

@test "no osascript: notify-send fallback succeeds" {
  shim_uninstall osascript   # remove from PATH so command -v misses
  # Mask any system osascript above the SHIM_DIR? command -v only finds
  # the first match; if the test host has no osascript anywhere, fine; if
  # it has one, we'd want to fully mask. CI/macOS may need follow-up.
  shim_install notify-send 'exit 0'
  if command -v osascript >/dev/null 2>&1; then
    skip "osascript present on host outside shim — would short-circuit fallback"
  fi
  run notify_local "hi"
  [ "$status" -eq 0 ]
  log="$JARVIS_HOME/test/notify.log"
  ok="$(jq -r '.ok' < "$log")"
  [ "$ok" = "true" ]
}

@test "no notifier available → ok=false + named error" {
  shim_uninstall osascript
  shim_uninstall notify-send
  if command -v osascript >/dev/null 2>&1 || command -v notify-send >/dev/null 2>&1; then
    skip "host has osascript or notify-send outside shim — cannot test no-notifier path"
  fi
  run notify_local "hi"
  [ "$status" -eq 1 ]
  log="$JARVIS_HOME/test/notify.log"
  err="$(jq -r '.error' < "$log")"
  [[ "$err" == *"no notifier available"* ]]
}
