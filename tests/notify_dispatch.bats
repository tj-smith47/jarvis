#!/usr/bin/env bats
# Tests for lib/notify/dispatch.sh — multi-channel fan-out,
# result composition (any-ok-wins), unknown-channel handling, and uniform
# notify.log emission across channels.

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
  source "${JARVIS_DIR}/lib/state/config.sh"
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/notify/registry.sh"
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/notify/local.sh"
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/notify/gotify.sh"
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/notify/slack.sh"
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/notify/dispatch.sh"
  state_ensure_tree
  cat > "$JARVIS_HOME/test/config.toml" <<'EOF'
[notify.gotify]
url = "https://gotify.example"
token = "tok"
[notify.slack]
webhook = "https://hooks.slack.example/abc"
EOF
}

teardown() {
  jarvis_common_teardown
}

# Build a reminder JSON for testing dispatch.
_reminder() {
  local message="$1" via_json="$2" profile="${3:-test}"
  jq -nc \
    --arg message "$message" --arg profile "$profile" \
    --argjson via "$via_json" \
    '{message:$message, profile:$profile, via:$via}'
}

# ---------- happy path ----------

@test "single channel ok → exit 0 + one notify.log row" {
  JARVIS_NOTIFY_DRYRUN=1 run notify_dispatch "$(_reminder "ping" '["local"]')"
  [ "$status" -eq 0 ]
  log="$JARVIS_HOME/test/notify.log"
  [ -f "$log" ]
  count="$(wc -l < "$log")"
  [ "$count" -eq 1 ]
  ok="$(jq -r '.ok' < "$log")"
  [ "$ok" = "true" ]
}

@test "multi-channel all ok → exit 0 + N notify.log rows" {
  JARVIS_NOTIFY_DRYRUN=1 run notify_dispatch "$(_reminder "ping" '["local","gotify","slack"]')"
  [ "$status" -eq 0 ]
  log="$JARVIS_HOME/test/notify.log"
  count="$(wc -l < "$log")"
  [ "$count" -eq 3 ]
  oks="$(jq -r '.ok' < "$log" | sort -u)"
  [ "$oks" = "true" ]
}

# ---------- partial / total fail ----------

@test "any channel ok → overall ok (partial fail still exits 0)" {
  shim_install curl 'exit 7'   # makes gotify + slack fail
  # Local stays in dryrun → ok. Gotify + slack hit shimmed curl (no dryrun
  # for them since we only set dryrun where intended). Set dryrun for local
  # only by toggling per-channel? Simpler: set dryrun globally; then unset
  # for the curl-using channels via the shim already installed.
  # Actually JARVIS_NOTIFY_DRYRUN affects every channel. To get a true
  # mixed result, run WITHOUT dryrun and rely on local's osascript path
  # which will fail (since none on host w/o shim) — but that's also a fail.
  # Cleanest construction: dryrun=1 → all ok; dryrun=0 + curl-fail → all
  # fail. Use the curl-fail-only path here:
  unset JARVIS_NOTIFY_DRYRUN
  shim_install osascript 'exit 0'   # local succeeds
  run notify_dispatch "$(_reminder "ping" '["local","gotify"]')"
  [ "$status" -eq 0 ]   # local ok, gotify fail → any-ok-wins
  log="$JARVIS_HOME/test/notify.log"
  oks="$(jq -r '.ok' < "$log" | sort -u | paste -sd, -)"
  [ "$oks" = "false,true" ]
}

@test "all channels fail → exit 1" {
  unset JARVIS_NOTIFY_DRYRUN
  shim_install curl 'exit 7'
  shim_install osascript 'exit 1'
  shim_install notify-send 'exit 1'
  run notify_dispatch "$(_reminder "ping" '["local","gotify","slack"]')"
  [ "$status" -eq 1 ]
  log="$JARVIS_HOME/test/notify.log"
  oks="$(jq -r '.ok' < "$log" | sort -u)"
  [ "$oks" = "false" ]
}

# ---------- unknown channel ----------

@test "unknown channel → notify.log row with 'unknown channel' error" {
  JARVIS_NOTIFY_DRYRUN=1 run notify_dispatch "$(_reminder "ping" '["whatever"]')"
  [ "$status" -eq 1 ]   # all-fail (unknown counts as failed)
  log="$JARVIS_HOME/test/notify.log"
  err="$(jq -r '.error' < "$log")"
  ch="$(jq -r '.channel' < "$log")"
  [ "$err" = "unknown channel" ]
  [ "$ch" = "whatever" ]
}

@test "mix of known + unknown → known still fires; unknown logged as fail" {
  JARVIS_NOTIFY_DRYRUN=1 run notify_dispatch "$(_reminder "ping" '["local","whatever"]')"
  [ "$status" -eq 0 ]   # local ok wins
  log="$JARVIS_HOME/test/notify.log"
  count="$(wc -l < "$log")"
  [ "$count" -eq 2 ]
}

# ---------- malformed input ----------

@test "invalid reminder JSON → exit 2" {
  run notify_dispatch "{not-json}"
  [ "$status" -eq 2 ]
}

@test "reminder with no message → exit 2" {
  json='{"profile":"test","via":["local"]}'
  run notify_dispatch "$json"
  [ "$status" -eq 2 ]
}

@test "empty via → no notify.log rows + exit 1 (no successful attempt)" {
  run notify_dispatch "$(_reminder "ping" '[]')"
  [ "$status" -eq 1 ]
  [ ! -f "$JARVIS_HOME/test/notify.log" ]
}

# ---------- profile threading ----------

@test "dispatch routes to per-reminder profile, not env profile" {
  mkdir -p "$JARVIS_HOME/work"
  cat > "$JARVIS_HOME/work/config.toml" <<'EOF'
[notify.gotify]
url = "https://gotify.work"
token = "wtok"
EOF
  shim_install curl 'printf "%s\n" "$@" >> "$0.log"; exit 0'
  unset JARVIS_NOTIFY_DRYRUN
  before="$JARVIS_PROFILE"
  notify_dispatch "$(_reminder "ping" '["gotify"]' work)"
  [ "$JARVIS_PROFILE" = "$before" ]
  grep -q "https://gotify.work/message" "$(shim_log_path curl)"
  grep -q "X-Gotify-Key: wtok" "$(shim_log_path curl)"
  # notify.log lands in the work profile.
  [ -f "$JARVIS_HOME/work/notify.log" ]
}
