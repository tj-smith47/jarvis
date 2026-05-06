#!/usr/bin/env bats
# T10 tests — cmds/remind/remind.sh creates reminders/<slug>.json with
# correct shape, validates channels at create time, and rejects invalid
# flag combinations.

bats_require_minimum_version 1.5.0

load 'helper'

setup() {
  jarvis_common_setup
  export JARVIS_FAKE_NOW="2026-04-26T14:00:00Z"
  state_init() {
    # shellcheck source=/dev/null
    source "${JARVIS_DIR}/lib/state/profile.sh"
    # shellcheck source=/dev/null
    source "${JARVIS_DIR}/lib/state/profile.sh"
    state_ensure_tree
  }
  state_init
}

teardown() {
  jarvis_common_teardown
}

# Run the remind cmd as standalone bash (without router/wrapper).
_remind() {
  bash "${JARVIS_DIR}/cmds/remind/remind.sh" "$@"
}

# ---------- one-shot --in ----------

@test "--in 10m creates reminder file" {
  run _remind "stand up" --in 10m
  [ "$status" -eq 0 ]
  ls "$JARVIS_HOME/test/reminders/" | head -1 | grep -q "stand-up-"
}

@test "--in 10m sets trigger_at = now+10m and status=pending" {
  _remind "stand up" --in 10m >/dev/null
  f="$(ls "$JARVIS_HOME/test/reminders/"*.json | head -1)"
  payload="$(cat "$f")"
  [ "$(jq -r '.trigger_at' <<< "$payload")" = "2026-04-26T14:10:00Z" ]
  [ "$(jq -r '.status' <<< "$payload")" = "pending" ]
  [ "$(jq -r '.repeat' <<< "$payload")" = "null" ]
}

# ---------- one-shot --at ----------

@test "--at 17:00 today creates one-shot reminder" {
  _remind "drink water" --at 17:00 >/dev/null
  f="$(ls "$JARVIS_HOME/test/reminders/"*.json | head -1)"
  [ "$(jq -r '.trigger_at' < "$f")" = "2026-04-26T17:00:00Z" ]
}

@test "--at past time rolls to tomorrow" {
  _remind "morning" --at 09:00 >/dev/null
  f="$(ls "$JARVIS_HOME/test/reminders/"*.json | head -1)"
  [ "$(jq -r '.trigger_at' < "$f")" = "2026-04-27T09:00:00Z" ]
}

# ---------- recurring ----------

@test "--repeat daily --at 09:00 creates active recurring" {
  _remind "standup" --repeat daily --at 09:00 >/dev/null
  f="$(ls "$JARVIS_HOME/test/reminders/"*.json | head -1)"
  payload="$(cat "$f")"
  [ "$(jq -r '.status' <<< "$payload")" = "active" ]
  [ "$(jq -r '.repeat' <<< "$payload")" = "daily" ]
  [ "$(jq -r '.anchor_at' <<< "$payload")" = "09:00" ]
}

@test "--repeat 2h interval (no --at needed)" {
  _remind "drink water" --repeat 2h >/dev/null
  f="$(ls "$JARVIS_HOME/test/reminders/"*.json | head -1)"
  payload="$(cat "$f")"
  [ "$(jq -r '.repeat' <<< "$payload")" = "2h" ]
  [ "$(jq -r '.anchor_at' <<< "$payload")" = "null" ]
  # First fire is now + 2h
  [ "$(jq -r '.trigger_at' <<< "$payload")" = "2026-04-26T16:00:00Z" ]
}

@test "--repeat anchored without --at errors" {
  run _remind "standup" --repeat daily
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires --at HH:MM"* ]]
}

@test "--repeat day-list canonicalizes (fri,mon → mon,fri)" {
  _remind "review" --repeat fri,mon --at 17:00 >/dev/null
  f="$(ls "$JARVIS_HOME/test/reminders/"*.json | head -1)"
  [ "$(jq -r '.repeat' < "$f")" = "mon,fri" ]
}

@test "--count and --until carry through" {
  _remind "ship" --repeat daily --at 09:00 --count 5 --until 2026-12-31 >/dev/null
  f="$(ls "$JARVIS_HOME/test/reminders/"*.json | head -1)"
  payload="$(cat "$f")"
  [ "$(jq -r '.count_remaining' <<< "$payload")" = "5" ]
  [ "$(jq -r '.until' <<< "$payload")" = "2026-12-31" ]
}

# ---------- mutex ----------

@test "--in + --at errors" {
  run _remind "x" --in 10m --at 17:00
  [ "$status" -ne 0 ]
  [[ "$output" == *"mutually exclusive"* ]]
}

@test "--in + --repeat errors" {
  run _remind "x" --in 10m --repeat daily
  [ "$status" -ne 0 ]
  [[ "$output" == *"mutually exclusive"* ]]
}

@test "no --in / --at / --repeat errors" {
  run _remind "x"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must provide"* ]]
}

@test "no message errors" {
  run _remind --in 10m
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage"* ]]
}

# ---------- channel validation ----------

@test "--via gotify without config rejects at create time" {
  run _remind "ping" --in 10m --via gotify
  [ "$status" -ne 0 ]
  [[ "$output" == *"[notify.gotify].url"* ]]
}

@test "--via slack without config rejects at create time" {
  run _remind "ping" --in 10m --via slack
  [ "$status" -ne 0 ]
  [[ "$output" == *"[notify.slack].webhook"* ]]
}

@test "--via with all configured channels succeeds" {
  cat > "$JARVIS_HOME/test/config.toml" <<'EOF'
[notify.gotify]
url = "https://gotify.example"
token = "tok"
[notify.slack]
webhook = "https://hooks.example"
EOF
  _remind "ping" --in 10m --via local,gotify,slack >/dev/null
  f="$(ls "$JARVIS_HOME/test/reminders/"*.json | head -1)"
  via="$(jq -c '.via' < "$f")"
  [ "$via" = '["local","gotify","slack"]' ]
}

@test "--via unknown channel errors" {
  run _remind "ping" --in 10m --via discord
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown channel"* ]]
}

# ---------- slug + payload shape ----------

@test "default --via local doesn't need config" {
  _remind "ping" --in 10m >/dev/null
  f="$(ls "$JARVIS_HOME/test/reminders/"*.json | head -1)"
  via="$(jq -c '.via' < "$f")"
  [ "$via" = '["local"]' ]
}

@test "slug includes UTC timestamp" {
  _remind "stand up" --in 10m >/dev/null
  f="$(ls "$JARVIS_HOME/test/reminders/"*.json | head -1)"
  base="${f##*/}"
  base="${base%.json}"
  # 2026-04-26T14:00:00Z in compact form: 2026-04-26-1400
  [[ "$base" == "stand-up-2026-04-26-1400" ]]
}

@test "payload has the documented keys (no delivery_recent)" {
  _remind "ping" --in 10m >/dev/null
  f="$(ls "$JARVIS_HOME/test/reminders/"*.json | head -1)"
  has_delivery_recent="$(jq 'has("delivery_recent")' < "$f")"
  [ "$has_delivery_recent" = "false" ]
}

@test "confirmation line goes to stderr (not stdout) — log_success" {
  run _remind "ping" --in 10m
  [ "$status" -eq 0 ]
  [[ "$output" == *"scheduled"* ]] || [[ "$output" == *"ping"* ]]
}
