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
  TPL_DIR="$JARVIS_DIR/templates"
}
teardown() { jarvis_common_teardown; }

@test "daily template declares timestamped short format" {
  local f="$TPL_DIR/daily.md"
  [ -f "$f" ]
  run fm_get "$f" "append.timestamp" ""
  [ "$output" = "true" ]
  run fm_get "$f" "append.format" ""
  [[ "$output" == *"%H:%M"* ]]
}

@test "meeting template disables append timestamp" {
  local f="$TPL_DIR/meeting.md"
  [ -f "$f" ]
  run fm_get "$f" "append.timestamp" ""
  [ "$output" = "false" ]
}

@test "1on1 template disables append timestamp" {
  run fm_get "$TPL_DIR/1on1.md" "append.timestamp" ""
  [ "$output" = "false" ]
}

@test "postmortem template uses default (timestamped) append" {
  local f="$TPL_DIR/postmortem.md"
  [ -f "$f" ]
  run fm_get "$f" "append.timestamp" "true"
  [ "$output" = "true" ]
}

@test "note_store_new with meeting template carries append.timestamp=false" {
  note_store_new meeting 1on1-alice-2026-04-18 "1on1 Alice" \
    --template "$TPL_DIR/meeting.md"
  local f
  f="$(note_path meeting/1on1-alice-2026-04-18)"
  run fm_get "$f" "append.timestamp" ""
  [ "$output" = "false" ]
}

@test "note_store_new pinned keys override template slug/kind" {
  note_store_new project "clift/demo" "Demo" \
    --template "$TPL_DIR/postmortem.md"
  local f
  f="$(note_path project/clift/demo)"
  run fm_get "$f" "slug" ""
  [ "$output" = "clift/demo" ]
  run fm_get "$f" "kind" ""
  [ "$output" = "project" ]
}

@test "note_store_new merges template tags with caller tags" {
  note_store_new project "clift/perf" "Perf" \
    --template "$TPL_DIR/postmortem.md" \
    --tags '["clift","perf"]'
  local f
  f="$(note_path project/clift/perf)"
  local tags
  tags="$(fm_parse "$f" | jq -r '.tags | sort | join(",")')"
  # postmortem.md ships with ["postmortem"]; union with caller ["clift","perf"]
  [[ "$tags" == *"postmortem"* ]]
  [[ "$tags" == *"clift"* ]]
  [[ "$tags" == *"perf"* ]]
}
