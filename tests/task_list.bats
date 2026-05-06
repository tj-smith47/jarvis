#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

load helper
load shim_helper

setup() {
  jarvis_common_setup
  shim_setup
  mkdir -p "$JARVIS_HOME/test/tasks"
  printf '1\n' > "$JARVIS_HOME/test/state.version"
}
teardown() { jarvis_common_teardown; }

seed() {
  # usage: seed <slug> <desc> <priority> <status> <project> <due> <seq>
  local slug="$1" desc="$2" pri="$3" status="$4" proj="$5" due="$6" seq="$7"
  local due_json='null'
  [[ -n "$due" ]] && due_json="\"$due\""
  local done_at_json='null'
  [[ "$status" == "done" ]] && done_at_json='"2026-04-20T00:00:00Z"'
  jq -n \
    --arg slug "$slug" --arg desc "$desc" --arg pri "$pri" \
    --arg status "$status" --arg proj "$proj" --argjson due "$due_json" \
    --argjson seq "$seq" --argjson done_at "$done_at_json" '
    {
      slug: $slug, desc: $desc, status: $status, priority: $pri,
      due: $due, project: $proj,
      created_at: "2026-04-20T00:00:00Z", updated_at: "2026-04-20T00:00:00Z",
      done_at: $done_at, seq: $seq, jira_key: null
    }' > "$JARVIS_HOME/test/tasks/$slug.json"
}

run_list() {
  FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR" \
  CLI_DIR="$JARVIS_DIR" \
  NO_COLOR="${NO_COLOR:-}" \
  bash -c '
    set -euo pipefail
    declare -A CLIFT_FLAGS=(
      [all]="'"${1:-}"'"
      [priority]="'"${2:-}"'"
      [project]="'"${3:-}"'"
      [due]="'"${4:-}"'"
      [json]="'"${5:-}"'"
      [yaml]="'"${6:-}"'"
      [jira]=""
    )
    source "$1"
  ' _ "$JARVIS_DIR/cmds/task/task.list.sh"
}

@test "task list with no tasks prints 'no open tasks'" {
  run run_list
  [ "$status" -eq 0 ]
  [[ "$output" == *"no open tasks"* ]]
}

@test "task list shows open task rows" {
  seed fix-k3s "Fix k3s etcd" high open release today 1
  run run_list
  [ "$status" -eq 0 ]
  [[ "$output" == *"fix-k3s"* ]]
  [[ "$output" == *"Fix k3s etcd"* ]]
  [[ "$output" == *"today"* ]]
  [[ "$output" == *"release"* ]]
}

@test "task list hides done by default" {
  seed a "open one" med open inbox "" 1
  seed b "done one" med "done" inbox "" 2
  run run_list
  [[ "$output" == *"open one"* ]]
  [[ "$output" != *"done one"* ]]
}

@test "task list --all includes done" {
  seed a "open one" med open inbox "" 1
  seed b "done one" med "done" inbox "" 2
  run run_list true
  [[ "$output" == *"open one"* ]]
  [[ "$output" == *"done one"* ]]
}

@test "task list --priority high filters" {
  seed a "hi" high open inbox "" 1
  seed b "lo" low  open inbox "" 2
  run run_list "" high
  [[ "$output" == *"hi"* ]]
  [[ "$output" != *"lo"* ]]
}

@test "task list --project release filters" {
  seed a "rel" med open release "" 1
  seed b "inb" med open inbox "" 2
  run run_list "" "" release
  [[ "$output" == *"rel"* ]]
  [[ "$output" != *"inb"* ]]
}

@test "task list --due today filters" {
  seed a "due-today-task" med open inbox today 1
  seed b "due-tomorrow-task" med open inbox tomorrow 2
  run run_list "" "" "" today
  [[ "$output" == *"due-today-task"* ]]
  [[ "$output" != *"due-tomorrow-task"* ]]
}

@test "task list --json emits an array of records" {
  seed a "hello" med open inbox today 1
  seed b "world" high open inbox tomorrow 2
  run run_list "" "" "" "" true
  [ "$status" -eq 0 ]
  [ "$(jq -r 'length' <<< "$output")" = "2" ]
  [ "$(jq -r '.[0].slug' <<< "$output")" = "a" ]
  [ "$(jq -r '.[1].slug' <<< "$output")" = "b" ]
}

@test "task list orders by seq" {
  seed c "c" med open inbox "" 3
  seed a "a" med open inbox "" 1
  seed b "b" med open inbox "" 2
  run run_list "" "" "" "" true
  [ "$(jq -r '.[0].slug' <<< "$output")" = "a" ]
  [ "$(jq -r '.[1].slug' <<< "$output")" = "b" ]
  [ "$(jq -r '.[2].slug' <<< "$output")" = "c" ]
}

@test "task list skips malformed JSON files with warning" {
  seed a "good" med open inbox "" 1
  printf 'not-json{{\n' > "$JARVIS_HOME/test/tasks/bad.json"
  # log_warn writes to stderr; --separate-stderr lets us assert against
  # the right stream instead of hedging against a merged $output.
  run --separate-stderr bash -c '
    set -euo pipefail
    declare -A CLIFT_FLAGS=([all]="" [priority]="" [project]="" [due]="" [json]="" [yaml]="")
    FRAMEWORK_DIR='"'$CLIFT_FRAMEWORK_DIR'"' \
    CLI_DIR='"'$JARVIS_DIR'"' \
    source "$1"
  ' _ "$JARVIS_DIR/cmds/task/task.list.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"good"* ]]
  [[ "$stderr" == *"malformed"* ]]
}

@test "task list honors NO_COLOR env" {
  seed fix-k3s "Fix k3s" high open release "" 1
  NO_COLOR=1 run run_list
  [ "$status" -eq 0 ]
  [[ "$output" != *$'\033['* ]]
}

@test "task list with no matching tasks after filter prints 'no open tasks'" {
  seed a "high one" high open inbox "" 1
  seed b "med one"  med  open inbox "" 2
  run run_list "" low
  [ "$status" -eq 0 ]
  [[ "$output" == *"no open tasks"* ]]
}

@test "task list --yaml emits yaml list of records" {
  seed a "hello" med open inbox today 1
  seed b "world" high open inbox tomorrow 2
  run run_list "" "" "" "" "" true
  [ "$status" -eq 0 ]
  # yq -P emits each record as a yaml block starting with `- slug:`.
  [[ "$output" == *"- slug:"* ]] || [[ "$output" == "[]"* ]]
  [[ "$output" == *"hello"* ]]
  [[ "$output" == *"world"* ]]
}

@test "task list --yaml on empty store still emits a valid yaml document" {
  # No seeds → empty list. yq -P renders as `[]`.
  run run_list "" "" "" "" "" true
  [ "$status" -eq 0 ]
  [[ "$output" == *"[]"* ]] || [[ "$output" == *"- slug:"* ]]
}

_run_list_with_jira() {
  # Direct invocation with --jira=true; lets us drive the merge path while
  # still picking up the rest of the script's CLIFT_FLAGS contract.
  local json="${1:-}"
  local project="${2:-}"
  FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR" \
  CLI_DIR="$JARVIS_DIR" \
  bash -c '
    set -euo pipefail
    declare -A CLIFT_FLAGS=(
      [all]=""
      [priority]=""
      [project]="'"$project"'"
      [due]=""
      [json]="'"$json"'"
      [yaml]=""
      [jira]="true"
    )
    source "$1"
  ' _ "$JARVIS_DIR/cmds/task/task.list.sh"
}

@test "task list --jira merges open jira issues with local tasks" {
  seed local-thing "ship the thing" high open release "" 1
  shim_install jira '
    case "$1" in
      me) printf "shimuser\n" ;;
      issue)
        # `jira issue list -ashimuser -s"To Do" -s"In Progress" --plain ...`
        printf "key\tsummary\tstatus\n"
        printf "FOO-101\tdo a thing\tTo Do\n"
        printf "FOO-202\tdo another thing\tIn Progress\n"
        ;;
    esac'
  cat > "$JARVIS_HOME/test/config.toml" <<EOF
[jira]
base_url = "https://jira.example.com"
EOF
  run _run_list_with_jira
  [ "$status" -eq 0 ]
  [[ "$output" == *"local-thing"* ]]
  [[ "$output" == *"FOO-101"* ]]
  [[ "$output" == *"FOO-202"* ]]
  [[ "$output" == *"do a thing"* ]]
}

@test "task list --jira --json projects jira issues with source=jira" {
  seed local-thing "ship the thing" high open release "" 1
  shim_install jira '
    case "$1" in
      me) printf "shimuser\n" ;;
      issue) printf "key\tsummary\tstatus\nFOO-7\twrite docs\tIn Progress\n" ;;
    esac'
  cat > "$JARVIS_HOME/test/config.toml" <<EOF
[jira]
base_url = "https://jira.example.com"
EOF
  run _run_list_with_jira true
  [ "$status" -eq 0 ]
  [ "$(jq -r 'length' <<< "$output")" = "2" ]
  # Local task has no source field; jira record carries source=jira.
  [ "$(jq -r '[.[] | select(.source=="jira")] | length' <<< "$output")" = "1" ]
  [ "$(jq -r '[.[] | select(.source=="jira")][0].slug' <<< "$output")" = "FOO-7" ]
  [ "$(jq -r '[.[] | select(.source=="jira")][0].url' <<< "$output")" = "https://jira.example.com/browse/FOO-7" ]
  [ "$(jq -r '[.[] | select(.source=="jira")][0].project' <<< "$output")" = "jira" ]
}

@test "task list --jira --project jira filters to jira-only" {
  seed local-thing "ship the thing" high open release "" 1
  shim_install jira '
    case "$1" in
      me) printf "shimuser\n" ;;
      issue) printf "key\tsummary\tstatus\nFOO-7\twrite docs\tIn Progress\n" ;;
    esac'
  cat > "$JARVIS_HOME/test/config.toml" <<EOF
[jira]
base_url = "https://jira.example.com"
EOF
  run _run_list_with_jira true jira
  [ "$status" -eq 0 ]
  [ "$(jq -r 'length' <<< "$output")" = "1" ]
  [ "$(jq -r '.[0].slug' <<< "$output")" = "FOO-7" ]
}

@test "task list --jira is silent when jira CLI is missing" {
  seed local-thing "ship the thing" high open release "" 1
  # No shim_install jira → jira not on PATH inside the test sandbox.
  run --separate-stderr _run_list_with_jira
  [ "$status" -eq 0 ]
  [[ "$output" == *"local-thing"* ]]
  [[ "$output" != *"FOO-"* ]]
  # No "not yet implemented" or panic on stderr.
  [[ "$stderr" != *"not yet implemented"* ]]
}

@test "task list renders empty/null project the same way as null due" {
  # Both an empty project string and a null due value should render
  # consistently so the column doesn't look broken. We pin '—' for both.
  seed a "no proj" med open "" "" 1
  run run_list
  [ "$status" -eq 0 ]
  # Walk the data row for the seeded task — count occurrences of '—'
  # in the row to confirm both columns render the placeholder.
  local row
  row="$(printf '%s\n' "$output" | grep -F 'no proj' || true)"
  [ -n "$row" ]
  # Two placeholder columns minimum (due + project both null/empty).
  local count
  count="$(printf '%s\n' "$row" | grep -o -- '—' | wc -l)"
  [ "$count" -ge 2 ]
}
