#!/usr/bin/env bats
# Tests for lib/integrations/gh.sh — `gh pr list ... --json ...`
# JSON array → NDJSON {number,title,url,repo}. Uses PATH-shimmed `gh` so no
# real binary is invoked.

bats_require_minimum_version 1.5.0

load 'helper'
load 'shim_helper'

setup() {
  jarvis_common_setup
  shim_setup
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/integrations/gh.sh"
}

teardown() {
  jarvis_common_teardown
}

@test "missing gh -> exit 1" {
  PATH="$SHIM_DIR" run gh_prs_review_requested
  [ "$status" -eq 1 ]
}

@test "gh review-requested -> NDJSON rows" {
  shim_install gh 'cat <<EOF
[{"number":482,"title":"feat(router): persistent flags","url":"https://github.com/org/repo/pull/482","headRepository":{"name":"repo","owner":{"login":"org"}}},
 {"number":491,"title":"fix(flags): alias collision","url":"https://github.com/org/other/pull/491","headRepository":{"name":"other","owner":{"login":"org"}}}]
EOF
exit 0'
  run gh_prs_review_requested
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 2 ]
  printf '%s\n' "$output" | head -1 | jq -e '.number == 482 and .repo == "org/repo"' > /dev/null
}

@test "gh authored -> NDJSON rows" {
  shim_install gh 'cat <<EOF
[{"number":500,"title":"chore: bump","url":"https://github.com/org/repo/pull/500","headRepository":{"name":"repo","owner":{"login":"org"}}}]
EOF
exit 0'
  run gh_prs_authored
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
}

@test "gh nonzero exit -> exit 1 with stderr" {
  shim_install gh 'echo "auth required" >&2; exit 4'
  run --separate-stderr gh_prs_review_requested
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"auth required"* ]]
}

@test "empty array -> exit 0 empty stdout" {
  shim_install gh 'echo "[]"; exit 0'
  run gh_prs_review_requested
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
