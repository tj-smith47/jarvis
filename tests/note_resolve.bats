#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

load helper

setup() {
  jarvis_common_setup
  source "$JARVIS_DIR/lib/state/profile.sh"
  source "$JARVIS_DIR/lib/note/resolve.sh"
  state_ensure_tree
  NOTES="$(note_root)"
  mkdir -p "$NOTES/inbox" "$NOTES/ref" "$NOTES/projects/clift" "$NOTES/meetings"
  : > "$NOTES/inbox/audit-the-flock.md"
  : > "$NOTES/ref/etcd-restore-runbook.md"
  : > "$NOTES/projects/clift/perf-investigation.md"
  : > "$NOTES/meetings/1on1-alice-2026-04-18.md"

  cat > "$(note_index_file)" <<'EOF'
{
  "inbox/audit-the-flock": {"title":"Audit the flock path","kind":"inbox","tags":[]},
  "ref/etcd-restore-runbook": {"title":"Etcd Restore Runbook","kind":"ref","tags":["k3s"]},
  "projects/clift/perf-investigation": {"title":"Perf Investigation","kind":"project","tags":["clift","perf"]},
  "meetings/1on1-alice-2026-04-18": {"title":"1on1 Alice","kind":"meeting","tags":[]}
}
EOF
}
teardown() { jarvis_common_teardown; }

@test "note_resolve: explicit kind/slug short-circuits" {
  run note_resolve "ref/etcd-restore-runbook"
  [ "$status" -eq 0 ]
  [ "$output" = "ref/etcd-restore-runbook" ]
}

@test "note_resolve: unique slug across kinds" {
  run note_resolve "perf-investigation"
  [ "$status" -eq 0 ]
  [ "$output" = "projects/clift/perf-investigation" ]
}

@test "note_resolve: title exact (case-insensitive)" {
  run note_resolve "perf investigation"
  [ "$status" -eq 0 ]
  [ "$output" = "projects/clift/perf-investigation" ]
}

@test "note_resolve: title prefix" {
  run note_resolve "etcd restore"
  [ "$status" -eq 0 ]
  [ "$output" = "ref/etcd-restore-runbook" ]
}

@test "note_resolve: slug prefix" {
  run note_resolve "audit-the"
  [ "$status" -eq 0 ]
  [ "$output" = "inbox/audit-the-flock" ]
}

@test "note_resolve: unknown → exit 1" {
  run note_resolve "nonexistent"
  [ "$status" -eq 1 ]
}

@test "note_resolve: ambiguous prefix lists candidates on stderr" {
  mkdir -p "$NOTES/inbox"
  : > "$NOTES/inbox/foo-a.md"
  : > "$NOTES/inbox/foo-b.md"
  cat > "$(note_index_file)" <<'EOF'
{
  "inbox/foo-a": {"title":"Foo A","kind":"inbox","tags":[]},
  "inbox/foo-b": {"title":"Foo B","kind":"inbox","tags":[]}
}
EOF
  run note_resolve "foo"
  [ "$status" -eq 2 ]
  [[ "$output$stderr" == *"inbox/foo-a"* ]]
  [[ "$output$stderr" == *"inbox/foo-b"* ]]
}

@test "note_path resolves to full .md path" {
  run note_path "ref/etcd-restore-runbook"
  [ "$output" = "$NOTES/ref/etcd-restore-runbook.md" ]
}

@test "note_kind_of + note_slug_of split on first slash only" {
  run note_kind_of "projects/clift/perf-investigation"
  [ "$output" = "projects" ]
  run note_slug_of "projects/clift/perf-investigation"
  [ "$output" = "clift/perf-investigation" ]
}

@test "note_resolve: jira-key slug preserves upper-snake" {
  : > "$NOTES/inbox/DEV-123.md"
  cat > "$(note_index_file)" <<'EOF'
{
  "inbox/audit-the-flock": {"title":"Audit the flock path","kind":"inbox","tags":[]},
  "inbox/DEV-123": {"title":"DEV-123 something","kind":"inbox","tags":[]}
}
EOF
  run note_resolve "DEV-123"
  [ "$status" -eq 0 ]
  [ "$output" = "inbox/DEV-123" ]
}

@test "note_resolve: explicit kind/slug that doesn't exist falls through to title match" {
  run note_resolve "ref/perf investigation"
  # slash-bearing query, literal file missing → falls through; nothing matches title "ref/perf investigation"
  [ "$status" -eq 1 ]
}

@test "note_resolve: tier 2 (unique slug) wins over tier 3 (title)" {
  # add a note whose slug matches another note's title
  mkdir -p "$NOTES/ref"
  : > "$NOTES/ref/perf-investigation-reference.md"
  cat > "$(note_index_file)" <<'EOF'
{
  "projects/clift/perf-investigation": {"title":"Perf Investigation","kind":"project","tags":[]},
  "ref/perf-investigation-reference": {"title":"Perf Investigation","kind":"ref","tags":[]}
}
EOF
  # Two index entries now have title "Perf Investigation" — tier 3 is ambiguous.
  # But a query of the unique slug "perf-investigation" should still hit tier 2 (single match).
  run note_resolve "perf-investigation"
  [ "$status" -eq 0 ]
  [ "$output" = "projects/clift/perf-investigation" ]
}

@test "note_resolve: ambiguous bare slug (same slug in two kinds) lists candidates" {
  mkdir -p "$NOTES/ref"
  : > "$NOTES/ref/perf-investigation.md"
  cat > "$(note_index_file)" <<'EOF'
{
  "projects/clift/perf-investigation": {"title":"A","kind":"project","tags":[]},
  "ref/perf-investigation": {"title":"B","kind":"ref","tags":[]}
}
EOF
  run note_resolve "perf-investigation"
  [ "$status" -eq 2 ]
  [[ "$output$stderr" == *"projects/clift/perf-investigation"* ]]
  [[ "$output$stderr" == *"ref/perf-investigation"* ]]
}

@test "note_resolve: ascii case-insensitive title match" {
  run note_resolve "ETCD RESTORE RUNBOOK"
  [ "$status" -eq 0 ]
  [ "$output" = "ref/etcd-restore-runbook" ]
}
