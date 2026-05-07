#!/usr/bin/env bash
# Oncall integration — config-only. Reads [oncall] primary, secondary, pager
# from <profile>/config.toml and emits NDJSON.

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_INTEGRATIONS_ONCALL_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_INTEGRATIONS_ONCALL_LOADED=1

oncall_show() {
  local profile="${1:-${JARVIS_PROFILE:-default}}"
  local primary secondary pager until
  primary="$(config_get oncall.primary "" "$profile")"
  secondary="$(config_get oncall.secondary "" "$profile")"
  pager="$(config_get oncall.pager "" "$profile")"
  # `until` (rotation expiry) closes the "should I take this big task on?"
  # question — the static schema captured who is on, but never until when.
  until="$(config_get oncall.until "" "$profile")"

  if [[ -n "$primary" ]]; then
    jq -nc --arg w "$primary" --arg p "$pager" --arg u "$until" \
      '{role:"primary", who:$w}
       + (if $p != "" then {pager:$p} else {} end)
       + (if $u != "" then {until:$u} else {} end)'
  fi
  if [[ -n "$secondary" ]]; then
    jq -nc --arg w "$secondary" --arg u "$until" \
      '{role:"secondary", who:$w}
       + (if $u != "" then {until:$u} else {} end)'
  fi
}
