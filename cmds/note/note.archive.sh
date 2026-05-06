#!/usr/bin/env bash
set -euo pipefail

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
source "${CLI_DIR}/lib/frontmatter.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/note/resolve.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/note/index.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/note/store.sh"

if ! declare -p CLIFT_FLAGS >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/runtime/standalone_argv.sh"
  jarvis_standalone_pos_only "$@"
fi

q="${CLIFT_POS_1:-}"

if [[ -z "$q" ]]; then
  clift_exit 2 "usage: jarvis note archive <slug|title>"
fi

set +e
key="$(note_resolve "$q" 2>/dev/null)"
rc=$?
set -e
case "$rc" in
  0) ;;
  1) clift_exit 1 "note not found: $q" ;;
  2) clift_exit 2 "note query is ambiguous: $q" ;;
  *) clift_exit "$rc" "note_resolve failed for: $q" ;;
esac

new_key="$(note_store_archive "$key")"
log_success "archived $key -> $new_key"
printf '%s\n' "$new_key"
