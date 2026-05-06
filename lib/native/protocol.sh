#!/usr/bin/env bash
# Native binary protocol-version pin checker.
# Library — intentionally does NOT set `set -euo pipefail`; options inherit
# from the caller (matches lib/state/*.sh convention).

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_NATIVE_PROTOCOL_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_NATIVE_PROTOCOL_LOADED=1

# Expected protocol version all jarvis native binaries must speak.
_JARVIS_NATIVE_PROTOCOL=1

# _native_protocol_cache_var <binary>
# Converts a binary path to a valid env var name for the per-binary cache.
# Replaces every non-alphanumeric character with underscore, uppercases.
_native_protocol_cache_var() {
  local binary="$1"
  # Strip leading non-word chars, replace non-alnum with _, uppercase.
  local sanitized
  sanitized="${binary//[^a-zA-Z0-9]/_}"
  sanitized="${sanitized^^}"
  printf '_JARVIS_NATIVE_PROTOCOL_%s' "$sanitized"
}

# native_protocol_check <binary>
# Verifies that <binary> speaks the expected protocol version.
# First-call-per-shell result is cached in a per-binary global; subsequent
# calls for the same binary path are instant (no fork).
#
# Exit codes:
#   0 — version matches
#   4 — version mismatch or binary too old / missing --protocol-version flag
native_protocol_check() {
  local binary="$1"
  local cache_var
  cache_var="$(_native_protocol_cache_var "$binary")"

  # Use cached result if available (no fork on repeated calls).
  if [[ -n "${!cache_var:-}" ]]; then
    return 0
  fi

  # Probe the binary — capture output and exit code separately.
  local reported_version
  local probe_rc=0
  reported_version="$("$binary" --protocol-version 2>/dev/null)" || probe_rc=$?

  if [[ "$probe_rc" -ne 0 ]] || [[ -z "$reported_version" ]]; then
    clift_exit 4 "${binary} too old or missing --protocol-version; run 'task build'"
  fi

  if [[ "$reported_version" != "$_JARVIS_NATIVE_PROTOCOL" ]]; then
    clift_exit 4 "${binary} speaks protocol ${reported_version}, jarvis expects ${_JARVIS_NATIVE_PROTOCOL}; run 'task build'"
  fi

  # Cache the validated version so subsequent calls skip the fork.
  printf -v "$cache_var" '%s' "$reported_version"
}
