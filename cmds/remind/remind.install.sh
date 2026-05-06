#!/usr/bin/env bash
set -euo pipefail

# Install the reminder scheduler. Backend resolution: --backend arg >
# `[scheduler] backend` in config.toml > "cron". See lib/remind/install.sh
# for the per-backend implementations.

: "${FRAMEWORK_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
: "${CLI_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# shellcheck source=/dev/null
source "${FRAMEWORK_DIR}/lib/log/log.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/profile.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/config.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/remind/install.sh"

if ! declare -p CLIFT_FLAGS >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/runtime/standalone_argv.sh"
  jarvis_standalone_argv_parse \
    '[{"name":"backend","type":"string"}]' \
    "$@"
fi

backend="$(remind_install_resolve_backend "${CLIFT_FLAGS[backend]:-}")"
remind_install "$backend"
