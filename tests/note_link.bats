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
  note_store_new inbox a "A" >/dev/null
  note_store_new inbox b "B" >/dev/null
}
teardown() { jarvis_common_teardown; }

run_link() {
  env -i \
    HOME="$HOME" PATH="$PATH" \
    JARVIS_HOME="$JARVIS_HOME" JARVIS_PROFILE="$JARVIS_PROFILE" \
    CLI_DIR="$JARVIS_DIR" FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR" \
    bash "$JARVIS_DIR/cmds/note/note.link.sh" "$@"
}

@test "link: bidirectional [[other]] cross-reference" {
  run run_link a b
  [ "$status" -eq 0 ]
  grep -qF '[[inbox/b]]' "$(note_path inbox/a)"
  grep -qF '[[inbox/a]]' "$(note_path inbox/b)"
}

@test "link: idempotent under repeat invocation" {
  run run_link a b
  [ "$status" -eq 0 ]
  run run_link a b
  [ "$status" -eq 0 ]
  local ca cb
  ca="$(grep -cF '[[inbox/b]]' "$(note_path inbox/a)")"
  cb="$(grep -cF '[[inbox/a]]' "$(note_path inbox/b)")"
  [ "$ca" = "1" ]
  [ "$cb" = "1" ]
}

@test "link: re-indexes both notes" {
  run run_link a b
  [ "$status" -eq 0 ]
  # Index timestamps should reflect the post-link mtime; both rows must exist.
  local idx
  idx="$(note_index_file)"
  [ -n "$(jq -r '."inbox/a".updated_at // empty' "$idx")" ]
  [ -n "$(jq -r '."inbox/b".updated_at // empty' "$idx")" ]
}

@test "link: missing second arg → exit 2" {
  run --separate-stderr run_link a
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"usage"* ]]
}

@test "link: missing both args → exit 2" {
  run --separate-stderr run_link
  [ "$status" -eq 2 ]
}

@test "link: unresolvable target → exit 1" {
  run --separate-stderr run_link a nope
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"not found"* ]]
}

@test "link: same note to itself → exit 2 (rejects self-link)" {
  run --separate-stderr run_link a a
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"self"* ]]
}
