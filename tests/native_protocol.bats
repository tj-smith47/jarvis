#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

load helper

JARVIS_DIR_REAL="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
PROTOCOL_LIB="${JARVIS_DIR_REAL}/lib/native/protocol.sh"

setup() {
  jarvis_common_setup
  LOG_LIB="${CLIFT_FRAMEWORK_DIR}/lib/log/log.sh"
  export FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR"
  export JARVIS_DIR="$JARVIS_DIR_REAL"
  # Stub bin dir lives in bats-managed tmp
  mkdir -p "$BATS_TMPDIR/bin"
}

teardown() {
  jarvis_common_teardown
  rm -rf "$BATS_TMPDIR/bin"
}

# ---------------------------------------------------------------------------
# Helper: write a stub binary that prints VERSION on --protocol-version
# and exits EXIT_CODE; on any other arg it exits 0.
# ---------------------------------------------------------------------------
make_stub() {
  local name="$1" version="$2" exit_on_flag="${3:-0}"
  local path="$BATS_TMPDIR/bin/$name"
  printf '#!/usr/bin/env bash\n' > "$path"
  printf 'if [[ "${1:-}" == "--protocol-version" ]]; then\n' >> "$path"
  if [[ -n "$version" ]]; then
    printf '  printf "%%s\\n" "%s"\n' "$version" >> "$path"
  fi
  printf '  exit %s\n' "$exit_on_flag" >> "$path"
  printf 'fi\n' >> "$path"
  printf 'exit 0\n' >> "$path"
  chmod +x "$path"
  echo "$path"
}

# ---------------------------------------------------------------------------
# 1. Happy path: stub prints "1", native_protocol_check returns 0, no output.
# ---------------------------------------------------------------------------
@test "native_protocol_check: happy path — version matches, returns 0, no output" {
  local stub
  stub="$(make_stub "foo" "1" "0")"

  run --separate-stderr bash -c "
    LOG_THEME=minimal
    source '$LOG_LIB'
    source '$PROTOCOL_LIB'
    native_protocol_check '$stub'
  "
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

# ---------------------------------------------------------------------------
# 2. Mismatch: stub prints "0", helper exits 4 with protocol mismatch message.
# ---------------------------------------------------------------------------
@test "native_protocol_check: version mismatch — exits 4, stderr contains mismatch message" {
  local stub
  stub="$(make_stub "bar" "0" "0")"

  run --separate-stderr bash -c "
    LOG_THEME=minimal
    source '$LOG_LIB'
    source '$PROTOCOL_LIB'
    native_protocol_check '$stub'
  "
  [ "$status" -eq 4 ]
  [[ "$stderr" == *"speaks protocol 0, jarvis expects 1"* ]]
}

# ---------------------------------------------------------------------------
# 3. Missing flag: stub exits 2 on --protocol-version (old binary or absent).
# ---------------------------------------------------------------------------
@test "native_protocol_check: binary exits non-zero on --protocol-version — exits 4, too old message" {
  local stub
  stub="$(make_stub "baz" "" "2")"

  run --separate-stderr bash -c "
    LOG_THEME=minimal
    source '$LOG_LIB'
    source '$PROTOCOL_LIB'
    native_protocol_check '$stub'
  "
  [ "$status" -eq 4 ]
  [[ "$stderr" == *"too old or missing --protocol-version"* ]]
}

# ---------------------------------------------------------------------------
# 4. Caching: second call does not re-fork the binary (binary removed between
#    calls but second invocation still succeeds because result is cached).
# ---------------------------------------------------------------------------
@test "native_protocol_check: second call uses cache — binary can be removed between calls" {
  local stub
  stub="$(make_stub "cached" "1" "0")"

  run bash -c "
    LOG_THEME=minimal
    source '$LOG_LIB'
    source '$PROTOCOL_LIB'
    # First call — populates cache
    native_protocol_check '$stub' || exit 1
    # Remove binary so a real fork would fail
    rm -f '$stub'
    # Second call — must use cached value and succeed
    native_protocol_check '$stub' || exit 1
    echo ok
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}
