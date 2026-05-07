#!/usr/bin/env bash
# ICS calendar provider. Reads [calendar.ics] source (URL or path), parses
# VEVENT blocks, emits NDJSON {start,end,title,url} filtered to [since,until).
#
# Failure modes:
#   - missing [calendar.ics] source        -> exit 1
#   - URL fetch failure (curl error)       -> exit 1, curl stderr passes through
#   - file path that doesn't exist         -> exit 1
#
# Behavior notes:
#   - Folded ICS lines (CRLF + SP/TAB continuation per RFC 5545 §3.1) are
#     unfolded before parsing.
#   - Field regexes anchor on `<NAME>[:;]` to avoid false-positive matches
#     (e.g. `URLISH:` no longer matches `URL`).
#   - DTSTART without trailing `Z` (TZID-local timestamps) is skipped with a
#     stderr warning. Cross-platform local-time -> UTC requires GNU date,
#     which isn't portable; until that lands, those events drop.
#   - outlook-ics is registered as an alias — same parser, separate config
#     name for readability ([calendar] provider = "outlook-ics" reads better
#     than `ics` for a Microsoft feed).
#   - Only the explicit `URL:` field is consulted; extracting meeting URLs
#     from SUMMARY/LOCATION/DESCRIPTION lives in lib/calendar/meeting_url.sh.

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_CALENDAR_ICS_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_CALENDAR_ICS_LOADED=1

calendar_ics_events() {
  local since="$1" until="$2" profile="${3:-${JARVIS_PROFILE:-default}}"
  local source
  source="$(config_get calendar.ics.source "" "$profile")"
  [[ -z "$source" ]] && return 1

  local body
  if [[ "$source" =~ ^https?:// ]]; then
    command -v curl >/dev/null 2>&1 || return 1
    # Refuse SSRF-prone targets up front. The user normally configures a
    # public ICS feed; an internal host or a cloud metadata IP is almost
    # certainly a misconfiguration or attempted exfil — fail closed with a
    # diagnostic instead of curling it.
    local _host="${source#http://}"; _host="${_host#https://}"
    _host="${_host%%[/?#:]*}"
    case "$_host" in
      localhost|127.0.0.1|0.0.0.0|::1|169.254.169.254)
        printf 'ics: refusing to fetch internal/metadata host: %s\n' "$_host" >&2
        return 1
        ;;
      10.*|192.168.*) ;& # fall-through to RFC1918 reject
      172.16.*|172.17.*|172.18.*|172.19.*|172.20.*|172.21.*|172.22.*|172.23.*) ;&
      172.24.*|172.25.*|172.26.*|172.27.*|172.28.*|172.29.*|172.30.*|172.31.*)
        printf 'ics: refusing to fetch RFC1918 host: %s\n' "$_host" >&2
        return 1
        ;;
    esac
    # Don't suppress curl stderr — `jarvis doctor` calls the provider directly
    # to surface diagnostics. Brief/standup go through the dispatcher which
    # silences provider stderr at the hot-path layer.
    if ! body="$(curl -fsSL "$source")"; then
      return 1
    fi
  else
    [[ -f "$source" ]] || return 1
    body="$(<"$source")"
  fi

  # AWK VEVENT parser:
  #   1. Strip CR + unfold continuation lines (RFC 5545 §3.1).
  #   2. Match field names anchored on `[:;]` so URLISH/SUMMARYX don't collide.
  #   3. Skip events without a UTC `Z` suffix on DTSTART (TZID-local), warn.
  #   4. JSON-escape title + url (\ first, then ").
  printf '%s\n' "$body" | awk -v since="$since" -v until="$until" '
    function emit_event() {
      if (!in_event || dt == "") return
      # Require trailing Z (UTC). TZID-local events are skipped here because
      # cross-platform local->UTC needs GNU date, which is not portable.
      if (dt !~ /Z$/) {
        printf "ics: skipping event with non-UTC DTSTART (%s)\n", dt > "/dev/stderr"
        return
      }
      dt_iso = substr(dt,1,4)"-"substr(dt,5,2)"-"substr(dt,7,2)"T"substr(dt,10,2)":"substr(dt,12,2)":"substr(dt,14,2)"Z"
      if (et != "" && et ~ /Z$/) {
        et_iso = substr(et,1,4)"-"substr(et,5,2)"-"substr(et,7,2)"T"substr(et,10,2)":"substr(et,12,2)":"substr(et,14,2)"Z"
      } else {
        et_iso = dt_iso
      }
      if (dt_iso >= since && dt_iso < until) {
        gsub(/\\/, "\\\\", title); gsub(/"/, "\\\"", title)
        gsub(/\\/, "\\\\", url);   gsub(/"/, "\\\"", url)
        printf "{\"start\":\"%s\",\"end\":\"%s\",\"title\":\"%s\",\"url\":\"%s\"}\n",
               dt_iso, et_iso, title, url
      }
    }
    function process_line(line) {
      if (line ~ /^BEGIN:VEVENT/)      { in_event = 1; dt=""; et=""; title=""; url=""; return }
      if (line ~ /^END:VEVENT/)        { emit_event(); in_event = 0; return }
      if (!in_event) return
      if (line ~ /^DTSTART[:;]/)       { sub(/^DTSTART[^:]*:/, "", line); dt = line; return }
      if (line ~ /^DTEND[:;]/)         { sub(/^DTEND[^:]*:/,   "", line); et = line; return }
      if (line ~ /^SUMMARY[:;]/)       { sub(/^SUMMARY[^:]*:/, "", line); title = line; return }
      if (line ~ /^URL[:;]/)           { sub(/^URL[^:]*:/,     "", line); url = line; return }
    }
    {
      sub(/\r$/, "")
      # RFC 5545 line unfolding: a line beginning with SP or HTAB continues
      # the previous logical line. Collect, emit on next non-continuation.
      if ($0 ~ /^[ \t]/) {
        prev = prev substr($0, 2)
        next
      }
      if (NR > 1) process_line(prev)
      prev = $0
    }
    END { if (prev != "") process_line(prev) }
  '
}

calendar_register ics calendar_ics_events
calendar_register outlook-ics calendar_ics_events
