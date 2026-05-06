#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

load helper

# jarvis_cal.bats — coverage for the jarvis-cal Rust helper:
#   * --protocol-version
#   * events --format gcalcli (TSV -> NDJSON)
#   * events --format ics (RFC 5545 -> NDJSON)
#   * emit-fixtures-for-parity (cross-encoder NDJSON parity gate)
#   * window filtering + error paths

CAL=
GOLDEN_DIR=
INPUTS_DIR=

setup() {
  # Resolve paths and (if needed) build the binary BEFORE HOME redirect —
  # cargo/rustup rely on $HOME/.rustup which jarvis_common_setup hides.
  JARVIS_DIR="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  CAL="$JARVIS_DIR/bin/jarvis-cal"
  GOLDEN_DIR="$JARVIS_DIR/tests/fixtures/ndjson-parity/golden"
  INPUTS_DIR="$JARVIS_DIR/tests/fixtures/ndjson-parity/inputs"
  if [[ ! -x "$CAL" ]]; then
    bash "$JARVIS_DIR/scripts/build_cal.sh"
  fi
  jarvis_common_setup
}

teardown() {
  jarvis_common_teardown
}

# ---------- Protocol --------------------------------------------------------

@test "jarvis-cal --protocol-version prints 1" {
  run "$CAL" --protocol-version
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "jarvis-cal with no args prints usage and exits 2" {
  run "$CAL"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage"* ]]
}

@test "jarvis-cal events with bad --since exits 2" {
  run bash -c "echo '' | '$CAL' events --format ics --since not-a-date --until 2026-04-29T00:00:00Z"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--since"* ]]
}

@test "jarvis-cal events with --since >= --until exits 2" {
  run bash -c "echo '' | '$CAL' events --format ics --since 2026-04-29T00:00:00Z --until 2026-04-28T00:00:00Z"
  [ "$status" -eq 2 ]
}

# ---------- gcalcli format --------------------------------------------------

@test "gcalcli: single basic row maps to one NDJSON event" {
  run bash -c "
    printf '2026-04-28\t14:00\t2026-04-28\t15:00\thttps://meet.example/abc\tStandup\n' \
      | '$CAL' events --format gcalcli --since 2026-04-28T00:00:00Z --until 2026-04-29T00:00:00Z
  "
  [ "$status" -eq 0 ]
  [ "$output" = '{"start":"2026-04-28T14:00:00","end":"2026-04-28T15:00:00","title":"Standup","url":"https://meet.example/abc"}' ]
}

@test "gcalcli: short rows are skipped" {
  run bash -c "
    printf 'incomplete\trow\n2026-04-28\t14:00\t2026-04-28\t15:00\tu\tT\n' \
      | '$CAL' events --format gcalcli --since 2026-04-28T00:00:00Z --until 2026-04-29T00:00:00Z
  "
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
}

@test "gcalcli: window filters out events outside [since, until)" {
  run bash -c "
    printf '2026-04-27\t10:00\t2026-04-27\t11:00\tu\tBefore\n2026-04-28\t14:00\t2026-04-28\t15:00\tu\tInside\n2026-04-30\t09:00\t2026-04-30\t10:00\tu\tAfter\n' \
      | '$CAL' events --format gcalcli --since 2026-04-28T00:00:00Z --until 2026-04-29T00:00:00Z
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"title":"Inside"'* ]]
  [[ "$output" != *"Before"* ]]
  [[ "$output" != *"After"* ]]
}

@test "gcalcli: NDJSON title is escaped through serde_json default" {
  # Embed a literal backslash + double-quote in the title; NDJSON must escape both.
  local tsv="$BATS_TEST_TMPDIR/escape.tsv"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    '2026-04-28' '14:00' '2026-04-28' '15:00' 'u' 'He said "hi" \' \
    > "$tsv"
  run bash -c "'$CAL' events --format gcalcli --since 2026-04-28T00:00:00Z --until 2026-04-29T00:00:00Z < '$tsv'"
  [ "$status" -eq 0 ]
  # `"` in title -> `\"`; literal `\` -> `\\` (two backslashes in NDJSON).
  # Use grep -F to escape the bash-pattern-vs-content backslash-quoting hazard.
  printf '%s' "$output" | grep -qF 'He said \"hi\" \\' || {
    echo "expected escaped title; got: $output"; return 1;
  }
}

# ---------- ICS format ------------------------------------------------------

@test "ics: basic UTC VEVENT emits one NDJSON event" {
  run bash -c "
    printf 'BEGIN:VEVENT\r\nDTSTART:20260428T140000Z\r\nDTEND:20260428T150000Z\r\nSUMMARY:Standup\r\nURL:https://meet.example/abc\r\nEND:VEVENT\r\n' \
      | '$CAL' events --format ics --since 2026-04-28T00:00:00Z --until 2026-04-29T00:00:00Z
  "
  [ "$status" -eq 0 ]
  [ "$output" = '{"start":"2026-04-28T14:00:00Z","end":"2026-04-28T15:00:00Z","title":"Standup","url":"https://meet.example/abc"}' ]
}

@test "ics: TZID-local DTSTART is converted to UTC (drains T4-W2)" {
  # 14:00 PDT (UTC-7) on 2026-04-28 = 21:00 UTC.
  run bash -c "
    printf 'BEGIN:VEVENT\nDTSTART;TZID=America/Los_Angeles:20260428T140000\nDTEND;TZID=America/Los_Angeles:20260428T150000\nSUMMARY:LA meeting\nEND:VEVENT\n' \
      | '$CAL' events --format ics --since 2026-04-28T00:00:00Z --until 2026-04-29T00:00:00Z
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"start":"2026-04-28T21:00:00Z"'* ]]
  [[ "$output" == *'"end":"2026-04-28T22:00:00Z"'* ]]
}

@test "ics: naked-local DTSTART (no TZID, no Z) is skipped with stderr warning" {
  run bash -c "
    printf 'BEGIN:VEVENT\nDTSTART:20260428T140000\nSUMMARY:floating\nEND:VEVENT\n' \
      | '$CAL' events --format ics --since 2026-04-28T00:00:00Z --until 2026-04-29T00:00:00Z 2>&1
  "
  [ "$status" -eq 0 ]
  # No NDJSON event in stdout (warning went to stderr but is captured here).
  [[ "$output" == *"non-UTC"* ]]
  [[ "$output" != *'"start":'* ]]
}

@test "ics: VALUE=DATE all-day event becomes midnight UTC" {
  run bash -c "
    printf 'BEGIN:VEVENT\nDTSTART;VALUE=DATE:20260428\nSUMMARY:Holiday\nEND:VEVENT\n' \
      | '$CAL' events --format ics --since 2026-04-28T00:00:00Z --until 2026-04-29T00:00:00Z
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"start":"2026-04-28T00:00:00Z"'* ]]
}

@test "ics: continuation lines unfold (RFC 5545 line folding)" {
  run bash -c "
    printf 'BEGIN:VEVENT\nDTSTART:20260428T140000Z\nSUMMARY:Long title that\n  continues here\nEND:VEVENT\n' \
      | '$CAL' events --format ics --since 2026-04-28T00:00:00Z --until 2026-04-29T00:00:00Z
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"title":"Long title that continues here"'* ]]
}

@test "ics: TEXT escapes are decoded in SUMMARY" {
  local ics="$BATS_TEST_TMPDIR/escapes.ics"
  {
    printf 'BEGIN:VEVENT\n'
    printf 'DTSTART:20260428T140000Z\n'
    printf 'SUMMARY:Line1\\nLine2 with \\, comma\n'
    printf 'END:VEVENT\n'
  } > "$ics"
  run bash -c "'$CAL' events --format ics --since 2026-04-28T00:00:00Z --until 2026-04-29T00:00:00Z < '$ics'"
  [ "$status" -eq 0 ]
  # ICS TEXT escape `\n` decodes to a literal newline; serde_json
  # then escapes it back to JSON `\n` (the two-byte backslash+n sequence).
  [[ "$output" == *'\n'* ]]
  [[ "$output" == *'Line2 with , comma'* ]]
}

@test "ics: URL property anchored avoids URLISH false-match" {
  run bash -c "
    printf 'BEGIN:VEVENT\nDTSTART:20260428T140000Z\nSUMMARY:T\nURLISH:not-a-url\nURL:https://real.example\nEND:VEVENT\n' \
      | '$CAL' events --format ics --since 2026-04-28T00:00:00Z --until 2026-04-29T00:00:00Z
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"url":"https://real.example"'* ]]
  [[ "$output" != *"not-a-url"* ]]
}

@test "ics: missing DTEND mirrors DTSTART" {
  run bash -c "
    printf 'BEGIN:VEVENT\nDTSTART:20260428T140000Z\nSUMMARY:NoEnd\nEND:VEVENT\n' \
      | '$CAL' events --format ics --since 2026-04-28T00:00:00Z --until 2026-04-29T00:00:00Z
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"start":"2026-04-28T14:00:00Z"'* ]]
  [[ "$output" == *'"end":"2026-04-28T14:00:00Z"'* ]]
}

@test "ics: multiple VEVENTs each emit a line" {
  run bash -c "
    printf 'BEGIN:VEVENT\nDTSTART:20260428T140000Z\nSUMMARY:A\nEND:VEVENT\nBEGIN:VEVENT\nDTSTART:20260428T160000Z\nSUMMARY:B\nEND:VEVENT\n' \
      | '$CAL' events --format ics --since 2026-04-28T00:00:00Z --until 2026-04-29T00:00:00Z
  "
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 2 ]
}

# ---------- emit-fixtures-for-parity ---------------------------------------

@test "emit-fixtures-for-parity: byte-identical output to Python oracle (50 fixtures)" {
  out_dir="$BATS_TEST_TMPDIR/parity-out"
  run "$CAL" emit-fixtures-for-parity --inputs "$INPUTS_DIR" --output "$out_dir"
  [ "$status" -eq 0 ]
  run diff -r "$GOLDEN_DIR" "$out_dir"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "emit-fixtures-for-parity: missing inputs dir exits 2" {
  run "$CAL" emit-fixtures-for-parity --inputs /nonexistent --output "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 2 ]
}
