#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

load helper

setup() {
  jarvis_common_setup
  source "$JARVIS_DIR/lib/state/profile.sh"
  source "$JARVIS_DIR/lib/state/lock.sh"
  source "$JARVIS_DIR/lib/state/json.sh"
  source "$JARVIS_DIR/lib/frontmatter.sh"
  source "$JARVIS_DIR/lib/note/resolve.sh"
  source "$JARVIS_DIR/lib/note/index.sh"
  source "$JARVIS_DIR/lib/note/store.sh"
  state_ensure_tree
  note_store_new inbox audit "Audit Flock" --tags '["arch"]' >/dev/null
  note_store_new ref etcd "Etcd Runbook" --tags '["k3s"]' >/dev/null
  note_store_new project "clift/perf" "Perf Investigation" --tags '["clift","perf"]' >/dev/null
}
teardown() { jarvis_common_teardown; }

run_list() {
  env -i \
    HOME="$HOME" PATH="$PATH" \
    JARVIS_HOME="$JARVIS_HOME" JARVIS_PROFILE="$JARVIS_PROFILE" \
    CLI_DIR="$JARVIS_DIR" FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR" \
    PAGER=cat \
    bash "$JARVIS_DIR/cmds/note/note.list.sh" "$@"
}

@test "list: groups by kind; shows titles" {
  run run_list
  [ "$status" -eq 0 ]
  [[ "$output" == *"INBOX"* ]]
  [[ "$output" == *"REF"* ]]
  [[ "$output" == *"PROJECT"* ]]
  [[ "$output" == *"Audit Flock"* ]]
  [[ "$output" == *"Etcd Runbook"* ]]
  [[ "$output" == *"Perf Investigation"* ]]
}

@test "list --kind ref filters to a single kind" {
  run run_list --kind ref
  [ "$status" -eq 0 ]
  [[ "$output" == *"Etcd Runbook"* ]]
  [[ "$output" != *"Audit Flock"* ]]
  [[ "$output" != *"Perf Investigation"* ]]
}

@test "list --tag clift filters by tag" {
  run run_list --tag clift
  [ "$status" -eq 0 ]
  [[ "$output" == *"Perf Investigation"* ]]
  [[ "$output" != *"Audit Flock"* ]]
  [[ "$output" != *"Etcd Runbook"* ]]
}

@test "list --json emits a JSON array" {
  run run_list --json
  [ "$status" -eq 0 ]
  run jq '. | length' <<< "$output"
  [ "$output" = "3" ]
}

@test "list --archived: archived rows hidden by default, shown with flag" {
  note_store_archive inbox/audit >/dev/null

  run run_list
  [ "$status" -eq 0 ]
  [[ "$output" != *"Audit Flock"* ]]

  run run_list --archived
  [ "$status" -eq 0 ]
  [[ "$output" == *"Audit Flock"* ]]
}

@test "list --limit 1 truncates" {
  run run_list --json --limit 1
  [ "$status" -eq 0 ]
  run jq '. | length' <<< "$output"
  [ "$output" = "1" ]
}

@test "list: no matches → friendly message (non-JSON)" {
  run run_list --kind daily
  [ "$status" -eq 0 ]
  [[ "$output" == *"no notes"* ]]
}

@test "list --json with no matches → []" {
  run run_list --json --kind daily
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}
