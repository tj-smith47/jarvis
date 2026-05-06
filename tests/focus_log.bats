#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

load helper

setup() {
  jarvis_common_setup
  source "$JARVIS_DIR/lib/state/profile.sh"
  source "$JARVIS_DIR/lib/state/lock.sh"
  source "$JARVIS_DIR/lib/state/ndjson.sh"
  source "$JARVIS_DIR/lib/focus/log.sh"
  LOG="$(focus_log_path)"
}
teardown() { jarvis_common_teardown; }

# ---- focus_log_path -----------------------------------------------------

@test "focus_log_path resolves under profile dir" {
  run focus_log_path
  [ "$status" -eq 0 ]
  [[ "$output" == "$JARVIS_HOME/$JARVIS_PROFILE/focus.log" ]]
}

# ---- focus_log_append (start) -------------------------------------------

@test "focus_log_append start writes one row with topic + duration" {
  focus_log_append start "25m" "design review"
  [ -f "$LOG" ]
  run jq -c '.' "$LOG"
  [ "$(echo "$output" | jq -r '.event')"    = "start" ]
  [ "$(echo "$output" | jq -r '.duration')" = "25m" ]
  [ "$(echo "$output" | jq -r '.topic')"    = "design review" ]
  [[ "$(echo "$output" | jq -r '.ts')" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]
}

@test "focus_log_append start with empty topic emits null" {
  focus_log_append start "1s" ""
  run jq -r '.topic' "$LOG"
  [ "$output" = "null" ]
}

# ---- focus_log_append (end) ---------------------------------------------

@test "focus_log_append end writes row without duration key" {
  focus_log_append end "" "demo"
  run jq -c '.' "$LOG"
  [ "$(echo "$output" | jq -r '.event')" = "end" ]
  [ "$(echo "$output" | jq -r '.topic')" = "demo" ]
  [ "$(echo "$output" | jq -r 'has("duration")')" = "false" ]
}

# ---- focus_log_append (validation) --------------------------------------

@test "focus_log_append rejects unknown event" {
  run focus_log_append weird "1s" "topic"
  [ "$status" -eq 2 ]
  [ ! -f "$LOG" ]
}

# ---- focus_log_append_coffee --------------------------------------------

@test "focus_log_append_coffee writes a single coffee row" {
  focus_log_append_coffee
  run jq -c '.' "$LOG"
  [ "$(echo "$output" | jq -r '.event')"        = "coffee" ]
  [ "$(echo "$output" | jq -r 'has("topic")')"  = "false" ]
}

# ---- focus_session_pairs ------------------------------------------------

@test "focus_session_pairs pairs simple start+end on same topic" {
  ndjson_append "$LOG" '{"ts":"2026-04-25T14:00:00Z","event":"start","duration":"25m","topic":"reviews"}'
  ndjson_append "$LOG" '{"ts":"2026-04-25T14:25:00Z","event":"end","topic":"reviews"}'

  run focus_session_pairs
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l)" -eq 1 ]
  [ "$(echo "$output" | jq -r '.topic')"           = "reviews" ]
  [ "$(echo "$output" | jq -r '.duration')"        = "25m" ]
  [ "$(echo "$output" | jq -r '.elapsed_seconds')" = "1500" ]
  [ "$(echo "$output" | jq -r '.start_ts')"        = "2026-04-25T14:00:00Z" ]
  [ "$(echo "$output" | jq -r '.end_ts')"          = "2026-04-25T14:25:00Z" ]
}

@test "focus_session_pairs disambiguates two parallel topics with out-of-order ends" {
  ndjson_append "$LOG" '{"ts":"2026-04-25T09:00:00Z","event":"start","duration":"2h","topic":"long"}'
  ndjson_append "$LOG" '{"ts":"2026-04-25T09:30:00Z","event":"start","duration":"25m","topic":"quick"}'
  ndjson_append "$LOG" '{"ts":"2026-04-25T11:00:00Z","event":"end","topic":"long"}'
  ndjson_append "$LOG" '{"ts":"2026-04-25T11:05:00Z","event":"end","topic":"quick"}'

  run focus_session_pairs
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l)" -eq 2 ]

  local long_elapsed quick_elapsed
  long_elapsed="$(echo "$output" | jq -rs 'map(select(.topic=="long"))[0].elapsed_seconds')"
  quick_elapsed="$(echo "$output" | jq -rs 'map(select(.topic=="quick"))[0].elapsed_seconds')"

  [ "$long_elapsed"  = "7200" ]   # 09:00 → 11:00
  [ "$quick_elapsed" = "5700" ]   # 09:30 → 11:05
}

@test "focus_session_pairs ignores orphan starts" {
  ndjson_append "$LOG" '{"ts":"2026-04-25T09:00:00Z","event":"start","duration":"25m","topic":"orphan"}'
  ndjson_append "$LOG" '{"ts":"2026-04-25T10:00:00Z","event":"start","duration":"25m","topic":"paired"}'
  ndjson_append "$LOG" '{"ts":"2026-04-25T10:25:00Z","event":"end","topic":"paired"}'

  run focus_session_pairs
  [ "$(echo "$output" | wc -l)" -eq 1 ]
  [ "$(echo "$output" | jq -r '.topic')" = "paired" ]
}

@test "focus_session_pairs ignores coffee rows" {
  ndjson_append "$LOG" '{"ts":"2026-04-25T14:00:00Z","event":"coffee"}'
  ndjson_append "$LOG" '{"ts":"2026-04-25T14:01:00Z","event":"start","duration":"5s","topic":"foo"}'
  ndjson_append "$LOG" '{"ts":"2026-04-25T14:01:05Z","event":"end","topic":"foo"}'

  run focus_session_pairs
  [ "$(echo "$output" | wc -l)" -eq 1 ]
  [ "$(echo "$output" | jq -r '.topic')"           = "foo" ]
  [ "$(echo "$output" | jq -r '.elapsed_seconds')" = "5" ]
}

@test "focus_session_pairs on empty log returns nothing, exit 0" {
  run focus_session_pairs
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---- focus_orphan_starts ------------------------------------------------

@test "focus_orphan_starts emits one row per unended start" {
  ndjson_append "$LOG" '{"ts":"2026-04-25T09:00:00Z","event":"start","duration":"25m","topic":"orphan-a"}'
  ndjson_append "$LOG" '{"ts":"2026-04-25T09:30:00Z","event":"start","duration":"25m","topic":"orphan-b"}'
  ndjson_append "$LOG" '{"ts":"2026-04-25T10:00:00Z","event":"start","duration":"25m","topic":"paired"}'
  ndjson_append "$LOG" '{"ts":"2026-04-25T10:25:00Z","event":"end","topic":"paired"}'

  run focus_orphan_starts
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l)" -eq 2 ]
  local topics
  topics="$(echo "$output" | jq -rs 'map(.topic) | sort | join(",")')"
  [ "$topics" = "orphan-a,orphan-b" ]
}

@test "focus_orphan_starts on empty log returns nothing, exit 0" {
  run focus_orphan_starts
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
