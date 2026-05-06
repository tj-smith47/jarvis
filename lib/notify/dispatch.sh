#!/usr/bin/env bash
# Channel fan-out for a single reminder.
#
# notify_dispatch <reminder-json>
#   - Reads the reminder's `via` array + `profile` field.
#   - For each name in via, looks up the channel fn in the _NOTIFY_CHANNELS
#     registry (loaded by sourcing the channel libs at the call site) and
#     invokes it as `<fn> <message> <profile>`. No env mutation.
#   - Unknown channel: emits a notify.log row (`_notify_log <name> false
#     "<msg>" "unknown channel" <profile>`) and counts as a failed attempt.
#   - Returns 0 if any channel attempt succeeded, 1 if all failed.
#
# Channels handle their own notify.log writes via _notify_log — dispatch
# never double-logs.

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_NOTIFY_DISPATCH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_NOTIFY_DISPATCH_LOADED=1

notify_dispatch() {
  local reminder_json="$1"
  if ! jq -e . <<< "$reminder_json" >/dev/null 2>&1; then
    printf 'notify_dispatch: reminder JSON is invalid\n' >&2
    return 2
  fi

  local message profile
  message="$(jq -r '.message // empty' <<< "$reminder_json")"
  profile="$(jq -r '.profile // empty' <<< "$reminder_json")"
  if [[ -z "$message" ]]; then
    printf 'notify_dispatch: reminder has no message\n' >&2
    return 2
  fi

  local any_ok=0
  local channel fn
  while IFS= read -r channel; do
    [[ -z "$channel" ]] && continue
    fn="${_NOTIFY_CHANNELS[$channel]:-}"
    if [[ -z "$fn" ]]; then
      _notify_log "$channel" false "$message" "unknown channel" "$profile"
      continue
    fi
    if "$fn" "$message" "$profile"; then
      any_ok=1
    fi
  done < <(jq -r '.via[]?' <<< "$reminder_json")

  if (( any_ok == 1 )); then
    return 0
  fi
  return 1
}
