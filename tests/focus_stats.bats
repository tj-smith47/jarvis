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
  export TZ=UTC
  # Pin the wall clock to a midday UTC instant. Tests below seed sessions
  # at relative offsets (e.g. -3600s) and assert against
  # `focus_stats_today_minutes`, which filters by UTC start-of-day. When
  # the suite ran near midnight UTC the relative-offset arithmetic
  # crossed the day boundary and "today" sessions were silently
  # excluded. The midday anchor makes that impossible, and individual
  # tests can still override JARVIS_FAKE_NOW per `run` invocation.
  export JARVIS_FAKE_NOW="2026-05-01T12:00:00Z"
}
teardown() { jarvis_common_teardown; }

# Build an ISO timestamp anchored on the test clock (relative offsets in
# seconds). When JARVIS_FAKE_NOW is set the offset is applied to that
# fixed instant; otherwise the system clock is used (legacy behavior).
# Portable across linux + macOS via jq instead of GNU `date -d`.
_iso_offset() {
  if [[ -n "${JARVIS_FAKE_NOW:-}" ]]; then
    jq -nr --arg now "$JARVIS_FAKE_NOW" --argjson off "$1" \
      '($now | fromdateiso8601) + $off | strftime("%Y-%m-%dT%H:%M:%SZ")'
  else
    jq -nr --argjson off "$1" 'now + $off | strftime("%Y-%m-%dT%H:%M:%SZ")'
  fi
}

_seed_pair() {
  local topic="$1" start_off="$2" end_off="$3" duration="${4:-25m}"
  local s e
  s="$(_iso_offset "$start_off")"
  e="$(_iso_offset "$end_off")"
  ndjson_append "$LOG" \
    "$(jq -nc --arg ts "$s" --arg d "$duration" --arg t "$topic" \
        '{ts:$ts,event:"start",duration:$d,topic:$t}')"
  ndjson_append "$LOG" \
    "$(jq -nc --arg ts "$e" --arg t "$topic" \
        '{ts:$ts,event:"end",topic:$t}')"
}

# ---- focus_stats_today_minutes ------------------------------------------

@test "focus_stats_today_minutes returns 0 on empty log" {
  run focus_stats_today_minutes
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "focus_stats_today_minutes sums elapsed across today's sessions" {
  _seed_pair "reviews"   -3600 -3000   # 10 min ago for 10 min
  _seed_pair "design review" -1800 -300    # 30 min ago for 25 min
  _seed_pair "1on1"      -120  -60     # 2 min ago for 1 min

  run focus_stats_today_minutes
  [ "$status" -eq 0 ]
  # 10 + 25 + 1 = 36 minutes
  [ "$output" = "36" ]
}

@test "focus_stats_today_minutes ignores sessions from prior days" {
  _seed_pair "old" -$((9 * 86400)) -$((9 * 86400 - 1500))   # 9 days ago
  _seed_pair "today" -1800 -300                              # today, 25 min

  run focus_stats_today_minutes
  [ "$output" = "25" ]
}

@test "focus_stats_today_minutes ignores orphan starts" {
  ndjson_append "$LOG" \
    "$(jq -nc --arg ts "$(_iso_offset -300)" \
        '{ts:$ts,event:"start",duration:"25m",topic:"orphan"}')"

  run focus_stats_today_minutes
  [ "$output" = "0" ]
}

@test "focus_stats_today_minutes ignores coffee rows (zero duration)" {
  focus_log_append_coffee
  _seed_pair "real" -600 -300   # 5 min today

  run focus_stats_today_minutes
  [ "$output" = "5" ]
}

@test "focus_stats_today_minutes honors JARVIS_FAKE_NOW" {
  # Seed a pair on a fixed UTC date.
  ndjson_append "$LOG" '{"ts":"2026-05-01T10:00:00Z","event":"start","duration":"75m","topic":"focus"}'
  ndjson_append "$LOG" '{"ts":"2026-05-01T11:15:00Z","event":"end","topic":"focus"}'
  # And a pair on a different day.
  ndjson_append "$LOG" '{"ts":"2026-04-30T10:00:00Z","event":"start","duration":"30m","topic":"focus"}'
  ndjson_append "$LOG" '{"ts":"2026-04-30T10:30:00Z","event":"end","topic":"focus"}'

  JARVIS_FAKE_NOW="2026-05-01T15:00:00Z" run focus_stats_today_minutes
  [ "$status" -eq 0 ]
  [ "$output" = "75" ]

  JARVIS_FAKE_NOW="2026-04-30T15:00:00Z" run focus_stats_today_minutes
  [ "$output" = "30" ]
}

# ---- focus_stats_sessions_today -----------------------------------------

@test "focus_stats_sessions_today returns 0 on empty log" {
  run focus_stats_sessions_today
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "focus_stats_sessions_today counts pairs + coffee rows today" {
  _seed_pair "a" -300 -240
  _seed_pair "b" -180 -120
  focus_log_append_coffee

  run focus_stats_sessions_today
  [ "$output" = "3" ]
}

@test "focus_stats_sessions_today excludes prior-day sessions and coffee" {
  _seed_pair "old" -$((9 * 86400)) -$((9 * 86400 - 600))
  ndjson_append "$LOG" \
    "$(jq -nc --arg ts "$(_iso_offset -$((9 * 86400)))" \
        '{ts:$ts,event:"coffee"}')"
  _seed_pair "today" -300 -240

  run focus_stats_sessions_today
  [ "$output" = "1" ]
}

# ---- focus_stats_top_topics ---------------------------------------------

@test "focus_stats_top_topics on empty log returns []" {
  run focus_stats_top_topics
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "focus_stats_top_topics groups, sums, sorts by minutes desc" {
  # Three topics, varied minute totals:
  _seed_pair "design"  -3600 -1800   # 30 min
  _seed_pair "design"  -1500 -900    # 10 min  → design total = 40
  _seed_pair "reviews" -800  -200    # 10 min
  _seed_pair "1on1"    -180  -60     #  2 min

  run focus_stats_top_topics
  [ "$status" -eq 0 ]
  local got
  got="$(echo "$output" | jq -c .)"
  [ "$(echo "$got" | jq -r '.[0].topic')"    = "design" ]
  [ "$(echo "$got" | jq -r '.[0].minutes')"  = "40" ]
  [ "$(echo "$got" | jq -r '.[0].sessions')" = "2" ]
  [ "$(echo "$got" | jq -r '.[1].topic')"    = "reviews" ]
  [ "$(echo "$got" | jq -r '.[2].topic')"    = "1on1" ]
}

@test "focus_stats_top_topics --days N applies cutoff window" {
  _seed_pair "recent" -3600 -1800                              # 30 min today
  _seed_pair "old"    -$((10 * 86400)) -$((10 * 86400 - 1800)) # 30 min, 10d ago

  # Default 7-day window: only "recent"
  run focus_stats_top_topics
  [ "$(echo "$output" | jq 'length')" -eq 1 ]
  [ "$(echo "$output" | jq -r '.[0].topic')" = "recent" ]

  # 14-day window: both
  run focus_stats_top_topics --days 14
  [ "$(echo "$output" | jq 'length')" -eq 2 ]
}

@test "focus_stats_top_topics --limit N caps row count" {
  _seed_pair "a" -3600 -3000
  _seed_pair "b" -2400 -1800
  _seed_pair "c" -1500 -900
  _seed_pair "d" -600  -120

  run focus_stats_top_topics --limit 2
  [ "$(echo "$output" | jq 'length')" -eq 2 ]
}

@test "focus_stats_top_topics excludes null/empty topics" {
  _seed_pair "" -300 -240
  _seed_pair "real" -180 -120

  run focus_stats_top_topics
  [ "$(echo "$output" | jq 'length')" -eq 1 ]
  [ "$(echo "$output" | jq -r '.[0].topic')" = "real" ]
}

# =========================================================================
# `jarvis focus stats` CLI surface (cmds/focus/focus.stats.sh)
# =========================================================================

# Run focus.stats.sh in a fresh subprocess; CLIFT_FLAGS rebuilt via
# standalone_argv from the passed argv.
run_stats() {
  env -i \
    HOME="$HOME" PATH="$PATH" TZ="$TZ" \
    JARVIS_HOME="$JARVIS_HOME" JARVIS_PROFILE="$JARVIS_PROFILE" \
    JARVIS_FAKE_NOW="${JARVIS_FAKE_NOW:-}" \
    CLI_DIR="$JARVIS_DIR" FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR" \
    bash "$JARVIS_DIR/cmds/focus/focus.stats.sh" "$@"
}

@test "focus stats: empty log → friendly no-sessions message" {
  run run_stats
  [ "$status" -eq 0 ]
  [[ "$output" == *"no focus sessions yet"* ]]
}

@test "focus stats --json: stable shape on empty log" {
  run run_stats --json
  [ "$status" -eq 0 ]
  local got
  got="$(echo "$output" | jq -c .)"
  [ "$got" = '{"today_minutes":0,"sessions_today":0,"top_topics":[]}' ]
}

@test "focus stats --json: full payload after seeded sessions" {
  _seed_pair "design"  -3600 -1800   # 30 min today
  _seed_pair "reviews" -800  -200    # 10 min today
  focus_log_append_coffee

  run run_stats --json
  [ "$status" -eq 0 ]
  local got
  got="$(echo "$output" | jq -c .)"
  [ "$(echo "$got" | jq '.today_minutes')"      = "40" ]
  [ "$(echo "$got" | jq '.sessions_today')"     = "3" ]
  [ "$(echo "$got" | jq '.top_topics | length')" = "2" ]
  [ "$(echo "$got" | jq -r '.top_topics[0].topic')" = "design" ]
}

@test "focus stats --yaml: round-trips to identical JSON" {
  _seed_pair "alpha" -600 -300

  local json_out yaml_out
  json_out="$(run_stats --json | jq -cS .)"
  yaml_out="$(run_stats --yaml | yq -o=json | jq -cS .)"
  [ "$json_out" = "$yaml_out" ]
}

@test "focus stats --json and --yaml are mutually exclusive" {
  run run_stats --json --yaml
  [ "$status" -eq 2 ]
}

@test "focus stats: human output contains today minutes + sessions" {
  _seed_pair "demo" -300 -120   # 3 min today

  run run_stats
  [ "$status" -eq 0 ]
  [[ "$output" == *"3 min"* ]]
  [[ "$output" == *"1 session"* ]]
}

@test "focus stats --days N narrows top-topics window" {
  _seed_pair "recent" -3600 -1800
  _seed_pair "old"    -$((10 * 86400)) -$((10 * 86400 - 1800))

  run run_stats --days 7 --json
  [ "$(echo "$output" | jq '.top_topics | length')" = "1" ]

  run run_stats --days 14 --json
  [ "$(echo "$output" | jq '.top_topics | length')" = "2" ]
}
