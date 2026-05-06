#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

load 'helper'

setup() {
  jarvis_common_setup
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/calendar/meeting_url.sh"
}
teardown() { jarvis_common_teardown; }

@test "extracts zoom.us URL" {
  run bash -c "echo 'join at https://zoom.us/j/12345 ASAP' | meeting_url_extract"
  [ "$status" -eq 0 ]
  [ "$output" = "https://zoom.us/j/12345" ]
}

@test "extracts subdomain zoom URL" {
  run bash -c "echo 'see https://acme.zoom.us/j/98765?pwd=abc here' | meeting_url_extract"
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://acme.zoom.us/j/98765"* ]]
}

@test "extracts meet.google.com URL" {
  run bash -c "echo 'https://meet.google.com/abc-defg-hij' | meeting_url_extract"
  [ "$status" -eq 0 ]
  [ "$output" = "https://meet.google.com/abc-defg-hij" ]
}

@test "extracts teams.microsoft.com URL" {
  run bash -c "echo 'https://teams.microsoft.com/l/meetup-join/19%3a...?context=...' | meeting_url_extract"
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://teams.microsoft.com/l/meetup-join/"* ]]
}

@test "no match -> exit 1" {
  run bash -c "echo 'no urls here' | meeting_url_extract"
  [ "$status" -eq 1 ]
}

@test "first match wins on multi-URL input" {
  run bash -c "printf 'first https://zoom.us/j/111\nsecond https://meet.google.com/xx-yy-zz\n' | meeting_url_extract"
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://zoom.us/j/111"* ]]
}
