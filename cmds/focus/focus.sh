#!/usr/bin/env bash
set -euo pipefail

# Resolve framework/CLI dirs with fallback so this script runs standalone in tests.
: "${FRAMEWORK_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
: "${CLI_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# shellcheck source=/dev/null
source "${FRAMEWORK_DIR}/lib/log/log.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/profile.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/lock.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/ndjson.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/focus/log.sh"

# Standalone-argv fallback (tests, direct invocation). Mirrors the router
# contract: CLIFT_POS_* + CLIFT_FLAGS keyed by canonical flag name.
if ! declare -p CLIFT_FLAGS >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/runtime/standalone_argv.sh"
  jarvis_standalone_argv_parse \
    '[{"name":"on","type":"string"},{"name":"silent","type":"bool"}]' \
    "$@"
fi

duration="${CLIFT_POS_1:-}"
topic="${CLIFT_FLAGS[on]:-}"
silent="${CLIFT_FLAGS[silent]:-}"

if [[ -z "$duration" ]]; then
  clift_exit 2 "usage: jarvis focus <duration> [--on TOPIC]"
fi

if [[ ! "$duration" =~ ^[0-9]+[smhd]$ ]]; then
  clift_exit 2 "duration must match ^[0-9]+[smhd]\$ (e.g. 25m, 10s, 1h)"
fi

# Convert to seconds for `sleep`.
_unit="${duration: -1}"
_value="${duration%?}"
case "$_unit" in
  s) seconds="$_value" ;;
  m) seconds=$(( _value * 60 )) ;;
  h) seconds=$(( _value * 3600 )) ;;
  d) seconds=$(( _value * 86400 )) ;;
esac

# Log the start row BEFORE installing the EXIT trap. If we trap first and
# the start-write fails (jq error, disk full), the trap would emit an end
# row with no matching start. Sequencing avoids that orphan-end class.
focus_log_append start "$duration" "$topic"

# Single EXIT trap covers normal exit, SIGINT (Ctrl+C), SIGTERM, SIGHUP,
# and `set -e` failures. SIGKILL is uncatchable in any language; orphan
# starts surface via `jarvis doctor`. The guard prevents a double-write
# in the unlikely case the trap re-enters.
_focus_finalize_done=0
_focus_finalize() {
  (( _focus_finalize_done )) && return 0
  _focus_finalize_done=1
  # `|| true` keeps a logging failure from masking the real exit code we
  # want the parent shell to see (130 for SIGINT, etc.).
  focus_log_append end "" "$topic" || true
}
trap _focus_finalize EXIT

title="Focus: ${topic:-unspecified} (${duration})"
if [[ "$silent" != "true" ]] && command -v gum &>/dev/null; then
  gum spin --spinner points --title "$title" -- sleep "$seconds"
else
  [[ "$silent" == "true" ]] || log_info "$title"
  sleep "$seconds"
fi

if [[ "$silent" != "true" ]]; then
  log_success "✓ ${duration} focus session on ${topic:-—} complete."
else
  log_success "✓ complete."
fi
