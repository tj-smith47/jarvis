#!/usr/bin/env bats
# Tests for lib/remind/schema.sh — single-blob create,
# load, save, validate, list, and delivery-log NDJSON append.

bats_require_minimum_version 1.5.0

load 'helper'

setup() {
  jarvis_common_setup
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/state/profile.sh"
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/state/lock.sh"
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/state/json.sh"
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/state/ndjson.sh"
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/remind/schema.sh"
  state_ensure_tree
}

teardown() {
  jarvis_common_teardown
}

# Build a minimal valid reminder JSON blob.
_one_shot_blob() {
  local slug="$1" message="${2:-stand up}"
  jq -nc \
    --arg slug "$slug" --arg message "$message" \
    --arg profile "test" \
    --arg trigger_at "2026-04-26T14:30:00Z" \
    --argjson via '["local"]' \
    --arg created_at "2026-04-26T14:20:00Z" \
    '{slug:$slug, message:$message, profile:$profile,
      trigger_at:$trigger_at, via:$via, status:"pending",
      repeat:null, anchor_at:null, until:null, count_remaining:null,
      created_at:$created_at, fire_count:0, last_fired_at:null}'
}

# ---------- remind_schema_path ----------

@test "schema_path defaults to current profile" {
  run remind_schema_path "ping"
  [ "$status" -eq 0 ]
  [ "$output" = "$JARVIS_HOME/test/reminders/ping.json" ]
}

@test "schema_path with explicit profile uses that profile" {
  run remind_schema_path "ping" "work"
  [ "$status" -eq 0 ]
  [ "$output" = "$JARVIS_HOME/work/reminders/ping.json" ]
}

# ---------- remind_schema_validate ----------

@test "schema_validate accepts a complete blob" {
  blob="$(_one_shot_blob "ping")"
  run remind_schema_validate "$blob"
  [ "$status" -eq 0 ]
}

@test "schema_validate rejects missing slug" {
  blob="$(_one_shot_blob "ping" | jq 'del(.slug)')"
  run remind_schema_validate "$blob"
  [ "$status" -ne 0 ]
}

@test "schema_validate rejects missing message" {
  blob="$(_one_shot_blob "ping" | jq 'del(.message)')"
  run remind_schema_validate "$blob"
  [ "$status" -ne 0 ]
}

@test "schema_validate rejects missing trigger_at" {
  blob="$(_one_shot_blob "ping" | jq 'del(.trigger_at)')"
  run remind_schema_validate "$blob"
  [ "$status" -ne 0 ]
}

@test "schema_validate rejects non-array via" {
  blob="$(_one_shot_blob "ping" | jq '.via = "local"')"
  run remind_schema_validate "$blob"
  [ "$status" -ne 0 ]
}

@test "schema_validate rejects malformed JSON" {
  run remind_schema_validate "{not json}"
  [ "$status" -ne 0 ]
}

# ---------- remind_schema_create ----------

@test "schema_create writes file with documented keys" {
  blob="$(_one_shot_blob "ping")"
  run remind_schema_create "ping" "$blob"
  [ "$status" -eq 0 ]
  [ -f "$JARVIS_HOME/test/reminders/ping.json" ]
  # Assert keys present (sorted) — golden contract.
  keys="$(jq -S 'keys' < "$JARVIS_HOME/test/reminders/ping.json")"
  expected='[
  "anchor_at",
  "count_remaining",
  "created_at",
  "fire_count",
  "last_fired_at",
  "message",
  "profile",
  "repeat",
  "slug",
  "status",
  "trigger_at",
  "until",
  "via"
]'
  [ "$keys" = "$expected" ]
}

@test "schema_create rejects an invalid blob" {
  run remind_schema_create "bad" "{not json}"
  [ "$status" -ne 0 ]
  [ ! -f "$JARVIS_HOME/test/reminders/bad.json" ]
}

@test "schema_create has no delivery_recent field (history lives in NDJSON)" {
  blob="$(_one_shot_blob "ping")"
  run remind_schema_create "ping" "$blob"
  [ "$status" -eq 0 ]
  has="$(jq 'has("delivery_recent")' < "$JARVIS_HOME/test/reminders/ping.json")"
  [ "$has" = "false" ]
}

# ---------- remind_schema_load / save ----------

@test "schema_load returns saved blob" {
  blob="$(_one_shot_blob "ping")"
  remind_schema_create "ping" "$blob" >/dev/null
  run remind_schema_load "ping"
  [ "$status" -eq 0 ]
  loaded_slug="$(jq -r '.slug' <<< "$output")"
  [ "$loaded_slug" = "ping" ]
}

@test "schema_load missing slug returns non-zero" {
  run remind_schema_load "nope"
  [ "$status" -ne 0 ]
}

@test "schema_save updates an existing reminder" {
  blob="$(_one_shot_blob "ping")"
  remind_schema_create "ping" "$blob" >/dev/null
  updated="$(jq -c '.status = "delivered" | .fire_count = 1' \
              < "$JARVIS_HOME/test/reminders/ping.json")"
  run remind_schema_save "ping" "$updated"
  [ "$status" -eq 0 ]
  status_after="$(jq -r '.status' < "$JARVIS_HOME/test/reminders/ping.json")"
  [ "$status_after" = "delivered" ]
}

# ---------- remind_schema_list_profile ----------

@test "schema_list_profile emits slugs one per line" {
  for s in ping pong tick; do
    blob="$(_one_shot_blob "$s")"
    remind_schema_create "$s" "$blob" >/dev/null
  done
  run remind_schema_list_profile "$JARVIS_HOME/test"
  [ "$status" -eq 0 ]
  echo "$output" | sort > "$BATS_TMPDIR/got"
  printf '%s\n' ping pong tick > "$BATS_TMPDIR/want"
  diff "$BATS_TMPDIR/got" "$BATS_TMPDIR/want"
}

@test "schema_list_profile of empty dir returns empty" {
  run remind_schema_list_profile "$JARVIS_HOME/test"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------- delivery NDJSON ----------

@test "delivery_log_path defaults to current profile" {
  run remind_delivery_log_path
  [ "$status" -eq 0 ]
  [ "$output" = "$JARVIS_HOME/test/reminders.delivery.log" ]
}

@test "delivery_log_path with explicit profile" {
  run remind_delivery_log_path work
  [ "$status" -eq 0 ]
  [ "$output" = "$JARVIS_HOME/work/reminders.delivery.log" ]
}

@test "delivery_log_append writes one parseable NDJSON line per call" {
  row1='{"ts":"2026-04-26T14:30:00Z","channel":"local","ok":true}'
  row2='{"ts":"2026-04-26T14:30:01Z","channel":"gotify","ok":false,"error":"500"}'
  remind_delivery_log_append "ping" "$row1"
  remind_delivery_log_append "ping" "$row2"
  log="$JARVIS_HOME/test/reminders.delivery.log"
  [ -f "$log" ]
  count="$(wc -l < "$log")"
  [ "$count" -eq 2 ]
  # Both lines must be jq-parseable AND carry the slug we passed in.
  slugs="$(jq -r '.slug' < "$log" | sort -u)"
  [ "$slugs" = "ping" ]
}

@test "delivery_log_append rejects malformed JSON without partial write" {
  run remind_delivery_log_append "ping" "{not-json}"
  [ "$status" -ne 0 ]
  [ ! -s "$JARVIS_HOME/test/reminders.delivery.log" ]
}
