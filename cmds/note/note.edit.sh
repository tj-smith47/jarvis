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
source "${CLI_DIR}/lib/frontmatter.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/note/resolve.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/note/index.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/note/current.sh"

# note edit takes no flags — only a positional. Use the positional-only
# fallback so $@ from a standalone invocation maps to CLIFT_POS_*.
if ! declare -p CLIFT_FLAGS >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/runtime/standalone_argv.sh"
  jarvis_standalone_pos_only "$@"
fi

q="${CLIFT_POS_1:-}"

if [[ -z "$q" ]]; then
  if ! q="$(note_current_resolve 2>/dev/null)"; then
    clift_exit 2 "no current note set; provide a slug or title"
  fi
fi

# See note.show.sh — `if ! cmd; then rc=$?` swallows the real rc.
set +e
key="$(note_resolve "$q" 2>/dev/null)"
rc=$?
set -e
if (( rc != 0 )); then
  case "$rc" in
    1) clift_exit 1 "note not found: $q" ;;
    2) clift_exit 2 "note query is ambiguous: $q" ;;
    *) clift_exit "$rc" "note_resolve failed for: $q" ;;
  esac
fi

file="$(note_path "$key")"
[[ -f "$file" ]] || clift_exit 1 "note file missing on disk: $key"

[[ -z "${EDITOR:-}" ]] && clift_exit 2 "EDITOR not set"
"$EDITOR" "$file"

# Re-index so any frontmatter edits (title, tags, archived) land in
# .index.json on the same beat.
note_index_update "$key"
log_success "$file"
