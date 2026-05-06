#!/usr/bin/env bats
# T8 tests — one-shot tick path. Recurring + multi-profile come in T9.

bats_require_minimum_version 1.5.0

load 'helper'
load 'shim_helper'

setup() {
  jarvis_common_setup
  shim_setup
  for f in state/profile state/lock state/json state/ndjson state/config \
           remind/parse remind/schedule remind/schema \
           notify/registry notify/local notify/gotify notify/slack notify/email \
           notify/dispatch remind/tick; do
    # shellcheck source=/dev/null
    source "${JARVIS_DIR}/lib/$f.sh"
  done
  state_ensure_tree
}

teardown() {
  jarvis_common_teardown
}

# Build a one-shot reminder JSON; defaults are due-now in fake-time.
_one_shot_reminder() {
  local slug="$1" via_json="${2:-[\"local\"]}" trigger="${3:-2026-04-26T14:30:00Z}"
  jq -nc \
    --arg slug "$slug" --arg message "$slug-msg" \
    --arg profile "test" --arg trigger_at "$trigger" \
    --argjson via "$via_json" --arg created "2026-04-26T14:00:00Z" \
    '{slug:$slug, message:$message, profile:$profile,
      trigger_at:$trigger_at, via:$via, status:"pending",
      repeat:null, anchor_at:null, until:null, count_remaining:null,
      created_at:$created, fire_count:0, last_fired_at:null}'
}

_seed() {
  local slug="$1" via_json="${2:-[\"local\"]}" trigger="${3:-2026-04-26T14:30:00Z}"
  local blob; blob="$(_one_shot_reminder "$slug" "$via_json" "$trigger")"
  remind_schema_create "$slug" "$blob" >/dev/null
}

# ---------- one-shot fire happy path ----------

@test "due one-shot pending fires → status=delivered, fire_count=1" {
  _seed ping
  export JARVIS_FAKE_NOW="2026-04-26T14:35:00Z"
  export JARVIS_NOTIFY_DRYRUN=1
  remind_tick_run
  payload="$(cat "$JARVIS_HOME/test/reminders/ping.json")"
  [ "$(jq -r '.status' <<< "$payload")" = "delivered" ]
  [ "$(jq -r '.fire_count' <<< "$payload")" = "1" ]
  [ "$(jq -r '.last_fired_at' <<< "$payload")" = "2026-04-26T14:35:00Z" ]
}

@test "fire writes a delivery NDJSON row keyed by slug" {
  _seed ping
  export JARVIS_FAKE_NOW="2026-04-26T14:35:00Z"
  export JARVIS_NOTIFY_DRYRUN=1
  remind_tick_run
  log="$JARVIS_HOME/test/reminders.delivery.log"
  [ -f "$log" ]
  # First row is the heartbeat; the fire row(s) follow.
  fire_rows="$(jq -c 'select(.slug == "ping")' < "$log" | wc -l)"
  [ "$fire_rows" -ge 1 ]
}

@test "every tick run appends a tick.heartbeat row" {
  _seed ping
  export JARVIS_FAKE_NOW="2026-04-26T14:35:00Z"
  export JARVIS_NOTIFY_DRYRUN=1
  remind_tick_run
  log="$JARVIS_HOME/test/reminders.delivery.log"
  hb_count="$(jq -c 'select(.kind == "tick.heartbeat")' < "$log" | wc -l)"
  [ "$hb_count" = "1" ]
}

@test "heartbeat fires even when nothing else does" {
  # Empty profile (no reminders) still gets a heartbeat.
  export JARVIS_FAKE_NOW="2026-04-26T14:35:00Z"
  remind_tick_run
  log="$JARVIS_HOME/test/reminders.delivery.log"
  [ -f "$log" ]
  hb_count="$(jq -c 'select(.kind == "tick.heartbeat")' < "$log" | wc -l)"
  [ "$hb_count" = "1" ]
}

# ---------- not-due / wrong-status ----------

@test "not-yet-due reminder is unchanged" {
  _seed ping '["local"]' "2026-04-26T15:00:00Z"
  export JARVIS_FAKE_NOW="2026-04-26T14:30:00Z"   # before trigger
  export JARVIS_NOTIFY_DRYRUN=1
  remind_tick_run
  payload="$(cat "$JARVIS_HOME/test/reminders/ping.json")"
  [ "$(jq -r '.status' <<< "$payload")" = "pending" ]
  [ "$(jq -r '.fire_count' <<< "$payload")" = "0" ]
}

@test "already-delivered reminder not re-fired" {
  _seed ping
  payload="$(cat "$JARVIS_HOME/test/reminders/ping.json" \
              | jq -c '.status = "delivered" | .fire_count = 1')"
  remind_schema_save ping "$payload" >/dev/null
  export JARVIS_FAKE_NOW="2026-04-26T14:35:00Z"
  export JARVIS_NOTIFY_DRYRUN=1
  remind_tick_run
  fc="$(jq -r '.fire_count' < "$JARVIS_HOME/test/reminders/ping.json")"
  [ "$fc" = "1" ]   # still 1, didn't bump
}

# ---------- failure path ----------

@test "all channels fail → status=failed, delivery row ok=false" {
  _seed ping '["gotify"]'
  cat > "$JARVIS_HOME/test/config.toml" <<'EOF'
[notify.gotify]
url = "https://gotify.example"
token = "tok"
EOF
  shim_install curl 'echo "boom" >&2; exit 7'
  export JARVIS_FAKE_NOW="2026-04-26T14:35:00Z"
  remind_tick_run
  payload="$(cat "$JARVIS_HOME/test/reminders/ping.json")"
  [ "$(jq -r '.status' <<< "$payload")" = "failed" ]
  [ "$(jq -r '.fire_count' <<< "$payload")" = "1" ]
  log="$JARVIS_HOME/test/reminders.delivery.log"
  fail_rows="$(jq -c 'select(.slug == "ping" and .ok == false)' < "$log" | wc -l)"
  [ "$fail_rows" -ge 1 ]
}

# ---------- concurrent tick race ----------

@test "two concurrent ticks → exactly one fire (flock guards)" {
  _seed ping
  export JARVIS_FAKE_NOW="2026-04-26T14:35:00Z"
  export JARVIS_NOTIFY_DRYRUN=1
  # Spawn two ticks concurrently; flock on .tick.lock should let only one
  # in. The other silently exits 0.
  remind_tick_run &
  pid1=$!
  remind_tick_run &
  pid2=$!
  wait "$pid1" "$pid2"
  fc="$(jq -r '.fire_count' < "$JARVIS_HOME/test/reminders/ping.json")"
  [ "$fc" = "1" ]
}

# ---------- recurring path (T9) ----------

# Build a recurring reminder JSON. Defaults are due-now in fake-time.
_recurring_reminder() {
  local slug="$1" repeat="${2:-daily}" anchor="${3:-09:00}" \
        trigger="${4:-2026-04-26T09:00:00Z}" \
        until="${5:-}" count="${6:-}"
  jq -nc \
    --arg slug "$slug" --arg message "$slug-msg" \
    --arg profile "test" --arg trigger "$trigger" \
    --arg repeat "$repeat" --arg anchor "$anchor" \
    --arg until_at "$until" --arg count "$count" \
    --arg created "2026-04-26T08:00:00Z" \
    '{slug:$slug, message:$message, profile:$profile,
      trigger_at:$trigger, via:["local"], status:"active",
      repeat:$repeat, anchor_at:$anchor,
      until: (if $until_at == "" then null else $until_at end),
      count_remaining: (if $count == "" then null else ($count|tonumber) end),
      created_at:$created, fire_count:0, last_fired_at:null}'
}

_seed_rec() {
  local slug="$1"; shift
  local blob; blob="$(_recurring_reminder "$slug" "$@")"
  remind_schema_create "$slug" "$blob" >/dev/null
}

@test "recurring daily fires + stays active + advances trigger_at" {
  _seed_rec daily-standup
  export JARVIS_FAKE_NOW="2026-04-26T10:00:00Z"   # past 09:00 trigger
  export JARVIS_NOTIFY_DRYRUN=1
  remind_tick_run
  payload="$(cat "$JARVIS_HOME/test/reminders/daily-standup.json")"
  [ "$(jq -r '.status' <<< "$payload")" = "active" ]
  [ "$(jq -r '.fire_count' <<< "$payload")" = "1" ]
  # Tomorrow 09:00 UTC
  [ "$(jq -r '.trigger_at' <<< "$payload")" = "2026-04-27T09:00:00Z" ]
  # Delivery row keyed by slug
  log="$JARVIS_HOME/test/reminders.delivery.log"
  fire_rows="$(jq -c 'select(.slug == "daily-standup")' < "$log" | wc -l)"
  [ "$fire_rows" -ge 1 ]
}

@test "recurring with count_remaining=2 fires twice then exhausts" {
  _seed_rec twice "daily" "09:00" "2026-04-26T09:00:00Z" "" "2"
  export JARVIS_NOTIFY_DRYRUN=1
  # Fire 1
  export JARVIS_FAKE_NOW="2026-04-26T10:00:00Z"
  remind_tick_run
  cr1="$(jq -r '.count_remaining' < "$JARVIS_HOME/test/reminders/twice.json")"
  st1="$(jq -r '.status' < "$JARVIS_HOME/test/reminders/twice.json")"
  [ "$cr1" = "1" ]
  [ "$st1" = "active" ]
  # Fire 2
  export JARVIS_FAKE_NOW="2026-04-27T10:00:00Z"
  remind_tick_run
  cr2="$(jq -r '.count_remaining' < "$JARVIS_HOME/test/reminders/twice.json")"
  st2="$(jq -r '.status' < "$JARVIS_HOME/test/reminders/twice.json")"
  fc2="$(jq -r '.fire_count' < "$JARVIS_HOME/test/reminders/twice.json")"
  [ "$cr2" = "0" ]
  [ "$st2" = "exhausted" ]
  [ "$fc2" = "2" ]
}

@test "recurring with until past now → exhausted without firing" {
  _seed_rec endingsoon "daily" "09:00" "2026-04-26T09:00:00Z" "2026-04-25" ""
  export JARVIS_FAKE_NOW="2026-04-26T10:00:00Z"   # past until=2026-04-25
  export JARVIS_NOTIFY_DRYRUN=1
  remind_tick_run
  payload="$(cat "$JARVIS_HOME/test/reminders/endingsoon.json")"
  [ "$(jq -r '.status' <<< "$payload")" = "exhausted" ]
  [ "$(jq -r '.fire_count' <<< "$payload")" = "0" ]   # no fire
  # No delivery row for this slug.
  log="$JARVIS_HOME/test/reminders.delivery.log"
  rows="$(jq -c 'select(.slug == "endingsoon")' < "$log" | wc -l)"
  [ "$rows" = "0" ]
}

@test "recurring with until in future → still fires" {
  _seed_rec ongoing "daily" "09:00" "2026-04-26T09:00:00Z" "2026-12-31" ""
  export JARVIS_FAKE_NOW="2026-04-26T10:00:00Z"
  export JARVIS_NOTIFY_DRYRUN=1
  remind_tick_run
  payload="$(cat "$JARVIS_HOME/test/reminders/ongoing.json")"
  [ "$(jq -r '.status' <<< "$payload")" = "active" ]
  [ "$(jq -r '.fire_count' <<< "$payload")" = "1" ]
}

# ---------- multi-profile (B2 fix verification) ----------

@test "multi-profile tick fires each profile's reminder via that profile's config" {
  # Setup two profiles each with their own gotify URL. Both reminders due.
  for prof in work home; do
    mkdir -p "$JARVIS_HOME/$prof/reminders"
  done
  cat > "$JARVIS_HOME/work/config.toml" <<'EOF'
[notify.gotify]
url = "https://gotify.work.example"
token = "wtok"
EOF
  cat > "$JARVIS_HOME/home/config.toml" <<'EOF'
[notify.gotify]
url = "https://gotify.home.example"
token = "htok"
EOF

  # Create a reminder in each profile (manually, since remind_schema_create
  # uses current $JARVIS_PROFILE — but we explicitly threading via the
  # profile field inside the JSON which dispatch reads).
  for prof in work home; do
    blob="$(jq -nc --arg slug "ping-$prof" --arg msg "ping" \
              --arg prof "$prof" --arg trig "2026-04-26T09:00:00Z" \
              '{slug:$slug, message:$msg, profile:$prof,
                trigger_at:$trig, via:["gotify"], status:"pending",
                repeat:null, anchor_at:null, until:null, count_remaining:null,
                created_at:"2026-04-26T08:00:00Z", fire_count:0, last_fired_at:null}')"
    JARVIS_PROFILE="$prof" remind_schema_create "ping-$prof" "$blob" >/dev/null
  done

  # Shimmed curl that records every URL it was called with.
  shim_install curl 'printf "%s\n" "$@" >> "$0.log"; exit 0'
  export JARVIS_FAKE_NOW="2026-04-26T10:00:00Z"
  remind_tick_run

  curl_log="$(shim_log_path curl)"
  [ -f "$curl_log" ]
  grep -q "https://gotify.work.example/message?token=wtok" "$curl_log"
  grep -q "https://gotify.home.example/message?token=htok" "$curl_log"

  # Each profile's reminder transitioned to delivered.
  [ "$(jq -r '.status' < "$JARVIS_HOME/work/reminders/ping-work.json")" = "delivered" ]
  [ "$(jq -r '.status' < "$JARVIS_HOME/home/reminders/ping-home.json")" = "delivered" ]
}

# ---------- now < trigger (early) ----------

@test "recurring not yet at trigger_at is unchanged" {
  _seed_rec daily-standup "daily" "09:00" "2026-04-27T09:00:00Z"
  export JARVIS_FAKE_NOW="2026-04-26T10:00:00Z"   # before trigger
  export JARVIS_NOTIFY_DRYRUN=1
  remind_tick_run
  payload="$(cat "$JARVIS_HOME/test/reminders/daily-standup.json")"
  [ "$(jq -r '.fire_count' <<< "$payload")" = "0" ]
  [ "$(jq -r '.trigger_at' <<< "$payload")" = "2026-04-27T09:00:00Z" ]
}
