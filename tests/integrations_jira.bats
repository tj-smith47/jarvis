#!/usr/bin/env bats
# Tests for lib/integrations/jira.sh — `jira` CLI in-flight
# issues + my comments since. --plain output is TSV; awk parses + JSON-escapes.
# Uses PATH-shimmed `jira` so no real binary is invoked.

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
  source "${JARVIS_DIR}/lib/integrations/jira.sh"
  state_ensure_tree
  printf '[jira]\nbase_url = "https://jira.example.com"\n' > "$JARVIS_HOME/test/config.toml"
}

teardown() {
  jarvis_common_teardown
}

@test "missing jira -> exit 1" {
  PATH="$SHIM_DIR" run jira_in_flight test
  [ "$status" -eq 1 ]
}

@test "jira_in_flight emits NDJSON from --plain output" {
  shim_install jira '
case "$1 $2" in
  "me ")    echo "alice"; exit 0 ;;
  "issue list")
    cat <<EOF
KEY	SUMMARY	STATUS
PLAT-123	Migrate auth	In Progress
PLAT-456	Refactor index	In Progress
EOF
    exit 0 ;;
esac'
  run jira_in_flight test
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 2 ]
  printf '%s\n' "$output" | head -1 | jq -e '.key == "PLAT-123" and .url == "https://jira.example.com/browse/PLAT-123"' > /dev/null
}

@test "jira_my_comments_since filters by ts and author" {
  shim_install jira '
case "$1 $2" in
  "me ")    echo "alice"; exit 0 ;;
  "issue list")
    cat <<EOF
KEY	SUMMARY	STATUS
PLAT-123	Migrate auth	In Progress
EOF
    exit 0 ;;
  "issue comment")
    cat <<EOF
ID	AUTHOR	CREATED	BODY
1	alice	2026-04-30T15:22:11Z	pushed PR up
2	bob	2026-04-29T10:00:00Z	thanks
3	alice	2026-04-25T09:00:00Z	too old
EOF
    exit 0 ;;
esac'
  run jira_my_comments_since "2026-04-30T00:00:00Z" test
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
  printf '%s\n' "$output" | jq -e '.key == "PLAT-123" and .body == "pushed PR up"' > /dev/null
}

@test "jira_in_flight nonzero exit -> exit 1" {
  shim_install jira '
case "$1 $2" in
  "me ")    echo "alice"; exit 0 ;;
  "issue list") echo "boom" >&2; exit 3 ;;
esac'
  run jira_in_flight test
  [ "$status" -eq 1 ]
}

@test "jira summary with quotes is JSON-escaped" {
  shim_install jira '
case "$1 $2" in
  "me ")    echo "alice"; exit 0 ;;
  "issue list")
    printf "KEY\tSUMMARY\tSTATUS\n"
    printf "PLAT-9\tFix \"auth\" bug\tIn Progress\n"
    exit 0 ;;
esac'
  run jira_in_flight test
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.summary == "Fix \"auth\" bug"' > /dev/null
}
