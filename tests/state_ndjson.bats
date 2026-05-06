#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

load helper

setup() {
  jarvis_common_setup
  source "$JARVIS_DIR/lib/state/lock.sh"
  source "$JARVIS_DIR/lib/state/ndjson.sh"
  LOG="$TEST_DIR/test.ndjson"
}
teardown() { jarvis_common_teardown; }

@test "ndjson_append creates file and writes one line" {
  ndjson_append "$LOG" '{"a":1}'
  [ -f "$LOG" ]
  run wc -l < "$LOG"
  [ "$output" -eq 1 ]
  run cat "$LOG"
  [ "$output" = '{"a":1}' ]
}

@test "ndjson_append appends multiple lines" {
  ndjson_append "$LOG" '{"a":1}'
  ndjson_append "$LOG" '{"a":2}'
  ndjson_append "$LOG" '{"a":3}'
  run wc -l < "$LOG"
  [ "$output" -eq 3 ]
  run jq -s 'length' "$LOG"
  [ "$output" -eq 3 ]
  run jq -s '[.[].a]' "$LOG"
  [ "$(echo "$output" | jq -c '.')" = '[1,2,3]' ]
}

@test "ndjson_append rejects invalid JSON, file unchanged" {
  ndjson_append "$LOG" '{"a":1}'
  run ndjson_append "$LOG" '{not valid json'
  [ "$status" -eq 2 ]
  run wc -l < "$LOG"
  [ "$output" -eq 1 ]
}

@test "ndjson_append rejects invalid JSON when file does not exist" {
  run ndjson_append "$LOG" 'garbage'
  [ "$status" -eq 2 ]
  [ ! -f "$LOG" ]
}

@test "ndjson_append creates parent directories" {
  local nested="$TEST_DIR/a/b/c/log.ndjson"
  ndjson_append "$nested" '{"x":1}'
  [ -f "$nested" ]
}

@test "ndjson_append survives concurrent writers without torn lines" {
  for i in 1 2 3 4 5 6 7 8 9 10; do
    ndjson_append "$LOG" "$(jq -nc --arg i "$i" '{i: $i}')" &
  done
  wait
  run wc -l < "$LOG"
  [ "$output" -eq 10 ]
  # Every line must be valid JSON — no torn writes.
  run jq -e '. | type == "object" and has("i")' "$LOG"
  [ "$status" -eq 0 ]
}

@test "ndjson_read on missing file returns empty stdout, exit 0" {
  run ndjson_read "$TEST_DIR/never-existed.ndjson"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ndjson_read returns appended content verbatim" {
  ndjson_append "$LOG" '{"a":1}'
  ndjson_append "$LOG" '{"b":2}'
  run ndjson_read "$LOG"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l)" -eq 2 ]
  echo "$output" | jq -e '.' >/dev/null
}

@test "ndjson_read on empty file returns empty stdout" {
  : > "$LOG"
  run ndjson_read "$LOG"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
