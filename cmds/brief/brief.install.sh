#!/usr/bin/env bash
# brief install — wire `jarvis brief` into the user's crontab so the
# morning briefing fires automatically. Closes the friction loop where
# the user knows brief is the right command but never remembers to run
# it.
#
# Modes:
#   default                install at the configured time + channel
#   --at HH:MM             override fire time (default 08:00)
#   --notify <channel>     pipe the brief through a notify channel
#                          (gotify/slack/email/local). Required values
#                          for that channel must already be set in
#                          [notify.<channel>] — run `jarvis notify
#                          configure <channel>` first.
#   --uninstall            remove the cron line
#   --dry-run              print the cron line that would be installed
#                          (no crontab mutation)
#
# Sentinel: `JARVIS_BRIEF_DAILY` (in a comment on the cron line) so the
# detection regex doesn't false-positive on user-installed cron lines
# that happen to call `jarvis brief` for unrelated reasons.

set -euo pipefail

: "${FRAMEWORK_DIR:=${CLIFT_FRAMEWORK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}}"
: "${CLI_DIR:=${JARVIS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"

# shellcheck source=/dev/null
source "${FRAMEWORK_DIR}/lib/log/log.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/profile.sh"

if ! declare -p CLIFT_FLAGS >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/runtime/standalone_argv.sh"
  jarvis_standalone_argv_parse \
    '[{"name":"at","type":"string"},
      {"name":"notify","type":"string"},
      {"name":"uninstall","type":"bool"},
      {"name":"dry-run","type":"bool"}]' \
    "$@"
fi

at="${CLIFT_FLAGS[at]:-08:00}"
channel="${CLIFT_FLAGS[notify]:-}"
do_uninstall="${CLIFT_FLAGS[uninstall]:-}"
dry_run="${CLIFT_FLAGS[dry-run]:-}"

if [[ ! "$at" =~ ^([01]?[0-9]|2[0-3]):([0-5][0-9])$ ]]; then
  clift_exit 2 "invalid --at: $at (expected HH:MM, e.g. 08:00)"
fi
hour="${BASH_REMATCH[1]#0}"; [[ -z "$hour" ]] && hour=0
minute="${BASH_REMATCH[2]#0}"; [[ -z "$minute" ]] && minute=0

case "$channel" in
  ""|local|gotify|slack|email) ;;
  *) clift_exit 2 "invalid --notify channel: $channel (expected: local|gotify|slack|email)" ;;
esac

state_profile_dir >/dev/null
profile="${JARVIS_PROFILE:-default}"

# Resolve the absolute jarvis binary so the cron wrapper doesn't depend
# on PATH being set in the cron shell. Falls back to the literal "jarvis"
# when not on PATH (the user can fix later by editing crontab manually).
if jarvis_bin="$(command -v jarvis 2>/dev/null)" && [[ -n "$jarvis_bin" ]]; then
  :
else
  jarvis_bin="jarvis"
fi

# Build the cron line. The trailing comment carries the sentinel so we
# can detect + uninstall this exact line later without false-positives.
SENTINEL='JARVIS_BRIEF_DAILY'
cmd_part="${jarvis_bin} brief --short --profile ${profile}"
[[ -n "$channel" ]] && cmd_part="${cmd_part} --notify ${channel}"
cron_line="${minute} ${hour} * * * ${cmd_part}  # ${SENTINEL}"

if [[ "$dry_run" == "true" ]]; then
  printf '%s\n' "$cron_line"
  exit 0
fi

_cron_current() { crontab -l 2>/dev/null || true; }
_cron_has_sentinel() { _cron_current | grep -qF "$SENTINEL"; }

if [[ "$do_uninstall" == "true" ]]; then
  if ! _cron_has_sentinel; then
    log_info "brief install: not installed (no $SENTINEL line); nothing to do"
    exit 0
  fi
  new_crontab="$(_cron_current | grep -vF "$SENTINEL" || true)"
  if [[ -z "$new_crontab" ]]; then
    crontab -r 2>/dev/null || true
  else
    printf '%s\n' "$new_crontab" | crontab -
  fi
  log_success "brief install: uninstalled"
  exit 0
fi

if _cron_has_sentinel; then
  # Replace the existing line in place to honor the new --at / --notify
  # flags. Safer than "no-op if any sentinel" because the user may be
  # changing their daily-fire time.
  new_crontab="$( { _cron_current | grep -vF "$SENTINEL" || true; printf '%s\n' "$cron_line"; } )"
else
  new_crontab="$( { _cron_current; printf '%s\n' "$cron_line"; } )"
fi
printf '%s\n' "$new_crontab" | crontab -

log_success "brief install: scheduled at ${at} daily (${cron_line})"
