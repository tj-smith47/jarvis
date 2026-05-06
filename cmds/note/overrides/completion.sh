#!/usr/bin/env bash
# Dynamic completers for `jarvis note` and its subcommands.
#
# Naming contract (from lib/wrapper/wrapper.sh.tmpl):
#   clift_complete_<task-colons→underscores>_<flag-dashes→underscores>
# Positional slot completers use the synthetic flag name "pos<N>"
# (lib/completion/completion.sh).
#
# Sourced standalone by the hidden `_complete` subcommand inside a
# subshell, so we must NOT depend on jarvis lib state being already
# loaded — the index path is computed inline using the same default
# logic state_profile_dir uses.

# Internal: index file path (matches state_profile_dir's defaults).
_note_completion_idx_path() {
  local home="${JARVIS_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/jarvis}"
  local profile="${JARVIS_PROFILE:-default}"
  printf '%s/%s/notes/.index.json\n' "$home" "$profile"
}

# Internal: emit non-archived keys from .index.json that begin with $1.
# Returns silently (no error, no output) when the index doesn't exist
# yet — completion must never disrupt the shell.
_note_completion_keys() {
  local prefix="${1:-}"
  local idx
  idx="$(_note_completion_idx_path)"
  [[ -f "$idx" ]] || return 0
  jq -r --arg p "$prefix" '
    to_entries
    | map(select((.value.archived // false) | not))
    | .[]
    | select(.key | startswith($p))
    | .key
  ' "$idx" 2>/dev/null
}

# Positional slug completers — one per slot per subcommand.
clift_complete_note_show_pos1()    { _note_completion_keys "${1:-}"; }
clift_complete_note_edit_pos1()    { _note_completion_keys "${1:-}"; }
clift_complete_note_tag_pos1()     { _note_completion_keys "${1:-}"; }
clift_complete_note_link_pos1()    { _note_completion_keys "${1:-}"; }
clift_complete_note_link_pos2()    { _note_completion_keys "${1:-}"; }
clift_complete_note_archive_pos1() { _note_completion_keys "${1:-}"; }

# `note current <ref>` accepts the reserved keyword "daily" in addition
# to the resolved-slug forms — emit it too, prefix-filtered.
clift_complete_note_current_pos1() {
  local prefix="${1:-}"
  if [[ "daily" == "$prefix"* ]]; then
    printf 'daily\n'
  fi
  _note_completion_keys "$prefix"
}

# Flag-value completer for `note --on <ref>` (default-capture routing).
clift_complete_note_on() { _note_completion_keys "${1:-}"; }

# Existing static --tag completer for the bare `note --tag` flag value.
# Kept here so the legacy contract continues to work alongside the new
# slug-aware positional completers.
clift_complete_note_tag() {
  local prefix="${1:-}"
  local tags=(arch queue bug 1:1 idea retro release infra oncall onboarding)
  local t
  for t in "${tags[@]}"; do
    [[ "$t" == "$prefix"* ]] && printf '%s\n' "$t"
  done
}
