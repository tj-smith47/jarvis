#!/usr/bin/env bash
# Status dashboard. Aggregates real counts AND the rows behind them
# across tasks, focus.log, reminders, calendar, jira, and notes.
#
# JSON shape is extended additively from the v1 contract — see
# tests/golden/status.json. Existing keys stay; new keys (calendar.*,
# tasks.top, reminders.upcoming, jira.top, focus.current_*, notes.*)
# are added so consumers that read .tasks.open continue to work.
#
# Reminder math: scheduled = pending|active count. next_in_minutes is the
# (rounded) minutes until the soonest future trigger; null when no reminder
# is scheduled. upcoming = top 3 future reminders ascending by trigger_at.
# Streak counts unique calendar days (UTC) with at least one focus
# end-event ending exactly on `today - i` for i = 0,1,2,...
# Focus current_*: derived from the last unpaired `start` row in focus.log,
# null when no in-progress session.
#
# Invocation modes:
#   * via clift router → CLIFT_FLAGS pre-populated
#   * direct bash      → standalone_argv parses --json/--yaml/--profile
# Both paths produce identical output.
set -euo pipefail

# Resolve framework/CLI dirs with fallback so this runs standalone in tests.
: "${FRAMEWORK_DIR:=${CLIFT_FRAMEWORK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}}"
: "${CLI_DIR:=${JARVIS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"

# shellcheck source=/dev/null
source "${FRAMEWORK_DIR}/lib/log/log.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/profile.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/config.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/integrations/jira.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/lock.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/ndjson.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/focus/log.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/cache/file.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/calendar/provider.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/calendar/none.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/calendar/ics.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/calendar/gcalcli.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/calendar/applescript.sh"

# Flag resolution: prefer pre-populated CLIFT_FLAGS; otherwise parse argv
# ourselves via the shared standalone helper so direct-invocation tests get
# identical semantics to the router pipeline.
if ! declare -p CLIFT_FLAGS >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/runtime/standalone_argv.sh"
  jarvis_standalone_argv_parse \
    '[{"name":"json","type":"bool"},{"name":"yaml","type":"bool"},{"name":"profile","type":"string"}]' \
    "$@"
fi

want_json="${CLIFT_FLAGS[json]:-}"
want_yaml="${CLIFT_FLAGS[yaml]:-}"

if [[ "$want_json" == "true" && "$want_yaml" == "true" ]]; then
  clift_exit 2 "--json and --yaml are mutually exclusive"
fi

# state_profile_dir centralizes precedence (CLIFT_FLAGS[profile] >
# CLIFT_FLAG_PROFILE > JARVIS_PROFILE > default) and exports JARVIS_PROFILE.
profile_dir="$(state_profile_dir)"
profile="$JARVIS_PROFILE"

# shellcheck source=/dev/null
source "${CLI_DIR}/lib/native/clock.sh"

# "now" — overridable for deterministic tests; clock helpers honor JARVIS_FAKE_NOW.
now_iso="$(native_now_iso)"
now_epoch="$(native_now_epoch)"
today_date="${now_iso%T*}"

# ------------------------------------------------------------- tasks
tasks_open=0
tasks_done_today=0
tasks_top_json='[]'
if [[ -d "$profile_dir/tasks" ]]; then
  shopt -s nullglob
  task_files=( "$profile_dir/tasks"/*.json )
  shopt -u nullglob
  if (( ${#task_files[@]} > 0 )); then
    rollup="$(jq -s --arg today "$today_date" '
      [.[] | select((.status // "open") == "open")] as $open
      | {open: ($open | length),
         done_today: ([.[] | select((.status // "") == "done"
                                    and ((.done_at // "") | startswith($today)))] | length),
         top: ($open
                | sort_by(.priority // "med", .created_at // "")
                | .[:3]
                | map({slug, title: (.desc // .slug // "(untitled)")}))}' \
      "${task_files[@]}")"
    tasks_open="$(jq -r '.open' <<< "$rollup")"
    tasks_done_today="$(jq -r '.done_today' <<< "$rollup")"
    tasks_top_json="$(jq -c '.top' <<< "$rollup")"
  fi
fi

# ------------------------------------------------------------- focus
# Minutes-today: focus_stats_today_minutes (paired starts/ends).
# Streak: count of consecutive days (today, today-1, ...) with at least
# one end-event.
# Current session: derived from the last unpaired `start` row.
focus_streak=0
focus_minutes_today=0
focus_current_topic="null"
focus_current_minutes="null"
focus_log="$profile_dir/focus.log"
if [[ -f "$focus_log" ]]; then
  focus_minutes_today="$(focus_stats_today_minutes)"

  focus_streak="$(jq -rs --arg today "$today_date" '
    [.[] | select(.event == "end") | (.ts // "")[:10]
         | select(length == 10)] | unique | sort | reverse as $days
    | reduce range(0; ($days | length)) as $i (0;
        if ($days[$i] | strptime("%Y-%m-%d") | mktime) ==
           (($today | strptime("%Y-%m-%d") | mktime) - ($i * 86400))
        then . + 1 else . end)' "$focus_log")"

  # Current session: the last `start` row whose start_ts is not yet paired
  # with a downstream `end` row (focus_orphan_starts already implements
  # this — pick the most-recent if multiple).
  current_start="$(focus_orphan_starts 2>/dev/null | jq -sc 'sort_by(.ts) | last // null')"
  if [[ "$current_start" != "null" ]]; then
    cs_ts="$(jq -r '.ts // empty' <<< "$current_start")"
    cs_topic="$(jq -r '.topic // empty' <<< "$current_start")"
    if [[ -n "$cs_ts" ]]; then
      cs_epoch="$(native_resolve_to_epoch "$cs_ts" 2>/dev/null || printf '0')"
      if [[ "$cs_epoch" != "0" ]]; then
        focus_current_minutes=$(( (now_epoch - cs_epoch + 30) / 60 ))
        if [[ -n "$cs_topic" ]]; then
          focus_current_topic="$(jq -nc --arg t "$cs_topic" '$t')"
        fi
      fi
    fi
  fi
fi

# ------------------------------------------------------------- reminders
reminders_scheduled=0
next_in="null"
next_msg="null"
upcoming_json='[]'
if [[ -d "$profile_dir/reminders" ]]; then
  shopt -s nullglob
  rem_files=( "$profile_dir/reminders"/*.json )
  shopt -u nullglob
  if (( ${#rem_files[@]} > 0 )); then
    rollup="$(jq -s --arg now "$now_iso" '
      [.[] | select((.status // "pending") == "pending"
                    or (.status // "") == "active")] as $sched
      | ($sched | length) as $count
      | ($sched
          | map(select((.trigger_at // "") > $now))
          | sort_by(.trigger_at)) as $future
      | {count: $count,
         next_at: ($future[0].trigger_at // null),
         next_msg: ($future[0].message // $future[0].slug // null),
         upcoming: ($future[:3]
                    | map({trigger_at, message: (.message // .slug // "(no message)")}))}' \
      "${rem_files[@]}")"
    reminders_scheduled="$(jq -r '.count' <<< "$rollup")"
    next_at="$(jq -r '.next_at // empty' <<< "$rollup")"
    if [[ -n "$next_at" ]]; then
      next_epoch="$(native_resolve_to_epoch "$next_at")"
      next_in="$(( (next_epoch - now_epoch + 30) / 60 ))"
      next_msg="$(jq -c '.next_msg' <<< "$rollup")"
    fi
    upcoming_json="$(jq -c '.upcoming' <<< "$rollup")"
  fi
fi

# ------------------------------------------------------------- calendar (next meeting)
# Pre-fix the dashboard had no calendar awareness — the user couldn't
# answer "what's next?" from `status` even though the data was a
# calendar_events call away.
cal_next_in="null"
cal_next_title="null"
cal_next_url="null"
day_start_iso="$(native_day_start "$now_iso")"
day_end_iso="$(native_day_boundary "$day_start_iso" +1d)"
cal_events="$(calendar_events "$now_iso" "$day_end_iso" "$profile" 2>/dev/null || true)"
if [[ -n "$cal_events" ]]; then
  next_event="$(printf '%s\n' "$cal_events" | jq -sc 'sort_by(.start) | first // null')"
  if [[ "$next_event" != "null" ]]; then
    ev_start="$(jq -r '.start // empty' <<< "$next_event")"
    ev_title="$(jq -r '.title // empty' <<< "$next_event")"
    ev_url="$(jq -r '.url // ""' <<< "$next_event")"
    if [[ -n "$ev_start" ]]; then
      ev_epoch="$(native_resolve_to_epoch "$ev_start" 2>/dev/null || printf '0')"
      if [[ "$ev_epoch" != "0" ]]; then
        cal_next_in=$(( (ev_epoch - now_epoch + 30) / 60 ))
        cal_next_title="$(jq -nc --arg t "$ev_title" '$t')"
        if [[ -n "$ev_url" ]]; then
          cal_next_url="$(jq -nc --arg u "$ev_url" '$u')"
        fi
      fi
    fi
  fi
fi

# ------------------------------------------------------------- jira
# Single fetch. command -v short-circuits when jira isn't installed.
jira_count=0
jira_top_json='[]'
if command -v jira >/dev/null 2>&1; then
  if [[ "${CLIFT_FLAGS[verbose]:-}" == "true" ]]; then
    jira_rows="$(jira_in_flight "$profile" || true)"
  else
    jira_rows="$(jira_in_flight "$profile" 2>/dev/null || true)"
  fi
  if [[ -n "$jira_rows" ]]; then
    jira_count="$(printf '%s\n' "$jira_rows" | grep -c .)"
    jira_top_json="$(printf '%s\n' "$jira_rows" | jq -sc 'sort_by(.key) | .[:3] | map({key, summary})')"
  fi
fi

# ------------------------------------------------------------- notes
# Today's daily-note slug + count of distinct notes touched in the past
# week. notes/index.json carries kind, updated_at, archived per row.
notes_daily_today="null"
notes_touched_week=0
if [[ -f "$profile_dir/notes/index.json" ]]; then
  week_ago_iso="$(native_epoch_to_iso $((now_epoch - 7 * 86400)) 2>/dev/null || printf '')"
  notes_rollup="$(jq -c --arg today "$today_date" --arg week_ago "$week_ago_iso" '
    {daily_today: ([.notes[]?
                    | select((.archived // false) == false
                             and (.kind // "") == "daily"
                             and ((.path // "") | endswith($today + ".md")))]
                   | .[0].path // null),
     touched_week: ([.notes[]?
                     | select((.archived // false) == false
                              and (.updated_at // "") >= $week_ago)]
                    | length)}' \
    "$profile_dir/notes/index.json" 2>/dev/null || printf '{}')"
  if [[ -n "$notes_rollup" && "$notes_rollup" != "{}" ]]; then
    daily_path="$(jq -r '.daily_today // empty' <<< "$notes_rollup")"
    if [[ -n "$daily_path" ]]; then
      notes_daily_today="$(jq -nc --arg p "$daily_path" '$p')"
    fi
    notes_touched_week="$(jq -r '.touched_week // 0' <<< "$notes_rollup")"
  fi
fi

# ------------------------------------------------------------- render
_render_json() {
  jq -n \
    --arg profile "$profile" --arg ts "$now_iso" \
    --argjson o  "$tasks_open"           --argjson dt "$tasks_done_today" \
    --argjson tt "$tasks_top_json" \
    --argjson sd "$focus_streak"         --argjson mt "$focus_minutes_today" \
    --argjson fct "$focus_current_topic" --argjson fcm "$focus_current_minutes" \
    --argjson sc "$reminders_scheduled"  --argjson ni "$next_in" \
    --argjson nm "$next_msg" \
    --argjson up "$upcoming_json" \
    --argjson cni "$cal_next_in" --argjson cnt "$cal_next_title" --argjson cnu "$cal_next_url" \
    --argjson inf "$jira_count" --argjson jt "$jira_top_json" \
    --argjson ndt "$notes_daily_today" --argjson ntw "$notes_touched_week" \
    '{profile:$profile, ts:$ts,
      tasks:    {open: $o, done_today: $dt, top: $tt},
      focus:    {streak_days: $sd, minutes_today: $mt,
                 current_topic: $fct, current_minutes: $fcm},
      reminders:{scheduled: $sc, next_in_minutes: $ni, next_message: $nm,
                 upcoming: $up},
      calendar: {next_in_minutes: $cni, next_title: $cnt, next_url: $cnu},
      jira:     {in_flight: $inf, top: $jt},
      notes:    {daily_today: $ndt, touched_this_week: $ntw}}'
}

if [[ "$want_json" == "true" ]]; then
  _render_json
  exit 0
fi

if [[ "$want_yaml" == "true" ]]; then
  _render_json | yq -P eval '.' -
  exit 0
fi

# Default: pretty dashboard. Each section gets a header line that carries
# the count, then the actual rows underneath.
if declare -F log_info >/dev/null 2>&1; then
  log_info "Dashboard ($profile)"
else
  printf 'info: Dashboard (%s)\n' "$profile"
fi

# Tasks
printf '\n  \033[1mTasks\033[0m  %d open · %d done today\n' \
  "$tasks_open" "$tasks_done_today"
if [[ "$tasks_top_json" != "[]" ]]; then
  printf '%s\n' "$tasks_top_json" | jq -r '.[] | "    - " + .title'
fi

# Calendar / next meeting
if [[ "$cal_next_in" != "null" ]]; then
  next_title_str="$(jq -r . <<< "$cal_next_title")"
  next_url_str="$(jq -r '. // ""' <<< "$cal_next_url")"
  printf '\n  \033[1mNext meeting\033[0m  in %sm  %s' "$cal_next_in" "$next_title_str"
  [[ -n "$next_url_str" ]] && printf '  %s' "$next_url_str"
  printf '\n'
fi

# Reminders
if [[ "$next_in" == "null" ]]; then
  printf '\n  \033[1mReminders\033[0m  %d scheduled\n' "$reminders_scheduled"
else
  next_msg_pretty="$(jq -r . <<< "$next_msg")"
  printf '\n  \033[1mReminders\033[0m  %d scheduled · next in %sm: %s\n' \
    "$reminders_scheduled" "$next_in" "$next_msg_pretty"
  if [[ "$upcoming_json" != "[]" ]]; then
    printf '%s\n' "$upcoming_json" | jq -r '.[] |
      "    " + (.trigger_at | sub("^.*T"; "") | sub(":[0-9]+Z?$"; "")) +
      "  " + .message'
  fi
fi

# Focus
if [[ "$focus_current_minutes" != "null" ]]; then
  cur_topic_str="$(jq -r 'if . == null then "" else . end' <<< "$focus_current_topic")"
  printf '\n  \033[1mFocus\033[0m  streak %dd \xf0\x9f\x94\xa5 · today %dm · in progress: %sm' \
    "$focus_streak" "$focus_minutes_today" "$focus_current_minutes"
  [[ -n "$cur_topic_str" ]] && printf ' on %s' "$cur_topic_str"
  printf '\n'
else
  printf '\n  \033[1mFocus\033[0m  streak %dd \xf0\x9f\x94\xa5 · today %d min\n' \
    "$focus_streak" "$focus_minutes_today"
fi

# Notes
if [[ "$notes_daily_today" != "null" || "$notes_touched_week" -gt 0 ]]; then
  printf '\n  \033[1mNotes\033[0m'
  if [[ "$notes_daily_today" != "null" ]]; then
    daily_str="$(jq -r . <<< "$notes_daily_today")"
    # Strip "notes/daily/" prefix and ".md" suffix for display
    daily_display="${daily_str##*/}"
    daily_display="${daily_display%.md}"
    printf '  daily: %s' "$daily_display"
  fi
  if [[ "$notes_touched_week" -gt 0 ]]; then
    printf '  ·  %d touched this week' "$notes_touched_week"
  fi
  printf '\n'
fi

# Jira
if (( jira_count > 0 )); then
  printf '\n  \033[1mJira\033[0m  %d in flight\n' "$jira_count"
  if [[ "$jira_top_json" != "[]" ]]; then
    printf '%s\n' "$jira_top_json" | jq -r '.[] | "    [" + .key + "]  " + .summary'
  fi
fi

printf '\n'
