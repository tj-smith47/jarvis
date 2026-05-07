#!/usr/bin/env bash
# Reminder schema layer for jarvis.
# Builds on state/{profile,lock,json,ndjson}.sh — caller must source those first.
#
# Per-reminder JSON: $JARVIS_HOME/<profile>/reminders/<slug>.json
#   Small, monotonic, git-sync friendly. Carries identity + cadence + status
#   + monotonic counters (fire_count, last_fired_at). NEVER carries delivery
#   history — that would mutate the file every fire and cause sync conflicts.
#
# Delivery history: $JARVIS_HOME/<profile>/reminders.delivery.log (NDJSON)
#   Append-only, one row per channel attempt. Doctor reads this for "delivered
#   count" rollups in O(1) wc/grep instead of O(N) per-file reads.

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_REMIND_SCHEMA_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_REMIND_SCHEMA_LOADED=1

# Required keys + simple type checks. Anchor/until/count are optional but
# must be present (possibly null).
_REMIND_REQUIRED_KEYS='["slug","message","profile","trigger_at","via","status","repeat","anchor_at","until","count_remaining","created_at","fire_count","last_fired_at"]'

_remind_profile_dir() {
  local profile="${1:-}"
  if [[ -n "$profile" ]]; then
    local home="${JARVIS_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/jarvis}"
    printf '%s/%s\n' "$home" "$profile"
  else
    state_profile_dir
  fi
}

remind_schema_path() {
  local slug="$1" profile="${2:-}"
  printf '%s/reminders/%s.json\n' "$(_remind_profile_dir "$profile")" "$slug"
}

remind_delivery_log_path() {
  local profile="${1:-}"
  printf '%s/reminders.delivery.log\n' "$(_remind_profile_dir "$profile")"
}

remind_schema_validate() {
  local payload="$1"
  if ! jq -e . <<< "$payload" >/dev/null 2>&1; then
    printf 'remind_schema_validate: not valid JSON\n' >&2
    return 2
  fi
  # Required keys present?
  local missing
  missing="$(jq -r --argjson req "$_REMIND_REQUIRED_KEYS" \
    '$req - (keys) | .[]' <<< "$payload")"
  if [[ -n "$missing" ]]; then
    printf 'remind_schema_validate: missing required keys: %s\n' \
      "$(tr '\n' ' ' <<< "$missing")" >&2
    return 2
  fi
  # via must be array
  local via_type
  via_type="$(jq -r '.via | type' <<< "$payload")"
  if [[ "$via_type" != "array" ]]; then
    printf 'remind_schema_validate: .via must be array (got %s)\n' "$via_type" >&2
    return 2
  fi
  # slug/message/trigger_at must be non-empty strings
  local slug message trigger_at
  slug="$(jq -r '.slug // empty' <<< "$payload")"
  message="$(jq -r '.message // empty' <<< "$payload")"
  trigger_at="$(jq -r '.trigger_at // empty' <<< "$payload")"
  if [[ -z "$slug" || -z "$message" || -z "$trigger_at" ]]; then
    printf 'remind_schema_validate: slug/message/trigger_at must be non-empty\n' >&2
    return 2
  fi
  return 0
}

# remind_schema_create <slug> <json-blob>
# Validates the blob then atomic-writes via state_json_write. The cmd layer
# is responsible for assembling the blob — keeps this lib free of flag parsing.
remind_schema_create() {
  local slug="$1" payload="$2"
  remind_schema_validate "$payload" || return 2
  local target
  target="$(remind_schema_path "$slug")"
  mkdir -p "$(dirname "$target")"
  state_json_write "$target" "$payload"
}

# remind_schema_load — counterpart to remind_schema_save. Currently exercised
# only by tests as the load half of a round-trip: save → load → assert
# byte-equal. Kept in the lib so the round-trip property is maintained as
# the schema evolves; if a future writer skews the on-disk format, the
# load-side test is the canary.
remind_schema_load() {
  local slug="$1" profile="${2:-}"
  local target
  target="$(remind_schema_path "$slug" "$profile")"
  state_json_read "$target"
}

remind_schema_save() {
  local slug="$1" payload="$2" profile="${3:-}"
  remind_schema_validate "$payload" || return 2
  local target
  target="$(remind_schema_path "$slug" "$profile")"
  mkdir -p "$(dirname "$target")"
  state_json_write "$target" "$payload"
}

# remind_schema_list_profile <profile-dir>
# Emits slugs (one per line) for every *.json under <profile-dir>/reminders/.
# Returns 0 with empty stdout for empty/missing dir.
remind_schema_list_profile() {
  local profile_dir="$1"
  local d="$profile_dir/reminders"
  [[ -d "$d" ]] || return 0
  local f base
  for f in "$d"/*.json; do
    [[ -e "$f" ]] || continue
    base="${f##*/}"
    printf '%s\n' "${base%.json}"
  done
}

# remind_delivery_log_append <slug> <delivery-json>
# Appends one NDJSON row to the profile's reminders.delivery.log. Validates
# the row is JSON, then merges in the slug field (so the row carries identity
# without requiring callers to remember to set it).
remind_delivery_log_append() {
  local slug="$1" row="$2" profile="${3:-}"
  if ! jq -e . <<< "$row" >/dev/null 2>&1; then
    printf 'remind_delivery_log_append: row is not valid JSON\n' >&2
    return 2
  fi
  local merged
  merged="$(jq -c --arg slug "$slug" '. + {slug:$slug}' <<< "$row")"
  local target
  target="$(remind_delivery_log_path "$profile")"
  mkdir -p "$(dirname "$target")"
  ndjson_append "$target" "$merged"
}
