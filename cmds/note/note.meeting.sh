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
  jarvis_standalone_argv_parse \
    '[{"name":"no-edit","type":"bool"}]' \
    "$@"
fi

title="${CLIFT_POS_1:-}"
no_edit="${CLIFT_FLAGS[no-edit]:-}"
today="${JARVIS_TODAY:-$(date +%F)}"

if [[ -z "$title" ]]; then
  clift_exit 2 "usage: jarvis note meeting <title> [--no-edit]"
fi

state_ensure_tree

base="$(slug_from_desc "$title")" || clift_exit 2 "title is empty after slug normalization"
meeting_dir="$(note_root)/meeting"
mkdir -p "$meeting_dir"

# 1on1 routing: case-insensitive prefix match. Falls back to meeting.md if
# the 1on1 template is absent so the command still works in stripped-down
# template directories.
template="$CLI_DIR/templates/meeting.md"
if [[ "${title,,}" == 1on1[\ _]* ]] && [[ -f "$CLI_DIR/templates/1on1.md" ]]; then
  template="$CLI_DIR/templates/1on1.md"
fi

# Date-suffix the slug, then resolve collisions with -2, -3, ... (md ext —
# default "json" would silently miss markdown files in this directory).
slug="$(slug_resolve_collision "${base}-${today}" "$meeting_dir" md)"

key="$(note_store_new meeting "$slug" "$title" --template "$template")"

if [[ "$no_edit" != "true" ]] && [[ -n "${EDITOR:-}" ]] && [[ -t 1 ]]; then
  "$EDITOR" "$(note_path "$key")" || true
  note_index_update "$key"
fi

log_success "$(note_path "$key")"
printf '%s\n' "$key"
