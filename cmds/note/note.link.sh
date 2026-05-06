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

if ! declare -p CLIFT_FLAGS >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/runtime/standalone_argv.sh"
  jarvis_standalone_pos_only "$@"
fi

a_q="${CLIFT_POS_1:-}"
b_q="${CLIFT_POS_2:-}"

if [[ -z "$a_q" || -z "$b_q" ]]; then
  clift_exit 2 "usage: jarvis note link <a> <b>"
fi

_resolve_or_exit() {
  local q="$1" rc resolved
  set +e
  resolved="$(note_resolve "$q" 2>/dev/null)"
  rc=$?
  set -e
  case "$rc" in
    0) printf '%s\n' "$resolved" ;;
    1) clift_exit 1 "note not found: $q" ;;
    2) clift_exit 2 "note query is ambiguous: $q" ;;
    *) clift_exit "$rc" "note_resolve failed for: $q" ;;
  esac
}

a_key="$(_resolve_or_exit "$a_q")"
b_key="$(_resolve_or_exit "$b_q")"

if [[ "$a_key" == "$b_key" ]]; then
  clift_exit 2 "refusing self-link: $a_key"
fi

# Locked check-then-append per file. The grep-and-append must happen
# inside the same lock note_store_append uses, otherwise a concurrent
# writer could insert between the existence check and the append, or
# clobber the append entirely.
_jarvis_link_append() {
  local file="$JARVIS_LINK_FILE"
  local target="$JARVIS_LINK_TARGET"
  if grep -qF "[[$target]]" "$file" 2>/dev/null; then
    return 0
  fi
  printf '\n[[%s]]\n' "$target" >> "$file"
}

a_file="$(note_path "$a_key")"
b_file="$(note_path "$b_key")"

JARVIS_LINK_FILE="$a_file" JARVIS_LINK_TARGET="$b_key" \
  state_with_lock "$a_file" '_jarvis_link_append'
note_index_update "$a_key"

JARVIS_LINK_FILE="$b_file" JARVIS_LINK_TARGET="$a_key" \
  state_with_lock "$b_file" '_jarvis_link_append'
note_index_update "$b_key"

log_success "linked $a_key <-> $b_key"
