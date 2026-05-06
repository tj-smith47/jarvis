#!/usr/bin/env bats
# Persistent --profile flag honored by every cmd that reads/writes state.
#
# The persistent flag is declared on the root Taskfile and exported by the
# parser as CLIFT_FLAGS[profile] (assoc array, in-shell) plus
# CLIFT_FLAG_PROFILE (env, subshells). Every cmd routes its state I/O
# through state_profile_dir(), so pinning the precedence centrally is
# enough — no per-cmd translation needed.
#
# These tests pin the contract: setting CLIFT_FLAGS[profile]="work" must
# land state writes under $JARVIS_HOME/work, *not* the test default
# ($JARVIS_HOME/test).

bats_require_minimum_version 1.5.0

load 'helper'

setup() {
  jarvis_common_setup
  mkdir -p "$JARVIS_HOME/work" "$JARVIS_HOME/home"
  printf '1\n' > "$JARVIS_HOME/work/state.version"
  printf '1\n' > "$JARVIS_HOME/home/state.version"
}
teardown() { jarvis_common_teardown; }

# Run a cmd script with CLIFT_FLAGS pre-populated (router-pipeline shape).
# Assoc arrays don't export across env, so we declare in a heredoc'd subshell.
_invoke_with_profile() {
  local script="$1" profile="$2"; shift 2
  FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR" \
  CLI_DIR="$JARVIS_DIR" \
  bash -c '
    set -euo pipefail
    declare -A CLIFT_FLAGS=([profile]="'"$profile"'")
    source "$1"
  ' _ "$script" "$@"
}

# ---- state_profile_dir picks up CLIFT_FLAGS[profile] ----

@test "state_profile_dir honors CLIFT_FLAGS[profile]" {
  declare -A CLIFT_FLAGS=([profile]=work)
  source "$JARVIS_DIR/lib/state/profile.sh"
  local dir
  dir="$(state_profile_dir)"
  [ "$dir" = "$JARVIS_HOME/work" ]
}

@test "state_profile_dir honors CLIFT_FLAG_PROFILE env (subshell case)" {
  source "$JARVIS_DIR/lib/state/profile.sh"
  CLIFT_FLAG_PROFILE=home run state_profile_dir
  [ "$status" -eq 0 ]
  [ "$output" = "$JARVIS_HOME/home" ]
}

@test "state_profile_dir falls back to JARVIS_PROFILE when no flag set" {
  source "$JARVIS_DIR/lib/state/profile.sh"
  unset CLIFT_FLAGS CLIFT_FLAG_PROFILE 2>/dev/null || true
  JARVIS_PROFILE=test run state_profile_dir
  [ "$status" -eq 0 ]
  [ "$output" = "$JARVIS_HOME/test" ]
}

# ---- task / note / focus / coffee writes land in the flagged profile ----

@test "task add --profile work writes to work profile, not default" {
  mkdir -p "$JARVIS_HOME/work/tasks"
  FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR" CLI_DIR="$JARVIS_DIR" \
    bash -c '
      set -euo pipefail
      declare -A CLIFT_FLAGS=([profile]=work [priority]=med [project]=inbox)
      export CLIFT_POS_1="walk dog"
      source "$1"
    ' _ "$JARVIS_DIR/cmds/task/task.add.sh"
  [ -f "$JARVIS_HOME/work/tasks/walk-dog.json" ]
  [ ! -f "$JARVIS_HOME/test/tasks/walk-dog.json" ]
}

@test "coffee --profile home appends to home/focus.log" {
  mkdir -p "$JARVIS_HOME/home"
  printf '1\n' > "$JARVIS_HOME/home/state.version"
  FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR" CLI_DIR="$JARVIS_DIR" \
    bash -c '
      set -euo pipefail
      declare -A CLIFT_FLAGS=([profile]=home)
      source "$1"
    ' _ "$JARVIS_DIR/cmds/coffee/coffee.sh"
  [ -f "$JARVIS_HOME/home/focus.log" ]
}

@test "focus --profile work writes start row to work/focus.log" {
  # Duration is positional 1; topic via --on. Use 1s so the sleep is trivial.
  FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR" CLI_DIR="$JARVIS_DIR" \
    bash -c '
      set -euo pipefail
      declare -A CLIFT_FLAGS=([profile]=work [on]="quick-task" [silent]=true)
      export CLIFT_POS_1="1s"
      source "$1"
    ' _ "$JARVIS_DIR/cmds/focus/focus.sh" >/dev/null 2>&1 || true
  [ -f "$JARVIS_HOME/work/focus.log" ]
}

@test "remind list --profile work reads work/reminders/" {
  mkdir -p "$JARVIS_HOME/work/reminders"
  jq -nc '{slug:"x", message:"x", profile:"work", trigger_at:"2026-04-26T15:00:00Z",
           via:["local"], status:"pending", repeat:"", anchor_at:"", until:"",
           count_remaining:null, created_at:"2026-04-26T14:00:00Z",
           fire_count:0, last_fired_at:""}' \
    > "$JARVIS_HOME/work/reminders/x.json"
  run bash -c '
    set -euo pipefail
    declare -A CLIFT_FLAGS=([profile]=work)
    source "$1"
  ' _ "$JARVIS_DIR/cmds/remind/remind.list.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"x"* ]]
}

@test "note new --profile work creates note under work/notes/" {
  FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR" CLI_DIR="$JARVIS_DIR" \
    bash -c '
      set -euo pipefail
      declare -A CLIFT_FLAGS=([profile]=work [folder]=inbox)
      export CLIFT_POS_1="planning"
      source "$1"
    ' _ "$JARVIS_DIR/cmds/note/note.new.sh"
  shopt -s nullglob
  files=("$JARVIS_HOME/work/notes/inbox"/*.md)
  shopt -u nullglob
  (( ${#files[@]} >= 1 ))
}
