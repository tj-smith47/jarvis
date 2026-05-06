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
  note_store_new inbox audit-flock "Audit Flock" >/dev/null
  note_store_new ref etcd-restore "Etcd Restore" >/dev/null
  note_store_new project "clift/perf" "Perf" >/dev/null
  note_store_new inbox done-with-it "Done With It" >/dev/null
  note_store_archive inbox/done-with-it >/dev/null
}
teardown() { jarvis_common_teardown; }

source_completers() {
  source "$JARVIS_DIR/cmds/note/overrides/completion.sh"
}

@test "note_show pos1 lists active keys (excludes archived)" {
  source_completers
  run clift_complete_note_show_pos1 ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"inbox/audit-flock"* ]]
  [[ "$output" == *"ref/etcd-restore"* ]]
  [[ "$output" == *"project/clift/perf"* ]]
  [[ "$output" != *"done-with-it"* ]]
}

@test "note_show pos1 prefix filters" {
  source_completers
  run clift_complete_note_show_pos1 "ref/"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ref/etcd-restore"* ]]
  [[ "$output" != *"inbox/"* ]]
  [[ "$output" != *"project/"* ]]
}

@test "note_edit pos1 emits same set as show" {
  source_completers
  run clift_complete_note_edit_pos1 ""
  [[ "$output" == *"inbox/audit-flock"* ]]
}

@test "note_tag pos1 emits keys" {
  source_completers
  run clift_complete_note_tag_pos1 ""
  [[ "$output" == *"inbox/audit-flock"* ]]
}

@test "note_link pos1 + pos2 both emit keys" {
  source_completers
  run clift_complete_note_link_pos1 ""
  [[ "$output" == *"inbox/audit-flock"* ]]
  run clift_complete_note_link_pos2 ""
  [[ "$output" == *"ref/etcd-restore"* ]]
}

@test "note_archive pos1 emits keys" {
  source_completers
  run clift_complete_note_archive_pos1 ""
  [[ "$output" == *"inbox/audit-flock"* ]]
}

@test "note_current pos1 includes 'daily' keyword" {
  source_completers
  run clift_complete_note_current_pos1 "d"
  [ "$status" -eq 0 ]
  [[ "$output" == *"daily"* ]]
}

@test "note_current pos1 emits both keyword and slug matches" {
  source_completers
  run clift_complete_note_current_pos1 ""
  [[ "$output" == *"daily"* ]]
  [[ "$output" == *"inbox/audit-flock"* ]]
}

@test "note_on flag-value completer lists keys" {
  source_completers
  run clift_complete_note_on ""
  [[ "$output" == *"inbox/audit-flock"* ]]
}

@test "legacy note tag flag-value completer still emits the static tag list" {
  source_completers
  run clift_complete_note_tag "i"
  [[ "$output" == *"idea"* ]]
  [[ "$output" == *"infra"* ]]
}

@test "completers are no-ops when no index file exists yet" {
  rm -rf "$(note_root)/.index.json"
  source_completers
  run clift_complete_note_show_pos1 ""
  [ "$status" -eq 0 ]
  # No index → no slugs. (Empty output OK.)
  [ -z "$output" ]
}
