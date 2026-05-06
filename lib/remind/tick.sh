#!/usr/bin/env bash
# Tick loop — fires due reminders across every profile under $JARVIS_HOME.
#
# Wraps work in per-profile `flock -n` so concurrent ticks (cron */1 + slow
# gotify, double-cron config, manual + scheduled overlap) cannot double-fire
# the same reminder.
#
# On every tick run, appends a `tick.heartbeat` row to the per-profile
# reminders.delivery.log so `doctor` can detect "scheduler installed but not
# firing" — caught case where cron line exists but crond isn't running.
#
# Per-channel attempt results live in two places by design:
#   - notify.log: uniform per-channel record written by every channel via
#     _notify_log (used for jq queries during testing/debugging).
#   - reminders.delivery.log: per-fire NDJSON keyed by slug. Built by tick
#     diffing notify.log around the dispatch call; doctor reads this for
#     O(1) "delivered/failed count" rollups.

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_REMIND_TICK_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_REMIND_TICK_LOADED=1

remind_tick_run() {
  local home="${JARVIS_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/jarvis}"
  [[ -d "$home" ]] || return 0

  local profile_dir
  for profile_dir in "$home"/*; do
    [[ -d "$profile_dir" ]] || continue
    local profile_name="${profile_dir##*/}"
    mkdir -p "$profile_dir/reminders"
    local lock_file="$profile_dir/reminders/.tick.lock"

    # Per-profile non-blocking lock. Subshell isolates the lock fd; if
    # another tick holds it, this profile is silently skipped this round.
    (
      exec 9>"$lock_file"
      flock -n 9 || exit 0
      _remind_tick_one_profile "$profile_name" "$profile_dir"
    )
  done
}

_remind_tick_one_profile() {
  local profile_name="$1" profile_dir="$2"
  local now_iso now_e
  now_iso="$(_remind_tick_now_iso)" || return 1
  now_e="$(_remind_now_epoch)" || return 1

  # Heartbeat first — even if no reminders fire, doctor sees the tick ran.
  local heartbeat
  heartbeat="$(jq -nc --arg ts "$now_iso" '{ts:$ts, kind:"tick.heartbeat"}')"
  remind_delivery_log_append "_heartbeat" "$heartbeat" "$profile_name"

  local f
  for f in "$profile_dir"/reminders/*.json; do
    [[ -e "$f" ]] || continue
    _remind_tick_one_reminder "$f" "$profile_name" "$now_iso" "$now_e"
  done
}

# now_iso preferring fake clock for tests.
_remind_tick_now_iso() {
  if [[ -n "${JARVIS_FAKE_NOW:-}" ]]; then
    printf '%s\n' "$JARVIS_FAKE_NOW"
  else
    date -u +%Y-%m-%dT%H:%M:%SZ
  fi
}

_remind_tick_one_reminder() {
  local file="$1" profile_name="$2" now_iso="$3" now_e="$4"

  local payload
  payload="$(state_json_read "$file")" || return 0

  local status
  status="$(jq -r '.status' <<< "$payload")"
  case "$status" in
    pending|active) ;;
    *) return 0 ;;
  esac

  local trigger_at trigger_e
  trigger_at="$(jq -r '.trigger_at' <<< "$payload")"
  trigger_e="$(_rs_to_epoch "$trigger_at")" || return 0
  (( trigger_e <= now_e )) || return 0

  local slug rem_profile repeat
  slug="$(jq -r '.slug' <<< "$payload")"
  rem_profile="$(jq -r '.profile' <<< "$payload")"
  repeat="$(jq -r '.repeat // empty' <<< "$payload")"

  # Recurring exhaustion check: if the schedule has expired (`until` past
  # OR `count_remaining` was 0 going in), transition to exhausted without
  # firing. This catches reminders that were set up days ago and have run
  # past their fence; a missed last-fire isn't worth notifying about.
  if [[ -n "$repeat" ]] && _remind_recurring_expired "$payload" "$now_e"; then
    local exhausted
    exhausted="$(jq -c '.status = "exhausted"' <<< "$payload")"
    remind_schema_save "$slug" "$exhausted" "$rem_profile"
    return 0
  fi

  # Fire: dispatch + capture per-channel results into delivery NDJSON.
  local dispatch_rc=0
  _remind_tick_dispatch_and_log "$payload" "$slug" "$rem_profile" || dispatch_rc=$?

  if [[ -z "$repeat" ]]; then
    _remind_tick_finalize_one_shot "$payload" "$slug" "$rem_profile" \
      "$now_iso" "$dispatch_rc"
  else
    _remind_tick_finalize_recurring "$payload" "$slug" "$rem_profile" \
      "$now_iso"
  fi
}

# Returns 0 (true) if the recurring reminder is past its until or has
# zero count_remaining — caller should mark exhausted and not fire.
_remind_recurring_expired() {
  local payload="$1" now_e="$2"
  local until_at count_remaining
  until_at="$(jq -r '.until // empty' <<< "$payload")"
  count_remaining="$(jq -r '.count_remaining // empty' <<< "$payload")"

  if [[ -n "$until_at" ]]; then
    # Treat `until` date as inclusive end-of-day in UTC.
    local until_e
    until_e="$(_rs_to_epoch "${until_at}T23:59:59Z" 2>/dev/null)" || return 1
    if (( now_e > until_e )); then
      return 0
    fi
  fi

  if [[ -n "$count_remaining" && "$count_remaining" != "null" ]]; then
    if (( count_remaining <= 0 )); then
      return 0
    fi
  fi

  return 1
}

# Diff notify.log around dispatch and append per-channel rows (keyed by
# slug) to the delivery NDJSON. Returns dispatch's exit code so the caller
# can compute one-shot status transitions.
_remind_tick_dispatch_and_log() {
  local payload="$1" slug="$2" rem_profile="$3"
  local notify_log before=0 after=0
  notify_log="$(_notify_log_path "$rem_profile")"
  [[ -f "$notify_log" ]] && before="$(wc -l < "$notify_log")"

  local rc=0
  notify_dispatch "$payload" || rc=$?

  [[ -f "$notify_log" ]] && after="$(wc -l < "$notify_log")"
  if (( after > before )); then
    local row
    while IFS= read -r row; do
      [[ -z "$row" ]] && continue
      remind_delivery_log_append "$slug" "$row" "$rem_profile"
    done < <(tail -n +"$((before+1))" "$notify_log")
  fi
  return "$rc"
}

_remind_tick_finalize_one_shot() {
  local payload="$1" slug="$2" rem_profile="$3" now_iso="$4" dispatch_rc="$5"
  local new_status
  if (( dispatch_rc == 0 )); then
    new_status="delivered"
  else
    new_status="failed"
  fi
  local updated
  updated="$(jq -c \
    --arg now "$now_iso" --arg s "$new_status" \
    '. | .last_fired_at = $now
       | .fire_count = (.fire_count + 1)
       | .status = $s' <<< "$payload")"
  remind_schema_save "$slug" "$updated" "$rem_profile"
}

_remind_tick_finalize_recurring() {
  local payload="$1" slug="$2" rem_profile="$3" now_iso="$4"
  local repeat anchor_at count_remaining next_at
  repeat="$(jq -r '.repeat' <<< "$payload")"
  anchor_at="$(jq -r '.anchor_at // empty' <<< "$payload")"
  count_remaining="$(jq -r '.count_remaining // empty' <<< "$payload")"
  next_at="$(remind_next_trigger "$repeat" "$anchor_at" "$now_iso")" || {
    # If next-trigger calculation fails, leave reminder mid-state and log
    # — better than silently dropping advancement.
    printf 'tick: next_trigger failed for slug=%s repeat=%s\n' \
      "$slug" "$repeat" >&2
    return 1
  }

  if [[ -n "$count_remaining" && "$count_remaining" != "null" ]]; then
    local new_count=$((count_remaining - 1))
    local updated
    if (( new_count <= 0 )); then
      # This was the last fire; schedule no further triggers.
      updated="$(jq -c \
        --arg now "$now_iso" \
        '. | .last_fired_at = $now
           | .fire_count = (.fire_count + 1)
           | .count_remaining = 0
           | .status = "exhausted"' <<< "$payload")"
    else
      updated="$(jq -c \
        --arg now "$now_iso" --arg next "$next_at" \
        --argjson nc "$new_count" \
        '. | .last_fired_at = $now
           | .fire_count = (.fire_count + 1)
           | .count_remaining = $nc
           | .trigger_at = $next' <<< "$payload")"
    fi
    remind_schema_save "$slug" "$updated" "$rem_profile"
    return 0
  fi

  # No count limit — just advance trigger; status stays active.
  local updated
  updated="$(jq -c \
    --arg now "$now_iso" --arg next "$next_at" \
    '. | .last_fired_at = $now
       | .fire_count = (.fire_count + 1)
       | .trigger_at = $next' <<< "$payload")"
  remind_schema_save "$slug" "$updated" "$rem_profile"
}
