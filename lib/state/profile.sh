#!/usr/bin/env bash
# State profile resolver.
#
# Resolution order (first wins):
#   1. CLIFT_FLAGS[profile]      — assoc array populated by the router pipeline
#                                  for in-shell parsed-cmd invocations.
#   2. CLIFT_FLAG_PROFILE env    — exported by the framework parser; survives
#                                  across subshells (assoc arrays don't).
#   3. JARVIS_PROFILE env        — direct override (tests, manual export).
#   4. 'default'                 — last-resort fallback.
#
# Pinning the precedence here rather than per-cmd means every command that
# touches state via state_profile_dir() honors the persistent --profile
# flag automatically — no per-cmd `JARVIS_PROFILE=$flag; export` boilerplate.
# JARVIS_PROFILE is also exported as a side effect so downstream libs that
# read the env directly (lib/calendar/provider.sh, lib/integrations/*.sh,
# lib/state/config.sh fallback path) see the same resolved value.

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_STATE_PROFILE_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_STATE_PROFILE_LOADED=1

state_profile_dir() {
  local home="${JARVIS_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/jarvis}"
  local profile
  if declare -p CLIFT_FLAGS >/dev/null 2>&1 \
     && [[ -n "${CLIFT_FLAGS[profile]:-}" ]]; then
    profile="${CLIFT_FLAGS[profile]}"
  elif [[ -n "${CLIFT_FLAG_PROFILE:-}" ]]; then
    profile="${CLIFT_FLAG_PROFILE}"
  else
    profile="${JARVIS_PROFILE:-default}"
  fi
  JARVIS_PROFILE="$profile"
  export JARVIS_PROFILE
  printf '%s/%s\n' "$home" "$profile"
}

state_ensure_tree() {
  local dir
  dir="$(state_profile_dir)"
  mkdir -p \
    "$dir/tasks" \
    "$dir/reminders" \
    "$dir/cache" \
    "$dir/notes/inbox" \
    "$dir/notes/daily" \
    "$dir/notes/meetings" \
    "$dir/notes/ref" \
    "$dir/notes/archive" \
    "$dir/notes/templates"
  if [[ ! -f "$dir/state.version" ]]; then
    printf '1\n' > "$dir/state.version"
  fi
}
