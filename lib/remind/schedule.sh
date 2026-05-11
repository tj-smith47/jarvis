#!/usr/bin/env bash
# Pure: compute next trigger ISO from (repeat, anchor, after).
#
# Interval forms (Ns|Nm|Nh|Nd) add seconds in pure UTC.
# Anchored forms (daily|weekly|weekdays|weekends|<day-list>) compute the next
# wall-clock occurrence in $TZ (default UTC). DST handling:
#   - Spring-forward gap (anchor falls in non-existent local time): skip the
#     day, walk to the next valid candidate. GNU/BSD `date -d` does NOT error
#     on gap times — it silently rolls forward to the next valid instant
#     (e.g. 02:30 → 03:30 EDT). We detect this by round-tripping the parsed
#     epoch back to local %H:%M and rejecting the mismatch.
#   - Fall-back ambiguity (anchor falls in repeated local time): pick the
#     first occurrence (matches GNU/BSD `date` defaults).

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_REMIND_SCHEDULE_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_REMIND_SCHEDULE_LOADED=1

# _rs_to_epoch <iso-or-spec> — portable date→epoch in UTC.
# Returns 2 + named error if every parse form yields empty stdout (so callers
# never silently see epoch-0 on bad input).
_rs_to_epoch() {
  local out
  out="$(date -u -d "$1" +%s 2>/dev/null)" \
    || out="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null)" \
    || out="$(date -u -j -f "%Y-%m-%d %H:%M" "$1" +%s 2>/dev/null)"
  if [[ -z "$out" ]]; then
    printf '_rs_to_epoch: could not parse "%s"\n' "$1" >&2
    return 2
  fi
  printf '%s\n' "$out"
}

_rs_epoch_to_iso() {
  local out
  out="$(date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" \
    || out="$(date -u -j -f %s "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  if [[ -z "$out" ]]; then
    printf '_rs_epoch_to_iso: could not convert epoch %q\n' "$1" >&2
    return 2
  fi
  printf '%s\n' "$out"
}

_rs_dow() { # 1=Mon..7=Sun, in current $TZ
  date -d "@$1" +%u 2>/dev/null || date -j -f %s "$1" +%u
}

_rs_local_date() {
  date -d "@$1" +%Y-%m-%d 2>/dev/null || date -j -f %s "$1" +%Y-%m-%d
}

# _rs_local_to_epoch "<YYYY-MM-DD HH:MM>" — local-tz spec → epoch.
# Returns 2 with empty stdout when the local time doesn't exist (DST gap),
# letting the caller skip the day.
#
# GNU/BSD `date` does not raise on gap times — they silently roll forward
# to the next valid instant. We round-trip the parsed epoch back to local
# %H:%M and compare to the requested anchor; mismatch → gap → return 2.
_rs_local_to_epoch() {
  local spec="$1" out roundtrip want_hm
  out="$(date -d "$spec" +%s 2>/dev/null)" \
    || out="$(date -j -f "%Y-%m-%d %H:%M" "$spec" +%s 2>/dev/null)"
  if [[ -z "$out" ]]; then
    return 2
  fi
  # want_hm is the trailing HH:MM token of the local spec. Split on the
  # last space rather than indexing fixed offsets so a future caller can
  # pass alternative date formats without resilencing the guard.
  want_hm="${spec##* }"
  roundtrip="$(date -d "@$out" +%H:%M 2>/dev/null \
            || date -j -f %s "$out" +%H:%M 2>/dev/null)"
  if [[ -z "$roundtrip" || "$roundtrip" != "$want_hm" ]]; then
    return 2
  fi
  printf '%s\n' "$out"
}

remind_next_trigger() {
  local repeat="${1:-}" anchor="${2:-}" after="${3:-}"

  if [[ -z "$repeat" ]]; then
    printf 'remind_next_trigger: empty repeat spec\n' >&2
    return 2
  fi

  local after_e
  after_e="$(_rs_to_epoch "$after")" || return 2

  # Interval form
  if [[ "$repeat" =~ ^([0-9]+)([smhd])$ ]]; then
    local n="${BASH_REMATCH[1]}" u="${BASH_REMATCH[2]}" mult
    case "$u" in
      s) mult=1 ;;
      m) mult=60 ;;
      h) mult=3600 ;;
      d) mult=86400 ;;
    esac
    _rs_epoch_to_iso "$(( after_e + n * mult ))"
    return 0
  fi

  # Anchored forms
  if [[ -z "$anchor" ]]; then
    printf 'remind_next_trigger: anchored repeat "%s" needs HH:MM anchor\n' "$repeat" >&2
    return 2
  fi

  local match_dow=""
  case "$repeat" in
    daily)    match_dow="1,2,3,4,5,6,7" ;;
    weekly)   match_dow="$(_rs_dow "$after_e")" ;;
    weekdays) match_dow="1,2,3,4,5" ;;
    weekends) match_dow="6,7" ;;
    *)
      if [[ ! "$repeat" =~ ^(mon|tue|wed|thu|fri|sat|sun)(,(mon|tue|wed|thu|fri|sat|sun))*$ ]]; then
        printf 'remind_next_trigger: bad repeat spec "%s"\n' "$repeat" >&2
        return 2
      fi
      match_dow="$(printf '%s' "$repeat" \
        | tr ',' '\n' \
        | awk '{m["mon"]=1;m["tue"]=2;m["wed"]=3;m["thu"]=4;m["fri"]=5;m["sat"]=6;m["sun"]=7; print m[$0]}' \
        | paste -sd, -)"
      ;;
  esac

  # Walk forward up to 8 days; pick first matching wall-clock instant strictly
  # after `after_e`. 8 days covers the worst case (weekly 7-day wrap).
  local i d_e cand_e cand_dow
  for ((i=0; i<8; i++)); do
    d_e="$(( after_e + i * 86400 ))"
    cand_e="$(_rs_local_to_epoch "$(_rs_local_date "$d_e") $anchor" 2>/dev/null)" || continue
    [[ -z "$cand_e" ]] && continue
    [[ "$cand_e" -le "$after_e" ]] && continue
    cand_dow="$(_rs_dow "$cand_e")"
    if [[ ",$match_dow," == *",$cand_dow,"* ]]; then
      _rs_epoch_to_iso "$cand_e"
      return 0
    fi
  done
  printf 'remind_next_trigger: no match within 8 days for "%s"\n' "$repeat" >&2
  return 2
}
