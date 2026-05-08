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

@test "yesterday surfaces gh-merged PRs (squash/rebase merges absent from local git log)" {
  # Override the existing gh shim so it answers `gh pr list --search ...
  # is:merged author:@me ...` with a JSON array.
  # gh pr list --search "<query>" --json ...   →   $1=pr $2=list $3=--search $4=<query>
  shim_install gh '
if [[ "$1 $2" == "pr list" ]]; then
  query=""
  shift 2
  while (( $# > 0 )); do
    case "$1" in
      --search) query="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [[ "$query" == *"is:merged"* ]]; then
    cat <<EOF2
[
  {"number":42,"title":"feat: ship audit doc","url":"https://github.com/acme/widgets/pull/42",
   "headRepository":{"name":"widgets","owner":{"login":"acme"}},
   "mergedAt":"2026-04-30T18:00:00Z","additions":120,"deletions":3}
]
EOF2
  else
    printf "[]\n"
  fi
  exit 0
fi'
  run bash "${JARVIS_DIR}/cmds/standup/standup.sh" --since 1d --repo "$REPO" --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"🚀 acme/widgets#42"*"feat: ship audit doc"* ]]
}

@test "yesterday surfaces tasks closed in the standup window" {
  # Drop a done-yesterday task into the fixture profile. Schema field is
  # `desc` (the task store's canonical field) — pre-fix this seed used
  # `title`, which task-store writers don't emit, so renders silently fell
  # through to slug.
  jq -nc \
    '{slug:"shipped",desc:"shipped audit doc",status:"done",
      done_at:"2026-04-30T17:00:00Z",created_at:"2026-04-29T10:00:00Z"}' \
    > "$JARVIS_HOME/test/tasks/shipped.json"
  # And a task closed long before the window — must NOT appear.
  jq -nc \
    '{slug:"old",desc:"old work",status:"done",
      done_at:"2026-04-01T10:00:00Z",created_at:"2026-03-01T10:00:00Z"}' \
    > "$JARVIS_HOME/test/tasks/old.json"
  run bash "${JARVIS_DIR}/cmds/standup/standup.sh" --since 1d --repo "$REPO" --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓"*"shipped audit doc"* ]]
  [[ "$output" != *"old work"* ]]
}

@test "yesterday surfaces focus minutes and top topics from focus.log" {
  # Two end-rows on yesterday (relative to JARVIS_FAKE_NOW=2026-05-01T15:00:00Z),
  # both with topic "jarvis-audit", totaling 90 minutes.
  cat > "$JARVIS_HOME/test/focus.log" <<EOF
{"ts":"2026-04-30T09:00:00Z","event":"start","topic":"jarvis-audit"}
{"ts":"2026-04-30T10:00:00Z","event":"end","topic":"jarvis-audit","elapsed_seconds":3600}
{"ts":"2026-04-30T13:00:00Z","event":"start","topic":"jarvis-audit"}
{"ts":"2026-04-30T13:30:00Z","event":"end","topic":"jarvis-audit","elapsed_seconds":1800}
EOF
  run bash "${JARVIS_DIR}/cmds/standup/standup.sh" --since 1d --repo "$REPO" --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"focus: 1h 30m"*"jarvis-audit"* ]]
}

@test "yesterday surfaces fired reminders as a list (not bare count)" {
  # Two delivered, one failed (filtered), one outside the window (filtered).
  # Pre-fix the renderer collapsed these to "$N reminders fired" — the
  # detail (when, what, on which channels) was buried in notify.log even
  # though the standup audience usually wants exactly that.
  cat > "$JARVIS_HOME/test/notify.log" <<EOF
{"ts":"2026-04-30T10:00:00Z","channel":"local","ok":true,"message":"deploy notice"}
{"ts":"2026-04-30T15:00:00Z","channel":"local","ok":true,"message":"standup soon"}
{"ts":"2026-04-30T16:00:00Z","channel":"local","ok":false,"message":"oops","error":"fail"}
{"ts":"2026-04-01T10:00:00Z","channel":"local","ok":true,"message":"old"}
EOF
  run bash "${JARVIS_DIR}/cmds/standup/standup.sh" --since 1d --repo "$REPO" --profile test
  [ "$status" -eq 0 ]
  # Each delivered message renders as its own row with channel(s).
  [[ "$output" == *"deploy notice"*"[local]"* ]]
  [[ "$output" == *"standup soon"*"[local]"* ]]
  # Out-of-window + failed rows are filtered.
  [[ "$output" != *"oops"* ]]
  [[ "$output" != *"old"* ]]
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

@test "blockers: open task tagged 'blocker' surfaces in standup" {
  # Task-side blockers were silently dropped before the tags-schema land —
  # standup only scanned notes. Now an open task with tag=blocker shows
  # alongside note blockers under the same Blockers section.
  jq -nc '{slug:"freeze-investigate", desc:"investigate cluster freeze",
           status:"open", priority:"high", due:null, project:"inbox",
           created_at:"2026-04-29T10:00:00Z",
           updated_at:"2026-04-30T15:00:00Z",
           done_at:null, seq:1, jira_key:null,
           tags:["blocker"]}' \
    > "$JARVIS_HOME/test/tasks/freeze-investigate.json"
  run bash "${JARVIS_DIR}/cmds/standup/standup.sh" --since 1d --repo "$REPO" --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"Blockers"* ]]
  [[ "$output" == *"investigate cluster freeze"* ]]
}

@test "blockers: open task without 'blocker' tag is NOT surfaced" {
  jq -nc '{slug:"unrelated", desc:"unrelated work", status:"open",
           priority:"med", due:null, project:"inbox",
           created_at:"2026-04-29T10:00:00Z", updated_at:"2026-04-30T15:00:00Z",
           done_at:null, seq:1, jira_key:null, tags:["release"]}' \
    > "$JARVIS_HOME/test/tasks/unrelated.json"
  run bash "${JARVIS_DIR}/cmds/standup/standup.sh" --since 1d --repo "$REPO" --profile test
  [ "$status" -eq 0 ]
  [[ "$output" != *"unrelated work"*"Blockers"* ]] || true  # never under Blockers
}

@test "blockers: done task tagged 'blocker' is NOT surfaced under Blockers" {
  # A closed-yesterday blocker correctly DOES appear under yesterday's
  # tasks-shipped section ("✓ resolved blocker") — this test only asserts
  # it's not surfaced under the active Blockers heading.
  jq -nc '{slug:"resolved", desc:"resolved blocker", status:"done",
           priority:"high", due:null, project:"inbox",
           created_at:"2026-04-29T10:00:00Z", updated_at:"2026-04-30T15:00:00Z",
           done_at:"2026-04-30T16:00:00Z", seq:1, jira_key:null,
           tags:["blocker"]}' \
    > "$JARVIS_HOME/test/tasks/resolved.json"
  # Strip notes-side blockers from the fixture so the Blockers section
  # is gated only by tasks; otherwise a note-blocker would mask the assertion.
  echo '{"version":1,"notes":[]}' > "$JARVIS_HOME/test/notes/index.json"
  run bash "${JARVIS_DIR}/cmds/standup/standup.sh" --since 1d --repo "$REPO" --profile test
  [ "$status" -eq 0 ]
  # Walk just the Blockers section (heading → blank line). With notes
  # cleared and the closed task filtered, that section reads "(none)".
  blockers_section="$(printf '%s\n' "$output" | awk '/Blockers/,/^$/')"
  [[ "$blockers_section" == *"(none)"* ]]
  [[ "$blockers_section" != *"resolved blocker"* ]]
}

@test "today: open tasks render priority + due + jira_key suffixes" {
  # Pre-fix the renderer reached for `.title` (doesn't exist) and dropped
  # priority / due / jira_key even though every record carries them.
  jq -nc '{slug:"ship-it", desc:"ship the migration", status:"open",
           priority:"high", due:"2026-05-09", project:"release",
           created_at:"2026-04-30T10:00:00Z", updated_at:"2026-04-30T10:00:00Z",
           done_at:null, seq:1, jira_key:"PLAT-456", tags:[]}' \
    > "$JARVIS_HOME/test/tasks/ship-it.json"
  run bash "${JARVIS_DIR}/cmds/standup/standup.sh" --since 1d --repo "$REPO" --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"ship the migration"* ]]
  [[ "$output" == *"[high]"* ]]
  [[ "$output" == *"due 2026-05-09"* ]]
  [[ "$output" == *"PLAT-456"* ]]
}

@test "yesterday: closed task carries jira_key suffix" {
  jq -nc '{slug:"shipped-jira", desc:"ship migration", status:"done",
           priority:"med", due:null, project:"release",
           created_at:"2026-04-29T10:00:00Z", updated_at:"2026-04-30T16:00:00Z",
           done_at:"2026-04-30T17:00:00Z", seq:1, jira_key:"PLAT-789", tags:[]}' \
    > "$JARVIS_HOME/test/tasks/shipped-jira.json"
  run bash "${JARVIS_DIR}/cmds/standup/standup.sh" --since 1d --repo "$REPO" --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓"*"ship migration"* ]]
  [[ "$output" == *"PLAT-789"* ]]
}

@test "yesterday: created-but-unmerged PRs render with 📝 prefix" {
  # gh shim: created PR 99, draft.
  shim_install gh '
case "$1 $2" in
  "auth status") exit 0 ;;
  "pr list")
    case "$*" in
      *"is:merged"*) printf "[]\n" ;;
      *"is:open"*"created"*)
        cat <<JSON
[{"number":99,"title":"feat: draft handoff","url":"https://github.com/acme/widgets/pull/99","headRepository":{"name":"widgets","owner":{"login":"acme"}},"createdAt":"2026-04-30T11:00:00Z","isDraft":true}]
JSON
        ;;
      *) printf "[]\n" ;;
    esac ;;
esac'
  run bash "${JARVIS_DIR}/cmds/standup/standup.sh" --since 1d --repo "$REPO" --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"📝"* ]]
  [[ "$output" == *"[DRAFT]"* ]]
  [[ "$output" == *"acme/widgets#99"* ]]
  [[ "$output" == *"feat: draft handoff"* ]]
}

@test "standup --all-repos warns when [standup] repos config absent" {
  # Pre-fix --all-repos silently no-op'd to cwd when repos= was unset; user
  # got the wrong scan and never knew the flag wasn't honored. Now the
  # silence is visible: stderr explains the fallback so the user can fix
  # the config (or stop passing --all-repos).
  run --separate-stderr bash "${JARVIS_DIR}/cmds/standup/standup.sh" \
    --all-repos --since 1d --profile test
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"--all-repos"* ]]
  [[ "$stderr" == *"[standup] repos not set"* ]] || [[ "$stderr" == *"falling back to cwd"* ]]
}
