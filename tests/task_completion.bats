#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

load helper

setup() {
  jarvis_common_setup
  mkdir -p "$JARVIS_HOME/test/tasks"
  printf '1\n' > "$JARVIS_HOME/test/state.version"
  source "$JARVIS_DIR/lib/state/profile.sh"
  source "$JARVIS_DIR/lib/state/lock.sh"
  source "$JARVIS_DIR/lib/state/json.sh"
  source "$JARVIS_DIR/lib/task/store.sh"
  source "$JARVIS_DIR/cmds/task/overrides/completion.sh"
}
teardown() { jarvis_common_teardown; }

seed() {
  local slug="$1" status="$2"
  local done_at='null'
  [[ "$status" == "done" ]] && done_at='"2026-04-20T00:00:00Z"'
  jq -n --arg slug "$slug" --arg status "$status" --argjson done_at "$done_at" '
    {slug:$slug, desc:$slug, status:$status, priority:"med", due:null,
     project:"inbox", created_at:"2026-04-20T00:00:00Z",
     updated_at:"2026-04-20T00:00:00Z", done_at:$done_at, seq:1, jira_key:null}
  ' > "$JARVIS_HOME/test/tasks/$slug.json"
}

@test "done pos1 completer lists only open slugs" {
  seed fix-k3s open
  seed ship-demos open
  seed old-task done
  run clift_complete_task_done_pos1 ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"fix-k3s"* ]]
  [[ "$output" == *"ship-demos"* ]]
  [[ "$output" != *"old-task"* ]]
}

@test "done pos1 completer filters by prefix" {
  seed fix-k3s open
  seed fix-etcd open
  seed ship-demos open
  run clift_complete_task_done_pos1 "fix"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fix-k3s"* ]]
  [[ "$output" == *"fix-etcd"* ]]
  [[ "$output" != *"ship-demos"* ]]
}

@test "edit pos1 completer lists all slugs (open + done)" {
  seed fix-k3s open
  seed old-task done
  run clift_complete_task_edit_pos1 ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"fix-k3s"* ]]
  [[ "$output" == *"old-task"* ]]
}

@test "remove pos1 completer lists all slugs (open + done)" {
  seed fix-k3s open
  seed old-task done
  run clift_complete_task_remove_pos1 ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"fix-k3s"* ]]
  [[ "$output" == *"old-task"* ]]
}

@test "completer emits empty output when no tasks" {
  run clift_complete_task_done_pos1 ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
