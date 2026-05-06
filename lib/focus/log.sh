#!/usr/bin/env bash
# Focus log primitives for jarvis.
# Builds on state/{profile,lock,ndjson}.sh — caller must source those first.
#
# Schema: append-only NDJSON at $JARVIS_HOME/<profile>/focus.log.
# Rows are one of:
#   {"ts":"…","event":"start","duration":"25m","topic":"…"|null}
#   {"ts":"…","event":"end","topic":"…"|null}
#   {"ts":"…","event":"coffee"}
#
# Pairing rule (load-bearing): an `end` matches the most-recent unended
# `start` WITH THE SAME TOPIC. Same-topic concurrent sessions are degenerate
# and unsupported (single-user spec). Topic-pair handles long-running +
# pomodoro overlap without a PID field.
#
# No `completed` field. End-row presence IS completion. SIGKILL/power loss
# leaves an orphan start; surfaced by `doctor`, never papered over here.

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_FOCUS_LOG_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_FOCUS_LOG_LOADED=1

focus_log_path() {
  printf '%s/focus.log\n' "$(state_profile_dir)"
}

_focus_now_iso() {
  if [[ -n "${JARVIS_FAKE_NOW:-}" ]]; then
    printf '%s\n' "$JARVIS_FAKE_NOW"
  else
    date -u +%Y-%m-%dT%H:%M:%SZ
  fi
}

# focus_log_append <event> <duration> <topic>
# event ∈ {start, end}; coffee uses focus_log_append_coffee.
# Empty topic → JSON null. End rows omit `duration`.
focus_log_append() {
  local event="$1" duration="${2:-}" topic="${3:-}"
  local ts payload
  ts="$(_focus_now_iso)"

  case "$event" in
    start)
      payload="$(jq -nc \
        --arg ts "$ts" \
        --arg duration "$duration" \
        --arg topic "$topic" \
        '{ts: $ts, event: "start", duration: $duration,
          topic: (if $topic == "" then null else $topic end)}')"
      ;;
    end)
      payload="$(jq -nc \
        --arg ts "$ts" \
        --arg topic "$topic" \
        '{ts: $ts, event: "end",
          topic: (if $topic == "" then null else $topic end)}')"
      ;;
    *)
      printf 'focus_log_append: invalid event "%s" (expected start|end)\n' "$event" >&2
      return 2
      ;;
  esac

  ndjson_append "$(focus_log_path)" "$payload"
}

focus_log_append_coffee() {
  local ts payload
  ts="$(_focus_now_iso)"
  payload="$(jq -nc --arg ts "$ts" '{ts: $ts, event: "coffee"}')"
  ndjson_append "$(focus_log_path)" "$payload"
}

# Single jq pass: builds a topic-keyed stack of open starts; each end pops
# the matching topic's most-recent open and emits a paired record. Coffee
# rows pass through unmatched (the else branch is a no-op). Orphan starts
# stay in the .open map and are dropped (this filter is for completed
# sessions only — see focus_orphan_starts for the complement).
# shellcheck disable=SC2016  # jq filter — $row, $s are jq vars, not shell.
_focus_pair_filter='
  reduce .[] as $row (
    {open: {}, pairs: []};
    if $row.event == "start" then
      .open[$row.topic // ""] = ((.open[$row.topic // ""] // []) + [$row])
    elif $row.event == "end" then
      if ((.open[$row.topic // ""] // []) | length) > 0 then
        ((.open[$row.topic // ""] | last) as $s
         | .pairs += [{start: $s, end: $row}]
         | .open[$row.topic // ""] |= .[:-1])
      else . end
    else . end
  )
  | .pairs[]
  | {
      start_ts: .start.ts,
      end_ts:   .end.ts,
      duration: .start.duration,
      topic:    .start.topic,
      elapsed_seconds: ((.end.ts | fromdateiso8601) - (.start.ts | fromdateiso8601))
    }
'

# shellcheck disable=SC2016  # jq filter — $row is a jq var, not shell.
_focus_orphan_filter='
  reduce .[] as $row (
    {open: {}};
    if $row.event == "start" then
      .open[$row.topic // ""] = ((.open[$row.topic // ""] // []) + [$row])
    elif $row.event == "end" then
      if ((.open[$row.topic // ""] // []) | length) > 0 then
        .open[$row.topic // ""] |= .[:-1]
      else . end
    else . end
  )
  | .open
  | to_entries
  | map(.value[])
  | .[]
'

focus_session_pairs() {
  local content
  content="$(ndjson_read "$(focus_log_path)")"
  [[ -z "$content" ]] && return 0
  jq -c -s "$_focus_pair_filter" <<< "$content"
}

focus_orphan_starts() {
  local content
  content="$(ndjson_read "$(focus_log_path)")"
  [[ -z "$content" ]] && return 0
  jq -c -s "$_focus_orphan_filter" <<< "$content"
}

# Local-day boundary used by today-scoped stats. Honors $TZ via the date
# command's process environment AND $JARVIS_FAKE_NOW (UTC ISO-8601) for
# deterministic tests + dashboards under fake-clock.
_focus_today_local() {
  if [[ -n "${JARVIS_FAKE_NOW:-}" ]]; then
    date -d "$JARVIS_FAKE_NOW" +%Y-%m-%d 2>/dev/null \
      || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$JARVIS_FAKE_NOW" +%Y-%m-%d
  else
    date +%Y-%m-%d
  fi
}

# Sum elapsed_seconds for paired sessions whose start_ts is today (local
# tz), then convert to whole minutes (floor). Coffee rows excluded by
# construction (they're not pairs). Orphan starts excluded (no pair).
focus_stats_today_minutes() {
  local pairs today
  pairs="$(focus_session_pairs)"
  if [[ -z "$pairs" ]]; then
    printf '0\n'
    return 0
  fi
  today="$(_focus_today_local)"
  jq -s --arg today "$today" '
    map(select((.start_ts | fromdateiso8601 | strftime("%Y-%m-%d")) == $today))
    | (map(.elapsed_seconds) | add // 0)
    | (. / 60 | floor)
  ' <<< "$pairs"
}

# Count of "things that happened today" — paired sessions + coffee rows.
# Pairs are counted by start_ts; coffee by its single ts.
focus_stats_sessions_today() {
  local content today pairs_today coffee_today
  content="$(ndjson_read "$(focus_log_path)")"
  if [[ -z "$content" ]]; then
    printf '0\n'
    return 0
  fi
  today="$(_focus_today_local)"

  local pairs
  pairs="$(focus_session_pairs)"
  if [[ -n "$pairs" ]]; then
    pairs_today="$(jq -s --arg today "$today" '
      map(select((.start_ts | fromdateiso8601 | strftime("%Y-%m-%d")) == $today))
      | length' <<< "$pairs")"
  else
    pairs_today=0
  fi

  coffee_today="$(jq -s --arg today "$today" '
    map(select(.event == "coffee"
        and (.ts | fromdateiso8601 | strftime("%Y-%m-%d")) == $today))
    | length' <<< "$content")"

  printf '%s\n' "$(( pairs_today + coffee_today ))"
}

# Top topics by minutes over the last N days (default 7), capped at LIMIT
# (default 5). Null/empty topics excluded. Output: JSON array sorted by
# minutes desc.
focus_stats_top_topics() {
  local days=7 limit=5
  while (( $# )); do
    case "$1" in
      --days)  days="$2";  shift 2 ;;
      --limit) limit="$2"; shift 2 ;;
      *)
        printf 'focus_stats_top_topics: unknown arg "%s"\n' "$1" >&2
        return 2
        ;;
    esac
  done

  local pairs
  pairs="$(focus_session_pairs)"
  if [[ -z "$pairs" ]]; then
    printf '[]\n'
    return 0
  fi

  # When JARVIS_FAKE_NOW is set, the test clock has shifted but jq's
  # `now` builtin still reads the system clock — pass an explicit epoch
  # so the cutoff window aligns with seeded timestamps.
  local now_epoch
  if [[ -n "${JARVIS_FAKE_NOW:-}" ]]; then
    now_epoch="$(jq -nr --arg t "$JARVIS_FAKE_NOW" '$t | fromdateiso8601')"
  else
    now_epoch="$(date +%s)"
  fi

  jq -sc --argjson days "$days" --argjson limit "$limit" --argjson now "$now_epoch" '
    ($now - ($days * 86400)) as $cutoff
    | map(select((.start_ts | fromdateiso8601) >= $cutoff
                 and (.topic // "") != ""))
    | group_by(.topic)
    | map({
        topic:    .[0].topic,
        minutes:  ((map(.elapsed_seconds) | add) / 60 | floor),
        sessions: length
      })
    | sort_by(-.minutes)
    | .[:$limit]
  ' <<< "$pairs"
}
