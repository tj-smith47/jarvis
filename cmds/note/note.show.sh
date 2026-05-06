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
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/note/current.sh"

if ! declare -p CLIFT_FLAGS >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/runtime/standalone_argv.sh"
  jarvis_standalone_argv_parse \
    '[{"name":"raw","type":"bool"}]' \
    "$@"
fi

q="${CLIFT_POS_1:-}"
raw="${CLIFT_FLAGS[raw]:-}"

if [[ -z "$q" ]]; then
  if ! q="$(note_current_resolve 2>/dev/null)"; then
    clift_exit 2 "no current note set; provide a slug or title"
  fi
fi

# note_resolve emits the key on stdout; non-zero rc → miss (1) or
# ambiguous (2). Capture rc with set +e — the `if ! cmd; then rc=$?`
# pattern silently rewrites $? to 0 once the body runs, swallowing the
# real return code.
set +e
key="$(note_resolve "$q" 2>/dev/null)"
rc=$?
set -e
if (( rc != 0 )); then
  case "$rc" in
    1) clift_exit 1 "note not found: $q" ;;
    2) clift_exit 2 "note query is ambiguous: $q" ;;
    *) clift_exit "$rc" "note_resolve failed for: $q" ;;
  esac
fi

file="$(note_path "$key")"
[[ -f "$file" ]] || clift_exit 1 "note file missing on disk: $key"

# Renderer chain: glow > bat > cat. --raw forces cat (skip rendering).
if [[ "$raw" == "true" ]]; then
  cat "$file"
elif command -v glow >/dev/null 2>&1; then
  glow "$file"
elif command -v bat >/dev/null 2>&1; then
  bat -l md --style plain "$file"
else
  cat "$file"
fi
