#!/usr/bin/env bats
# standup: Yesterday/Today/Blockers from real data.
# T12 — git log + jira comments + open tasks + blocker notes.
# --join / --meeting accepted as no-ops; wired in T13.

bats_require_minimum_version 1.5.0

load 'helper'
load 'shim_helper'

setup() {
  jarvis_common_setup
  shim_setup
  cp -R "${BATS_TEST_DIRNAME}/fixtures/status-profile" "$JARVIS_HOME/test"
  REPO="$TEST_DIR/repo"
  mkdir -p "$REPO"
  ( cd "$REPO" && git init -q --initial-branch=main \
    && git config user.email alice@example.com \
    && git config user.name alice \
    && git commit --allow-empty -m "wip: yesterday's work" --date="2026-04-30T10:00:00Z" \
    && git commit --allow-empty -m "feat: ship today" --date="2026-05-01T09:00:00Z" )
  mkdir -p "$JARVIS_HOME/test/notes/inbox"
  cat > "$JARVIS_HOME/test/notes/index.json" <<EOF
{"version":1,"notes":[
  {"path":"notes/inbox/auth-broken.md","kind":"inbox","title":"auth broken","tags":["blocker"],"updated_at":"2026-04-30T15:00:00Z","archived":false},
  {"path":"notes/inbox/random.md","kind":"inbox","title":"random","tags":["idea"],"updated_at":"2026-04-30T16:00:00Z","archived":false}
]}
EOF
  shim_install jira '
case "$1 $2" in
  "me ") echo "alice" ; exit 0 ;;
  "issue list")
    cat <<EOF
KEY	SUMMARY	STATUS
PLAT-123	Migrate auth	In Progress
EOF
    exit 0 ;;
  "issue comment")
    cat <<EOF
ID	AUTHOR	CREATED	BODY
1	alice	2026-04-30T15:22:11Z	pushed PR up
EOF
    exit 0 ;;
esac'
  export JARVIS_FAKE_NOW="2026-05-01T15:00:00Z"
}

teardown() { jarvis_common_teardown; }

@test "standup --since 1d --repo <repo> shows yesterday + today + blockers" {
  run bash "${JARVIS_DIR}/cmds/standup/standup.sh" \
    --since 1d --repo "$REPO" --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"Yesterday"* ]]
  [[ "$output" == *"wip: yesterday's work"* ]]
  [[ "$output" == *"pushed PR up"* ]]
  [[ "$output" == *"Today"* ]]
  [[ "$output" == *"buy milk"* ]]
  [[ "$output" == *"PLAT-123"* ]]
  [[ "$output" == *"Blockers"* ]]
  [[ "$output" == *"auth broken"* ]]
}

@test "standup with no blockers shows 'none'" {
  echo '{"version":1,"notes":[]}' > "$JARVIS_HOME/test/notes/index.json"
  run bash "${JARVIS_DIR}/cmds/standup/standup.sh" \
    --since 1d --repo "$REPO" --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"Blockers"* ]]
  [[ "$output" == *"none"* ]]
}

@test "standup --all-repos iterates [standup] repos" {
  REPO2="$TEST_DIR/repo2"
  mkdir -p "$REPO2"
  ( cd "$REPO2" && git init -q --initial-branch=main \
    && git config user.email alice@example.com \
    && git config user.name alice \
    && git commit --allow-empty -m "fix: another repo" --date="2026-04-30T11:00:00Z" )
  cat >> "$JARVIS_HOME/test/config.toml" <<EOF

[standup]
repos = ["$REPO", "$REPO2"]
EOF
  run bash "${JARVIS_DIR}/cmds/standup/standup.sh" \
    --since 1d --all-repos --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"wip: yesterday's work"* ]]
  [[ "$output" == *"fix: another repo"* ]]
}

@test "standup accepts --join and --meeting as no-ops in T12" {
  run bash "${JARVIS_DIR}/cmds/standup/standup.sh" \
    --since 1d --repo "$REPO" --profile test --join --meeting "https://zoom.us/j/123"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Yesterday"* ]]
}

@test "yesterday-git rows are prefixed with repo slug and PR ref or short hash" {
  # Add a commit with a (#NNN) PR-merge-style suffix so the PR-ref extraction
  # path is exercised. Existing fixture commits have no (#NNN), so they fall
  # through to the @<short-hash> path — both are asserted.
  ( cd "$REPO" \
    && git remote add origin https://github.com/acme/widgets.git \
    && git commit --allow-empty -m "feat: add fancy thing (#42)" \
                  --date="2026-04-30T13:00:00Z" )
  run bash "${JARVIS_DIR}/cmds/standup/standup.sh" \
    --since 1d --repo "$REPO" --profile test
  [ "$status" -eq 0 ]
  # PR-ref form on the (#42) commit
  [[ "$output" == *"acme/widgets#42"*"feat: add fancy thing"* ]]
  # Hash form on a commit without (#NNN) — slug + @ + 7-char short hash
  [[ "$output" =~ acme/widgets@[0-9a-f]{7}[[:space:]]+wip:\ yesterday\'s\ work ]]
}

@test "yesterday-git falls back to repo basename when no remote is configured" {
  REPO_NOREMOTE="$TEST_DIR/no-remote-repo"
  mkdir -p "$REPO_NOREMOTE"
  ( cd "$REPO_NOREMOTE" && git init -q --initial-branch=main \
    && git config user.email alice@example.com \
    && git config user.name alice \
    && git commit --allow-empty -m "fix: noremote work" --date="2026-04-30T11:00:00Z" )
  run bash "${JARVIS_DIR}/cmds/standup/standup.sh" \
    --since 1d --repo "$REPO_NOREMOTE" --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-remote-repo@"* ]]
  [[ "$output" == *"fix: noremote work"* ]]
}

@test "blockers: long-standing note (older than --since) is still surfaced" {
  # Pre-fix the section silently filtered out blockers that hadn't been
  # touched in the standup window — exactly the ones most likely to need
  # attention. Stale-but-unresolved blockers must show.
  cat > "$JARVIS_HOME/test/notes/index.json" <<EOF
{"version":1,"notes":[
  {"path":"notes/inbox/old-blocker.md","kind":"inbox","title":"old blocker — 30 days stale","tags":["blocker"],
   "updated_at":"2026-04-01T10:00:00Z","archived":false}
]}
EOF
  mkdir -p "$JARVIS_HOME/test/notes/inbox"
  printf 'still real after 30 days. waiting on infra team.\n' \
    > "$JARVIS_HOME/test/notes/inbox/old-blocker.md"
  run bash "${JARVIS_DIR}/cmds/standup/standup.sh" --since 1d --repo "$REPO" --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"old blocker — 30 days stale"* ]]
}

@test "blockers: archived notes are still excluded" {
  cat > "$JARVIS_HOME/test/notes/index.json" <<EOF
{"version":1,"notes":[
  {"path":"notes/inbox/done.md","kind":"inbox","title":"resolved blocker","tags":["blocker"],
   "updated_at":"2026-04-30T10:00:00Z","archived":true}
]}
EOF
  run bash "${JARVIS_DIR}/cmds/standup/standup.sh" --since 1d --repo "$REPO" --profile test
  [ "$status" -eq 0 ]
  [[ "$output" != *"resolved blocker"* ]]
}

@test "today's meetings render as their own section after Today" {
  # Pre-fix, standup never showed today's calendar — a standup draft that
  # doesn't surface "I have a 1:1 at 14:00" is missing half the picture.
  cat > "$JARVIS_HOME/test/cal.ics" <<'ICS'
BEGIN:VCALENDAR
BEGIN:VEVENT
DTSTART:20260501T160000Z
DTEND:20260501T163000Z
SUMMARY:1:1 with manager
URL:https://meet.google.com/team-sync
END:VEVENT
BEGIN:VEVENT
DTSTART:20260501T180000Z
DTEND:20260501T190000Z
SUMMARY:platform sync
URL:https://zoom.us/j/55555
END:VEVENT
END:VCALENDAR
ICS
  cat >> "$JARVIS_HOME/test/config.toml" <<EOF

[calendar]
provider = "ics"

[calendar.ics]
source = "$JARVIS_HOME/test/cal.ics"
EOF
  run bash "${JARVIS_DIR}/cmds/standup/standup.sh" --since 1d --repo "$REPO" --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"Meetings"* ]]
  [[ "$output" == *"16:00"*"1:1 with manager"*"https://meet.google.com/team-sync"* ]]
  [[ "$output" == *"18:00"*"platform sync"* ]]
}

@test "today's reminders render as their own section after Meetings" {
  mkdir -p "$JARVIS_HOME/test/reminders"
  jq -nc --arg ts "2026-05-01T17:00:00Z" \
    '{slug:"call-vendor",message:"call vendor",status:"pending",
      trigger_at:$ts, via:["local"], repeat:"", anchor_at:"", until:"",
      count_remaining:null, created_at:"2026-05-01T08:00:00Z",
      fire_count:0, last_fired_at:""}' \
    > "$JARVIS_HOME/test/reminders/call-vendor.json"
  run bash "${JARVIS_DIR}/cmds/standup/standup.sh" --since 1d --repo "$REPO" --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"Reminders"* ]]
  [[ "$output" == *"17:00"*"call vendor"* ]]
}

@test "blockers: row carries age suffix and body excerpt" {
  cat > "$JARVIS_HOME/test/notes/index.json" <<EOF
{"version":1,"notes":[
  {"path":"notes/inbox/auth-broken.md","kind":"inbox","title":"auth broken","tags":["blocker"],
   "updated_at":"2026-04-30T15:00:00Z","archived":false}
]}
EOF
  mkdir -p "$JARVIS_HOME/test/notes/inbox"
  cat > "$JARVIS_HOME/test/notes/inbox/auth-broken.md" <<EOF
---
title: auth broken
---

# auth broken

can't push to staging — 401 from the gateway since this morning's deploy
EOF
  run bash "${JARVIS_DIR}/cmds/standup/standup.sh" --since 1d --repo "$REPO" --profile test
  [ "$status" -eq 0 ]
  # Title row carries age suffix; 24h boundary rolls to 1d.
  [[ "$output" == *"auth broken (1d)"* ]]
  # Excerpt skips frontmatter + headings, picks the first prose line
  [[ "$output" == *"can't push to staging"* ]]
}
