#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

load helper

setup() {
  jarvis_common_setup
  source "$JARVIS_DIR/lib/state/profile.sh"
  source "$JARVIS_DIR/lib/state/lock.sh"
  source "$JARVIS_DIR/lib/state/ndjson.sh"
  source "$JARVIS_DIR/lib/focus/log.sh"
  LOG="$(focus_log_path)"
}
teardown() { jarvis_common_teardown; }

# Run focus.sh in a fresh subprocess so CLIFT_FLAGS / CLIFT_POS_* are
# parsed from argv via the standalone fallback. PATH-strip suppresses the
# gum spinner so tests don't hang on a TTY-less spinner; we bypass it by
# unsetting PATH binaries — easier: pass --silent which skips gum.
run_focus() {
  env -i \
    HOME="$HOME" PATH="$PATH" \
    JARVIS_HOME="$JARVIS_HOME" JARVIS_PROFILE="$JARVIS_PROFILE" \
    CLI_DIR="$JARVIS_DIR" FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR" \
    bash "$JARVIS_DIR/cmds/focus/focus.sh" "$@"
}

# NOTES on the signal-driven tests below:
#
# 1. Inline the spawn in each test — a `pid="$(spawn ...)"` helper would
#    run inside command substitution, the script gets reparented when
#    that subshell exits, and `wait $pid` then blocks forever.
#
# 2. Use `setsid` to put the spawned bash in its own session/pgroup,
#    then signal the pgroup with `kill -- -$pid`. Bats runs without job
#    control (`set -m` off), so backgrounded children share the test
#    shell's process group; `kill -TERM $pid` reaches bash but bash is
#    blocked in `sleep` and won't propagate, so the test hangs until
#    the 25m sleep returns. setsid + pgroup-kill mirrors how an
#    interactive terminal delivers Ctrl+C to the whole foreground group.

# ---- argv validation ----------------------------------------------------

@test "focus: missing duration → exit 2" {
  run run_focus
  [ "$status" -eq 2 ]
}

@test "focus: invalid duration shape → exit 2" {
  run run_focus 25minutes
  [ "$status" -eq 2 ]
}

@test "focus: valid units accepted" {
  run run_focus 1s --silent
  [ "$status" -eq 0 ]
}

# ---- happy path ---------------------------------------------------------

@test "focus 1s --on demo --silent: writes start + end with topic" {
  run run_focus 1s --on demo --silent
  [ "$status" -eq 0 ]
  [ -f "$LOG" ]
  [ "$(jq -s 'length' "$LOG")" -eq 2 ]
  [ "$(jq -r 'select(.event=="start") | .topic' "$LOG" | head -1)"    = "demo" ]
  [ "$(jq -r 'select(.event=="start") | .duration' "$LOG" | head -1)" = "1s" ]
  [ "$(jq -r 'select(.event=="end")   | .topic' "$LOG" | head -1)"    = "demo" ]
}

@test "focus 1s (no --on, non-git cwd): topic is JSON null in both rows" {
  # cwd matters: git-repo cwds get auto-defaulted to repo:branch via the
  # focus.sh git fallback. Pin a non-git cwd so this test stays about the
  # null-topic-when-no-data path specifically.
  cd "$TEST_DIR"
  run run_focus 1s --silent
  [ "$status" -eq 0 ]
  [ "$(jq -sc '[.[].topic] | unique' "$LOG")" = "[null]" ]
}

# ---- EXIT trap on SIGTERM ----------------------------------------------
#
# We send SIGTERM rather than SIGINT here for a process-group reason: the
# bats test shell runs without job control, so a backgrounded `bash
# focus.sh ...` shares its parent's process group. `kill -INT $pid` reaches
# bash but not the child `sleep` it's blocked on, so bash queues the INT
# until sleep returns naturally — minutes later. SIGTERM kills sleep
# directly, bash exits with 143, and the EXIT trap fires the same way it
# would under interactive Ctrl+C (terminal delivers INT to the whole pgrp).
# The trap's behavior is identical for INT/TERM/HUP — what we're really
# verifying is "EXIT trap writes the end row no matter how the shell exits."

@test "focus interrupted by SIGTERM: end row still written" {
  setsid env -i \
    HOME="$HOME" PATH="$PATH" \
    JARVIS_HOME="$JARVIS_HOME" JARVIS_PROFILE="$JARVIS_PROFILE" \
    CLI_DIR="$JARVIS_DIR" FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR" \
    bash "$JARVIS_DIR/cmds/focus/focus.sh" 25m --on interrupted --silent \
    >/dev/null 2>&1 &
  local pid=$!

  # Poll for the start row to land before signaling — robust against
  # scheduler jitter without a fixed sleep.
  local tries=0
  until [[ -s "$LOG" ]]; do
    tries=$((tries + 1))
    (( tries > 50 )) && break
    sleep 0.1
  done
  [ -s "$LOG" ]

  kill -TERM -- -"$pid"
  wait "$pid" 2>/dev/null || true

  [ "$(jq -rs 'map(select(.event=="end")) | length' "$LOG")" -eq 1 ]
  [ "$(jq -r 'select(.event=="end") | .topic' "$LOG" | head -1)" = "interrupted" ]
}

# ---- SIGKILL leaves an orphan start ------------------------------------

@test "focus killed with SIGKILL: orphan start, no end" {
  setsid env -i \
    HOME="$HOME" PATH="$PATH" \
    JARVIS_HOME="$JARVIS_HOME" JARVIS_PROFILE="$JARVIS_PROFILE" \
    CLI_DIR="$JARVIS_DIR" FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR" \
    bash "$JARVIS_DIR/cmds/focus/focus.sh" 25m --on orphan --silent \
    >/dev/null 2>&1 &
  local pid=$!
  local tries=0
  until [[ -s "$LOG" ]]; do
    tries=$((tries + 1))
    (( tries > 50 )) && break
    sleep 0.1
  done
  [ -s "$LOG" ]

  kill -KILL -- -"$pid"
  wait "$pid" 2>/dev/null || true

  # SIGKILL is uncatchable — only the start row exists.
  [ "$(jq -rs 'map(select(.event=="start")) | length' "$LOG")" -eq 1 ]
  [ "$(jq -rs 'map(select(.event=="end")) | length' "$LOG")" -eq 0 ]

  # focus_orphan_starts surfaces it.
  source "$JARVIS_DIR/lib/state/ndjson.sh"
  source "$JARVIS_DIR/lib/focus/log.sh"
  run focus_orphan_starts
  [ "$(echo "$output" | jq -r '.topic')" = "orphan" ]
}

@test "focus auto-defaults topic to <repo>:<branch> when --on omitted in a git repo" {
  REPO="$TEST_DIR/myproj"
  mkdir -p "$REPO"
  ( cd "$REPO" && git init -q --initial-branch=feat-auto-topic \
    && git config user.email a@b.com && git config user.name a )
  cd "$REPO" && run_focus 1s --silent
  cd "$JARVIS_DIR"
  local log="$JARVIS_HOME/test/focus.log"
  [ -f "$log" ]
  [ "$(jq -r 'select(.event=="start") | .topic' "$log" | head -1)" = "myproj:feat-auto-topic" ]
}

@test "focus --on explicit beats the git-branch auto-default" {
  REPO="$TEST_DIR/myproj"
  mkdir -p "$REPO"
  ( cd "$REPO" && git init -q --initial-branch=auto && git config user.email a@b.com && git config user.name a )
  cd "$REPO" && run_focus 1s --on explicit-topic --silent
  cd "$JARVIS_DIR"
  local log="$JARVIS_HOME/test/focus.log"
  [ "$(jq -r 'select(.event=="start") | .topic' "$log" | head -1)" = "explicit-topic" ]
}

@test "focus in a non-git cwd leaves topic empty when --on omitted" {
  # No git repo at cwd — fallback chain doesn't fire, topic stays null.
  cd "$TEST_DIR" && run_focus 1s --silent
  cd "$JARVIS_DIR"
  local log="$JARVIS_HOME/test/focus.log"
  # Topic is null in NDJSON when unset (focus_log_append uses null for empty).
  [ "$(jq -r 'select(.event=="start") | .topic' "$log" | head -1)" = "null" ]
}
