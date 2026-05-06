#!/usr/bin/env bats
# T11 tests — cmds/remind/remind.list.sh: table output, --all-profiles,
# --json/--yaml, sort order, LAST_FIRED column for recurring (review S2).

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

# Run the remind cmd to seed reminders.
_seed_one_shot() {
  bash "${JARVIS_DIR}/cmds/remind/remind.sh" "$@" >/dev/null
}

_list() {
  bash "${JARVIS_DIR}/cmds/remind/remind.list.sh" "$@"
}

# ---------- empty ----------

@test "empty list prints 'no reminders' on tty path" {
  run _list
  [ "$status" -eq 0 ]
  [[ "$output" == *"no reminders"* ]]
}

@test "empty --json returns []" {
  run _list --json
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

# ---------- single one-shot ----------

@test "one-shot reminder shows in table with WHEN, REPEAT=once, LAST_FIRED=—" {
  _seed_one_shot "ping" --in 10m
  run _list
  [ "$status" -eq 0 ]
  [[ "$output" == *"SLUG"* ]]
  [[ "$output" == *"WHEN"* ]]
  [[ "$output" == *"REPEAT"* ]]
  [[ "$output" == *"LAST_FIRED"* ]]
  [[ "$output" == *"ping-2026-04-26-1400"* ]]
  [[ "$output" == *"in 10m"* ]]
  [[ "$output" == *"once"* ]]
  [[ "$output" == *"—"* ]]
}

# ---------- recurring with last_fired ----------

@test "recurring with last_fired shows relative time in LAST_FIRED column" {
  _seed_one_shot "standup" --repeat daily --at 09:00
  # Mutate the file: simulate a previous fire 1h ago.
  f="$(ls "$JARVIS_HOME/test/reminders/"*.json | head -1)"
  jq -c '.last_fired_at = "2026-04-26T13:00:00Z" | .fire_count = 1' "$f" > "$f.tmp"
  mv "$f.tmp" "$f"
  run _list
  [ "$status" -eq 0 ]
  [[ "$output" == *"daily 09:00"* ]]
  [[ "$output" == *"1h ago"* ]]
}

# ---------- sorted ----------

@test "list sorted by trigger_at ascending" {
  _seed_one_shot "later" --in 1h
  _seed_one_shot "soon" --in 5m
  run _list
  [ "$status" -eq 0 ]
  # 'soon' should appear before 'later' in output.
  soon_line=$(echo "$output" | grep -n "soon-" | head -1 | cut -d: -f1)
  later_line=$(echo "$output" | grep -n "later-" | head -1 | cut -d: -f1)
  [ "$soon_line" -lt "$later_line" ]
}

# ---------- --json ----------

@test "--json emits sorted array" {
  _seed_one_shot "later" --in 1h
  _seed_one_shot "soon" --in 5m
  run _list --json
  [ "$status" -eq 0 ]
  count="$(jq 'length' <<< "$output")"
  [ "$count" = "2" ]
  first_slug="$(jq -r '.[0].slug' <<< "$output")"
  [[ "$first_slug" == soon-* ]]
}

@test "--json + --yaml mutually exclusive" {
  run _list --json --yaml
  [ "$status" -ne 0 ]
}

# ---------- --all-profiles ----------

@test "--all-profiles includes reminders from every profile" {
  # Seed in 'test' profile.
  _seed_one_shot "test-rem" --in 10m
  # Seed in 'work' profile by switching JARVIS_PROFILE.
  mkdir -p "$JARVIS_HOME/work/reminders"
  JARVIS_PROFILE=work bash "${JARVIS_DIR}/cmds/remind/remind.sh" \
    "work-rem" --in 5m >/dev/null

  run _list --all-profiles --json
  [ "$status" -eq 0 ]
  count="$(jq 'length' <<< "$output")"
  [ "$count" = "2" ]
}

@test "default (no --all-profiles) shows only current profile" {
  _seed_one_shot "test-rem" --in 10m
  mkdir -p "$JARVIS_HOME/work/reminders"
  JARVIS_PROFILE=work bash "${JARVIS_DIR}/cmds/remind/remind.sh" \
    "work-rem" --in 5m >/dev/null

  run _list --json
  [ "$status" -eq 0 ]
  count="$(jq 'length' <<< "$output")"
  [ "$count" = "1" ]
  slug="$(jq -r '.[0].slug' <<< "$output")"
  [[ "$slug" == test-rem-* ]]
}
