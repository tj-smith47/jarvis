#!/usr/bin/env bash
# meeting next — peek at the next upcoming meeting.
#
# Default render is one line: "HH:MM  <title>  in <countdown>  <url>"
# --json emits the structured event {start, title, url, in_minutes, in_str}
# so consumers can build dashboards / status lines without scraping.
#
# Source-of-truth: calendar_events for the [now, now+--in) window. Same
# pipeline as `meeting join`.
#
# Exit codes:
#   0  rendered an event (or empty JSON `{}` with --json)
#   1  no events in window
#   2  bad flag

set -euo pipefail

: "${FRAMEWORK_DIR:=${CLIFT_FRAMEWORK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}}"
: "${CLI_DIR:=${JARVIS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"

# shellcheck source=/dev/null
source "${FRAMEWORK_DIR}/lib/log/log.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/profile.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/config.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/cache/file.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/calendar/provider.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/calendar/none.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/calendar/ics.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/calendar/gcalcli.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/calendar/applescript.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/calendar/meeting_url.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/native/clock.sh"

if ! declare -p CLIFT_FLAGS >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/runtime/standalone_argv.sh"
  jarvis_standalone_argv_parse \
    '[{"name":"in","type":"string"},
      {"name":"json","type":"bool"}]' \
    "$@"
fi

window="${CLIFT_FLAGS[in]:-1d}"
want_json="${CLIFT_FLAGS[json]:-}"

if [[ ! "$window" =~ ^[0-9]+[smhd]$ ]]; then
  clift_exit 2 "invalid --in: $window (expected Ns|Nm|Nh|Nd, e.g. 30m, 2h, 1d)"
fi

profile="$(state_profile_dir >/dev/null && printf '%s\n' "$JARVIS_PROFILE")"

now_iso="$(native_now_iso)"
now_epoch="$(native_now_epoch)"

n="${window%[smhd]}"
u="${window: -1}"
case "$u" in
  s) sec=$n ;;
  m) sec=$((n*60)) ;;
  h) sec=$((n*3600)) ;;
  d) sec=$((n*86400)) ;;
esac
horizon_epoch=$(( now_epoch + sec ))
horizon_iso="$(native_epoch_to_iso "$horizon_epoch")"

events="$(calendar_events "$now_iso" "$horizon_iso" "$profile" 2>/dev/null || true)"
target="$(printf '%s' "$events" | head -1)"

if [[ -z "$target" ]]; then
  if [[ "$want_json" == "true" ]]; then
    printf '{}\n'
  else
    printf 'no upcoming meeting in next %s\n' "$window"
  fi
  exit 1
fi

# Compute countdown via native epoch so JARVIS_FAKE_NOW stays the only
# source-of-truth for "now" — `date -d` math here would silently drift in
# tests that pin time to a fake clock.
start_iso="$(printf '%s' "$target" | jq -r '.start // ""')"
start_epoch="$(native_resolve_to_epoch "$start_iso" 2>/dev/null || printf '0')"
in_secs=$(( start_epoch - now_epoch ))
(( in_secs < 0 )) && in_secs=0

# Format countdown: <60s → "now", <60m → "Xm", <24h → "XhYm", else "Xd".
if   (( in_secs < 60 ));   then in_str="now"
elif (( in_secs < 3600 )); then in_str="$((in_secs / 60))m"
elif (( in_secs < 86400 )); then
  h=$((in_secs / 3600))
  m=$(( (in_secs % 3600) / 60 ))
  if (( m == 0 )); then in_str="${h}h"
  else in_str="${h}h ${m}m"
  fi
else in_str="$((in_secs / 86400))d"
fi

# URL fallback: same chain as meeting join — .url then location/desc/title
# extraction. Avoids the case where `meeting next --json | jq -r .url`
# returns empty for an event we know has a Zoom link in the location.
url="$(printf '%s' "$target" | jq -r '.url // ""')"
if [[ -z "$url" ]]; then
  for field in location description title; do
    candidate="$(printf '%s' "$target" | jq -r --arg f "$field" '.[$f] // ""')"
    [[ -z "$candidate" ]] && continue
    url="$(printf '%s' "$candidate" | meeting_url_extract 2>/dev/null || true)"
    [[ -n "$url" ]] && break
  done
fi

title="$(printf '%s' "$target" | jq -r '.title // "(untitled)"')"

if [[ "$want_json" == "true" ]]; then
  jq -nc \
    --arg start "$start_iso" \
    --arg title "$title" \
    --arg url "$url" \
    --arg in_str "$in_str" \
    --argjson in_minutes "$((in_secs / 60))" \
    '{start:$start, title:$title, url:$url, in_minutes:$in_minutes, in_str:$in_str}'
  exit 0
fi

# HH:MM is the local-naive start clipped at the colon-seconds. Same shape as
# brief/standup so the user reads one consistent time format across rollups.
time_str="$(printf '%s' "$start_iso" | sed -E 's/^.*T//; s/:[0-9]+Z?$//')"
if [[ -n "$url" ]]; then
  printf '%s  %s  in %s  %s\n' "$time_str" "$title" "$in_str" "$url"
else
  printf '%s  %s  in %s\n' "$time_str" "$title" "$in_str"
fi
