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

# Mirror note.add.sh's standalone-argv contract: command scripts parse
# raw argv when CLIFT_FLAGS isn't pre-populated. EDITOR is forced empty
# so --no-edit isn't load-bearing for tests that don't pass it.
run_new() {
  local title="${CLIFT_POS_1:-}"
  env -i \
    HOME="$HOME" PATH="$PATH" \
    JARVIS_HOME="$JARVIS_HOME" \
    JARVIS_PROFILE="$JARVIS_PROFILE" \
    CLI_DIR="$JARVIS_DIR" \
    FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR" \
    EDITOR="" \
    CLIFT_POS_1="$title" \
    bash "$JARVIS_DIR/cmds/note/note.new.sh" "$@"
}

@test "note new: kind=inbox default, no template; persists title in frontmatter" {
  CLIFT_POS_1="My Inbox Note" run run_new --no-edit
  [ "$status" -eq 0 ]
  local f
  f="$(note_path inbox/my-inbox-note)"
  [ -f "$f" ]
  [ "$(fm_get "$f" title "")" = "My Inbox Note" ]
  [ "$(fm_get "$f" kind "")" = "inbox" ]
  [ "$(fm_get "$f" slug "")" = "my-inbox-note" ]
}

@test "note new --kind ref applies the ref template body" {
  mkdir -p "$JARVIS_DIR/templates"
  cat > "$JARVIS_DIR/templates/ref.md" <<'EOF'
---
kind: ref
tags: [ref]
---
# Reference
EOF
  CLIFT_POS_1="Etcd Restore Runbook" run run_new --kind ref --no-edit
  [ "$status" -eq 0 ]
  local f
  f="$(note_path ref/etcd-restore-runbook)"
  [ -f "$f" ]
  grep -q '# Reference' "$f"
  rm -f "$JARVIS_DIR/templates/ref.md"
}

@test "note new without title exits 2 with usage" {
  run --separate-stderr run_new --no-edit
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"usage"* ]]
}

@test "note new with invalid --kind exits 2" {
  run --separate-stderr bash -c '
    CLIFT_POS_1="x" \
    JARVIS_HOME="'"$JARVIS_HOME"'" \
    JARVIS_PROFILE="'"$JARVIS_PROFILE"'" \
    CLI_DIR="'"$JARVIS_DIR"'" \
    FRAMEWORK_DIR="'"$CLIFT_FRAMEWORK_DIR"'" \
    EDITOR="" \
    bash "'"$JARVIS_DIR"'/cmds/note/note.new.sh" --kind bogus --no-edit
  '
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"--kind"* ]]
}

@test "note new --tag NAME populates frontmatter tags (list flag)" {
  CLIFT_POS_1="Thoughts" run run_new --no-edit --tag idea --tag infra
  [ "$status" -eq 0 ]
  local f
  f="$(note_path inbox/thoughts)"
  [ -f "$f" ]
  local tags
  tags="$(fm_parse "$f" | jq -r '.tags | sort | join(",")')"
  [[ "$tags" == *"idea"* ]]
  [[ "$tags" == *"infra"* ]]
}

@test "note new resolves slug collision with -2 suffix" {
  CLIFT_POS_1="Same Title" run run_new --no-edit
  [ "$status" -eq 0 ]
  CLIFT_POS_1="Same Title" run run_new --no-edit
  [ "$status" -eq 0 ]
  [ -f "$(note_path inbox/same-title)" ]
  [ -f "$(note_path inbox/same-title-2)" ]
}

@test "note new emits resolved <kind>/<slug> on stdout" {
  CLIFT_POS_1="Print Me" run run_new --no-edit
  [ "$status" -eq 0 ]
  # Last stdout line is the key (log_success now goes to stderr).
  [ "${lines[-1]}" = "inbox/print-me" ]
}

@test "note new title that normalizes to empty exits 2" {
  CLIFT_POS_1="---" run --separate-stderr run_new --no-edit
  [ "$status" -eq 2 ]
}

@test "note new updates the note index" {
  CLIFT_POS_1="Indexed" run run_new --no-edit
  [ "$status" -eq 0 ]
  # note_index_update writes a row keyed by kind/slug at the top level.
  local idx
  idx="$(note_root)/.index.json"
  [ -f "$idx" ]
  [ "$(jq -r '."inbox/indexed".title' "$idx")" = "Indexed" ]
}
