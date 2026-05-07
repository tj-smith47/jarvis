#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

load helper

setup() {
  jarvis_common_setup
  command -v rg >/dev/null 2>&1 || skip "rg not installed"
  source "$JARVIS_DIR/lib/state/profile.sh"
  source "$JARVIS_DIR/lib/state/lock.sh"
  source "$JARVIS_DIR/lib/state/json.sh"
  source "$JARVIS_DIR/lib/frontmatter.sh"
  source "$JARVIS_DIR/lib/note/resolve.sh"
  source "$JARVIS_DIR/lib/note/index.sh"
  source "$JARVIS_DIR/lib/note/store.sh"
  state_ensure_tree
  note_store_new inbox a "A" --tags '["alpha"]' >/dev/null
  note_store_append inbox/a "need to audit the flock path" --no-timestamp
  note_store_new project "clift/perf" "Perf" --tags '["clift"]' >/dev/null
  note_store_append project/clift/perf "considered flock but went with mkdir locks" --no-timestamp
  note_store_new ref upper "Upper" --tags '["docs"]' >/dev/null
  note_store_append ref/upper "Flock semantics summary" --no-timestamp
}
teardown() { jarvis_common_teardown; }

run_search() {
  local q="${CLIFT_POS_1:-}"
  env -i \
    HOME="$HOME" PATH="$PATH" \
    JARVIS_HOME="$JARVIS_HOME" JARVIS_PROFILE="$JARVIS_PROFILE" \
    CLI_DIR="$JARVIS_DIR" FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR" \
    CLIFT_POS_1="$q" \
    bash "$JARVIS_DIR/cmds/note/note.search.sh" "$@"
}

@test "search: literal query hits both files" {
  CLIFT_POS_1="flock" run run_search
  [ "$status" -eq 0 ]
  [[ "$output" == *"audit the flock path"* ]]
  [[ "$output" == *"considered flock but"* ]]
}

@test "search: smart-case (lowercase query matches mixed-case body)" {
  CLIFT_POS_1="flock" run run_search
  [ "$status" -eq 0 ]
  [[ "$output" == *"Flock semantics"* ]]
}

@test "search --kind project: filters to project notes only" {
  CLIFT_POS_1="flock" run run_search --kind project
  [ "$status" -eq 0 ]
  [[ "$output" == *"mkdir locks"* ]]
  [[ "$output" != *"audit the flock"* ]]
  [[ "$output" != *"Flock semantics"* ]]
}

@test "search --tag clift: tag filter" {
  CLIFT_POS_1="flock" run run_search --tag clift
  [ "$status" -eq 0 ]
  [[ "$output" == *"mkdir locks"* ]]
  [[ "$output" != *"audit the flock"* ]]
}

@test "search without query → exit 2" {
  run --separate-stderr run_search
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"usage"* ]]
}

@test "search no matches → exit 0, empty stdout, friendly stderr" {
  CLIFT_POS_1="thisdefinitelydoesnotappear" run --separate-stderr run_search
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"no matches for: thisdefinitelydoesnotappear"* ]]
}

@test "search --regex enables regex (anchors work)" {
  CLIFT_POS_1='^Flock' run run_search --regex
  [ "$status" -eq 0 ]
  [[ "$output" == *"Flock semantics"* ]]
  # "considered flock" doesn't start the line → not matched.
  [[ "$output" != *"considered flock"* ]]
}
