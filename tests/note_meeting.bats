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
  state_ensure_tree
}
teardown() { jarvis_common_teardown; }

run_meeting() {
  local title="${CLIFT_POS_1:-}"
  env -i \
    HOME="$HOME" PATH="$PATH" \
    JARVIS_HOME="$JARVIS_HOME" JARVIS_PROFILE="$JARVIS_PROFILE" \
    JARVIS_TODAY="$JARVIS_TODAY" \
    CLI_DIR="$JARVIS_DIR" FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR" \
    EDITOR="" \
    CLIFT_POS_1="$title" \
    bash "$JARVIS_DIR/cmds/note/note.meeting.sh" "$@"
}

@test "meeting: creates meeting/<slug>-<date>.md from meeting template" {
  CLIFT_POS_1="Design Review" run run_meeting --no-edit
  [ "$status" -eq 0 ]
  local f
  f="$(note_path meeting/design-review-2026-04-19)"
  [ -f "$f" ]
  # meeting template body landed.
  grep -q '## Agenda' "$f"
  [ "$(fm_get "$f" kind "")" = "meeting" ]
}

@test "meeting: 1on1 title prefers 1on1 template (and inherits its tags)" {
  CLIFT_POS_1="1on1 Alice" run run_meeting --no-edit
  [ "$status" -eq 0 ]
  local f
  f="$(note_path meeting/1on1-alice-2026-04-19)"
  [ -f "$f" ]
  # 1on1 template body landed (has "Their topics", not "Agenda").
  grep -q '## Their topics' "$f"
  ! grep -q '## Agenda' "$f"
  local tags
  tags="$(fm_parse "$f" | jq -r '.tags | sort | join(",")')"
  [[ "$tags" == *"1on1"* ]]
  [[ "$tags" == *"meeting"* ]]
}

@test "meeting without title → exit 2 with usage" {
  run --separate-stderr run_meeting --no-edit
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"usage"* ]]
}

@test "meeting collision resolves with -2 suffix" {
  CLIFT_POS_1="Design Review" run run_meeting --no-edit
  [ "$status" -eq 0 ]
  CLIFT_POS_1="Design Review" run run_meeting --no-edit
  [ "$status" -eq 0 ]
  [ -f "$(note_path meeting/design-review-2026-04-19)" ]
  [ -f "$(note_path meeting/design-review-2026-04-19-2)" ]
}
