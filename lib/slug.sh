#!/usr/bin/env bash
# Slug utilities for jarvis: generate, detect Jira keys, resolve collisions
# and user-typed prefixes. Pure bash — no state, no side effects.

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_SLUG_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_SLUG_LOADED=1

# slug_from_desc "<desc>"
# First line only, lowercased, non-alnum → -, collapse --, trim edges.
slug_from_desc() {
  local raw="${1:-}"
  local first_line="${raw%%$'\n'*}"
  local lower="${first_line,,}"
  local hyphened="${lower//[^a-z0-9]/-}"
  while [[ "$hyphened" == *--* ]]; do
    hyphened="${hyphened//--/-}"
  done
  hyphened="${hyphened#-}"
  hyphened="${hyphened%-}"
  # Cap at 100 chars — keep paths well under filesystem NAME_MAX (255 on ext4)
  # with headroom for collision suffixes (-2, -3, …) and .json/.tmp sidecars.
  if (( ${#hyphened} > 100 )); then
    hyphened="${hyphened:0:100}"
    # Re-trim trailing hyphen if the cut lands on one
    hyphened="${hyphened%-}"
  fi
  if [[ -z "$hyphened" ]]; then
    return 1
  fi
  printf '%s\n' "$hyphened"
}

# slug_is_jira_key "<s>"
# True for ABC-123 style keys. Bypasses generated-slug pipeline.
# Project key must be 2+ chars: first uppercase letter, then uppercase
# letters or digits. Real Atlassian keys are never single-letter; the
# `^[A-Z]+-[0-9]+$` form accepted `A-1` and would mis-route a normal
# slug like `a-1` after upper-casing.
slug_is_jira_key() {
  [[ "${1:-}" =~ ^[A-Z][A-Z0-9]+-[0-9]+$ ]]
}

# slug_resolve_collision <base> <dir> [<ext>]
# Returns <base> if free, else <base>-2, -3, ... until no matching <ext>
# (default "json") exists. Notes pass "md" so they don't collide with the
# task-store's `.json` convention.
slug_resolve_collision() {
  local base="$1"
  local dir="$2"
  local ext="${3:-json}"
  local candidate="$base"
  local n=2
  while [[ -e "$dir/$candidate.$ext" ]]; do
    candidate="${base}-${n}"
    n=$((n + 1))
  done
  printf '%s\n' "$candidate"
}

# slug_resolve_prefix <query> <tasks-dir>
# Exact match wins. Otherwise unique-prefix wins. No match or ambiguous → 1.
slug_resolve_prefix() {
  local query="$1"
  local dir="$2"
  if [[ -f "$dir/$query.json" ]]; then
    printf '%s\n' "$query"
    return 0
  fi
  local matches=()
  local f slug
  for f in "$dir"/*.json; do
    [[ -e "$f" ]] || continue
    slug="$(basename "$f" .json)"
    if [[ "$slug" == "$query"* ]]; then
      matches+=("$slug")
    fi
  done
  case "${#matches[@]}" in
    0)
      printf 'no task matches "%s"\n' "$query" >&2
      return 1
      ;;
    1)
      printf '%s\n' "${matches[0]}"
      return 0
      ;;
    *)
      local sorted
      mapfile -t sorted < <(printf '%s\n' "${matches[@]}" | sort)
      printf 'ambiguous prefix "%s" — candidates:\n' "$query" >&2
      printf '  %s\n' "${sorted[@]}" >&2
      return 1
      ;;
  esac
}
