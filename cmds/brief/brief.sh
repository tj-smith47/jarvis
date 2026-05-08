#!/usr/bin/env bash
# Morning briefing. Aggregates Calendar / PRs / Jira / Deploys / Oncall via
# the integration libs (T1-T9) and renders pretty (default) or one-line
# (--short). Section gating: a section is hidden if its lib emits no rows
# (tool missing, no config, empty result).
#
# --short shape is the frozen contract — see tests/fixtures/brief-short.txt.
#
# Invocation modes:
#   * via clift router → CLIFT_FLAGS pre-populated
#   * direct bash      → standalone_argv parses --short / --skip-* / --profile
# Both paths produce identical output.
set -euo pipefail

# Resolve framework/CLI dirs with fallback so this runs standalone in tests.
: "${FRAMEWORK_DIR:=${CLIFT_FRAMEWORK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}}"
: "${CLI_DIR:=${JARVIS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"

# shellcheck source=/dev/null
source "${FRAMEWORK_DIR}/lib/log/log.sh"

# Flag resolution: prefer pre-populated CLIFT_FLAGS; otherwise parse argv
# ourselves via the shared standalone helper so direct-invocation tests get
# identical semantics to the router pipeline.
if ! declare -p CLIFT_FLAGS >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/runtime/standalone_argv.sh"
  jarvis_standalone_argv_parse \
    '[{"name":"short","type":"bool"},
      {"name":"skip-calendar","type":"bool"},
      {"name":"skip-prs","type":"bool"},
      {"name":"skip-jira","type":"bool"},
      {"name":"skip-deploys","type":"bool"},
      {"name":"skip-oncall","type":"bool"},
      {"name":"skip-reminders","type":"bool"},
      {"name":"skip-focus","type":"bool"},
      {"name":"skip-tasks","type":"bool"},
      {"name":"skip-notes","type":"bool"},
      {"name":"profile","type":"string"}]' \
    "$@"
fi

short="${CLIFT_FLAGS[short]:-}"
skip_cal="${CLIFT_FLAGS[skip-calendar]:-}"
skip_prs="${CLIFT_FLAGS[skip-prs]:-}"
skip_jira="${CLIFT_FLAGS[skip-jira]:-}"
skip_dep="${CLIFT_FLAGS[skip-deploys]:-}"
skip_oncall="${CLIFT_FLAGS[skip-oncall]:-}"
skip_rem="${CLIFT_FLAGS[skip-reminders]:-}"
skip_focus="${CLIFT_FLAGS[skip-focus]:-}"
skip_tasks="${CLIFT_FLAGS[skip-tasks]:-}"
skip_notes="${CLIFT_FLAGS[skip-notes]:-}"

# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/profile.sh"
# state_profile_dir resolves the precedence chain (CLIFT_FLAGS[profile] >
# CLIFT_FLAG_PROFILE env > JARVIS_PROFILE > default) and exports
# JARVIS_PROFILE so downstream libs see the resolved value. Profile dir
# is also captured for direct file reads (reminders/, etc).
profile_dir="$(state_profile_dir)"
profile="$JARVIS_PROFILE"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/config.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/cache/file.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/calendar/provider.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/calendar/none.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/calendar/gcalcli.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/calendar/ics.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/calendar/applescript.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/integrations/gh.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/integrations/jira.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/integrations/deploys.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/integrations/oncall.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/native/clock.sh"

# "now" — overridable for deterministic tests. Day window is [00:00 today, 00:00 tomorrow).
now_iso="$(native_now_iso)"
day_start="$(native_day_start "$now_iso")"
day_end="$(native_day_boundary "$day_start" +1d)"

# Gather sections. Each lib returns:
#   - exit 0 + NDJSON rows when populated
#   - exit 0 + empty stdout when configured but empty (e.g. cache-miss provider="none")
#   - exit 1 when tool/config missing — treated as "hide section" by `|| true`
#
# `--verbose` lets stderr through so failure modes (gh auth required, ICS
# fetch failed, jira not authenticated) are visible without dropping into
# `jarvis doctor --integrations-live`.
verbose="${CLIFT_FLAGS[verbose]:-}"
_silence() {
  if [[ "$verbose" == "true" ]]; then "$@"; else "$@" 2>/dev/null; fi
}
calendar=""; prs=""; jira_rows=""; deploys=""; oncall=""; reminders=""
[[ "$skip_cal"    != "true" ]] && calendar="$(_silence calendar_events "$day_start" "$day_end" "$profile" || true)"
[[ "$skip_prs"    != "true" ]] && prs="$(_silence gh_prs_review_requested "$profile" || true)"
[[ "$skip_jira"   != "true" ]] && jira_rows="$(_silence jira_in_flight "$profile" || true)"
[[ "$skip_dep"    != "true" ]] && deploys="$(_silence deploys_recent "$day_start" "$profile" || true)"
[[ "$skip_oncall" != "true" ]] && oncall="$(_silence oncall_show "$profile" || true)"

# Focus one-liner: yesterday's totals + top topic. Pre-fix `focus.log`
# was a write-only journal as far as `brief` was concerned — the user
# had to drop into `focus stats` to see anything they did the day before.
focus_yesterday=""
focus_log="$profile_dir/focus.log"
if [[ "$skip_focus" != "true" && -f "$focus_log" ]]; then
  _now_epoch="$(native_now_epoch)"
  yesterday_date="$(native_epoch_to_iso $((_now_epoch - 86400)) 2>/dev/null | cut -c1-10)"
  if [[ -n "$yesterday_date" ]]; then
    focus_yesterday="$(jq -rs --arg y "$yesterday_date" '
      [ .[] | select(.event=="end" and ((.ts // "") | startswith($y))) ] as $ends
      | ($ends | map(.elapsed_seconds // 0) | add // 0) as $secs
      | ($secs / 60 | floor) as $m
      | ($ends
          | map(.topic // "(untitled)")
          | group_by(.)
          | map({t:.[0], n:length})
          | sort_by(-.n)
          | .[0].t // "") as $top
      | if $m == 0 then ""
        elif $m < 60 then
          "\($m) min" + (if $top != "" then " on \($top)" else "" end)
        else
          ($m / 60 | floor) as $h
          | (if ($m % 60) == 0 then "\($h)h" else "\($h)h \($m % 60)m" end) as $hm
          | "\($hm)" + (if $top != "" then " on \($top)" else "" end)
        end
    ' < "$focus_log" 2>/dev/null || true)"
  fi
fi

# Reminders firing later today. The data has always been in
# <profile>/reminders/*.json — only `status` (the dashboard) consumed it
# pre-fix, so the user reading their morning brief never saw "you have a
# reminder firing at 14:00 today" even though the system had every byte.
if [[ "$skip_rem" != "true" && -d "$profile_dir/reminders" ]]; then
  shopt -s nullglob
  _rem_files=( "$profile_dir/reminders"/*.json )
  shopt -u nullglob
  if (( ${#_rem_files[@]} > 0 )); then
    reminders="$(jq -cs --arg now "$now_iso" --arg end "$day_end" '
      [ .[]
        | select((.status // "pending") == "pending" or (.status // "") == "active")
        | select(.trigger_at >= $now and .trigger_at < $end) ]
      | sort_by(.trigger_at)
      | .[]
    ' "${_rem_files[@]}" 2>/dev/null || true)"
  fi
fi

# Tasks rollup. Pre-fix the morning brief showed no tasks at all — even
# though the user might have ten open and three due today. Surface a
# count plus the top 3 by (priority desc, seq asc) so the reader gets a
# usable "what's next" view without leaving brief.
tasks_top=""; tasks_open_count=0; tasks_due_today_count=0
if [[ "$skip_tasks" != "true" && -d "$profile_dir/tasks" ]]; then
  shopt -s nullglob
  _task_files=( "$profile_dir/tasks"/*.json )
  shopt -u nullglob
  if (( ${#_task_files[@]} > 0 )); then
    # Single jq pass: open count, due-today count, and top-3 NDJSON. The
    # priority sort uses a synthetic ranking (high=0, med=1, low=2, other=3)
    # so high-priority bubbles to the top regardless of insertion order.
    today_date="${now_iso%%T*}"
    _task_blob="$(jq -s --arg today "$today_date" '
      def pri_rank: if .priority == "high" then 0
                    elif .priority == "med" then 1
                    elif .priority == "low" then 2
                    else 3 end;
      [ .[] | select((.status // "open") == "open") ] as $open
      | {
          open_count: ($open | length),
          due_today: ([ $open[] | select(.due == "today" or .due == $today) ] | length),
          top: ($open | sort_by(pri_rank, .seq) | .[:3]
                      | map({slug, desc, priority, due, jira_key, tags}))
        }
    ' "${_task_files[@]}" 2>/dev/null || printf '{"open_count":0,"due_today":0,"top":[]}')"
    tasks_open_count="$(jq -r '.open_count' <<< "$_task_blob")"
    tasks_due_today_count="$(jq -r '.due_today' <<< "$_task_blob")"
    tasks_top="$(jq -c '.top[]?' <<< "$_task_blob")"
  fi
fi

# Notes rollup. Daily-note presence is a recurring quiet question ("did I
# already start today's daily?"); pair that with a touched-this-week count
# and the user can decide whether to start one or pick up where they left
# off without dropping into `note list`.
notes_daily_today=""; notes_touched_week=0
if [[ "$skip_notes" != "true" && -f "$profile_dir/notes/index.json" ]]; then
  # The notes index records `path`, `kind`, `created_at`, `updated_at` per
  # entry. `kind == "daily"` + `created_at` matching today is the daily-today
  # check; updated_at within last 7d covers everything else worth flagging.
  today_date="${now_iso%%T*}"
  week_ago_epoch="$(( $(native_now_epoch) - 7*86400 ))"
  week_ago_iso="$(native_epoch_to_iso "$week_ago_epoch")"
  _notes_blob="$(jq --arg today "$today_date" --arg wk "$week_ago_iso" '
    .notes // []
    | {
        daily_today: (
          [ .[]
            | select((.kind // "") == "daily"
                     and ((.created_at // "") | startswith($today))
                     and (.archived // false) == false) ]
          | first | (.path // "") // ""
        ),
        touched: ([ .[]
                    | select((.archived // false) == false
                             and (.updated_at // "") >= $wk) ] | length)
      }
  ' "$profile_dir/notes/index.json" 2>/dev/null || printf '{"daily_today":"","touched":0}')"
  notes_daily_today="$(jq -r '.daily_today // ""' <<< "$_notes_blob")"
  notes_touched_week="$(jq -r '.touched // 0' <<< "$_notes_blob")"
fi

# Count NDJSON rows (one JSON per line). Empty input -> 0.
_count() {
  if [[ -z "$1" ]]; then printf '0\n'; else printf '%s\n' "$1" | grep -c .; fi
}

if [[ "$short" == "true" ]]; then
  # One-line glance. Pre-fix this dropped meetings, reminders, focus, and
  # tasks entirely — the user got `3 PRs · 2 deploys · oncall: TJ` and
  # nothing else, despite three other surfaces having data ready. Order
  # mirrors the long-form section order so the eye finds the same chunk
  # in the same place.
  pr_count="$(_count "$prs")"
  cal_count="$(_count "$calendar")"
  dep_count="$(_count "$deploys")"
  rem_count="$(_count "$reminders")"
  jira_count="$(_count "$jira_rows")"
  pr_label="PRs"; (( pr_count == 1 )) && pr_label="PR"
  dep_label="deploys"; (( dep_count == 1 )) && dep_label="deploy"
  cal_label="meetings"; (( cal_count == 1 )) && cal_label="meeting"
  rem_label="reminders"; (( rem_count == 1 )) && rem_label="reminder"
  jira_label="jira"
  task_label="tasks"; (( tasks_open_count == 1 )) && task_label="task"

  # Always-show counts for core surfaces. Zero is plural ("0 PRs",
  # "0 deploys") — matches goreleaser-style English and lets shell consumers
  # grep for fixed labels without conditional logic. Optional surfaces
  # (jira when integration absent, focus when no log) only render when
  # they actually have data.
  segments=("$cal_count $cal_label" "$pr_count $pr_label" "$tasks_open_count $task_label")
  (( jira_count > 0 )) && segments+=("$jira_count $jira_label")
  segments+=("$rem_count $rem_label" "$dep_count $dep_label")
  if [[ -n "$focus_yesterday" ]]; then
    # focus_yesterday already carries unit (e.g. "4h on cfgd" or "45 min");
    # strip the topic suffix for the short form so it stays a single token.
    focus_short="${focus_yesterday%% on *}"
    segments+=("$focus_short focus")
  fi

  primary=""; secondary=""
  if [[ -n "$oncall" ]]; then
    primary="$(printf '%s\n' "$oncall" | jq -r 'select(.role == "primary") | .who' 2>/dev/null | head -n1)"
    secondary="$(printf '%s\n' "$oncall" | jq -r 'select(.role == "secondary") | .who' 2>/dev/null | head -n1)"
  fi

  # Body uses U+00B7 middle dot as section separator (matches the legacy
  # short shape so consumers piping to grep keep working).
  body=""
  for seg in "${segments[@]}"; do
    [[ -z "$body" ]] && body="$seg" || body="$body $(printf '\xc2\xb7') $seg"
  done

  if [[ -n "$primary" && -n "$secondary" ]]; then
    printf 'brief (%s): %s \xc2\xb7 oncall: %s / %s\n' "$profile" "$body" "$primary" "$secondary"
  elif [[ -n "$primary" ]]; then
    printf 'brief (%s): %s \xc2\xb7 oncall: %s\n' "$profile" "$body" "$primary"
  else
    printf 'brief (%s): %s\n' "$profile" "$body"
  fi
  exit 0
fi

# Pretty render.
printf '\n'
if declare -F log_info >/dev/null 2>&1; then
  log_info "☀  Good morning — ${profile} profile"
else
  printf 'info: ☀  Good morning — %s profile\n' "$profile"
fi
printf '\n'

if [[ -n "$calendar" ]]; then
  # Calendar provider NDJSON shape is {start,end,title,url,...}. The renderer
  # used to drop .url silently and lacked duration entirely — meetings could
  # be joined via standup --join, but the brief surfaced neither link nor a
  # 30-min-vs-2-hour signal. Now both render alongside the title.
  printf '  \033[1mCalendar\033[0m\n'
  printf '%s\n' "$calendar" | jq -r '
    def duration_str:
      if .end and .end != "" and .end != .start then
        ((.end | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) -
         (.start | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime)) as $secs
        | ($secs / 60 | floor) as $m
        | if $m < 60 then "  (\($m)m)"
          elif ($m % 60) == 0 then "  (\($m / 60 | floor)h)"
          else "  (\($m / 60 | floor)h \($m % 60)m)" end
      else "" end;
    "    " +
    (.start | sub("^.*T"; "") | sub(":[0-9]+Z?$"; "")) +
    "  " + .title +
    duration_str +
    (if (.url // "") != "" then "  [2m" + .url + "[0m" else "" end)'
  printf '\n'
fi

if [[ -n "$prs" ]]; then
  # Each row carries the signals that change how a reviewer reads it:
  # draft marker (don't review yet), CI rollup (red is unreviewable, pending
  # blocks merge), age (stale signal), reviewDecision (already approved or
  # changes-requested by someone). The bare repo#num+title from before
  # buried all four — the audit's canonical example of "captured but
  # invisible". `now_iso` honors JARVIS_FAKE_NOW so age is deterministic
  # under tests.
  printf '  \033[1mPRs awaiting your review\033[0m\n'
  printf '%s\n' "$prs" | jq -r --arg now "$now_iso" '
    def age_str:
      if (.updatedAt // "") != "" and ($now // "") != "" then
        (($now    | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) -
         (.updatedAt | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime)) as $secs
        | if $secs < 3600    then "  \($secs / 60 | floor)m"
          elif $secs < 86400  then "  \($secs / 3600 | floor)h"
          elif $secs < 604800 then "  \($secs / 86400 | floor)d"
          else "  \($secs / 604800 | floor)w" end
      else "" end;
    def ci_str:
      if .ci == "success"  then "  ✓CI"
      elif .ci == "failure" then "  ✗CI"
      elif .ci == "pending" then "  ⏳CI"
      else "" end;
    def decision_str:
      if .reviewDecision == "APPROVED"          then "  approved"
      elif .reviewDecision == "CHANGES_REQUESTED" then "  changes-requested"
      else "" end;
    (if .isDraft then "    [DRAFT] " else "    " end) +
    .repo + "#" + (.number|tostring) + "  " + .title +
    age_str + ci_str + decision_str'
  printf '\n'
fi

if [[ -n "$focus_yesterday" ]]; then
  printf '  \033[1mFocus yesterday\033[0m  %s\n\n' "$focus_yesterday"
fi

if [[ -n "$reminders" ]]; then
  printf '  \033[1mReminders today\033[0m\n'
  printf '%s\n' "$reminders" | jq -r '
    "    " +
    (.trigger_at | sub("^.*T"; "") | sub(":[0-9]+Z?$"; "")) +
    "  " + (.message // .slug // "(no message)") +
    (if (.repeat // "") != "" and .repeat != "once" then "  (every \(.repeat))" else "" end)'
  printf '\n'
fi

if [[ -n "$jira_rows" ]]; then
  # Each row carries priority/due/parent post-fix (jira.sh extended its
  # column projection). Render shows priority as a bracketed badge, due
  # date when set, and uses the URL when clicking through is wanted.
  printf '  \033[1mJira in flight\033[0m\n'
  printf '%s\n' "$jira_rows" | jq -r '
    "    " + .key + "  " + .summary +
    (if (.priority // "") != "" and .priority != "null" then "  [\(.priority)]" else "" end) +
    (if (.due // "") != "" and .due != "null" then "  due \(.due)" else "" end)'
  printf '\n'
fi

# Tasks section. Header summarizes the open count and how many are due
# today; body is up to 3 priority-ranked rows. Rows mirror the standup
# render shape (desc + [pri] + due + jira_key) so a user fluent in one
# is fluent in the other.
if (( tasks_open_count > 0 )); then
  if (( tasks_due_today_count > 0 )); then
    printf '  \033[1mTasks\033[0m  %d open  ·  %d due today\n' \
      "$tasks_open_count" "$tasks_due_today_count"
  else
    printf '  \033[1mTasks\033[0m  %d open\n' "$tasks_open_count"
  fi
  if [[ -n "$tasks_top" ]]; then
    printf '%s\n' "$tasks_top" | jq -r '
      "    " + (.desc // .slug // "(untitled)") +
      (if (.priority // "") != "" and .priority != "null" and .priority != "med"
        then "  [\(.priority)]" else "" end) +
      (if (.due // "") != "" and .due != "null" then "  due \(.due)" else "" end) +
      (if (.jira_key // "") != "" and .jira_key != "null" then "  \(.jira_key)" else "" end)'
  fi
  printf '\n'
fi

# Notes section. Two pieces of state: did I start today's daily, and how
# many notes have I touched this week. Either one alone tells me whether
# I have momentum or need to bootstrap; together they're a 5-second pulse.
if [[ "$skip_notes" != "true" ]] && \
   { [[ -n "$notes_daily_today" ]] || (( notes_touched_week > 0 )); }; then
  printf '  \033[1mNotes\033[0m'
  if [[ -n "$notes_daily_today" ]]; then
    printf '  daily today: ✓'
  else
    printf '  daily today: —'
  fi
  if (( notes_touched_week > 0 )); then
    printf '  ·  %d touched this week' "$notes_touched_week"
  fi
  printf '\n\n'
fi

if [[ -n "$deploys" ]]; then
  printf '  \033[1mDeploys\033[0m\n'
  printf '%s\n' "$deploys" | jq -r '"    " + (.ts | sub("^.*T"; "") | sub(":[0-9]+Z?$"; "")) + "  " + .service + "  " + .version + "  " + .status'
  printf '\n'
fi

if [[ -n "$oncall" ]]; then
  printf '  \033[1mOncall\033[0m\n'
  printf '%s\n' "$oncall" | jq -r '
    "    " + .role + ":  " + .who +
    (if .pager then "  (pager: \(.pager))" else "" end) +
    (if .until then "  (until \(.until))" else "" end)'
  printf '\n'
fi

# All-empty hint: if every section is gated off (no integrations configured /
# no data), the user gets only the "Good morning" line. Surface a single hint
# pointing at doctor so the silence is actionable.
if [[ -z "$calendar" && -z "$prs" && -z "$jira_rows" && -z "$deploys" \
   && -z "$oncall" && -z "$reminders" && -z "$focus_yesterday" \
   && "$tasks_open_count" -eq 0 && -z "$notes_daily_today" \
   && "$notes_touched_week" -eq 0 ]]; then
  if declare -F log_info >/dev/null 2>&1; then
    log_info "no integrations configured — run \`jarvis doctor\` for diagnostics"
  else
    printf 'info: no integrations configured — run `jarvis doctor` for diagnostics\n'
  fi
fi
