#!/usr/bin/env bash
set -euo pipefail

: "${FRAMEWORK_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
: "${CLI_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# shellcheck source=/dev/null
source "${FRAMEWORK_DIR}/lib/log/log.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/profile.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/lock.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/json.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/frontmatter.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/note/resolve.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/note/index.sh"

if ! declare -p CLIFT_FLAGS >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/runtime/standalone_argv.sh"
  jarvis_standalone_pos_only "$@"
fi

count="${CLIFT_POS_COUNT:-0}"
q="${CLIFT_POS_1:-}"

if [[ -z "$q" ]]; then
  clift_exit 2 "usage: jarvis note tag <slug> [+tag]... [-tag]..."
fi
if (( count < 2 )); then
  clift_exit 2 "usage: jarvis note tag <slug> [+tag]... [-tag]... (at least one +tag/-tag required)"
fi

set +e
key="$(note_resolve "$q" 2>/dev/null)"
rc=$?
set -e
case "$rc" in
  0) ;;
  1) clift_exit 1 "note not found: $q" ;;
  2) clift_exit 2 "note query is ambiguous: $q" ;;
  *) clift_exit "$rc" "note_resolve failed for: $q" ;;
esac

file="$(note_path "$key")"

# Collect adds / removes from positionals 2..N. Validate the +/- prefix
# up front so we don't half-mutate when one op is malformed.
adds=()
removes=()
for (( i=2; i<=count; i++ )); do
  var="CLIFT_POS_$i"
  op="${!var}"
  case "$op" in
    +?*) adds+=("${op#+}") ;;
    -?*) removes+=("${op#-}") ;;
    *) clift_exit 2 "bad tag op: '$op' (expected +tag or -tag)" ;;
  esac
done

# JSON-encode the lists once, outside the lock.
adds_json="[]"
if (( ${#adds[@]} > 0 )); then
  adds_json="$(printf '%s\n' "${adds[@]}" | jq -R . | jq -cs .)"
fi
removes_json="[]"
if (( ${#removes[@]} > 0 )); then
  removes_json="$(printf '%s\n' "${removes[@]}" | jq -R . | jq -cs .)"
fi

# Locked read-modify-write: another writer (e.g. note_store_append)
# could append to the body between read and rewrite, and a naive atomic
# rename would clobber that append. Hold the same lock note_store_append
# acquires so the two operations serialize.
_jarvis_tag_apply() {
  local file="$JARVIS_TAG_FILE"
  local adds_json="$JARVIS_TAG_ADDS"
  local removes_json="$JARVIS_TAG_REMOVES"
  local body="" fm="" fm_json updated yaml tmp
  fm_split "$file" body fm
  if [[ -z "$fm" ]]; then
    fm_json="{}"
  else
    fm_json="$(dasel -i yaml -o json <<< "$fm" 2>/dev/null)" || return 1
  fi
  updated="$(jq --argjson a "$adds_json" --argjson r "$removes_json" '
    .tags = (
      ((.tags // []) + $a)
      | unique
      | map(select(. as $t | ($r | index($t)) | not))
    )
  ' <<< "$fm_json")" || return 1
  yaml="$(dasel -i json -o yaml <<< "$updated")" || return 1
  case "$body" in
    '') ;;
    *$'\n') ;;
    *) body="${body}"$'\n' ;;
  esac
  tmp="${file}.tmp.$$.$BASHPID.$RANDOM"
  { printf -- '---\n%s\n---\n' "$yaml"; printf '%s' "$body"; } > "$tmp"
  mv -f "$tmp" "$file"
}

JARVIS_TAG_FILE="$file" \
JARVIS_TAG_ADDS="$adds_json" \
JARVIS_TAG_REMOVES="$removes_json" \
state_with_lock "$file" '_jarvis_tag_apply'

note_index_update "$key"
new_tags="$(fm_parse "$file" | jq -r '.tags // [] | sort | join(", ")')"
log_success "$key tags: ${new_tags:-(none)}"
