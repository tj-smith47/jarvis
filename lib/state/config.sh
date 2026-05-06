#!/usr/bin/env bash
# TOML config loader for jarvis. Requires `dasel` on PATH.
# Usage:
#   config_get <dotted.key> <default-value>            # uses $JARVIS_PROFILE
#   config_get <dotted.key> <default-value> <profile>  # explicit profile,
#                                                        no env mutation

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_STATE_CONFIG_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_STATE_CONFIG_LOADED=1

config_get() {
  local key="$1"
  local default="$2"
  local profile="${3:-}"
  local cfg

  if [[ -n "$profile" ]]; then
    # Explicit profile: derive cfg path directly without touching $JARVIS_PROFILE
    # (callers can resolve any profile's config without disturbing global state).
    local home="${JARVIS_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/jarvis}"
    cfg="$home/$profile/config.toml"
  else
    cfg="$(state_profile_dir)/config.toml"
  fi

  if [[ ! -f "$cfg" ]]; then
    printf '%s\n' "$default"
    return 0
  fi
  if ! command -v dasel >/dev/null 2>&1; then
    printf '%s\n' "$default"
    return 0
  fi

  local val
  val="$(dasel -i toml "$key" < "$cfg" 2>/dev/null || true)"
  # dasel v3 wraps string scalars in single quotes — strip them
  val="${val#\'}"
  val="${val%\'}"
  if [[ -z "$val" ]]; then
    printf '%s\n' "$default"
  else
    printf '%s\n' "$val"
  fi
}
