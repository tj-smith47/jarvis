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
  source "$JARVIS_DIR/lib/note/current.sh"
  state_ensure_tree
}
teardown() { jarvis_common_teardown; }

# Drive a command script directly with all args going through standalone-argv
# parsing. Mirrors the router shape (env-only, $@ holds the user argv) so
# both the parsed and passthrough paths are exercised.
run_script() {
  local script="$1"; shift
  env -i \
    HOME="$HOME" PATH="$PATH" EDITOR="" \
    JARVIS_HOME="$JARVIS_HOME" JARVIS_PROFILE="$JARVIS_PROFILE" \
    JARVIS_TODAY="$JARVIS_TODAY" \
    CLI_DIR="$JARVIS_DIR" FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR" \
    PAGER=cat \
    bash "$JARVIS_DIR/cmds/note/$script" "$@"
}

@test "roundtrip: capture → daily → new → meeting → project → tag → list → search → link → archive → current+append → rebuild" {
  # 1. Quick capture into inbox. note.add doesn't open an editor; no flag.
  run_script note.add.sh "need to audit the flock path in lib/flags/compile.sh"
  [ -f "$(note_path inbox/need-to-audit-the-flock-path-in-lib-flags-compile-sh)" ]

  # 2. Daily, missing + no body → create-only under --no-edit.
  run_script note.daily.sh --no-edit
  [ -f "$(note_path daily/2026-04-19)" ]

  # 3. Daily, exists + body → append.
  run_script note.daily.sh "finished the state layer, moving to task crud" --no-edit
  grep -q 'finished the state layer' "$(note_path daily/2026-04-19)"

  # 4. New ref note.
  run_script note.new.sh "Etcd Restore Runbook" --kind ref --no-edit
  [ -f "$(note_path ref/etcd-restore-runbook)" ]

  # 5. Meeting (1on1 prefix → 1on1 template).
  run_script note.meeting.sh "1on1 Alice" --no-edit
  [ -f "$(note_path meeting/1on1-alice-2026-04-19)" ]

  # 6. Project note.
  run_script note.project.sh "clift/Perf Investigation" --no-edit
  [ -f "$(note_path project/clift/perf-investigation)" ]

  # 7. Tag mutation on the project note.
  run_script note.tag.sh "perf-investigation" +clift +perf
  local tags
  tags="$(fm_parse "$(note_path project/clift/perf-investigation)" \
            | jq -r '.tags | sort | join(",")')"
  [[ "$tags" == *"clift"* ]]
  [[ "$tags" == *"perf"* ]]

  # 8. List sees everything.
  run run_script note.list.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"Etcd Restore Runbook"* ]]
  [[ "$output" == *"Perf Investigation"* ]]

  # 9. Search hits the captured body.
  run run_script note.search.sh flock
  [ "$status" -eq 0 ]
  [[ "$output" == *"audit the flock path"* ]]

  # 10. Link the ref note to the project note bidirectionally.
  run_script note.link.sh "etcd-restore-runbook" "perf-investigation"
  grep -qF '[[project/clift/perf-investigation]]' "$(note_path ref/etcd-restore-runbook)"
  grep -qF '[[ref/etcd-restore-runbook]]' "$(note_path project/clift/perf-investigation)"

  # 11. Current + append routing: setting current to the project, then a bare
  #     `note <body>` appends there.
  run_script note.current.sh "Perf Investigation"
  run_script note.add.sh "also check parser.sh"
  grep -q 'also check parser.sh' "$(note_path project/clift/perf-investigation)"

  # 12. Show renders the project note's body.
  run run_script note.show.sh perf-investigation --raw
  [ "$status" -eq 0 ]
  [[ "$output" == *"also check parser.sh"* ]]

  # 13. Archive the meeting note.
  run_script note.archive.sh "1on1-alice-2026-04-19"
  [ ! -f "$(note_path meeting/1on1-alice-2026-04-19)" ]
  [ -f "$(note_root)/archive/1on1-alice-2026-04-19.md" ]

  # 14. doctor --rebuild-index produces an index that matches the live one
  #     (modulo updated_at, which the rebuild stamps fresh).
  local before after
  before="$(jq -Sc 'to_entries
    | map(.value |= (del(.updated_at) | del(.created_at)))
    | from_entries' "$(note_index_file)")"
  note_index_rebuild
  after="$(jq -Sc 'to_entries
    | map(.value |= (del(.updated_at) | del(.created_at)))
    | from_entries' "$(note_index_file)")"
  [ "$before" = "$after" ]
}
