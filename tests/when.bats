#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

load helper

# jarvis_when.bats
# Coverage for the jarvis-when Python helper (parse / humanize / delta /
# next-occurrence / --protocol-version). All assertions pin time via
# JARVIS_FAKE_NOW so the suite is deterministic regardless of wall clock.

WHEN=
FAKE_NOW="2026-04-28T12:00:00Z"   # Tuesday

setup() {
  JARVIS_DIR="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  WHEN="$JARVIS_DIR/bin/jarvis-when"
  if [[ ! -x "$WHEN" ]]; then
    bash "$JARVIS_DIR/scripts/build_when.sh"
  fi
  jarvis_common_setup
  export JARVIS_FAKE_NOW="$FAKE_NOW"
}

teardown() {
  jarvis_common_teardown
  unset JARVIS_FAKE_NOW JARVIS_TODAY
}

# ---------- Protocol --------------------------------------------------------

@test "jarvis-when --protocol-version prints 1" {
  run "$WHEN" --protocol-version
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "jarvis-when --help exits 0 with non-empty output" {
  run "$WHEN" --help
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "jarvis-when no-args prints help (exit 0)" {
  run "$WHEN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"jarvis-when"* ]]
}

@test "jarvis-when unknown subcommand exits 2" {
  run "$WHEN" frobnicate
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown subcommand"* ]]
}

# ---------- parse: keywords -------------------------------------------------

@test "parse now == FAKE_NOW" {
  run "$WHEN" parse now
  [ "$status" -eq 0 ]
  [ "$output" = "$FAKE_NOW" ]
}

@test "parse today == FAKE_NOW date at 00:00:00" {
  run "$WHEN" parse today
  [ "$status" -eq 0 ]
  [ "$output" = "2026-04-28T00:00:00Z" ]
}

@test "parse tomorrow == next-day midnight" {
  run "$WHEN" parse tomorrow
  [ "$status" -eq 0 ]
  [ "$output" = "2026-04-29T00:00:00Z" ]
}

@test "parse yesterday == prev-day midnight" {
  run "$WHEN" parse yesterday
  [ "$status" -eq 0 ]
  [ "$output" = "2026-04-27T00:00:00Z" ]
}

# ---------- parse: durations ------------------------------------------------

@test "parse 'in 2h' adds 2 hours" {
  run "$WHEN" parse "in 2h"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-04-28T14:00:00Z" ]
}

@test "parse '5m ago' subtracts 5 minutes" {
  run "$WHEN" parse "5m ago"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-04-28T11:55:00Z" ]
}

@test "parse bare duration '30m' == 'in 30m'" {
  run "$WHEN" parse "30m"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-04-28T12:30:00Z" ]
}

@test "parse compound duration '1h30m' adds 90 minutes" {
  run "$WHEN" parse "1h30m"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-04-28T13:30:00Z" ]
}

@test "parse week duration '1w'" {
  run "$WHEN" parse "1w"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-05-05T12:00:00Z" ]
}

# ---------- parse: HH:MM ----------------------------------------------------

@test "parse HH:MM future today stays today" {
  run "$WHEN" parse "13:30"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-04-28T13:30:00Z" ]
}

@test "parse HH:MM past rolls to tomorrow" {
  run "$WHEN" parse "09:00"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-04-29T09:00:00Z" ]
}

@test "parse 'tomorrow HH:MM' anchors to next day" {
  run "$WHEN" parse "tomorrow 09:00"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-04-29T09:00:00Z" ]
}

# ---------- parse: calendar / ISO ------------------------------------------

@test "parse YYYY-MM-DD == midnight UTC" {
  run "$WHEN" parse "2026-12-31"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-12-31T00:00:00Z" ]
}

@test "parse 'YYYY-MM-DD HH:MM' == that minute UTC" {
  run "$WHEN" parse "2026-12-31 09:00"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-12-31T09:00:00Z" ]
}

@test "parse ISO 8601 with Z passes through" {
  run "$WHEN" parse "2026-06-15T15:30:45Z"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-06-15T15:30:45Z" ]
}

@test "parse ISO 8601 with +offset converts to UTC" {
  run "$WHEN" parse "2026-06-15T15:30:00+05:00"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-06-15T10:30:00Z" ]
}

# ---------- parse: weekday names -------------------------------------------

@test "parse 'next monday' from a Tuesday FAKE_NOW" {
  run "$WHEN" parse "next monday"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-05-04T00:00:00Z" ]
}

@test "parse bare weekday == next occurrence" {
  run "$WHEN" parse "friday"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-05-01T00:00:00Z" ]
}

@test "parse 'last friday' == prev occurrence" {
  run "$WHEN" parse "last friday"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-04-24T00:00:00Z" ]
}

@test "parse weekday today (Tuesday) returns next-week Tuesday" {
  # When FAKE_NOW is Tuesday, "tuesday" should NOT be today (degenerate);
  # roll to next week so callers get a strictly-future moment.
  run "$WHEN" parse "tuesday"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-05-05T00:00:00Z" ]
}

# ---------- parse: error paths ---------------------------------------------

@test "parse empty expression exits 2" {
  run "$WHEN" parse ""
  [ "$status" -eq 2 ]
}

@test "parse gibberish exits 2 with stderr" {
  run "$WHEN" parse "frobnicate the widget"
  [ "$status" -eq 2 ]
  [[ "$output" == *"unrecognised"* ]] || [[ "$output" == *"jarvis-when"* ]]
}

@test "parse missing argument exits 2" {
  run "$WHEN" parse
  [ "$status" -eq 2 ]
}

# ---------- humanize --------------------------------------------------------

@test "humanize a near-future timestamp says 'in Ns'" {
  run "$WHEN" humanize "2026-04-28T12:00:30Z"
  [ "$status" -eq 0 ]
  [ "$output" = "in 30s" ]
}

@test "humanize a near-past timestamp says 'Ns ago'" {
  run "$WHEN" humanize "2026-04-28T11:59:30Z"
  [ "$status" -eq 0 ]
  [ "$output" = "30s ago" ]
}

@test "humanize a same-day future timestamp says 'today at HH:MM'" {
  run "$WHEN" humanize "2026-04-28T15:00:00Z"
  [ "$status" -eq 0 ]
  [ "$output" = "today at 15:00" ]
}

@test "humanize a tomorrow timestamp says 'tomorrow at HH:MM'" {
  run "$WHEN" humanize "2026-04-29T09:00:00Z"
  [ "$status" -eq 0 ]
  [ "$output" = "tomorrow at 9:00" ]
}

@test "humanize a multi-day-future timestamp uses 'in Xd' form" {
  run "$WHEN" humanize "2026-05-05T12:00:00Z"
  [ "$status" -eq 0 ]
  [ "$output" = "in 1w" ]
}

@test "humanize a multi-day-past timestamp uses 'X ago' form" {
  run "$WHEN" humanize "2026-04-26T12:00:00Z"
  [ "$status" -eq 0 ]
  [ "$output" = "2d ago" ]
}

# ---------- delta -----------------------------------------------------------

@test "delta forward direction prints positive compact form" {
  run "$WHEN" delta "2026-04-28T12:00:00Z" "2026-04-30T15:30:00Z"
  [ "$status" -eq 0 ]
  [ "$output" = "2d 3h 30m" ]
}

@test "delta zero prints '0s'" {
  run "$WHEN" delta "2026-04-28T12:00:00Z" "2026-04-28T12:00:00Z"
  [ "$status" -eq 0 ]
  [ "$output" = "0s" ]
}

@test "delta backward direction prints negative" {
  run "$WHEN" delta "2026-04-30T15:30:00Z" "2026-04-28T12:00:00Z"
  [ "$status" -eq 0 ]
  [ "$output" = "-2d 3h 30m" ]
}

@test "delta sub-minute precision" {
  run "$WHEN" delta "2026-04-28T12:00:00Z" "2026-04-28T12:00:45Z"
  [ "$status" -eq 0 ]
  [ "$output" = "45s" ]
}

# ---------- next-occurrence ------------------------------------------------

@test "next-occurrence friday from Tuesday == that Friday" {
  run "$WHEN" next-occurrence friday
  [ "$status" -eq 0 ]
  [ "$output" = "2026-05-01T00:00:00Z" ]
}

@test "next-occurrence accepts short weekday names" {
  run "$WHEN" next-occurrence wed
  [ "$status" -eq 0 ]
  [ "$output" = "2026-04-29T00:00:00Z" ]
}

@test "next-occurrence rejects non-weekday with exit 2" {
  run "$WHEN" next-occurrence frobday
  [ "$status" -eq 2 ]
}

# ---------- JARVIS_TODAY precedence ----------------------------------------

@test "JARVIS_TODAY overrides JARVIS_FAKE_NOW for 'today'" {
  export JARVIS_TODAY=2026-06-15
  run "$WHEN" parse today
  [ "$status" -eq 0 ]
  [ "$output" = "2026-06-15T00:00:00Z" ]
}

@test "JARVIS_TODAY override propagates to relative durations" {
  export JARVIS_TODAY=2026-06-15
  run "$WHEN" parse "in 1h"
  [ "$status" -eq 0 ]
  # JARVIS_TODAY sets time to 00:00, +1h = 01:00
  [ "$output" = "2026-06-15T01:00:00Z" ]
}

@test "Bad JARVIS_FAKE_NOW exits 2 with diagnostic" {
  export JARVIS_FAKE_NOW="not-a-date"
  run "$WHEN" parse now
  [ "$status" -eq 2 ]
  [[ "$output" == *"JARVIS_FAKE_NOW"* ]]
}

@test "Bad JARVIS_TODAY exits 2 with diagnostic" {
  export JARVIS_TODAY="2026/06/15"
  run "$WHEN" parse today
  [ "$status" -eq 2 ]
  [[ "$output" == *"JARVIS_TODAY"* ]]
}
