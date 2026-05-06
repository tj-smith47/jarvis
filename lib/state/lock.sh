#!/usr/bin/env bash
# flock-based single-writer guard for JSON state files.

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_STATE_LOCK_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_STATE_LOCK_LOADED=1

# state_with_lock <target-file> <command>
# Acquires an exclusive lock on <target-file>.lock, runs <command> via eval,
# releases the lock. Creates the lockfile if missing. Returns command's exit.
#
# Subshell isolation matters: callers like state_json_mutate pass bodies
# that `exit N` on jq failure. With a `{ ... }` group those exits would
# kill the entire calling script (not just the locked block). The
# `( ... )` form keeps the exit local — caller sees N as the function's
# exit status and decides what to do.
state_with_lock() {
  local target="$1"
  shift
  local lockfile="${target}.lock"
  mkdir -p "$(dirname "$lockfile")"
  : > "$lockfile"

  (
    flock 9
    # eval is intentional: callers pass shell snippets (redirects, subshells)
    # as a single string, not argv — e.g. state_with_lock "$f" 'mv a b'.
    # shellcheck disable=SC2294
    eval "$@"
  ) 9<"$lockfile"
}
