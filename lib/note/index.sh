#!/usr/bin/env bash
# Incremental .index.json for jarvis notes.
# Requires state/{lock,json}.sh, frontmatter.sh, note/resolve.sh.
#
# Library — intentionally does NOT set `set -euo pipefail`; options inherit
# from the caller (matches state/*.sh convention).
#
# Row schema: { path, kind, title, tags[], updated_at, archived, original_kind }.

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_NOTE_INDEX_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_NOTE_INDEX_LOADED=1

_note_index_ensure_file() {
  local idx
  idx="$(note_index_file)"
  if [[ ! -f "$idx" ]]; then
    mkdir -p "$(dirname "$idx")"
    printf '{}\n' > "$idx"
  fi
}

# note_index_get <kind/slug>
# Emits the row JSON (compact) or empty string when the key is absent.
note_index_get() {
  local key="$1"
  local idx
  idx="$(note_index_file)"
  [[ -f "$idx" ]] || { printf ''; return 0; }
  jq -c --arg k "$key" '.[$k] // empty' "$idx"
}

# note_index_keys
# Emits all keys, sorted.
note_index_keys() {
  local idx
  idx="$(note_index_file)"
  [[ -f "$idx" ]] || return 0
  jq -r 'keys | sort | .[]' "$idx"
}

# note_index_update <kind/slug>
# Reads frontmatter + mtime from the note file, patches a single row under a
# flock. The row is written to a tmp file and read back inside the locked
# body so arbitrary shell metacharacters in frontmatter values (quotes,
# backticks, $) never hit the eval'd command string.
note_index_update() {
  local key="$1"
  local file
  file="$(note_path "$key")"
  [[ -f "$file" ]] || return 1
  _note_index_ensure_file

  local fm_json kind title tags updated archived original_kind
  fm_json="$(fm_parse "$file")"
  kind="$(jq -r '.kind // empty' <<< "$fm_json")"
  [[ -z "$kind" ]] && kind="$(note_kind_of "$key")"
  title="$(jq -r '.title // empty' <<< "$fm_json")"
  tags="$(jq -c '.tags // []' <<< "$fm_json")"
  updated="$(date -u -r "$file" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
  archived="$(jq -r '.archived // false' <<< "$fm_json")"
  original_kind="$(jq -r '.original_kind // empty' <<< "$fm_json")"

  local row
  row="$(jq -n \
    --arg path "$key.md" \
    --arg kind "$kind" \
    --arg title "$title" \
    --argjson tags "$tags" \
    --arg updated "$updated" \
    --argjson archived "$archived" \
    --arg original_kind "$original_kind" \
    '{
      path: $path,
      kind: $kind,
      title: $title,
      tags: $tags,
      updated_at: $updated,
      archived: $archived,
      original_kind: (if $original_kind == "" then null else $original_kind end)
    }')"

  # Write row AND key to tmp files; read both back inside the lock body so
  # neither multi-line JSON nor arbitrary shell metacharacters in the key
  # (defensive — callers sanitize, but note_index_rebuild walks the fs and
  # could encounter a hand-edited .md filename with quotes) ever hit the
  # eval'd command string.
  local idx row_file key_file
  idx="$(note_index_file)"
  row_file="${idx}.row.$$.$BASHPID.$RANDOM"
  key_file="${idx}.key.$$.$BASHPID.$RANDOM"
  printf '%s' "$row" > "$row_file"
  printf '%s' "$key" > "$key_file"

  # shellcheck disable=SC2016
  state_with_lock "$idx" '
    _row="$(cat '"'$row_file'"')"
    _key="$(cat '"'$key_file'"')"
    _cur="$(cat '"'$idx'"' 2>/dev/null || printf "{}")"
    _new="$(jq --arg k "$_key" --argjson row "$_row" ".[\$k] = \$row" <<< "$_cur")"
    printf "%s\n" "$_new" > '"'$idx'"'
  '
  local rc=$?
  rm -f "$row_file" "$key_file"
  return "$rc"
}

# note_index_remove <kind/slug>
# Drops the key from the index. No-op if the index file is missing.
# $key routed through a tmp file so shell metacharacters stay inert.
note_index_remove() {
  local key="$1"
  local idx key_file
  idx="$(note_index_file)"
  [[ -f "$idx" ]] || return 0
  key_file="${idx}.key.$$.$BASHPID.$RANDOM"
  printf '%s' "$key" > "$key_file"
  # shellcheck disable=SC2016
  state_with_lock "$idx" '
    _key="$(cat '"'$key_file'"')"
    _cur="$(cat '"'$idx'"')"
    _new="$(jq --arg k "$_key" "del(.[\$k])" <<< "$_cur")"
    printf "%s\n" "$_new" > '"'$idx'"'
  '
  local rc=$?
  rm -f "$key_file"
  return "$rc"
}

# note_index_rebuild
# Scans $(note_root) for all .md files (excluding dotfiles) and rewrites
# the index from scratch. Overwrites, never merges.
note_index_rebuild() {
  _note_index_ensure_file
  local root idx
  root="$(note_root)"
  idx="$(note_index_file)"
  # shellcheck disable=SC2016
  state_with_lock "$idx" 'printf "{}\n" > '"'$idx'"
  local f key
  while IFS= read -r -d '' f; do
    key="${f#"$root"/}"
    key="${key%.md}"
    [[ "$key" == .* ]] && continue
    note_index_update "$key"
  done < <(find "$root" -type f -name '*.md' -print0 2>/dev/null)
}
