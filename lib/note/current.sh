#!/usr/bin/env bash
# Current-note state: notes/.current holds one line.
#   kind=daily             → auto-rotates to today's daily on resolve
#   slug=<kind>/<slug>     → frozen to that key
# Requires note/resolve.sh (for note_root).
#
# Library — intentionally does NOT set `set -euo pipefail`; options inherit
# from the caller (matches state/*.sh and note/*.sh convention).

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_NOTE_CURRENT_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_NOTE_CURRENT_LOADED=1

# note_current_file → absolute path to the state file.
note_current_file() {
  printf '%s/.current\n' "$(note_root)"
}

# note_current_read → stdout: the single line of state, or empty if unset.
note_current_read() {
  local f
  f="$(note_current_file)"
  [[ -f "$f" ]] || return 0
  head -n1 "$f"
}

# note_current_write <line> — write exactly one line to the state file.
note_current_write() {
  local line="$1"
  local f
  f="$(note_current_file)"
  mkdir -p "$(dirname "$f")"
  printf '%s\n' "$line" > "$f"
}

# note_current_clear — rm -f the state file.
note_current_clear() {
  rm -f "$(note_current_file)"
}

# note_current_resolve → stdout: concrete <kind>/<slug> key.
# Exit 1 when state is unset; exit 2 when state is malformed.
# kind=daily auto-rotates to today's YYYY-MM-DD (caller creates the file if
# it's missing — resolver returns the key unconditionally).
note_current_resolve() {
  local line key today
  line="$(note_current_read)"
  [[ -z "$line" ]] && return 1
  case "$line" in
    kind=daily)
      # Honor JARVIS_TODAY for tests + cron determinism — same contract
      # as note.daily.sh so the two never disagree on which file is
      # "today".
      today="${JARVIS_TODAY:-$(date +%F)}"
      printf 'daily/%s\n' "$today"
      return 0
      ;;
    slug=*)
      key="${line#slug=}"
      printf '%s\n' "$key"
      return 0
      ;;
    *)
      printf 'note_current: malformed state %q\n' "$line" >&2
      return 2
      ;;
  esac
}
