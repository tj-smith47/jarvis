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
}
teardown() { jarvis_common_teardown; }

run_project() {
  local spec="${CLIFT_POS_1:-}"
  env -i \
    HOME="$HOME" PATH="$PATH" \
    JARVIS_HOME="$JARVIS_HOME" JARVIS_PROFILE="$JARVIS_PROFILE" \
    CLI_DIR="$JARVIS_DIR" FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR" \
    EDITOR="" \
    CLIFT_POS_1="$spec" \
    bash "$JARVIS_DIR/cmds/note/note.project.sh" "$@"
}

@test "project: <proj>/<title> creates nested file" {
  CLIFT_POS_1="clift/Perf Investigation" run run_project --no-edit
  [ "$status" -eq 0 ]
  local f
  f="$(note_path project/clift/perf-investigation)"
  [ -f "$f" ]
  [ "$(fm_get "$f" kind "")" = "project" ]
  [ "$(fm_get "$f" title "")" = "Perf Investigation" ]
}

@test "project: missing proj/ prefix → exit 2" {
  CLIFT_POS_1="plainthing" run --separate-stderr run_project --no-edit
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"<proj>/<title>"* ]]
}

@test "project: empty title (proj only with trailing slash) → exit 2" {
  CLIFT_POS_1="clift/" run --separate-stderr run_project --no-edit
  [ "$status" -eq 2 ]
}

@test "project: empty input → exit 2 with usage" {
  run --separate-stderr run_project --no-edit
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"usage"* ]]
}

@test "project: indexes the new note" {
  CLIFT_POS_1="clift/Perf Investigation" run run_project --no-edit
  [ "$status" -eq 0 ]
  local idx
  idx="$(note_root)/.index.json"
  [ -f "$idx" ]
  [ "$(jq -r '."project/clift/perf-investigation".kind' "$idx")" = "project" ]
}
