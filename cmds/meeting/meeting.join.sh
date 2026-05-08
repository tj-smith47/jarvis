#!/usr/bin/env bash
# meeting join — open the next meeting URL.
#
# Resolution order for the URL we open:
#   1. --meeting URL (explicit) — skip calendar lookup entirely.
#   2. First event in the calendar window [now, now+--in) whose title
#      matches --filter (default: any), with a non-empty .url.
#   3. Same event but with .url empty: try meeting_url_extract on .location
#      then .description then .title.
#
# Open via `open` (macOS), then `xdg-open` (Linux), falling back to print.
# Exit codes:
#   0  URL opened (or printed when no opener available)
#   1  no URL found in window (or no event matched filter)
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
# Calendar provider stack — order matters; provider.sh defines the registry,
# backends register themselves on source.
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
      {"name":"filter","type":"string"},
      {"name":"meeting","type":"string"}]' \
    "$@"
fi

window="${CLIFT_FLAGS[in]:-15m}"
filter="${CLIFT_FLAGS[filter]:-}"
explicit="${CLIFT_FLAGS[meeting]:-}"

# Validate window early so we fail before sourcing the calendar pipeline.
if [[ ! "$window" =~ ^[0-9]+[smhd]$ ]]; then
  clift_exit 2 "invalid --in: $window (expected Ns|Nm|Nh|Nd, e.g. 30m, 2h)"
fi

# Resolve profile via state_profile_dir's export side-effect (sets
# JARVIS_PROFILE), then read it back. The directory itself isn't used
# here — calendar_events takes a profile name, not a path.
state_profile_dir >/dev/null
profile="$JARVIS_PROFILE"

_meeting_open_url() {
  local url="$1"
  if command -v open >/dev/null 2>&1; then
    open "$url"
    return
  fi
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url"
    return
  fi
  printf '%s\n' "$url"
}

if [[ -n "$explicit" ]]; then
  _meeting_open_url "$explicit"
  exit 0
fi

now_iso="$(native_now_iso)"
now_epoch="$(native_now_epoch)"

# Resolve --in to a horizon ISO. Bash arith handles the unit math; native_*
# helpers honor JARVIS_FAKE_NOW so tests get deterministic windows.
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
if [[ -z "$events" ]]; then
  printf 'meeting: no events in next %s (calendar provider configured?)\n' "$window" >&2
  exit 1
fi

# Pick the first event matching --filter (or any event if no filter).
# `test/2` runs the regex case-insensitively via the `i` flag.
if [[ -n "$filter" ]]; then
  target="$(printf '%s\n' "$events" \
            | jq -rc --arg f "$filter" 'select(.title | test($f; "i"))' \
            | head -1)"
else
  target="$(printf '%s\n' "$events" | head -1)"
fi

if [[ -z "$target" ]]; then
  printf 'meeting: no events match --filter %s in next %s\n' "$filter" "$window" >&2
  exit 1
fi

url="$(printf '%s' "$target" | jq -r '.url // ""')"
if [[ -z "$url" ]]; then
  # Fallback chain: location → description → title. The calendar providers
  # already run an ICS-side url-fallback (lib/calendar/ics.sh
  # _calendar_ics_apply_url_fallback) but applescript / gcalcli only emit
  # the link field. Re-run the extractor here so every provider gets the
  # same surface.
  for field in location description title; do
    candidate="$(printf '%s' "$target" | jq -r --arg f "$field" '.[$f] // ""')"
    [[ -z "$candidate" ]] && continue
    url="$(printf '%s' "$candidate" | meeting_url_extract 2>/dev/null || true)"
    [[ -n "$url" ]] && break
  done
fi

if [[ -z "$url" ]]; then
  title="$(printf '%s' "$target" | jq -r '.title // "(untitled)"')"
  printf 'meeting: %s has no joinable URL (no .url, .location, .description, or .title match)\n' \
    "$title" >&2
  exit 1
fi

_meeting_open_url "$url"
