#!/usr/bin/env bash
set -euo pipefail

: "${FRAMEWORK_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
: "${CLI_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# shellcheck source=/dev/null
source "${FRAMEWORK_DIR}/lib/log/log.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/profile.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/lock.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/ndjson.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/focus/log.sh"

if ! declare -p CLIFT_FLAGS >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/runtime/standalone_argv.sh"
  jarvis_standalone_argv_parse \
    '[{"name":"json","type":"bool"},{"name":"yaml","type":"bool"},{"name":"days","type":"string"},{"name":"limit","type":"string"}]' \
    "$@"
fi

want_json="${CLIFT_FLAGS[json]:-}"
want_yaml="${CLIFT_FLAGS[yaml]:-}"
days="${CLIFT_FLAGS[days]:-7}"
limit="${CLIFT_FLAGS[limit]:-5}"

if [[ "$want_json" == "true" && "$want_yaml" == "true" ]]; then
  clift_exit 2 "--json and --yaml are mutually exclusive"
fi

# Compute aggregates once; reused across all output paths.
minutes_today="$(focus_stats_today_minutes)"
sessions_today="$(focus_stats_sessions_today)"
top_topics_json="$(focus_stats_top_topics --days "$days" --limit "$limit")"

if [[ "$want_json" == "true" ]]; then
  jq -n \
    --argjson m "$minutes_today" \
    --argjson s "$sessions_today" \
    --argjson t "$top_topics_json" \
    '{today_minutes: $m, sessions_today: $s, top_topics: $t}'
  exit 0
fi

if [[ "$want_yaml" == "true" ]]; then
  jq -n \
    --argjson m "$minutes_today" \
    --argjson s "$sessions_today" \
    --argjson t "$top_topics_json" \
    '{today_minutes: $m, sessions_today: $s, top_topics: $t}' \
    | yq -P eval '.' -
  exit 0
fi

# Default human output. Plain printf — gum is reserved for live/spinner
# surfaces; static layout uses aligned printf to keep dependencies minimal
# and output predictable in non-tty pipes.
if (( sessions_today == 0 )); then
  printf 'no focus sessions yet today\n'
  exit 0
fi

printf 'focus stats\n'
printf '  today        %s min  (%s session%s)\n' \
  "$minutes_today" "$sessions_today" "$([[ "$sessions_today" -eq 1 ]] || printf s)"

if [[ "$top_topics_json" == "[]" ]]; then
  exit 0
fi

printf '  top topics (last %sd)\n' "$days"
while IFS=$'\t' read -r topic mins sess; do
  [[ -z "$topic" ]] && continue
  printf '    %-24s %4s min  (%s)\n' "$topic" "$mins" "$sess"
done < <(jq -r '.[] | [.topic, .minutes, .sessions] | @tsv' <<< "$top_topics_json")
