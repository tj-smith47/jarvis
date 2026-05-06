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

if ! declare -p CLIFT_FLAGS >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/runtime/standalone_argv.sh"
  jarvis_standalone_argv_parse \
    '[{"name":"clear","type":"bool"}]' \
    "$@"
fi

target="${CLIFT_POS_1:-}"
clear_flag="${CLIFT_FLAGS[clear]:-}"

state_ensure_tree
mkdir -p "$(note_root)"

# --clear unsets and exits, regardless of any positional. Idempotent
# when nothing is set.
if [[ "$clear_flag" == "true" ]]; then
  note_current_clear
  log_success "current cleared"
  exit 0
fi

# Show mode: no positional → render the current selection.
if [[ -z "$target" ]]; then
  line="$(note_current_read)"
  if [[ -z "$line" ]]; then
    printf 'none (no current note set)\n'
    exit 0
  fi
  set +e
  key="$(note_current_resolve 2>/dev/null)"
  rc=$?
  set -e
  if (( rc != 0 )); then
    printf '%s (unresolvable)\n' "$line"
    exit 0
  fi
  idx="$(note_index_file)"
  title=""
  if [[ -f "$idx" ]]; then
    title="$(jq -r --arg k "$key" '.[$k].title // empty' "$idx" 2>/dev/null)"
  fi
  if [[ -z "$title" ]]; then
    title="$key"
  fi
  printf 'Current: %s\n  %s\n' "$title" "$key"
  exit 0
fi

# Set mode: reserved keyword "daily" stores kind=daily so the resolver
# auto-rotates per day. Anything else goes through note_resolve.
if [[ "$target" == "daily" ]]; then
  note_current_write "kind=daily"
  log_success "current: daily (auto-rotates to today)"
  exit 0
fi

set +e
key="$(note_resolve "$target" 2>/dev/null)"
rc=$?
set -e
case "$rc" in
  0) ;;
  1) clift_exit 1 "could not resolve: $target" ;;
  2) clift_exit 2 "ambiguous target: $target" ;;
  *) clift_exit "$rc" "note_resolve failed for: $target" ;;
esac

note_current_write "slug=$key"
title=""
idx="$(note_index_file)"
if [[ -f "$idx" ]]; then
  title="$(jq -r --arg k "$key" '.[$k].title // empty' "$idx" 2>/dev/null)"
fi
if [[ -z "$title" ]]; then
  title="$key"
fi
log_success "current: $title ($key)"
