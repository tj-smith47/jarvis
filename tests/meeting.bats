#!/usr/bin/env bats
# meeting cmd: `jarvis meeting join` opens the next meeting URL,
# `jarvis meeting next` peeks at the next event with countdown.
#
# Calendar source for these tests is the ICS provider — point its source
# at a local file so the live HTTP fetch never fires.

bats_require_minimum_version 1.5.0

load 'helper'
load 'shim_helper'

setup() {
  jarvis_common_setup
  shim_setup
  mkdir -p "$JARVIS_HOME/test"
  printf '1\n' > "$JARVIS_HOME/test/state.version"
  # Pin "now" so the search windows are deterministic. Calendar event below
  # starts at 14:00, so 13:00 puts us 60min before it.
  export JARVIS_FAKE_NOW="2026-05-01T13:00:00Z"

  cat > "$JARVIS_HOME/test/cal.ics" <<'ICS'
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//jarvis//meeting test//EN
BEGIN:VEVENT
UID:1@test
DTSTART:20260501T140000Z
DTEND:20260501T150000Z
SUMMARY:standup
URL:https://zoom.us/j/standup-zoom
END:VEVENT
BEGIN:VEVENT
UID:2@test
DTSTART:20260501T160000Z
DTEND:20260501T170000Z
SUMMARY:1:1 with bob
LOCATION:https://meet.google.com/abc-defg-hij
END:VEVENT
BEGIN:VEVENT
UID:3@test
DTSTART:20260501T180000Z
DTEND:20260501T190000Z
SUMMARY:no-link meeting
END:VEVENT
END:VCALENDAR
ICS
  cat > "$JARVIS_HOME/test/config.toml" <<EOF
[calendar]
provider = "ics"
[calendar.ics]
source = "$JARVIS_HOME/test/cal.ics"
EOF
}

teardown() { jarvis_common_teardown; }

# Capture the URL `meeting join` would open by stubbing both `open` and
# `xdg-open`. The stubs print the URL to stdout so `run` can assert on it
# without actually launching a browser.
_install_open_stub() {
  shim_install open    'printf "OPENED %s\n" "$1"'
  shim_install xdg-open 'printf "OPENED %s\n" "$1"'
}

@test "meeting next: emits next event with title + URL + countdown" {
  run bash "${JARVIS_DIR}/cmds/meeting/meeting.next.sh" --profile test
  [ "$status" -eq 0 ]
  # 14:00 event starting in 60 minutes from fake-now (13:00).
  [[ "$output" == *"14:00"* ]]
  [[ "$output" == *"standup"* ]]
  [[ "$output" == *"in 1h"* ]]
  [[ "$output" == *"https://zoom.us/j/standup-zoom"* ]]
}

@test "meeting next --json emits structured shape" {
  run bash "${JARVIS_DIR}/cmds/meeting/meeting.next.sh" --json --profile test
  [ "$status" -eq 0 ]
  [ "$(jq -r '.title' <<< "$output")" = "standup" ]
  [ "$(jq -r '.url' <<< "$output")" = "https://zoom.us/j/standup-zoom" ]
  [ "$(jq -r '.in_minutes' <<< "$output")" = "60" ]
  [ "$(jq -r '.in_str' <<< "$output")" = "1h" ]
}

@test "meeting next: window with no events exits 1" {
  # 1m window from 13:00 includes nothing (first event is at 14:00).
  run bash "${JARVIS_DIR}/cmds/meeting/meeting.next.sh" --in 1m --profile test
  [ "$status" -eq 1 ]
  [[ "$output" == *"no upcoming meeting"* ]]
}

@test "meeting next: window with no events --json emits {}" {
  run bash "${JARVIS_DIR}/cmds/meeting/meeting.next.sh" --in 1m --json --profile test
  [ "$status" -eq 1 ]
  [ "$output" = "{}" ]
}

@test "meeting next: invalid --in exits 2" {
  run bash "${JARVIS_DIR}/cmds/meeting/meeting.next.sh" --in 5x --profile test
  [ "$status" -eq 2 ]
}

@test "meeting join: opens next event's .url field" {
  _install_open_stub
  # Default window is 15m; the standup event is 1h ahead so widen to 2h.
  run bash "${JARVIS_DIR}/cmds/meeting/meeting.join.sh" --in 2h --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"OPENED https://zoom.us/j/standup-zoom"* ]]
}

@test "meeting join --filter narrows by title regex (case-insensitive)" {
  _install_open_stub
  # Window has to be wide enough to reach the 16:00 event (3h ahead).
  run bash "${JARVIS_DIR}/cmds/meeting/meeting.join.sh" \
    --in 4h --filter '1:1' --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"OPENED https://meet.google.com/abc-defg-hij"* ]]
}

@test "meeting join --meeting URL bypasses calendar" {
  _install_open_stub
  run bash "${JARVIS_DIR}/cmds/meeting/meeting.join.sh" \
    --meeting "https://zoom.us/j/explicit-12345" --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"OPENED https://zoom.us/j/explicit-12345"* ]]
}

@test "meeting join: extracts URL from .location when .url empty" {
  _install_open_stub
  # The 1:1 event has empty .url + meet URL in location. Filter to it.
  run bash "${JARVIS_DIR}/cmds/meeting/meeting.join.sh" \
    --in 4h --filter 'bob' --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"OPENED https://meet.google.com/abc-defg-hij"* ]]
}

@test "meeting join: event with no extractable URL exits 1 with hint" {
  _install_open_stub
  run --separate-stderr bash "${JARVIS_DIR}/cmds/meeting/meeting.join.sh" \
    --in 6h --filter 'no-link' --profile test
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"no joinable URL"* ]] || [[ "$output" == *"no joinable URL"* ]]
}

@test "meeting join: --filter with no match exits 1" {
  _install_open_stub
  run --separate-stderr bash "${JARVIS_DIR}/cmds/meeting/meeting.join.sh" \
    --in 4h --filter 'never-matches' --profile test
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"no events match"* ]] || [[ "$output" == *"no events match"* ]]
}

@test "meeting join: empty calendar window exits 1" {
  _install_open_stub
  run --separate-stderr bash "${JARVIS_DIR}/cmds/meeting/meeting.join.sh" \
    --in 1m --profile test
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"no events in next"* ]] || [[ "$output" == *"no events in next"* ]]
}

@test "meeting join: invalid --in exits 2" {
  run bash "${JARVIS_DIR}/cmds/meeting/meeting.join.sh" --in 5x --profile test
  [ "$status" -eq 2 ]
}
