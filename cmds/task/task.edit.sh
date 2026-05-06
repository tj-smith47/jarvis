#!/usr/bin/env bash
set -euo pipefail

# Resolve framework/CLI dirs with fallback so this script runs standalone in tests.
: "${FRAMEWORK_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
: "${CLI_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

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

if ! declare -p CLIFT_FLAGS >/dev/null 2>&1; then
  declare -A CLIFT_FLAGS=()
fi

input="${CLIFT_POS_1:-}"
if [[ -z "$input" ]]; then
  clift_exit 2 "usage: jarvis task edit <slug> [--desc|--priority|--due|--project VAL]"
fi

new_desc="${CLIFT_FLAGS[desc]:-}"
new_pri="${CLIFT_FLAGS[priority]:-}"
new_due="${CLIFT_FLAGS[due]:-}"
new_project="${CLIFT_FLAGS[project]:-}"

if [[ -z "$new_desc" && -z "$new_pri" && -z "$new_due" && -z "$new_project" ]]; then
  clift_exit 2 "nothing to change — pass at least one of --desc/--priority/--due/--project"
fi

if [[ -n "$new_pri" ]]; then
  case "$new_pri" in
    low|med|high) ;;
    *) clift_exit 2 "invalid --priority: $new_pri (expected low|med|high)" ;;
  esac
fi

due_is_clear=0
if [[ -n "$new_due" ]]; then
  case "$new_due" in
    today|tomorrow) ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    clear) due_is_clear=1 ;;
    *) clift_exit 2 "invalid --due: $new_due (expected today|tomorrow|YYYY-MM-DD|clear)" ;;
  esac
fi

tasks_dir="$(task_store_dir)"
slug="$(slug_resolve_prefix "$input" "$tasks_dir")" || exit 1

# Build the jq filter from the set flags. Values are threaded through as
# --arg bindings so the filter text stays a fixed literal regardless of user
# input — no shell-metacharacter escaping required. The whole read-mutate-write
# happens inside task_store_mutate's single flock window.
filter='.'
args=()
if [[ -n "$new_desc" ]]; then
  filter="$filter | .desc = \$desc"
  args+=(--arg desc "$new_desc")
fi
if [[ -n "$new_pri" ]]; then
  filter="$filter | .priority = \$pri"
  args+=(--arg pri "$new_pri")
fi
if [[ -n "$new_project" ]]; then
  filter="$filter | .project = \$project"
  args+=(--arg project "$new_project")
fi
if [[ -n "$new_due" ]]; then
  if (( due_is_clear )); then
    # Literal null — no --arg binding needed.
    filter="$filter | .due = null"
  else
    filter="$filter | .due = \$due"
    args+=(--arg due "$new_due")
  fi
fi

task_store_mutate "$slug" "$filter" "${args[@]}"

log_success "edited ${slug}"
