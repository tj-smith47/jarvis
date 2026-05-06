#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

load 'helper'
load 'shim_helper'

setup() {
  jarvis_common_setup
  shim_setup
  cp -R "${BATS_TEST_DIRNAME}/fixtures/status-profile" "$JARVIS_HOME/test"
  export JARVIS_FAKE_NOW="2026-05-01T15:00:00Z"
}
teardown() { jarvis_common_teardown; }

@test "status --json matches golden fixture (canonical key order)" {
  run bash "${JARVIS_DIR}/cmds/status/status.sh" --json --profile test
  [ "$status" -eq 0 ]
  diff <(printf '%s\n' "$output" | jq -S .) \
       <(jq -S . "${BATS_TEST_DIRNAME}/golden/status.json")
}

@test "status --yaml emits same shape" {
  run bash "${JARVIS_DIR}/cmds/status/status.sh" --yaml --profile test
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q "open: 2"
  printf '%s\n' "$output" | grep -q "minutes_today: 75"
}

@test "status (default pretty) shows real counts" {
  run bash "${JARVIS_DIR}/cmds/status/status.sh" --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"open"* ]]
  [[ "$output" == *"75 min"* ]]
}

@test "status --json with no reminders" {
  rm -rf "$JARVIS_HOME/test/reminders"
  mkdir -p "$JARVIS_HOME/test/reminders"
  run bash "${JARVIS_DIR}/cmds/status/status.sh" --json --profile test
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.reminders.scheduled == 0 and .reminders.next_in_minutes == null' > /dev/null
}
