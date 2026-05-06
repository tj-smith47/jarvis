#!/usr/bin/env bash
# No-op calendar provider — always empty.
# Default when [calendar] provider is unset; also the explicit "I don't
# want a calendar source wired up" choice.

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_CALENDAR_NONE_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_CALENDAR_NONE_LOADED=1

calendar_none_events() { return 0; }

calendar_register none calendar_none_events
