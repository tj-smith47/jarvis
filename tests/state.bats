#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

load helper

# jarvis_state.bats — coverage for the jarvis-state Go helper.

STATE=
GOLDEN_DIR=
INPUTS_DIR=
HOME_DIR=

setup() {
  # Pre-build BEFORE HOME redirect so go can find its toolchain.
  JARVIS_DIR="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  STATE="$JARVIS_DIR/bin/jarvis-state"
  GOLDEN_DIR="$JARVIS_DIR/tests/fixtures/ndjson-parity/golden"
  INPUTS_DIR="$JARVIS_DIR/tests/fixtures/ndjson-parity/inputs"
  if [[ ! -x "$STATE" ]]; then
    bash "$JARVIS_DIR/scripts/build_state.sh"
  fi
  jarvis_common_setup
  HOME_DIR="$BATS_TEST_TMPDIR/jarvis-home"
  mkdir -p "$HOME_DIR/test"
  export JARVIS_HOME="$HOME_DIR" JARVIS_PROFILE=test
}

teardown() {
  jarvis_common_teardown
  unset JARVIS_HOME JARVIS_PROFILE JARVIS_FAKE_NOW JARVIS_TODAY
}

# ---------- Protocol --------------------------------------------------------

@test "jarvis-state --protocol-version prints 1" {
  run "$STATE" --protocol-version
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "jarvis-state with no args prints usage" {
  run "$STATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Subcommands"* ]]
}

@test "jarvis-state unknown subcommand exits 2" {
  run "$STATE" frobnicate
  [ "$status" -eq 2 ]
}

# ---------- emit-fixtures-for-parity ---------------------------------------

@test "emit-fixtures-for-parity: byte-identical to Python oracle (50 fixtures)" {
  out_dir="$BATS_TEST_TMPDIR/state-parity"
  run "$STATE" emit-fixtures-for-parity --inputs "$INPUTS_DIR" --output "$out_dir"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run diff -r "$GOLDEN_DIR" "$out_dir"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "emit-fixtures-for-parity: missing inputs dir exits 2" {
  run "$STATE" emit-fixtures-for-parity --inputs /nonexistent --output "$BATS_TEST_TMPDIR/x"
  [ "$status" -eq 2 ]
}

# ---------- slug normalize -------------------------------------------------

@test "slug normalize basic ASCII" {
  run "$STATE" slug normalize "Fix the etcd restore bug"
  [ "$status" -eq 0 ]
  [ "$output" = "fix-the-etcd-restore-bug" ]
}

@test "slug normalize collapses non-alnum runs" {
  run "$STATE" slug normalize "  Hello, World !! 2026-04-28  "
  [ "$status" -eq 0 ]
  [ "$output" = "hello-world-2026-04-28" ]
}

@test "slug normalize empty input exits 2" {
  run "$STATE" slug normalize ""
  [ "$status" -eq 2 ]
}

@test "slug normalize takes only the first line" {
  run "$STATE" slug normalize "First line
ignored second"
  [ "$status" -eq 0 ]
  [ "$output" = "first-line" ]
}

@test "slug normalize caps at 100 chars" {
  longstr=""
  for i in $(seq 1 60); do longstr+="abc "; done   # ~240 chars
  run "$STATE" slug normalize "$longstr"
  [ "$status" -eq 0 ]
  [ "${#output}" -le 100 ]
}

@test "slug normalize --collision-dir appends -2 when target exists" {
  mkdir -p "$BATS_TEST_TMPDIR/coll"
  : > "$BATS_TEST_TMPDIR/coll/foo.json"
  run "$STATE" slug normalize "Foo" --collision-dir "$BATS_TEST_TMPDIR/coll" --ext json
  [ "$status" -eq 0 ]
  [ "$output" = "foo-2" ]
}

# ---------- frontmatter ----------------------------------------------------

@test "frontmatter parse: extracts YAML to compact JSON" {
  cat > "$BATS_TEST_TMPDIR/n.md" <<'EOF'
---
title: T
slug: t
kind: inbox
tags: [a, b]
archived: false
---

body
EOF
  run "$STATE" frontmatter parse "$BATS_TEST_TMPDIR/n.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"title":"T"'* ]]
  [[ "$output" == *'"tags":["a","b"]'* ]]
  [[ "$output" == *'"archived":false'* ]]
}

@test "frontmatter parse: file with no frontmatter emits {}" {
  printf 'just body\n' > "$BATS_TEST_TMPDIR/plain.md"
  run "$STATE" frontmatter parse "$BATS_TEST_TMPDIR/plain.md"
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
}

@test "frontmatter parse: malformed YAML exits 3" {
  cat > "$BATS_TEST_TMPDIR/bad.md" <<'EOF'
---
title: [unclosed
---

body
EOF
  run "$STATE" frontmatter parse "$BATS_TEST_TMPDIR/bad.md"
  [ "$status" -eq 3 ]
}

@test "frontmatter parse: missing file exits 1" {
  run "$STATE" frontmatter parse /nonexistent/path.md
  [ "$status" -eq 1 ]
}

@test "frontmatter emit: JSON object on stdin -> ---yaml---" {
  run bash -c "echo '{\"title\":\"x\",\"slug\":\"y\"}' | '$STATE' frontmatter emit"
  [ "$status" -eq 0 ]
  [[ "$output" == *"---"* ]]
  [[ "$output" == *"title: x"* ]]
}

@test "frontmatter set: in-place mutate preserves body trailing newline" {
  cat > "$BATS_TEST_TMPDIR/n.md" <<'EOF'
---
title: T
---

body line 1
body line 2
EOF
  run "$STATE" frontmatter set "$BATS_TEST_TMPDIR/n.md" title NewTitle
  [ "$status" -eq 0 ]
  grep -q 'NewTitle' "$BATS_TEST_TMPDIR/n.md"
  grep -q 'body line 2' "$BATS_TEST_TMPDIR/n.md"
  # Body preservation: file must end in a newline. $(...) strips trailing
  # newlines, so a non-empty result means the last byte was NOT a newline.
  [ -z "$(tail -c1 "$BATS_TEST_TMPDIR/n.md")" ]
}

@test "frontmatter set: bool/int auto-typing" {
  cat > "$BATS_TEST_TMPDIR/n.md" <<'EOF'
---
title: T
---
body
EOF
  run "$STATE" frontmatter set "$BATS_TEST_TMPDIR/n.md" archived true
  [ "$status" -eq 0 ]
  run "$STATE" frontmatter set "$BATS_TEST_TMPDIR/n.md" count 42
  [ "$status" -eq 0 ]
  # archived is an actual yaml bool, count is an int — yaml renders without quotes.
  grep -q '^archived: true' "$BATS_TEST_TMPDIR/n.md"
  grep -q '^count: 42' "$BATS_TEST_TMPDIR/n.md"
}

# ---------- note index ------------------------------------------------------

@test "note index update + rebuild: round-trip a single note" {
  notes_dir="$JARVIS_HOME/$JARVIS_PROFILE/notes/inbox"
  mkdir -p "$notes_dir"
  cat > "$notes_dir/test.md" <<'EOF'
---
title: Test
slug: test
kind: inbox
tags: [foo, bar]
---

body
EOF
  run "$STATE" note index update inbox/test
  [ "$status" -eq 0 ]
  idx="$JARVIS_HOME/$JARVIS_PROFILE/notes/.index.json"
  [ -f "$idx" ]
  jq -e '."inbox/test".kind == "inbox"' "$idx" >/dev/null
  jq -e '."inbox/test".tags == ["foo","bar"]' "$idx" >/dev/null
}

@test "note index rebuild: scans every .md file" {
  notes_root="$JARVIS_HOME/$JARVIS_PROFILE/notes"
  mkdir -p "$notes_root/inbox" "$notes_root/daily"
  for slug in a b c; do
    cat > "$notes_root/inbox/$slug.md" <<EOF
---
title: $slug
kind: inbox
tags: []
---
body
EOF
  done
  cat > "$notes_root/daily/2026-04-28.md" <<'EOF'
---
title: Daily
kind: daily
tags: []
---
body
EOF
  run "$STATE" note index rebuild
  [ "$status" -eq 0 ]
  idx="$notes_root/.index.json"
  [ "$(jq 'keys | length' "$idx")" -eq 4 ]
  jq -e '."daily/2026-04-28".kind == "daily"' "$idx" >/dev/null
}

@test "note index batch: keys on stdin update under one flock" {
  notes_root="$JARVIS_HOME/$JARVIS_PROFILE/notes"
  mkdir -p "$notes_root/inbox"
  for slug in a b c; do
    cat > "$notes_root/inbox/$slug.md" <<EOF
---
title: $slug
kind: inbox
tags: []
---
body
EOF
  done
  run bash -c "printf 'inbox/a\ninbox/b\ninbox/c\n' | '$STATE' note index batch"
  [ "$status" -eq 0 ]
  idx="$notes_root/.index.json"
  [ "$(jq 'keys | length' "$idx")" -eq 3 ]
}

@test "note resolve: bare slug picks unique kind/slug" {
  notes_root="$JARVIS_HOME/$JARVIS_PROFILE/notes"
  mkdir -p "$notes_root/inbox" "$notes_root/ref"
  cat > "$notes_root/inbox/foo.md" <<'EOF'
---
title: F
kind: inbox
---
body
EOF
  "$STATE" note index rebuild
  run "$STATE" note resolve foo
  [ "$status" -eq 0 ]
  [ "$output" = "inbox/foo" ]
}

@test "note resolve: ambiguous bare slug exits 1 with candidates" {
  notes_root="$JARVIS_HOME/$JARVIS_PROFILE/notes"
  mkdir -p "$notes_root/inbox" "$notes_root/ref"
  for d in inbox ref; do
    cat > "$notes_root/$d/dup.md" <<EOF
---
title: D
kind: $d
---
body
EOF
  done
  "$STATE" note index rebuild
  run "$STATE" note resolve dup
  [ "$status" -eq 1 ]
}

# ---------- task -----------------------------------------------------------

@test "task add + list: round-trip via slug" {
  export JARVIS_FAKE_NOW="2026-04-28T12:00:00Z"
  run "$STATE" task add "Buy milk" --priority high --due 2026-04-30
  [ "$status" -eq 0 ]
  [ "$output" = "buy-milk" ]
  run "$STATE" task list
  [ "$status" -eq 0 ]
  [[ "$output" == *'"slug":"buy-milk"'* ]]
  [[ "$output" == *'"priority":"high"'* ]]
  [[ "$output" == *'"due":"2026-04-30"'* ]]
}

@test "task done: marks status + sets done_at" {
  export JARVIS_FAKE_NOW="2026-04-28T12:00:00Z"
  "$STATE" task add "Pay bills" >/dev/null
  run "$STATE" task done pay-bills
  [ "$status" -eq 0 ]
  run "$STATE" task list --filter status=done
  [ "$status" -eq 0 ]
  [[ "$output" == *'"slug":"pay-bills"'* ]]
}

@test "task remove: drops the file" {
  "$STATE" task add "ephemeral" >/dev/null
  run "$STATE" task remove ephemeral
  [ "$status" -eq 0 ]
  [ ! -f "$JARVIS_HOME/$JARVIS_PROFILE/tasks/ephemeral.json" ]
}

@test "task list --filter k=v narrows results" {
  "$STATE" task add "open task" >/dev/null
  "$STATE" task add "another open" >/dev/null
  "$STATE" task add "to be done" >/dev/null
  "$STATE" task done to-be-done >/dev/null
  run "$STATE" task list --filter status=open
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 2 ]
}

# ---------- focus ----------------------------------------------------------

@test "focus pairs: empty log emits nothing" {
  run "$STATE" focus pairs
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "focus pairs: pairs start/end on matching topic" {
  log="$JARVIS_HOME/$JARVIS_PROFILE/focus.log"
  mkdir -p "$(dirname "$log")"
  {
    printf '{"ts":"2026-04-28T10:00:00Z","event":"start","duration":"25m","topic":"deep"}\n'
    printf '{"ts":"2026-04-28T10:25:00Z","event":"end","topic":"deep"}\n'
  } > "$log"
  run "$STATE" focus pairs
  [ "$status" -eq 0 ]
  [[ "$output" == *'"start_ts":"2026-04-28T10:00:00Z"'* ]]
  [[ "$output" == *'"elapsed_seconds":1500'* ]]
}

@test "focus stats today: returns minutes for matching local-day pairs" {
  export JARVIS_FAKE_NOW="2026-04-28T15:00:00Z"
  log="$JARVIS_HOME/$JARVIS_PROFILE/focus.log"
  mkdir -p "$(dirname "$log")"
  {
    printf '{"ts":"2026-04-28T10:00:00Z","event":"start","duration":"25m","topic":"deep"}\n'
    printf '{"ts":"2026-04-28T10:30:00Z","event":"end","topic":"deep"}\n'
    printf '{"ts":"2026-04-27T10:00:00Z","event":"start","duration":"25m","topic":"old"}\n'
    printf '{"ts":"2026-04-27T10:25:00Z","event":"end","topic":"old"}\n'
  } > "$log"
  run "$STATE" focus stats today
  [ "$status" -eq 0 ]
  [ "$output" = "30" ]
}

@test "focus stats top-topics: groups + sorts by minutes desc" {
  export JARVIS_FAKE_NOW="2026-04-28T20:00:00Z"
  log="$JARVIS_HOME/$JARVIS_PROFILE/focus.log"
  mkdir -p "$(dirname "$log")"
  {
    printf '{"ts":"2026-04-28T10:00:00Z","event":"start","duration":"25m","topic":"alpha"}\n'
    printf '{"ts":"2026-04-28T10:30:00Z","event":"end","topic":"alpha"}\n'
    printf '{"ts":"2026-04-28T11:00:00Z","event":"start","duration":"50m","topic":"alpha"}\n'
    printf '{"ts":"2026-04-28T12:00:00Z","event":"end","topic":"alpha"}\n'
    printf '{"ts":"2026-04-28T13:00:00Z","event":"start","duration":"15m","topic":"beta"}\n'
    printf '{"ts":"2026-04-28T13:15:00Z","event":"end","topic":"beta"}\n'
  } > "$log"
  run "$STATE" focus stats top-topics --days 7 --limit 5
  [ "$status" -eq 0 ]
  # alpha has more minutes -> first row.
  [ "$(echo "$output" | jq '.[0].topic')" = '"alpha"' ]
  [ "$(echo "$output" | jq '.[0].sessions')" -eq 2 ]
  [ "$(echo "$output" | jq '.[1].topic')" = '"beta"' ]
}

# ---------- stats weekly|monthly -------------------------------------------

@test "stats weekly --json: returns rollup with focus/tasks/notes sections" {
  export JARVIS_FAKE_NOW="2026-04-28T20:00:00Z"
  run "$STATE" stats weekly --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.window_days == 7' >/dev/null
  echo "$output" | jq -e 'has("focus") and has("tasks") and has("notes")' >/dev/null
}

@test "stats monthly default emits markdown rollup table" {
  export JARVIS_FAKE_NOW="2026-04-28T20:00:00Z"
  run "$STATE" stats monthly
  [ "$status" -eq 0 ]
  [[ "$output" == *"# jarvis monthly rollup"* ]]
}
