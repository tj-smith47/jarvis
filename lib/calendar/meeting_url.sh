#!/usr/bin/env bash
# Pure helper: extract first Zoom/Meet/Teams URL from stdin.
#
# Patterns are tried in priority order. Within each pattern, the first match
# in the input wins. No I/O beyond stdin/stdout.
#
# Patterns (priority order):
#   https://[*.]zoom.us/j/<id>[?<query>]
#   https://meet.google.com/<slug>
#   https://teams.microsoft.com/l/meetup-join/<...>
#   https://teams.live.com/meet/<...>

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_MEETING_URL_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_MEETING_URL_LOADED=1

meeting_url_extract() {
  local input url pat
  input="$(cat)"
  for pat in \
    'https://[a-zA-Z0-9.-]*zoom\.us/j/[0-9]+(\?[^[:space:]"<>]*)?' \
    'https://meet\.google\.com/[a-z0-9-]+' \
    'https://teams\.microsoft\.com/l/meetup-join/[^[:space:]"<>]+' \
    'https://teams\.live\.com/meet/[^[:space:]"<>]+'; do
    url="$(printf '%s' "$input" | grep -oE "$pat" | head -1)"
    if [[ -n "$url" ]]; then
      printf '%s\n' "$url"
      return 0
    fi
  done
  return 1
}

# Export so subshells (e.g. `bash -c "... | meeting_url_extract"`) inherit it.
export -f meeting_url_extract
