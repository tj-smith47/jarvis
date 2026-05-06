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
  # Strip gum from PATH so focus + coffee fall through to plain sleep,
  # avoiding tty checks that misbehave under bats.
  export PATH="$(echo "$PATH" | tr ':' '\n' | grep -v gum | tr '\n' ':')"
  export TZ=UTC
}
teardown() { jarvis_common_teardown; }

run_focus()  {
  env -i HOME="$HOME" PATH="$PATH" \
    JARVIS_HOME="$JARVIS_HOME" JARVIS_PROFILE="$JARVIS_PROFILE" \
    CLI_DIR="$JARVIS_DIR" FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR" \
    bash "$JARVIS_DIR/cmds/focus/focus.sh" "$@"
}
run_coffee() {
  env -i HOME="$HOME" PATH="$PATH" \
    JARVIS_HOME="$JARVIS_HOME" JARVIS_PROFILE="$JARVIS_PROFILE" \
    CLI_DIR="$JARVIS_DIR" FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR" \
    bash "$JARVIS_DIR/cmds/coffee/coffee.sh" "$@"
}
run_stats()  {
  env -i HOME="$HOME" PATH="$PATH" TZ="$TZ" \
    JARVIS_HOME="$JARVIS_HOME" JARVIS_PROFILE="$JARVIS_PROFILE" \
    CLI_DIR="$JARVIS_DIR" FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR" \
    bash "$JARVIS_DIR/cmds/focus/focus.stats.sh" "$@"
}

@test "focus round-trip: complete + interrupt + coffee + stats" {
  # 1. Complete a 1s focus session.
  run run_focus 1s --on demo --silent
  [ "$status" -eq 0 ]

  # 2. Start a long session and SIGTERM it mid-flight (acts like Ctrl+C
  #    via the EXIT trap path; see jarvis_focus.bats for the rationale).
  setsid env -i HOME="$HOME" PATH="$PATH" \
    JARVIS_HOME="$JARVIS_HOME" JARVIS_PROFILE="$JARVIS_PROFILE" \
    CLI_DIR="$JARVIS_DIR" FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR" \
    bash "$JARVIS_DIR/cmds/focus/focus.sh" 25m --on long-run --silent \
    >/dev/null 2>&1 &
  local pid=$!
  local tries=0
  until [[ "$(jq -rs 'map(select(.event=="start" and .topic=="long-run")) | length' "$LOG" 2>/dev/null)" = "1" ]]; do
    tries=$((tries + 1))
    (( tries > 50 )) && break
    sleep 0.1
  done
  kill -TERM -- -"$pid"
  wait "$pid" 2>/dev/null || true

  # 3. Two coffees: one with --no-log (excluded), one logged.
  run run_coffee --no-log
  [ "$status" -eq 0 ]
  run run_coffee
  [ "$status" -eq 0 ]

  # 4. Inspect the raw log: 2 start/end pairs + 1 coffee = 5 rows.
  [ "$(jq -rs 'length' "$LOG")" -eq 5 ]
  [ "$(jq -rs 'map(select(.event=="start")) | length' "$LOG")" -eq 2 ]
  [ "$(jq -rs 'map(select(.event=="end"))   | length' "$LOG")" -eq 2 ]
  [ "$(jq -rs 'map(select(.event=="coffee")) | length' "$LOG")" -eq 1 ]

  # 5. Stats — JSON shape sanity.
  run run_stats --json
  [ "$status" -eq 0 ]
  local got
  got="$(echo "$output" | jq -c .)"
  # 1 demo + 1 long-run + 1 coffee = 3 sessions today.
  [ "$(echo "$got" | jq '.sessions_today')" -eq 3 ]
  # Two distinct topics tracked (coffee is not a topic).
  [ "$(echo "$got" | jq '.top_topics | length')" -eq 2 ]
  local topics
  topics="$(echo "$got" | jq -rc '.top_topics | map(.topic) | sort')"
  [ "$topics" = '["demo","long-run"]' ]
  # Today minutes is non-negative; tight bound infeasible (timing).
  [ "$(echo "$got" | jq '.today_minutes >= 0')" = "true" ]
}
