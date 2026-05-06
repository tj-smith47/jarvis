#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

load helper

setup() {
  jarvis_common_setup
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/cache/file.sh"
}
teardown() { jarvis_common_teardown; }

@test "cache_get on missing key -> exit 1" {
  run cache_get test calendar 300
  [ "$status" -eq 1 ]
}

@test "cache_put then cache_get within TTL -> returns content" {
  cache_put test calendar '{"events":[]}'
  run cache_get test calendar 300
  [ "$status" -eq 0 ]
  [ "$output" = '{"events":[]}' ]
}

@test "cache_get past TTL -> exit 1" {
  cache_put test calendar '{"events":[]}'
  # Backdate the file 600s
  touch -d "@$(($(date +%s) - 600))" "$JARVIS_HOME/test/cache/calendar.json"
  run cache_get test calendar 300
  [ "$status" -eq 1 ]
}

@test "cache_put is atomic -- no partial files visible" {
  cache_put test foo '{"a":1}'
  [ ! -f "$JARVIS_HOME/test/cache/foo.json.tmp" ]
  [ -f "$JARVIS_HOME/test/cache/foo.json" ]
}

@test "cache_get TTL=0 always stale" {
  cache_put test calendar '{"events":[]}'
  run cache_get test calendar 0
  [ "$status" -eq 1 ]
}

@test "cache round-trip preserves trailing newline (NDJSON)" {
  # Multi-line NDJSON ending in \n must come back identical.
  printf -v ndjson '{"a":1}\n{"b":2}\n'
  cache_put test ndjson "$ndjson"
  run cache_get test ndjson 300
  [ "$status" -eq 0 ]
  [ "$output" = '{"a":1}
{"b":2}' ]   # bats strips ONE trailing \n into $output; raw bytes verified below
  raw="$(wc -c < "$JARVIS_HOME/test/cache/ndjson.json")"
  [ "$raw" -eq 16 ]
}

@test "JARVIS_FAKE_NOW shifts TTL evaluation" {
  cache_put test calendar '{"events":[]}'
  # mtime ~ real now; fake-now 600s in future -> past TTL
  future=$(( $(date +%s) + 600 ))
  if date -u -d "@$future" +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
    JARVIS_FAKE_NOW="$(date -u -d "@$future" +%Y-%m-%dT%H:%M:%SZ)"
  else
    JARVIS_FAKE_NOW="$(date -u -j -f %s "$future" +%Y-%m-%dT%H:%M:%SZ)"
  fi
  export JARVIS_FAKE_NOW
  run cache_get test calendar 300
  [ "$status" -eq 1 ]
}

@test "cache_get sets _CACHE_GET_REASON for each failure mode (T1-W3)" {
  unset _CACHE_GET_REASON
  cache_get test missing-key 300 || true
  [ "$_CACHE_GET_REASON" = "missing" ]
  cache_put test foo '{"a":1}'
  unset _CACHE_GET_REASON
  cache_get test foo 0 || true
  [ "$_CACHE_GET_REASON" = "ttl_zero" ]
  touch -d "@$(($(date +%s) - 600))" "$JARVIS_HOME/test/cache/foo.json"
  unset _CACHE_GET_REASON
  cache_get test foo 300 || true
  [ "$_CACHE_GET_REASON" = "stale" ]
}

@test "cache_put surfaces stderr on mkdir failure (T1-W2)" {
  # Point JARVIS_HOME at a regular file so `mkdir -p` cannot create the
  # cache subdirectory under it. Works even when the test runs as root
  # (chmod 0500 doesn't gate root, but a file-instead-of-directory does).
  blocker="$BATS_TEST_TMPDIR/blocker"
  : > "$blocker"   # regular file
  JARVIS_HOME="$blocker" run cache_put test foo '{}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"mkdir"* ]]
  [[ "$output" == *"failed"* ]]
}

@test "cache_put_file: byte-exact NDJSON with trailing newline survives round-trip" {
  src="$BATS_TEST_TMPDIR/ndjson.txt"
  printf '{"a":1}\n{"b":2}\n' > "$src"
  cache_put_file test ndj "$src"
  cmp "$src" "$JARVIS_HOME/test/cache/ndj.json"
}
