#!/usr/bin/env bash
# Calendar provider dispatcher.
#
# Providers register at source-time:
#   calendar_register <name> <fn>
#
# Mirrors lib/notify/registry.sh — same registry pattern, so adding a new
# calendar source (gcalcli, ics, caldav) is a single file + register call,
# no churn at the dispatch site.
#
# calendar_events <since_iso> <until_iso> [profile]
#   Reads [calendar] provider from config (default 'none'), routes through
#   the file cache (key 'calendar', TTL 300s). Cache hit -> emit cached
#   bytes. Miss -> invoke registered fn, capture stdout, cache_put on
#   success, then emit. Provider exit 1 -> no cache write, no output.
#   Unknown provider -> exit 0 + stderr warning (treat as 'none').

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_CALENDAR_PROVIDER_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_CALENDAR_PROVIDER_LOADED=1

declare -gA _CALENDAR_PROVIDERS=()

calendar_register() {
  local name="$1" fn="$2"
  if [[ -z "$name" || -z "$fn" ]]; then
    printf 'calendar_register: usage calendar_register <name> <fn>\n' >&2
    return 2
  fi
  _CALENDAR_PROVIDERS["$name"]="$fn"
}

# calendar_providers — registered provider names, one per line, sorted.
calendar_providers() {
  if (( ${#_CALENDAR_PROVIDERS[@]} == 0 )); then
    return 0
  fi
  printf '%s\n' "${!_CALENDAR_PROVIDERS[@]}" | sort
}

# Cache writes use temp+mv (atomic). Concurrent misses may double-fetch;
# tolerated because cache_put is idempotent and TTL is coarse (300s).
# Provider stderr is suppressed here — brief/standup are user-facing surfaces;
# `jarvis doctor` invokes providers directly to surface diagnostics.
#
# Capture flow uses temp files instead of `out=$(...)` so trailing newlines
# survive the round-trip (drains T2-W2 from .claude/known-bugs.md).
calendar_events() {
  local since="$1" until="$2" profile="${3:-${JARVIS_PROFILE:-default}}"
  local provider fn
  provider="$(config_get calendar.provider none "$profile")"
  if [[ "$provider" == "none" ]]; then
    return 0
  fi
  fn="${_CALENDAR_PROVIDERS[$provider]:-}"
  if [[ -z "$fn" ]]; then
    printf "calendar: unknown provider '%s' (configured under [calendar] provider)\n" "$provider" >&2
    return 0
  fi
  # Cache hit -> stream the cached bytes through cat (preserves trailing
  # newline that command substitution would strip).
  if cache_get "$profile" calendar 300 2>/dev/null; then
    return 0
  fi
  # Cache miss -> capture provider stdout in a temp file (NOT a shell var)
  # so the bytes round-trip into the cache and back out unchanged.
  local tmp_provider
  tmp_provider="$(mktemp)" || return 0
  if ! "$fn" "$since" "$until" "$profile" >"$tmp_provider" 2>/dev/null; then
    rm -f "$tmp_provider"
    return 0
  fi
  cache_put_file "$profile" calendar "$tmp_provider"
  cat "$tmp_provider"
  rm -f "$tmp_provider"
}
