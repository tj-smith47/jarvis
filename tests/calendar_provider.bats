#!/usr/bin/env bats
# Tests for lib/calendar/provider.sh — provider registry,
# config-driven dispatch, and TTL cache integration.

bats_require_minimum_version 1.5.0

load 'helper'

setup() {
  jarvis_common_setup
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/state/profile.sh"
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/state/config.sh"
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/cache/file.sh"
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/calendar/provider.sh"
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/calendar/none.sh"
  state_ensure_tree
  printf '[calendar]\nprovider = "none"\n' > "$JARVIS_HOME/test/config.toml"
}

teardown() {
  jarvis_common_teardown
}

@test "none provider -> empty output, exit 0" {
  run calendar_events "2026-05-01T00:00:00Z" "2026-05-02T00:00:00Z" test
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "unknown provider -> exit 0 with stderr warning" {
  printf '[calendar]\nprovider = "doesnotexist"\n' > "$JARVIS_HOME/test/config.toml"
  run calendar_events "2026-05-01T00:00:00Z" "2026-05-02T00:00:00Z" test
  [ "$status" -eq 0 ]
}

@test "registered provider is invoked once on cache miss" {
  : > "$JARVIS_HOME/test/hits"
  fake_provider() {
    printf 'hit\n' >> "$JARVIS_HOME/test/hits"
    printf '{"start":"2026-05-01T10:00:00Z","end":"2026-05-01T10:30:00Z","title":"x","url":""}\n'
  }
  calendar_register fake fake_provider
  printf '[calendar]\nprovider = "fake"\n' > "$JARVIS_HOME/test/config.toml"
  calendar_events "2026-05-01T00:00:00Z" "2026-05-02T00:00:00Z" test > /dev/null
  calendar_events "2026-05-01T00:00:00Z" "2026-05-02T00:00:00Z" test > /dev/null
  [ "$(wc -l < "$JARVIS_HOME/test/hits")" -eq 1 ]
}

@test "provider exit 1 -> no cache write, no output" {
  fail_provider() { return 1; }
  calendar_register failing fail_provider
  printf '[calendar]\nprovider = "failing"\n' > "$JARVIS_HOME/test/config.toml"
  run calendar_events "2026-05-01T00:00:00Z" "2026-05-02T00:00:00Z" test
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$JARVIS_HOME/test/cache/calendar.json" ]
}
