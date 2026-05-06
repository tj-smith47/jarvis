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
source "${CLI_DIR}/lib/state/json.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/config.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/slug.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/task/store.sh"

if ! declare -p CLIFT_FLAGS >/dev/null 2>&1; then
  declare -A CLIFT_FLAGS=()
fi

input="${CLIFT_POS_1:-}"
if [[ -z "$input" ]]; then
  clift_exit 2 "usage: jarvis task done <slug|JIRA-KEY>"
fi

if slug_is_jira_key "$input"; then
  transition="$(config_get jira.done_transition Done)"
  if command -v jira >/dev/null 2>&1; then
    jira issue move "$input" "$transition"
    exit $?
  else
    clift_exit 4 "jira binary missing — install jira-cli (or use task done <slug> for local tasks)"
  fi
fi

tasks_dir="$(task_store_dir)"
slug="$(slug_resolve_prefix "$input" "$tasks_dir")" || exit 1
task_store_set_done "$slug"
log_success "task ${slug} marked done  🎉"
