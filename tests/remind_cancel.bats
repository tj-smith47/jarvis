#!/usr/bin/env bats
# T12 tests — cmds/remind/remind.cancel.sh: removes a reminder by slug,
# offers did-you-mean suggestions for typos (Levenshtein via
# clift_did_you_mean from lib/flags/errors.sh; substring fallback when
# that helper isn't loaded — see review S5).

bats_require_minimum_version 1.5.0

load 'helper'

setup() {
  jarvis_common_setup
  export JARVIS_FAKE_NOW="2026-04-26T14:00:00Z"
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/state/profile.sh"
  state_ensure_tree
}

teardown() {
  jarvis_common_teardown
}

_remind() {
  bash "${JARVIS_DIR}/cmds/remind/remind.sh" "$@"
}

_cancel() {
  bash "${JARVIS_DIR}/cmds/remind/remind.cancel.sh" "$@"
}

# Helper: seed N reminders with given descriptions, return slugs.
# Uses successive JARVIS_FAKE_NOW so each gets a unique timestamp suffix.
_seed() {
  local desc="$1"
  _remind "$desc" --in 10m >/dev/null
}

# ---------- happy path ----------

@test "cancel existing slug removes the reminder file" {
  _seed "ping"
  slug_file="$(ls "$JARVIS_HOME/test/reminders/"*.json | head -1)"
  base="${slug_file##*/}"
  slug="${base%.json}"

  run _cancel "$slug"
  [ "$status" -eq 0 ]
  [ ! -f "$slug_file" ]
  [[ "$output" == *"cancelled"* ]]
  [[ "$output" == *"$slug"* ]]
}

# ---------- missing-slug + similar names → suggestion ----------

@test "missing slug with similar candidate prints did-you-mean" {
  _seed "ping"
  # Capture the actual slug then mangle it for the typo lookup.
  slug_file="$(ls "$JARVIS_HOME/test/reminders/"*.json | head -1)"
  base="${slug_file##*/}"
  real="${base%.json}"
  # Make a typo: drop the last char.
  typo="${real%?}"

  run _cancel "$typo"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no reminder named"* ]]
  [[ "$output" == *"$typo"* ]]
  [[ "$output" == *"did you mean"* ]]
  [[ "$output" == *"$real"* ]]
}

# ---------- missing-slug + nothing similar → no suggestion line ----------

@test "missing slug with no similar candidate omits did-you-mean" {
  _seed "ping"

  run _cancel "totally-unrelated-name-xyz"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no reminder named"* ]]
  [[ "$output" == *"totally-unrelated-name-xyz"* ]]
  # Must NOT contain a did-you-mean line.
  [[ "$output" != *"did you mean"* ]]
}

# ---------- empty profile (no reminders at all) ----------

@test "missing slug with empty profile omits did-you-mean" {
  run _cancel "any-slug"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no reminder named"* ]]
  [[ "$output" != *"did you mean"* ]]
}

# ---------- usage ----------

@test "cancel with no slug prints usage and exits 2" {
  run _cancel
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage"* ]]
}
