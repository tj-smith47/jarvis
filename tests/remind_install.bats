#!/usr/bin/env bats
# T14 — cmds/remind/remind.{install,uninstall}.sh + lib/remind/install.sh
# (cron backend). T15 will append systemd-backend tests.
#
# Tests use a PATH-shimmed `crontab` so the real user crontab is never
# touched. The shim backs the user's crontab with $TEST_DIR/fake.crontab so
# install/uninstall behaviour is observable.

bats_require_minimum_version 1.5.0

load 'helper'
load 'shim_helper'

setup() {
  jarvis_common_setup
  # jarvis_common_setup leaves TEST_DIR un-exported; shimmed subprocesses
  # need it in their env to find $TEST_DIR/fake.crontab.
  export TEST_DIR
  shim_setup
  # shellcheck source=/dev/null
  source "${JARVIS_DIR}/lib/state/profile.sh"
  state_ensure_tree

  # Fake crontab. Mirrors enough of `crontab` for install/uninstall:
  #   crontab -l   → cat the file (or exit 1 = "no crontab for user")
  #   crontab -    → read stdin into the file
  #   crontab -r   → remove the file
  shim_install crontab '
fake="$TEST_DIR/fake.crontab"
case "${1:-}" in
  -l)
    if [[ -f "$fake" ]]; then cat "$fake"; else exit 1; fi
    ;;
  -r)
    rm -f "$fake"
    ;;
  -)
    cat > "$fake"
    ;;
  *)
    cat > "$fake"
    ;;
esac
'
}

teardown() {
  jarvis_common_teardown
}

_install() {
  bash "${JARVIS_DIR}/cmds/remind/remind.install.sh" "$@"
}

_uninstall() {
  bash "${JARVIS_DIR}/cmds/remind/remind.uninstall.sh" "$@"
}

# ---------- cron backend ----------

@test "install (cron) adds the tick line to crontab" {
  run _install
  [ "$status" -eq 0 ]
  [ -f "$TEST_DIR/fake.crontab" ]
  grep -F 'jarvis remind tick' "$TEST_DIR/fake.crontab"
}

@test "install (cron) is idempotent — second run leaves single line" {
  run _install
  [ "$status" -eq 0 ]
  run _install
  [ "$status" -eq 0 ]
  count="$(grep -c -F 'jarvis remind tick' "$TEST_DIR/fake.crontab")"
  [ "$count" = "1" ]
}

@test "install (cron) preserves existing unrelated crontab entries" {
  printf '%s\n' '0 9 * * * other-job' > "$TEST_DIR/fake.crontab"
  run _install
  [ "$status" -eq 0 ]
  grep -F 'other-job' "$TEST_DIR/fake.crontab"
  grep -F 'jarvis remind tick' "$TEST_DIR/fake.crontab"
}

@test "uninstall (cron) removes only the tick line" {
  printf '%s\n' '0 9 * * * other-job' > "$TEST_DIR/fake.crontab"
  run _install
  [ "$status" -eq 0 ]
  run _uninstall
  [ "$status" -eq 0 ]
  grep -F 'other-job' "$TEST_DIR/fake.crontab"
  ! grep -F 'jarvis remind tick' "$TEST_DIR/fake.crontab"
}

@test "uninstall (cron) on clean crontab is a no-op exit 0" {
  run _uninstall
  [ "$status" -eq 0 ]
}

# ---------- backend resolution ----------

@test "config [scheduler].backend = cron is honoured by default" {
  cat > "$JARVIS_HOME/test/config.toml" <<EOF
[scheduler]
backend = "cron"
EOF
  run _install
  [ "$status" -eq 0 ]
  grep -F 'jarvis remind tick' "$TEST_DIR/fake.crontab"
}

@test "--backend cron explicit override works" {
  run _install --backend cron
  [ "$status" -eq 0 ]
  grep -F 'jarvis remind tick' "$TEST_DIR/fake.crontab"
}

@test "--backend bogus exits 2 with usage hint" {
  run _install --backend xyz
  [ "$status" -eq 2 ]
  [[ "$output" == *"backend"* ]]
  [[ "$output" == *"cron"* ]]
}

# ---------- systemd backend (T15) ----------

@test "install (systemd) writes service + timer files and runs systemctl" {
  shim_install systemctl 'echo "systemctl: $*" >> "$0.log"; exit 0'
  run _install --backend systemd
  [ "$status" -eq 0 ]
  [ -f "$HOME/.config/systemd/user/jarvis-tick.service" ]
  [ -f "$HOME/.config/systemd/user/jarvis-tick.timer" ]
  log="$(shim_log_path systemctl)"
  [ -f "$log" ]
  grep -F -- '--user daemon-reload' "$log"
  grep -F -- '--user enable --now jarvis-tick.timer' "$log"
}

@test "install (systemd) is idempotent — second run does not rewrite unchanged files" {
  shim_install systemctl 'echo "systemctl: $*" >> "$0.log"; exit 0'
  run _install --backend systemd
  [ "$status" -eq 0 ]
  svc="$HOME/.config/systemd/user/jarvis-tick.service"
  before_mtime="$(stat -c %Y "$svc" 2>/dev/null || stat -f %m "$svc")"
  sleep 1
  run _install --backend systemd
  [ "$status" -eq 0 ]
  after_mtime="$(stat -c %Y "$svc" 2>/dev/null || stat -f %m "$svc")"
  [ "$before_mtime" = "$after_mtime" ]
}

@test "install (systemd) rewrites file when content changed" {
  shim_install systemctl 'echo "systemctl: $*" >> "$0.log"; exit 0'
  run _install --backend systemd
  [ "$status" -eq 0 ]
  svc="$HOME/.config/systemd/user/jarvis-tick.service"
  printf '%s\n' 'tampered' > "$svc"
  run _install --backend systemd
  [ "$status" -eq 0 ]
  ! grep -F 'tampered' "$svc"
  grep -F 'jarvis remind tick' "$svc"
}

@test "uninstall (systemd) disables timer and removes both files" {
  shim_install systemctl 'echo "systemctl: $*" >> "$0.log"; exit 0'
  run _install --backend systemd
  [ "$status" -eq 0 ]
  run _uninstall --backend systemd
  [ "$status" -eq 0 ]
  [ ! -f "$HOME/.config/systemd/user/jarvis-tick.service" ]
  [ ! -f "$HOME/.config/systemd/user/jarvis-tick.timer" ]
  log="$(shim_log_path systemctl)"
  grep -F -- '--user disable --now jarvis-tick.timer' "$log"
}

@test "uninstall (systemd) on clean state is a no-op exit 0" {
  shim_install systemctl 'echo "systemctl: $*" >> "$0.log"; exit 0'
  run _uninstall --backend systemd
  [ "$status" -eq 0 ]
}

@test "config [scheduler].backend = systemd routes default install" {
  shim_install systemctl 'echo "systemctl: $*" >> "$0.log"; exit 0'
  cat > "$JARVIS_HOME/test/config.toml" <<EOF
[scheduler]
backend = "systemd"
EOF
  run _install
  [ "$status" -eq 0 ]
  [ -f "$HOME/.config/systemd/user/jarvis-tick.timer" ]
  [ ! -f "$TEST_DIR/fake.crontab" ]
}
