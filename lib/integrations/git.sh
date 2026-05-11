#!/usr/bin/env bash
# Local git-log integration. Emits NDJSON commit rows for a repo + time
# window, filtered by the repo's own `git config user.email` (overridable).
#
# Standup and `standup discover --activity` both consume this so the
# "what did I commit yesterday" surface is single-sourced. Compared to
# the gh integration: gh is the collaboration surface (PRs / reviews /
# issues — none of which are in git log), git is the on-disk ground truth
# (includes unpushed commits + direct-pushes-to-master that never became
# PRs). Standup cross-correlates the two streams to flag commits whose
# subject carries no `(#NNN)` PR ref → "this branch isn't a PR yet".
#
# Sourced library — no `set` calls (would leak into the caller's shell).
#
# Failure modes (return 1, silent stdout):
#   - git not on PATH
#   - dir doesn't exist or has no .git/
#   - no user.email configured (one-line stderr; doctor surfaces the fix)

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_INTEGRATIONS_GIT_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_INTEGRATIONS_GIT_LOADED=1

# git_repo_slug <repo-dir>
# Normalize origin URL to owner/name. Falls back to basename(repo-dir)
# when remote.origin.url is unset (uncloned scratch repos still render
# something useful). Handles:
#   https://github.com/owner/name(.git)?
#   git@github.com:owner/name(.git)?
#   ssh://git@github.com/owner/name
git_repo_slug() {
  local dir="$1" origin
  origin="$(cd "$dir" 2>/dev/null && git config remote.origin.url 2>/dev/null)" || origin=""
  if [[ -z "$origin" ]]; then
    (cd "$dir" 2>/dev/null && basename "$(pwd)")
    return 0
  fi
  printf '%s' "$origin" | awk '{
    sub(/\.git$/, "")
    sub(/\/$/, "")
    gsub(/:/, "/")
    n = split($0, a, "/")
    if (n >= 2) print a[n-1] "/" a[n]
    else        print a[n]
  }'
}

# git_commits_since <repo-dir> <since-iso> <until-iso> [<author-email>]
# Emit NDJSON one row per commit authored by <author-email> in the half-
# open window [since-iso, until-iso]. Empty <author-email> → use the
# repo's local user.email.
#
# Row schema:
#   {"repo":<slug>, "sha":<short>, "ts":<author-iso>,
#    "subject":<text>, "pr":<number-or-null>, "author":<email>}
#
# pr extraction: trailing ` (#NNN)` in the subject (GitHub squash-merge
# convention). pr == null is the "no PR" signal the standup renderer
# uses to flag direct-push / unmerged-branch commits.
#
# Window filter runs in awk against the *author* date (%aI), not commit
# date. `git log --since` filters commit date, which means rebased /
# replayed commits with old author-date but new commit-date would falsely
# include themselves; the awk pass keeps the contract honest.
git_commits_since() {
  local dir="$1" since="$2" until_="$3" author="${4:-}"

  if ! command -v git >/dev/null 2>&1; then
    return 1
  fi
  if [[ -z "$dir" || ! -d "$dir/.git" ]]; then
    return 1
  fi

  if [[ -z "$author" ]]; then
    author="$(cd "$dir" 2>/dev/null && git config user.email 2>/dev/null)" || author=""
  fi
  if [[ -z "$author" ]]; then
    printf 'git_commits_since: %s: no user.email configured\n' "$dir" >&2
    return 1
  fi

  local slug
  slug="$(git_repo_slug "$dir")"

  (cd "$dir" 2>/dev/null && \
     git log --author="$author" --pretty=format:'%aI|%h|%s' 2>/dev/null) \
    | awk -F'|' -v s="$since" -v u="$until_" -v repo="$slug" -v author="$author" '
        function jesc(t) { gsub(/\\/, "\\\\", t); gsub(/"/, "\\\"", t); return t }
        NF >= 3 && $1 >= s && $1 <= u {
          ts = $1
          sha = $2
          subj = $3
          for (i = 4; i <= NF; i++) subj = subj "|" $i
          pr = ""
          if (match(subj, / \(#[0-9]+\)$/)) {
            pr = substr(subj, RSTART + 3, RLENGTH - 4)
            subj = substr(subj, 1, RSTART - 1)
          }
          pr_json = (pr == "" ? "null" : pr)
          printf "{\"repo\":\"%s\",\"sha\":\"%s\",\"ts\":\"%s\",\"subject\":\"%s\",\"pr\":%s,\"author\":\"%s\"}\n",
                 jesc(repo), jesc(sha), jesc(ts), jesc(subj), pr_json, jesc(author)
        }'
}
