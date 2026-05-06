#!/usr/bin/env bats
# Tests for lib/calendar/applescript.sh — Calendar.app provider.
# Strategy: PATH-shim `osascript` so every code path except the literal Apple
# Events bridge can be exercised on Linux. The lone end-to-end fetch test
# `skip`s when osascript is genuinely missing (i.e. always on Linux).

bats_require_minimum_version 1.5.0

load 'helper'
load 'shim_helper'

setup() {
  jarvis_common_setup
  shim_setup
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/state/profile.sh"
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/state/config.sh"
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/calendar/provider.sh"
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/calendar/applescript.sh"
  # CLI_DIR is what the wrapper uses to locate applescript.scpt; point it at
  # the real source tree.
  export CLI_DIR="${JARVIS_DIR}"
  state_ensure_tree
}

teardown() {
  jarvis_common_teardown
}

# --- registration & static checks -------------------------------------------

@test "applescript registers itself in dispatcher" {
  [[ -n "${_CALENDAR_PROVIDERS[applescript]:-}" ]]
}

@test "applescript.sh shellcheck-clean" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck not installed"
  fi
  run shellcheck "${JARVIS_DIR}/lib/calendar/applescript.sh"
  [ "$status" -eq 0 ]
}

@test "applescript.scpt declares Calendar.app tell + ARGV handler" {
  # Smoke: file is structurally what the wrapper expects (osascript ARGV
  # entry point + Calendar.app block). Catches accidental file truncation.
  local f="${JARVIS_DIR}/lib/calendar/applescript.scpt"
  grep -q 'on run argv' "$f"
  grep -q 'tell application "Calendar"' "$f"
  grep -q 'every event whose start date' "$f"
}

# --- failure-path coverage --------------------------------------------------

@test "missing osascript -> exit 1 with macOS hint" {
  # Strip osascript from PATH (it's not installed on the runner anyway, but
  # be explicit so this test remains valid on a Mac dev machine).
  PATH="$SHIM_DIR" run calendar_applescript_events \
    "2026-05-01T00:00:00Z" "2026-05-02T00:00:00Z" test
  [ "$status" -eq 1 ]
  [[ "$output" == *"osascript"* ]]
  [[ "$output" == *"macOS"* ]]
}

@test "TCC denial (-1743) -> exit 1 with friendly System Settings hint" {
  shim_install osascript 'echo "execution error: Not authorized to send Apple events to Calendar. (-1743)" >&2; exit 1'
  run --separate-stderr calendar_applescript_events \
    "2026-05-01T00:00:00Z" "2026-05-02T00:00:00Z" test
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"Calendar access not authorized"* ]]
  [[ "$stderr" == *"System Settings"* ]]
  [[ "$stderr" == *"Automation"* ]]
}

@test "non-TCC osascript error -> stderr passes through" {
  shim_install osascript 'echo "execution error: Some other failure (-2700)" >&2; exit 1'
  run --separate-stderr calendar_applescript_events \
    "2026-05-01T00:00:00Z" "2026-05-02T00:00:00Z" test
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"Some other failure"* ]]
  [[ "$stderr" != *"System Settings"* ]]
}

# --- happy-path TSV -> NDJSON -----------------------------------------------

@test "TSV with 2 events -> 2 NDJSON rows" {
  shim_install osascript 'printf "2026-05-01T10:00:00\t2026-05-01T10:30:00\tstandup\thttps://meet.google.com/abc\t\n2026-05-01T13:30:00\t2026-05-01T14:00:00\t1:1 with sam\thttps://zoom.us/j/123\t\n"; exit 0'
  run calendar_applescript_events \
    "2026-05-01T00:00:00Z" "2026-05-02T00:00:00Z" test
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 2 ]
  printf '%s\n' "$output" | head -1 \
    | jq -e '.start == "2026-05-01T10:00:00" and .title == "standup" and .url == "https://meet.google.com/abc"' >/dev/null
  printf '%s\n' "$output" | sed -n 2p \
    | jq -e '.title == "1:1 with sam" and .url == "https://zoom.us/j/123"' >/dev/null
}

@test "title with quotes and backslashes is JSON-escaped" {
  shim_install osascript $'printf "2026-05-01T10:00:00\\t2026-05-01T10:30:00\\tSam\'s \\"1:1\\" review with C:\\\\\\\\share\\thttps://example/meet\\t\\n"; exit 0'
  run calendar_applescript_events \
    "2026-05-01T00:00:00Z" "2026-05-02T00:00:00Z" test
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.title == "Sam'\''s \"1:1\" review with C:\\share"' >/dev/null
}

@test "empty osascript stdout -> exit 0 empty NDJSON" {
  shim_install osascript 'exit 0'
  run calendar_applescript_events \
    "2026-05-01T00:00:00Z" "2026-05-02T00:00:00Z" test
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- extract_url_from --------------------------------------------------------

@test "extract_url_from default ('url') ignores location even when url is empty" {
  printf '[calendar]\nprovider = "applescript"\n' > "$JARVIS_HOME/test/config.toml"
  shim_install osascript 'printf "2026-05-01T10:00:00\t2026-05-01T10:30:00\tplanning\t\thttps://zoom.us/j/in-location\n"; exit 0'
  run calendar_applescript_events \
    "2026-05-01T00:00:00Z" "2026-05-02T00:00:00Z" test
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.url == ""' >/dev/null
}

@test "extract_url_from='url,location' falls back to location when url empty" {
  printf '[calendar]\nprovider = "applescript"\n[calendar.applescript]\nextract_url_from = "url,location"\n' \
    > "$JARVIS_HOME/test/config.toml"
  shim_install osascript 'printf "2026-05-01T10:00:00\t2026-05-01T10:30:00\tplanning\t\thttps://zoom.us/j/in-location\n"; exit 0'
  run calendar_applescript_events \
    "2026-05-01T00:00:00Z" "2026-05-02T00:00:00Z" test
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.url == "https://zoom.us/j/in-location"' >/dev/null
}

@test "extract_url_from='url,location' prefers url when both set" {
  printf '[calendar]\nprovider = "applescript"\n[calendar.applescript]\nextract_url_from = "url,location"\n' \
    > "$JARVIS_HOME/test/config.toml"
  shim_install osascript 'printf "2026-05-01T10:00:00\t2026-05-01T10:30:00\tplanning\thttps://meet.google.com/wins\thttps://zoom.us/loses\n"; exit 0'
  run calendar_applescript_events \
    "2026-05-01T00:00:00Z" "2026-05-02T00:00:00Z" test
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.url == "https://meet.google.com/wins"' >/dev/null
}

# --- calendar filter --------------------------------------------------------

@test "calendars array passed to osascript as comma-list ARGV[3]" {
  printf '[calendar]\nprovider = "applescript"\n[calendar.applescript]\ncalendars = ["Work", "Personal"]\n' \
    > "$JARVIS_HOME/test/config.toml"
  # Shim records ARGV to a log file we can inspect.
  shim_install osascript 'printf "argv: %s\n" "$*" >> "$0.log"; exit 0'
  run calendar_applescript_events \
    "2026-05-01T00:00:00Z" "2026-05-02T00:00:00Z" test
  [ "$status" -eq 0 ]
  local log
  log="$(shim_log_path osascript)"
  [ -f "$log" ]
  grep -q 'Work,Personal' "$log"
}

@test "absent calendars config -> empty filter ARGV (Z stripped, local-naive)" {
  printf '[calendar]\nprovider = "applescript"\n' > "$JARVIS_HOME/test/config.toml"
  # osascript invocation shape: `osascript SCPT SINCE UNTIL CALFILTER`
  # so the shim sees: $1=scpt $2=since $3=until $4=calfilter.
  # SINCE/UNTIL are converted from UTC-Z to local-naive before osascript sees them.
  shim_install osascript 'printf "argv: [%s][%s][%s][%s]\n" "$1" "$2" "$3" "$4" >> "$0.log"; exit 0'
  TZ=UTC run calendar_applescript_events \
    "2026-05-01T00:00:00Z" "2026-05-02T00:00:00Z" test
  [ "$status" -eq 0 ]
  local log
  log="$(shim_log_path osascript)"
  grep -qE 'argv: \[[^]]*applescript\.scpt\]\[2026-05-01T00:00:00\]\[2026-05-02T00:00:00\]\[\]' "$log"
}

# --- TZ conversion ----------------------------------------------------------

@test "non-UTC TZ shifts UTC-Z window to local wall-clock before osascript" {
  printf '[calendar]\nprovider = "applescript"\n' > "$JARVIS_HOME/test/config.toml"
  shim_install osascript 'printf "argv: [%s][%s][%s][%s]\n" "$1" "$2" "$3" "$4" >> "$0.log"; exit 0'
  # America/New_York is UTC-4 in May (EDT), so 2026-05-01T00:00:00Z is
  # 2026-04-30T20:00:00 EDT. The reviewer flagged this drift as Important #1
  # in the AppleScript provider review (2026-05-04). This test pins the fix.
  TZ='America/New_York' run calendar_applescript_events \
    "2026-05-01T00:00:00Z" "2026-05-02T00:00:00Z" test
  [ "$status" -eq 0 ]
  local log
  log="$(shim_log_path osascript)"
  grep -qE 'argv: \[[^]]*applescript\.scpt\]\[2026-04-30T20:00:00\]\[2026-05-01T20:00:00\]\[\]' "$log"
}

# --- AS-S4 — calendars filter parse failure warning -------------------------

@test "AS-S4: calendars set but dasel returns empty -> stderr warn" {
  printf '[calendar]\nprovider = "applescript"\n[calendar.applescript]\ncalendars = ["Work"]\n' \
    > "$JARVIS_HOME/test/config.toml"
  # Shim dasel to produce no output, simulating either dasel-missing or a
  # parse failure on a key the user clearly intended to set.
  shim_install dasel 'exit 0'
  shim_install osascript 'exit 0'
  run --separate-stderr calendar_applescript_events \
    "2026-05-01T00:00:00Z" "2026-05-02T00:00:00Z" test
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"calendars"* ]]
  [[ "$stderr" == *"showing all calendars"* ]]
}

@test "AS-S4: warning is one-shot per process across repeat calls" {
  printf '[calendar]\nprovider = "applescript"\n[calendar.applescript]\ncalendars = ["Work"]\n' \
    > "$JARVIS_HOME/test/config.toml"
  shim_install dasel 'exit 0'
  shim_install osascript 'exit 0'
  local stderr_acc n
  stderr_acc="$(
    { calendar_applescript_events "2026-05-01T00:00:00Z" "2026-05-02T00:00:00Z" test
      calendar_applescript_events "2026-05-01T00:00:00Z" "2026-05-02T00:00:00Z" test
    } 2>&1 1>/dev/null
  )"
  n="$(printf '%s\n' "$stderr_acc" | grep -c 'showing all calendars' || true)"
  [ "$n" -eq 1 ]
}

@test "AS-S4: no warning when calendars key absent from config" {
  printf '[calendar]\nprovider = "applescript"\n' > "$JARVIS_HOME/test/config.toml"
  shim_install dasel 'exit 0'
  shim_install osascript 'exit 0'
  run --separate-stderr calendar_applescript_events \
    "2026-05-01T00:00:00Z" "2026-05-02T00:00:00Z" test
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"showing all calendars"* ]]
}

@test "AS-S4: no warning when dasel parses the array successfully" {
  printf '[calendar]\nprovider = "applescript"\n[calendar.applescript]\ncalendars = ["Work"]\n' \
    > "$JARVIS_HOME/test/config.toml"
  shim_install osascript 'exit 0'   # real dasel + jq parse the array
  run --separate-stderr calendar_applescript_events \
    "2026-05-01T00:00:00Z" "2026-05-02T00:00:00Z" test
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"showing all calendars"* ]]
}

# --- AS-S5 — unknown extract_url_from token warning -------------------------

@test "AS-S5: unknown extract_url_from token -> stderr warn" {
  printf '[calendar]\nprovider = "applescript"\n[calendar.applescript]\nextract_url_from = "url,locaton"\n' \
    > "$JARVIS_HOME/test/config.toml"
  shim_install osascript 'printf "2026-05-01T10:00:00\t2026-05-01T10:30:00\tplanning\thttps://meet/x\thttps://zoom/y\n"; exit 0'
  run --separate-stderr calendar_applescript_events \
    "2026-05-01T00:00:00Z" "2026-05-02T00:00:00Z" test
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"locaton"* ]]
  [[ "$stderr" == *"not recognized"* ]]
}

@test "AS-S5: known tokens only -> no warn" {
  printf '[calendar]\nprovider = "applescript"\n[calendar.applescript]\nextract_url_from = "url,location"\n' \
    > "$JARVIS_HOME/test/config.toml"
  shim_install osascript 'printf "2026-05-01T10:00:00\t2026-05-01T10:30:00\tplanning\thttps://meet/x\t\n"; exit 0'
  run --separate-stderr calendar_applescript_events \
    "2026-05-01T00:00:00Z" "2026-05-02T00:00:00Z" test
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"not recognized"* ]]
}

@test "AS-S5: same unknown token across repeat calls warns once" {
  printf '[calendar]\nprovider = "applescript"\n[calendar.applescript]\nextract_url_from = "locaton"\n' \
    > "$JARVIS_HOME/test/config.toml"
  shim_install osascript 'printf "2026-05-01T10:00:00\t2026-05-01T10:30:00\tx\thttps://a\thttps://b\n"; exit 0'
  local stderr_acc n
  stderr_acc="$(
    { calendar_applescript_events "2026-05-01T00:00:00Z" "2026-05-02T00:00:00Z" test
      calendar_applescript_events "2026-05-01T00:00:00Z" "2026-05-02T00:00:00Z" test
    } 2>&1 1>/dev/null
  )"
  n="$(printf '%s\n' "$stderr_acc" | grep -c 'locaton' || true)"
  [ "$n" -eq 1 ]
}

# --- end-to-end (Mac only) --------------------------------------------------

@test "end-to-end: osascript fetches against Calendar.app (Mac only)" {
  if ! command -v osascript >/dev/null 2>&1; then
    skip "osascript not available — Mac-only path; see .claude/smoke/mac-calendar.md"
  fi
  # On a Mac, this exercises the full bridge. Without a deterministic
  # fixture calendar we only assert structural shape: exit code is one of
  # {0 = events fetched, 1 = TCC denied} and stderr/stdout obey the contract.
  run calendar_applescript_events \
    "$(date -u +%Y-%m-%dT00:00:00Z)" \
    "$(date -u -v+1d +%Y-%m-%dT00:00:00Z 2>/dev/null \
       || date -u -d 'tomorrow' +%Y-%m-%dT00:00:00Z)" \
    test
  [[ "$status" -eq 0 || "$status" -eq 1 ]]
  if [ "$status" -eq 0 ] && [ -n "$output" ]; then
    # Each non-empty stdout line must be valid JSON with required keys.
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      printf '%s\n' "$line" \
        | jq -e 'has("start") and has("end") and has("title") and has("url")' >/dev/null
    done <<<"$output"
  fi
}
