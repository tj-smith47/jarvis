#!/usr/bin/env bats
# `jarvis brief install` — daily-fire cron line wiring. Tests use a shimmed
# crontab so the real user crontab is never touched (see jarvis_common_setup
# tripwire — even with shim, the bats helper would fail loudly if real
# $HOME got mutated).

bats_require_minimum_version 1.5.0

load 'helper'
load 'shim_helper'

setup() {
  jarvis_common_setup
  shim_setup
  mkdir -p "$JARVIS_HOME/test"
  printf '1\n' > "$JARVIS_HOME/test/state.version"
  # Minimal crontab shim mirroring the remind.install tests: -l reads
  # from $TEST_DIR/fake.crontab, anything else writes to it.
  shim_install crontab '
fake="$TEST_DIR/fake.crontab"
case "${1:-}" in
  -l) cat "$fake" 2>/dev/null || exit 1 ;;
  -r) rm -f "$fake" ;;
  *)  cat > "$fake" ;;
esac'
}
teardown() { jarvis_common_teardown; }

_run_install() {
  TEST_DIR="$TEST_DIR" \
  FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR" CLI_DIR="$JARVIS_DIR" \
    bash "$JARVIS_DIR/cmds/brief/brief.install.sh" "$@"
}

@test "install --dry-run prints cron line at default 08:00" {
  run _run_install --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == "0 8 * * * "*"jarvis brief --short --profile test"*"JARVIS_BRIEF_DAILY"* ]]
  [ ! -e "$TEST_DIR/fake.crontab" ]
}

@test "install --at 07:30 --dry-run reflects the time" {
  run _run_install --at 07:30 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == "30 7 * * * "* ]]
}

@test "install --at 17:45 --notify gotify --dry-run" {
  run _run_install --at 17:45 --notify gotify --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == "45 17 * * * "* ]]
  [[ "$output" == *"--notify gotify"* ]]
}

@test "install rejects malformed --at with exit 2" {
  run _run_install --at 99:99 --dry-run
  [ "$status" -eq 2 ]
}

@test "install rejects unknown --notify channel with exit 2" {
  run _run_install --notify carrier-pigeon --dry-run
  [ "$status" -eq 2 ]
}

@test "install writes the cron line to the user's crontab" {
  run _run_install --at 08:00
  [ "$status" -eq 0 ]
  grep -qF 'JARVIS_BRIEF_DAILY' "$TEST_DIR/fake.crontab"
  grep -qE '^0 8 \* \* \*' "$TEST_DIR/fake.crontab"
}

@test "install replaces the existing cron line when re-run with new time" {
  _run_install --at 08:00 >/dev/null
  run _run_install --at 09:30
  [ "$status" -eq 0 ]
  # Only one JARVIS_BRIEF_DAILY line in the crontab after re-install.
  [ "$(grep -cF 'JARVIS_BRIEF_DAILY' "$TEST_DIR/fake.crontab")" = "1" ]
  grep -qE '^30 9 \* \* \*' "$TEST_DIR/fake.crontab"
}

@test "install --uninstall removes the cron line" {
  _run_install --at 08:00 >/dev/null
  run _run_install --uninstall
  [ "$status" -eq 0 ]
  if [[ -e "$TEST_DIR/fake.crontab" ]]; then
    [ "$(grep -cF 'JARVIS_BRIEF_DAILY' "$TEST_DIR/fake.crontab")" = "0" ]
  fi
}

@test "install --uninstall when not installed: silent no-op exit 0" {
  run _run_install --uninstall
  [ "$status" -eq 0 ]
}

@test "install preserves unrelated cron lines on add + remove" {
  printf '* * * * * other-thing\n' > "$TEST_DIR/fake.crontab"
  _run_install --at 08:00 >/dev/null
  grep -qF 'other-thing' "$TEST_DIR/fake.crontab"
  grep -qF 'JARVIS_BRIEF_DAILY' "$TEST_DIR/fake.crontab"

  _run_install --uninstall >/dev/null
  grep -qF 'other-thing' "$TEST_DIR/fake.crontab"
  ! grep -qF 'JARVIS_BRIEF_DAILY' "$TEST_DIR/fake.crontab"
}
