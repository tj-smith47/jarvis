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
  #
  # JSON projection includes signals that change how a reviewer reads the
  # row: isDraft (don't review-yet), CI rollup (red is unreviewable, pending
  # blocks merge), updatedAt (stale signal), reviewDecision (someone else
  # already approved / changes-requested). These are queryable in one round
  # trip; rendering is the consumer's call.
  if ! out="$(gh pr list --search "$search" \
                --json number,title,url,headRepository,isDraft,updatedAt,statusCheckRollup,reviewDecision)"; then
    return 1
  fi
  # CI rollup: gh's statusCheckRollup is an array of check objects, each
  # with a `conclusion` (completed) or `status` (in-flight) field. Roll up
  # to a single token here so consumers don't need to know the schema.
  printf '%s' "$out" | jq -c '.[] | {
    number, title, url,
    repo: (.headRepository.owner.login + "/" + .headRepository.name),
    isDraft,
    updatedAt,
    reviewDecision,
    ci: (
      (.statusCheckRollup // [])
      | if length == 0 then "none"
        elif all(.[]; (.conclusion // .status) == "SUCCESS") then "success"
        elif any(.[]; (.conclusion // .status)
                      | IN("FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"))
          then "failure"
        else "pending" end
    )
  }'
}

gh_prs_review_requested() {
  _gh_run 'is:open is:pr review-requested:@me' "${1:-}"
}

# Merged-by-me-since: PRs the current user authored that landed (state:merged)
# in [since, now]. Used by standup yesterday to surface code that shipped
# via "Squash and merge" / "Rebase and merge" — git log alone misses these
# because the local branch never gets a merge commit.
#   $1 — since (UTC ISO-8601)
#   $2 — profile (unused; honored for registry contract)
gh_prs_merged_since() {
  local since="$1" _profile="${2:-}"
  command -v gh >/dev/null 2>&1 || return 1
  # gh's `merged:>=<date>` accepts YYYY-MM-DD; trim the time portion.
  local since_date="${since%%T*}"
  local out
  if ! out="$(gh pr list \
                --search "is:pr is:merged author:@me merged:>=${since_date}" \
                --json number,title,url,headRepository,mergedAt,additions,deletions)"; then
    return 1
  fi
  # Normalize {repo, mergedAt}, strip rows older than the precise --since
  # (the `>=` filter on gh's date-only granularity could include too much).
  printf '%s' "$out" | jq -c --arg since "$since" '
    .[]
    | select((.mergedAt // "") >= $since)
    | {number, title, url,
       repo: (.headRepository.owner.login + "/" + .headRepository.name),
       mergedAt,
       additions, deletions}
  '
}
