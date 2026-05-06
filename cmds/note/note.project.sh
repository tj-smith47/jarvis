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

spec="${CLIFT_POS_1:-}"
no_edit="${CLIFT_FLAGS[no-edit]:-}"

if [[ -z "$spec" ]]; then
  clift_exit 2 "usage: jarvis note project <proj>/<title> [--no-edit]"
fi
if [[ "$spec" != */* ]]; then
  clift_exit 2 "project requires <proj>/<title>: got $spec"
fi

proj="${spec%%/*}"
title="${spec#*/}"
if [[ -z "$proj" || -z "$title" ]]; then
  clift_exit 2 "project requires <proj>/<title>: got $spec"
fi

state_ensure_tree

proj_slug="$(slug_from_desc "$proj")" || clift_exit 2 "proj is empty after slug normalization"
title_slug="$(slug_from_desc "$title")" || clift_exit 2 "title is empty after slug normalization"

proj_dir="$(note_root)/project/$proj_slug"
mkdir -p "$proj_dir"

# Resolve collision within the project subdir; pass "md" so we don't
# silently miss markdown files (default ext is "json").
title_slug="$(slug_resolve_collision "$title_slug" "$proj_dir" md)"
slug="$proj_slug/$title_slug"

# Optional template — only attach if the file actually exists.
template_args=()
if [[ -f "$CLI_DIR/templates/project.md" ]]; then
  template_args=(--template "$CLI_DIR/templates/project.md")
fi

key="$(note_store_new project "$slug" "$title" \
  ${template_args[@]+"${template_args[@]}"})"

if [[ "$no_edit" != "true" ]] && [[ -n "${EDITOR:-}" ]] && [[ -t 1 ]]; then
  "$EDITOR" "$(note_path "$key")" || true
  note_index_update "$key"
fi

log_success "$(note_path "$key")"
printf '%s\n' "$key"
