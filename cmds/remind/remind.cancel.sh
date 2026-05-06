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
source "${CLI_DIR}/lib/state/ndjson.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/remind/schema.sh"

# clift_did_you_mean (Levenshtein-based) is provided by the framework. If
# the symbol isn't on PATH (older clift, vendored copy missing), we fall
# back to a simple substring suggester so the cmd still gives helpful
# output instead of swallowing the user's typo (review S5).
if [[ -f "${FRAMEWORK_DIR}/lib/flags/errors.sh" ]]; then
  # shellcheck source=/dev/null
  source "${FRAMEWORK_DIR}/lib/flags/errors.sh"
fi

if ! declare -p CLIFT_FLAGS >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/runtime/standalone_argv.sh"
  jarvis_standalone_pos_only "$@"
fi

slug="${CLIFT_POS_1:-}"
if [[ -z "$slug" ]]; then
  clift_exit 2 'usage: jarvis remind cancel <slug>'
fi

target="$(remind_schema_path "$slug")"
if [[ -f "$target" ]]; then
  rm -f "$target"
  log_success "cancelled: $slug"
  exit 0
fi

# ---------- not found: did-you-mean ----------

# Collect every reminder slug in the current profile.
profile_dir="$(state_profile_dir)"
candidates=""
if [[ -d "$profile_dir/reminders" ]]; then
  shopt -s nullglob
  for f in "$profile_dir"/reminders/*.json; do
    base="${f##*/}"
    candidates+="${base%.json} "
  done
  shopt -u nullglob
fi

suggestion=""
if declare -f clift_did_you_mean >/dev/null 2>&1; then
  suggestion="$(clift_did_you_mean "$slug" "$candidates")"
fi

# Fallback: simple substring contains, cap 3.
if [[ -z "$suggestion" && -n "$candidates" ]]; then
  # Use first 3 chars of the typo as a probe; if the typo is shorter,
  # use the whole thing.
  probe="${slug:0:3}"
  for cand in $candidates; do
    if [[ "$cand" == *"$probe"* ]]; then
      suggestion="$suggestion${suggestion:+ }$cand"
    fi
  done
  # Truncate to 3 suggestions.
  read -ra suggs <<< "$suggestion"
  if (( ${#suggs[@]} > 3 )); then
    suggestion="${suggs[0]} ${suggs[1]} ${suggs[2]}"
  fi
fi

if [[ -n "$suggestion" ]]; then
  printf 'no reminder named "%s"\n  did you mean: %s\n' "$slug" "$suggestion" >&2
else
  printf 'no reminder named "%s"\n' "$slug" >&2
fi
exit 2
