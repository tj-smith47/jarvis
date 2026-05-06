#!/usr/bin/env bash
# File-backed TTL cache. Per-profile: <profile>/cache/<key>.json.
# Atomic writes via temp+mv. Honors JARVIS_FAKE_NOW for tests.
#
# Contract:
#   cache_get <profile> <key> <ttl_sec>
#     - exits 0 + prints content if file exists and now-mtime < ttl_sec
#     - exits 1 if missing, stale, ttl == 0, or read failed
#       (any failure is a "cache miss" by design — callers re-fetch)
#     - sets $_CACHE_GET_REASON to one of: missing | stale | ttl_zero | read_error
#       so debug consumers (`jarvis doctor --cache-debug`, future) can
#       distinguish without breaking the universal "exit 1 = miss" contract
#       relied on by existing tests + dispatchers.
#   cache_put <profile> <key> <content>
#     - writes atomically (temp + mv), creates dirs as needed
#     - on mkdir failure, emits a stderr line with the path (was silently
#       swallowed pre-2026-04-28; T1-W2 from .claude/known-bugs.md)
#
# JARVIS_FAKE_NOW (UTC ISO, e.g. 2026-04-27T12:00:00Z) overrides "now"
# for deterministic test runs. Unset -> date +%s is the source of truth.

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_CACHE_FILE_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_CACHE_FILE_LOADED=1

_cache_now_epoch() {
  if [[ -n "${JARVIS_FAKE_NOW:-}" ]]; then
    date -u -d "$JARVIS_FAKE_NOW" +%s 2>/dev/null \
      || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$JARVIS_FAKE_NOW" +%s
  else
    date -u +%s
  fi
}

_cache_path() {
  local profile="$1" key="$2"
  local home="${JARVIS_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/jarvis}"
  printf '%s/%s/cache/%s.json\n' "$home" "$profile" "$key"
}

_cache_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"
}

cache_get() {
  local profile="$1" key="$2" ttl="$3"
  local f
  f="$(_cache_path "$profile" "$key")"
  _CACHE_GET_REASON=""
  if [[ ! -f "$f" ]]; then
    _CACHE_GET_REASON="missing"
    return 1
  fi
  if (( ttl == 0 )); then
    _CACHE_GET_REASON="ttl_zero"
    return 1
  fi
  local mtime now
  mtime="$(_cache_mtime "$f")"
  now="$(_cache_now_epoch)"
  if (( now - mtime >= ttl )); then
    _CACHE_GET_REASON="stale"
    return 1
  fi
  # Use cat (not $(<f)) — command substitution strips trailing newline,
  # which would cause miss-vs-hit byte drift on multi-line NDJSON.
  if ! cat "$f"; then
    _CACHE_GET_REASON="read_error"
    return 1
  fi
}

cache_put() {
  local profile="$1" key="$2" content="$3"
  local f tmp dir
  f="$(_cache_path "$profile" "$key")"
  dir="$(dirname "$f")"
  if ! mkdir -p "$dir" 2>/dev/null; then
    printf 'cache_put: mkdir -p %q failed\n' "$dir" >&2
    return 1
  fi
  tmp="${f}.tmp.$$.${RANDOM}"
  if ! printf '%s' "$content" > "$tmp"; then
    printf 'cache_put: write %q failed\n' "$tmp" >&2
    return 1
  fi
  mv -f "$tmp" "$f"
}

# cache_put_file <profile> <key> <src-path>
# Byte-exact variant — copies the source file rather than passing its
# bytes through a shell variable (which would strip trailing newlines).
# Use this from dispatchers that must round-trip provider stdout
# unchanged through the cache (drains T2-W2 from .claude/known-bugs.md).
cache_put_file() {
  local profile="$1" key="$2" src="$3"
  local f tmp dir
  f="$(_cache_path "$profile" "$key")"
  dir="$(dirname "$f")"
  if ! mkdir -p "$dir" 2>/dev/null; then
    printf 'cache_put_file: mkdir -p %q failed\n' "$dir" >&2
    return 1
  fi
  if [[ ! -r "$src" ]]; then
    printf 'cache_put_file: source %q not readable\n' "$src" >&2
    return 1
  fi
  tmp="${f}.tmp.$$.${RANDOM}"
  if ! cp "$src" "$tmp"; then
    printf 'cache_put_file: copy %q -> %q failed\n' "$src" "$tmp" >&2
    return 1
  fi
  mv -f "$tmp" "$f"
}
