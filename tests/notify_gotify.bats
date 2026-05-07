#!/usr/bin/env bats
# Tests for lib/notify/gotify.sh — dryrun, config-missing
# rejection, curl-failure handling, multi-profile config isolation.

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
  source "${JARVIS_DIR}/lib/notify/gotify.sh"
  state_ensure_tree
  cat > "$JARVIS_HOME/test/config.toml" <<'EOF'
[notify.gotify]
url = "https://gotify.example"
token = "tok-test"
EOF
}

teardown() {
  jarvis_common_teardown
}

# ---------- registration ----------

@test "gotify channel auto-registers" {
  run notify_channels
  [[ "$output" == *"gotify"* ]]
}

# ---------- dryrun ----------

@test "dryrun → ok=true notify.log row, no curl invocation" {
  shim_install curl 'echo "curl was called: $*" >> "$0.log"; exit 0'
  JARVIS_NOTIFY_DRYRUN=1 run notify_gotify "ping"
  [ "$status" -eq 0 ]
  log="$JARVIS_HOME/test/notify.log"
  ok="$(jq -r '.ok' < "$log")"
  ch="$(jq -r '.channel' < "$log")"
  [ "$ok" = "true" ]
  [ "$ch" = "gotify" ]
  [ ! -f "$(shim_log_path curl)" ]
}

# ---------- missing config ----------

@test "missing url → exit 2 with named error" {
  rm "$JARVIS_HOME/test/config.toml"
  run notify_gotify "ping"
  [ "$status" -eq 2 ]
  log="$JARVIS_HOME/test/notify.log"
  err="$(jq -r '.error' < "$log")"
  [[ "$err" == *"[notify.gotify].url"* ]]
}

@test "missing token → exit 2 with named error" {
  cat > "$JARVIS_HOME/test/config.toml" <<'EOF'
[notify.gotify]
url = "https://gotify.example"
EOF
  run notify_gotify "ping"
  [ "$status" -eq 2 ]
  log="$JARVIS_HOME/test/notify.log"
  err="$(jq -r '.error' < "$log")"
  [[ "$err" == *"[notify.gotify].token"* ]]
}

# ---------- curl execution ----------

@test "curl success → ok=true notify.log row" {
  shim_install curl 'exit 0'
  run notify_gotify "ping"
  [ "$status" -eq 0 ]
  log="$JARVIS_HOME/test/notify.log"
  ok="$(jq -r '.ok' < "$log")"
  [ "$ok" = "true" ]
}

@test "curl failure → ok=false + curl error captured" {
  shim_install curl 'echo "curl: connection refused" >&2; exit 7'
  run notify_gotify "ping"
  [ "$status" -eq 1 ]
  log="$JARVIS_HOME/test/notify.log"
  ok="$(jq -r '.ok' < "$log")"
  err="$(jq -r '.error' < "$log")"
  [ "$ok" = "false" ]
  [[ "$err" == *"connection refused"* ]]
}

@test "curl invoked with url, token, message, priority" {
  shim_install curl 'printf "%s\n" "$@" >> "$0.log"; exit 0'
  notify_gotify "ping"
  log="$(shim_log_path curl)"
  [ -f "$log" ]
  grep -q "https://gotify.example/message" "$log"
  grep -q "X-Gotify-Key: tok-test" "$log"
  grep -q "title=jarvis" "$log"
  grep -q "message=ping" "$log"
  grep -q "priority=5" "$log"
}

# ---------- profile isolation ----------

@test "explicit profile arg reads that profile's config without env mutation" {
  mkdir -p "$JARVIS_HOME/work"
  cat > "$JARVIS_HOME/work/config.toml" <<'EOF'
[notify.gotify]
url = "https://gotify.work"
token = "work-tok"
EOF
  shim_install curl 'printf "%s\n" "$@" >> "$0.log"; exit 0'
  before="$JARVIS_PROFILE"
  notify_gotify "ping" "work"
  [ "$JARVIS_PROFILE" = "$before" ]
  grep -q "https://gotify.work/message" "$(shim_log_path curl)"
  grep -q "X-Gotify-Key: work-tok" "$(shim_log_path curl)"
  # Notify.log lives under the work profile (profile-aware logging).
  [ -f "$JARVIS_HOME/work/notify.log" ]
}

@test "empty message → exit 1 + named error" {
  run notify_gotify ""
  [ "$status" -eq 1 ]
  log="$JARVIS_HOME/test/notify.log"
  err="$(jq -r '.error' < "$log")"
  [ "$err" = "empty message" ]
}
