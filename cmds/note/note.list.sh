#!/usr/bin/env bash
set -euo pipefail

: "${FRAMEWORK_DIR:=${CLIFT_FRAMEWORK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}}"
: "${CLI_DIR:=${JARVIS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"

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
    '[{"name":"kind","type":"string"},
      {"name":"tag","type":"list"},
      {"name":"since","type":"string"},
      {"name":"archived","type":"bool"},
      {"name":"limit","type":"string"},
      {"name":"json","type":"bool"},
      {"name":"yaml","type":"bool"}]' \
    "$@"
fi

kind="${CLIFT_FLAGS[kind]:-}"
archived="${CLIFT_FLAGS[archived]:-}"
limit="${CLIFT_FLAGS[limit]:-50}"
json_out="${CLIFT_FLAGS[json]:-}"
yaml_out="${CLIFT_FLAGS[yaml]:-}"
since="${CLIFT_FLAGS[since]:-}"

# Build the requested-tags JSON array from the CLIFT_FLAG_TAG_* shape that
# both the router and standalone_argv expose.
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

# Validate --limit (string flag, but must be a non-negative integer).
if ! [[ "$limit" =~ ^[0-9]+$ ]]; then
  clift_exit 2 "--limit must be a non-negative integer (got: $limit)"
fi

idx="$(note_index_file)"
if [[ ! -f "$idx" ]]; then
  if [[ "$json_out" == "true" ]]; then
    printf '[]\n'
  else
    log_info "no notes recorded yet — try \`jarvis note new\`"
  fi
  exit 0
fi

# Filter pipeline:
#   1. Hydrate keys into the row objects so .key is available downstream.
#   2. Hide archived rows unless --archived is set.
#   3. Restrict by --kind when provided.
#   4. Restrict by --tag (any of the requested tags matches any note tag).
#   5. Restrict by --since against updated_at (lexical compare on RFC3339
#      sorts correctly).
#   6. Sort newest-first.
filtered="$(jq \
    --arg kind "$kind" \
    --arg archived "$archived" \
    --argjson tags "$tags_json" \
    --arg since "$since" '
  to_entries
  | map(.value + {key: .key})
  | map(select(($archived == "true") or ((.archived // false) | not)))
  | map(select($kind == "" or .kind == $kind))
  | map(select(
      ($tags | length) == 0
      or any((.tags // [])[]; . as $t | $tags | index($t))
    ))
  | map(select($since == "" or (.updated_at // "0") >= $since))
  | sort_by(.updated_at // "")
  | reverse
' "$idx")"

limited="$(jq --argjson n "$limit" '.[:$n]' <<< "$filtered")"

if [[ "$json_out" == "true" ]]; then
  printf '%s\n' "$limited"
  exit 0
fi

if [[ "$yaml_out" == "true" ]]; then
  if [[ "$(jq 'length' <<< "$limited")" == "0" ]]; then
    printf '[]\n'
  else
    dasel -r json -w yaml <<< "$limited"
  fi
  exit 0
fi

count="$(jq 'length' <<< "$limited")"
if (( count == 0 )); then
  log_info "no notes match"
  exit 0
fi

# Grouped table render. group_by preserves jq's natural ordering, which
# after our reverse-sort means the most-recent group is first within each
# bucket but groups themselves are alphabetical by kind — that's the
# documented contract.
render_grouped() {
  jq -r '
    group_by(.kind // "other")[]
    | "\n" + ((.[0].kind // "other") | ascii_upcase) + "  (\(length))",
      (.[] | "  \(.title // .key)    \(.tags // [] | join(", "))")
  ' <<< "$limited"
}

if [[ -t 1 ]] && [[ -n "${PAGER:-}" ]]; then
  # PAGER may carry args; intentional word-split.
  # shellcheck disable=SC2086
  render_grouped | $PAGER
else
  render_grouped
fi
