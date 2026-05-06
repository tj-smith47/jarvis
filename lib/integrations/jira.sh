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
  # `jira me` prints the auth-required hint to stderr on a fresh machine —
  # callers (jira_in_flight, jira_my_comments_since) treat exit 1 as "not
  # configured" and skip the section, so the auth hint becomes redundant
  # noise. doctor --integrations-live invokes jira_in_flight directly and
  # routes through this same path; the auth error there is visible because
  # jira's nonzero exit propagates and the live-probe handler reports it.
  jira me 2>/dev/null
}

_jira_emit_ndjson() {
  local out="$1" base="$2"
  printf '%s\n' "$out" | awk -F'\t' -v base="$base" '
    NR > 1 && NF >= 3 {
      k=$1; s=$2; st=$3
      gsub(/\\/, "\\\\", k); gsub(/"/, "\\\"", k)
      gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s)
      gsub(/\\/, "\\\\", st); gsub(/"/, "\\\"", st)
      printf "{\"key\":\"%s\",\"summary\":\"%s\",\"status\":\"%s\",\"url\":\"%s/browse/%s\"}\n",
             k, s, st, base, k
    }'
}

jira_in_flight() {
  local profile="${1:-${JARVIS_PROFILE:-default}}"
  command -v jira >/dev/null 2>&1 || return 1
  local me out
  me="$(_jira_me)" || return 1
  if ! out="$(jira issue list -a"$me" -s"In Progress" --plain --columns key,summary,status)"; then
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
  if ! out="$(jira issue list -a"$me" -s"To Do" -s"In Progress" \
                --plain --columns key,summary,status)"; then
    return 1
  fi
  _jira_emit_ndjson "$out" "$(_jira_base_url "$profile")"
}

jira_my_comments_since() {
  local since="$1" profile="${2:-${JARVIS_PROFILE:-default}}"
  command -v jira >/dev/null 2>&1 || return 1
  local me; me="$(_jira_me)" || return 1
  local keys
  keys="$(jira_in_flight "$profile" | jq -r '.key')" || return 1
  [[ -z "$keys" ]] && return 0
  local key out
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    # 2>/dev/null is intentional: a multi-key sweep over in-flight issues
    # routinely hits 404s when an issue was just transitioned/deleted; the
    # noise on stderr drowns real signals. `|| continue` swallows the row
    # quietly. Other integrations (gh, deploys) don't loop, so they don't
    # need this guard.
    out="$(jira issue comment list "$key" --plain --columns id,author,created,body 2>/dev/null)" || continue
    printf '%s\n' "$out" | awk -F'\t' -v me="$me" -v since="$since" -v key="$key" '
      NR > 1 && NF >= 4 && $2 == me && $3 >= since {
        body=""
        for (i=4; i<=NF; i++) body = body (i==4?"":" ") $i
        gsub(/\\/, "\\\\", body); gsub(/"/, "\\\"", body)
        printf "{\"key\":\"%s\",\"ts\":\"%s\",\"body\":\"%s\"}\n", key, $3, body
      }'
  done <<< "$keys"
}
