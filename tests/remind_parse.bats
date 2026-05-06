#!/usr/bin/env bats
# Tests for lib/remind/parse.sh — pure parsers for
# --in / --at / --repeat. Time is pinned via JARVIS_FAKE_NOW.

bats_require_minimum_version 1.5.0

load 'helper'

setup() {
  jarvis_common_setup
  export TZ=UTC
  export JARVIS_FAKE_NOW="2026-04-26T14:00:00Z"
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/remind/parse.sh"
}

teardown() {
  jarvis_common_teardown
}

# ---------- remind_parse_in ----------

@test "parse_in 10m → now + 10m UTC" {
  run remind_parse_in 10m
  [ "$status" -eq 0 ]
  [ "$output" = "2026-04-26T14:10:00Z" ]
}

@test "parse_in 30s → now + 30s UTC" {
  run remind_parse_in 30s
  [ "$status" -eq 0 ]
  [ "$output" = "2026-04-26T14:00:30Z" ]
}

@test "parse_in 2h → now + 2h UTC" {
  run remind_parse_in 2h
  [ "$status" -eq 0 ]
  [ "$output" = "2026-04-26T16:00:00Z" ]
}

@test "parse_in 1d → now + 24h UTC" {
  run remind_parse_in 1d
  [ "$status" -eq 0 ]
  [ "$output" = "2026-04-27T14:00:00Z" ]
}

@test "parse_in garbage → exit 2" {
  run remind_parse_in "later"
  [ "$status" -eq 2 ]
}

@test "parse_in empty → exit 2" {
  run remind_parse_in ""
  [ "$status" -eq 2 ]
}

# ---------- remind_parse_at ----------

@test "parse_at HH:MM future today resolves today" {
  run remind_parse_at "17:00"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-04-26T17:00:00Z" ]
}

@test "parse_at HH:MM past today rolls to tomorrow" {
  run remind_parse_at "09:00"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-04-27T09:00:00Z" ]
}

@test "parse_at HH:MM equal to now rolls to tomorrow" {
  # JARVIS_FAKE_NOW=14:00; --at 14:00 must NOT resolve to right now.
  run remind_parse_at "14:00"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-04-27T14:00:00Z" ]
}

@test "parse_at absolute future date" {
  run remind_parse_at "2026-04-27 09:00"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-04-27T09:00:00Z" ]
}

@test "parse_at absolute past date errors" {
  run remind_parse_at "2026-04-20 09:00"
  [ "$status" -eq 2 ]
  [[ "$output" == *"is in the past"* ]]
}

@test "parse_at garbage errors" {
  run remind_parse_at "tomorrow"
  [ "$status" -eq 2 ]
}

# ---------- remind_parse_repeat ----------

@test "parse_repeat daily passes through" {
  run remind_parse_repeat "daily"
  [ "$status" -eq 0 ]
  [ "$output" = "daily" ]
}

@test "parse_repeat weekly passes through" {
  run remind_parse_repeat "weekly"
  [ "$status" -eq 0 ]
  [ "$output" = "weekly" ]
}

@test "parse_repeat weekdays passes through" {
  run remind_parse_repeat "weekdays"
  [ "$status" -eq 0 ]
  [ "$output" = "weekdays" ]
}

@test "parse_repeat weekends passes through" {
  run remind_parse_repeat "weekends"
  [ "$status" -eq 0 ]
  [ "$output" = "weekends" ]
}

@test "parse_repeat 2h interval passes through" {
  run remind_parse_repeat "2h"
  [ "$status" -eq 0 ]
  [ "$output" = "2h" ]
}

@test "parse_repeat 1d interval passes through" {
  run remind_parse_repeat "1d"
  [ "$status" -eq 0 ]
  [ "$output" = "1d" ]
}

@test "parse_repeat day-list canonicalizes sorted" {
  run remind_parse_repeat "fri,mon"
  [ "$status" -eq 0 ]
  [ "$output" = "mon,fri" ]
}

@test "parse_repeat day-list mon,wed,fri stays sorted" {
  run remind_parse_repeat "mon,wed,fri"
  [ "$status" -eq 0 ]
  [ "$output" = "mon,wed,fri" ]
}

@test "parse_repeat single day mon" {
  run remind_parse_repeat "mon"
  [ "$status" -eq 0 ]
  [ "$output" = "mon" ]
}

@test "parse_repeat invalid day errors" {
  run remind_parse_repeat "monday,tuesday"
  [ "$status" -eq 2 ]
}

@test "parse_repeat garbage errors" {
  run remind_parse_repeat "sometime"
  [ "$status" -eq 2 ]
}

@test "parse_repeat empty errors" {
  run remind_parse_repeat ""
  [ "$status" -eq 2 ]
}
