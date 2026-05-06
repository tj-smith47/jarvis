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
source "${CLI_DIR}/lib/task/store.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/config.sh"

if ! declare -p CLIFT_FLAGS >/dev/null 2>&1; then
  declare -A CLIFT_FLAGS=()
fi

all="${CLIFT_FLAGS[all]:-}"
pri="${CLIFT_FLAGS[priority]:-}"
project="${CLIFT_FLAGS[project]:-}"
due="${CLIFT_FLAGS[due]:-}"
want_json="${CLIFT_FLAGS[json]:-}"
want_yaml="${CLIFT_FLAGS[yaml]:-}"
want_jira="${CLIFT_FLAGS[jira]:-}"

# Pull jira-assigned issues (open + in-progress) and project them onto the
# task record shape so the merged list filters/renders identically.
# Synthetic fields: slug=<KEY>, project="jira", priority="med", due=null,
# status="open", source="jira", url=<browse-link>, seq=10^9 + index so jira
# rows sort after local tasks. Missing/unconfigured jira is silent — caller
# expectation is "include if available."
jira_records='[]'
if [[ "$want_jira" == "true" ]]; then
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/integrations/jira.sh"
  if jira_out="$(jira_my_open_issues 2>/dev/null)" && [[ -n "$jira_out" ]]; then
    jira_records="$(printf '%s\n' "$jira_out" | jq -s '
      to_entries | map(
        .value as $row | {
          slug:     $row.key,
          desc:     $row.summary,
          priority: "med",
          due:      null,
          project:  "jira",
          status:   "open",
          source:   "jira",
          url:      $row.url,
          seq:      (1000000000 + .key)
        })')"
  fi
fi

tasks_dir="$(task_store_dir)"
# Save/restore nullglob so we don't clobber the caller's shell options
# (matches the task_store_list pattern in lib/task/store.sh).
_had_nullglob=0
shopt -q nullglob && _had_nullglob=1
shopt -s nullglob
files=("$tasks_dir"/*.json)
(( _had_nullglob )) || shopt -u nullglob
unset _had_nullglob

# Resilient-skip malformed JSON: one bad file shouldn't kill the whole listing.
# Validate each file up-front with `jq -e .`; warn on failures, drop from the
# slurp input. The `+"${array[@]}"` expansion form guards against `set -u`
# firing when the array is empty (bash 4 quirk).
valid_files=()
for f in "${files[@]+"${files[@]}"}"; do
  if jq -e . "$f" >/dev/null 2>&1; then
    valid_files+=("$f")
  else
    log_warn "skipping malformed task record: ${f##*/}"
  fi
done
files=("${valid_files[@]+"${valid_files[@]}"}")

# Build filtered array via single jq pass.
# Filter values are passed via --arg to avoid injection (projects / due
# values with quotes would otherwise break the filter string).
# Empty-string args get selected-out by a guard in the filter itself.
# Jira-projected records are concatenated before filtering so the same
# predicates apply uniformly (e.g. --project jira filters to jira rows).
if (( ${#files[@]} == 0 )); then
  local_records='[]'
else
  local_records="$(jq -s '.' "${files[@]}")"
fi

records="$(jq -n \
  --argjson local "$local_records" \
  --argjson jira "$jira_records" \
  --arg all "$all" \
  --arg pri "$pri" \
  --arg project "$project" \
  --arg due "$due" \
  '
    ($local + $jira)
    | map(
        select($all == "true" or .status == "open")
        | select($pri == "" or .priority == $pri)
        | select($project == "" or .project == $project)
        | select($due == "" or .due == $due)
      )
    | sort_by(.seq)
  ')"

count="$(jq 'length' <<< "$records")"

if [[ "$want_json" == "true" ]]; then
  printf '%s\n' "$records"
  exit 0
fi

if [[ "$want_yaml" == "true" ]]; then
  printf '%s\n' "$records" | yq -P eval '.' -
  exit 0
fi

if (( count == 0 )); then
  if [[ "$all" == "true" ]]; then
    printf '  no tasks\n'
  else
    printf '  no open tasks\n'
  fi
  exit 0
fi

_use_color() {
  [[ -z "${NO_COLOR:-}" ]]
}

_pr_color() {
  if ! _use_color; then
    printf '%s' "$1"
    return
  fi
  case "$1" in
    high) printf '\033[31m%s\033[0m' "$1" ;;
    med)  printf '\033[33m%s\033[0m' "$1" ;;
    low)  printf '\033[90m%s\033[0m' "$1" ;;
    *)    printf '%s' "$1" ;;
  esac
}

if _use_color; then
  printf '\n  \033[1m%-24s %-6s %-40s %-10s %s\033[0m\n' "SLUG" "PRI" "DESCRIPTION" "DUE" "PROJECT"
else
  printf '\n  %-24s %-6s %-40s %-10s %s\n' "SLUG" "PRI" "DESCRIPTION" "DUE" "PROJECT"
fi
while IFS=$'\t' read -r slug desc priority due_s project_s; do
  [[ -z "$slug" ]] && continue
  # Render null/empty as the same "—" placeholder for both due and
  # project so the column doesn't look broken (asymmetric blank vs "—"
  # looks like a render bug to readers).
  [[ "$due_s" == "null" || -z "$due_s" ]] && due_s="—"
  [[ "$project_s" == "null" || -z "$project_s" ]] && project_s="—"
  if _use_color; then
    # Data row uses %-15s for PRI to absorb ANSI escapes (~9 bytes of
    # \033[NNm...\033[0m) so visible alignment matches the header's %-6s.
    printf '  %-24s %-15s %-40s %-10s %s\n' \
      "$slug" "$(_pr_color "$priority")" "$desc" "$due_s" "$project_s"
  else
    printf '  %-24s %-6s %-40s %-10s %s\n' \
      "$slug" "$priority" "$desc" "$due_s" "$project_s"
  fi
done < <(jq -r '.[] | [.slug, .desc, .priority, (.due // "null"), (.project // "null")] | @tsv' <<< "$records")
printf '\n'
