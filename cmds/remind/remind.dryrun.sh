#!/usr/bin/env bash
# remind dryrun <slug> — fire a scheduled reminder right now (S1 from .claude/known-bugs.md).
#
# Looks up <slug> in the active profile's reminders/, dispatches its
# (via, message) through notify_dispatch immediately, and exits with the
# dispatcher's rc (0 if any channel attempt succeeded, 1 if all failed).
#
# Does NOT touch the on-disk reminder: trigger_at, fire_count, status,
# delivery log are all unchanged. Useful exclusively for channel-config
# debugging — "does my gotify webhook actually fire?".

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
source "${CLI_DIR}/lib/state/config.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/remind/schema.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/notify/registry.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/notify/local.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/notify/gotify.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/notify/slack.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/notify/email.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/notify/dispatch.sh"

if ! declare -p CLIFT_FLAGS >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/runtime/standalone_argv.sh"
  jarvis_standalone_pos_only "$@"
fi

slug="${CLIFT_POS_1:-}"
if [[ -z "$slug" ]]; then
  clift_exit 2 'usage: jarvis remind dryrun <slug>'
fi

target="$(remind_schema_path "$slug")"
if [[ ! -f "$target" ]]; then
  printf 'no reminder named "%s"\n' "$slug" >&2
  exit 2
fi

reminder_json="$(<"$target")"
if ! jq -e . <<< "$reminder_json" >/dev/null 2>&1; then
  printf 'remind dryrun: %s is malformed JSON\n' "$target" >&2
  exit 3
fi

log_info "dryrun: dispatching $slug NOW (state file unchanged)"
notify_dispatch "$reminder_json"
