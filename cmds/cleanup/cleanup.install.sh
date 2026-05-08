#!/usr/bin/env bash
# cleanup install — wire `jarvis cleanup --confirm` into the user's
# crontab. Mirror of brief.install.sh; same sentinel pattern, same
# atomic crontab-mutation approach.
#
# Sentinel: JARVIS_CLEANUP_DAILY

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
      {"name":"before","type":"string"},
      {"name":"uninstall","type":"bool"},
      {"name":"dry-run","type":"bool"}]' \
    "$@"
fi

at="${CLIFT_FLAGS[at]:-03:00}"
before="${CLIFT_FLAGS[before]:-90d}"
do_uninstall="${CLIFT_FLAGS[uninstall]:-}"
dry_run="${CLIFT_FLAGS[dry-run]:-}"

if [[ ! "$at" =~ ^([01]?[0-9]|2[0-3]):([0-5][0-9])$ ]]; then
  clift_exit 2 "invalid --at: $at (expected HH:MM, e.g. 03:00)"
fi
hour="${BASH_REMATCH[1]#0}"; [[ -z "$hour" ]] && hour=0
minute="${BASH_REMATCH[2]#0}"; [[ -z "$minute" ]] && minute=0

if [[ ! "$before" =~ ^[0-9]+[dwm]$ ]]; then
  clift_exit 2 "invalid --before: $before (expected Nd|Nw|Nm)"
fi

state_profile_dir >/dev/null
profile="${JARVIS_PROFILE:-default}"

if jarvis_bin="$(command -v jarvis 2>/dev/null)" && [[ -n "$jarvis_bin" ]]; then
  :
else
  jarvis_bin="jarvis"
fi

SENTINEL='JARVIS_CLEANUP_DAILY'
cron_line="${minute} ${hour} * * * ${jarvis_bin} cleanup --confirm --before ${before} --profile ${profile}  # ${SENTINEL}"

if [[ "$dry_run" == "true" ]]; then
  printf '%s\n' "$cron_line"
  exit 0
fi

_cron_current() { crontab -l 2>/dev/null || true; }
_cron_has_sentinel() { _cron_current | grep -qF "$SENTINEL"; }

if [[ "$do_uninstall" == "true" ]]; then
  if ! _cron_has_sentinel; then
    log_info "cleanup install: not installed (no $SENTINEL line); nothing to do"
    exit 0
  fi
  new_crontab="$(_cron_current | grep -vF "$SENTINEL" || true)"
  if [[ -z "$new_crontab" ]]; then
    crontab -r 2>/dev/null || true
  else
    printf '%s\n' "$new_crontab" | crontab -
  fi
  log_success "cleanup install: uninstalled"
  exit 0
fi

if _cron_has_sentinel; then
  new_crontab="$( { _cron_current | grep -vF "$SENTINEL" || true; printf '%s\n' "$cron_line"; } )"
else
  new_crontab="$( { _cron_current; printf '%s\n' "$cron_line"; } )"
fi
printf '%s\n' "$new_crontab" | crontab -

log_success "cleanup install: scheduled at ${at} daily (before=${before})"
