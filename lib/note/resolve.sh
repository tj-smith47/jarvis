#!/usr/bin/env bash
# Note identifier resolver: slug, title, prefix, explicit <kind>/<slug>.
# Requires state/profile.sh. Reads .index.json when present; falls back to FS.

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_NOTE_RESOLVE_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_NOTE_RESOLVE_LOADED=1

note_root() {
  printf '%s/notes\n' "$(state_profile_dir)"
}

note_index_file() {
  printf '%s/.index.json\n' "$(note_root)"
}

note_path() {
  printf '%s/%s.md\n' "$(note_root)" "$1"
}

note_kind_of() {
  printf '%s\n' "${1%%/*}"
}

note_slug_of() {
  printf '%s\n' "${1#*/}"
}

_note_index_keys() {
  local idx
  idx="$(note_index_file)"
  [[ -f "$idx" ]] || return 0
  jq -r 'keys[]' "$idx" 2>/dev/null || true
}

_note_fs_keys() {
  local root
  root="$(note_root)"
  [[ -d "$root" ]] || return 0
  local f key
  while IFS= read -r -d '' f; do
    key="${f#"$root"/}"
    key="${key%.md}"
    [[ "$key" == .* ]] && continue
    [[ "$key" == archive/* ]] && continue
    printf '%s\n' "$key"
  done < <(find "$root" -type f -name '*.md' -print0 2>/dev/null)
}

# Uses ASCII-only case folding (jq ascii_downcase). Non-ASCII titles must match byte-for-byte.
# Archive rows are filtered out so a title match honors the same
# archived-hidden contract as the bare-slug tier (and `note list`'s
# default). Archived notes remain reachable via explicit "archive/<slug>"
# in tier 1.
_note_title_match() {
  local idx q mode
  idx="$(note_index_file)"
  q="$1"
  mode="$2"
  [[ -f "$idx" ]] || return 0
  if [[ "$mode" == "exact" ]]; then
    jq -r --arg q "$q" '
      ($q | ascii_downcase) as $lowq
      | to_entries[]
      | select((.value.archived // false) | not)
      | select((.value.title // "") | ascii_downcase == $lowq)
      | .key
    ' "$idx" 2>/dev/null
  else
    jq -r --arg q "$q" '
      ($q | ascii_downcase) as $lowq
      | to_entries[]
      | select((.value.archived // false) | not)
      | select((.value.title // "") | ascii_downcase | startswith($lowq))
      | .key
    ' "$idx" 2>/dev/null
  fi
}

_note_ambiguous() {
  local q="$1"; shift
  printf 'ambiguous note "%s" — candidates:\n' "$q" >&2
  local m
  for m in "$@"; do
    printf '  %s\n' "$m" >&2
  done
}

# Exit codes:
#   0 — resolved; stdout holds the single <kind>/<slug> key
#   1 — miss (no candidate matched at any tier)
#   2 — ambiguous (multiple candidates at the winning tier; stderr lists them)
# The 1-vs-2 split lets consumers (e.g. `note --on`) branch between
# "create in inbox" and "abort and show candidates".
note_resolve() {
  local q="$1"
  [[ -z "$q" ]] && { printf 'note_resolve: empty query\n' >&2; return 1; }

  # 1. Explicit <kind>/<slug> literal file
  if [[ "$q" == */* ]]; then
    local root
    root="$(note_root)"
    if [[ -f "$root/$q.md" ]]; then
      printf '%s\n' "$q"
      return 0
    fi
  fi

  # Build full key list (index + fs fallback). Drop archive/* entries so
  # archived notes are hidden by default — matches `note list`'s
  # archived-default-hidden contract and `_note_fs_keys`' own filter.
  # An explicit "archive/<slug>" still resolves via tier 1 above (literal
  # file check), so callers can reach archived notes when they ask by the
  # archived key directly.
  local keys=()
  mapfile -t keys < <({ _note_index_keys; _note_fs_keys; } \
    | sort -u \
    | grep -v '^archive/' || true)

  # 2. Unique bare slug across kinds
  local matches=() k slug
  for k in "${keys[@]}"; do
    slug="${k##*/}"
    [[ "$slug" == "$q" ]] && matches+=("$k")
  done
  case "${#matches[@]}" in
    1) printf '%s\n' "${matches[0]}"; return 0 ;;
    0) : ;;
    *) _note_ambiguous "$q" "${matches[@]}"; return 2 ;;
  esac

  # 3. Title exact (case-insensitive, via index)
  mapfile -t matches < <(_note_title_match "$q" exact)
  case "${#matches[@]}" in
    1) printf '%s\n' "${matches[0]}"; return 0 ;;
    0) : ;;
    *) _note_ambiguous "$q" "${matches[@]}"; return 2 ;;
  esac

  # 4. Title prefix (ci)
  mapfile -t matches < <(_note_title_match "$q" prefix)
  case "${#matches[@]}" in
    1) printf '%s\n' "${matches[0]}"; return 0 ;;
    0) : ;;
    *) _note_ambiguous "$q" "${matches[@]}"; return 2 ;;
  esac

  # 5. Slug prefix across kinds
  matches=()
  for k in "${keys[@]}"; do
    slug="${k##*/}"
    [[ "$slug" == "$q"* ]] && matches+=("$k")
  done
  case "${#matches[@]}" in
    1) printf '%s\n' "${matches[0]}"; return 0 ;;
    0) printf 'no note matches "%s"\n' "$q" >&2; return 1 ;;
    *) _note_ambiguous "$q" "${matches[@]}"; return 2 ;;
  esac
}
