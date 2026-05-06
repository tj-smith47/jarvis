#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

load helper

# native_clock.bats — coverage for lib/native/clock.sh, the wrapper
# that hides bin/jarvis-when behind a stable bash API.

CLOCK_LIB=
LOG_LIB=
WHEN_BIN=

setup() {
  CLI_DIR_REAL="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  CLOCK_LIB="${CLI_DIR_REAL}/lib/native/clock.sh"
  jarvis_common_setup
  LOG_LIB="${CLIFT_FRAMEWORK_DIR}/lib/log/log.sh"
  WHEN_BIN="${CLI_DIR_REAL}/bin/jarvis-when"
  if [[ ! -x "$WHEN_BIN" ]]; then
    bash "${CLI_DIR_REAL}/scripts/build_when.sh"
  fi
  export CLI_DIR="$CLI_DIR_REAL"
}

teardown() {
  jarvis_common_teardown
  unset JARVIS_FAKE_NOW JARVIS_TODAY CLI_DIR
}

# ---------- now / today ----------------------------------------------------

@test "native_now_iso returns FAKE_NOW pass-through" {
  export JARVIS_FAKE_NOW="2026-04-28T12:00:00Z"
  run bash -c "source '$LOG_LIB'; source '$CLOCK_LIB'; native_now_iso"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-04-28T12:00:00Z" ]
}

@test "native_now_epoch matches FAKE_NOW seconds-since-epoch" {
  export JARVIS_FAKE_NOW="2026-04-28T12:00:00Z"
  run bash -c "source '$LOG_LIB'; source '$CLOCK_LIB'; native_now_epoch"
  [ "$status" -eq 0 ]
  expected="$(date -u -d "2026-04-28T12:00:00Z" +%s 2>/dev/null \
              || date -u -j -f %Y-%m-%dT%H:%M:%SZ "2026-04-28T12:00:00Z" +%s)"
  [ "$output" = "$expected" ]
}

@test "native_today_local returns FAKE_NOW date" {
  export JARVIS_FAKE_NOW="2026-04-28T12:00:00Z"
  run bash -c "source '$LOG_LIB'; source '$CLOCK_LIB'; native_today_local"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-04-28" ]
}

@test "native_today_local: JARVIS_TODAY overrides JARVIS_FAKE_NOW" {
  export JARVIS_FAKE_NOW="2026-04-28T12:00:00Z"
  export JARVIS_TODAY="2026-12-31"
  run bash -c "source '$LOG_LIB'; source '$CLOCK_LIB'; native_today_local"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-12-31" ]
}

# ---------- resolve --------------------------------------------------------

@test "native_resolve 'tomorrow' maps to next-day midnight" {
  export JARVIS_FAKE_NOW="2026-04-28T12:00:00Z"
  run bash -c "source '$LOG_LIB'; source '$CLOCK_LIB'; native_resolve tomorrow"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-04-29T00:00:00Z" ]
}

@test "native_resolve 'in 2h' adds 2 hours" {
  export JARVIS_FAKE_NOW="2026-04-28T12:00:00Z"
  run bash -c "source '$LOG_LIB'; source '$CLOCK_LIB'; native_resolve 'in 2h'"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-04-28T14:00:00Z" ]
}

@test "native_resolve 'next monday' from a Tuesday" {
  export JARVIS_FAKE_NOW="2026-04-28T12:00:00Z"
  run bash -c "source '$LOG_LIB'; source '$CLOCK_LIB'; native_resolve 'next monday'"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-05-04T00:00:00Z" ]
}

@test "native_resolve gibberish exits non-zero with stderr" {
  run bash -c "source '$LOG_LIB'; source '$CLOCK_LIB'; native_resolve 'frobnicate'" 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"unrecognised"* ]] || [[ "$output" == *"jarvis-when"* ]]
}

@test "native_resolve_to_epoch round-trips via native_epoch_to_iso" {
  export JARVIS_FAKE_NOW="2026-04-28T12:00:00Z"
  run bash -c "source '$LOG_LIB'; source '$CLOCK_LIB'; ep=\$(native_resolve_to_epoch tomorrow); native_epoch_to_iso \$ep"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-04-29T00:00:00Z" ]
}

# ---------- day-boundary helpers -------------------------------------------

@test "native_day_start strips time component to midnight UTC" {
  run bash -c "source '$LOG_LIB'; source '$CLOCK_LIB'; native_day_start 2026-04-28T15:30:45Z"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-04-28T00:00:00Z" ]
}

@test "native_day_boundary +1d adds a day" {
  export JARVIS_FAKE_NOW="2026-04-28T15:00:00Z"
  run bash -c "source '$LOG_LIB'; source '$CLOCK_LIB'; native_day_boundary 2026-04-28T15:30:45Z +1d"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-04-29T00:00:00Z" ]
}

@test "native_day_boundary +7d advances seven days" {
  export JARVIS_FAKE_NOW="2026-04-28T00:00:00Z"
  run bash -c "source '$LOG_LIB'; source '$CLOCK_LIB'; native_day_boundary 2026-04-28T00:00:00Z +7d"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-05-05T00:00:00Z" ]
}

@test "native_day_boundary rejects bad delta with exit 2" {
  run bash -c "source '$LOG_LIB'; source '$CLOCK_LIB'; native_day_boundary 2026-04-28T00:00:00Z 1d 2>&1"
  [ "$status" -eq 2 ]
  [[ "$output" == *"bad delta"* ]]
}

# ---------- protocol pin ---------------------------------------------------

@test "first call triggers a single protocol-pin check" {
  # Stub jarvis-when wrapper that records each invocation.
  local stub_dir="$BATS_TEST_TMPDIR/stub-cli"
  mkdir -p "$stub_dir/bin"
  local log="$stub_dir/calls.log"
  cat > "$stub_dir/bin/jarvis-when" <<EOF
#!/bin/sh
echo "\$@" >> '$log'
case "\$1" in
  --protocol-version) echo 1 ;;
  parse)              echo 2026-04-28T12:00:00Z ;;
esac
EOF
  chmod +x "$stub_dir/bin/jarvis-when"
  export CLI_DIR="$stub_dir"
  run bash -c "source '$LOG_LIB'; source '$CLOCK_LIB'; native_now_iso; native_now_iso; native_now_iso"
  [ "$status" -eq 0 ]
  # Three native_now_iso calls = 1 --protocol-version + 3 parse = 4 lines.
  [ "$(wc -l < "$log")" -eq 4 ]
  [ "$(grep -c -- --protocol-version "$log")" -eq 1 ]
}

@test "protocol mismatch exits 4 from the wrapper" {
  local stub_dir="$BATS_TEST_TMPDIR/stub-bad"
  mkdir -p "$stub_dir/bin"
  cat > "$stub_dir/bin/jarvis-when" <<'EOF'
#!/bin/sh
case "$1" in
  --protocol-version) echo 0 ;;
  *)                  exit 0 ;;
esac
EOF
  chmod +x "$stub_dir/bin/jarvis-when"
  export CLI_DIR="$stub_dir"
  run bash -c "source '$LOG_LIB'; source '$CLOCK_LIB'; native_now_iso 2>&1"
  [ "$status" -eq 4 ]
  [[ "$output" == *"speaks protocol"* ]]
}
