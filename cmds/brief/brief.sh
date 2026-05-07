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
      {"name":"profile","type":"string"}]' \
    "$@"
fi

short="${CLIFT_FLAGS[short]:-}"
skip_cal="${CLIFT_FLAGS[skip-calendar]:-}"
skip_prs="${CLIFT_FLAGS[skip-prs]:-}"
skip_jira="${CLIFT_FLAGS[skip-jira]:-}"
skip_dep="${CLIFT_FLAGS[skip-deploys]:-}"

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
[[ "$skip_cal"  != "true" ]] && calendar="$(_silence calendar_events "$day_start" "$day_end" "$profile" || true)"
[[ "$skip_prs"  != "true" ]] && prs="$(_silence gh_prs_review_requested "$profile" || true)"
[[ "$skip_jira" != "true" ]] && jira_rows="$(_silence jira_in_flight "$profile" || true)"
[[ "$skip_dep"  != "true" ]] && deploys="$(_silence deploys_recent "$day_start" "$profile" || true)"
oncall="$(_silence oncall_show "$profile" || true)"

# Focus one-liner: yesterday's totals + top topic. Pre-fix `focus.log`
# was a write-only journal as far as `brief` was concerned — the user
# had to drop into `focus stats` to see anything they did the day before.
focus_yesterday=""
focus_log="$profile_dir/focus.log"
if [[ -f "$focus_log" ]]; then
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
if [[ -d "$profile_dir/reminders" ]]; then
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

# Count NDJSON rows (one JSON per line). Empty input -> 0.
_count() {
  if [[ -z "$1" ]]; then printf '0\n'; else printf '%s\n' "$1" | grep -c .; fi
}

if [[ "$short" == "true" ]]; then
  pr_count="$(_count "$prs")"
  dep_count="$(_count "$deploys")"
  pr_label="PRs"; (( pr_count == 1 )) && pr_label="PR"
  dep_label="deploys"; (( dep_count == 1 )) && dep_label="deploy"
  primary=""; secondary=""
  if [[ -n "$oncall" ]]; then
    primary="$(printf '%s\n' "$oncall" | jq -r 'select(.role == "primary") | .who' 2>/dev/null | head -n1)"
    secondary="$(printf '%s\n' "$oncall" | jq -r 'select(.role == "secondary") | .who' 2>/dev/null | head -n1)"
  fi
  if [[ -n "$primary" && -n "$secondary" ]]; then
    printf 'brief (%s): %d %s \xc2\xb7 %d %s today \xc2\xb7 oncall: %s / %s\n' \
      "$profile" "$pr_count" "$pr_label" "$dep_count" "$dep_label" "$primary" "$secondary"
  elif [[ -n "$primary" ]]; then
    printf 'brief (%s): %d %s \xc2\xb7 %d %s today \xc2\xb7 oncall: %s\n' \
      "$profile" "$pr_count" "$pr_label" "$dep_count" "$dep_label" "$primary"
  else
    printf 'brief (%s): %d %s \xc2\xb7 %d %s today\n' \
      "$profile" "$pr_count" "$pr_label" "$dep_count" "$dep_label"
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
  printf '  \033[1mJira in flight\033[0m\n'
  printf '%s\n' "$jira_rows" | jq -r '"    " + .key + "  " + .summary'
  printf '\n'
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
if [[ -z "$calendar" && -z "$prs" && -z "$jira_rows" && -z "$deploys" && -z "$oncall" && -z "$reminders" && -z "$focus_yesterday" ]]; then
  if declare -F log_info >/dev/null 2>&1; then
    log_info "no integrations configured — run \`jarvis doctor\` for diagnostics"
  else
    printf 'info: no integrations configured — run `jarvis doctor` for diagnostics\n'
  fi
fi
