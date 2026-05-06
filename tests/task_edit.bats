#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

load helper

setup() {
  jarvis_common_setup
  mkdir -p "$JARVIS_HOME/test/tasks"
  printf '1\n' > "$JARVIS_HOME/test/state.version"
}
teardown() { jarvis_common_teardown; }

seed() {
  local slug="$1"
  jq -n --arg slug "$slug" '
    {slug:$slug, desc:"original", status:"open", priority:"med", due:"today",
     project:"inbox", created_at:"2026-04-20T00:00:00Z",
     updated_at:"2026-04-20T00:00:00Z", done_at:null, seq:1, jira_key:null}
  ' > "$JARVIS_HOME/test/tasks/$slug.json"
}

run_edit() {
  local slug="$1"; shift
  local desc="${1:-}"; shift || true
  local pri="${1:-}"; shift || true
  local due="${1:-}"; shift || true
  local project="${1:-}"; shift || true
  FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR" \
  CLI_DIR="$JARVIS_DIR" \
  bash -c '
    set -euo pipefail
    declare -A CLIFT_FLAGS=(
      [desc]="'"$desc"'"
      [priority]="'"$pri"'"
      [due]="'"$due"'"
      [project]="'"$project"'"
    )
    export CLIFT_POS_1="'"$slug"'"
    source "$1"
  ' _ "$JARVIS_DIR/cmds/task/task.edit.sh"
}

@test "edit --priority mutates priority and bumps updated_at" {
  seed fix-k3s
  sleep 1
  run run_edit fix-k3s "" high
  [ "$status" -eq 0 ]
  [ "$(jq -r '.priority' "$JARVIS_HOME/test/tasks/fix-k3s.json")" = "high" ]
  [ "$(jq -r '.created_at != .updated_at' "$JARVIS_HOME/test/tasks/fix-k3s.json")" = "true" ]
}

@test "edit --desc mutates description" {
  seed fix-k3s
  run run_edit fix-k3s "rephrased description"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.desc' "$JARVIS_HOME/test/tasks/fix-k3s.json")" = "rephrased description" ]
}

@test "edit --due YYYY-MM-DD sets due" {
  seed fix-k3s
  run run_edit fix-k3s "" "" "2026-06-01"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.due' "$JARVIS_HOME/test/tasks/fix-k3s.json")" = "2026-06-01" ]
}

@test "edit --due clear nulls due" {
  seed fix-k3s
  run run_edit fix-k3s "" "" clear
  [ "$status" -eq 0 ]
  [ "$(jq -r '.due' "$JARVIS_HOME/test/tasks/fix-k3s.json")" = "null" ]
}

@test "edit --project mutates project" {
  seed fix-k3s
  run run_edit fix-k3s "" "" "" release
  [ "$status" -eq 0 ]
  [ "$(jq -r '.project' "$JARVIS_HOME/test/tasks/fix-k3s.json")" = "release" ]
}

@test "edit resolves unique prefix" {
  seed fix-k3s-etcd
  run run_edit fix-k "" high
  [ "$status" -eq 0 ]
  [ "$(jq -r '.priority' "$JARVIS_HOME/test/tasks/fix-k3s-etcd.json")" = "high" ]
}

@test "edit with no flags exits 2" {
  seed fix-k3s
  run run_edit fix-k3s
  [ "$status" -eq 2 ]
}

@test "edit with invalid --priority exits 2" {
  seed fix-k3s
  run run_edit fix-k3s "" urgent
  [ "$status" -eq 2 ]
}

@test "edit with invalid --due exits 2" {
  seed fix-k3s
  run run_edit fix-k3s "" "" "someday"
  [ "$status" -eq 2 ]
}

@test "edit on unknown slug exits 1" {
  run run_edit nope "" high
  [ "$status" -eq 1 ]
}
