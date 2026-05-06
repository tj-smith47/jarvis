#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

load helper

JARVIS_DIR_REAL="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() { jarvis_common_setup; }
teardown() { jarvis_common_teardown; }

# ---------------------------------------------------------------------------
# Lint gate: no cmd script may call native_protocol_check directly.
# Cmds must go through the wrapper layer (lib/native/{state,cal,when}.sh).
# This test will fail CI if any cmd author bypasses the abstraction.
# ---------------------------------------------------------------------------
@test "no cmd calls native_protocol_check directly" {
  local count
  count="$(grep -rn 'native_protocol_check' "${JARVIS_DIR_REAL}/cmds/" 2>/dev/null | wc -l | tr -d '[:space:]')"
  [ "$count" -eq 0 ]
}
