#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

load helper

setup() {
  jarvis_common_setup
  mkdir -p "$JARVIS_HOME/test/tasks"
}
teardown() { jarvis_common_teardown; }

seed() {
  local slug="$1"
  jq -n --arg slug "$slug" '
    {slug:$slug, desc:$slug, status:"open", priority:"med", due:null,
     project:"inbox", created_at:"2026-04-20T00:00:00Z",
     updated_at:"2026-04-20T00:00:00Z", done_at:null, seq:1, jira_key:null}
  ' > "$JARVIS_HOME/test/tasks/$slug.json"
}

run_remove() {
  FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR" \
  CLI_DIR="$JARVIS_DIR" \
  bash -c '
    set -euo pipefail
    declare -A CLIFT_FLAGS=()
    export CLIFT_POS_1="'"$1"'"
    source "$1"
  ' _ "$JARVIS_DIR/cmds/task/task.remove.sh"
}

@test "remove hard-deletes the slug file" {
  seed fix-k3s
  run run_remove fix-k3s
  [ "$status" -eq 0 ]
  [ ! -f "$JARVIS_HOME/test/tasks/fix-k3s.json" ]
}

@test "remove resolves unique prefix" {
  seed ship-vhs-demos
  run run_remove ship-vhs
  [ "$status" -eq 0 ]
  [ ! -f "$JARVIS_HOME/test/tasks/ship-vhs-demos.json" ]
}

@test "remove on unknown slug exits 1" {
  run run_remove nope
  [ "$status" -eq 1 ]
}

@test "remove without positional exits 2" {
  run run_remove ""
  [ "$status" -eq 2 ]
}

@test "remove cleans up lock and tmp sidecars" {
  seed fix-k3s
  : > "$JARVIS_HOME/test/tasks/fix-k3s.json.lock"
  : > "$JARVIS_HOME/test/tasks/fix-k3s.json.tmp.99"
  run run_remove fix-k3s
  [ "$status" -eq 0 ]
  [ ! -f "$JARVIS_HOME/test/tasks/fix-k3s.json.lock" ]
  [ -z "$(find "$JARVIS_HOME/test/tasks" -name 'fix-k3s.json.tmp.*' -print -quit)" ]
}
