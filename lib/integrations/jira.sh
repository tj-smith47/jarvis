#!/usr/bin/env bash
# Jira integration. Shells to `jira` CLI. --plain output is TSV; parsed
# with awk and escaped for JSON. jira's stderr is not suppressed —
# diagnostics bubble through to `jarvis doctor`.
#
# Failure modes:
#   - jira not on PATH       -> exit 1, no stderr
#   - jira nonzero exit      -> exit 1; jira's own stderr is allowed to bubble
#                               (e.g. "auth required") — same convention as
#                               gh.sh.

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_INTEGRATIONS_JIRA_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_INTEGRATIONS_JIRA_LOADED=1

_jira_base_url() {
  local profile="$1"
  config_get jira.base_url "https://jira.example.com" "$profile"
}

_jira_me() {
  command -v jira >/dev/null 2>&1 || return 1
  # Let `jira me`'s stderr through so the auth-required hint is visible to
  # `jarvis doctor --integrations-live` and to brief/standup --verbose. Hot
  # paths (brief / standup / status) silence stderr at the call site via
  # _silence(); doctor lets it bubble.
  jira me
}

_jira_emit_ndjson() {
  local out="$1" base="$2"
  # Columns past STATUS are optional — older shims and `jira` configs that
  # don't expose priority/duedate/parent emit only the first three. The
  # awk emits empty strings for any missing column so consumers can
  # `// ""` cleanly.
  printf '%s\n' "$out" | awk -F'\t' -v base="$base" '
    function jesc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
    NR > 1 && NF >= 3 {
      k = $1; s = $2; st = $3
      pri = (NF >= 4 ? $4 : "")
      due = (NF >= 5 ? $5 : "")
      par = (NF >= 6 ? $6 : "")
      printf "{\"key\":\"%s\",\"summary\":\"%s\",\"status\":\"%s\",\"url\":\"%s/browse/%s\",\"priority\":\"%s\",\"due\":\"%s\",\"parent\":\"%s\"}\n",
             jesc(k), jesc(s), jesc(st), base, k, jesc(pri), jesc(due), jesc(par)
    }'
}

jira_in_flight() {
  local profile="${1:-${JARVIS_PROFILE:-default}}"
  command -v jira >/dev/null 2>&1 || return 1
  local me out
  me="$(_jira_me)" || return 1
  # Extended columns surface priority badge, due date, and parent epic in
  # consumer renders — these were buried metadata pre-fix, even though
  # the jira CLI exposes them in one round trip.
  if ! out="$(jira issue list -a"$me" -s"In Progress" --plain \
                --columns key,summary,status,priority,duedate,parent)"; then
    return 1
  fi
  _jira_emit_ndjson "$out" "$(_jira_base_url "$profile")"
}

# Open + in-progress issues assigned to current user. Wider than jira_in_flight
# (which is brief/standup's "what am I actively working on right now"); this
# returns everything not yet started or in flight, suitable for merging into
# `task list`.
jira_my_open_issues() {
  local profile="${1:-${JARVIS_PROFILE:-default}}"
  command -v jira >/dev/null 2>&1 || return 1
  local me out
  me="$(_jira_me)" || return 1
  if ! out="$(jira issue list -a"$me" -s"To Do" -s"In Progress" --plain \
                --columns key,summary,status,priority,duedate,parent)"; then
    return 1
  fi
  _jira_emit_ndjson "$out" "$(_jira_base_url "$profile")"
}

jira_my_comments_since() {
  local since="$1" profile="${2:-${JARVIS_PROFILE:-default}}"
  command -v jira >/dev/null 2>&1 || return 1
  local me; me="$(_jira_me)" || return 1
  # in_flight rows carry key + summary + url; we keep summary/url in a side
  # map so each emitted comment row can carry its issue's display context
  # ("[KEY] body" alone forces the reader to remember what KEY is, and the
  # comment URL was previously dropped — there was no way to click through
  # to the comment from a standup draft).
  local in_flight
  in_flight="$(jira_in_flight "$profile")" || return 1
  [[ -z "$in_flight" ]] && return 0
  local base; base="$(_jira_base_url "$profile")"
  local keys
  keys="$(printf '%s\n' "$in_flight" | jq -r '.key')"
  [[ -z "$keys" ]] && return 0
  local key out summary url
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    summary="$(printf '%s\n' "$in_flight" | jq -r --arg k "$key" 'select(.key == $k) | .summary' | head -1)"
    url="$base/browse/$key"
    # 2>/dev/null is intentional: a multi-key sweep over in-flight issues
    # routinely hits 404s when an issue was just transitioned/deleted; the
    # noise on stderr drowns real signals. `|| continue` swallows the row
    # quietly. Other integrations (gh, deploys) don't loop, so they don't
    # need this guard.
    out="$(jira issue comment list "$key" --plain --columns id,author,created,body 2>/dev/null)" || continue
    printf '%s\n' "$out" | awk -F'\t' \
        -v me="$me" -v since="$since" -v key="$key" \
        -v summary="$summary" -v url="$url" '
      function jesc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
      NR > 1 && NF >= 4 && $2 == me && $3 >= since {
        body=""
        for (i=4; i<=NF; i++) body = body (i==4?"":" ") $i
        printf "{\"key\":\"%s\",\"ts\":\"%s\",\"body\":\"%s\",\"summary\":\"%s\",\"url\":\"%s\"}\n",
               key, $3, jesc(body), jesc(summary), jesc(url)
      }'
  done <<< "$keys"
}
