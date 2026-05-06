#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

load helper

# jarvis_ndjson_parity.bats — D2 cross-encoder NDJSON gate.
#
# Independently validates that all THREE encoders agree byte-for-byte
# on the canonical NDJSON shape:
#   - Python oracle (scripts/build_ndjson_golden.py + ensure_ascii=False)
#   - Rust serde_json with preserve_order (jarvis-cal emit-fixtures-for-parity)
#   - Go encoding/json with manual canonical emit (jarvis-state emit-fixtures-for-parity)
#
# A drift in any one of the three breaks the gate. The fixtures live at
# tests/fixtures/ndjson-parity/ — see docs/ndjson-contract.md.

CAL=
STATE=
ORACLE=
INPUTS_DIR=
GOLDEN_DIR=

setup() {
  # Resolve paths and (if needed) build the binaries BEFORE jarvis_common_setup
  # redirects HOME — cargo/rustup look up the toolchain in $HOME/.rustup, and
  # a redirected HOME makes the build fail with 'no default toolchain'.
  JARVIS_DIR="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  CAL="$JARVIS_DIR/bin/jarvis-cal"
  STATE="$JARVIS_DIR/bin/jarvis-state"
  ORACLE="$JARVIS_DIR/scripts/build_ndjson_golden.py"
  INPUTS_DIR="$JARVIS_DIR/tests/fixtures/ndjson-parity/inputs"
  GOLDEN_DIR="$JARVIS_DIR/tests/fixtures/ndjson-parity/golden"
  if [[ ! -x "$CAL" ]]; then
    bash "$JARVIS_DIR/scripts/build_cal.sh"
  fi
  if [[ ! -x "$STATE" ]]; then
    bash "$JARVIS_DIR/scripts/build_state.sh"
  fi
  jarvis_common_setup
}

teardown() {
  jarvis_common_teardown
}

@test "Python oracle --check passes against committed golden" {
  run python3 "$ORACLE" --check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "jarvis-cal emit matches committed golden byte-for-byte (50 fixtures)" {
  out_dir="$BATS_TEST_TMPDIR/cal-out"
  run "$CAL" emit-fixtures-for-parity --inputs "$INPUTS_DIR" --output "$out_dir"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run diff -r "$GOLDEN_DIR" "$out_dir"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "jarvis-state emit matches committed golden byte-for-byte (50 fixtures)" {
  out_dir="$BATS_TEST_TMPDIR/state-out"
  run "$STATE" emit-fixtures-for-parity --inputs "$INPUTS_DIR" --output "$out_dir"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run diff -r "$GOLDEN_DIR" "$out_dir"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "Rust + Go emit byte-identical output to each other (cross-encoder)" {
  cal_dir="$BATS_TEST_TMPDIR/cal-cross"
  state_dir="$BATS_TEST_TMPDIR/state-cross"
  "$CAL" emit-fixtures-for-parity --inputs "$INPUTS_DIR" --output "$cal_dir"
  "$STATE" emit-fixtures-for-parity --inputs "$INPUTS_DIR" --output "$state_dir"
  run diff -r "$cal_dir" "$state_dir"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "all three encoders agree (Python ↔ Rust ↔ Go)" {
  py_dir="$BATS_TEST_TMPDIR/py-out"
  cal_dir="$BATS_TEST_TMPDIR/cal-out"
  state_dir="$BATS_TEST_TMPDIR/state-out"
  python3 "$ORACLE" --output "$py_dir"
  "$CAL" emit-fixtures-for-parity --inputs "$INPUTS_DIR" --output "$cal_dir"
  "$STATE" emit-fixtures-for-parity --inputs "$INPUTS_DIR" --output "$state_dir"
  run diff -r "$py_dir" "$cal_dir"
  [ "$status" -eq 0 ] || { echo "py vs cal: $output"; return 1; }
  run diff -r "$py_dir" "$state_dir"
  [ "$status" -eq 0 ] || { echo "py vs state: $output"; return 1; }
  run diff -r "$cal_dir" "$state_dir"
  [ "$status" -eq 0 ] || { echo "cal vs state: $output"; return 1; }
}
