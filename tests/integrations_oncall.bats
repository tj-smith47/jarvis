#!/usr/bin/env bats
# Tests for lib/integrations/oncall.sh — config-driven oncall
# reader. No external CLI; reads [oncall] table from <profile>/config.toml.

bats_require_minimum_version 1.5.0

load 'helper'

setup() {
  jarvis_common_setup
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/state/profile.sh"
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/state/config.sh"
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/integrations/oncall.sh"
  state_ensure_tree
}

teardown() {
  jarvis_common_teardown
}

@test "no config -> empty output" {
  run oncall_show test
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "primary + secondary + pager -> 2 rows" {
  cat > "$JARVIS_HOME/test/config.toml" <<EOF
[oncall]
primary = "alex"
secondary = "you"
pager = "quiet"
EOF
  run oncall_show test
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 2 ]
  printf '%s\n' "$output" | head -1 | jq -e '.role == "primary" and .who == "alex" and .pager == "quiet"' > /dev/null
  printf '%s\n' "$output" | sed -n 2p | jq -e '.role == "secondary" and .who == "you" and (has("pager") | not)' > /dev/null
}

@test "primary only" {
  cat > "$JARVIS_HOME/test/config.toml" <<EOF
[oncall]
primary = "alex"
EOF
  run oncall_show test
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
}

@test "[oncall] until is surfaced on every emitted row when set" {
  cat > "$JARVIS_HOME/test/config.toml" <<EOF
[oncall]
primary   = "alex"
secondary = "you"
until     = "2026-05-09"
EOF
  run oncall_show test
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | head -1 | jq -e '.until == "2026-05-09"' > /dev/null
  printf '%s\n' "$output" | sed -n 2p | jq -e '.until == "2026-05-09"' > /dev/null
}

@test "until omitted when not in config (no key emitted)" {
  cat > "$JARVIS_HOME/test/config.toml" <<EOF
[oncall]
primary = "alex"
EOF
  run oncall_show test
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e 'has("until") | not' > /dev/null
}
