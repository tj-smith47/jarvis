#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

load helper
load shim_helper

setup() {
  jarvis_common_setup
  export TEST_DIR
}
teardown() { jarvis_common_teardown; }

# Seed a reminder JSON with given slug + status. Bypasses cmds/remind/remind.sh
# so we can test counts without invoking the time-aware create path.
_seed_reminder() {
  local slug="$1" status="$2"
  local dir="$JARVIS_HOME/test/reminders"
  mkdir -p "$dir"
  jq -nc \
    --arg slug "$slug" \
    --arg status "$status" \
    '{slug:$slug, message:"x", profile:"test",
      trigger_at:"2026-04-26T15:00:00Z", via:["local"],
      status:$status, repeat:"", anchor_at:"", until:"",
      count_remaining:null, created_at:"2026-04-26T14:00:00Z",
      fire_count:0, last_fired_at:""}' > "$dir/$slug.json"
}

# Append a delivery row to the NDJSON log. Used for delivered/failed counts.
_seed_delivery() {
  local ok="$1" channel="${2:-local}" slug="${3:-x-1}"
  local log="$JARVIS_HOME/test/reminders.delivery.log"
  mkdir -p "$(dirname "$log")"
  jq -nc \
    --arg ch "$channel" --argjson ok "$ok" --arg slug "$slug" \
    '{ts:"2026-04-26T15:00:00Z", channel:$ch, ok:$ok,
      message:"hello", slug:$slug}' >> "$log"
}

_seed_heartbeat() {
  local ts="$1"
  local log="$JARVIS_HOME/test/reminders.delivery.log"
  mkdir -p "$(dirname "$log")"
  jq -nc --arg ts "$ts" '{ts:$ts, kind:"tick.heartbeat", slug:"_heartbeat"}' \
    >> "$log"
}

@test "debug command directory no longer exists" {
  [ ! -d "$JARVIS_DIR/cmds/debug" ]
}

@test "debug not referenced in root Taskfile.yaml" {
  ! grep -qE '^\s*debug:' "$JARVIS_DIR/Taskfile.yaml"
}

@test "doctor prints profile line with resolved path" {
  mkdir -p "$JARVIS_HOME/test"
  printf '1\n' > "$JARVIS_HOME/test/state.version"
  run bash "$JARVIS_DIR/cmds/doctor/doctor.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"profile"* ]]
  [[ "$output" == *"$JARVIS_HOME/test"* ]]
}

@test "doctor prints state schema line" {
  mkdir -p "$JARVIS_HOME/test"
  printf '1\n' > "$JARVIS_HOME/test/state.version"
  run bash "$JARVIS_DIR/cmds/doctor/doctor.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"state schema"* ]]
  [[ "$output" == *"v1"* ]]
}

@test "doctor --path prints resolved state dir and exits" {
  mkdir -p "$JARVIS_HOME/test"
  # doctor.sh reads CLIFT_FLAGS[path]; bats subshell needs explicit declaration.
  run bash -c 'declare -A CLIFT_FLAGS=([path]=true); source "$1"' _ "$JARVIS_DIR/cmds/doctor/doctor.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "$JARVIS_HOME/test" ]
}

@test "doctor --rebuild-index regenerates .index.json from files on disk" {
  source "$JARVIS_DIR/lib/state/profile.sh"
  source "$JARVIS_DIR/lib/state/lock.sh"
  source "$JARVIS_DIR/lib/state/json.sh"
  source "$JARVIS_DIR/lib/frontmatter.sh"
  source "$JARVIS_DIR/lib/note/resolve.sh"
  source "$JARVIS_DIR/lib/note/index.sh"
  source "$JARVIS_DIR/lib/note/store.sh"
  state_ensure_tree
  note_store_new inbox a "A" >/dev/null
  note_store_new ref b "B" >/dev/null
  rm -f "$(note_index_file)"

  run bash -c 'declare -A CLIFT_FLAGS=([rebuild-index]=true); source "$1"' _ "$JARVIS_DIR/cmds/doctor/doctor.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 notes"* ]]
  [ -f "$(note_index_file)" ]
  run jq -r 'keys | sort | join(",")' "$(note_index_file)"
  [ "$output" = "inbox/a,ref/b" ]
}

@test "doctor --rebuild-index on an empty notes tree reports 0 notes" {
  source "$JARVIS_DIR/lib/state/profile.sh"
  source "$JARVIS_DIR/lib/note/resolve.sh"
  state_ensure_tree

  run bash -c 'declare -A CLIFT_FLAGS=([rebuild-index]=true); source "$1"' _ "$JARVIS_DIR/cmds/doctor/doctor.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 notes"* ]]
}

# ---- focus.log orphan-row check ----------------------------------------

@test "doctor: focus.log line shows 'no log yet' before any sessions" {
  mkdir -p "$JARVIS_HOME/test"
  printf '1\n' > "$JARVIS_HOME/test/state.version"
  run bash "$JARVIS_DIR/cmds/doctor/doctor.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"focus.log"* ]]
  [[ "$output" == *"no log yet"* ]]
}

@test "doctor: focus.log clean when all starts have ends" {
  mkdir -p "$JARVIS_HOME/test"
  printf '1\n' > "$JARVIS_HOME/test/state.version"
  source "$JARVIS_DIR/lib/state/profile.sh"
  source "$JARVIS_DIR/lib/state/lock.sh"
  source "$JARVIS_DIR/lib/state/ndjson.sh"
  source "$JARVIS_DIR/lib/focus/log.sh"
  focus_log_append start "1s" "demo"
  focus_log_append end   ""   "demo"

  run bash "$JARVIS_DIR/cmds/doctor/doctor.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 orphan rows"* ]]
}

# ---- T16: reminders rollup + scheduler check --------------------------

@test "doctor: reminders section appears with all-zero counts on empty profile" {
  mkdir -p "$JARVIS_HOME/test"
  printf '1\n' > "$JARVIS_HOME/test/state.version"
  run bash "$JARVIS_DIR/cmds/doctor/doctor.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"reminders"* ]]
  [[ "$output" == *"pending"* ]]
  [[ "$output" == *"delivered"* ]]
  [[ "$output" == *"scheduler"* ]]
}

@test "doctor: pending + active counts reflect seeded reminders" {
  mkdir -p "$JARVIS_HOME/test"
  printf '1\n' > "$JARVIS_HOME/test/state.version"
  _seed_reminder a pending
  _seed_reminder b pending
  _seed_reminder c active
  run bash "$JARVIS_DIR/cmds/doctor/doctor.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ pending[[:space:]]+2 ]]
  [[ "$output" =~ active[[:space:]]+1 ]]
}

@test "doctor: delivered + failed counts come from NDJSON" {
  mkdir -p "$JARVIS_HOME/test"
  printf '1\n' > "$JARVIS_HOME/test/state.version"
  _seed_delivery true  local a
  _seed_delivery true  local b
  _seed_delivery true  local c
  _seed_delivery false local d
  run bash "$JARVIS_DIR/cmds/doctor/doctor.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ delivered[[:space:]]+3 ]]
  [[ "$output" =~ failed[[:space:]]+1 ]]
}

@test "doctor: scheduler reports NOT installed when no cron line" {
  mkdir -p "$JARVIS_HOME/test"
  printf '1\n' > "$JARVIS_HOME/test/state.version"
  shim_setup
  shim_install crontab 'exit 1'  # no crontab for user
  run bash "$JARVIS_DIR/cmds/doctor/doctor.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT installed"* ]]
}

@test "doctor: scheduler reports cron installed + recent tick" {
  mkdir -p "$JARVIS_HOME/test"
  printf '1\n' > "$JARVIS_HOME/test/state.version"
  shim_setup
  shim_install crontab '
fake="$TEST_DIR/fake.crontab"
case "${1:-}" in
  -l) cat "$fake" 2>/dev/null || exit 1 ;;
  *)  cat > "$fake" ;;
esac
'
  printf '%s\n' '* * * * * jarvis remind tick >/dev/null 2>&1' \
    > "$TEST_DIR/fake.crontab"

  # Heartbeat 30s before fake-now
  export JARVIS_FAKE_NOW="2026-04-26T15:00:00Z"
  _seed_heartbeat "2026-04-26T14:59:30Z"

  run bash "$JARVIS_DIR/cmds/doctor/doctor.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"installed"* ]]
  [[ "$output" != *"NOT installed"* ]]
  [[ "$output" != *"stale"* ]]
}

@test "doctor: scheduler stale warning when heartbeat > 5min ago" {
  mkdir -p "$JARVIS_HOME/test"
  printf '1\n' > "$JARVIS_HOME/test/state.version"
  shim_setup
  shim_install crontab '
fake="$TEST_DIR/fake.crontab"
case "${1:-}" in
  -l) cat "$fake" 2>/dev/null || exit 1 ;;
  *)  cat > "$fake" ;;
esac
'
  printf '%s\n' '* * * * * jarvis remind tick >/dev/null 2>&1' \
    > "$TEST_DIR/fake.crontab"

  # Heartbeat 10 minutes before fake-now
  export JARVIS_FAKE_NOW="2026-04-26T15:10:00Z"
  _seed_heartbeat "2026-04-26T15:00:00Z"

  run bash "$JARVIS_DIR/cmds/doctor/doctor.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stale"* ]]
}

@test "doctor: systemd backend installed reports installed" {
  mkdir -p "$JARVIS_HOME/test"
  printf '1\n' > "$JARVIS_HOME/test/state.version"
  cat > "$JARVIS_HOME/test/config.toml" <<EOF
[scheduler]
backend = "systemd"
EOF
  mkdir -p "$HOME/.config/systemd/user"
  printf '[Unit]\nDescription=jarvis remind tick\n' \
    > "$HOME/.config/systemd/user/jarvis-tick.service"
  printf '[Timer]\nOnCalendar=*:0/1\n' \
    > "$HOME/.config/systemd/user/jarvis-tick.timer"

  export JARVIS_FAKE_NOW="2026-04-26T15:00:00Z"
  _seed_heartbeat "2026-04-26T14:59:30Z"

  run bash "$JARVIS_DIR/cmds/doctor/doctor.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"systemd"* ]]
  [[ "$output" == *"installed"* ]]
  [[ "$output" != *"NOT installed"* ]]
}

# ---- T14: integrations rollup (calendar / gh / jira / gcalcli) -------

@test "doctor shows integrations rollup" {
  mkdir -p "$JARVIS_HOME/test"
  printf '1\n' > "$JARVIS_HOME/test/state.version"
  shim_setup
  shim_install gh 'case "$1 $2" in "auth status") exit 0;; *) exit 0;; esac'
  shim_install jira 'exit 0'
  cat > "$JARVIS_HOME/test/config.toml" <<EOF
[calendar]
provider = "ics"
EOF
  run bash "${JARVIS_DIR}/cmds/doctor/doctor.sh" --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"Integrations"* ]]
  [[ "$output" == *"calendar"* ]]
  [[ "$output" == *"ics"* ]]
  [[ "$output" == *"gh"* ]]
  [[ "$output" == *"ok"* ]]
  [[ "$output" == *"jira"* ]]
  [[ "$output" == *"gcalcli"* ]]
  [[ "$output" == *"missing"* ]]   # gcalcli has no shim
}

@test "doctor shows calendar 'not configured' on default" {
  mkdir -p "$JARVIS_HOME/test"
  printf '1\n' > "$JARVIS_HOME/test/state.version"
  run bash "${JARVIS_DIR}/cmds/doctor/doctor.sh" --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"not configured"* ]]
}

# ---- --integrations-live (live probes that surface upstream errors) ---

@test "doctor --integrations-live shows Live probes section" {
  mkdir -p "$JARVIS_HOME/test"
  printf '1\n' > "$JARVIS_HOME/test/state.version"
  shim_setup
  shim_install gh 'case "$1 $2" in "auth status") exit 0;; *) printf "[]\n";; esac'
  shim_install jira '
    case "$1" in
      me) printf "shimuser\n" ;;
      issue) printf "key\tsummary\tstatus\nFOO-1\tdo a thing\tIn Progress\n" ;;
      *) exit 0 ;;
    esac'
  run bash "${JARVIS_DIR}/cmds/doctor/doctor.sh" --profile test --integrations-live
  [ "$status" -eq 0 ]
  [[ "$output" == *"Live probes"* ]]
  [[ "$output" == *"gh"* ]]
  [[ "$output" == *"jira"* ]]
  # jira shim returned 1 in-flight row.
  [[ "$output" == *"1 in flight"* ]]
}

@test "doctor --integrations-live: calendar=ics with bad source surfaces probe failure" {
  mkdir -p "$JARVIS_HOME/test"
  printf '1\n' > "$JARVIS_HOME/test/state.version"
  shim_setup
  # curl exits 22 (HTTP error). The provider is invoked directly so its
  # stderr reaches the user — assert via run --separate-stderr.
  shim_install curl 'printf "curl: (22) HTTP error\n" >&2; exit 22'
  cat > "$JARVIS_HOME/test/config.toml" <<EOF
[calendar]
provider = "ics"
[calendar.ics]
source = "https://nope.example.com/cal.ics"
EOF
  run --separate-stderr bash "${JARVIS_DIR}/cmds/doctor/doctor.sh" \
    --profile test --integrations-live
  [ "$status" -eq 0 ]
  [[ "$output" == *"Live probes"* ]]
  [[ "$output" == *"calendar"* ]]
  [[ "$output" == *"ics"* ]]
  # The curl stderr should bubble through to the user.
  [[ "$stderr" == *"HTTP error"* ]] || [[ "$output" == *"probe exited"* ]]
}

@test "doctor (default, no --integrations-live) does NOT show Live probes" {
  mkdir -p "$JARVIS_HOME/test"
  printf '1\n' > "$JARVIS_HOME/test/state.version"
  run bash "${JARVIS_DIR}/cmds/doctor/doctor.sh" --profile test
  [ "$status" -eq 0 ]
  [[ "$output" != *"Live probes"* ]]
}

# ---- Enablement reasons (one-line "why disabled" per integration) -----

@test "doctor: calendar reason explains missing config.toml" {
  mkdir -p "$JARVIS_HOME/test"
  printf '1\n' > "$JARVIS_HOME/test/state.version"
  run bash "${JARVIS_DIR}/cmds/doctor/doctor.sh" --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"calendar"* ]]
  [[ "$output" == *"not configured"* ]]
  [[ "$output" == *"no config.toml"* ]]
}

@test "doctor: calendar reason explains missing [calendar] provider key" {
  mkdir -p "$JARVIS_HOME/test"
  printf '1\n' > "$JARVIS_HOME/test/state.version"
  printf '[other]\nkey = "x"\n' > "$JARVIS_HOME/test/config.toml"
  run bash "${JARVIS_DIR}/cmds/doctor/doctor.sh" --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"calendar"* ]]
  [[ "$output" == *"not configured"* ]]
  [[ "$output" == *"set [calendar] provider"* ]]
}

@test "doctor: calendar reason marks explicit provider='none' as disabled" {
  mkdir -p "$JARVIS_HOME/test"
  printf '1\n' > "$JARVIS_HOME/test/state.version"
  cat > "$JARVIS_HOME/test/config.toml" <<EOF
[calendar]
provider = "none"
EOF
  run bash "${JARVIS_DIR}/cmds/doctor/doctor.sh" --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"calendar"* ]]
  [[ "$output" == *"disabled"* ]]
  [[ "$output" == *"provider = 'none'"* ]]
}

@test "doctor: calendar reason flags unknown provider with the registered list" {
  mkdir -p "$JARVIS_HOME/test"
  printf '1\n' > "$JARVIS_HOME/test/state.version"
  cat > "$JARVIS_HOME/test/config.toml" <<EOF
[calendar]
provider = "bogus"
EOF
  run bash "${JARVIS_DIR}/cmds/doctor/doctor.sh" --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"calendar"* ]]
  [[ "$output" == *"unknown provider"* ]]
  [[ "$output" == *"bogus"* ]]
  [[ "$output" == *"gcalcli"* ]]   # registered list mentions gcalcli + ics
  [[ "$output" == *"ics"* ]]
}

@test "doctor: gh missing reason points at install hint" {
  mkdir -p "$JARVIS_HOME/test"
  printf '1\n' > "$JARVIS_HOME/test/state.version"
  shim_setup
  # Mask system gh by restricting PATH to SHIM_DIR + the minimum needed for
  # bash + jq + dasel to resolve. SHIM_DIR has no gh, so command -v gh fails.
  PATH="$SHIM_DIR:/usr/local/bin:/usr/bin:/bin" \
    run bash "${JARVIS_DIR}/cmds/doctor/doctor.sh" --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"gh"* ]]
  [[ "$output" == *"missing"* ]]
  [[ "$output" == *"install"* ]]
}

@test "doctor: gh auth-required reason points at gh auth login" {
  mkdir -p "$JARVIS_HOME/test"
  printf '1\n' > "$JARVIS_HOME/test/state.version"
  shim_setup
  shim_install gh 'case "$1 $2" in "auth status") exit 1;; *) exit 0;; esac'
  run bash "${JARVIS_DIR}/cmds/doctor/doctor.sh" --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"gh"* ]]
  [[ "$output" == *"auth required"* ]]
  [[ "$output" == *"gh auth login"* ]]
}

@test "doctor: jira+gcalcli missing reasons point at install hints" {
  mkdir -p "$JARVIS_HOME/test"
  printf '1\n' > "$JARVIS_HOME/test/state.version"
  shim_setup
  shim_install gh 'exit 0'
  # No jira / gcalcli shims.
  run bash "${JARVIS_DIR}/cmds/doctor/doctor.sh" --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"jira"* ]]
  [[ "$output" == *"gcalcli"* ]]
  [[ "$output" == *"missing"* ]]
  [[ "$output" == *"install"* ]]
}

@test "doctor: focus.log warns on orphan starts (SIGKILL / power loss)" {
  mkdir -p "$JARVIS_HOME/test"
  printf '1\n' > "$JARVIS_HOME/test/state.version"
  source "$JARVIS_DIR/lib/state/profile.sh"
  source "$JARVIS_DIR/lib/state/lock.sh"
  source "$JARVIS_DIR/lib/state/ndjson.sh"
  source "$JARVIS_DIR/lib/focus/log.sh"
  focus_log_append start "25m" "killed-a"
  focus_log_append start "25m" "killed-b"
  focus_log_append start "1s"  "completed"
  focus_log_append end   ""    "completed"

  run bash "$JARVIS_DIR/cmds/doctor/doctor.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 orphan rows"* ]]
}

# ---- doctor --reap-focus-orphans (P3-design from .claude/known-bugs.md) ---

@test "doctor --reap-focus-orphans: synthesizes end rows for every orphan" {
  mkdir -p "$JARVIS_HOME/test"
  printf '1\n' > "$JARVIS_HOME/test/state.version"
  source "$JARVIS_DIR/lib/state/profile.sh"
  source "$JARVIS_DIR/lib/state/lock.sh"
  source "$JARVIS_DIR/lib/state/ndjson.sh"
  source "$JARVIS_DIR/lib/focus/log.sh"
  focus_log_append start "25m" "killed-a"
  focus_log_append start "25m" "killed-b"
  focus_log_append start "30m" ""           # null-topic orphan

  run bash "$JARVIS_DIR/cmds/doctor/doctor.sh" --reap-focus-orphans
  [ "$status" -eq 0 ]
  [[ "$output" == *"reaped 3 orphan focus starts"* ]]

  # Verify each start now has a matching end (zero orphans afterward).
  run bash "$JARVIS_DIR/cmds/doctor/doctor.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 orphan rows"* ]]
}

@test "doctor --reap-focus-orphans: no-op (idempotent) on a clean log" {
  mkdir -p "$JARVIS_HOME/test"
  printf '1\n' > "$JARVIS_HOME/test/state.version"
  source "$JARVIS_DIR/lib/state/profile.sh"
  source "$JARVIS_DIR/lib/state/lock.sh"
  source "$JARVIS_DIR/lib/state/ndjson.sh"
  source "$JARVIS_DIR/lib/focus/log.sh"
  focus_log_append start "25m" "complete"
  focus_log_append end   ""    "complete"

  run bash "$JARVIS_DIR/cmds/doctor/doctor.sh" --reap-focus-orphans
  [ "$status" -eq 0 ]
  [[ "$output" == *"reaped 0 orphan"* ]]
}
