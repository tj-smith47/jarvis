#!/usr/bin/env bash
set -euo pipefail

# Hidden tick subcommand. Called by cron/systemd-timer (configured by
# `remind --install`); end-users invoke it manually only for debugging.
# All work lives in lib/remind/tick.sh — this file just wires the deps.

: "${FRAMEWORK_DIR:=${CLIFT_FRAMEWORK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}}"
: "${CLI_DIR:=${JARVIS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"

# shellcheck source=/dev/null
source "${FRAMEWORK_DIR}/lib/log/log.sh"
for f in state/profile state/lock state/json state/ndjson state/config \
         remind/parse remind/schedule remind/schema \
         notify/registry notify/local notify/gotify notify/slack notify/email \
         notify/dispatch remind/tick; do
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/${f}.sh"
done

if ! declare -p CLIFT_FLAGS >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/runtime/standalone_argv.sh"
  jarvis_standalone_pos_only "$@"
fi

remind_tick_run
