#!/usr/bin/env bats
# `jarvis cleanup install` — daily cron line wiring. Same shim pattern as
# brief_install.bats; touches only $TEST_DIR/fake.crontab.

bats_require_minimum_version 1.5.0

load 'helper'
load 'shim_helper'

setup() {
  jarvis_common_setup
  shim_setup
  mkdir -p "$JARVIS_HOME/test"
  printf '1\n' > "$JARVIS_HOME/test/state.version"
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
    bash "$JARVIS_DIR/cmds/cleanup/cleanup.install.sh" "$@"
}

@test "cleanup install --dry-run prints cron line at default 03:00" {
  run _run_install --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == "0 3 * * * "*"jarvis cleanup --confirm --before 90d"*"JARVIS_CLEANUP_DAILY"* ]]
}

@test "cleanup install --before 30d --dry-run reflects retention" {
  run _run_install --before 30d --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"--before 30d"* ]]
}

@test "cleanup install rejects malformed --before with exit 2" {
  run _run_install --before forever --dry-run
  [ "$status" -eq 2 ]
}

@test "cleanup install rejects malformed --at with exit 2" {
  run _run_install --at noon --dry-run
  [ "$status" -eq 2 ]
}

@test "cleanup install writes cron line; --uninstall removes it" {
  run _run_install --at 03:00
  [ "$status" -eq 0 ]
  grep -qF 'JARVIS_CLEANUP_DAILY' "$TEST_DIR/fake.crontab"

  run _run_install --uninstall
  [ "$status" -eq 0 ]
  if [[ -e "$TEST_DIR/fake.crontab" ]]; then
    [ "$(grep -cF 'JARVIS_CLEANUP_DAILY' "$TEST_DIR/fake.crontab")" = "0" ]
  fi
}

@test "cleanup install replaces existing cron line on re-run" {
  _run_install --at 03:00 >/dev/null
  run _run_install --at 04:30
  [ "$status" -eq 0 ]
  [ "$(grep -cF 'JARVIS_CLEANUP_DAILY' "$TEST_DIR/fake.crontab")" = "1" ]
  grep -qE '^30 4 \* \* \*' "$TEST_DIR/fake.crontab"
}
