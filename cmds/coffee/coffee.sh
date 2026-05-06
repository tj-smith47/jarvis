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
source "${CLI_DIR}/lib/state/ndjson.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/focus/log.sh"

if ! declare -p CLIFT_FLAGS >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/runtime/standalone_argv.sh"
  jarvis_standalone_argv_parse \
    '[{"name":"size","type":"string"},{"name":"milk","type":"bool"},{"name":"no-log","type":"bool"}]' \
    "$@"
fi

size="${CLIFT_FLAGS[size]:-medium}"
milk="${CLIFT_FLAGS[milk]:-}"
no_log="${CLIFT_FLAGS[no-log]:-}"

if [[ "$milk" == "true" ]]; then
  beverage="${size} coffee with milk"
else
  beverage="${size} coffee"
fi

if command -v gum &>/dev/null; then
  gum spin --spinner meter --title "Brewing your ${beverage}…" -- sleep 3
else
  log_info "Brewing your ${beverage}…"
  sleep 3
fi

# Append a coffee row to focus.log so today's session count reflects it.
# `|| true` keeps a logging failure from masking the user-facing success;
# coffee should never block on bookkeeping. --no-log skips the row
# entirely (testing escape hatch + opt-out for users who don't want
# coffee polluting focus stats).
if [[ "$no_log" != "true" ]]; then
  focus_log_append_coffee || log_warn "could not append coffee row to focus.log"
fi

log_success "☕  One ${beverage}, ready."
