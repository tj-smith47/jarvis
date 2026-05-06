#!/usr/bin/env bash
# Note store: create / append / archive / delete / read.
# Requires state/{profile,lock,json}.sh, frontmatter.sh, note/{resolve,index}.sh.
#
# Library — intentionally does NOT set `set -euo pipefail`; options inherit
# from the caller (matches state/*.sh convention).
#
# Crash-consistency model: the `.md` file is the source of truth; `.index.json`
# is a cache. If a process is killed between `note_store_new`'s file rename
# and its `note_index_update`, the note exists but the index lacks the row.
# `note_resolve` falls through to a filesystem scan, so the system degrades
# gracefully. `note_index_rebuild` (wired to `doctor --rebuild-index` in Task
# 16) regenerates `.index.json` from disk to close the gap.

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_NOTE_STORE_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_NOTE_STORE_LOADED=1

note_now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# _note_store_parse_flags <args...>
# Shared flag parser for --tags / --template / --extra-fm / --no-timestamp / --format.
# Caller pre-declares NS_TAGS / NS_TEMPLATE / NS_EXTRA / NS_NOTS / NS_FORMAT; we set them.
_note_store_parse_flags() {
  local arg
  while (( $# > 0 )); do
    arg="$1"
    case "$arg" in
      --tags) NS_TAGS="$2"; shift 2 ;;
      --template) NS_TEMPLATE="$2"; shift 2 ;;
      --extra-fm) NS_EXTRA="$2"; shift 2 ;;
      --no-timestamp) NS_NOTS=1; shift ;;
      --format) NS_FORMAT="$2"; shift 2 ;;
      *) return 2 ;;
    esac
  done
}

# note_store_new <kind> <slug> <title> [--tags JSON] [--template FILE] [--extra-fm JSON]
# Creates notes/<kind>/<slug>.md atomically via `ln(2)` — the hardlink create
# fails with EEXIST atomically under the kernel, so under a concurrent race
# exactly one writer wins and the rest get return 1. Emits the resolved
# <kind>/<slug> on stdout on success. Returns 1 on collision (explicit
# "already exists" error on stderr), 2 on bad flag args.
#
# Prior implementations used `[[ -e $file ]]` + `mv -f` — neither atomic:
# all racers passed the existence check, all racers overwrote one file, and
# callers relying on the 1-on-collision contract silently got 0 for every
# racer. The `ln` form below is the canonical POSIX atomic-create pattern.
note_store_new() {
  local kind="$1" slug="$2" title="$3"
  shift 3
  local NS_TAGS="[]" NS_TEMPLATE="" NS_EXTRA="{}" NS_NOTS=0 NS_FORMAT=""
  _note_store_parse_flags "$@" || return 2

  local key="$kind/$slug"
  local file
  file="$(note_path "$key")"
  mkdir -p "$(dirname "$file")"

  local now template_fm="{}" template_body=""
  now="$(note_now_iso)"
  if [[ -n "$NS_TEMPLATE" && -f "$NS_TEMPLATE" ]]; then
    template_fm="$(fm_parse "$NS_TEMPLATE")"
    template_body="$(fm_body "$NS_TEMPLATE")"
  fi

  local jarvis_fm
  jarvis_fm="$(jq -n \
    --arg slug "$slug" \
    --arg kind "$kind" \
    --arg title "$title" \
    --arg now "$now" \
    --argjson tags "$NS_TAGS" \
    --argjson extra "$NS_EXTRA" \
    '{slug:$slug,kind:$kind,title:$title,created_at:$now,updated_at:$now,tags:$tags} + $extra')"

  local merged
  merged="$(fm_merge "$template_fm" "$jarvis_fm")"

  local yaml tmp
  yaml="$(dasel -i json -o yaml <<< "$merged")"
  tmp="${file}.tmp.$$.$BASHPID.$RANDOM"
  {
    printf -- '---\n%s\n---\n' "$yaml"
    printf '%s' "$template_body"
  } > "$tmp"

  # Atomic create: ln(2) fails with EEXIST if the target exists, and the
  # check+create happens under a single kernel call — no TOCTOU window.
  if ! ln "$tmp" "$file" 2>/dev/null; then
    rm -f "$tmp"
    printf 'note_store_new: note already exists: %s\n' "$key" >&2
    return 1
  fi
  rm -f "$tmp"

  note_index_update "$key"
  printf '%s\n' "$key"
}

# note_store_append <kind/slug> <body> [--no-timestamp] [--format STRFTIME]
# Atomic flock-guarded tail append. The body+header chunk is built in a tmp
# file outside the lock, then concatenated in with `cat >> file` inside the
# lock — this keeps user-supplied body text (which may contain quotes, $,
# backticks) from being interpolated into the eval'd lock command string.
note_store_append() {
  local key="$1" body="$2"
  shift 2
  local NS_TAGS="[]" NS_TEMPLATE="" NS_EXTRA="{}" NS_NOTS=0 NS_FORMAT=""
  _note_store_parse_flags "$@" || return 2

  local file
  file="$(note_path "$key")"
  [[ -f "$file" ]] || return 1

  local fm_ts fm_fmt use_ts format
  fm_ts="$(fm_get "$file" "append.timestamp" "true")"
  fm_fmt="$(fm_get "$file" "append.format" "## %Y-%m-%d %H:%M")"
  if (( NS_NOTS )) || [[ "$fm_ts" == "false" ]]; then
    use_ts=0
  else
    use_ts=1
  fi
  format="${NS_FORMAT:-$fm_fmt}"

  # Build the chunk in a tmp file so $body never enters the eval'd lock body.
  local chunk
  chunk="${file}.chunk.$$.$BASHPID.$RANDOM"
  {
    printf '\n'
    if (( use_ts )); then
      date +"$format"
      printf '\n'
    fi
    printf '%s\n' "$body"
  } > "$chunk"

  # shellcheck disable=SC2016
  state_with_lock "$file" 'cat '"'$chunk'"' >> '"'$file'"
  local rc=$?
  rm -f "$chunk"
  (( rc == 0 )) || return "$rc"

  note_index_update "$key"
}

# note_store_archive <kind/slug>
# Moves the note to archive/<slug>.md with -2, -3, ... collision suffix.
# Stamps original_kind, archived=true, kind="archive" in the frontmatter so
# the index picks them up on note_index_update.
note_store_archive() {
  local key="$1"
  local file
  file="$(note_path "$key")"
  [[ -f "$file" ]] || return 1

  local root slug kind dest n
  root="$(note_root)"
  kind="$(note_kind_of "$key")"
  slug="${key##*/}"
  mkdir -p "$root/archive"
  dest="$root/archive/$slug.md"
  n=2
  while [[ -e "$dest" ]]; do
    dest="$root/archive/$slug-$n.md"
    n=$((n + 1))
  done
  mv -f "$file" "$dest"

  local new_key
  new_key="archive/$(basename "$dest" .md)"

  # Stamp original_kind + archived=true + kind=archive in frontmatter so the
  # index picks them up via the normal fm_parse path.
  local body fm_json upd yaml tmp
  body="$(fm_body "$dest")"
  fm_json="$(fm_parse "$dest")"
  upd="$(jq --arg k "$kind" '.original_kind = $k | .archived = true | .kind = "archive"' <<< "$fm_json")"
  yaml="$(dasel -i json -o yaml <<< "$upd")"
  tmp="${dest}.tmp.$$.$BASHPID.$RANDOM"
  { printf -- '---\n%s\n---\n' "$yaml"; printf '%s' "$body"; } > "$tmp"
  mv -f "$tmp" "$dest"

  note_index_remove "$key"
  note_index_update "$new_key"
  printf '%s\n' "$new_key"
}

# note_store_delete <kind/slug>
# Removes the note file, lock sidecar, any stale tmp dropings, and the
# matching index row.
note_store_delete() {
  local key="$1"
  local file
  file="$(note_path "$key")"
  rm -f "$file" "$file.lock" "$file".tmp.*
  note_index_remove "$key"
}

# note_store_read <kind/slug>
# Emits the full file content (including frontmatter).
note_store_read() {
  local key="$1"
  local file
  file="$(note_path "$key")"
  [[ -f "$file" ]] || return 1
  printf '%s' "$(<"$file")"
  # Preserve trailing newline that command substitution would strip when
  # the caller captures via $(...).
  printf '\n'
}
