#!/usr/bin/env bash
# gcalcli calendar provider. Shells to `gcalcli agenda --tsv` and maps the
# tab-separated agenda rows to our NDJSON event shape: {start,end,title,url}.
#
# TSV columns (gcalcli >=4.x):
#   start_date \t start_time \t end_date \t end_time \t link \t title
#
# Failure modes:
#   - gcalcli not on PATH      -> exit 1, no stderr (silent: covered by doctor)
#   - gcalcli nonzero exit     -> exit 1, single-line stderr ("gcalcli: agenda call failed")
#   - empty agenda             -> exit 0, no output

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_CALENDAR_GCALCLI_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_CALENDAR_GCALCLI_LOADED=1

calendar_gcalcli_events() {
  local since="$1" until="$2"
  local _profile="${3:-}"  # accepted by registry contract; unused (gcalcli reads ~/.gcalclirc)
  if ! command -v gcalcli >/dev/null 2>&1; then
    return 1
  fi
  local tsv
  # Don't suppress gcalcli's stderr — its diagnostic ("auth error", "network …")
  # is what `jarvis doctor` and direct invocation surface. Dispatcher already
  # silences for brief/standup.
  if ! tsv="$(gcalcli agenda --tsv "$since" "$until")"; then
    printf 'gcalcli: agenda call failed\n' >&2
    return 1
  fi
  [[ -z "$tsv" ]] && return 0
  # Columns: start_date \t start_time \t end_date \t end_time \t link \t title.
  # Tabs inside titles/URLs are unhandled — gcalcli is assumed to sanitize.
  # Escape order matters: backslash first, then double-quote.
  printf '%s\n' "$tsv" \
    | awk -F'\t' 'NF >= 6 {
        t = $6; u = $5
        gsub(/\\/, "\\\\", t); gsub(/"/, "\\\"", t)
        gsub(/\\/, "\\\\", u); gsub(/"/, "\\\"", u)
        printf "{\"start\":\"%sT%s:00\",\"end\":\"%sT%s:00\",\"title\":\"%s\",\"url\":\"%s\"}\n", \
               $1, $2, $3, $4, t, u
      }'
}

calendar_register gcalcli calendar_gcalcli_events
