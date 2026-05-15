#!/usr/bin/env bash
set -euo pipefail

# Resolve framework/CLI dirs with fallback so this script runs standalone in tests.
: "${FRAMEWORK_DIR:=${CLIFT_FRAMEWORK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}}"
: "${CLI_DIR:=${JARVIS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"

# shellcheck source=/dev/null
source "${FRAMEWORK_DIR}/lib/log/log.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/profile.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/native/clock.sh"

# Flag resolution: prefer pre-populated CLIFT_FLAGS (router pipeline);
# otherwise parse argv ourselves so direct-invocation tests get identical
# semantics. --profile is honored by exporting JARVIS_PROFILE.
if ! declare -p CLIFT_FLAGS >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/runtime/standalone_argv.sh"
  jarvis_standalone_argv_parse \
    '[{"name":"migrate","type":"bool"},
      {"name":"path","type":"bool"},
      {"name":"rebuild-index","type":"bool"},
      {"name":"integrations-live","type":"bool"},
      {"name":"reap-focus-orphans","type":"bool"},
      {"name":"profile","type":"string"}]' \
    "$@"
  if [[ -n "${CLIFT_FLAGS[profile]:-}" ]]; then
    export JARVIS_PROFILE="${CLIFT_FLAGS[profile]}"
  fi
fi

path_flag="${CLIFT_FLAGS[path]:-}"
rebuild_flag="${CLIFT_FLAGS[rebuild-index]:-}"
live_flag="${CLIFT_FLAGS[integrations-live]:-}"
reap_flag="${CLIFT_FLAGS[reap-focus-orphans]:-}"

state_dir="$(state_profile_dir)"

if [[ "$path_flag" == "true" ]]; then
  printf '%s\n' "$state_dir"
  exit 0
fi

if [[ "$rebuild_flag" == "true" ]]; then
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/state/lock.sh"
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/state/json.sh"
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/frontmatter.sh"
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/note/resolve.sh"
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/note/index.sh"

  state_ensure_tree
  note_index_rebuild
  count="$(jq -r 'keys | length' "$(note_index_file)" 2>/dev/null || printf '0')"
  log_success "rebuilt note index: $count notes"
  exit 0
fi

# --reap-focus-orphans (P3-design from .claude/known-bugs.md)
# Walks focus_orphan_starts() output, appends a synthesized `end` row for
# each — start_ts + 1s, topic preserved. SIGKILL / power-loss recovery.
# Idempotent: a second run finds zero orphans (because the first run
# matched them all).
if [[ "$reap_flag" == "true" ]]; then
  focus_log="$state_dir/focus.log"
  if [[ ! -f "$focus_log" ]]; then
    log_info "no focus.log to reap"
    exit 0
  fi
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/state/lock.sh"
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/state/ndjson.sh"
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/focus/log.sh"
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/native/clock.sh"

  reaped=0
  while IFS= read -r orphan; do
    [[ -z "$orphan" ]] && continue
    start_ts="$(jq -r '.ts' <<< "$orphan")"
    topic="$(jq -r '.topic // empty' <<< "$orphan")"
    start_e="$(native_resolve_to_epoch "$start_ts")" || continue
    end_e=$(( start_e + 1 ))
    end_ts="$(native_epoch_to_iso "$end_e")"
    end_row="$(jq -nc \
      --arg ts "$end_ts" \
      --arg topic "$topic" \
      '{ts: $ts, event: "end",
        topic: (if $topic == "" then null else $topic end)}')"
    ndjson_append "$focus_log" "$end_row"
    reaped=$((reaped + 1))
  done < <(focus_orphan_starts)
  log_success "reaped $reaped orphan focus starts"
  exit 0
fi

printf '%-15s %-20s %s\n' "profile" "${JARVIS_PROFILE:-default}" "state at $state_dir"

# Red counter — incremented for any signal that warrants a non-zero exit
# (so `jarvis doctor` can gate CI on broken state). Conservative definition:
# state corruption, missing REQUIRED bin, scheduler installed-but-stale,
# calendar typo, and live-probe failures count as red. Missing optional
# bins / integrations are surfaced with a yellow warn marker and a fix hint
# but do NOT contribute to red — the user has opted out by not configuring
# them.
_doctor_red=0

if [[ -f "$state_dir/state.version" ]]; then
  schema_raw="$(< "$state_dir/state.version")"
  if [[ "$schema_raw" =~ ^[0-9]+$ ]]; then
    printf '%-15s %-20s %s\n' "state schema" "v$schema_raw" "up to date"
  else
    printf '\u2717 %-13s %-20s %s\n' "state schema" "corrupt" \
      "state.version is not a number — delete and re-run any jarvis command"
    _doctor_red=$((_doctor_red + 1))
  fi
else
  printf '%-15s %-20s %s\n' "state schema" "uninitialized" "run any jarvis command once to initialize"
fi

# Per-binary version probe — some tools (dasel) expose version via subcommand, not --flag.
probe_version() {
  case "$1" in
    dasel) dasel version 2>/dev/null | head -1 ;;
    *)     "$1" --version 2>&1 | head -1 ;;
  esac
}

# REQUIRED bins — jarvis cannot function without these. jq is used in every
# integration; curl is needed for gotify/slack notify channels; git underlies
# standup. A missing required bin is RED.
for bin in jq curl git; do
  if command -v "$bin" >/dev/null 2>&1; then
    ver="$(probe_version "$bin" || true)"
    printf '\u2713 %-13s %-20s %s\n' "$bin" "$ver" "available"
  else
    printf '\u2717 %-13s %-20s %s\n' "$bin" "missing" "install $bin (required)"
    _doctor_red=$((_doctor_red + 1))
  fi
done

# OPTIONAL bins — degrade gracefully when missing. dasel is needed for
# array-shaped TOML reads (standup --all-repos); rg / glow speed up notes
# search/render but grep / cat substitute; task is the clift router driver
# but standalone scripts work without it. Missing → warn, no red contribution.
for bin in dasel rg glow task; do
  if command -v "$bin" >/dev/null 2>&1; then
    ver="$(probe_version "$bin" || true)"
    printf '\u2713 %-13s %-20s %s\n' "$bin" "$ver" "available"
  else
    printf '\u26a0 %-13s %-20s %s\n' "$bin" "missing" "install $bin (optional)"
  fi
done

# reminders rollup + scheduler check (T16)
# Counts derive from per-item JSON files (pending/active) and the NDJSON
# delivery log (delivered/failed). Scheduler line reports the configured
# backend's install state plus a stale-tick warning when the heartbeat is
# older than 5 minutes (catches "cron line installed but crond not running"
# or "systemd timer disabled").
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/config.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/remind/install.sh"

_doctor_count_status() {
  local dir="$1" status="$2"
  shopt -s nullglob
  local files=( "$dir"/reminders/*.json )
  shopt -u nullglob
  if (( ${#files[@]} == 0 )); then
    printf '0\n'; return 0
  fi
  jq -s --arg s "$status" '[.[] | select(.status == $s)] | length' \
    "${files[@]}" 2>/dev/null || printf '0\n'
}

_doctor_count_delivery() {
  local log="$1" cond="$2"
  if [[ ! -f "$log" ]]; then
    printf '0\n'; return 0
  fi
  jq -c "select($cond)" < "$log" 2>/dev/null | wc -l | tr -d ' '
}

_doctor_last_heartbeat() {
  local log="$1"
  [[ -f "$log" ]] || return 1
  local ts
  ts="$(jq -r 'select(.kind == "tick.heartbeat") | .ts' < "$log" 2>/dev/null \
        | tail -n 1)"
  [[ -n "$ts" ]] || return 1
  printf '%s\n' "$ts"
}

_doctor_now_epoch() {
  # Single source of truth: native_now_epoch honors JARVIS_FAKE_NOW and
  # JARVIS_TODAY via the jarvis-when binary, with no bilateral date math.
  native_now_epoch
}

_doctor_format_age() {
  local secs="$1"
  if (( secs < 60 )); then
    printf '%ds ago' "$secs"
  elif (( secs < 3600 )); then
    printf '%dm ago' $((secs / 60))
  else
    printf '%dh ago' $((secs / 3600))
  fi
}

# Emits the scheduler line on stdout and returns 1 when stale (so the
# caller can increment _doctor_red \u2014 modifying it inside this function
# would die with the $(...) subshell that captures stdout).
_doctor_scheduler_line() {
  local backend="$1" log="$2"
  local installed=1 last_iso last_e now_e age
  case "$backend" in
    cron)    _remind_cron_installed    && installed=0 ;;
    systemd) _remind_systemd_installed && installed=0 ;;
    *)       printf '%s NOT installed (unknown backend)\n' "$backend"; return 0 ;;
  esac

  if (( installed != 0 )); then
    # shellcheck disable=SC2016  # backticks here are literal markdown, not subshells
    printf '%s NOT installed \u2014 run `jarvis remind install`\n' "$backend"
    return 0
  fi

  if last_iso="$(_doctor_last_heartbeat "$log")"; then
    last_e="$(native_resolve_to_epoch "$last_iso" 2>/dev/null || printf '0')"
    now_e="$(_doctor_now_epoch)"
    age=$((now_e - last_e))
    if (( age > 300 )); then
      # Stale tick = scheduler installed but not actually running. Red:
      # the user thinks reminders are firing but they aren't.
      printf '%s installed but stale \u2014 last tick %s \u2014 is the scheduler running?\n' \
        "$backend" "$(_doctor_format_age "$age")"
      return 1
    else
      printf '%s installed (last tick %s)\n' "$backend" "$(_doctor_format_age "$age")"
    fi
  else
    printf '%s installed (no tick yet \u2014 wait one minute)\n' "$backend"
  fi
}

_doctor_render_reminders() {
  local dir="$1"
  local log="$dir/reminders.delivery.log"
  local pending active delivered failed backend sched_line sched_rc=0
  pending="$(_doctor_count_status "$dir" pending)"
  active="$(_doctor_count_status "$dir" active)"
  delivered="$(_doctor_count_delivery "$log" '.ok == true')"
  failed="$(_doctor_count_delivery "$log" '.ok == false')"
  backend="$(config_get scheduler.backend cron)"
  # Capture rc separately because the $(...) subshell can't propagate a
  # _doctor_red increment back to the parent. `sched_line` carries the
  # display string; `sched_rc` becomes 1 iff the scheduler reports stale.
  sched_line="$(_doctor_scheduler_line "$backend" "$log")" || sched_rc=$?

  printf '\nreminders:\n'
  printf '  pending     %s\n' "$pending"
  printf '  active      %s\n' "$active"
  printf '  delivered   %s\n' "$delivered"
  printf '  failed      %s\n' "$failed"
  printf '  scheduler   %s\n' "$sched_line"

  return "$sched_rc"
}

_doctor_render_reminders "$state_dir" || _doctor_red=$((_doctor_red + 1))

# --- Integrations rollup ---
# Config + cache-mtime driven; no network calls. Calendar provider name comes
# from [calendar] provider in config.toml. Cache freshness is derived from the
# mtime of cache/calendar.json — providers write that file on successful sync.
# gh / jira / gcalcli are presence + (for gh) auth-status probes. Provider fns
# themselves are NOT invoked here so we don't trigger real-time API calls
# during a health check.
#
# Each disabled / failing integration carries a parenthesised one-line "reason"
# so the user knows *why* it's off without hunting through config.toml.
# Calendar disambiguates four cases: no config.toml, [calendar] provider key
# absent, provider = 'none' (explicit), and an unrecognised provider name.
profile="${JARVIS_PROFILE:-default}"
printf '\n  \033[1mIntegrations\033[0m\n'

# Source calendar provider stack at registration-only cost so we can list
# the recognised provider names when the configured one is unknown. None of
# these libs perform I/O at source-time; they only call calendar_register.
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/calendar/provider.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/calendar/none.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/calendar/gcalcli.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/calendar/ics.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/calendar/applescript.sh"

# _doctor_calendar_raw — dasel probe that distinguishes "key absent" from
# "key explicitly set to 'none'". config_get collapses both to "none", which
# is fine for the dispatcher but loses the signal we need here.
_doctor_calendar_raw() {
  local cfg="$1"
  [[ -f "$cfg" ]] || return 1
  command -v dasel >/dev/null 2>&1 || return 1
  local raw
  raw="$(dasel -i toml calendar.provider < "$cfg" 2>/dev/null || true)"
  raw="${raw#\'}"; raw="${raw%\'}"
  printf '%s' "$raw"
}

cfg="$state_dir/config.toml"
cal_raw="$(_doctor_calendar_raw "$cfg" || true)"
if [[ ! -f "$cfg" ]]; then
  printf "    calendar       not configured  (no config.toml at %s)\n" "$cfg"
elif [[ -z "$cal_raw" ]]; then
  printf "    calendar       not configured  (set [calendar] provider in %s)\n" "$cfg"
elif [[ "$cal_raw" == "none" ]]; then
  printf "    calendar       disabled  (provider = 'none' in %s)\n" "$cfg"
elif ! declare -F "calendar_${cal_raw}_events" >/dev/null 2>&1 \
   && [[ -z "${_CALENDAR_PROVIDERS[$cal_raw]:-}" ]]; then
  # Unknown provider = user typo in config.toml. Red because the user
  # thinks calendar is wired and it silently isn't (the dispatcher returns
  # exit 0 with empty stdout for unknown providers — every brief / standup
  # silently drops the calendar section).
  registered="$(calendar_providers | paste -sd, - 2>/dev/null || true)"
  printf "    calendar       %s  unknown provider (registered: %s)\n" "$cal_raw" "$registered"
  _doctor_red=$((_doctor_red + 1))
else
  cal_cache="$state_dir/cache/calendar.json"
  if [[ -f "$cal_cache" ]]; then
    cal_mtime="$(stat -c %Y "$cal_cache" 2>/dev/null || stat -f %m "$cal_cache" 2>/dev/null || printf '0')"
    cal_age=$(( $(date +%s) - cal_mtime ))
    printf "    calendar       %s  (cache %ds ago)\n" "$cal_raw" "$cal_age"
  else
    printf "    calendar       %s  (no cache yet)\n" "$cal_raw"
  fi
fi

if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    printf '    gh             ok\n'
  else
    # shellcheck disable=SC2016  # backticks are literal markdown, not subshell
    printf '    gh             auth required  (run `gh auth login`)\n'
  fi
else
  printf '    gh             missing  (install: https://cli.github.com)\n'
fi

if command -v jira >/dev/null 2>&1; then
  printf '    jira           ok\n'
else
  printf '    jira           missing  (install: https://github.com/ankitpokhrel/jira-cli)\n'
fi

if command -v gcalcli >/dev/null 2>&1; then
  printf '    gcalcli        ok\n'
else
  printf '    gcalcli        missing  (install: pipx install gcalcli)\n'
fi
printf '\n'

# --- Live integration probes ---
# Opt-in via --integrations-live. Bypasses the calendar cache, invokes provider
# fns directly, and lets upstream stderr through so misconfigured ICS URLs,
# gh auth failures, and jira backend errors are visible to the human.
# Default doctor stays static (no network).
if [[ "$live_flag" == "true" ]]; then
  printf '\n  \033[1mLive probes\033[0m\n'

  # Calendar \u2014 invoke the registered provider directly (skip the cache layer
  # and the dispatcher's stderr mute). Today's [00:00, +1d) window.
  cal_provider="$(config_get calendar.provider none "$profile")"
  if [[ "$cal_provider" == "none" ]]; then
    printf '    calendar       not configured\n'
  else
    # shellcheck source=/dev/null
    source "${CLI_DIR}/lib/cache/file.sh"
    # shellcheck source=/dev/null
    source "${CLI_DIR}/lib/calendar/provider.sh"
    # shellcheck source=/dev/null
    source "${CLI_DIR}/lib/calendar/none.sh"
    # shellcheck source=/dev/null
    source "${CLI_DIR}/lib/calendar/gcalcli.sh"
    # shellcheck source=/dev/null
    source "${CLI_DIR}/lib/calendar/ics.sh"
    # shellcheck source=/dev/null
    source "${CLI_DIR}/lib/calendar/applescript.sh"

    now_iso="$(native_now_iso)"
    day_start="$(native_day_start "$now_iso")"
    day_end="$(native_day_boundary "$day_start" +1d)"

    fn="calendar_${cal_provider}_events"
    if ! declare -F "$fn" >/dev/null; then
      printf '    calendar       %s  unknown provider (no registered fn)\n' "$cal_provider"
      _doctor_red=$((_doctor_red + 1))
    else
      cal_rc=0
      cal_out="$("$fn" "$day_start" "$day_end" "$profile")" || cal_rc=$?
      cal_count=0
      [[ -n "$cal_out" ]] && cal_count="$(printf '%s\n' "$cal_out" | grep -c .)"
      if (( cal_rc == 0 )); then
        printf '    calendar       %s  %d events today\n' "$cal_provider" "$cal_count"
      else
        # Live probe failure: provider configured + invoked + returned non-zero.
        # That's a misconfig the user should know about (red).
        printf '    calendar       %s  probe exited %d (see stderr above)\n' "$cal_provider" "$cal_rc"
        _doctor_red=$((_doctor_red + 1))
      fi
    fi
  fi

  # gh \u2014 invoke directly so its stderr (auth required, network) reaches the user.
  if command -v gh >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "${CLI_DIR}/lib/integrations/gh.sh"
    gh_rc=0
    gh_out="$(gh_prs_review_requested "$profile")" || gh_rc=$?
    gh_count=0
    [[ -n "$gh_out" ]] && gh_count="$(printf '%s\n' "$gh_out" | grep -c .)"
    if (( gh_rc == 0 )); then
      printf '    gh             %d PRs awaiting review\n' "$gh_count"
    else
      printf '    gh             probe exited %d (see stderr above)\n' "$gh_rc"
      _doctor_red=$((_doctor_red + 1))
    fi
  else
    printf '    gh             missing\n'
  fi

  # jira \u2014 same.
  if command -v jira >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "${CLI_DIR}/lib/integrations/jira.sh"
    jr_rc=0
    jr_out="$(jira_in_flight "$profile")" || jr_rc=$?
    jr_count=0
    [[ -n "$jr_out" ]] && jr_count="$(printf '%s\n' "$jr_out" | grep -c .)"
    if (( jr_rc == 0 )); then
      printf '    jira           %d in flight\n' "$jr_count"
    else
      printf '    jira           probe exited %d (see stderr above)\n' "$jr_rc"
      _doctor_red=$((_doctor_red + 1))
    fi
  else
    printf '    jira           missing\n'
  fi
  printf '\n'
fi

# focus.log orphan check \u2014 surfaces SIGKILL / power-loss cases where a
# `start` row landed but the EXIT trap never got to write its `end`.
# Sources are loaded lazily here so the dependency only kicks in when the
# log exists (avoids cost on a freshly-bootstrapped profile).
focus_log="$state_dir/focus.log"
if [[ -f "$focus_log" ]]; then
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/state/lock.sh"
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/state/ndjson.sh"
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/focus/log.sh"
  orphan_count="$(focus_orphan_starts | grep -c . || true)"
  if (( orphan_count == 0 )); then
    printf '\u2713 %-13s %-20s %s\n' "focus.log" "0 orphan rows" "clean"
  else
    # Orphan rows are recoverable via --reap-focus-orphans; surface as warn
    # rather than red so the user can fix it without doctor blocking CI.
    printf '\u26a0 %-13s %-20s %s\n' "focus.log" "$orphan_count orphan rows" \
      "run \`jarvis doctor --reap-focus-orphans\` to synthesize end rows"
  fi
else
  printf '\u2713 %-13s %-20s %s\n' "focus.log" "no log yet" "no focus sessions recorded"
fi

# Exit non-zero if any red signal fired so this command can gate CI / cron
# wrappers / shell prompts. Conservative red count means a fully-default
# profile with no integrations configured still exits 0; only actively
# broken state (corrupt schema, missing required bin, scheduler stale,
# calendar typo, live probe fail) trips the gate.
if (( _doctor_red > 0 )); then
  if declare -F log_warn >/dev/null 2>&1; then
    log_warn "doctor: $_doctor_red red signal$( (( _doctor_red == 1 )) || printf 's' ) \u2014 see \u2717 rows above"
  fi
  exit 1
fi
exit 0
