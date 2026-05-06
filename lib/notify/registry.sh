#!/usr/bin/env bash
# Notification channel registry + uniform delivery log.
#
# Channels register at source-time:
#   notify_register <name> <fn>
#
# Dispatch (lib/notify/dispatch.sh) iterates the registry rather than a
# hardcoded case so adding a new channel later is a single new file +
# notify_register call — no churn at the dispatch site.
#
# All channel attempts emit one JSON line via _notify_log to the per-profile
# notify.log. Uniform shape lets tests assert via jq instead of parsing
# tab-separated formats that drift.

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_NOTIFY_REGISTRY_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_NOTIFY_REGISTRY_LOADED=1

declare -gA _NOTIFY_CHANNELS=()

notify_register() {
  local name="$1" fn="$2"
  if [[ -z "$name" || -z "$fn" ]]; then
    printf 'notify_register: usage notify_register <name> <fn>\n' >&2
    return 2
  fi
  _NOTIFY_CHANNELS["$name"]="$fn"
}

# notify_channels — registered channel names, one per line, sorted.
notify_channels() {
  if (( ${#_NOTIFY_CHANNELS[@]} == 0 )); then
    return 0
  fi
  printf '%s\n' "${!_NOTIFY_CHANNELS[@]}" | sort
}

_notify_log_path() {
  local profile="${1:-}"
  local home dir
  if [[ -n "$profile" ]]; then
    home="${JARVIS_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/jarvis}"
    dir="$home/$profile"
  else
    dir="$(state_profile_dir)"
  fi
  printf '%s/notify.log\n' "$dir"
}

# _notify_log <channel> <ok-bool> <message> [error] [profile]
# Append one JSON line to the per-profile notify.log. Locked via flock
# (reusing state/lock.sh which channels source transitively).
_notify_log() {
  local channel="$1" ok="$2" message="$3" error="${4:-}" profile="${5:-}"
  local ts target row
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  target="$(_notify_log_path "$profile")"
  mkdir -p "$(dirname "$target")"

  if [[ -n "$error" ]]; then
    row="$(jq -nc \
      --arg ts "$ts" --arg ch "$channel" --argjson ok "$ok" \
      --arg msg "$message" --arg err "$error" \
      '{ts:$ts, channel:$ch, ok:$ok, message:$msg, error:$err}')"
  else
    row="$(jq -nc \
      --arg ts "$ts" --arg ch "$channel" --argjson ok "$ok" \
      --arg msg "$message" \
      '{ts:$ts, channel:$ch, ok:$ok, message:$msg}')"
  fi
  state_with_lock "$target" "printf '%s\n' '$row' >> '$target'"
}
