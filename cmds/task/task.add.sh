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

# CLIFT_FLAGS may not be declared when invoked standalone.
if ! declare -p CLIFT_FLAGS >/dev/null 2>&1; then
  declare -A CLIFT_FLAGS=()
fi

desc="${CLIFT_POS_1:-}"
priority="${CLIFT_FLAGS[priority]:-med}"
due="${CLIFT_FLAGS[due]:-}"
project="${CLIFT_FLAGS[project]:-inbox}"
urgency="${CLIFT_FLAGS[urgency]:-}"

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

payload="$(task_store_build "$slug" "$desc" "$priority" "$due" "$project" "$seq" null)"
task_store_put "$slug" "$payload"

# Stdout carries only the slug so callers can `slug=$(jarvis task add "…")`.
# log_success goes to stderr like every other log_*; no redirect needed.
log_success "tasks/${slug}.json"
printf '%s\n' "$slug"
