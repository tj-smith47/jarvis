#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

load helper

setup() {
  jarvis_common_setup
  mkdir -p "$JARVIS_HOME/test/tasks"
  printf '1\n' > "$JARVIS_HOME/test/state.version"
}
teardown() { jarvis_common_teardown; }

# Helper: run task.add.sh with a fake CLIFT_FLAGS/CLIFT_POS_1 env.
# Values are passed via environment variables, not single-quote
# interpolation, so descriptions and flag values containing quotes,
# backticks, or other shell metacharacters land verbatim.
run_add() {
  local desc="$1"; shift
  local priority="${1:-med}"; shift || true
  local due="${1:-}"; shift || true
  local project="${1:-inbox}"; shift || true
  local urgency="${1:-}"; shift || true
  # Clear EDITOR / VISUAL so an empty CLIFT_POS_1 (test for "no desc")
  # doesn't fall through to the editor path that the new C1 wiring
  # introduces. Tests that want to exercise the editor path do so
  # explicitly via the dedicated test cases below.
  FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR" \
  CLI_DIR="$JARVIS_DIR" \
  CLIFT_RUN_DESC="$desc" \
  CLIFT_RUN_PRIORITY="$priority" \
  CLIFT_RUN_DUE="$due" \
  CLIFT_RUN_PROJECT="$project" \
  CLIFT_RUN_URGENCY="$urgency" \
  EDITOR="" VISUAL="" \
  bash -c '
    set -euo pipefail
    declare -A CLIFT_FLAGS=(
      [priority]="$CLIFT_RUN_PRIORITY"
      [due]="$CLIFT_RUN_DUE"
      [project]="$CLIFT_RUN_PROJECT"
      [urgency]="$CLIFT_RUN_URGENCY"
    )
    export CLIFT_POS_1="$CLIFT_RUN_DESC"
    source "$1"
  ' _ "$JARVIS_DIR/cmds/task/task.add.sh"
}

@test "task add creates tasks/<slug>.json and echoes slug" {
  run run_add "Fix k3s etcd"
  [ "$status" -eq 0 ]
  # Last stdout line is the slug (log_success goes to stderr via log.sh)
  local slug="${lines[-1]}"
  [ "$slug" = "fix-k3s-etcd" ]
  [ -f "$JARVIS_HOME/test/tasks/fix-k3s-etcd.json" ]
}

@test "task add persists all user-facing fields" {
  run run_add "Ship VHS demos" high today "release" ""
  [ "$status" -eq 0 ]
  local f="$JARVIS_HOME/test/tasks/ship-vhs-demos.json"
  [ "$(jq -r '.desc' "$f")" = "Ship VHS demos" ]
  [ "$(jq -r '.priority' "$f")" = "high" ]
  [ "$(jq -r '.due' "$f")" = "today" ]
  [ "$(jq -r '.project' "$f")" = "release" ]
  [ "$(jq -r '.status' "$f")" = "open" ]
  [ "$(jq -r '.seq' "$f")" = "1" ]
}

@test "task add without description exits 2" {
  run run_add ""
  [ "$status" -eq 2 ]
}

@test "task add rejects invalid --due with exit 2" {
  run run_add "foo" med "yesterdayish"
  [ "$status" -eq 2 ]
}

@test "task add accepts --due YYYY-MM-DD" {
  run run_add "foo" med "2026-05-01"
  [ "$status" -eq 0 ]
  local slug="${lines[-1]}"
  [ "$(jq -r '.due' "$JARVIS_HOME/test/tasks/$slug.json")" = "2026-05-01" ]
}

@test "task add collision appends -2 on second slug" {
  run_add "Fix k3s etcd" >/dev/null
  run run_add "Fix k3s etcd"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "fix-k3s-etcd-2" ]
  [ -f "$JARVIS_HOME/test/tasks/fix-k3s-etcd.json" ]
  [ -f "$JARVIS_HOME/test/tasks/fix-k3s-etcd-2.json" ]
}

@test "task add with --urgency (no --priority) uses urgency value" {
  run run_add "Rotate creds" med "" inbox high
  [ "$status" -eq 0 ]
  local slug="${lines[-1]}"
  [ "$(jq -r '.priority' "$JARVIS_HOME/test/tasks/$slug.json")" = "high" ]
}

@test "task add increments seq per invocation" {
  run_add "one" >/dev/null
  run_add "two" >/dev/null
  run_add "three" >/dev/null
  [ "$(jq -r '.seq' "$JARVIS_HOME/test/tasks/one.json")" = "1" ]
  [ "$(jq -r '.seq' "$JARVIS_HOME/test/tasks/two.json")" = "2" ]
  [ "$(jq -r '.seq' "$JARVIS_HOME/test/tasks/three.json")" = "3" ]
}

@test "task add with --priority explicit beats --urgency (priority high wins over urgency low)" {
  run run_add "Pick one" high "" inbox low
  [ "$status" -eq 0 ]
  local slug="${lines[-1]}"
  [ "$(jq -r '.priority' "$JARVIS_HOME/test/tasks/$slug.json")" = "high" ]
}

@test "task add with invalid --priority exits 2" {
  run run_add "foo" urgent
  [ "$status" -eq 2 ]
}

@test "task add with desc that normalizes to empty exits 2" {
  run run_add "---"
  [ "$status" -eq 2 ]
}

@test "task add persists full multi-line desc; slug is first-line-only" {
  run run_add $'Line one\nLine two detail'
  [ "$status" -eq 0 ]
  local slug="${lines[-1]}"
  [ "$slug" = "line-one" ]
  [ "$(jq -r '.desc' "$JARVIS_HOME/test/tasks/$slug.json")" = $'Line one\nLine two detail' ]
}

@test "task add tolerates shell metacharacters in desc (no quoting bugs)" {
  # Pins the run_add helper's env-var pass-through against a regression
  # to single-quote interpolation. Apostrophes, backticks, dollar-signs
  # and pipes must all land verbatim in the persisted record.
  local desc="bob's \`whoami\` task | \$(rm -rf /)"
  run run_add "$desc"
  [ "$status" -eq 0 ]
  local slug="${lines[-1]}"
  [ "$(jq -r '.desc' "$JARVIS_HOME/test/tasks/$slug.json")" = "$desc" ]
}

# Helper: task add via the standalone parser path so list-flag handling
# (--tag repeated) gets exercised. Bypasses the run_add CLIFT_FLAGS shim
# because that shim doesn't model list flags.
_task_add_argv() {
  FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR" CLI_DIR="$JARVIS_DIR" \
    bash "$JARVIS_DIR/cmds/task/task.add.sh" "$@"
}

@test "task add stores tags: [] by default" {
  run _task_add_argv "untagged work"
  [ "$status" -eq 0 ]
  local slug="${lines[-1]}"
  [ "$(jq -r '.tags | type' "$JARVIS_HOME/test/tasks/$slug.json")" = "array" ]
  [ "$(jq -r '.tags | length' "$JARVIS_HOME/test/tasks/$slug.json")" = "0" ]
}

@test "task add --tag stores single tag" {
  run _task_add_argv "investigate freeze" --tag blocker
  [ "$status" -eq 0 ]
  local slug="${lines[-1]}"
  [ "$(jq -r '.tags | join(",")' "$JARVIS_HOME/test/tasks/$slug.json")" = "blocker" ]
}

@test "task add --tag is repeatable and dedupes" {
  run _task_add_argv "ops work" --tag blocker --tag ops --tag blocker
  [ "$status" -eq 0 ]
  local slug="${lines[-1]}"
  # Sorted-join keeps the assertion order-independent (jq's `unique_by`
  # preserves first-seen order; we don't want the test pinned to that).
  [ "$(jq -r '.tags | sort | join(",")' "$JARVIS_HOME/test/tasks/$slug.json")" = "blocker,ops" ]
}

@test "task add --tag normalizes case (UPPERCASE → lowercase)" {
  run _task_add_argv "noisy" --tag BLOCKER --tag Ops
  [ "$status" -eq 0 ]
  local slug="${lines[-1]}"
  [ "$(jq -r '.tags | sort | join(",")' "$JARVIS_HOME/test/tasks/$slug.json")" = "blocker,ops" ]
}

@test "task add --tag rejects whitespace tags with exit 2" {
  # `bad tag` contains a space; would never match standup's index() lookup.
  run _task_add_argv "needs grep" --tag "bad tag"
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid --tag"* ]] || [[ "${stderr:-}" == *"invalid --tag"* ]]
}

@test "task add reads desc from stdin when no positional" {
  run bash -c '
    FRAMEWORK_DIR="$1" CLI_DIR="$2" \
    bash "$2/cmds/task/task.add.sh" <<<"piped from stdin"
  ' _ "$CLIFT_FRAMEWORK_DIR" "$JARVIS_DIR"
  [ "$status" -eq 0 ]
  local slug="${lines[-1]}"
  [ "$(jq -r '.desc' "$JARVIS_HOME/test/tasks/$slug.json")" = "piped from stdin" ]
}

@test "task add positional beats stdin (positional wins)" {
  run bash -c '
    FRAMEWORK_DIR="$1" CLI_DIR="$2" \
    bash "$2/cmds/task/task.add.sh" "explicit" <<<"piped"
  ' _ "$CLIFT_FRAMEWORK_DIR" "$JARVIS_DIR"
  [ "$status" -eq 0 ]
  local slug="${lines[-1]}"
  [ "$(jq -r '.desc' "$JARVIS_HOME/test/tasks/$slug.json")" = "explicit" ]
}

@test "task add opens \$EDITOR when no positional and stdin is a tty" {
  # Shim EDITOR to a script file (cleaner than inline `bash -c` quoting).
  # </dev/null in the bash invocation closes stdin so task.add.sh sees
  # stdin-not-a-pipe → the EDITOR path fires.
  cat > "$TEST_DIR/fake-editor.sh" <<'EDIT'
#!/usr/bin/env bash
printf 'from-editor task\n' > "$1"
EDIT
  chmod +x "$TEST_DIR/fake-editor.sh"
  run bash -c '
    FRAMEWORK_DIR="$1" CLI_DIR="$2" EDITOR="$3" VISUAL="" \
    bash "$2/cmds/task/task.add.sh" </dev/null
  ' _ "$CLIFT_FRAMEWORK_DIR" "$JARVIS_DIR" "$TEST_DIR/fake-editor.sh"
  [ "$status" -eq 0 ]
  local slug="${lines[-1]}"
  [ "$(jq -r '.desc' "$JARVIS_HOME/test/tasks/$slug.json")" = "from-editor task" ]
}

@test "task add: editor abandoned (empty buffer) → exit 2" {
  # Editor script truncates the file to empty, simulating "saved with
  # nothing typed" — task.add.sh treats that as a cancel.
  cat > "$TEST_DIR/empty-editor.sh" <<'EDIT'
#!/usr/bin/env bash
:> "$1"
EDIT
  chmod +x "$TEST_DIR/empty-editor.sh"
  run bash -c '
    FRAMEWORK_DIR="$1" CLI_DIR="$2" EDITOR="$3" VISUAL="" \
    bash "$2/cmds/task/task.add.sh" </dev/null
  ' _ "$CLIFT_FRAMEWORK_DIR" "$JARVIS_DIR" "$TEST_DIR/empty-editor.sh"
  [ "$status" -eq 2 ]
}

@test "task add: no positional, stdin closed, no EDITOR → exit 2 with usage" {
  run bash -c '
    FRAMEWORK_DIR="$1" CLI_DIR="$2" EDITOR="" VISUAL="" \
    bash "$2/cmds/task/task.add.sh" </dev/null
  ' _ "$CLIFT_FRAMEWORK_DIR" "$JARVIS_DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]] || [[ "$output" == *"task add"* ]]
}
