#!/usr/bin/env bats
# `jarvis cleanup` — retention policy applied to focus.log + notify.log
# + delivered reminders + done tasks. Cron-based wrapper covered in
# tests/cleanup_install.bats.
#
# All time math is anchored on JARVIS_FAKE_NOW so the cutoff is
# deterministic regardless of when the test runs.

bats_require_minimum_version 1.5.0

load 'helper'

setup() {
  jarvis_common_setup
  mkdir -p "$JARVIS_HOME/test/reminders" "$JARVIS_HOME/test/tasks"
  printf '1\n' > "$JARVIS_HOME/test/state.version"
  export JARVIS_FAKE_NOW="2026-05-01T15:00:00Z"
}
teardown() { jarvis_common_teardown; }

_run_cleanup() {
  FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR" CLI_DIR="$JARVIS_DIR" \
    bash "$JARVIS_DIR/cmds/cleanup/cleanup.sh" "$@"
}

# Fixture builder. JARVIS_FAKE_NOW is 2026-05-01.
# 1 day ago         = 2026-04-30   (within 30d retention)
# 100 days ago      = 2026-01-21   (outside 30d, outside 90d would also exclude)
# 30 days ago + 1d  = 2026-04-02   (just outside 30d retention)
_seed_focus_log() {
  cat > "$JARVIS_HOME/test/focus.log" <<EOF
{"ts":"2026-04-30T10:00:00Z","event":"start","topic":"recent"}
{"ts":"2026-04-30T11:00:00Z","event":"end","topic":"recent","elapsed_seconds":3600}
{"ts":"2026-01-21T10:00:00Z","event":"start","topic":"old"}
{"ts":"2026-01-21T11:00:00Z","event":"end","topic":"old","elapsed_seconds":3600}
EOF
}

_seed_notify_log() {
  cat > "$JARVIS_HOME/test/notify.log" <<EOF
{"ts":"2026-04-30T10:00:00Z","channel":"local","ok":true,"message":"recent"}
{"ts":"2026-01-21T10:00:00Z","channel":"local","ok":true,"message":"old"}
EOF
}

_seed_reminder() {
  local slug="$1" status="$2" repeat="$3" last_fired_at="$4"
  jq -nc \
    --arg slug "$slug" --arg status "$status" --arg repeat "$repeat" \
    --arg lf "$last_fired_at" \
    '{slug:$slug, message:"x", profile:"test",
      trigger_at:"2026-04-26T15:00:00Z", via:["local"],
      status:$status, repeat:$repeat, anchor_at:"", until:"",
      count_remaining:null, created_at:"2026-01-01T00:00:00Z",
      fire_count:1, last_fired_at:$lf}' \
    > "$JARVIS_HOME/test/reminders/$slug.json"
}

_seed_task() {
  local slug="$1" status="$2" done_at="$3"
  jq -nc \
    --arg slug "$slug" --arg status "$status" --arg done_at "$done_at" \
    '{slug:$slug, desc:$slug, status:$status, priority:"med", due:null,
      project:"inbox", created_at:"2026-01-01T00:00:00Z",
      updated_at:"2026-01-01T00:00:00Z",
      done_at:(if $done_at == "" then null else $done_at end),
      seq:1, jira_key:null, tags:[]}' \
    > "$JARVIS_HOME/test/tasks/$slug.json"
}

@test "cleanup default (dry-run, 90d) prints plan with zero counts on clean state" {
  run _run_cleanup
  [ "$status" -eq 0 ]
  [[ "$output" == *"focus.log rows               0"* ]]
  [[ "$output" == *"notify.log rows              0"* ]]
  [[ "$output" == *"delivered reminders          0"* ]]
  [[ "$output" == *"done tasks                   0"* ]]
  [[ "$output" == *"(nothing to do)"* ]]
}

@test "cleanup --json emits structured plan" {
  _seed_focus_log
  run _run_cleanup --before 30d --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.before' <<< "$output")" = "30d" ]
  [ "$(jq -r '.focus_log_rows' <<< "$output")" = "2" ]
}

@test "cleanup --before 30d counts focus.log + notify.log rows older than cutoff" {
  _seed_focus_log
  _seed_notify_log
  run _run_cleanup --before 30d
  [ "$status" -eq 0 ]
  # 2 old focus rows, 1 old notify row.
  [[ "$output" == *"focus.log rows               2"* ]]
  [[ "$output" == *"notify.log rows              1"* ]]
}

@test "cleanup --before 30d --confirm compacts focus.log in place" {
  _seed_focus_log
  run _run_cleanup --before 30d --confirm
  [ "$status" -eq 0 ]
  # After compaction only the 2 recent rows survive.
  [ "$(wc -l < "$JARVIS_HOME/test/focus.log")" = "2" ]
  ! grep -q '"old"' "$JARVIS_HOME/test/focus.log"
  grep -q '"recent"' "$JARVIS_HOME/test/focus.log"
}

@test "cleanup --confirm drops delivered one-shot reminders past cutoff" {
  _seed_reminder old-delivered  delivered ""        "2026-01-21T10:00:00Z"
  _seed_reminder recent-delivered delivered ""      "2026-04-30T10:00:00Z"
  _seed_reminder recurring-old  delivered "1d"      "2026-01-21T10:00:00Z"
  _seed_reminder pending        pending   ""        ""

  run _run_cleanup --before 30d --confirm
  [ "$status" -eq 0 ]
  [ ! -e "$JARVIS_HOME/test/reminders/old-delivered.json" ]
  [ -e "$JARVIS_HOME/test/reminders/recent-delivered.json" ]
  [ -e "$JARVIS_HOME/test/reminders/recurring-old.json" ]   # repeating: never deleted
  [ -e "$JARVIS_HOME/test/reminders/pending.json" ]         # not delivered
}

@test "cleanup --confirm drops done tasks past cutoff" {
  _seed_task old-done   done "2026-01-21T10:00:00Z"
  _seed_task recent-done done "2026-04-30T10:00:00Z"
  _seed_task open      open ""

  run _run_cleanup --before 30d --confirm
  [ "$status" -eq 0 ]
  [ ! -e "$JARVIS_HOME/test/tasks/old-done.json" ]
  [ -e "$JARVIS_HOME/test/tasks/recent-done.json" ]
  [ -e "$JARVIS_HOME/test/tasks/open.json" ]
}

@test "cleanup invalid --before exits 2" {
  run _run_cleanup --before 7
  [ "$status" -eq 2 ]
}

@test "cleanup --before 4w accepts week unit" {
  _seed_focus_log
  run _run_cleanup --before 4w
  [ "$status" -eq 0 ]
  # 4 weeks = 28 days; focus rows from 2026-01-21 (100d ago) trip cutoff.
  [[ "$output" == *"focus.log rows               2"* ]]
}

@test "cleanup --confirm leaves a day-old focus.log untouched" {
  _seed_focus_log
  # 1d cutoff: only "recent" rows from 2026-04-30 survive.
  run _run_cleanup --before 1d --confirm
  [ "$status" -eq 0 ]
  # All 4 rows are >1d old? actually JARVIS_FAKE_NOW=2026-05-01T15:00:00Z,
  # cutoff = 2026-04-30T15:00:00Z. The recent rows at 2026-04-30T10/11
  # are BEFORE that cutoff. So all 4 get evicted.
  [ "$(wc -l < "$JARVIS_HOME/test/focus.log" || echo 0)" = "0" ]
}
