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

@test "note_store_new creates file with merged frontmatter + empty body" {
  run note_store_new inbox audit-flock "Audit Flock Path"
  [ "$status" -eq 0 ]
  [ "$output" = "inbox/audit-flock" ]
  local f="$(note_path inbox/audit-flock)"
  [ -f "$f" ]
  run fm_get "$f" "title" ""
  [ "$output" = "Audit Flock Path" ]
  run fm_get "$f" "kind" ""
  [ "$output" = "inbox" ]
  run fm_get "$f" "slug" ""
  [ "$output" = "audit-flock" ]
}

@test "note_store_new with --tags merges into frontmatter" {
  note_store_new ref etcd-restore "Etcd Restore" --tags '["k3s","runbook"]'
  local f="$(note_path ref/etcd-restore)"
  run fm_get "$f" "tags.0" ""
  [ "$output" = "k3s" ]
}

@test "note_store_append writes timestamped tail by default" {
  note_store_new inbox foo "Foo"
  note_store_append inbox/foo "line one"
  local f="$(note_path inbox/foo)"
  grep -q '^## ' "$f"
  grep -q 'line one' "$f"
}

@test "note_store_append --no-timestamp skips the header" {
  note_store_new inbox bar "Bar"
  note_store_append inbox/bar "plain text" --no-timestamp
  local f="$(note_path inbox/bar)"
  grep -q 'plain text' "$f"
  ! grep -q '^## 20' "$f"
}

@test "note_store_append honors frontmatter append.timestamp = false" {
  note_store_new inbox baz "Baz"
  local f="$(note_path inbox/baz)"
  fm_set "$f" "append.timestamp" "false"
  note_store_append inbox/baz "body only"
  ! grep -q '^## 20' "$f"
}

@test "note_store_archive moves file and flips archived flag in index" {
  note_store_new inbox to-archive "To Archive"
  note_store_archive inbox/to-archive
  [ ! -f "$(note_path inbox/to-archive)" ]
  [ -f "$(note_root)/archive/to-archive.md" ]
  local idx="$(note_index_file)"
  run jq -r '."archive/to-archive".archived' "$idx"
  [ "$output" = "true" ]
  run jq -r '."archive/to-archive".original_kind' "$idx"
  [ "$output" = "inbox" ]
}

@test "note_store_delete removes file and index row" {
  note_store_new inbox goner "Goner"
  note_store_delete inbox/goner
  [ ! -f "$(note_path inbox/goner)" ]
  local idx="$(note_index_file)"
  run jq -r '."inbox/goner" // "absent"' "$idx"
  [ "$output" = "absent" ]
}

@test "note_store_new errors on slug collision" {
  note_store_new inbox dup "First"
  run --separate-stderr note_store_new inbox dup "Second"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"already exists"* ]]
  # First note's title preserved.
  run fm_get "$(note_path inbox/dup)" "title" ""
  [ "$output" = "First" ]
}

@test "note_store_new is atomic under concurrent launch" {
  # Launch 4 workers racing to create distinct slugs. All 4 must win — this
  # confirms the atomic path doesn't spuriously reject non-colliding writers
  # (no shared-locks regression).
  local i pids=()
  for i in 1 2 3 4; do
    ( note_store_new inbox "race-$i" "race $i" ) >/dev/null 2>&1 &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || true
  done
  local n
  n="$(ls "$(note_root)/inbox"/race-*.md 2>/dev/null | wc -l)"
  [ "$n" -eq 4 ]
}

@test "note_store_new atomically rejects exact collision" {
  # Launch 4 workers ALL trying the same key. Exactly 1 wins (rc=0), 3 fail
  # (rc=1). The ln(2) EEXIST path guarantees this under the kernel.
  #
  # `wait $pid` propagates the child's exit code; under bats's set -e a
  # non-zero child aborts the test before we can tally winners/losers.
  # Guard each wait with `|| true` — the rc files are the source of truth.
  #
  # The rc files are written from backgrounded subshells. bats tweaks the
  # child shell's error handling in ways that caused the rc files to not
  # land when the note_store_new call returned non-zero (set -e + pipe
  # handling inside `run` harness). Using an explicit `{ …; } 2>/dev/null`
  # + sequenced command list with explicit rc capture avoids that.
  local i rc
  local tmpdir="$TEST_DIR"
  for i in 1 2 3 4; do
    # Disable set -e inside each backgrounded subshell so a failing
    # note_store_new doesn't abort before the rc capture line runs. The
    # rc files are the atomic-path evidence.
    ( set +e
      note_store_new inbox dup "dup $i" >/dev/null 2>&1
      echo "$?" > "$tmpdir/rc.$i"
    ) &
  done
  wait 2>/dev/null || true
  local winners=0 losers=0
  for i in 1 2 3 4; do
    [[ -f "$tmpdir/rc.$i" ]] || { echo "missing rc.$i" >&2; ls "$tmpdir" >&2; return 1; }
    rc="$(<"$tmpdir/rc.$i")"
    (( rc == 0 )) && winners=$((winners+1))
    (( rc == 1 )) && losers=$((losers+1))
  done
  [ "$winners" -eq 1 ]
  [ "$losers" -eq 3 ]
  [ -f "$(note_path inbox/dup)" ]
}
