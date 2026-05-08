#!/usr/bin/env bash
# cleanup — apply a retention policy to the per-profile state directory.
#
# Default behavior is DRY-RUN: print what would change, mutate nothing.
# --confirm flips it to actually execute. The intended driver is the
# cron line installed by `cleanup install` (daily 03:00 fire); manual
# invocation is the escape hatch for one-off cleanups + previews.
#
# Targets + the rule applied to each:
#
#   focus.log              NDJSON; keep rows where .ts >= cutoff
#   notify.log             NDJSON; keep rows where .ts >= cutoff
#   reminders/<slug>.json  delete iff:
#                              .status == "delivered"
#                              and .repeat in ("", "once")     (one-shots only)
#                              and .last_fired_at < cutoff
#   tasks/<slug>.json      delete iff:
#                              .status == "done"
#                              and .done_at < cutoff
#
# Recurring reminders, open tasks, and unfired reminders are never
# touched. Compaction of NDJSON files uses an atomic temp+mv so an
# interrupted cleanup never leaves a half-written log.
#
# Exit codes:
#   0   dry-run printed, OR confirm completed
#   2   bad flag

set -euo pipefail

: "${FRAMEWORK_DIR:=${CLIFT_FRAMEWORK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}}"
: "${CLI_DIR:=${JARVIS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"

# shellcheck source=/dev/null
source "${FRAMEWORK_DIR}/lib/log/log.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/profile.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/native/clock.sh"

if ! declare -p CLIFT_FLAGS >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/runtime/standalone_argv.sh"
  jarvis_standalone_argv_parse \
    '[{"name":"before","type":"string"},
      {"name":"confirm","type":"bool"},
      {"name":"json","type":"bool"}]' \
    "$@"
fi

before="${CLIFT_FLAGS[before]:-90d}"
confirm="${CLIFT_FLAGS[confirm]:-}"
want_json="${CLIFT_FLAGS[json]:-}"

# Parse the threshold. Accepts Nd / Nw / Nm where Nm is "N months" and
# always means N*30d (we don't track real calendar months — too much
# variance for what is fundamentally a retention knob, not a precision
# clock). Sub-day granularity isn't useful for a cleanup target.
if [[ ! "$before" =~ ^([0-9]+)([dwm])$ ]]; then
  clift_exit 2 "invalid --before: $before (expected Nd|Nw|Nm, e.g. 30d, 4w, 6m)"
fi
n="${BASH_REMATCH[1]}"; u="${BASH_REMATCH[2]}"
case "$u" in
  d) sec=$((n * 86400)) ;;
  w) sec=$((n * 7 * 86400)) ;;
  m) sec=$((n * 30 * 86400)) ;;
esac

now_epoch="$(native_now_epoch)"
cutoff_epoch=$(( now_epoch - sec ))
cutoff_iso="$(native_epoch_to_iso "$cutoff_epoch")"

profile_dir="$(state_profile_dir)"

# Plan-build phase — pure read. Each function returns a count + (in
# verbose / json mode) the list of victims. The mutate phase below
# re-runs the same predicates against actual paths to avoid TOCTOU
# (another jarvis cmd may have moved state between plan and apply).

# focus.log + notify.log: NDJSON files where row.ts < cutoff.
_count_old_ndjson_rows() {
  local path="$1"
  [[ -f "$path" ]] || { printf '0\n'; return 0; }
  jq -rs --arg c "$cutoff_iso" '
    [.[] | select((.ts // "") < $c)] | length
  ' < "$path" 2>/dev/null || printf '0'
}

# reminders/: count delivered one-shots whose last_fired_at < cutoff.
_count_stale_reminders() {
  local dir="$1"
  [[ -d "$dir" ]] || { printf '0\n'; return 0; }
  shopt -s nullglob
  local files=( "$dir"/*.json )
  shopt -u nullglob
  (( ${#files[@]} == 0 )) && { printf '0\n'; return 0; }
  jq -rs --arg c "$cutoff_iso" '
    [ .[]
      | select((.status // "") == "delivered"
               and ((.repeat // "") == "" or (.repeat // "") == "once")
               and (.last_fired_at // "") != ""
               and (.last_fired_at // "") < $c) ]
    | length
  ' "${files[@]}" 2>/dev/null || printf '0'
}

# tasks/: count done tasks where done_at < cutoff.
_count_stale_tasks() {
  local dir="$1"
  [[ -d "$dir" ]] || { printf '0\n'; return 0; }
  shopt -s nullglob
  local files=( "$dir"/*.json )
  shopt -u nullglob
  (( ${#files[@]} == 0 )) && { printf '0\n'; return 0; }
  jq -rs --arg c "$cutoff_iso" '
    [ .[]
      | select((.status // "") == "done"
               and (.done_at // "") != ""
               and (.done_at // "") < $c) ]
    | length
  ' "${files[@]}" 2>/dev/null || printf '0'
}

focus_count="$(_count_old_ndjson_rows "$profile_dir/focus.log")"
notify_count="$(_count_old_ndjson_rows "$profile_dir/notify.log")"
reminders_count="$(_count_stale_reminders "$profile_dir/reminders")"
tasks_count="$(_count_stale_tasks "$profile_dir/tasks")"

if [[ "$want_json" == "true" ]]; then
  jq -nc \
    --arg cutoff "$cutoff_iso" \
    --arg before "$before" \
    --argjson f "$focus_count" --argjson n "$notify_count" \
    --argjson r "$reminders_count" --argjson t "$tasks_count" \
    '{cutoff:$cutoff, before:$before,
      focus_log_rows:$f, notify_log_rows:$n,
      delivered_reminders:$r, done_tasks:$t}'
  exit 0
fi

# Pretty plan summary. Always rendered (dry-run + confirm both call this).
total=$((focus_count + notify_count + reminders_count + tasks_count))
printf 'cleanup plan (cutoff %s, before %s):\n' "$cutoff_iso" "$before"
printf '  focus.log rows               %d\n' "$focus_count"
printf '  notify.log rows              %d\n' "$notify_count"
printf '  delivered reminders          %d\n' "$reminders_count"
printf '  done tasks                   %d\n' "$tasks_count"
printf '  total mutations              %d\n' "$total"

if [[ "$confirm" != "true" ]]; then
  if (( total == 0 )); then
    printf '  (nothing to do)\n'
  else
    printf '\nrun with --confirm to apply.\n'
  fi
  exit 0
fi

# Apply phase. Each path is independent — partial failures don't roll
# back others (state-keeping correctness wins over atomicity here; a
# half-cleaned state is still consistent because each file is its own
# unit). atomic temp+mv on the NDJSON compactions guards against
# torn-write on power loss.

_compact_ndjson() {
  local path="$1"
  [[ -f "$path" ]] || return 0
  local tmp="${path}.cleanup.tmp"
  jq -c --arg c "$cutoff_iso" 'select((.ts // "") >= $c)' < "$path" > "$tmp"
  mv "$tmp" "$path"
}

_compact_ndjson "$profile_dir/focus.log"
_compact_ndjson "$profile_dir/notify.log"

# reminders + tasks: rm files matching the stale predicate.
_rm_stale_reminders() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  shopt -s nullglob
  local f
  for f in "$dir"/*.json; do
    if jq -e --arg c "$cutoff_iso" '
        select((.status // "") == "delivered"
               and ((.repeat // "") == "" or (.repeat // "") == "once")
               and (.last_fired_at // "") != ""
               and (.last_fired_at // "") < $c)' < "$f" >/dev/null 2>&1; then
      rm -f "$f"
    fi
  done
  shopt -u nullglob
}

_rm_stale_tasks() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  shopt -s nullglob
  local f
  for f in "$dir"/*.json; do
    if jq -e --arg c "$cutoff_iso" '
        select((.status // "") == "done"
               and (.done_at // "") != ""
               and (.done_at // "") < $c)' < "$f" >/dev/null 2>&1; then
      rm -f "$f"
    fi
  done
  shopt -u nullglob
}

_rm_stale_reminders "$profile_dir/reminders"
_rm_stale_tasks "$profile_dir/tasks"

log_success "cleanup: applied (focus=${focus_count}, notify=${notify_count}, reminders=${reminders_count}, tasks=${tasks_count})"
