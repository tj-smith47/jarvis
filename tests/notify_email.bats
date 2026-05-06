#!/usr/bin/env bats
# Tests for lib/notify/email.sh — registration, config
# rejection, dryrun, transport auto-detect, MTA invocation, profile isolation.

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
  source "${JARVIS_DIR}/lib/notify/email.sh"
  state_ensure_tree
  cat > "$JARVIS_HOME/test/config.toml" <<'EOF'
[notify.email]
to = "ops@example.com"
EOF
}

teardown() { jarvis_common_teardown; }

# ---------- registration ----------

@test "email channel auto-registers" {
  run notify_channels
  [[ "$output" == *"email"* ]]
}

# ---------- empty / missing config ----------

@test "empty message → exit 1 + named error" {
  shim_install mail 'exit 0'
  run notify_email ""
  [ "$status" -eq 1 ]
  err="$(jq -r '.error' < "$JARVIS_HOME/test/notify.log")"
  [ "$err" = "empty message" ]
}

@test "missing [notify.email].to → exit 2 with named error" {
  rm "$JARVIS_HOME/test/config.toml"
  shim_install mail 'exit 0'
  run notify_email "ping"
  [ "$status" -eq 2 ]
  err="$(jq -r '.error' < "$JARVIS_HOME/test/notify.log")"
  [[ "$err" == *"[notify.email].to"* ]]
}

@test "no MTA on PATH → exit 2 with install hint" {
  # Override `command -v` so neither mail nor sendmail resolve, even if
  # the host has a system MTA installed (CI runners typically do).
  command() {
    if [[ "$1" == "-v" && ( "$2" == "mail" || "$2" == "sendmail" ) ]]; then
      return 1
    fi
    builtin command "$@"
  }
  export -f command
  run notify_email "ping"
  [ "$status" -eq 2 ]
  err="$(jq -r '.error' < "$JARVIS_HOME/test/notify.log")"
  [[ "$err" == *"no email transport"* ]]
}

@test "unknown transport name → exit 2 with named error" {
  cat >> "$JARVIS_HOME/test/config.toml" <<'EOF'
transport = "telegrams"
EOF
  shim_install mail 'exit 0'
  run notify_email "ping"
  [ "$status" -eq 2 ]
  err="$(jq -r '.error' < "$JARVIS_HOME/test/notify.log")"
  [[ "$err" == *"unknown transport"* ]]
  [[ "$err" == *"telegrams"* ]]
}

# ---------- dryrun ----------

@test "dryrun → ok=true notify.log row, no MTA invocation" {
  shim_install mail 'echo "mail was called: $*" >> "$0.log"; exit 0'
  JARVIS_NOTIFY_DRYRUN=1 run notify_email "ping"
  [ "$status" -eq 0 ]
  ok="$(jq -r '.ok' < "$JARVIS_HOME/test/notify.log")"
  ch="$(jq -r '.channel' < "$JARVIS_HOME/test/notify.log")"
  [ "$ok" = "true" ]
  [ "$ch" = "email" ]
  [ ! -f "$(shim_log_path mail)" ]
}

# ---------- transport auto-detect ----------

@test "auto transport prefers mail when present" {
  shim_install mail     'echo "mail-stdin: $(cat)" >> "$0.log"; printf "%s\n" "$@" >> "$0.log"; exit 0'
  shim_install sendmail 'echo "sendmail was called" >> "$0.log"; exit 0'
  run notify_email "hello"
  [ "$status" -eq 0 ]
  [ -f "$(shim_log_path mail)" ]
  [ ! -f "$(shim_log_path sendmail)" ]
}

@test "auto transport falls back to sendmail when mail missing" {
  shim_install sendmail 'cat >> "$0.log"; exit 0'
  run notify_email "fallback"
  [ "$status" -eq 0 ]
  [ -f "$(shim_log_path sendmail)" ]
  grep -q "Subject: \[jarvis\] fallback" "$(shim_log_path sendmail)"
  grep -q "To: ops@example.com" "$(shim_log_path sendmail)"
  grep -q "fallback" "$(shim_log_path sendmail)"
}

# ---------- mail invocation shape ----------

@test "mail invoked with subject, to, message body on stdin" {
  shim_install mail '
    printf "args: %s\n" "$*" >> "$0.log"
    printf "stdin: %s\n" "$(cat)" >> "$0.log"
    exit 0
  '
  notify_email "deploy started"
  log="$(shim_log_path mail)"
  [ -f "$log" ]
  grep -q "args: -s \[jarvis\] deploy started -- ops@example.com" "$log"
  grep -q "stdin: deploy started" "$log"
}

@test "mail honors [notify.email].from via -r" {
  cat > "$JARVIS_HOME/test/config.toml" <<'EOF'
[notify.email]
to   = "ops@example.com"
from = "jarvis@workstation"
EOF
  shim_install mail 'printf "%s\n" "$@" >> "$0.log"; exit 0'
  notify_email "ping"
  log="$(shim_log_path mail)"
  grep -q -- "-r" "$log"
  grep -q "jarvis@workstation" "$log"
}

@test "subject_prefix override applied" {
  cat > "$JARVIS_HOME/test/config.toml" <<'EOF'
[notify.email]
to             = "ops@example.com"
subject_prefix = "[ALERT]"
EOF
  shim_install mail 'printf "%s\n" "$@" >> "$0.log"; exit 0'
  notify_email "disk full"
  grep -q "\[ALERT\] disk full" "$(shim_log_path mail)"
}

# ---------- failure handling ----------

@test "mail failure → ok=false + first stderr line captured" {
  shim_install mail 'echo "smtp: connection refused" >&2; echo "tail line" >&2; exit 7'
  run notify_email "ping"
  [ "$status" -eq 1 ]
  ok="$(jq -r '.ok' < "$JARVIS_HOME/test/notify.log")"
  err="$(jq -r '.error' < "$JARVIS_HOME/test/notify.log")"
  [ "$ok" = "false" ]
  [[ "$err" == *"connection refused"* ]]
}

# ---------- profile isolation ----------

@test "explicit profile arg reads that profile's config without env mutation" {
  mkdir -p "$JARVIS_HOME/work"
  cat > "$JARVIS_HOME/work/config.toml" <<'EOF'
[notify.email]
to = "work@example.com"
EOF
  shim_install mail 'printf "%s\n" "$@" >> "$0.log"; exit 0'
  before="$JARVIS_PROFILE"
  notify_email "ping" "work"
  [ "$JARVIS_PROFILE" = "$before" ]
  grep -q "work@example.com" "$(shim_log_path mail)"
  [ -f "$JARVIS_HOME/work/notify.log" ]
}
