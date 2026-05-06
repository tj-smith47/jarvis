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
profile="${CLIFT_FLAGS[profile]:-${JARVIS_PROFILE:-default}}"
[[ -z "$profile" ]] && profile="${JARVIS_PROFILE:-default}"
skip_cal="${CLIFT_FLAGS[skip-calendar]:-}"
skip_prs="${CLIFT_FLAGS[skip-prs]:-}"
skip_jira="${CLIFT_FLAGS[skip-jira]:-}"
skip_dep="${CLIFT_FLAGS[skip-deploys]:-}"

# state_profile_dir / config_get / cache helpers all read JARVIS_PROFILE;
# honor an explicit --profile by exporting before sourcing.
JARVIS_PROFILE="$profile"
export JARVIS_PROFILE

# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/profile.sh"
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

# "now" — overridable for deterministic tests. Day window is [00:00 today, 00:00 tomorrow).
now_iso="${JARVIS_FAKE_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
today_date="${now_iso%T*}"
day_start="${today_date}T00:00:00Z"
day_end="$(date -u -d "$today_date +1 day" +%Y-%m-%dT00:00:00Z 2>/dev/null \
        || date -u -j -v+1d -f "%Y-%m-%d" "$today_date" +%Y-%m-%dT00:00:00Z)"

# Gather sections. Each lib returns:
#   - exit 0 + NDJSON rows when populated
#   - exit 0 + empty stdout when configured but empty (e.g. cache-miss provider="none")
#   - exit 1 when tool/config missing — treated as "hide section" by `|| true`
calendar=""; prs=""; jira_rows=""; deploys=""; oncall=""
[[ "$skip_cal"  != "true" ]] && calendar="$(calendar_events "$day_start" "$day_end" "$profile" 2>/dev/null || true)"
[[ "$skip_prs"  != "true" ]] && prs="$(gh_prs_review_requested "$profile" 2>/dev/null || true)"
[[ "$skip_jira" != "true" ]] && jira_rows="$(jira_in_flight "$profile" 2>/dev/null || true)"
[[ "$skip_dep"  != "true" ]] && deploys="$(deploys_recent "$day_start" "$profile" 2>/dev/null || true)"
oncall="$(oncall_show "$profile" 2>/dev/null || true)"

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
  printf '  \033[1mCalendar\033[0m\n'
  printf '%s\n' "$calendar" | jq -r '"    " + (.start | sub("^.*T"; "") | sub(":[0-9]+Z?$"; "")) + "  " + .title'
  printf '\n'
fi

if [[ -n "$prs" ]]; then
  printf '  \033[1mPRs awaiting your review\033[0m\n'
  printf '%s\n' "$prs" | jq -r '"    #" + (.number|tostring) + "  " + .title'
  printf '\n'
fi

if [[ -n "$jira_rows" ]]; then
  printf '  \033[1mJira in flight\033[0m\n'
  printf '%s\n' "$jira_rows" | jq -r '"    " + .key + "  " + .summary'
  printf '\n'
fi

if [[ -n "$deploys" ]]; then
  printf '  \033[1mDeploys\033[0m\n'
  printf '%s\n' "$deploys" | jq -r '"    " + .service + "  " + .version + "  " + .status'
  printf '\n'
fi

if [[ -n "$oncall" ]]; then
  printf '  \033[1mOncall\033[0m\n'
  printf '%s\n' "$oncall" | jq -r '"    " + .role + ":  " + .who + (if .pager then "  (pager: " + .pager + ")" else "" end)'
  printf '\n'
fi
