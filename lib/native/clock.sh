#!/usr/bin/env bash
# Clock + date-math wrappers backed by bin/jarvis-when.
#
# Replaces ~30 site-groups of bilateral GNU/BSD `date -d ... || date -j -f`
# fallbacks scattered across cmds/ and lib/. One source of truth: jarvis-when
# (Python, cross-platform) handles every form (HH:MM, ISO, "tomorrow",
# "next monday", durations) deterministically per the JARVIS_TODAY ->
# JARVIS_FAKE_NOW -> system precedence the binary itself enforces.
#
# Library — intentionally does NOT set `set -euo pipefail`; options inherit
# from the caller (matches lib/state/*.sh, lib/note/*.sh convention).
#
# Public API:
#   native_now_iso                  UTC ISO-8601 'now' (honors FAKE_NOW/TODAY)
#   native_now_epoch                UTC seconds-since-epoch 'now'
#   native_today_local              YYYY-MM-DD 'today' (TODAY > FAKE_NOW > sys)
#   native_resolve "<expr>"         <expr> -> UTC ISO-8601 (forwards to jarvis-when)
#   native_resolve_to_epoch "<expr>" <expr> -> UTC seconds
#   native_epoch_to_iso <epoch>     epoch -> UTC ISO-8601
#   native_day_start <iso>          midnight UTC of <iso>'s date
#   native_day_boundary <iso> +Nd   <iso> + N days as UTC ISO
#   native_dow_of <epoch>           %u (1=Mon..7=Sun)
#
# Failure modes:
#   - bin/jarvis-when missing or wrong protocol -> clift_exit 4 via
#     native_protocol_check (one-shot per shell session)
#   - bad input expression -> exit 2 with stderr from jarvis-when
#
# Exclusively called from inside the wrappers in this directory; cmd
# scripts under cmds/ MUST NOT invoke jarvis-when directly. The
# jarvis_protocol_no_leak.bats test enforces that boundary.

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_NATIVE_CLOCK_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_NATIVE_CLOCK_LOADED=1

# Resolve bin/jarvis-when relative to CLI_DIR with a sane fallback for
# tests that haven't exported CLI_DIR (e.g. direct `bash cmds/...`).
_native_when_bin() {
  local cli_dir="${CLI_DIR:-}"
  if [[ -z "$cli_dir" ]]; then
    # BASH_SOURCE is lib/native/clock.sh; repo root is two levels up.
    cli_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  fi
  printf '%s/bin/jarvis-when\n' "$cli_dir"
}

_native_clock_pin_checked=0
_native_clock_pin_check() {
  if (( _native_clock_pin_checked )); then return 0; fi
  # Source protocol checker on first use so callers can `source clock.sh`
  # without paying the protocol-check cost upfront.
  if ! declare -F native_protocol_check >/dev/null 2>&1; then
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck disable=SC1091
    source "$lib_dir/protocol.sh"
  fi
  native_protocol_check "$(_native_when_bin)"
  _native_clock_pin_checked=1
}

# native_now_iso — UTC ISO-8601 'now'.
native_now_iso() {
  _native_clock_pin_check
  "$(_native_when_bin)" parse now
}

# native_now_epoch — UTC seconds-since-epoch 'now'.
native_now_epoch() {
  _native_clock_pin_check
  local iso
  iso="$("$(_native_when_bin)" parse now)" || return 2
  _native_iso_to_epoch "$iso"
}

# native_today_local — YYYY-MM-DD 'today' (honors precedence).
native_today_local() {
  _native_clock_pin_check
  local iso
  iso="$("$(_native_when_bin)" parse today)" || return 2
  printf '%s\n' "${iso%%T*}"
}

# native_resolve "<expr>" — arbitrary user expression -> UTC ISO-8601.
native_resolve() {
  _native_clock_pin_check
  "$(_native_when_bin)" parse "$1"
}

# native_resolve_to_epoch "<expr>" — same as native_resolve, then convert.
native_resolve_to_epoch() {
  local iso
  iso="$(native_resolve "$1")" || return 2
  _native_iso_to_epoch "$iso"
}

# native_epoch_to_iso <epoch> — epoch -> UTC ISO-8601.
native_epoch_to_iso() {
  local epoch="$1"
  # date -d works on Linux (GNU coreutils); -j -f on BSD/macOS. We don't
  # round-trip through jarvis-when here because the conversion is purely
  # arithmetic and `date` is universally available.
  date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -j -f %s "$epoch" +%Y-%m-%dT%H:%M:%SZ
}

# native_day_start <iso> — midnight UTC of the date component of <iso>.
native_day_start() {
  local iso="$1"
  printf '%sT00:00:00Z\n' "${iso%%T*}"
}

# native_day_boundary <iso> +Nd — <iso> + N days as UTC ISO.
# N must be a non-negative integer; +1d / +7d are typical callers.
native_day_boundary() {
  _native_clock_pin_check
  local iso="$1" delta="$2"
  if [[ ! "$delta" =~ ^\+([0-9]+)d$ ]]; then
    printf 'native_day_boundary: bad delta %q (expected +Nd)\n' "$delta" >&2
    return 2
  fi
  local n="${BASH_REMATCH[1]}"
  # Anchor to the date component then ask jarvis-when for "<date> + Nd".
  local base="${iso%%T*}T00:00:00Z"
  local epoch
  epoch="$(_native_iso_to_epoch "$base")" || return 2
  epoch=$(( epoch + n * 86400 ))
  native_epoch_to_iso "$epoch"
}

# native_dow_of <epoch> — %u (1=Mon..7=Sun).
native_dow_of() {
  local epoch="$1"
  date -u -d "@$epoch" +%u 2>/dev/null \
    || date -u -j -f %s "$epoch" +%u
}

# Internal: ISO-8601 -> epoch, with bilateral GNU/BSD fallback.
# Single source of this fallback lives here; cmd scripts use the helpers.
_native_iso_to_epoch() {
  local iso="$1"
  date -u -d "$iso" +%s 2>/dev/null \
    || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s
}
