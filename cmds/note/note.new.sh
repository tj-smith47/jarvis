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

# Standalone-argv fallback — same contract as note.add.sh. The router
# pre-populates CLIFT_FLAGS + CLIFT_FLAG_TAG_*; tests and direct invocations
# get raw argv parsed here instead.
if ! declare -p CLIFT_FLAGS >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/runtime/standalone_argv.sh"
  jarvis_standalone_argv_parse \
    '[{"name":"kind","type":"string"},{"name":"tag","type":"list"},{"name":"no-edit","type":"bool"}]' \
    "$@"
fi

title="${CLIFT_POS_1:-}"
kind="${CLIFT_FLAGS[kind]:-inbox}"
no_edit="${CLIFT_FLAGS[no-edit]:-}"

if [[ -z "$title" ]]; then
  clift_exit 2 "usage: jarvis note new <title> [--kind KIND] [--tag NAME]... [--no-edit]"
fi

case "$kind" in
  inbox|meeting|ref|project|daily) ;;
  *) clift_exit 2 "invalid --kind: $kind (expected inbox|meeting|ref|project|daily)" ;;
esac

state_ensure_tree

base="$(slug_from_desc "$title")" || clift_exit 2 "title is empty after slug normalization"
kind_dir="$(note_root)/$kind"
mkdir -p "$kind_dir"
slug="$(slug_resolve_collision "$base" "$kind_dir" md)"

# Build tags JSON array from the list flag.
tag_count="${CLIFT_FLAG_TAG_COUNT:-0}"
tags_json="[]"
if (( tag_count > 0 )); then
  tag_args=()
  for (( i=1; i<=tag_count; i++ )); do
    var="CLIFT_FLAG_TAG_${i}"
    tag_args+=("${!var}")
  done
  tags_json="$(printf '%s\n' "${tag_args[@]}" | jq -R . | jq -sc .)"
fi

template_args=()
template_file="$CLI_DIR/templates/$kind.md"
if [[ -f "$template_file" ]]; then
  template_args=(--template "$template_file")
fi

# note_store_new emits the key on stdout; capture it for our own printf and
# the optional $EDITOR launch. Stdout from this script is reserved for the
# key (so callers can do `key=$(jarvis note new "...")`).
key="$(note_store_new "$kind" "$slug" "$title" \
  --tags "$tags_json" \
  ${template_args[@]+"${template_args[@]}"})"

# Optional $EDITOR — only when stdout is a tty and the user didn't opt out.
# A successful editor session re-runs the index update so frontmatter edits
# (e.g., a user-added tag) are reflected immediately.
if [[ "$no_edit" != "true" ]] && [[ -n "${EDITOR:-}" ]] && [[ -t 1 ]]; then
  "$EDITOR" "$(note_path "$key")" || true
  note_index_update "$key"
fi

log_success "$(note_path "$key")"
printf '%s\n' "$key"
