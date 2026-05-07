#!/usr/bin/env bats
# Tests for lib/notify/slack.sh — dryrun, config-missing,
# curl-failure, profile isolation.

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
  source "${JARVIS_DIR}/lib/notify/slack.sh"
  state_ensure_tree
  cat > "$JARVIS_HOME/test/config.toml" <<'EOF'
[notify.slack]
webhook = "https://hooks.slack.example/abc"
EOF
}

teardown() {
  jarvis_common_teardown
}

@test "slack channel auto-registers" {
  run notify_channels
  [[ "$output" == *"slack"* ]]
}

@test "dryrun → ok=true, no curl" {
  shim_install curl 'echo "called: $*" >> "$0.log"; exit 0'
  JARVIS_NOTIFY_DRYRUN=1 run notify_slack "ping"
  [ "$status" -eq 0 ]
  log="$JARVIS_HOME/test/notify.log"
  ok="$(jq -r '.ok' < "$log")"
  [ "$ok" = "true" ]
  [ ! -f "$(shim_log_path curl)" ]
}

@test "missing webhook → exit 2 with named error" {
  rm "$JARVIS_HOME/test/config.toml"
  run notify_slack "ping"
  [ "$status" -eq 2 ]
  log="$JARVIS_HOME/test/notify.log"
  err="$(jq -r '.error' < "$log")"
  [[ "$err" == *"[notify.slack].webhook"* ]]
}

@test "curl success → ok=true" {
  shim_install curl 'exit 0'
  run notify_slack "ping"
  [ "$status" -eq 0 ]
  log="$JARVIS_HOME/test/notify.log"
  ok="$(jq -r '.ok' < "$log")"
  [ "$ok" = "true" ]
}

@test "curl failure → ok=false + error" {
  shim_install curl 'echo "curl: timeout" >&2; exit 28'
  run notify_slack "ping"
  [ "$status" -eq 1 ]
  log="$JARVIS_HOME/test/notify.log"
  ok="$(jq -r '.ok' < "$log")"
  err="$(jq -r '.error' < "$log")"
  [ "$ok" = "false" ]
  [[ "$err" == *"timeout"* ]]
}

@test "curl payload is JSON {text: ...} sent to webhook URL" {
  # The webhook URL travels via curl --config (stdin) so it never lands on
  # argv — capture both argv and stdin so the assertion still hits the URL.
  shim_install curl 'printf "%s\n" "$@" >> "$0.log"; cat >> "$0.log"; exit 0'
  notify_slack "stand up"
  log="$(shim_log_path curl)"
  grep -q "https://hooks.slack.example/abc" "$log"
  grep -qF '{"text":"stand up"}' "$log"
}

@test "explicit profile reads that profile's webhook without env mutation" {
  mkdir -p "$JARVIS_HOME/work"
  cat > "$JARVIS_HOME/work/config.toml" <<'EOF'
[notify.slack]
webhook = "https://hooks.slack.example/work"
EOF
  shim_install curl 'printf "%s\n" "$@" >> "$0.log"; cat >> "$0.log"; exit 0'
  before="$JARVIS_PROFILE"
  notify_slack "ping" "work"
  [ "$JARVIS_PROFILE" = "$before" ]
  grep -q "https://hooks.slack.example/work" "$(shim_log_path curl)"
  [ -f "$JARVIS_HOME/work/notify.log" ]
}

@test "empty message → exit 1" {
  run notify_slack ""
  [ "$status" -eq 1 ]
}
