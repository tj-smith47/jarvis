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
}
teardown() { jarvis_common_teardown; }

# Invoke note.add.sh as a fresh bash subprocess so that a) CLIFT_FLAGS is
# re-initialised cleanly per call, and b) we can pass through the positional
# body + optional --* argv. note.add.sh has a standalone-argv fallback that
# populates CLIFT_FLAGS/CLIFT_FLAG_TAG_* when invoked without the router.
run_add() {
  local body="${CLIFT_POS_1:-}"
  env -i \
    HOME="$HOME" PATH="$PATH" \
    JARVIS_HOME="$JARVIS_HOME" \
    JARVIS_PROFILE="$JARVIS_PROFILE" \
    CLI_DIR="$JARVIS_DIR" \
    FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR" \
    CLIFT_POS_1="$body" \
    bash "$JARVIS_DIR/cmds/note/note.add.sh" "$@"
}

@test "note <body>: no current → creates inbox/<slug> file" {
  CLIFT_POS_1="need to audit flock path" run run_add
  [ "$status" -eq 0 ]
  [ -f "$(note_path inbox/need-to-audit-flock-path)" ]
}

@test "note <body>: with current=slug → appends to target" {
  note_store_new inbox perf "Perf"
  note_current_write "slug=inbox/perf"
  CLIFT_POS_1="another thought" run run_add
  [ "$status" -eq 0 ]
  grep -q 'another thought' "$(note_path inbox/perf)"
  [ ! -f "$(note_path inbox/another-thought)" ]
}

@test "note <body>: with current=daily → appends to today's daily, creating if missing" {
  note_current_write "kind=daily"
  CLIFT_POS_1="first entry" run run_add
  [ "$status" -eq 0 ]
  local today daily
  today="$(date +%F)"
  daily="$(note_path "daily/$today")"
  [ -f "$daily" ]
  grep -q 'first entry' "$daily"
}

@test "note <body> --on TARGET appends without changing current" {
  note_store_new inbox alpha "Alpha"
  CLIFT_POS_1="stray idea" run run_add --on inbox/alpha
  [ "$status" -eq 0 ]
  grep -q 'stray idea' "$(note_path inbox/alpha)"
  run note_current_read
  [ -z "$output" ]
}

@test "note <body> --on with missing target → creates inbox/<slug-of-title>" {
  CLIFT_POS_1="quick capture" run run_add --on "Ghost Note"
  [ "$status" -eq 0 ]
  [ -f "$(note_path inbox/ghost-note)" ]
}

@test "note <body> --on with missing target creates AND appends the body" {
  CLIFT_POS_1="quick capture" run run_add --on "Ghost Note"
  [ "$status" -eq 0 ]
  local f
  f="$(note_path inbox/ghost-note)"
  [ -f "$f" ]
  grep -q 'quick capture' "$f"
}

@test "note <body> --on ambiguous → exit 2, doesn't create" {
  note_store_new inbox perf-one "Perf One"
  note_store_new inbox perf-two "Perf Two"
  CLIFT_POS_1="x" run run_add --on "perf"
  [ "$status" -eq 2 ]
  [[ "$stderr$output" == *"ambiguous"* ]]
  [ ! -f "$(note_path inbox/perf)" ]
}

@test "note <body> --on overrides current without mutating current state" {
  note_current_write "kind=daily"
  note_store_new inbox alpha "Alpha"
  CLIFT_POS_1="override test" run run_add --on inbox/alpha
  [ "$status" -eq 0 ]
  grep -q 'override test' "$(note_path inbox/alpha)"
  [ ! -f "$(note_path "daily/$(date +%F)")" ]
  run note_current_read
  [ "$output" = "kind=daily" ]
}

@test "note <body>: malformed current state → exit 1" {
  note_current_write "junk_line"
  CLIFT_POS_1="x" run run_add
  [ "$status" -eq 1 ]
}

@test "note <body>: current=slug pointing to deleted note → exit 1" {
  note_current_write "slug=inbox/deleted"
  CLIFT_POS_1="x" run run_add
  [ "$status" -eq 1 ]
}

@test "note <body>: quick-capture with existing slug yields -2 suffix" {
  # With inbox/race-test already on disk, a fresh quick-capture of the same
  # body must mint inbox/race-test-2 rather than colliding or overwriting.
  # (Real concurrency coverage lives in jarvis_note_store.bats — this test
  # pins the caller-side retry-loop behavior only.)
  note_store_new inbox "race-test" "race test"
  CLIFT_POS_1="race test" run run_add
  [ "$status" -eq 0 ]
  # First note intact.
  [ -f "$(note_path inbox/race-test)" ]
  # Second call got a fresh slug (-2 suffix).
  [ -f "$(note_path inbox/race-test-2)" ]
}

@test "note <body> without body → exit 2" {
  run run_add
  [ "$status" -eq 2 ]
}

@test "note <body> --tag FOO --tag BAR attaches tags on create" {
  CLIFT_POS_1="tagged thought" run run_add --tag arch --tag queue
  [ "$status" -eq 0 ]
  local f
  f="$(note_path inbox/tagged-thought)"
  [ -f "$f" ]
  local tags
  tags="$(fm_parse "$f" | jq -r '.tags | sort | join(",")')"
  [[ "$tags" == *"arch"* && "$tags" == *"queue"* ]]
}

@test "note <body> --no-timestamp on append skips header" {
  note_store_new inbox plain "Plain"
  note_current_write "slug=inbox/plain"
  CLIFT_POS_1="body only" run run_add --no-timestamp
  [ "$status" -eq 0 ]
  ! grep -q '^## 20' "$(note_path inbox/plain)"
  grep -q 'body only' "$(note_path inbox/plain)"
}
