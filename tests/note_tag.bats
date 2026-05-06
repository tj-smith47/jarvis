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

run_tag() {
  env -i \
    HOME="$HOME" PATH="$PATH" \
    JARVIS_HOME="$JARVIS_HOME" JARVIS_PROFILE="$JARVIS_PROFILE" \
    CLI_DIR="$JARVIS_DIR" FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR" \
    bash "$JARVIS_DIR/cmds/note/note.tag.sh" "$@"
}

read_tags() {
  fm_parse "$1" | jq -r '.tags // [] | sort | join(",")'
}

@test "tag: +b adds" {
  run run_tag foo +b
  [ "$status" -eq 0 ]
  [ "$(read_tags "$(note_path inbox/foo)")" = "a,b" ]
}

@test "tag: -a removes" {
  run run_tag foo -a
  [ "$status" -eq 0 ]
  [ "$(read_tags "$(note_path inbox/foo)")" = "" ]
}

@test "tag: combined +b -a in one call" {
  run run_tag foo +b -a
  [ "$status" -eq 0 ]
  [ "$(read_tags "$(note_path inbox/foo)")" = "b" ]
}

@test "tag: idempotent +a (already present)" {
  run run_tag foo +a
  [ "$status" -eq 0 ]
  [ "$(read_tags "$(note_path inbox/foo)")" = "a" ]
}

@test "tag: index reflects new tags after mutation" {
  run run_tag foo +k3s
  [ "$status" -eq 0 ]
  run jq -r '."inbox/foo".tags | sort | join(",")' "$(note_index_file)"
  [[ "$output" == *"k3s"* ]]
}

@test "tag: bare op without +/- prefix → exit 2" {
  run --separate-stderr run_tag foo plain
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"+tag"* ]]
}

@test "tag: missing slug → exit 2" {
  run --separate-stderr run_tag
  [ "$status" -eq 2 ]
}

@test "tag: missing ops → exit 2" {
  run --separate-stderr run_tag foo
  [ "$status" -eq 2 ]
}

@test "tag: unknown slug → exit 1" {
  run --separate-stderr run_tag nope +b
  [ "$status" -eq 1 ]
}

@test "tag: append concurrent with tag mutation does not lose body" {
  # Sanity for the lock contract — if note tag rewrites the file via
  # atomic rename without holding the same lock note_store_append uses,
  # an in-flight append could be silently dropped. We can't reliably
  # race from bats, but we can check that tag preserves an existing
  # body that was put there by a prior append.
  note_store_append inbox/foo "important body line" --no-timestamp
  run run_tag foo +new
  [ "$status" -eq 0 ]
  grep -q 'important body line' "$(note_path inbox/foo)"
}
