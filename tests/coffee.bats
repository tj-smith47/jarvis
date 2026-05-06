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
  # Strip gum from PATH so coffee falls back to plain sleep — keeps tests
  # fast (~3s sleep is unavoidable per the script's intent) and removes
  # tty dependence.
  export PATH="$(echo "$PATH" | tr ':' '\n' | grep -v gum | tr '\n' ':')"
}
teardown() { jarvis_common_teardown; }

run_coffee() {
  env -i \
    HOME="$HOME" PATH="$PATH" \
    JARVIS_HOME="$JARVIS_HOME" JARVIS_PROFILE="$JARVIS_PROFILE" \
    CLI_DIR="$JARVIS_DIR" FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR" \
    bash "$JARVIS_DIR/cmds/coffee/coffee.sh" "$@"
}

@test "coffee writes one coffee row to focus.log" {
  run run_coffee
  [ "$status" -eq 0 ]
  [ -f "$LOG" ]
  [ "$(jq -rs 'map(select(.event=="coffee")) | length' "$LOG")" -eq 1 ]
}

@test "coffee --no-log skips the focus.log row" {
  run run_coffee --no-log
  [ "$status" -eq 0 ]
  [ ! -f "$LOG" ]
}

@test "two coffees → two rows" {
  run run_coffee
  [ "$status" -eq 0 ]
  run run_coffee
  [ "$status" -eq 0 ]
  [ "$(jq -rs 'map(select(.event=="coffee")) | length' "$LOG")" -eq 2 ]
}

@test "coffee row increments focus_stats_sessions_today" {
  run run_coffee
  run focus_stats_sessions_today
  [ "$output" = "1" ]
}
