#!/usr/bin/env bats
# T13 — standup --join / --meeting wiring.
# --join: scan calendar [now, now+15min); first /standup/i match; URL precedence
#   .url field > meeting_url_extract on title. open|xdg-open with stdout fallback.
# --meeting URL: bypass calendar, open URL directly.
# Always renders the normal Yesterday/Today/Blockers summary afterward.

bats_require_minimum_version 1.5.0

load 'helper'
load 'shim_helper'

setup() {
  jarvis_common_setup
  shim_setup
  cp -R "${BATS_TEST_DIRNAME}/fixtures/status-profile" "$JARVIS_HOME/test"
  cp "${BATS_TEST_DIRNAME}/fixtures/calendar.ics" "$JARVIS_HOME/test/cal.ics"
  cat >> "$JARVIS_HOME/test/config.toml" <<EOF

[calendar]
provider = "ics"
[calendar.ics]
source = "$JARVIS_HOME/test/cal.ics"
EOF
  shim_install open     'echo "open: $1" > "$0.log"; exit 0'
  shim_install xdg-open 'echo "xdg-open: $1" > "$0.log"; exit 0'
  mkdir -p "$JARVIS_HOME/test/notes"
  echo '{"version":1,"notes":[]}' > "$JARVIS_HOME/test/notes/index.json"
  # 10 min before standup at 10:00 — within the 15-min lookahead window.
  export JARVIS_FAKE_NOW="2026-05-01T09:50:00Z"
}

teardown() { jarvis_common_teardown; }

@test "standup --join finds standup event and opens its URL" {
  run bash "${JARVIS_DIR}/cmds/standup/standup.sh" --join --profile test
  [ "$status" -eq 0 ]
  [ -f "$(shim_log_path open)" ]
  grep -q "https://zoom.us/j/123" "$(shim_log_path open)"
  [[ "$output" == *"Yesterday"* ]]
}

@test "standup --meeting URL bypasses calendar" {
  rm -f "$JARVIS_HOME/test/cal.ics"
  run bash "${JARVIS_DIR}/cmds/standup/standup.sh" \
    --meeting "https://meet.google.com/xyz-abcd-efg" --profile test
  [ "$status" -eq 0 ]
  [ -f "$(shim_log_path open)" ]
  grep -q "https://meet.google.com/xyz-abcd-efg" "$(shim_log_path open)"
}

@test "standup --join with no standup event prints note + summary" {
  export JARVIS_FAKE_NOW="2026-05-01T22:00:00Z"
  run bash "${JARVIS_DIR}/cmds/standup/standup.sh" --join --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"no standup event"* ]]
  [ ! -f "$(shim_log_path open)" ]
}

@test "no open/xdg-open available -> URL printed to stdout" {
  rm -f "$SHIM_DIR/open" "$SHIM_DIR/xdg-open"
  run bash "${JARVIS_DIR}/cmds/standup/standup.sh" \
    --meeting "https://zoom.us/j/777" --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://zoom.us/j/777"* ]]
}

# ---- cron-meet-cal helper integration (URL extraction fallback) -------
# Spec: when cron-meet-cal is on PATH, prefer it for meeting-URL extraction
# over the internal regex. Only kicks in when the event has no .url field
# (i.e. the URL is embedded in the title/summary). Subcommand convention:
#   `cron-meet-cal extract-url` reads event text on stdin, writes URL on
#   stdout, exits 0 (found) / 1 (none). Empty / non-zero -> fall through to
#   meeting_url_extract.

# Helper: write a no-URL standup event ICS that the test can re-point [calendar.ics] source at.
_write_nourl_fixture() {
  cat > "$JARVIS_HOME/test/cal-nourl.ics" <<'EOF'
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//jarvis test//EN
BEGIN:VEVENT
UID:standup-nourl-2026-05-01@test
DTSTART:20260501T100000Z
DTEND:20260501T103000Z
SUMMARY:standup join https://zoom.us/j/9876543
END:VEVENT
END:VCALENDAR
EOF
  # Re-point the source. dasel can rewrite the value but sed-replace is fine
  # since we control the fixture shape.
  cp "$JARVIS_HOME/test/config.toml" "$JARVIS_HOME/test/config.toml.tmp"
  sed "s|/cal\\.ics|/cal-nourl.ics|" \
    "$JARVIS_HOME/test/config.toml.tmp" > "$JARVIS_HOME/test/config.toml"
  rm -f "$JARVIS_HOME/test/config.toml.tmp"
}

@test "standup --join uses cron-meet-cal extractor when present" {
  _write_nourl_fixture
  shim_install cron-meet-cal '
    case "$1" in
      extract-url) printf "https://meet.example.com/from-cron-meet-cal\n"; exit 0 ;;
      *) exit 1 ;;
    esac'
  run bash "${JARVIS_DIR}/cmds/standup/standup.sh" --join --profile test
  [ "$status" -eq 0 ]
  [ -f "$(shim_log_path open)" ]
  grep -q "https://meet.example.com/from-cron-meet-cal" "$(shim_log_path open)"
}

@test "standup --join falls back to meeting_url_extract when cron-meet-cal absent" {
  _write_nourl_fixture
  # No cron-meet-cal shim — command -v fails; internal regex must catch the
  # zoom URL embedded in the SUMMARY.
  run bash "${JARVIS_DIR}/cmds/standup/standup.sh" --join --profile test
  [ "$status" -eq 0 ]
  [ -f "$(shim_log_path open)" ]
  grep -q "https://zoom.us/j/9876543" "$(shim_log_path open)"
}

@test "standup --join falls back when cron-meet-cal exits 1 (URL not found)" {
  _write_nourl_fixture
  shim_install cron-meet-cal 'exit 1'
  run bash "${JARVIS_DIR}/cmds/standup/standup.sh" --join --profile test
  [ "$status" -eq 0 ]
  [ -f "$(shim_log_path open)" ]
  # Internal regex still catches the zoom URL in the title.
  grep -q "https://zoom.us/j/9876543" "$(shim_log_path open)"
}
