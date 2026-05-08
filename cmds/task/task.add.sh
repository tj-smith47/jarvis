#!/usr/bin/env bash
set -euo pipefail

# Resolve framework/CLI dirs with fallback so this script runs standalone in tests.
: "${FRAMEWORK_DIR:=${CLIFT_FRAMEWORK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}}"
: "${CLI_DIR:=${JARVIS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"

# shellcheck source=/dev/null
source "${FRAMEWORK_DIR}/lib/log/log.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/profile.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/lock.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/json.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/slug.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/task/store.sh"

# Standalone-argv fallback. The router populates CLIFT_FLAGS / CLIFT_POS_*
# directly and CLIFT_FLAG_TAG_<n> for list flags; standalone invocations
# (tests, direct bash) need the parser to do the same.
if ! declare -p CLIFT_FLAGS >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/runtime/standalone_argv.sh"
  jarvis_standalone_argv_parse \
    '[{"name":"priority","type":"string"},
      {"name":"urgency","type":"string"},
      {"name":"due","type":"string"},
      {"name":"project","type":"string"},
      {"name":"tag","type":"list"}]' \
    "$@"
fi

desc="${CLIFT_POS_1:-}"
priority="${CLIFT_FLAGS[priority]:-med}"
due="${CLIFT_FLAGS[due]:-}"
project="${CLIFT_FLAGS[project]:-inbox}"
urgency="${CLIFT_FLAGS[urgency]:-}"

# --tag is a list flag. Build a normalized JSON array (lowercased, deduped,
# whitespace-trimmed) so blockers / list filters can match by exact string.
# Default-empty `[]` lets task_store_build land its `tags: []` field shape
# whether or not --tag was passed.
tags_json='[]'
_tag_count="${CLIFT_FLAG_TAG_COUNT:-0}"
if (( _tag_count > 0 )); then
  _tag_lines=""
  for _i in $(seq 1 "$_tag_count"); do
    _var="CLIFT_FLAG_TAG_$_i"
    _tag_lines+="${!_var}"$'\n'
  done
  # ascii_downcase + trim + reject empties + dedupe (preserve first-seen order).
  # Reject anything containing whitespace or shell glob metacharacters so a
  # `--tag "foo bar"` doesn't silently store a string that won't match
  # standup's `index("foo bar")` lookup later.
  tags_json="$(printf '%s' "$_tag_lines" | jq -Rcs '
    split("\n")
    | map(ascii_downcase | sub("^[ \t]+"; "") | sub("[ \t]+$"; ""))
    | map(select(length > 0))
    | unique_by(.)
  ')"
  # Validate shape: alnum + dash + underscore, ≤32 chars. Reject empty.
  invalid="$(jq -r '.[] | select(test("^[a-z0-9][a-z0-9_-]*$") | not) | .' <<< "$tags_json")"
  if [[ -n "$invalid" ]]; then
    clift_exit 2 "invalid --tag value(s): $invalid (allowed: lowercase alnum, '-', '_')"
  fi
fi

if [[ -z "$desc" ]]; then
  clift_exit 2 "usage: jarvis task add <description> [--priority low|med|high] [--due DATE] [--project NAME]"
fi

# --urgency fallback (framework emits its own deprecation warning).
# Map urgency → priority only when priority is still the default `med`,
# so an explicit --priority still wins over a legacy --urgency.
if [[ -n "$urgency" && "$priority" == "med" ]]; then
  priority="$urgency"
fi

case "$priority" in
  low|med|high) ;;
  *) clift_exit 2 "invalid --priority: $priority (expected low|med|high)" ;;
esac

if [[ -n "$due" ]]; then
  case "$due" in
    today|tomorrow) ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) clift_exit 2 "invalid --due: $due (expected today|tomorrow|YYYY-MM-DD)" ;;
  esac
fi

state_ensure_tree
base="$(slug_from_desc "$desc")" || clift_exit 2 "description is empty after slug normalization"
tasks_dir="$(task_store_dir)"
slug="$(slug_resolve_collision "$base" "$tasks_dir")"
seq="$(task_store_next_seq)"

payload="$(task_store_build "$slug" "$desc" "$priority" "$due" "$project" "$seq" null "$tags_json")"
task_store_put "$slug" "$payload"

# Stdout carries only the slug so callers can `slug=$(jarvis task add "…")`.
# log_success goes to stderr like every other log_*; no redirect needed.
log_success "tasks/${slug}.json"
printf '%s\n' "$slug"
