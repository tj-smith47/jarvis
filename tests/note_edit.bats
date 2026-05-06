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
  source "$JARVIS_DIR/lib/note/current.sh"
  state_ensure_tree

  # Fake $EDITOR that appends a marker line. Bash so it has a portable
  # shebang on every platform our tests run on.
  FAKE_ED="$TEST_DIR/fake-ed.sh"
  cat > "$FAKE_ED" <<'EOF'
#!/usr/bin/env bash
printf '\n[edited by fake]\n' >> "$1"
EOF
  chmod +x "$FAKE_ED"
}
teardown() { jarvis_common_teardown; }

run_edit() {
  local q="${CLIFT_POS_1:-}"
  env -i \
    HOME="$HOME" PATH="$PATH" \
    JARVIS_HOME="$JARVIS_HOME" JARVIS_PROFILE="$JARVIS_PROFILE" \
    CLI_DIR="$JARVIS_DIR" FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR" \
    EDITOR="$FAKE_ED" \
    CLIFT_POS_1="$q" \
    bash "$JARVIS_DIR/cmds/note/note.edit.sh" "$@" </dev/null
}

@test "edit by slug invokes \$EDITOR and re-indexes" {
  note_store_new inbox foo "Foo" >/dev/null
  CLIFT_POS_1="foo" run run_edit
  [ "$status" -eq 0 ]
  grep -q '\[edited by fake\]' "$(note_path inbox/foo)"
}

@test "edit without arg uses current" {
  note_store_new inbox bar "Bar" >/dev/null
  note_current_write "slug=inbox/bar"
  run run_edit
  [ "$status" -eq 0 ]
  grep -q '\[edited by fake\]' "$(note_path inbox/bar)"
}

@test "edit without arg and no current → exit 2" {
  run --separate-stderr run_edit
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"current"* ]]
}

@test "edit with unknown slug → exit 1" {
  CLIFT_POS_1="nope" run --separate-stderr run_edit
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"not found"* ]]
}

@test "edit with no \$EDITOR set → exit 2" {
  note_store_new inbox foo "Foo" >/dev/null
  run --separate-stderr env -i \
    HOME="$HOME" PATH="$PATH" \
    JARVIS_HOME="$JARVIS_HOME" JARVIS_PROFILE="$JARVIS_PROFILE" \
    CLI_DIR="$JARVIS_DIR" FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR" \
    CLIFT_POS_1="foo" \
    bash "$JARVIS_DIR/cmds/note/note.edit.sh"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"EDITOR"* ]]
}
