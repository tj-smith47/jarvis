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

@test "note_index_rebuild reconstructs index from filesystem" {
  note_store_new inbox a "A"
  note_store_new ref b "B"
  rm -f "$(note_index_file)"
  note_index_rebuild
  run jq -r 'keys | sort | join(",")' "$(note_index_file)"
  [ "$output" = "inbox/a,ref/b" ]
}

@test "note_index_rebuild and incremental agree" {
  note_store_new inbox a "A"
  note_store_new ref b "B"
  note_store_append inbox/a "more" --no-timestamp
  local incr
  incr="$(jq -Sc 'to_entries | map(.value |= del(.updated_at)) | from_entries' \
    "$(note_index_file)")"
  note_index_rebuild
  local rebuilt
  rebuilt="$(jq -Sc 'to_entries | map(.value |= del(.updated_at)) | from_entries' \
    "$(note_index_file)")"
  [ "$incr" = "$rebuilt" ]
}

@test "note_index_update picks up tag changes" {
  note_store_new inbox x "X" --tags '["a"]'
  local f="$(note_path inbox/x)"
  fm_set "$f" "tags" '["a","b"]' 2>/dev/null || true
  # fm_set on arrays is scalar-only in minimal impl; simulate via jq+rewrite
  local body fm fm_json upd yaml tmp
  fm_split "$f" body fm
  fm_json="$(fm_parse "$f")"
  upd="$(jq '.tags = ["a","b"]' <<< "$fm_json")"
  yaml="$(dasel -i json -o yaml <<< "$upd")"
  tmp="${f}.tmp.$$"
  { printf -- '---\n%s\n---\n' "$yaml"; printf '%s' "$body"; } > "$tmp"
  mv -f "$tmp" "$f"
  note_index_update inbox/x
  run jq -r '."inbox/x".tags | sort | join(",")' "$(note_index_file)"
  [ "$output" = "a,b" ]
}

@test "note_index_remove drops the row" {
  note_store_new inbox y "Y"
  note_index_remove inbox/y
  run jq -r '."inbox/y" // "absent"' "$(note_index_file)"
  [ "$output" = "absent" ]
}

@test "note_index_update is safe against keys with shell metacharacters" {
  # Seed a normal note so the index file exists.
  note_store_new inbox normal "Normal"
  # Now invoke with an injection-style key; note_index_update requires the
  # referenced .md to exist, so it returns 1 — but the injection attempt
  # must not execute any shell in the locked body (no INJECTED token should
  # appear on stderr, no sentinel file should be written).
  local sentinel="$TEST_DIR/injected.sentinel"
  run --separate-stderr note_index_update "x'; echo INJECTED >&2; touch '$sentinel'; #"
  [ "$status" -ne 0 ]
  [[ "$stderr" != *"INJECTED"* ]]
  [ ! -e "$sentinel" ]
  # The normal row is still present and intact.
  run jq -r '."inbox/normal".title' "$(note_index_file)"
  [ "$output" = "Normal" ]
}
