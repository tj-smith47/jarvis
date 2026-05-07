#!/usr/bin/env bash
# Local desktop notification channel.
# Detects osascript (macOS) then notify-send (Linux) at dispatch time so a
# synced $JARVIS_HOME works on either. Dryrun mode (JARVIS_NOTIFY_DRYRUN=1)
# skips the actual call and just logs success — used by tests.

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_NOTIFY_LOCAL_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_NOTIFY_LOCAL_LOADED=1

# Channel signature accepts a trailing profile arg for parity with
# config-reading channels (gotify/slack); local uses no config so the arg
# is unused but the uniform shape lets dispatch call every channel the same.
notify_local() {
  local message="${1:-}" profile="${2:-}"
  if [[ -z "$message" ]]; then
    _notify_log local false "" "empty message" "$profile"
    return 1
  fi

  if [[ "${JARVIS_NOTIFY_DRYRUN:-}" == "1" ]]; then
    _notify_log local true "$message" "" "$profile"
    return 0
  fi

  if command -v osascript >/dev/null 2>&1; then
    # AppleScript string literal: backslash-escape `\` and `"` in $message
    # before interpolating into the `-e` argument. Without this a message
    # body containing a quote (`"`) breaks the script and at the limit lets
    # AppleScript injection through.
    local _osa_msg="${message//\\/\\\\}"
    _osa_msg="${_osa_msg//\"/\\\"}"
    if osascript -e "display notification \"$_osa_msg\" with title \"jarvis\"" \
        >/dev/null 2>&1; then
      _notify_log local true "$message" "" "$profile"
      return 0
    fi
    _notify_log local false "$message" "osascript failed" "$profile"
    return 1
  fi

  if command -v notify-send >/dev/null 2>&1; then
    if notify-send "jarvis" "$message" >/dev/null 2>&1; then
      _notify_log local true "$message" "" "$profile"
      return 0
    fi
    _notify_log local false "$message" "notify-send failed" "$profile"
    return 1
  fi

  _notify_log local false "$message" "no notifier available (osascript or notify-send required)" "$profile"
  return 1
}

notify_register local notify_local
