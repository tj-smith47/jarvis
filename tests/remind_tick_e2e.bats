#!/usr/bin/env bats
# T13 e2e — full roundtrip through the actual cmd scripts:
#   1. `remind <msg> --in 1m` writes the JSON file
#   2. advance JARVIS_FAKE_NOW past trigger_at
#   3. `remind tick` fires the reminder via dispatch (DRYRUN channel)
#   4. assert status=delivered, NDJSON heartbeat + delivery row written
#
# Distinct from jarvis_remind_tick.bats which exercises remind_tick_run as
# a library function. This suite proves the cmd wrappers wire correctly.

bats_require_minimum_version 1.5.0

load 'helper'

setup() {
  jarvis_common_setup
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/state/profile.sh"
  state_ensure_tree
}

teardown() {
  jarvis_common_teardown
}

_remind() {
  bash "${JARVIS_DIR}/cmds/remind/remind.sh" "$@"
}

_tick() {
  bash "${JARVIS_DIR}/cmds/remind/remind.tick.sh" "$@"
}

@test "e2e: schedule --in 1m, advance time, tick fires + marks delivered" {
  export JARVIS_FAKE_NOW="2026-04-26T14:00:00Z"
  export JARVIS_NOTIFY_DRYRUN=1
  run _remind "ping" --in 1m
  [ "$status" -eq 0 ]

  rem_file="$(ls "$JARVIS_HOME/test/reminders/"*.json | head -1)"
  base="${rem_file##*/}"
  slug="${base%.json}"

  # Before tick: still pending.
  [ "$(jq -r '.status' < "$rem_file")" = "pending" ]
  [ "$(jq -r '.fire_count' < "$rem_file")" = "0" ]

  # Advance time past trigger and tick.
  export JARVIS_FAKE_NOW="2026-04-26T14:02:00Z"
  run _tick
  [ "$status" -eq 0 ]

  # After tick: delivered, fired once, last_fired_at = fake now.
  [ "$(jq -r '.status' < "$rem_file")" = "delivered" ]
  [ "$(jq -r '.fire_count' < "$rem_file")" = "1" ]
  [ "$(jq -r '.last_fired_at' < "$rem_file")" = "2026-04-26T14:02:00Z" ]

  # Delivery NDJSON has heartbeat + at least one row keyed by slug.
  log="$JARVIS_HOME/test/reminders.delivery.log"
  [ -f "$log" ]
  hb="$(jq -c 'select(.kind == "tick.heartbeat")' < "$log" | wc -l)"
  [ "$hb" -ge 1 ]
  fires="$(jq -c --arg s "$slug" 'select(.slug == $s)' < "$log" | wc -l)"
  [ "$fires" -ge 1 ]
}

@test "e2e: tick on empty profile only writes heartbeat, exits 0" {
  export JARVIS_FAKE_NOW="2026-04-26T14:02:00Z"
  run _tick
  [ "$status" -eq 0 ]

  log="$JARVIS_HOME/test/reminders.delivery.log"
  [ -f "$log" ]
  total="$(wc -l < "$log")"
  hb="$(jq -c 'select(.kind == "tick.heartbeat")' < "$log" | wc -l)"
  [ "$total" = "$hb" ]
  [ "$hb" = "1" ]
}

@test "e2e: tick recurring advances trigger_at and increments fire_count" {
  export JARVIS_FAKE_NOW="2026-04-26T08:55:00Z"
  export JARVIS_NOTIFY_DRYRUN=1
  run _remind "standup" --repeat daily --at 09:00
  [ "$status" -eq 0 ]

  rem_file="$(ls "$JARVIS_HOME/test/reminders/"*.json | head -1)"
  before_trigger="$(jq -r '.trigger_at' < "$rem_file")"
  [ "$before_trigger" = "2026-04-26T09:00:00Z" ]

  # Advance just past the 09:00 trigger.
  export JARVIS_FAKE_NOW="2026-04-26T09:01:00Z"
  run _tick
  [ "$status" -eq 0 ]

  # Recurring stays active; trigger advances; fire_count incremented.
  [ "$(jq -r '.status' < "$rem_file")" = "active" ]
  [ "$(jq -r '.fire_count' < "$rem_file")" = "1" ]
  [ "$(jq -r '.trigger_at' < "$rem_file")" = "2026-04-27T09:00:00Z" ]
}
