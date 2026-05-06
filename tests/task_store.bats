#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

load helper

setup() {
  jarvis_common_setup
  source "$JARVIS_DIR/lib/state/profile.sh"
  source "$JARVIS_DIR/lib/state/lock.sh"
  source "$JARVIS_DIR/lib/state/json.sh"
  source "$JARVIS_DIR/lib/task/store.sh"
  state_ensure_tree
}
teardown() { jarvis_common_teardown; }

@test "task_store_dir resolves under profile" {
  run task_store_dir
  [ "$status" -eq 0 ]
  [ "$output" = "$JARVIS_HOME/test/tasks" ]
}

@test "task_store_now_iso emits UTC YYYY-MM-DDTHH:MM:SSZ" {
  run task_store_now_iso
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "task_store_next_seq starts at 1 and increments monotonically" {
  run task_store_next_seq
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  run task_store_next_seq
  [ "$output" = "2" ]
  run task_store_next_seq
  [ "$output" = "3" ]
}

@test "task_store_build emits valid JSON with all fields" {
  run task_store_build fix-k3s "Fix k3s etcd" med today inbox 7 null
  [ "$status" -eq 0 ]
  [ "$(jq -r '.slug' <<< "$output")" = "fix-k3s" ]
  [ "$(jq -r '.status' <<< "$output")" = "open" ]
  [ "$(jq -r '.priority' <<< "$output")" = "med" ]
  [ "$(jq -r '.due' <<< "$output")" = "today" ]
  [ "$(jq -r '.project' <<< "$output")" = "inbox" ]
  [ "$(jq -r '.seq' <<< "$output")" = "7" ]
  [ "$(jq -r '.jira_key' <<< "$output")" = "null" ]
  [ "$(jq -r '.done_at' <<< "$output")" = "null" ]
}

@test "task_store_put then task_store_get round-trips" {
  local payload
  payload="$(task_store_build foo "hello" low "" inbox 1 null)"
  task_store_put foo "$payload"
  [ -f "$JARVIS_HOME/test/tasks/foo.json" ]
  run task_store_get foo
  [ "$status" -eq 0 ]
  [ "$(jq -r '.desc' <<< "$output")" = "hello" ]
}

@test "task_store_put rejects dot-prefixed slugs" {
  # `*.json` glob in task_store_list excludes dotfiles, so a slug like
  # `.foo` would silently disappear from list. The store must refuse
  # anything outside the slug_from_desc shape rather than half-store it.
  local payload
  payload="$(task_store_build .foo "x" med "" inbox 1 null)"
  run task_store_put .foo "$payload"
  [ "$status" -ne 0 ]
  [ ! -e "$JARVIS_HOME/test/tasks/.foo.json" ]
}

@test "task_store_put rejects path-traversal slugs" {
  local payload
  payload="$(task_store_build x "x" med "" inbox 1 null)"
  run task_store_put "../escape" "$payload"
  [ "$status" -ne 0 ]
  [ ! -e "$JARVIS_HOME/test/escape.json" ]
}

@test "task_store_put accepts valid hyphenated slug" {
  local payload
  payload="$(task_store_build fix-k3s-2 "x" med "" inbox 1 null)"
  run task_store_put fix-k3s-2 "$payload"
  [ "$status" -eq 0 ]
  [ -f "$JARVIS_HOME/test/tasks/fix-k3s-2.json" ]
}

@test "task_store_exists reflects file presence" {
  run task_store_exists foo
  [ "$status" -ne 0 ]
  task_store_put foo "$(task_store_build foo "x" med "" inbox 1 null)"
  run task_store_exists foo
  [ "$status" -eq 0 ]
}

@test "task_store_delete removes file and lock sidecar" {
  task_store_put foo "$(task_store_build foo "x" med "" inbox 1 null)"
  : > "$JARVIS_HOME/test/tasks/foo.json.lock"
  task_store_delete foo
  [ ! -f "$JARVIS_HOME/test/tasks/foo.json" ]
  [ ! -f "$JARVIS_HOME/test/tasks/foo.json.lock" ]
}

@test "task_store_list orders by seq" {
  task_store_put a "$(task_store_build a "a" med "" inbox 2 null)"
  task_store_put b "$(task_store_build b "b" med "" inbox 1 null)"
  task_store_put c "$(task_store_build c "c" med "" inbox 3 null)"
  run task_store_list
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "b" ]
  [ "${lines[1]}" = "a" ]
  [ "${lines[2]}" = "c" ]
}

@test "task_store_list status=open excludes done" {
  task_store_put a "$(task_store_build a "a" med "" inbox 1 null)"
  local done_json
  done_json="$(task_store_build b "b" med "" inbox 2 null \
    | jq '.status = "done" | .done_at = "2026-04-20T00:00:00Z"')"
  task_store_put b "$done_json"
  run task_store_list open
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "a" ]
}

@test "task_store_list skips corrupt records and returns valid ones with stderr warning" {
  # Hand-edited corruption shouldn't take the whole list down — that loses
  # visibility on the rest of the user's tasks. Skip-and-warn is the
  # right balance: user sees the problem, list still works.
  task_store_put a "$(task_store_build a "a" med "" inbox 1 null)"
  printf 'not json {{{\n' > "$JARVIS_HOME/test/tasks/broken.json"
  task_store_put c "$(task_store_build c "c" med "" inbox 2 null)"
  run --separate-stderr task_store_list
  [ "$status" -eq 0 ]
  [[ "$output" == *"a"* ]]
  [[ "$output" == *"c"* ]]
  [[ "$output" != *"broken"* ]]
  [[ "$stderr" == *"broken.json"* ]]
}

@test "task_store_get fails fast with stderr message on corrupt record" {
  printf 'not json\n' > "$JARVIS_HOME/test/tasks/wedge.json"
  run --separate-stderr task_store_get wedge
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"wedge.json"* ]]
}

@test "task_store_delete cleans tmp sidecars even with nullglob set in caller" {
  # If a caller has nullglob enabled, an unquoted glob still needs to
  # behave the same — orphaned .tmp.* files left from a crashed
  # write must be removed.
  task_store_put foo "$(task_store_build foo "x" med "" inbox 1 null)"
  : > "$JARVIS_HOME/test/tasks/foo.json.tmp.999.0.0"
  : > "$JARVIS_HOME/test/tasks/foo.json.lock"
  shopt -s nullglob
  task_store_delete foo
  shopt -u nullglob
  [ ! -f "$JARVIS_HOME/test/tasks/foo.json" ]
  [ ! -f "$JARVIS_HOME/test/tasks/foo.json.lock" ]
  [ ! -f "$JARVIS_HOME/test/tasks/foo.json.tmp.999.0.0" ]
}

@test "task_store_set_done flips status and sets done_at" {
  task_store_put foo "$(task_store_build foo "x" med "" inbox 1 null)"
  task_store_set_done foo
  run task_store_get foo
  [ "$(jq -r '.status' <<< "$output")" = "done" ]
  [ "$(jq -r '.done_at' <<< "$output")" != "null" ]
}

@test "task_store_mutate applies jq filter and bumps updated_at" {
  task_store_put foo "$(task_store_build foo "x" med "" inbox 1 null)"
  sleep 1   # ensure updated_at monotonic
  task_store_mutate foo '.priority = "high"'
  run task_store_get foo
  [ "$(jq -r '.priority' <<< "$output")" = "high" ]
  [ "$(jq -r '.created_at != .updated_at' <<< "$output")" = "true" ]
}
