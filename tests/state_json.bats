#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

load helper

setup() {
  jarvis_common_setup
  source "$JARVIS_DIR/lib/state/profile.sh"
  source "$JARVIS_DIR/lib/state/lock.sh"
  source "$JARVIS_DIR/lib/state/json.sh"
  state_ensure_tree
}
teardown() { jarvis_common_teardown; }

@test "state_json_write writes valid JSON atomically" {
  local f="$JARVIS_HOME/test/tasks/foo.json"
  state_json_write "$f" '{"slug":"foo","status":"open"}'
  [ -f "$f" ]
  jq -e '.slug == "foo"' "$f" >/dev/null
}

@test "state_json_write rejects invalid JSON" {
  local f="$JARVIS_HOME/test/tasks/bad.json"
  run state_json_write "$f" 'not json{'
  [ "$status" -ne 0 ]
  [ ! -f "$f" ]
}

@test "state_json_read returns contents" {
  local f="$JARVIS_HOME/test/tasks/foo.json"
  state_json_write "$f" '{"slug":"foo"}'
  run state_json_read "$f"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.slug' <<< "$output")" = "foo" ]
}

@test "state_json_read exits 1 on missing file" {
  run state_json_read "$JARVIS_HOME/test/tasks/nope.json"
  [ "$status" -eq 1 ]
}

@test "state_json_write is atomic (no partial file on jq failure)" {
  local f="$JARVIS_HOME/test/tasks/atomic.json"
  state_json_write "$f" '{"seq":1}'
  # Attempt to overwrite with invalid content
  run state_json_write "$f" 'garbage'
  [ "$status" -ne 0 ]
  # Original must still be intact
  [ "$(jq -r '.seq' "$f")" = "1" ]
}

@test "state_json_write survives concurrent writers (no tmp collisions)" {
  local f="$JARVIS_HOME/test/tasks/concurrent.json"
  local i pids=()
  for i in 1 2 3 4 5 6 7 8 9 10; do
    state_json_write "$f" "{\"writer\": $i}" &
    pids+=($!)
  done
  wait "${pids[@]}"
  # One of the 10 must win; file must be valid JSON.
  [ -f "$f" ]
  jq -e . "$f" >/dev/null
}

@test "state_json_mutate applies jq filter atomically" {
  local f="$JARVIS_HOME/test/tasks/m.json"
  state_json_write "$f" '{"n": 1}'
  state_json_mutate "$f" '.n += 10'
  [ "$(jq -r '.n' "$f")" = "11" ]
}

@test "state_json_mutate leaves file intact on jq error" {
  local f="$JARVIS_HOME/test/tasks/m.json"
  state_json_write "$f" '{"n": 1}'
  run state_json_mutate "$f" '.this_is_not_valid_jq_syntax ['
  [ "$status" -ne 0 ]
  [ "$(jq -r '.n' "$f")" = "1" ]
}

@test "state_json_mutate returns 1 on missing file" {
  run state_json_mutate "$JARVIS_HOME/test/tasks/nope.json" '.n = 1'
  [ "$status" -eq 1 ]
}

@test "state_json_mutate serializes concurrent writers (no lost updates)" {
  local f="$JARVIS_HOME/test/tasks/counter.json"
  state_json_write "$f" '{"n": 0}'
  # Fire 10 concurrent +1s.
  local i pids=()
  for i in 1 2 3 4 5 6 7 8 9 10; do
    state_json_mutate "$f" '.n += 1' &
    pids+=($!)
  done
  wait "${pids[@]}"
  [ "$(jq -r '.n' "$f")" = "10" ]
}

@test "state_json_mutate --arg passes shell metacharacters through verbatim" {
  # The --arg vararg threads user values into jq as bindings (\$NAME) so
  # callers don't have to embed untrusted strings into the filter text.
  # Pin that command-substitution markers, backticks, pipes, dollar
  # signs and quotes all land as literal characters in the persisted
  # field — i.e. nothing is interpolated by the shell or by jq's parser.
  local f="$JARVIS_HOME/test/tasks/meta.json"
  state_json_write "$f" '{"desc": "old"}'
  local payload='$(whoami) `id` | "quoted" '"'"'apostrophe'"'"' & background'
  state_json_mutate "$f" '.desc = $val' --arg val "$payload"
  [ "$(jq -r '.desc' "$f")" = "$payload" ]
}
