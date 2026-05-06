#!/usr/bin/env bash
# Reminder spec parsers — pure functions for the three time/cadence inputs.
#
# Outputs that include a moment in time are always UTC ISO-8601
# (YYYY-MM-DDTHH:MM:SSZ). Anchored repeat parsing happens elsewhere
# (lib/remind/schedule.sh); this file only canonicalizes the spec strings.
#
# Tests pin "now" via JARVIS_FAKE_NOW (UTC ISO). Production reads system clock.

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_REMIND_PARSE_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_REMIND_PARSE_LOADED=1

# _remind_now_epoch — UTC seconds-since-epoch; honors JARVIS_FAKE_NOW.
# Returns 2 + named error if JARVIS_FAKE_NOW is set but unparseable, so callers
# never see empty stdout silently flowing into arithmetic.
_remind_now_epoch() {
  local out
  if [[ -n "${JARVIS_FAKE_NOW:-}" ]]; then
    out="$(date -u -d "$JARVIS_FAKE_NOW" +%s 2>/dev/null)" \
      || out="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$JARVIS_FAKE_NOW" +%s 2>/dev/null)"
    if [[ -z "$out" ]]; then
      printf '_remind_now_epoch: cannot parse JARVIS_FAKE_NOW=%q\n' "$JARVIS_FAKE_NOW" >&2
      return 2
    fi
  else
    out="$(date -u +%s)"
  fi
  printf '%s\n' "$out"
}

_remind_epoch_to_iso() {
  local out
  out="$(date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" \
    || out="$(date -u -j -f %s "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  if [[ -z "$out" ]]; then
    printf '_remind_epoch_to_iso: cannot convert epoch %q\n' "$1" >&2
    return 2
  fi
  printf '%s\n' "$out"
}

# remind_parse_in <duration>
# duration ∈ Ns | Nm | Nh | Nd. Echoes "now + duration" as UTC ISO.
remind_parse_in() {
  local d="${1:-}"
  if [[ ! "$d" =~ ^([0-9]+)([smhd])$ ]]; then
    printf 'remind_parse_in: bad duration "%s" (expected Ns|Nm|Nh|Nd)\n' "$d" >&2
    return 2
  fi
  local n="${BASH_REMATCH[1]}" u="${BASH_REMATCH[2]}" mult
  case "$u" in
    s) mult=1 ;;
    m) mult=60 ;;
    h) mult=3600 ;;
    d) mult=86400 ;;
  esac
  _remind_epoch_to_iso "$(( $(_remind_now_epoch) + n * mult ))"
}

# remind_parse_at <spec>
# spec is "HH:MM" (24h, today/tomorrow rule) or "YYYY-MM-DD HH:MM" (absolute).
# HH:MM in the past today rolls forward to the same wall-clock tomorrow.
# Absolute past → exit 2 (we won't second-guess an explicit date).
remind_parse_at() {
  local spec="${1:-}" now_e target_e today
  now_e="$(_remind_now_epoch)"

  if [[ "$spec" =~ ^([0-2][0-9]):([0-5][0-9])$ ]]; then
    today="$(date -d "@$now_e" +%Y-%m-%d 2>/dev/null \
             || date -j -f %s "$now_e" +%Y-%m-%d)"
    target_e="$(date -d "${today} ${spec}" +%s 2>/dev/null \
                || date -j -f "%Y-%m-%d %H:%M" "${today} ${spec}" +%s)"
    if (( target_e <= now_e )); then
      # GNU date "+1 day" miscomputes wall-clock under TZ=UTC; "tomorrow"
      # is the literal-day form that does the right thing on both GNU and
      # BSD date. BSD path goes through `-v+1d` which is well-defined.
      target_e="$(date -d "${today} ${spec} tomorrow" +%s 2>/dev/null \
                  || date -j -v+1d -f "%Y-%m-%d %H:%M" "${today} ${spec}" +%s)"
    fi
    _remind_epoch_to_iso "$target_e"
    return 0
  fi

  if [[ "$spec" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})\ ([0-2][0-9]:[0-5][0-9])$ ]]; then
    target_e="$(date -d "$spec" +%s 2>/dev/null \
                || date -j -f "%Y-%m-%d %H:%M" "$spec" +%s)"
    if [[ -z "$target_e" ]]; then
      printf 'remind_parse_at: could not parse "%s"\n' "$spec" >&2
      return 2
    fi
    if (( target_e < now_e )); then
      printf 'remind_parse_at: --at %s is in the past; specify a future date\n' "$spec" >&2
      return 2
    fi
    _remind_epoch_to_iso "$target_e"
    return 0
  fi

  printf 'remind_parse_at: bad spec "%s" (expected HH:MM or "YYYY-MM-DD HH:MM")\n' "$spec" >&2
  return 2
}

# remind_parse_repeat <spec>
# Returns canonical token: daily | weekly | weekdays | weekends | <Ns|m|h|d> |
# sorted day-list (subset of mon,tue,wed,thu,fri,sat,sun).
remind_parse_repeat() {
  local spec="${1:-}"
  case "$spec" in
    daily|weekly|weekdays|weekends)
      printf '%s\n' "$spec"; return 0
      ;;
  esac
  if [[ "$spec" =~ ^[0-9]+[smhd]$ ]]; then
    printf '%s\n' "$spec"; return 0
  fi
  if [[ "$spec" =~ ^(mon|tue|wed|thu|fri|sat|sun)(,(mon|tue|wed|thu|fri|sat|sun))*$ ]]; then
    printf '%s\n' "$spec" \
      | tr ',' '\n' \
      | awk 'BEGIN{w["mon"]=1;w["tue"]=2;w["wed"]=3;w["thu"]=4;w["fri"]=5;w["sat"]=6;w["sun"]=7}
             {print w[$1] " " $1}' \
      | sort -k1,1n \
      | awk '{print $2}' \
      | paste -sd, -
    return 0
  fi
  printf 'remind_parse_repeat: bad repeat spec "%s"\n' "$spec" >&2
  return 2
}
