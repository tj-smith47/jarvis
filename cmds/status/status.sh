#!/usr/bin/env bash
# Status dashboard. Aggregates real counts across tasks, focus.log,
# reminders, and jira, and renders pretty / YAML / JSON.
#
# The --json shape is the frozen contract — see tests/golden/status.json.
# Reminder math: scheduled = pending|active count. next_in_minutes is the
# (rounded) minutes until the soonest future trigger; null when no reminder
# is scheduled. Streak counts unique calendar days (UTC) with at least one
# focus end-event ending exactly on `today - i` for i = 0,1,2,...
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
if [[ -d "$profile_dir/tasks" ]]; then
  shopt -s nullglob
  task_files=( "$profile_dir/tasks"/*.json )
  shopt -u nullglob
  if (( ${#task_files[@]} > 0 )); then
    # Single jq call over all task files — avoids per-file fork.
    counts="$(jq -s --arg today "$today_date" \
      '{open: ([.[] | select((.status // "open") == "open")] | length),
        done_today: ([.[] | select((.status // "") == "done"
                                    and ((.done_at // "") | startswith($today)))] | length)}' \
      "${task_files[@]}")"
    tasks_open="$(jq -r '.open' <<< "$counts")"
    tasks_done_today="$(jq -r '.done_today' <<< "$counts")"
  fi
fi

# ------------------------------------------------------------- focus
# Minutes-today goes through focus_stats_today_minutes (paired start/end
# with elapsed_seconds), which honors JARVIS_FAKE_NOW via _focus_today_local.
# Streak counts unique calendar days with at least one end-event.
focus_streak=0
focus_minutes_today=0
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
fi

# ------------------------------------------------------------- reminders
reminders_scheduled=0
next_in="null"      # JSON literal — emitted as --argjson
next_msg="null"     # JSON literal (string-quoted via jq -Rs when present)
if [[ -d "$profile_dir/reminders" ]]; then
  shopt -s nullglob
  rem_files=( "$profile_dir/reminders"/*.json )
  shopt -u nullglob
  if (( ${#rem_files[@]} > 0 )); then
    # Aggregate: scheduled count + soonest future trigger in one jq pass.
    rollup="$(jq -s --arg now "$now_iso" '
      [.[] | select((.status // "pending") == "pending"
                    or (.status // "") == "active")] as $sched
      | ($sched | length) as $count
      | ($sched
          | map(select((.trigger_at // "") > $now))
          | sort_by(.trigger_at)
          | first) as $next
      | {count: $count,
         next_at: ($next.trigger_at // null),
         next_msg: ($next.message // $next.slug // null)}' \
      "${rem_files[@]}")"
    reminders_scheduled="$(jq -r '.count' <<< "$rollup")"
    next_at="$(jq -r '.next_at // empty' <<< "$rollup")"
    if [[ -n "$next_at" ]]; then
      next_epoch="$(native_resolve_to_epoch "$next_at")"
      next_in="$(( (next_epoch - now_epoch + 30) / 60 ))"
      next_msg="$(jq -c '.next_msg' <<< "$rollup")"
    fi
  fi
fi

# ------------------------------------------------------------- jira
# Single fetch — was double-called for stderr suppression; collapsed to one
# round-trip. `command -v` short-circuits when jira isn't installed (normal
# state); the fetch itself silences stderr because status is hot-path UX
# (auth/network failures surface in `jarvis doctor`, not the dashboard).
jira_count=0
if command -v jira >/dev/null 2>&1; then
  # `--verbose` lets jira's stderr through so auth/network failures are
  # visible — default stays silent because status is hot-path UX.
  if [[ "${CLIFT_FLAGS[verbose]:-}" == "true" ]]; then
    jira_count="$(jira_in_flight "$profile" | grep -c . || true)"
  else
    jira_count="$(jira_in_flight "$profile" 2>/dev/null | grep -c . || true)"
  fi
fi

# ------------------------------------------------------------- render
if [[ "$want_json" == "true" ]]; then
  jq -n \
    --arg profile "$profile" --arg ts "$now_iso" \
    --argjson o  "$tasks_open"           --argjson dt "$tasks_done_today" \
    --argjson sd "$focus_streak"         --argjson mt "$focus_minutes_today" \
    --argjson sc "$reminders_scheduled"  --argjson ni "$next_in" \
    --argjson nm "$next_msg"             --argjson if "$jira_count" \
    '{profile:$profile, ts:$ts,
      tasks:    {open: $o,           done_today:      $dt},
      focus:    {streak_days: $sd,   minutes_today:   $mt},
      reminders:{scheduled: $sc,     next_in_minutes: $ni, next_message: $nm},
      jira:     {in_flight: $if}}'
  exit 0
fi

if [[ "$want_yaml" == "true" ]]; then
  jq -n \
    --arg profile "$profile" --arg ts "$now_iso" \
    --argjson o  "$tasks_open"           --argjson dt "$tasks_done_today" \
    --argjson sd "$focus_streak"         --argjson mt "$focus_minutes_today" \
    --argjson sc "$reminders_scheduled"  --argjson ni "$next_in" \
    --argjson nm "$next_msg"             --argjson if "$jira_count" \
    '{profile:$profile, ts:$ts,
      tasks:    {open: $o,           done_today:      $dt},
      focus:    {streak_days: $sd,   minutes_today:   $mt},
      reminders:{scheduled: $sc,     next_in_minutes: $ni, next_message: $nm},
      jira:     {in_flight: $if}}' \
    | yq -P eval '.' -
  exit 0
fi

# Default: pretty dashboard.
if declare -F log_info >/dev/null 2>&1; then
  log_info "Dashboard ($profile)"
else
  printf 'info: Dashboard (%s)\n' "$profile"
fi
printf '\n  \033[1mTasks\033[0m\n'
printf '    open           %d\n' "$tasks_open"
printf '    done today     %d\n\n' "$tasks_done_today"

printf '  \033[1mReminders\033[0m\n'
if [[ "$next_in" == "null" ]]; then
  printf '    scheduled      %d\n\n' "$reminders_scheduled"
else
  # next_msg is a JSON string at this point — strip quotes via jq -r for display.
  next_msg_pretty="$(jq -r . <<< "$next_msg")"
  printf '    scheduled      %d\n' "$reminders_scheduled"
  printf '    next           %sm  %s\n\n' "$next_in" "$next_msg_pretty"
fi

printf '  \033[1mFocus\033[0m\n'
printf '    streak         %d days  \xf0\x9f\x94\xa5\n' "$focus_streak"
printf '    today          %d min\n\n' "$focus_minutes_today"

if (( jira_count > 0 )); then
  printf '  \033[1mJira\033[0m\n'
  printf '    in flight      %d\n\n' "$jira_count"
fi
