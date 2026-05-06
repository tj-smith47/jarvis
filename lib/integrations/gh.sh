#!/usr/bin/env bash
# GitHub PR integration. Shells to `gh pr list --search ... --json ...` and
# maps the JSON array into NDJSON {number,title,url,repo} rows.
#
# Failure modes:
#   - gh not on PATH         -> exit 1, no stderr (silent: covered by doctor)
#   - gh nonzero exit        -> exit 1; gh's own stderr is allowed to bubble
#                               (e.g. "auth required") — the dispatcher
#                               silences for hot paths; doctor invokes
#                               directly to surface the diagnostic.
#   - empty array            -> exit 0, no stdout

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_INTEGRATIONS_GH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_INTEGRATIONS_GH_LOADED=1

_gh_run() {
  local search="$1"
  local _profile="${2:-}"  # accepted by registry contract; unused (gh reads ~/.config/gh)
  if ! command -v gh >/dev/null 2>&1; then
    return 1
  fi
  local out
  # Don't suppress gh's stderr — its diagnostic ("auth required", "API rate
  # limit", …) is what `jarvis doctor` and direct invocation surface.
  if ! out="$(gh pr list --search "$search" --json number,title,url,headRepository)"; then
    return 1
  fi
  # `gh` already emits a JSON array; jq does the projection. Empty array
  # produces no output (jq's `.[]` is a no-op on []).
  printf '%s' "$out" | jq -c '.[] | {number, title, url, repo: (.headRepository.owner.login + "/" + .headRepository.name)}'
}

gh_prs_review_requested() {
  _gh_run 'is:open is:pr review-requested:@me' "${1:-}"
}

gh_prs_authored() {
  _gh_run 'is:open is:pr author:@me' "${1:-}"
}
