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
  local primary secondary pager
  primary="$(config_get oncall.primary "" "$profile")"
  secondary="$(config_get oncall.secondary "" "$profile")"
  pager="$(config_get oncall.pager "" "$profile")"

  if [[ -n "$primary" ]]; then
    if [[ -n "$pager" ]]; then
      jq -nc --arg w "$primary" --arg p "$pager" '{role:"primary", who:$w, pager:$p}'
    else
      jq -nc --arg w "$primary" '{role:"primary", who:$w}'
    fi
  fi
  if [[ -n "$secondary" ]]; then
    jq -nc --arg w "$secondary" '{role:"secondary", who:$w}'
  fi
}
