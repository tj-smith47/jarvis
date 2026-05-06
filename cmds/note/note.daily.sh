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

# Standalone-argv fallback: under the router, CLIFT_FLAGS is pre-populated
# and $@ is empty. In tests / direct invocations, parse argv via the shared
# helper so the script's flag contract matches the router path 1:1.
if ! declare -p CLIFT_FLAGS >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/runtime/standalone_argv.sh"
  jarvis_standalone_argv_parse \
    '[{"name":"no-edit","type":"bool"}]' \
    "$@"
fi

body="${CLIFT_POS_1:-}"
no_edit="${CLIFT_FLAGS[no-edit]:-}"

# Local-date semantics: the user's "today" is what they see on the wall
# clock, not UTC. JARVIS_TODAY pinning is for tests + cron determinism.
today="${JARVIS_TODAY:-$(date +%F)}"
key="daily/$today"
file="$(note_path "$key")"

state_ensure_tree
mkdir -p "$(note_root)/daily"

# Create-if-missing. Tolerate the create-race the same way note.add.sh's
# _ensure_daily does: if a concurrent writer wins the ln(2) collision, the
# file lands on disk and we proceed. Anything else is a real failure.
if [[ ! -f "$file" ]]; then
  note_store_new daily "$today" "$today" \
    --template "$CLI_DIR/templates/daily.md" >/dev/null 2>&1 || true
  [[ -f "$file" ]] || clift_exit 1 "daily auto-create failed: $key"
fi

# Body given → append (regardless of whether we just created or it existed).
if [[ -n "$body" ]]; then
  note_store_append "$key" "$body"
  log_success "$key.md"
  exit 0
fi

# No body. Open editor when interactive and the user didn't opt out;
# refresh the index after a successful editor session so frontmatter
# edits land in .index.json.
if [[ "$no_edit" != "true" ]] && [[ -n "${EDITOR:-}" ]] && [[ -t 1 ]]; then
  "$EDITOR" "$file" || true
  note_index_update "$key"
fi

log_success "$key.md"
