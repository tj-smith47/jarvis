#!/usr/bin/env bats
# brief: real-data sections + --short snapshot.
# Sections gate on lib output; --short emits a frozen one-liner.

bats_require_minimum_version 1.5.0

load 'helper'
load 'shim_helper'

setup() {
  jarvis_common_setup
  shim_setup
  cp -R "${BATS_TEST_DIRNAME}/fixtures/status-profile" "$JARVIS_HOME/test"
  # Augment the fixture profile with an oncall block + ICS calendar source
  # so brief has every section to render. status-profile/config.toml already
  # carries [jira]; we append rather than rewrite.
  cat >> "$JARVIS_HOME/test/config.toml" <<EOF

[oncall]
primary = "alex"
secondary = "you"
pager = "quiet"

[calendar]
provider = "ics"

[calendar.ics]
source = "$JARVIS_HOME/test/cal.ics"
EOF
  cp "${BATS_TEST_DIRNAME}/fixtures/calendar.ics" "$JARVIS_HOME/test/cal.ics"
  cat > "$JARVIS_HOME/test/deploys.log" <<EOF
2026-05-01T13:00:00Z	api	v1.12.3	ok
2026-05-01T08:00:00Z	web	v0.47.1	ok
EOF
  shim_install gh '
case "$1" in
  pr) cat <<EOF2
[{"number":482,"title":"feat(router): persistent flags","url":"https://github.com/org/repo/pull/482","headRepository":{"name":"repo","owner":{"login":"org"}}}]
EOF2
   exit 0 ;;
esac'
  export JARVIS_FAKE_NOW="2026-05-01T15:00:00Z"
}

teardown() {
  jarvis_common_teardown
}

@test "brief shows all sections when configured" {
  run bash "${JARVIS_DIR}/cmds/brief/brief.sh" --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"Calendar"* ]]
  [[ "$output" == *"PRs"* ]]
  [[ "$output" == *"Deploys"* ]]
  [[ "$output" == *"Oncall"* ]]
  [[ "$output" == *"alex"* ]]
  [[ "$output" == *"v1.12.3"* ]]
  [[ "$output" == *"org/repo#482"* ]]
}

@test "brief --short matches snapshot byte-for-byte" {
  run bash "${JARVIS_DIR}/cmds/brief/brief.sh" --short --profile test
  [ "$status" -eq 0 ]
  diff <(printf '%s\n' "$output") "${BATS_TEST_DIRNAME}/fixtures/brief-short.txt"
}

@test "brief --short pluralizes counts (0 / 1 / N)" {
  # Drop the gh shim to get 0 PRs; clear deploys log to get 0 deploys.
  rm -f "$SHIM_DIR/gh"
  rm -f "$JARVIS_HOME/test/deploys.log"
  run bash "${JARVIS_DIR}/cmds/brief/brief.sh" --short --profile test
  [ "$status" -eq 0 ]
  # Zero is plural ("0 PRs", "0 deploys") — matches goreleaser-style English.
  [[ "$output" == *"0 PRs"* ]]
  [[ "$output" == *"0 deploys"* ]]

  # Re-shim gh to emit 1 PR.
  shim_install gh 'cat <<EOF2
[{"number":1,"title":"a","url":"u","headRepository":{"name":"r","owner":{"login":"o"}}}]
EOF2'
  printf '2026-05-01T08:00:00Z\tweb\tv1\tok\n' > "$JARVIS_HOME/test/deploys.log"
  run bash "${JARVIS_DIR}/cmds/brief/brief.sh" --short --profile test
  [[ "$output" == *"1 PR "* ]]
  [[ "$output" == *"1 deploy "* ]]
}

@test "brief --short omits oncall when no [oncall] config" {
  # Strip the [oncall] section by overwriting config.toml without it.
  cat > "$JARVIS_HOME/test/config.toml" <<EOF
[calendar]
provider = "ics"
[calendar.ics]
source = "$JARVIS_HOME/test/cal.ics"
EOF
  run bash "${JARVIS_DIR}/cmds/brief/brief.sh" --short --profile test
  [ "$status" -eq 0 ]
  [[ "$output" != *"oncall"* ]]
}

@test "brief --short shows primary only when no secondary" {
  cat > "$JARVIS_HOME/test/config.toml" <<EOF
[oncall]
primary = "alex"

[calendar]
provider = "ics"
[calendar.ics]
source = "$JARVIS_HOME/test/cal.ics"
EOF
  run bash "${JARVIS_DIR}/cmds/brief/brief.sh" --short --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"oncall: alex"* ]]
  [[ "$output" != *" / "* ]]
}

@test "brief --skip-calendar hides Calendar but keeps others" {
  run bash "${JARVIS_DIR}/cmds/brief/brief.sh" --skip-calendar --profile test
  [ "$status" -eq 0 ]
  [[ "$output" != *"Calendar"* ]]
  [[ "$output" == *"PRs"* ]]
  [[ "$output" == *"Deploys"* ]]
}

@test "missing gh hides PRs section" {
  rm -f "$SHIM_DIR/gh"
  run bash "${JARVIS_DIR}/cmds/brief/brief.sh" --profile test
  [ "$status" -eq 0 ]
  [[ "$output" != *"PRs awaiting"* ]]
}

@test "calendar cache populated after first brief run" {
  bash "${JARVIS_DIR}/cmds/brief/brief.sh" --profile test > /dev/null
  bash "${JARVIS_DIR}/cmds/brief/brief.sh" --profile test > /dev/null
  [ -f "$JARVIS_HOME/test/cache/calendar.json" ]
}

@test "Reminders firing later today are surfaced in brief" {
  # Reminders are pre-fix invisible to brief — they live in <profile>/reminders/*.json
  # and only the `status` dashboard read them. The most "what's hitting me today"
  # signal jarvis owns must show in the "what's hitting me today" command.
  mkdir -p "$JARVIS_HOME/test/reminders"
  jq -nc --arg ts "2026-05-01T16:00:00Z" \
    '{slug:"call-mom",message:"call mom",status:"pending",
      trigger_at:$ts, via:["local"], repeat:"", anchor_at:"", until:"",
      count_remaining:null, created_at:"2026-05-01T08:00:00Z",
      fire_count:0, last_fired_at:""}' \
    > "$JARVIS_HOME/test/reminders/call-mom.json"
  jq -nc --arg ts "2026-05-01T18:30:00Z" \
    '{slug:"meds",message:"take meds",status:"active",
      trigger_at:$ts, via:["local"], repeat:"daily", anchor_at:"18:30",
      until:"", count_remaining:null,
      created_at:"2026-04-01T08:00:00Z",
      fire_count:30, last_fired_at:"2026-04-30T18:30:00Z"}' \
    > "$JARVIS_HOME/test/reminders/meds.json"
  # Past reminder (already fired earlier today) should NOT show:
  jq -nc --arg ts "2026-05-01T08:00:00Z" \
    '{slug:"morning",message:"already-fired",status:"pending",
      trigger_at:$ts, via:["local"], repeat:"", anchor_at:"", until:"",
      count_remaining:null, created_at:"2026-05-01T07:00:00Z",
      fire_count:0, last_fired_at:""}' \
    > "$JARVIS_HOME/test/reminders/morning.json"
  run bash "${JARVIS_DIR}/cmds/brief/brief.sh" --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"Reminders today"* ]]
  [[ "$output" == *"16:00"*"call mom"* ]]
  [[ "$output" == *"18:30"*"take meds"*"every daily"* ]]
  [[ "$output" != *"already-fired"* ]]
}

@test "PR rows surface draft + CI + age + review-decision when gh provides them" {
  shim_install gh '
case "$1" in
  pr) cat <<EOF2
[
  {"number":42,"title":"feat: ready for review","url":"https://github.com/o/r/pull/42",
   "headRepository":{"name":"r","owner":{"login":"o"}},
   "isDraft":false,"updatedAt":"2026-05-01T13:00:00Z",
   "statusCheckRollup":[{"conclusion":"SUCCESS"},{"conclusion":"SUCCESS"}],
   "reviewDecision":"APPROVED"},
  {"number":43,"title":"wip: not yet","url":"https://github.com/o/r/pull/43",
   "headRepository":{"name":"r","owner":{"login":"o"}},
   "isDraft":true,"updatedAt":"2026-05-01T14:30:00Z",
   "statusCheckRollup":[{"status":"IN_PROGRESS"}],
   "reviewDecision":null},
  {"number":44,"title":"hotfix","url":"https://github.com/o/r/pull/44",
   "headRepository":{"name":"r","owner":{"login":"o"}},
   "isDraft":false,"updatedAt":"2026-05-01T08:00:00Z",
   "statusCheckRollup":[{"conclusion":"FAILURE"}],
   "reviewDecision":"CHANGES_REQUESTED"}
]
EOF2
   exit 0 ;;
esac'
  run bash "${JARVIS_DIR}/cmds/brief/brief.sh" --profile test
  [ "$status" -eq 0 ]
  # Row 1: ready, approved, CI clean — JARVIS_FAKE_NOW is 15:00 so 2h since 13:00.
  [[ "$output" == *"o/r#42"*"feat: ready for review"*"2h"*"✓CI"*"approved"* ]]
  # Row 2: draft, CI pending — DRAFT prefix, ⏳CI marker
  [[ "$output" == *"[DRAFT]"*"o/r#43"*"⏳CI"* ]]
  # Row 3: changes-requested, CI failing
  [[ "$output" == *"o/r#44"*"✗CI"*"changes-requested"* ]]
}

@test "brief Tasks section shows open count + top 3 with metadata" {
  # Two tasks already in the fixture (write-spec, buy-milk). Add a high
  # priority one to verify priority-rank sorting bubbles it to the top.
  jq -nc '{slug:"urgent-fix", desc:"urgent fix",
           status:"open", priority:"high", due:"today", project:"release",
           created_at:"2026-04-30T10:00:00Z", updated_at:"2026-04-30T10:00:00Z",
           done_at:null, seq:99, jira_key:"PLAT-1", tags:[]}' \
    > "$JARVIS_HOME/test/tasks/urgent-fix.json"
  run bash "${JARVIS_DIR}/cmds/brief/brief.sh" --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"Tasks"* ]]
  [[ "$output" == *"3 open"* ]]
  [[ "$output" == *"1 due today"* ]]
  [[ "$output" == *"urgent fix"* ]]
  [[ "$output" == *"[high]"* ]]
  [[ "$output" == *"due today"* ]]
  [[ "$output" == *"PLAT-1"* ]]
}

@test "brief Notes section shows daily-today + touched-this-week" {
  # Seed an index with a daily note created today + 2 inbox notes touched
  # in the last 7 days. JARVIS_FAKE_NOW=2026-05-01T15:00:00Z (set in setup).
  mkdir -p "$JARVIS_HOME/test/notes/daily" "$JARVIS_HOME/test/notes/inbox"
  cat > "$JARVIS_HOME/test/notes/index.json" <<EOF
{"version":1,"notes":[
  {"path":"notes/daily/2026-05-01.md","kind":"daily","title":"daily 2026-05-01",
   "tags":[], "archived":false,
   "created_at":"2026-05-01T08:00:00Z","updated_at":"2026-05-01T09:00:00Z"},
  {"path":"notes/inbox/recent.md","kind":"inbox","title":"recent",
   "tags":[], "archived":false,
   "created_at":"2026-04-29T10:00:00Z","updated_at":"2026-04-30T10:00:00Z"},
  {"path":"notes/inbox/old.md","kind":"inbox","title":"old",
   "tags":[], "archived":false,
   "created_at":"2026-03-01T10:00:00Z","updated_at":"2026-03-01T10:00:00Z"}
]}
EOF
  run bash "${JARVIS_DIR}/cmds/brief/brief.sh" --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"Notes"* ]]
  [[ "$output" == *"daily today: ✓"* ]]
  [[ "$output" == *"2 touched this week"* ]]
}

@test "brief --skip-tasks hides Tasks section" {
  run bash "${JARVIS_DIR}/cmds/brief/brief.sh" --skip-tasks --profile test
  [ "$status" -eq 0 ]
  [[ "$output" != *"Tasks"* ]]
  # Other sections still render.
  [[ "$output" == *"Calendar"* ]] || [[ "$output" == *"Oncall"* ]]
}

@test "brief --skip-notes hides Notes section" {
  mkdir -p "$JARVIS_HOME/test/notes/daily"
  cat > "$JARVIS_HOME/test/notes/index.json" <<EOF
{"version":1,"notes":[
  {"path":"notes/daily/2026-05-01.md","kind":"daily","title":"d",
   "tags":[],"archived":false,
   "created_at":"2026-05-01T08:00:00Z","updated_at":"2026-05-01T09:00:00Z"}
]}
EOF
  run bash "${JARVIS_DIR}/cmds/brief/brief.sh" --skip-notes --profile test
  [ "$status" -eq 0 ]
  [[ "$output" != *"Notes"* ]]
}

@test "brief --skip-reminders hides Reminders section" {
  mkdir -p "$JARVIS_HOME/test/reminders"
  jq -nc '{slug:"r1", message:"call dentist", status:"pending",
           trigger_at:"2026-05-01T18:00:00Z", via:["local"], repeat:"",
           anchor_at:"", until:"", count_remaining:null,
           created_at:"2026-05-01T08:00:00Z", fire_count:0, last_fired_at:""}' \
    > "$JARVIS_HOME/test/reminders/r1.json"
  run bash "${JARVIS_DIR}/cmds/brief/brief.sh" --skip-reminders --profile test
  [ "$status" -eq 0 ]
  [[ "$output" != *"call dentist"* ]]
}

@test "brief --skip-oncall hides Oncall section" {
  run bash "${JARVIS_DIR}/cmds/brief/brief.sh" --skip-oncall --profile test
  [ "$status" -eq 0 ]
  [[ "$output" != *"Oncall"* ]]
}

@test "brief --skip-focus hides yesterday focus line" {
  # Drop a focus.log entry for yesterday so the section would normally render.
  cat > "$JARVIS_HOME/test/focus.log" <<EOF
{"ts":"2026-04-30T09:00:00Z","event":"start","topic":"jarvis"}
{"ts":"2026-04-30T10:00:00Z","event":"end","topic":"jarvis","elapsed_seconds":3600}
EOF
  run bash "${JARVIS_DIR}/cmds/brief/brief.sh" --skip-focus --profile test
  [ "$status" -eq 0 ]
  [[ "$output" != *"Focus yesterday"* ]]
}
