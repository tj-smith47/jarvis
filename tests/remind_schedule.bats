#!/usr/bin/env bats
# Tests for lib/remind/schedule.sh — pure next_trigger
# computation across interval, anchored, weekly/weekdays/weekends,
# day-list, DST seam, and end-of-month wrap.

bats_require_minimum_version 1.5.0

load 'helper'

setup() {
  jarvis_common_setup
  export TZ=UTC
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/remind/schedule.sh"
}

teardown() {
  jarvis_common_teardown
}

# ---------- interval forms ----------

@test "interval 2h after 14:00 → +2h" {
  run remind_next_trigger "2h" "" "2026-04-26T14:00:00Z"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-04-26T16:00:00Z" ]
}

@test "interval 30m after 14:00 → +30m" {
  run remind_next_trigger "30m" "" "2026-04-26T14:00:00Z"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-04-26T14:30:00Z" ]
}

@test "interval 1d after midnight → +1d" {
  run remind_next_trigger "1d" "" "2026-04-26T00:00:00Z"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-04-27T00:00:00Z" ]
}

@test "interval 7d after Sunday → next Sunday same time" {
  run remind_next_trigger "7d" "" "2026-04-26T11:00:00Z"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-05-03T11:00:00Z" ]
}

# ---------- daily anchored ----------

@test "daily anchor 09:00 after 10:00 → tomorrow 09:00" {
  run remind_next_trigger "daily" "09:00" "2026-04-26T10:00:00Z"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-04-27T09:00:00Z" ]
}

@test "daily anchor 17:00 after 10:00 → today 17:00" {
  run remind_next_trigger "daily" "17:00" "2026-04-26T10:00:00Z"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-04-26T17:00:00Z" ]
}

# ---------- weekdays / weekends ----------

@test "weekdays anchor 09:00 after Friday 10:00 → Monday 09:00" {
  # 2026-04-24 is Friday; Saturday + Sunday skipped
  run remind_next_trigger "weekdays" "09:00" "2026-04-24T10:00:00Z"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-04-27T09:00:00Z" ]
}

@test "weekends anchor 10:00 after Sunday 11:00 → next Saturday 10:00" {
  # 2026-04-26 is Sunday
  run remind_next_trigger "weekends" "10:00" "2026-04-26T11:00:00Z"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-05-02T10:00:00Z" ]
}

@test "weekends anchor 10:00 after Friday 11:00 → Saturday 10:00" {
  # 2026-04-24 is Friday
  run remind_next_trigger "weekends" "10:00" "2026-04-24T11:00:00Z"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-04-25T10:00:00Z" ]
}

# ---------- day-list ----------

@test "day-list mon,wed after Tuesday 10:00 → Wednesday 09:00" {
  # 2026-04-28 is Tuesday
  run remind_next_trigger "mon,wed" "09:00" "2026-04-28T10:00:00Z"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-04-29T09:00:00Z" ]
}

@test "day-list fri after Saturday → next Friday" {
  # 2026-04-25 is Saturday
  run remind_next_trigger "fri" "09:00" "2026-04-25T10:00:00Z"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-05-01T09:00:00Z" ]
}

# ---------- weekly preserves day-of-week ----------

@test "weekly anchor 10:00 after Sunday 11:00 → next Sunday 10:00" {
  run remind_next_trigger "weekly" "10:00" "2026-04-26T11:00:00Z"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-05-03T10:00:00Z" ]
}

# ---------- end-of-month wrap ----------

@test "weekly anchor preserves day-of-week across month boundary" {
  # 2026-01-31 is Saturday
  run remind_next_trigger "weekly" "09:00" "2026-01-31T10:00:00Z"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-02-07T09:00:00Z" ]
}

@test "interval 1d crosses month boundary" {
  run remind_next_trigger "1d" "" "2026-01-31T15:00:00Z"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-02-01T15:00:00Z" ]
}

# ---------- DST seam ----------

# Spring forward (US/Eastern 2026-03-08 02:00 → 03:00 EDT; 02:30 doesn't exist)
@test "daily anchor 02:30 across spring-forward skips the gap day" {
  TZ="America/New_York" run remind_next_trigger "daily" "02:30" "2026-03-07T08:00:00Z"
  [ "$status" -eq 0 ]
  # 2026-03-07 02:30 EST already past (after = 03:00 EST). Next valid:
  # 2026-03-08 02:30 doesn't exist (gap); skip → 2026-03-09 02:30 EDT = 06:30Z.
  [ "$output" = "2026-03-09T06:30:00Z" ]
}

# Fall back (US/Eastern 2026-11-01 02:00 EDT → 01:00 EST; 01:30 ambiguous)
@test "daily anchor 01:30 across fall-back fires once at first 01:30" {
  TZ="America/New_York" run remind_next_trigger "daily" "01:30" "2026-10-31T10:00:00Z"
  [ "$status" -eq 0 ]
  # 2026-10-31 01:30 EDT past; next: 2026-11-01 01:30 EDT (first occurrence) = 05:30 UTC.
  [ "$output" = "2026-11-01T05:30:00Z" ]
}

# ---------- error contracts ----------

@test "anchored without anchor errors" {
  run remind_next_trigger "daily" "" "2026-04-26T10:00:00Z"
  [ "$status" -eq 2 ]
}

@test "garbage after-iso errors (no silent epoch-0)" {
  run remind_next_trigger "2h" "" "not-a-date"
  [ "$status" -eq 2 ]
}

@test "garbage repeat errors" {
  run remind_next_trigger "sometime" "09:00" "2026-04-26T10:00:00Z"
  [ "$status" -eq 2 ]
}

@test "empty repeat errors" {
  run remind_next_trigger "" "09:00" "2026-04-26T10:00:00Z"
  [ "$status" -eq 2 ]
}
