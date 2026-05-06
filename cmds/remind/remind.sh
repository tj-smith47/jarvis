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
source "${CLI_DIR}/lib/state/lock.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/json.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/ndjson.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/config.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/slug.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/remind/parse.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/remind/schema.sh"

# Standalone-argv fallback (tests, direct invocation).
if ! declare -p CLIFT_FLAGS >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/runtime/standalone_argv.sh"
  jarvis_standalone_argv_parse \
    '[{"name":"in","type":"string"},
      {"name":"at","type":"string"},
      {"name":"repeat","type":"string"},
      {"name":"until","type":"string"},
      {"name":"count","type":"string"},
      {"name":"via","type":"string","default":"local"}]' \
    "$@"
fi

message="${CLIFT_POS_1:-}"
in_="${CLIFT_FLAGS[in]:-}"
at_="${CLIFT_FLAGS[at]:-}"
repeat_="${CLIFT_FLAGS[repeat]:-}"
until_="${CLIFT_FLAGS[until]:-}"
count_="${CLIFT_FLAGS[count]:-}"
via_csv="${CLIFT_FLAGS[via]:-local}"

if [[ -z "$message" ]]; then
  clift_exit 2 'usage: jarvis remind "<message>" (--in DUR | --at TIME) [--repeat ...] [--via CSV]'
fi

# ---------- mutex / required combos ----------

if [[ -n "$in_" && ( -n "$at_" || -n "$repeat_" ) ]]; then
  clift_exit 2 "--in is mutually exclusive with --at and --repeat"
fi

if [[ -z "$in_" && -z "$at_" && -z "$repeat_" ]]; then
  clift_exit 2 "must provide --in <duration> or --at <time> (and optionally --repeat)"
fi

# Recurring needs anchor when the cadence is calendar-based (not interval).
anchor_at=""
if [[ -n "$repeat_" ]]; then
  if ! repeat_canonical="$(remind_parse_repeat "$repeat_" 2>&1)"; then
    clift_exit 2 "$repeat_canonical"
  fi
  case "$repeat_canonical" in
    daily|weekly|weekdays|weekends|*[!0-9smhd]*)
      # Anchored cadence (literal or day-list)
      if [[ -z "$at_" ]]; then
        clift_exit 2 "--repeat $repeat_canonical requires --at HH:MM"
      fi
      # Anchor must be HH:MM only (not absolute datetime).
      if [[ ! "$at_" =~ ^[0-2][0-9]:[0-5][0-9]$ ]]; then
        clift_exit 2 "anchored --repeat requires --at HH:MM (got '$at_')"
      fi
      anchor_at="$at_"
      ;;
    *)
      # Interval cadence (Ns|Nm|Nh|Nd) — no anchor needed.
      anchor_at=""
      ;;
  esac
else
  repeat_canonical=""
fi

# ---------- compute trigger_at ----------

if [[ -n "$in_" ]]; then
  if ! trigger_at="$(remind_parse_in "$in_" 2>&1)"; then
    clift_exit 2 "$trigger_at"
  fi
elif [[ -n "$at_" && -z "$repeat_" ]]; then
  # One-shot --at
  if ! trigger_at="$(remind_parse_at "$at_" 2>&1)"; then
    clift_exit 2 "$trigger_at"
  fi
elif [[ -n "$repeat_canonical" && -n "$anchor_at" ]]; then
  # Anchored recurring — first fire is the next occurrence of the anchor.
  if ! trigger_at="$(remind_parse_at "$anchor_at" 2>&1)"; then
    clift_exit 2 "$trigger_at"
  fi
elif [[ -n "$repeat_canonical" ]]; then
  # Interval recurring — first fire is now + interval.
  if ! trigger_at="$(remind_parse_in "$repeat_canonical" 2>&1)"; then
    clift_exit 2 "$trigger_at"
  fi
else
  clift_exit 2 "internal error: could not determine trigger time"
fi

# ---------- channel validation (fail-fast at create time) ----------

# Split comma-separated via list and validate each channel + its config.
IFS=',' read -ra via_arr <<< "$via_csv"
for ch in "${via_arr[@]}"; do
  ch="${ch// /}"   # strip whitespace
  case "$ch" in
    local) ;;
    gotify)
      url="$(config_get notify.gotify.url "")"
      tok="$(config_get notify.gotify.token "")"
      [[ -z "$url" ]] && clift_exit 2 "channel 'gotify' requires [notify.gotify].url in config.toml"
      [[ -z "$tok" ]] && clift_exit 2 "channel 'gotify' requires [notify.gotify].token in config.toml"
      ;;
    slack)
      hook="$(config_get notify.slack.webhook "")"
      [[ -z "$hook" ]] && clift_exit 2 "channel 'slack' requires [notify.slack].webhook in config.toml"
      ;;
    "")  ;;
    *)
      clift_exit 2 "unknown channel '$ch' (must be one of: local, gotify, slack)"
      ;;
  esac
done

# Build canonical via JSON array (whitespace-stripped).
via_json="$(printf '%s\n' "$via_csv" \
  | tr ',' '\n' \
  | awk 'NF{gsub(/ /,""); print}' \
  | jq -Rsc 'split("\n") | map(select(length>0))')"

# ---------- slug + payload assembly ----------

if [[ -n "${JARVIS_FAKE_NOW:-}" ]]; then
  now_iso="$JARVIS_FAKE_NOW"
else
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi

# Slug: <slugified-message>-<YYYY-MM-DD-HHMM> derived from now_iso so tests
# (with JARVIS_FAKE_NOW pinned) get deterministic slugs.
[[ "$now_iso" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}):([0-9]{2}) ]] \
  || clift_exit 2 "internal error: malformed now_iso '$now_iso'"
ts_compact="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
base_slug="$(slug_from_desc "$message")"
slug="${base_slug}-${ts_compact}"

profile="${JARVIS_PROFILE:-default}"
status="pending"
[[ -n "$repeat_canonical" ]] && status="active"

payload="$(jq -nc \
  --arg slug "$slug" --arg message "$message" \
  --arg profile "$profile" \
  --arg trigger_at "$trigger_at" \
  --argjson via "$via_json" \
  --arg status "$status" \
  --arg repeat "$repeat_canonical" \
  --arg anchor "$anchor_at" \
  --arg until_at "$until_" --arg count "$count_" \
  --arg created_at "$now_iso" \
  '{slug:$slug, message:$message, profile:$profile,
    trigger_at:$trigger_at, via:$via, status:$status,
    repeat: (if $repeat == "" then null else $repeat end),
    anchor_at: (if $anchor == "" then null else $anchor end),
    until: (if $until_at == "" then null else $until_at end),
    count_remaining: (if $count == "" then null else ($count|tonumber) end),
    created_at:$created_at, fire_count:0, last_fired_at:null}')"

remind_schema_create "$slug" "$payload"

# ---------- confirmation line ----------

if [[ -n "$repeat_canonical" ]]; then
  if [[ -n "$anchor_at" ]]; then
    when="repeat $repeat_canonical at $anchor_at"
  else
    when="repeat every $repeat_canonical"
  fi
elif [[ -n "$in_" ]]; then
  when="in $in_"
else
  when="at $at_"
fi

log_success "scheduled: $slug ($when via $via_csv)"
