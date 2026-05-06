#!/usr/bin/env bash
# Gotify push notification channel.
# Reads [notify.gotify] url, token (and optional priority) from per-profile
# config.toml — profile threaded explicitly, no env mutation.

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_NOTIFY_GOTIFY_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_NOTIFY_GOTIFY_LOADED=1

notify_gotify() {
  local message="${1:-}" profile="${2:-}"

  if [[ -z "$message" ]]; then
    _notify_log gotify false "" "empty message" "$profile"
    return 1
  fi

  local url token priority
  url="$(config_get notify.gotify.url "" "$profile")"
  token="$(config_get notify.gotify.token "" "$profile")"
  priority="$(config_get notify.gotify.priority "5" "$profile")"

  if [[ -z "$url" ]]; then
    _notify_log gotify false "$message" "missing [notify.gotify].url" "$profile"
    return 2
  fi
  if [[ -z "$token" ]]; then
    _notify_log gotify false "$message" "missing [notify.gotify].token" "$profile"
    return 2
  fi

  if [[ "${JARVIS_NOTIFY_DRYRUN:-}" == "1" ]]; then
    _notify_log gotify true "$message" "" "$profile"
    return 0
  fi

  local err
  if err="$(curl -fsS -X POST "${url}/message?token=${token}" \
              -F "title=jarvis" \
              -F "message=${message}" \
              -F "priority=${priority}" 2>&1 >/dev/null)"; then
    _notify_log gotify true "$message" "" "$profile"
    return 0
  fi
  # Trim curl's verbose output to first line for the log.
  err="${err%%$'\n'*}"
  _notify_log gotify false "$message" "$err" "$profile"
  return 1
}

notify_register gotify notify_gotify
