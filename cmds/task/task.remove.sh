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
source "${CLI_DIR}/lib/slug.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/task/store.sh"

if ! declare -p CLIFT_FLAGS >/dev/null 2>&1; then
  declare -A CLIFT_FLAGS=()
fi

input="${CLIFT_POS_1:-}"
if [[ -z "$input" ]]; then
  clift_exit 2 "usage: jarvis task remove <slug>"
fi

tasks_dir="$(task_store_dir)"
slug="$(slug_resolve_prefix "$input" "$tasks_dir")" || exit 1
task_store_delete "$slug"
log_success "removed ${slug}"
