bats_require_minimum_version 1.5.0

# shellcheck disable=SC2034
JARVIS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
INPUTS_DIR="$JARVIS_DIR/tests/fixtures/ndjson-parity/inputs"
GOLDEN_DIR="$JARVIS_DIR/tests/fixtures/ndjson-parity/golden"
ORACLE="$JARVIS_DIR/scripts/build_ndjson_golden.py"

setup() {
  # Redirect HOME — never touch real shell rc files or config dirs.
  TEST_DIR="$(mktemp -d)"
  export HOME="$TEST_DIR"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# ---------------------------------------------------------------------------
# 1. Every input fixture parses as valid JSON
# ---------------------------------------------------------------------------
@test "each input fixture is valid JSON" {
  run find "$INPUTS_DIR" -name '*.json' -type f
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -gt 0 ]

  local failures=()
  for f in "$INPUTS_DIR"/*.json; do
    if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$f" 2>/dev/null; then
      failures+=("$f")
    fi
  done

  if [ "${#failures[@]}" -gt 0 ]; then
    echo "Invalid JSON files:"
    printf '  %s\n' "${failures[@]}"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 2. Every golden file is valid NDJSON (one JSON object per line)
# ---------------------------------------------------------------------------
@test "each golden file is valid NDJSON" {
  run find "$GOLDEN_DIR" -name '*.ndjson' -type f
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -gt 0 ]

  local failures=()
  for f in "$GOLDEN_DIR"/*.ndjson; do
    # Each non-empty line must be a parseable JSON object
    if ! python3 - "$f" <<'EOF' 2>/dev/null
import json, sys
with open(sys.argv[1]) as fh:
    for lineno, line in enumerate(fh, 1):
        line = line.rstrip('\n')
        if not line:
            continue
        obj = json.loads(line)
        if not isinstance(obj, dict):
            raise ValueError(f"line {lineno}: not an object")
EOF
    then
      failures+=("$f")
    fi
  done

  if [ "${#failures[@]}" -gt 0 ]; then
    echo "Invalid NDJSON files:"
    printf '  %s\n' "${failures[@]}"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 3. Regenerator is deterministic — two runs produce byte-identical output
# ---------------------------------------------------------------------------
@test "oracle regenerator is deterministic" {
  OUT_A="$TEST_DIR/golden-a"
  OUT_B="$TEST_DIR/golden-b"
  mkdir -p "$OUT_A" "$OUT_B"

  run python3 "$ORACLE" --output "$OUT_A"
  [ "$status" -eq 0 ] || { echo "First run failed: $output"; return 1; }

  run python3 "$ORACLE" --output "$OUT_B"
  [ "$status" -eq 0 ] || { echo "Second run failed: $output"; return 1; }

  run diff -r "$OUT_A" "$OUT_B"
  [ "$status" -eq 0 ] || { echo "Outputs differ between runs"; diff -r "$OUT_A" "$OUT_B"; return 1; }
}

# ---------------------------------------------------------------------------
# 4. --check flag against committed golden: no drift
# ---------------------------------------------------------------------------
@test "oracle --check passes against committed golden" {
  run python3 "$ORACLE" --check
  [ "$status" -eq 0 ] || { echo "Golden drift detected: $output"; return 1; }
}

# ---------------------------------------------------------------------------
# 5. Exactly 50 input fixtures exist
# ---------------------------------------------------------------------------
@test "exactly 50 input fixtures" {
  run bash -c "find '$INPUTS_DIR' -name '*.json' -type f | wc -l"
  [ "$status" -eq 0 ]
  count="${output// /}"
  [ "$count" -eq 50 ] || { echo "Expected 50 fixtures, found $count"; return 1; }
}

# ---------------------------------------------------------------------------
# 6. Fixture filenames match pattern [a-z0-9-]+.json
# ---------------------------------------------------------------------------
@test "fixture filenames match [a-z0-9-]+.json pattern" {
  local bad=()
  for f in "$INPUTS_DIR"/*.json; do
    base="$(basename "$f")"
    if ! [[ "$base" =~ ^[a-z0-9-]+\.json$ ]]; then
      bad+=("$base")
    fi
  done
  if [ "${#bad[@]}" -gt 0 ]; then
    echo "Non-conforming filenames:"
    printf '  %s\n' "${bad[@]}"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 7. Golden key order is: start, end, title, url
# ---------------------------------------------------------------------------
@test "golden files use canonical key order: start end title url" {
  local failures=()
  for f in "$GOLDEN_DIR"/*.ndjson; do
    if ! python3 - "$f" <<'EOF' 2>/dev/null
import json, sys
with open(sys.argv[1]) as fh:
    for lineno, line in enumerate(fh, 1):
        line = line.rstrip('\n')
        if not line:
            continue
        obj = json.loads(line)
        keys = list(obj.keys())
        expected = ["start", "end", "title", "url"]
        if keys != expected:
            raise ValueError(f"line {lineno}: key order {keys} != {expected}")
EOF
    then
      failures+=("$f")
    fi
  done
  if [ "${#failures[@]}" -gt 0 ]; then
    echo "Wrong key order in:"
    printf '  %s\n' "${failures[@]}"
    return 1
  fi
}
