#!/usr/bin/env bash
set -euo pipefail

# Resolve framework/CLI dirs with fallback so this script runs standalone in tests.
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
source "${CLI_DIR}/lib/task/store.sh"

if ! declare -p CLIFT_FLAGS >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/runtime/standalone_argv.sh"
  jarvis_standalone_argv_parse \
    '[{"name":"desc","type":"string"},
      {"name":"priority","type":"string"},
      {"name":"due","type":"string"},
      {"name":"project","type":"string"},
      {"name":"tag-add","type":"list"},
      {"name":"tag-remove","type":"list"},
      {"name":"tags-clear","type":"bool"}]' \
    "$@"
fi

input="${CLIFT_POS_1:-}"
if [[ -z "$input" ]]; then
  clift_exit 2 "usage: jarvis task edit <slug> [--desc|--priority|--due|--project VAL] [--tag-add T] [--tag-remove T] [--tags-clear]"
fi

new_desc="${CLIFT_FLAGS[desc]:-}"
new_pri="${CLIFT_FLAGS[priority]:-}"
new_due="${CLIFT_FLAGS[due]:-}"
new_project="${CLIFT_FLAGS[project]:-}"
tags_clear="${CLIFT_FLAGS[tags-clear]:-}"

# --tag-add / --tag-remove are list flags. Collect (lowercased, trimmed,
# deduped) JSON arrays for both. --tags-clear empties the field outright;
# explicit and a strict superset of "remove every existing tag", so it's a
# separate flag rather than reusing `--tag-remove '*'` magic.
_tags_to_json_array() {
  local upper="$1" count_var="CLIFT_FLAG_${1}_COUNT"
  local count="${!count_var:-0}"
  (( count == 0 )) && { printf '[]'; return 0; }
  local lines=""
  for _i in $(seq 1 "$count"); do
    local var="CLIFT_FLAG_${upper}_${_i}"
    lines+="${!var}"$'\n'
  done
  printf '%s' "$lines" | jq -Rcs '
    split("\n")
    | map(ascii_downcase | sub("^[ \t]+"; "") | sub("[ \t]+$"; ""))
    | map(select(length > 0))
    | unique_by(.)'
}

tags_add_json="$(_tags_to_json_array TAG_ADD)"
tags_remove_json="$(_tags_to_json_array TAG_REMOVE)"

# Validate any new tags up front so an invalid --tag-add fails before the
# write rather than after part of the mutation lands.
invalid="$(jq -r '.[] | select(test("^[a-z0-9][a-z0-9_-]*$") | not) | .' <<< "$tags_add_json")"
if [[ -n "$invalid" ]]; then
  clift_exit 2 "invalid --tag-add value(s): $invalid (allowed: lowercase alnum, '-', '_')"
fi

if [[ -z "$new_desc" && -z "$new_pri" && -z "$new_due" && -z "$new_project" \
      && "$tags_add_json" == "[]" && "$tags_remove_json" == "[]" \
      && "$tags_clear" != "true" ]]; then
  clift_exit 2 "nothing to change — pass at least one of --desc/--priority/--due/--project/--tag-add/--tag-remove/--tags-clear"
fi

if [[ -n "$new_pri" ]]; then
  case "$new_pri" in
    low|med|high) ;;
    *) clift_exit 2 "invalid --priority: $new_pri (expected low|med|high)" ;;
  esac
fi

due_is_clear=0
if [[ -n "$new_due" ]]; then
  case "$new_due" in
    today|tomorrow) ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    clear) due_is_clear=1 ;;
    *) clift_exit 2 "invalid --due: $new_due (expected today|tomorrow|YYYY-MM-DD|clear)" ;;
  esac
fi

tasks_dir="$(task_store_dir)"
slug="$(slug_resolve_prefix "$input" "$tasks_dir")" || exit 1

# Build the jq filter from the set flags. Values are threaded through as
# --arg bindings so the filter text stays a fixed literal regardless of user
# input — no shell-metacharacter escaping required. The whole read-mutate-write
# happens inside task_store_mutate's single flock window.
filter='.'
args=()
if [[ -n "$new_desc" ]]; then
  filter="$filter | .desc = \$desc"
  args+=(--arg desc "$new_desc")
fi
if [[ -n "$new_pri" ]]; then
  filter="$filter | .priority = \$pri"
  args+=(--arg pri "$new_pri")
fi
if [[ -n "$new_project" ]]; then
  filter="$filter | .project = \$project"
  args+=(--arg project "$new_project")
fi
if [[ -n "$new_due" ]]; then
  if (( due_is_clear )); then
    # Literal null — no --arg binding needed.
    filter="$filter | .due = null"
  else
    filter="$filter | .due = \$due"
    args+=(--arg due "$new_due")
  fi
fi

# Tags mutation order: clear → remove → add. Clear wins because it's the
# explicit "drop everything" flag; --tag-remove on an already-cleared field
# is a no-op (which is consistent — it stays empty); --tag-add appends after
# remove so a single invocation `--tag-remove foo --tag-add foo` won't drop
# foo (it gets removed then re-added). Existing records without `.tags` get
# `.tags // []` defaulted on read.
#
# state_json_mutate only accepts --arg (string) bindings — not --argjson —
# so the JSON arrays are passed as strings and parsed via fromjson inside
# the filter. The conversion is round-trip-safe because the input JSON came
# from `jq -c` so it's already minified and valid.
if [[ "$tags_clear" == "true" ]]; then
  filter="$filter | .tags = []"
fi
if [[ "$tags_remove_json" != "[]" ]]; then
  filter="$filter | .tags = ((.tags // []) - (\$tags_remove | fromjson))"
  args+=(--arg tags_remove "$tags_remove_json")
fi
if [[ "$tags_add_json" != "[]" ]]; then
  filter="$filter | .tags = (((.tags // []) + (\$tags_add | fromjson)) | unique)"
  args+=(--arg tags_add "$tags_add_json")
fi

task_store_mutate "$slug" "$filter" "${args[@]}"

log_success "edited ${slug}"
