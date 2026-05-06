#!/usr/bin/env bash
# Scheduler install/uninstall for jarvis remind tick.
#
# Two backends: `cron` (default, portable) and `systemd` (linux user units).
# Backend resolution: explicit `--backend` arg > `[scheduler] backend` in
# the active profile's config.toml > literal "cron".
#
# Idempotent on both axes:
#   - install when already installed: no-op (cron line already present;
#     systemd unit files unchanged → no rewrite, no daemon-reload).
#   - uninstall when not installed: no-op exit 0 (silent).
#
# Cron impl appends `* * * * * jarvis remind tick >/dev/null 2>&1` to the
# user's crontab. Detection sentinel is the literal substring
# `jarvis remind tick` so unrelated crontab entries are never touched.

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_REMIND_INSTALL_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_REMIND_INSTALL_LOADED=1

REMIND_INSTALL_CRON_LINE='* * * * * jarvis remind tick >/dev/null 2>&1'
REMIND_INSTALL_CRON_SENTINEL='jarvis remind tick'

remind_install_resolve_backend() {
  local explicit="${1:-}"
  if [[ -n "$explicit" ]]; then
    printf '%s\n' "$explicit"
    return 0
  fi
  config_get scheduler.backend cron
}

remind_install_validate_backend() {
  local backend="$1"
  case "$backend" in
    cron|systemd) return 0 ;;
    *)
      printf 'unknown backend "%s" (valid: cron, systemd)\n' "$backend" >&2
      return 2
      ;;
  esac
}

remind_install() {
  local backend="$1"
  remind_install_validate_backend "$backend" || return 2
  case "$backend" in
    cron)    _remind_install_cron ;;
    systemd) _remind_install_systemd ;;
  esac
}

remind_uninstall() {
  local backend="$1"
  remind_install_validate_backend "$backend" || return 2
  case "$backend" in
    cron)    _remind_uninstall_cron ;;
    systemd) _remind_uninstall_systemd ;;
  esac
}

# ---------- cron ----------

_remind_cron_current() {
  crontab -l 2>/dev/null || true
}

_remind_cron_installed() {
  _remind_cron_current | grep -q -F "$REMIND_INSTALL_CRON_SENTINEL"
}

_remind_install_cron() {
  if _remind_cron_installed; then
    log_info "cron: already installed"
    return 0
  fi
  # Capture current crontab to a string before writing — atomic-swap
  # implementations (real cron) are safe either way, but naive backends
  # can read-truncate themselves if the read and write share a pipeline.
  local current next
  current="$(_remind_cron_current)"
  if [[ -n "$current" ]]; then
    next="${current}"$'\n'"${REMIND_INSTALL_CRON_LINE}"
  else
    next="$REMIND_INSTALL_CRON_LINE"
  fi
  printf '%s\n' "$next" | crontab -
  log_success "cron: installed jarvis remind tick (every minute)"
}

_remind_uninstall_cron() {
  if ! _remind_cron_installed; then
    log_info "cron: nothing to uninstall"
    return 0
  fi
  local next
  # Capture-then-write so we don't pipe a file into itself (see install).
  # grep -v exits 1 when every line matches; tolerate that — empty result
  # is a valid (empty) crontab.
  next="$(_remind_cron_current | grep -v -F "$REMIND_INSTALL_CRON_SENTINEL" || true)"
  printf '%s\n' "$next" | crontab -
  log_success "cron: removed jarvis remind tick"
}

# ---------- systemd ----------

_remind_systemd_unit_dir() {
  printf '%s/.config/systemd/user\n' "$HOME"
}

_remind_systemd_service_path() {
  printf '%s/jarvis-tick.service\n' "$(_remind_systemd_unit_dir)"
}

_remind_systemd_timer_path() {
  printf '%s/jarvis-tick.timer\n' "$(_remind_systemd_unit_dir)"
}

_remind_systemd_installed() {
  [[ -f "$(_remind_systemd_service_path)" && -f "$(_remind_systemd_timer_path)" ]]
}

_remind_systemd_service_body() {
  cat <<'UNIT'
[Unit]
Description=jarvis remind tick

[Service]
Type=oneshot
ExecStart=%h/.local/bin/jarvis remind tick
UNIT
}

_remind_systemd_timer_body() {
  cat <<'UNIT'
[Unit]
Description=jarvis remind tick (every minute)

[Timer]
OnCalendar=*:0/1
Persistent=true

[Install]
WantedBy=timers.target
UNIT
}

# Write file only if content differs from desired. Returns 0 if rewritten,
# 1 if already correct (so the caller can skip daemon-reload on no-op).
_remind_write_if_changed() {
  local target="$1" desired="$2"
  if [[ -f "$target" ]]; then
    local current
    current="$(<"$target")"
    if [[ "$current" == "$desired" ]]; then
      return 1
    fi
  fi
  mkdir -p "$(dirname "$target")"
  local tmp="${target}.tmp.$$"
  printf '%s' "$desired" > "$tmp"
  mv "$tmp" "$target"
  return 0
}

_remind_install_systemd() {
  local svc timer
  svc="$(_remind_systemd_service_path)"
  timer="$(_remind_systemd_timer_path)"

  local svc_body timer_body
  svc_body="$(_remind_systemd_service_body)"
  timer_body="$(_remind_systemd_timer_body)"

  local changed=0
  _remind_write_if_changed "$svc"   "$svc_body"   && changed=1
  _remind_write_if_changed "$timer" "$timer_body" && changed=1

  if (( changed == 0 )); then
    log_info "systemd: already installed"
    return 0
  fi

  systemctl --user daemon-reload
  systemctl --user enable --now jarvis-tick.timer
  log_success "systemd: installed jarvis-tick.timer (every minute)"
}

_remind_uninstall_systemd() {
  local svc timer
  svc="$(_remind_systemd_service_path)"
  timer="$(_remind_systemd_timer_path)"

  if [[ ! -f "$svc" && ! -f "$timer" ]]; then
    log_info "systemd: nothing to uninstall"
    return 0
  fi

  systemctl --user disable --now jarvis-tick.timer || true
  rm -f "$svc" "$timer"
  systemctl --user daemon-reload || true
  log_success "systemd: removed jarvis-tick.timer"
}
