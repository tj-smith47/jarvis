#!/usr/bin/env bash
# AppleScript calendar provider — drives Calendar.app via `osascript`.
# macOS-only at runtime; on Linux the missing-binary path is exercised so
# brief/standup degrade cleanly when this provider is configured by mistake.
#
# Provider contract (mirrors gcalcli.sh, ics.sh):
#   - emits NDJSON {start,end,title,url} on stdout
#   - exit 1 = osascript missing OR TCC denied (Calendar not authorized)
#   - stderr is left to surface for `jarvis doctor --integrations-live`;
#     the dispatcher silences provider stderr on the brief/standup hot path.
#
# Config (per-profile config.toml):
#   [calendar]
#   provider = "applescript"
#
#   [calendar.applescript]
#   calendars        = ["Work", "Personal"]   # optional; default = all visible
#   extract_url_from = "url,location"         # optional; default = "url"
#                                              # comma-list, first hit wins
#                                              # supported tokens: url, location
#
# Wiring:
#   The .scpt program produces TSV (tab-delimited) with 5 columns per line:
#     START_ISO \t END_ISO \t TITLE \t URL_FIELD \t LOCATION_FIELD
#   AppleScript collapses tabs/newlines inside fields to spaces before emit
#   so awk can rely on the column count.
#
# Time-zone handling:
#   Brief/standup hand us UTC-Z bounds (`...T00:00:00Z`). Calendar.app stores
#   events in local wall-clock; if we passed UTC components straight through
#   they would be reinterpreted as local and the day window would drift by the
#   local TZ offset. We convert UTC -> local-naive ISO here before invoking
#   osascript, so the .scpt always sees wall-clock components matching the
#   user's local day. Output ISO is local-naive too (matches gcalcli; brief
#   renderer just chops to HH:MM and is TZ-agnostic).
#
# Error mapping:
#   `osascript` returns -1743 ("Not authorized to send Apple events to Calendar")
#   when TCC permission is denied. We detect that substring in stderr and
#   surface a friendly System Settings instruction; otherwise the original
#   stderr is passed through unchanged for the doctor live-probe path.
#
# Performance:
#   AppleScript `whose start date >= X` evaluates inside Calendar.app's Apple
#   Events bridge — sub-second for day windows, but scales poorly with calendar
#   size (Lean Crew reports 60-100s for tens-of-thousands of events). Day-windowed
#   queries from brief/standup are the supported case; the dispatcher's 5-min
#   cache absorbs repeat invocations.
#
# Constraint — comma in calendar names:
#   `calendars = ["Personal, Family"]` will misparse: the bash side joins the
#   array with `,` and the .scpt splits on `,`, so `Personal, Family` fans out
#   to `Personal` + ` Family`. Use names without commas, or rename the calendar.
#
# Limitation — recurring events:
#   `every event whose start date >= X` checks the *original* event date, not
#   expanded recurrence instances. Daily/weekly events whose first instance
#   falls outside the window will not appear. Documented in applescript.scpt
#   header and .claude/smoke/mac-calendar.md.
#
# Sources cited in applescript.scpt header.

# This is a SOURCED library — no `set -euo pipefail`. See CLAUDE.md
# "Hard Rule — sourced libraries omit `set -euo pipefail`".

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_CALENDAR_APPLESCRIPT_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_CALENDAR_APPLESCRIPT_LOADED=1

# _calendar_applescript_warn_once — emit <msg> on stderr the first time a given
# <key> is seen in this process; subsequent calls with the same key are silent.
# Used by AS-S4 (calendars-filter parse failure) and AS-S5 (unknown
# extract_url_from token) so brief/standup hot paths don't spam.
_calendar_applescript_warn_once() {
  local key="$1" msg="$2"
  local var="_JARVIS_AS_WARNED_${key//[^A-Za-z0-9]/_}"
  [[ -n "${!var:-}" ]] && return 0
  # `declare -g` forces global scope; plain `printf -v` would scope to this
  # function and the sentinel would die with the call frame.
  declare -g "$var=1"
  printf '%s\n' "$msg" >&2
}

# _calendar_applescript_calendars_csv — read calendars array from per-profile
# config.toml and return a comma-joined string for the AppleScript ARGV. Empty
# string when unset or dasel/file missing (provider treats empty as "all").
# _calendar_applescript_utc_to_local — convert UTC ISO ("...Z") to local-naive
# ISO ("YYYY-MM-DDTHH:MM:SS"). GNU `date -d` first (Linux); BSD `date -j -f`
# fallback (macOS). Pass-through if neither parses (preserves any non-Z input).
_calendar_applescript_utc_to_local() {
  local utc="$1" out epoch
  if out="$(date -d "$utc" +%Y-%m-%dT%H:%M:%S 2>/dev/null)" && [[ -n "$out" ]]; then
    printf '%s' "$out"
    return 0
  fi
  if epoch="$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$utc" "+%s" 2>/dev/null)" \
     && [[ -n "$epoch" ]]; then
    date -j -r "$epoch" "+%Y-%m-%dT%H:%M:%S"
    return 0
  fi
  printf '%s' "$utc"
}

_calendar_applescript_calendars_csv() {
  local profile="$1"
  local home cfg
  home="${JARVIS_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/jarvis}"
  cfg="$home/$profile/config.toml"
  [[ -f "$cfg" ]] || return 0
  command -v dasel >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local arr_json
  arr_json="$(dasel -i toml -o json calendar.applescript.calendars < "$cfg" 2>/dev/null || true)"
  [[ -z "$arr_json" || "$arr_json" == "null" ]] && return 0
  jq -r 'if type == "array" then map(tostring) | join(",") else "" end' <<<"$arr_json" 2>/dev/null || true
}

# _calendar_applescript_has_calendars_key — true iff config.toml for <profile>
# declares a `calendars =` line inside the `[calendar.applescript]` section.
# Cheap regex scan; used by AS-S4 to distinguish "user didn't set it" (silent)
# from "user set it but we couldn't read it" (warn). Doesn't need dasel/jq.
_calendar_applescript_has_calendars_key() {
  local profile="$1"
  local home cfg
  home="${JARVIS_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/jarvis}"
  cfg="$home/$profile/config.toml"
  [[ -f "$cfg" ]] || return 1
  awk '
    /^[[:space:]]*\[calendar\.applescript\][[:space:]]*$/{flag=1; next}
    /^[[:space:]]*\[/{flag=0}
    flag && /^[[:space:]]*calendars[[:space:]]*=/{found=1; exit}
    END{exit !found}
  ' "$cfg" 2>/dev/null
}

calendar_applescript_events() {
  local since="$1" until="$2" profile="${3:-${JARVIS_PROFILE:-default}}"

  if ! command -v osascript >/dev/null 2>&1; then
    printf 'applescript: osascript not found (macOS-only provider)\n' >&2
    return 1
  fi

  local script_path="${CLI_DIR}/lib/calendar/applescript.scpt"
  if [[ ! -f "$script_path" ]]; then
    printf 'applescript: missing helper at %s\n' "$script_path" >&2
    return 1
  fi

  local cal_csv extract_from since_local until_local
  cal_csv="$(_calendar_applescript_calendars_csv "$profile")"
  extract_from="$(config_get calendar.applescript.extract_url_from "url" "$profile")"
  since_local="$(_calendar_applescript_utc_to_local "$since")"
  until_local="$(_calendar_applescript_utc_to_local "$until")"

  # AS-S4: silent-widen-to-all is mystifying when the user explicitly set
  # `calendars = [...]`. If we got nothing back but the key is in config,
  # surface a one-shot warning so they know the filter wasn't applied.
  # Done here in the parent rather than inside _calendar_applescript_calendars_csv
  # because the helper runs in a $(...) subshell and any sentinel set there
  # dies with the subshell.
  if [[ -z "$cal_csv" ]] && _calendar_applescript_has_calendars_key "$profile"; then
    _calendar_applescript_warn_once calendars-filter \
      'applescript: could not parse [calendar.applescript].calendars (need dasel + jq); showing all calendars'
  fi

  # AS-S5: warn (one-shot per token) on tokens other than url/location so a
  # config typo like `extract_url_from = "locaton"` surfaces instead of
  # silently producing empty url fields downstream.
  local _ef_tok
  local _ef_old_ifs="$IFS"
  IFS=','
  for _ef_tok in $extract_from; do
    _ef_tok="${_ef_tok# }"; _ef_tok="${_ef_tok% }"
    case "$_ef_tok" in
      url|location|"") ;;
      *)
        _calendar_applescript_warn_once "ef-${_ef_tok}" \
          "applescript: extract_url_from token '${_ef_tok}' not recognized (supported: url, location); ignoring"
        ;;
    esac
  done
  IFS="$_ef_old_ifs"

  local err_tmp tsv rc=0
  err_tmp="$(mktemp)"
  tsv="$(osascript "$script_path" "$since_local" "$until_local" "$cal_csv" 2>"$err_tmp")" || rc=$?

  if (( rc != 0 )); then
    if grep -q -- '-1743' "$err_tmp" 2>/dev/null; then
      printf 'applescript: Calendar access not authorized (-1743)\n' >&2
      printf 'applescript: grant access in System Settings -> Privacy & Security -> Automation -> Terminal -> Calendar\n' >&2
    else
      cat "$err_tmp" >&2
    fi
    rm -f "$err_tmp"
    return 1
  fi
  rm -f "$err_tmp"

  [[ -z "$tsv" ]] && return 0

  # TSV -> NDJSON. Column order: start, end, title, url, location.
  # extract_from is a comma-list of tokens; first non-empty field wins.
  # JSON-escape order: backslash first, then double-quote.
  printf '%s' "$tsv" | awk -F'\t' -v ef="$extract_from" '
    function jesc(s) {
      gsub(/\\/, "\\\\", s)
      gsub(/"/,  "\\\"", s)
      return s
    }
    function pick_url(   n, i, tok, candidate, j) {
      n = split(ef, toks, ",")
      for (i = 1; i <= n; i++) {
        tok = toks[i]
        # trim surrounding spaces
        sub(/^[ \t]+/, "", tok); sub(/[ \t]+$/, "", tok)
        if (tok == "url") candidate = $4
        else if (tok == "location") candidate = $5
        else continue
        if (candidate != "") return candidate
      }
      return ""
    }
    NF >= 3 {
      title = jesc($3)
      url   = jesc(pick_url())
      printf "{\"start\":\"%s\",\"end\":\"%s\",\"title\":\"%s\",\"url\":\"%s\"}\n", $1, $2, title, url
    }
  '
}

calendar_register applescript calendar_applescript_events
