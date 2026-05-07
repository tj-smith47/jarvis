#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

load 'helper'
load 'shim_helper'

setup() {
  jarvis_common_setup
  shim_setup
  cp -R "${BATS_TEST_DIRNAME}/fixtures/status-profile" "$JARVIS_HOME/test"
  export JARVIS_FAKE_NOW="2026-05-01T15:00:00Z"
}
teardown() { jarvis_common_teardown; }

@test "status --json matches golden fixture (canonical key order)" {
  run bash "${JARVIS_DIR}/cmds/status/status.sh" --json --profile test
  [ "$status" -eq 0 ]
  diff <(printf '%s\n' "$output" | jq -S .) \
       <(jq -S . "${BATS_TEST_DIRNAME}/golden/status.json")
}

@test "status --yaml emits same shape" {
  run bash "${JARVIS_DIR}/cmds/status/status.sh" --yaml --profile test
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q "open: 2"
  printf '%s\n' "$output" | grep -q "minutes_today: 75"
}

@test "status (default pretty) shows real counts" {
  run bash "${JARVIS_DIR}/cmds/status/status.sh" --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"open"* ]]
  [[ "$output" == *"75 min"* ]]
}

@test "status --json with no reminders" {
  rm -rf "$JARVIS_HOME/test/reminders"
  mkdir -p "$JARVIS_HOME/test/reminders"
  run bash "${JARVIS_DIR}/cmds/status/status.sh" --json --profile test
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.reminders.scheduled == 0 and .reminders.next_in_minutes == null' > /dev/null
}

@test "status pretty surfaces tasks list under header line" {
  run bash "${JARVIS_DIR}/cmds/status/status.sh" --profile test
  [ "$status" -eq 0 ]
  # Header line: "Tasks  N open · M done today" (substring)
  [[ "$output" == *"Tasks"*"open"*"done today"* ]]
  # Top-3 list lines under it (titles from the fixture)
  [[ "$output" == *"write spec"* ]]
  [[ "$output" == *"buy milk"* ]]
}

@test "status pretty: Reminders section lists upcoming when any are scheduled" {
  run bash "${JARVIS_DIR}/cmds/status/status.sh" --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"Reminders"*"scheduled"*"next in"* ]]
  # Two upcoming in the fixture: standup (2026-05-01T15:42), oncall-handoff (2026-05-02T17:00)
  [[ "$output" == *"15:42"*"stand up"* ]]
}

@test "status pretty: Next-meeting line when calendar has an upcoming event" {
  cat > "$JARVIS_HOME/test/cal.ics" <<'ICS'
BEGIN:VCALENDAR
BEGIN:VEVENT
DTSTART:20260501T160000Z
DTEND:20260501T163000Z
SUMMARY:1:1 with manager
URL:https://meet.google.com/team-sync
END:VEVENT
END:VCALENDAR
ICS
  cat >> "$JARVIS_HOME/test/config.toml" <<EOF

[calendar]
provider = "ics"

[calendar.ics]
source = "$JARVIS_HOME/test/cal.ics"
EOF
  run bash "${JARVIS_DIR}/cmds/status/status.sh" --profile test
  [ "$status" -eq 0 ]
  # JARVIS_FAKE_NOW=15:00 → 16:00 event is "in 60m"
  [[ "$output" == *"Next meeting"*"60m"*"1:1 with manager"*"https://meet.google.com/team-sync"* ]]
}

@test "status pretty: Focus surfaces in-progress session when an unpaired start exists" {
  cat >> "$JARVIS_HOME/test/focus.log" <<EOF
{"ts":"2026-05-01T14:30:00Z","event":"start","topic":"jarvis-audit"}
EOF
  run bash "${JARVIS_DIR}/cmds/status/status.sh" --profile test
  [ "$status" -eq 0 ]
  # 14:30 start, fake-now 15:00 → 30 min in progress on jarvis-audit
  [[ "$output" == *"Focus"*"in progress: 30m"*"jarvis-audit"* ]]
}

@test "status pretty: Notes section shows daily-today + touched count" {
  mkdir -p "$JARVIS_HOME/test/notes/daily"
  cat > "$JARVIS_HOME/test/notes/index.json" <<EOF
{"version":1,"notes":[
  {"path":"notes/daily/2026-05-01.md","kind":"daily","title":"daily 2026-05-01",
   "tags":[],"updated_at":"2026-05-01T08:00:00Z","archived":false},
  {"path":"notes/inbox/recent.md","kind":"inbox","title":"recent",
   "tags":[],"updated_at":"2026-04-29T10:00:00Z","archived":false},
  {"path":"notes/inbox/old.md","kind":"inbox","title":"old",
   "tags":[],"updated_at":"2026-04-01T10:00:00Z","archived":false}
]}
EOF
  run bash "${JARVIS_DIR}/cmds/status/status.sh" --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"Notes"*"daily: 2026-05-01"*"2 touched this week"* ]]
}
