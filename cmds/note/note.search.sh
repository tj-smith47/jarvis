#!/usr/bin/env bash
set -euo pipefail

: "${FRAMEWORK_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
: "${CLI_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# shellcheck source=/dev/null
source "${FRAMEWORK_DIR}/lib/log/log.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/profile.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/note/resolve.sh"

if ! declare -p CLIFT_FLAGS >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/runtime/standalone_argv.sh"
  jarvis_standalone_argv_parse \
    '[{"name":"regex","type":"bool"},
      {"name":"kind","type":"string"},
      {"name":"tag","type":"list"}]' \
    "$@"
fi

q="${CLIFT_POS_1:-}"
regex="${CLIFT_FLAGS[regex]:-}"
kind="${CLIFT_FLAGS[kind]:-}"

if [[ -z "$q" ]]; then
  clift_exit 2 "usage: jarvis note search <query> [--regex] [--kind KIND] [--tag T]..."
fi

command -v rg >/dev/null 2>&1 || clift_exit 3 "rg required for note search"

# Build requested-tags JSON array.
tag_count="${CLIFT_FLAG_TAG_COUNT:-0}"
tags_json="[]"
if (( tag_count > 0 )); then
  tag_arr=()
  for (( i=1; i<=tag_count; i++ )); do
    var="CLIFT_FLAG_TAG_${i}"
    tag_arr+=("${!var}")
  done
  tags_json="$(printf '%s\n' "${tag_arr[@]}" | jq -R . | jq -cs .)"
fi

root="$(note_root)"
idx="$(note_index_file)"
[[ -d "$root" ]] || exit 0

# Default: smart-case literal. --regex switches to a regex query (still
# smart-case unless caller pre-anchored).
rg_args=(--json)
if [[ "$regex" == "true" ]]; then
  rg_args+=(--smart-case)
else
  rg_args+=(--smart-case --fixed-strings)
fi

# rg returns 1 on "no matches" — that's a normal result here, not an error.
set +e
raw="$(rg "${rg_args[@]}" -- "$q" "$root" 2>/dev/null)"
rc=$?
set -e
# Exit codes: 0 = matches, 1 = no matches, 2+ = real error.
if (( rc > 1 )); then
  clift_exit "$rc" "rg failed (exit $rc) searching for: $q"
fi
[[ -z "$raw" ]] && exit 0

# Single jq pass: load index via --slurpfile, derive key from path,
# apply kind + tag filters, emit "<rel>:<line>: <text>". Filtering in
# one process keeps cost O(1) in the number of matches rather than the
# O(forks) shape that a per-line bash loop produces.
#
# When .index.json is missing (fresh state, no notes yet) the slurpfile
# arg is required by jq, so handle that branch with a stub array.
if [[ -f "$idx" ]]; then
  jq -r --slurpfile idx "$idx" \
        --arg root "$root" \
        --arg kind "$kind" \
        --argjson tags "$tags_json" '
    select(.type == "match")
    | .data as $d
    | ($d.path.text | sub($root + "/"; "") | sub("\\.md$"; "")) as $key
    | ($idx[0][$key] // {}) as $row
    | select($kind == "" or ($row.kind // "") == $kind)
    | select(($tags | length) == 0
             or any(($row.tags // [])[]; . as $t | $tags | index($t)))
    | "\($d.path.text | sub($root + "/"; "")):\($d.line_number): \($d.lines.text | rtrimstr("\n"))"
  ' <<< "$raw"
else
  # No index → kind/tag filters can't apply; if either was set, no rows
  # qualify; otherwise emit raw matches.
  if [[ -n "$kind" || "$tag_count" -gt 0 ]]; then
    exit 0
  fi
  jq -r --arg root "$root" '
    select(.type == "match")
    | .data as $d
    | "\($d.path.text | sub($root + "/"; "")):\($d.line_number): \($d.lines.text | rtrimstr("\n"))"
  ' <<< "$raw"
fi
