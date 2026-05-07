#!/usr/bin/env bats
# Tests for lib/calendar/ics.sh — VEVENT block parsing,
# [since,until) window filter, file + URL sources, JSON escaping.

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
  source "${JARVIS_DIR}/lib/calendar/ics.sh"
  state_ensure_tree
}

teardown() {
  jarvis_common_teardown
}

@test "ics registers itself + outlook-ics alias" {
  [[ -n "${_CALENDAR_PROVIDERS[ics]:-}" ]]
  [[ -n "${_CALENDAR_PROVIDERS[outlook-ics]:-}" ]]
}

@test "missing [calendar.ics] source -> exit 1" {
  printf '[calendar]\nprovider = "ics"\n' > "$JARVIS_HOME/test/config.toml"
  run calendar_ics_events "2026-05-01T00:00:00Z" "2026-05-02T00:00:00Z" test
  [ "$status" -eq 1 ]
}

@test "ics file path -> 2 events in window" {
  cp "${BATS_TEST_DIRNAME}/fixtures/calendar.ics" "$JARVIS_HOME/test/cal.ics"
  printf '[calendar]\nprovider = "ics"\n[calendar.ics]\nsource = "%s"\n' \
    "$JARVIS_HOME/test/cal.ics" > "$JARVIS_HOME/test/config.toml"
  run calendar_ics_events "2026-05-01T00:00:00Z" "2026-05-02T00:00:00Z" test
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 2 ]
  printf '%s\n' "$output" | head -1 | jq -e '.title == "standup" and .url == "https://zoom.us/j/123"' > /dev/null
}

@test "ics URL -> fetched via curl shim" {
  cp "${BATS_TEST_DIRNAME}/fixtures/calendar.ics" "$SHIM_DIR/feed.ics"
  shim_install curl 'cat "'"$SHIM_DIR"'/feed.ics"; exit 0'
  printf '[calendar]\nprovider = "ics"\n[calendar.ics]\nsource = "https://example.com/feed.ics"\n' \
    > "$JARVIS_HOME/test/config.toml"
  run calendar_ics_events "2026-05-01T00:00:00Z" "2026-05-02T00:00:00Z" test
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 2 ]
}

@test "events outside window are filtered out" {
  cp "${BATS_TEST_DIRNAME}/fixtures/calendar.ics" "$JARVIS_HOME/test/cal.ics"
  printf '[calendar]\nprovider = "ics"\n[calendar.ics]\nsource = "%s"\n' \
    "$JARVIS_HOME/test/cal.ics" > "$JARVIS_HOME/test/config.toml"
  run calendar_ics_events "2026-04-01T00:00:00Z" "2026-04-02T00:00:00Z" test
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
  printf '%s\n' "$output" | jq -e '.title == "past event"' > /dev/null
}

@test "URL with parameters (URL;VALUE=URI:) parsed correctly" {
  cat > "$JARVIS_HOME/test/cal.ics" <<'EOF'
BEGIN:VCALENDAR
BEGIN:VEVENT
DTSTART:20260501T100000Z
DTEND:20260501T103000Z
SUMMARY:meeting
URL;VALUE=URI:https://example.com/meet
END:VEVENT
END:VCALENDAR
EOF
  printf '[calendar]\nprovider = "ics"\n[calendar.ics]\nsource = "%s"\n' \
    "$JARVIS_HOME/test/cal.ics" > "$JARVIS_HOME/test/config.toml"
  run calendar_ics_events "2026-05-01T00:00:00Z" "2026-05-02T00:00:00Z" test
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.url == "https://example.com/meet"' > /dev/null
}

@test "URLISH: prefix does not match /^URL/" {
  cat > "$JARVIS_HOME/test/cal.ics" <<'EOF'
BEGIN:VCALENDAR
BEGIN:VEVENT
DTSTART:20260501T100000Z
DTEND:20260501T103000Z
SUMMARY:meeting
URLISH:not-the-url
URL:https://real.example/meet
END:VEVENT
END:VCALENDAR
EOF
  printf '[calendar]\nprovider = "ics"\n[calendar.ics]\nsource = "%s"\n' \
    "$JARVIS_HOME/test/cal.ics" > "$JARVIS_HOME/test/config.toml"
  run calendar_ics_events "2026-05-01T00:00:00Z" "2026-05-02T00:00:00Z" test
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.url == "https://real.example/meet"' > /dev/null
}

@test "TZID local-time DTSTART skipped with stderr warning" {
  cat > "$JARVIS_HOME/test/cal.ics" <<'EOF'
BEGIN:VCALENDAR
BEGIN:VEVENT
DTSTART;TZID=America/New_York:20260501T100000
DTEND;TZID=America/New_York:20260501T103000
SUMMARY:local time event
URL:https://example/meet
END:VEVENT
BEGIN:VEVENT
DTSTART:20260501T140000Z
DTEND:20260501T143000Z
SUMMARY:utc event
URL:https://example/utc
END:VEVENT
END:VCALENDAR
EOF
  printf '[calendar]\nprovider = "ics"\n[calendar.ics]\nsource = "%s"\n' \
    "$JARVIS_HOME/test/cal.ics" > "$JARVIS_HOME/test/config.toml"
  run --separate-stderr calendar_ics_events "2026-05-01T00:00:00Z" "2026-05-02T00:00:00Z" test
  [ "$status" -eq 0 ]
  # Only UTC event emitted on stdout
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
  printf '%s\n' "$output" | jq -e '.title == "utc event"' > /dev/null
  [[ "$stderr" == *"non-UTC DTSTART"* ]]
}

@test "folded SUMMARY line is unfolded (RFC 5545)" {
  # RFC 5545 §3.1: lines >75 octets are folded with CRLF + (SP|HTAB).
  # Continuation char is dropped; if a space is wanted at the join, the
  # original line keeps its trailing space (here "title " + "that..."),
  # so the unfolded result preserves the natural word boundary.
  printf 'BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20260501T100000Z\r\nDTEND:20260501T103000Z\r\nSUMMARY:long title \r\n that continues here\r\nURL:https://example/meet\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n' \
    > "$JARVIS_HOME/test/cal.ics"
  printf '[calendar]\nprovider = "ics"\n[calendar.ics]\nsource = "%s"\n' \
    "$JARVIS_HOME/test/cal.ics" > "$JARVIS_HOME/test/config.toml"
  run calendar_ics_events "2026-05-01T00:00:00Z" "2026-05-02T00:00:00Z" test
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.title == "long title that continues here"' > /dev/null
}

@test "ics title with quotes is JSON-escaped" {
  cat > "$JARVIS_HOME/test/cal.ics" <<'EOF'
BEGIN:VCALENDAR
BEGIN:VEVENT
DTSTART:20260501T100000Z
DTEND:20260501T103000Z
SUMMARY:Sam's "1:1" review
URL:https://example/meet
END:VEVENT
END:VCALENDAR
EOF
  printf '[calendar]\nprovider = "ics"\n[calendar.ics]\nsource = "%s"\n' \
    "$JARVIS_HOME/test/cal.ics" > "$JARVIS_HOME/test/config.toml"
  run calendar_ics_events "2026-05-01T00:00:00Z" "2026-05-02T00:00:00Z" test
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.title == "Sam'\''s \"1:1\" review"' > /dev/null
}

@test "STATUS:CANCELLED events are dropped" {
  cat > "$JARVIS_HOME/test/cal.ics" <<'EOF'
BEGIN:VCALENDAR
BEGIN:VEVENT
DTSTART:20260501T100000Z
DTEND:20260501T103000Z
SUMMARY:cancelled meeting
URL:https://example/cancel
STATUS:CANCELLED
END:VEVENT
BEGIN:VEVENT
DTSTART:20260501T140000Z
DTEND:20260501T143000Z
SUMMARY:live meeting
URL:https://example/live
STATUS:CONFIRMED
END:VEVENT
END:VCALENDAR
EOF
  printf '[calendar]\nprovider = "ics"\n[calendar.ics]\nsource = "%s"\n' \
    "$JARVIS_HOME/test/cal.ics" > "$JARVIS_HOME/test/config.toml"
  run calendar_ics_events "2026-05-01T00:00:00Z" "2026-05-02T00:00:00Z" test
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
  printf '%s\n' "$output" | jq -e '.title == "live meeting"' > /dev/null
}

@test "URL absent → falls back to meeting_url_extract on LOCATION" {
  cat > "$JARVIS_HOME/test/cal.ics" <<'EOF'
BEGIN:VCALENDAR
BEGIN:VEVENT
DTSTART:20260501T100000Z
DTEND:20260501T103000Z
SUMMARY:planning sync
LOCATION:Zoom: https://zoom.us/j/9876543210?pwd=xyz
END:VEVENT
END:VCALENDAR
EOF
  printf '[calendar]\nprovider = "ics"\n[calendar.ics]\nsource = "%s"\n' \
    "$JARVIS_HOME/test/cal.ics" > "$JARVIS_HOME/test/config.toml"
  run calendar_ics_events "2026-05-01T00:00:00Z" "2026-05-02T00:00:00Z" test
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.url == "https://zoom.us/j/9876543210?pwd=xyz"' > /dev/null
}

@test "URL absent and LOCATION has no link → falls back to DESCRIPTION" {
  cat > "$JARVIS_HOME/test/cal.ics" <<'EOF'
BEGIN:VCALENDAR
BEGIN:VEVENT
DTSTART:20260501T100000Z
DTEND:20260501T103000Z
SUMMARY:1on1
LOCATION:Conf Room A
DESCRIPTION:Join here: https://meet.google.com/abc-defg-hij  Agenda: ...
END:VEVENT
END:VCALENDAR
EOF
  printf '[calendar]\nprovider = "ics"\n[calendar.ics]\nsource = "%s"\n' \
    "$JARVIS_HOME/test/cal.ics" > "$JARVIS_HOME/test/config.toml"
  run calendar_ics_events "2026-05-01T00:00:00Z" "2026-05-02T00:00:00Z" test
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.url == "https://meet.google.com/abc-defg-hij"' > /dev/null
}

@test "explicit URL: field wins over LOCATION/DESCRIPTION fallback" {
  cat > "$JARVIS_HOME/test/cal.ics" <<'EOF'
BEGIN:VCALENDAR
BEGIN:VEVENT
DTSTART:20260501T100000Z
DTEND:20260501T103000Z
SUMMARY:overlap
URL:https://canonical.example/meet
LOCATION:also https://zoom.us/j/000
DESCRIPTION:also https://meet.google.com/zzz-zzz-zzz
END:VEVENT
END:VCALENDAR
EOF
  printf '[calendar]\nprovider = "ics"\n[calendar.ics]\nsource = "%s"\n' \
    "$JARVIS_HOME/test/cal.ics" > "$JARVIS_HOME/test/config.toml"
  run calendar_ics_events "2026-05-01T00:00:00Z" "2026-05-02T00:00:00Z" test
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.url == "https://canonical.example/meet"' > /dev/null
}
