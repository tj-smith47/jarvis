#!/usr/bin/env bats
# lib/integrations/git.sh — git log → NDJSON commit feed.
#
# Each test stands up a fresh repo under $TEST_DIR, seeds commits with
# pinned author dates so the window filter is deterministic, then asserts
# the emitted NDJSON shape. JARVIS_FAKE_NOW is intentionally NOT used —
# the lib takes since/until as explicit ISO args, the caller is what
# resolves "now".

bats_require_minimum_version 1.5.0

load 'helper'

setup() {
  jarvis_common_setup
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/integrations/git.sh"
  REPO="$TEST_DIR/repo"
  mkdir -p "$REPO"
  ( cd "$REPO" \
    && git init -q --initial-branch=main \
    && git config user.email alice@example.com \
    && git config user.name  alice \
    && git remote add origin https://github.com/acme/widgets.git \
    && git commit --allow-empty -m "wip: yesterday's work"              --date="2026-04-30T10:00:00Z" \
    && git commit --allow-empty -m "feat: add fancy thing (#42)"        --date="2026-04-30T13:00:00Z" \
    && git commit --allow-empty -m "feat: ship today"                   --date="2026-05-01T09:00:00Z" \
    && git commit --allow-empty -m "chore: long ago"                    --date="2026-01-01T10:00:00Z" )
}

teardown() { jarvis_common_teardown; }

@test "git_repo_slug resolves owner/name from origin URL" {
  [ "$(git_repo_slug "$REPO")" = "acme/widgets" ]
}

@test "git_repo_slug falls back to basename without origin" {
  noremote="$TEST_DIR/no-remote-repo"
  mkdir -p "$noremote"
  ( cd "$noremote" && git init -q --initial-branch=main )
  [ "$(git_repo_slug "$noremote")" = "no-remote-repo" ]
}

@test "git_repo_slug normalizes git@host:owner/name.git form" {
  ssh_repo="$TEST_DIR/ssh-repo"
  mkdir -p "$ssh_repo"
  ( cd "$ssh_repo" \
    && git init -q --initial-branch=main \
    && git remote add origin git@github.com:acme/foo.git )
  [ "$(git_repo_slug "$ssh_repo")" = "acme/foo" ]
}

@test "git_commits_since emits NDJSON per commit in [since,until]" {
  run git_commits_since "$REPO" "2026-04-30T00:00:00Z" "2026-05-01T00:00:00Z"
  [ "$status" -eq 0 ]
  # Two commits fall in the window: wip + feat (#42); the 2026-05-01 and
  # the 2026-01-01 commits sit outside it.
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 2 ]
  # Each row is parseable JSON with required keys.
  printf '%s\n' "$output" | while IFS= read -r row; do
    echo "$row" | jq -e 'has("repo") and has("sha") and has("ts") and has("subject") and has("pr") and has("author")' > /dev/null
  done
}

@test "git_commits_since extracts trailing (#NNN) as pr field" {
  run git_commits_since "$REPO" "2026-04-30T00:00:00Z" "2026-05-01T00:00:00Z"
  [ "$status" -eq 0 ]
  # The (#42) row carries pr=42 and a subject without the trailing ref.
  pr_row="$(printf '%s\n' "$output" | jq -c 'select(.pr == 42)')"
  [ -n "$pr_row" ]
  [ "$(jq -r '.subject' <<< "$pr_row")" = "feat: add fancy thing" ]
}

@test "git_commits_since flags commits without PR ref as pr=null" {
  run git_commits_since "$REPO" "2026-04-30T00:00:00Z" "2026-05-01T00:00:00Z"
  [ "$status" -eq 0 ]
  no_pr_row="$(printf '%s\n' "$output" | jq -c 'select(.subject == "wip: yesterday'\''s work")')"
  [ -n "$no_pr_row" ]
  [ "$(jq -r '.pr' <<< "$no_pr_row")" = "null" ]
}

@test "git_commits_since author defaults to repo user.email" {
  # Add a commit by a different author within the same window; default
  # filter should not include it.
  ( cd "$REPO" \
    && git -c user.email="bob@example.com" -c user.name="bob" \
       commit --allow-empty -m "feat: bob's commit" --date="2026-04-30T14:00:00Z" )
  run git_commits_since "$REPO" "2026-04-30T00:00:00Z" "2026-05-01T00:00:00Z"
  [ "$status" -eq 0 ]
  [[ "$output" != *"bob's commit"* ]]
  [[ "$output" == *"wip: yesterday"* ]]
}

@test "git_commits_since --author override scopes to a different email" {
  ( cd "$REPO" \
    && git -c user.email="bob@example.com" -c user.name="bob" \
       commit --allow-empty -m "feat: bob's commit" --date="2026-04-30T14:00:00Z" )
  run git_commits_since "$REPO" "2026-04-30T00:00:00Z" "2026-05-01T00:00:00Z" "bob@example.com"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]
  [[ "$output" == *"bob's commit"* ]]
}

@test "git_commits_since exits 1 when repo dir is missing" {
  run git_commits_since "$TEST_DIR/nope" "2026-04-30T00:00:00Z" "2026-05-01T00:00:00Z"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "git_commits_since exits 1 when user.email is unset" {
  bare="$TEST_DIR/bare-repo"
  mkdir -p "$bare"
  ( cd "$bare" && git init -q --initial-branch=main )
  # No user.email configured locally — relies on absence; lib reads only
  # the repo-local config, so a global default doesn't help.
  run git_commits_since "$bare" "2026-04-30T00:00:00Z" "2026-05-01T00:00:00Z"
  [ "$status" -eq 1 ]
}

@test "git_commits_since returns empty stdout for a window with no matching commits" {
  run git_commits_since "$REPO" "2025-01-01T00:00:00Z" "2025-01-02T00:00:00Z"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "git_commits_since escapes JSON in commit subjects" {
  ( cd "$REPO" \
    && git commit --allow-empty \
         -m 'fix: handle "quoted" path with \backslash' \
         --date="2026-04-30T15:00:00Z" )
  run git_commits_since "$REPO" "2026-04-30T00:00:00Z" "2026-05-01T00:00:00Z"
  [ "$status" -eq 0 ]
  # Every row must remain parseable JSON despite the quotes / backslash.
  printf '%s\n' "$output" | while IFS= read -r row; do
    echo "$row" | jq -e '.' > /dev/null
  done
}
