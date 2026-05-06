#!/usr/bin/env bash
# Atomic JSON read/write, flock-guarded.
# Writes validate via jq before rename; failures leave existing file intact.

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_STATE_JSON_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_STATE_JSON_LOADED=1

# state_json_write <path> <json-string>
# Validates via jq, writes to <path>.tmp, renames under flock.
# Tmp name mixes $$, $BASHPID, and $RANDOM so concurrent writers from the
# same parent shell (subshells share $$) don't collide on a single tmp path.
state_json_write() {
  local target="$1"
  local payload="$2"
  local tmp="${target}.tmp.$$.$BASHPID.$RANDOM"

  if ! jq -e . <<< "$payload" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 2
  fi

  state_with_lock "$target" "mv -f '$tmp' '$target'"
}

# state_json_read <path>
# Prints file contents (shared lock); exits 1 if missing, 2 if corrupt.
# Validating here gives callers a single, file-pointing error message
# instead of an opaque jq parse error two layers deeper.
state_json_read() {
  local target="$1"
  [[ -f "$target" ]] || return 1
  local content
  content="$(state_with_lock "$target" "cat '$target'")" || return 1
  if ! jq -e . <<< "$content" >/dev/null 2>&1; then
    printf 'state_json_read: corrupt JSON in %s\n' "$target" >&2
    return 2
  fi
  printf '%s' "$content"
}

# state_json_mutate <path> <jq-filter> [--arg NAME VALUE ...]
# Atomic read → apply jq filter → write, all inside one flock window. The
# filter is passed to jq via a tmp file (--from-file) so arbitrary shell
# metacharacters in the filter are safe. Optional --arg pairs thread user
# values into the filter as jq bindings (\$NAME), letting callers avoid
# embedding untrusted strings into the filter text. Filter errors, missing
# file, or rename failures → non-zero exit; target is left untouched.
state_json_mutate() {
  local target="$1"
  local filter="$2"
  shift 2
  [[ -f "$target" ]] || return 1

  # Collect any --arg NAME VALUE triplets. Values are piped to jq via a
  # NUL-delimited args file so shell metacharacters (quotes, $, backticks)
  # never touch the eval'd lock-body.
  local args_file="${target}.args.$$.$BASHPID.$RANDOM"
  : > "$args_file"
  local have_args=0
  while (( $# >= 3 )); do
    if [[ "$1" != "--arg" ]]; then
      rm -f "$args_file"
      return 2
    fi
    # NUL-delimited pairs: NAME<NUL>VALUE<NUL>
    printf '%s\0%s\0' "$2" "$3" >> "$args_file"
    have_args=1
    shift 3
  done
  if (( $# != 0 )); then
    rm -f "$args_file"
    return 2
  fi

  local tmp="${target}.tmp.$$.$BASHPID.$RANDOM"
  local filter_file="${target}.filter.$$.$BASHPID.$RANDOM"
  printf '%s' "$filter" > "$filter_file"

  # Build the jq invocation. When there are --arg pairs, read them from
  # $args_file inside the locked subshell and splat them into jq's argv.
  # xargs -0 -n2 would still invoke jq once per pair (breaking atomicity);
  # instead we build the argv in-shell via a NUL-delimited read loop.
  local status=0
  if (( have_args )); then
    # shellcheck disable=SC2016
    state_with_lock "$target" '
      declare -a _jq_args=()
      while IFS= read -r -d "" _name && IFS= read -r -d "" _value; do
        _jq_args+=(--arg "$_name" "$_value")
      done < "'"$args_file"'"
      if jq "${_jq_args[@]}" --from-file "'"$filter_file"'" "'"$target"'" > "'"$tmp"'" 2>/dev/null; then
        mv -f "'"$tmp"'" "'"$target"'"
      else
        rm -f "'"$tmp"'"
        exit 2
      fi
    ' || status=$?
  else
    state_with_lock "$target" "
      if jq --from-file '$filter_file' '$target' > '$tmp' 2>/dev/null; then
        mv -f '$tmp' '$target'
      else
        rm -f '$tmp'
        exit 2
      fi
    " || status=$?
  fi
  rm -f "$filter_file" "$args_file"
  return "$status"
}
