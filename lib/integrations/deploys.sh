#!/usr/bin/env bash
# Deploy log tail. Reads <profile>/deploys.log (TSV: ts service version status).

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_INTEGRATIONS_DEPLOYS_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_INTEGRATIONS_DEPLOYS_LOADED=1

deploys_recent() {
  local since="$1" profile="${2:-${JARVIS_PROFILE:-default}}"
  local home="${JARVIS_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/jarvis}"
  local f="$home/$profile/deploys.log"
  [[ -f "$f" ]] || return 1
  awk -F'\t' -v since="$since" '
    /^[[:space:]]*$/ { next }
    /^#/ { next }
    NF >= 4 && $1 >= since {
      ts=$1; svc=$2; ver=$3; st=$4
      gsub(/\\/, "\\\\", ts);  gsub(/"/, "\\\"", ts)
      gsub(/\\/, "\\\\", svc); gsub(/"/, "\\\"", svc)
      gsub(/\\/, "\\\\", ver); gsub(/"/, "\\\"", ver)
      gsub(/\\/, "\\\\", st);  gsub(/"/, "\\\"", st)
      printf "{\"ts\":\"%s\",\"service\":\"%s\",\"version\":\"%s\",\"status\":\"%s\"}\n", ts, svc, ver, st
    }
  ' "$f"
}
