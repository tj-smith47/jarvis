#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

load helper

setup() {
  jarvis_common_setup
  source "$JARVIS_DIR/lib/slug.sh"
  TASKS_DIR="$JARVIS_HOME/test/tasks"
  mkdir -p "$TASKS_DIR"
}
teardown() { jarvis_common_teardown; }

@test "slug_from_desc lowercases and hyphenates" {
  run slug_from_desc "Fix k3s etcd restore"
  [ "$status" -eq 0 ]
  [ "$output" = "fix-k3s-etcd-restore" ]
}

@test "slug_from_desc uses only the first line" {
  run slug_from_desc $'Fix k3s etcd restore\nsecond line ignored'
  [ "$status" -eq 0 ]
  [ "$output" = "fix-k3s-etcd-restore" ]
}

@test "slug_from_desc strips punctuation and collapses hyphens" {
  run slug_from_desc "Review  auth PR -- urgent!!!"
  [ "$status" -eq 0 ]
  [ "$output" = "review-auth-pr-urgent" ]
}

@test "slug_from_desc trims leading/trailing hyphens" {
  run slug_from_desc "-- weirdly bracketed --"
  [ "$status" -eq 0 ]
  [ "$output" = "weirdly-bracketed" ]
}

@test "slug_from_desc fails on empty input" {
  run slug_from_desc ""
  [ "$status" -ne 0 ]
}

@test "slug_from_desc fails on whitespace-only input" {
  run slug_from_desc "   "
  [ "$status" -ne 0 ]
}

@test "slug_from_desc caps at 100 chars" {
  local long_desc
  long_desc="$(printf 'word %.0s' {1..200})"  # ~1000 chars
  run slug_from_desc "$long_desc"
  [ "$status" -eq 0 ]
  [ "${#output}" -le 100 ]
  # Must not end with trailing hyphen
  [[ "$output" != *- ]]
}

@test "slug_is_jira_key recognizes PLAT-123" {
  run slug_is_jira_key "PLAT-123"
  [ "$status" -eq 0 ]
}

@test "slug_is_jira_key rejects lowercase prefix" {
  run slug_is_jira_key "plat-123"
  [ "$status" -ne 0 ]
}

@test "slug_is_jira_key rejects normal slug" {
  run slug_is_jira_key "fix-k3s-etcd"
  [ "$status" -ne 0 ]
}

@test "slug_is_jira_key rejects 1-letter project key (A-1)" {
  # Real Atlassian project keys are 2+ characters; the prior regex
  # `^[A-Z]+-[0-9]+$` accepted single-letter prefixes like A-1, which
  # would mis-route a slug like a slug `A-1` (legal as a normal slug)
  # into the Jira passthrough branch.
  run slug_is_jira_key "A-1"
  [ "$status" -ne 0 ]
}

@test "slug_is_jira_key accepts 2+ letter project key with digit suffix" {
  # JR1-123 is a real shape (project keys allow digits in positions 2+).
  run slug_is_jira_key "JR1-123"
  [ "$status" -eq 0 ]
}

@test "slug_resolve_collision returns base when unused" {
  run slug_resolve_collision "fix-k3s" "$TASKS_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "fix-k3s" ]
}

@test "slug_resolve_collision appends -2 on first clash" {
  : > "$TASKS_DIR/fix-k3s.json"
  run slug_resolve_collision "fix-k3s" "$TASKS_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "fix-k3s-2" ]
}

@test "slug_resolve_collision walks -2, -3, … until free" {
  : > "$TASKS_DIR/fix-k3s.json"
  : > "$TASKS_DIR/fix-k3s-2.json"
  : > "$TASKS_DIR/fix-k3s-3.json"
  run slug_resolve_collision "fix-k3s" "$TASKS_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "fix-k3s-4" ]
}

@test "slug_resolve_prefix echoes exact match" {
  : > "$TASKS_DIR/fix-k3s.json"
  : > "$TASKS_DIR/fix-k3s-etcd.json"
  run slug_resolve_prefix "fix-k3s" "$TASKS_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "fix-k3s" ]
}

@test "slug_resolve_prefix echoes unique prefix match" {
  : > "$TASKS_DIR/fix-k3s-etcd.json"
  run slug_resolve_prefix "fix-k3" "$TASKS_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "fix-k3s-etcd" ]
}

@test "slug_resolve_prefix fails with exit 1 on no match" {
  run slug_resolve_prefix "nope" "$TASKS_DIR"
  [ "$status" -eq 1 ]
}

@test "slug_resolve_prefix fails with exit 1 and lists candidates on ambiguous" {
  : > "$TASKS_DIR/fix-a.json"
  : > "$TASKS_DIR/fix-b.json"
  run --separate-stderr slug_resolve_prefix "fix" "$TASKS_DIR"
  [ "$status" -eq 1 ]
  # Candidates must land on stderr (the user-facing diagnostic stream),
  # not stdout — stdout is reserved for the resolved slug on success.
  [[ "$stderr" == *"fix-a"* ]]
  [[ "$stderr" == *"fix-b"* ]]
  [ -z "$output" ]
}

@test "slug_resolve_prefix emits candidates alphabetically on ambiguous" {
  : > "$TASKS_DIR/zebra-task.json"
  : > "$TASKS_DIR/alpha-task.json"
  : > "$TASKS_DIR/mango-task.json"
  run slug_resolve_prefix "" "$TASKS_DIR"   # empty prefix matches all
  [ "$status" -eq 1 ]
  # Find the alpha/mango/zebra lines in order (stderr merged into $output by default)
  local idx_a idx_m idx_z
  idx_a="$(printf '%s\n' "$output" | grep -n alpha-task | head -1 | cut -d: -f1)"
  idx_m="$(printf '%s\n' "$output" | grep -n mango-task | head -1 | cut -d: -f1)"
  idx_z="$(printf '%s\n' "$output" | grep -n zebra-task | head -1 | cut -d: -f1)"
  [ "$idx_a" -lt "$idx_m" ]
  [ "$idx_m" -lt "$idx_z" ]
}
