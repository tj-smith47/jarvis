#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

load helper

setup() {
  jarvis_common_setup
  mkdir -p "$JARVIS_HOME/test/tasks"
  printf '1\n' > "$JARVIS_HOME/test/state.version"
}
teardown() { jarvis_common_teardown; }

seed() {
  # usage: seed <slug>
  local slug="$1"
  jq -n --arg slug "$slug" '
    {slug:$slug, desc:$slug, status:"open", priority:"med", due:null,
     project:"inbox", created_at:"2026-04-20T00:00:00Z",
     updated_at:"2026-04-20T00:00:00Z", done_at:null, seq:1, jira_key:null}
  ' > "$JARVIS_HOME/test/tasks/$slug.json"
}

run_done() {
  FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR" \
  CLI_DIR="$JARVIS_DIR" \
  PATH="${FAKE_BIN:-$PATH}" \
  bash -c '
    set -euo pipefail
    declare -A CLIFT_FLAGS=()
    export CLIFT_POS_1="'"$1"'"
    source "$1"
  ' _ "$JARVIS_DIR/cmds/task/task.done.sh"
}

@test "done on existing slug sets status=done and done_at" {
  seed fix-k3s
  run run_done fix-k3s
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' "$JARVIS_HOME/test/tasks/fix-k3s.json")" = "done" ]
  [ "$(jq -r '.done_at' "$JARVIS_HOME/test/tasks/fix-k3s.json")" != "null" ]
}

@test "done resolves unique prefix" {
  seed fix-k3s-etcd
  run run_done fix-k
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' "$JARVIS_HOME/test/tasks/fix-k3s-etcd.json")" = "done" ]
}

@test "done on unknown slug exits 1" {
  run run_done nope
  [ "$status" -eq 1 ]
}

@test "done on ambiguous prefix exits 1 and lists candidates" {
  seed fix-a
  seed fix-b
  run run_done fix
  [ "$status" -eq 1 ]
  [[ "$output" == *"fix-a"* ]] || [[ "$stderr" == *"fix-a"* ]]
  [[ "$output" == *"fix-b"* ]] || [[ "$stderr" == *"fix-b"* ]]
}

@test "done without positional exits 2" {
  run run_done ""
  [ "$status" -eq 2 ]
}

@test "done on Jira key with jira binary shells to jira issue move" {
  # Install fake jira that records its argv.
  FAKE_BIN="$TEST_DIR/fake-bin"
  mkdir -p "$FAKE_BIN"
  cat > "$FAKE_BIN/jira" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_JIRA_LOG"
EOF
  chmod +x "$FAKE_BIN/jira"
  FAKE_BIN="$FAKE_BIN:$PATH"
  export FAKE_JIRA_LOG="$TEST_DIR/jira.log"

  run run_done PLAT-123
  [ "$status" -eq 0 ]
  [ -f "$FAKE_JIRA_LOG" ]
  grep -q '^issue$' "$FAKE_JIRA_LOG"
  grep -q '^move$' "$FAKE_JIRA_LOG"
  grep -q '^PLAT-123$' "$FAKE_JIRA_LOG"
}

@test "done on Jira key without jira binary exits 4" {
  FAKE_BIN="$TEST_DIR/empty-bin"
  mkdir -p "$FAKE_BIN"   # no jira here; PATH reduced
  FAKE_BIN="$FAKE_BIN:/usr/bin:/bin"
  run run_done PLAT-123
  [ "$status" -eq 4 ]
}
