#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

load helper

setup() {
  jarvis_common_setup
  export JARVIS_TODAY="2026-04-19"
  source "$JARVIS_DIR/lib/state/profile.sh"
  source "$JARVIS_DIR/lib/state/lock.sh"
  source "$JARVIS_DIR/lib/state/json.sh"
  source "$JARVIS_DIR/lib/frontmatter.sh"
  source "$JARVIS_DIR/lib/note/resolve.sh"
  source "$JARVIS_DIR/lib/note/index.sh"
  source "$JARVIS_DIR/lib/note/store.sh"
  source "$JARVIS_DIR/lib/note/current.sh"
  state_ensure_tree
  note_store_new project "clift/perf" "Perf Investigation" >/dev/null
}
teardown() { jarvis_common_teardown; }

run_current() {
  local q="${CLIFT_POS_1:-}"
  env -i \
    HOME="$HOME" PATH="$PATH" \
    JARVIS_HOME="$JARVIS_HOME" JARVIS_PROFILE="$JARVIS_PROFILE" \
    JARVIS_TODAY="$JARVIS_TODAY" \
    CLI_DIR="$JARVIS_DIR" FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR" \
    CLIFT_POS_1="$q" \
    bash "$JARVIS_DIR/cmds/note/note.current.sh" "$@"
}

@test "current: set to title resolves to slug and persists" {
  CLIFT_POS_1="Perf Investigation" run run_current
  [ "$status" -eq 0 ]
  run note_current_read
  [ "$output" = "slug=project/clift/perf" ]
}

@test "current: set to slug shorthand works too" {
  CLIFT_POS_1="perf" run run_current
  [ "$status" -eq 0 ]
  run note_current_read
  [ "$output" = "slug=project/clift/perf" ]
}

@test "current: set to 'daily' keyword stored as kind=daily" {
  CLIFT_POS_1="daily" run run_current
  [ "$status" -eq 0 ]
  run note_current_read
  [ "$output" = "kind=daily" ]
}

@test "current: no-arg prints title + path of current" {
  note_current_write "slug=project/clift/perf"
  run run_current
  [ "$status" -eq 0 ]
  [[ "$output" == *"Perf Investigation"* ]]
  [[ "$output" == *"project/clift/perf"* ]]
}

@test "current: no-arg with daily keyword prints today's daily key" {
  note_current_write "kind=daily"
  run run_current
  [ "$status" -eq 0 ]
  [[ "$output" == *"daily/2026-04-19"* ]]
}

@test "current: no-arg, nothing set → 'none'" {
  run run_current
  [ "$status" -eq 0 ]
  [[ "$output" == *"none"* ]]
}

@test "current: --clear unsets" {
  note_current_write "slug=project/clift/perf"
  run run_current --clear
  [ "$status" -eq 0 ]
  run note_current_read
  [ -z "$output" ]
}

@test "current: --clear when nothing was set is a no-op" {
  run run_current --clear
  [ "$status" -eq 0 ]
  [ ! -f "$(note_root)/.current" ]
}

@test "current: unresolvable target → exit 1" {
  CLIFT_POS_1="nope" run --separate-stderr run_current
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"resolve"* || "$stderr" == *"not found"* ]]
}

@test "current: ambiguous target → exit 2" {
  note_store_new inbox foo "X" >/dev/null
  note_store_new ref foo "Y" >/dev/null
  CLIFT_POS_1="foo" run --separate-stderr run_current
  [ "$status" -eq 2 ]
}
