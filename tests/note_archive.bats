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
  note_store_new inbox foo "Foo" --tags '["a"]' >/dev/null
}
teardown() { jarvis_common_teardown; }

run_archive() {
  env -i \
    HOME="$HOME" PATH="$PATH" \
    JARVIS_HOME="$JARVIS_HOME" JARVIS_PROFILE="$JARVIS_PROFILE" \
    CLI_DIR="$JARVIS_DIR" FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR" \
    bash "$JARVIS_DIR/cmds/note/note.archive.sh" "$@"
}

@test "archive: moves file and flips index row" {
  run run_archive foo
  [ "$status" -eq 0 ]
  [ ! -f "$(note_path inbox/foo)" ]
  [ -f "$(note_root)/archive/foo.md" ]
  local idx
  idx="$(note_index_file)"
  [ "$(jq -r '."archive/foo".archived' "$idx")" = "true" ]
  [ "$(jq -r '."archive/foo".kind' "$idx")" = "archive" ]
  [ "$(jq -r '."archive/foo".original_kind' "$idx")" = "inbox" ]
  # Old key is gone.
  [ "$(jq -r 'has("inbox/foo")' "$idx")" = "false" ]
}

@test "archive: collision suffix on repeat archive of same slug" {
  note_store_new inbox foo2 "Foo2" >/dev/null
  run run_archive foo
  [ "$status" -eq 0 ]
  # Re-create then archive again to land on archive/foo-2.md
  note_store_new inbox foo "Foo redux" >/dev/null
  run run_archive foo
  [ "$status" -eq 0 ]
  [ -f "$(note_root)/archive/foo.md" ]
  [ -f "$(note_root)/archive/foo-2.md" ]
}

@test "archive: emits new key on stdout" {
  run run_archive foo
  [ "$status" -eq 0 ]
  [[ "$output" == *"archive/foo"* ]]
}

@test "archive: unknown slug → exit 1" {
  run --separate-stderr run_archive nope
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"not found"* ]]
}

@test "archive: missing arg → exit 2" {
  run --separate-stderr run_archive
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"usage"* ]]
}
