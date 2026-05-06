#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

load 'helper'

setup() {
  jarvis_common_setup
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/state/profile.sh"
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/integrations/deploys.sh"
  state_ensure_tree
}
teardown() { jarvis_common_teardown; }

@test "missing deploys.log -> exit 1" {
  run deploys_recent "2026-04-01T00:00:00Z" test
  [ "$status" -eq 1 ]
}

@test "deploys.log entries within window emit NDJSON" {
  cat > "$JARVIS_HOME/test/deploys.log" <<EOF
# header
2026-05-01T13:00:00Z	api	v1.12.3	ok
2026-05-01T08:00:00Z	web	v0.47.1	ok
2026-04-30T12:00:00Z	ingest	v2.1.0	rolled-back
2026-04-01T00:00:00Z	old	v0.0.1	ok
EOF
  run deploys_recent "2026-04-30T00:00:00Z" test
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 3 ]
  printf '%s\n' "$output" | head -1 | jq -e '.service == "api" and .status == "ok"' > /dev/null
}

@test "comment + blank lines ignored" {
  cat > "$JARVIS_HOME/test/deploys.log" <<EOF
# initial deploys

2026-05-01T10:00:00Z	api	v1.0	ok
EOF
  run deploys_recent "2026-05-01T00:00:00Z" test
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
}
