#!/usr/bin/env bash
set -euo pipefail

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

if ! declare -p CLIFT_FLAGS >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/runtime/standalone_argv.sh"
  jarvis_standalone_argv_parse \
    '[{"name":"all-profiles","type":"bool"},
      {"name":"json","type":"bool"},
      {"name":"yaml","type":"bool"}]' \
    "$@"
fi

all_profiles="${CLIFT_FLAGS[all-profiles]:-}"
json_out="${CLIFT_FLAGS[json]:-}"
yaml_out="${CLIFT_FLAGS[yaml]:-}"

if [[ "$json_out" == "true" && "$yaml_out" == "true" ]]; then
  clift_exit 2 "--json and --yaml are mutually exclusive"
fi

# Resolve "now" honoring JARVIS_FAKE_NOW (used by tests for stable
# relative-time formatting).
if [[ -n "${JARVIS_FAKE_NOW:-}" ]]; then
  now_e="$(date -u -d "$JARVIS_FAKE_NOW" +%s 2>/dev/null \
            || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$JARVIS_FAKE_NOW" +%s)"
else
  now_e="$(date -u +%s)"
fi

# Collect reminder JSON files.
home="${JARVIS_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/jarvis}"
files=()
if [[ "$all_profiles" == "true" ]]; then
  shopt -s nullglob
  for d in "$home"/*; do
    [[ -d "$d" ]] || continue
    for f in "$d"/reminders/*.json; do
      files+=("$f")
    done
  done
  shopt -u nullglob
else
  shopt -s nullglob
  d="$(state_profile_dir)"
  for f in "$d"/reminders/*.json; do
    files+=("$f")
  done
  shopt -u nullglob
fi

# Build aggregate JSON array (sorted by trigger_at).
if (( ${#files[@]} == 0 )); then
  if [[ "$json_out" == "true" ]]; then
    printf '[]\n'
  elif [[ "$yaml_out" == "true" ]]; then
    printf -- '--- []\n'
  else
    log_info "no reminders"
  fi
  exit 0
fi

# Slurp + sort.
agg="$(jq -s 'sort_by(.trigger_at)' "${files[@]}")"

if [[ "$json_out" == "true" ]]; then
  printf '%s\n' "$agg"
  exit 0
fi

if [[ "$yaml_out" == "true" ]]; then
  if command -v yq >/dev/null 2>&1; then
    printf '%s\n' "$agg" | yq -P
  else
    printf '%s\n' "$agg"
  fi
  exit 0
fi

# ---------- table render ----------

# Format an epoch delta as a human "in 5m" / "3h ago" / "—" string.
_fmt_relative() {
  local target_e="$1"
  local diff=$(( target_e - now_e ))
  local sign suffix abs
  if (( diff >= 0 )); then
    sign="in"; suffix=""
    abs=$diff
  else
    sign=""; suffix=" ago"
    abs=$(( -diff ))
  fi
  local out
  if (( abs < 60 )); then
    out="${abs}s"
  elif (( abs < 3600 )); then
    out="$((abs/60))m"
  elif (( abs < 86400 )); then
    out="$((abs/3600))h"
  else
    out="$((abs/86400))d"
  fi
  if [[ -n "$sign" ]]; then
    printf '%s %s' "$sign" "$out"
  else
    printf '%s%s' "$out" "$suffix"
  fi
}

_fmt_repeat() {
  local repeat="$1" anchor="$2"
  if [[ -z "$repeat" || "$repeat" == "null" ]]; then
    printf 'once'
    return
  fi
  if [[ -n "$anchor" && "$anchor" != "null" ]]; then
    printf '%s %s' "$repeat" "$anchor"
  else
    printf 'every %s' "$repeat"
  fi
}

_fmt_last_fired() {
  local last="$1"
  if [[ -z "$last" || "$last" == "null" ]]; then
    printf -- '—'
    return
  fi
  local last_e
  last_e="$(date -u -d "$last" +%s 2>/dev/null \
            || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$last" +%s 2>/dev/null \
            || true)"
  if [[ -z "$last_e" ]]; then
    printf -- '—'
    return
  fi
  _fmt_relative "$last_e"
}

# Print header + rows.
printf '%-30s %-18s %-14s %-14s %-22s %s\n' \
  SLUG WHEN REPEAT LAST_FIRED VIA STATUS

# jq emits Unit-Separator (\x1f) joined fields. We can't use @tsv here
# because bash's `read -r` with IFS=$'\t' collapses runs of whitespace,
# eating empty repeat/anchor/last_fired columns and shifting everything.
while IFS=$'\x1f' read -r slug trigger repeat anchor last via status; do
  trigger_e="$(date -u -d "$trigger" +%s 2>/dev/null \
                || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$trigger" +%s)"
  when_str="$(_fmt_relative "$trigger_e")"
  repeat_str="$(_fmt_repeat "$repeat" "$anchor")"
  last_str="$(_fmt_last_fired "$last")"
  printf '%-30s %-18s %-14s %-14s %-22s %s\n' \
    "$slug" "$when_str" "$repeat_str" "$last_str" "$via" "$status"
done < <(printf '%s\n' "$agg" | jq -r '
  .[] | [
    .slug, .trigger_at,
    (.repeat // ""),
    (.anchor_at // ""),
    (.last_fired_at // ""),
    (.via | join(",")),
    .status
  ] | join("")')
