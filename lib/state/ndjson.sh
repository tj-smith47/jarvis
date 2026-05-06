#!/usr/bin/env bash
# Append-only NDJSON store for jarvis state (focus.log).
# Validates each row as JSON before append; corrupt input never lands.
# Append uses POSIX O_APPEND semantics inside flock — concurrent writers
# from the same parent shell serialize cleanly without torn lines.

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_STATE_NDJSON_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_STATE_NDJSON_LOADED=1

# ndjson_append <path> <json-string>
# Validates <json-string> via jq; bad JSON → exit 2, file untouched.
# Creates parent dir + lockfile as needed.
#
# Payload is piped via stdin into a `cat >> target` inside the lock,
# which side-steps eval-quoting hazards entirely (no shell escaping of
# the payload bytes). The here-string `<<<` adds a trailing newline so
# each row lands as one line.
ndjson_append() {
  local target="$1"
  local payload="$2"

  if ! jq -e . <<< "$payload" >/dev/null 2>&1; then
    return 2
  fi

  mkdir -p "$(dirname "$target")"
  state_with_lock "$target" "cat >> '$target'" <<< "$payload"
}

# ndjson_read <path>
# Emits file contents as-is on stdout under shared lock.
# Missing file → empty stdout, exit 0 (callers treat as "no rows yet").
ndjson_read() {
  local target="$1"
  [[ -f "$target" ]] || return 0
  state_with_lock "$target" "cat '$target'"
}
