#!/usr/bin/env bash
# Dynamic positional completers for `jarvis task done|edit|remove`.
# Sourced by the framework's `_complete` dispatcher at completion time.
# Convention: clift_complete_<task-colons→underscores>_pos<N>.

# Resolve jarvis lib dir relative to this file (works inside cmds/task/overrides/).
_JARVIS_TASK_COMPLETION_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)"

# shellcheck source=/dev/null
source "$_JARVIS_TASK_COMPLETION_LIB/state/profile.sh"
# shellcheck source=/dev/null
source "$_JARVIS_TASK_COMPLETION_LIB/state/lock.sh"
# shellcheck source=/dev/null
source "$_JARVIS_TASK_COMPLETION_LIB/state/json.sh"
# shellcheck source=/dev/null
source "$_JARVIS_TASK_COMPLETION_LIB/task/store.sh"

_jarvis_emit_slugs() {
  local prefix="$1" status="$2"
  local slug
  while IFS= read -r slug; do
    [[ -n "$slug" ]] || continue
    [[ "$slug" == "$prefix"* ]] && printf '%s\n' "$slug"
  done < <(task_store_list "$status" 2>/dev/null || true)
  return 0
}

clift_complete_task_done_pos1() {
  _jarvis_emit_slugs "${1:-}" open
}

clift_complete_task_edit_pos1() {
  _jarvis_emit_slugs "${1:-}" ""
}

clift_complete_task_remove_pos1() {
  _jarvis_emit_slugs "${1:-}" ""
}
