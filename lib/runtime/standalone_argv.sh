#!/usr/bin/env bash
# Standalone argv → CLIFT_FLAGS/CLIFT_POS_* fallback parser.
#
# Context: jarvis command scripts (cmds/note/note.add.sh, etc.) live under
# the router/parser pipeline in production — the router pre-populates
# CLIFT_FLAGS + CLIFT_POS_* and hands the script an empty $@. In tests and
# other standalone invocations, CLIFT_FLAGS is undeclared and $@ holds the
# raw argv. This helper covers the standalone path with a single shared
# implementation so each command doesn't grow its own ad-hoc parser.
#
# Usage (from a command script):
#   if ! declare -p CLIFT_FLAGS >/dev/null 2>&1; then
#     source "${CLI_DIR}/lib/runtime/standalone_argv.sh"
#     jarvis_standalone_argv_parse \
#       '[{"name":"tag","type":"list"},{"name":"on","type":"string"},
#         {"name":"no-timestamp","type":"bool"},{"name":"format","type":"string"}]' \
#       "$@"
#   fi
#
# Spec shape (JSON array, one entry per flag):
#   [{"name":"tag","type":"list"},
#    {"name":"on","type":"string"},
#    {"name":"no-timestamp","type":"bool"},
#    {"name":"format","type":"string"}]
#
# Contract:
#   - Declares global associative array CLIFT_FLAGS and sets entries
#     keyed by canonical flag name (no --) for scalar + bool flags.
#   - List flags export as CLIFT_FLAG_<UPPER_NAME>_1, ..._2, ... plus
#     CLIFT_FLAG_<UPPER_NAME>_COUNT. Dashes in the flag name are
#     normalized to underscores in the env-var suffix (matches the
#     router/parser contract documented in CLAUDE.md).
#   - Positional args populate CLIFT_POS_1 ... CLIFT_POS_N plus
#     CLIFT_POS_COUNT.
#   - `--` terminates flag parsing; every remaining arg is a positional.
#   - A leading `--` in the caller's argv is tolerated (readability).
#   - Unknown --flag tokens are tolerated as string flags with the next
#     arg as their value. Callers who want strict rejection should
#     add a post-parse `declare -p CLIFT_FLAGS` audit; jarvis commands
#     use clift_exit 2 inside their dispatchers if needed.
#
# Return codes: 0 on success; 2 if spec is empty/invalid.

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_STANDALONE_ARGV_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_STANDALONE_ARGV_LOADED=1

# Internal: write $val into the right env var shape for $name based on $type.
# Depends on caller-local `_jv_types` assoc array (the jq-derived map).
_jv_assign() {
  local name="$1" val="$2"
  local type="${_jv_types[$name]:-string}"
  if [[ "$type" == "list" ]]; then
    local upper="${name^^}"; upper="${upper//-/_}"
    local count_var="CLIFT_FLAG_${upper}_COUNT"
    local count="${!count_var:-0}"
    count=$((count+1))
    printf -v "CLIFT_FLAG_${upper}_${count}" '%s' "$val"
    printf -v "$count_var" '%s' "$count"
    # Two separate exports — passing "$count_var" as a positional to export
    # literally exports the string value of count_var (shellcheck SC2163).
    export "CLIFT_FLAG_${upper}_${count}"
    export "CLIFT_FLAG_${upper}_COUNT"
  else
    # shellcheck disable=SC2034  # consumed by caller via "${CLIFT_FLAGS[$name]}"
    CLIFT_FLAGS["$name"]="$val"
  fi
}

# jarvis_standalone_pos_only "$@"
# Positional-only variant for commands that declare no flags. Mirrors the
# router contract for CLIFT_POS_* / CLIFT_POS_COUNT and seeds an empty
# CLIFT_FLAGS so consumers can read `${CLIFT_FLAGS[name]:-}` without
# having to guard the assoc-array's existence first.
#
# Why a separate entry: the main parser refuses an empty flag spec
# (`return 2` on `_jv_types == 0`), and the spec is mandatory. This
# entry skips spec validation entirely — there's nothing to validate.
jarvis_standalone_pos_only() {
  declare -gA CLIFT_FLAGS 2>/dev/null || true
  CLIFT_FLAGS=()
  local pos_count=0
  while (( $# > 0 )); do
    pos_count=$((pos_count+1))
    printf -v "CLIFT_POS_$pos_count" '%s' "$1"
    export "CLIFT_POS_$pos_count"
    shift
  done
  export CLIFT_POS_COUNT="$pos_count"
}

jarvis_standalone_argv_parse() {
  local spec="$1"; shift
  [[ -z "$spec" ]] && return 2
  # Tolerate a leading `--` (readability for callers).
  [[ "${1:-}" == "--" ]] && shift

  # Build name→type lookup from the spec via a single jq call.
  local -A _jv_types=()
  local line n t
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    n="${line%%=*}"; t="${line#*=}"
    _jv_types["$n"]="$t"
  done < <(jq -r '.[] | "\(.name)=\(.type)"' <<< "$spec" 2>/dev/null)
  # If jq failed (invalid spec), refuse rather than pretend to parse.
  (( ${#_jv_types[@]} > 0 )) || return 2

  # Declare the globals the caller expects. Use `declare -gA` so the assoc
  # array is visible in the sourcing shell.
  declare -gA CLIFT_FLAGS 2>/dev/null || true
  # Reset any residual state from a previous invocation in the same shell.
  CLIFT_FLAGS=()

  local pos_count=0
  local a name val type
  while (( $# > 0 )); do
    a="$1"
    case "$a" in
      --)
        shift
        while (( $# > 0 )); do
          pos_count=$((pos_count+1))
          printf -v "CLIFT_POS_$pos_count" '%s' "$1"
          export "CLIFT_POS_$pos_count"
          shift
        done
        ;;
      --*=*)
        name="${a%%=*}"; name="${name#--}"
        val="${a#*=}"
        _jv_assign "$name" "$val"
        shift
        ;;
      --*)
        name="${a#--}"
        type="${_jv_types[$name]:-string}"
        if [[ "$type" == "bool" ]]; then
          # shellcheck disable=SC2034  # caller reads via "${CLIFT_FLAGS[$name]}"
          CLIFT_FLAGS["$name"]="true"
          shift
        else
          _jv_assign "$name" "${2:-}"
          # `shift 2` with $#=1 returns 1; under the caller's set -e
          # that aborts the script for what is otherwise a benign
          # missing-value (e.g. an unknown trailing --flag tolerated as
          # a string slot). Guard against the end-of-args case
          # explicitly so a wrong-argv shape never panics.
          if (( $# >= 2 )); then
            shift 2
          else
            shift
          fi
        fi
        ;;
      *)
        pos_count=$((pos_count+1))
        printf -v "CLIFT_POS_$pos_count" '%s' "$a"
        export "CLIFT_POS_$pos_count"
        shift
        ;;
    esac
  done
  export CLIFT_POS_COUNT="$pos_count"
}
