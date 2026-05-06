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
