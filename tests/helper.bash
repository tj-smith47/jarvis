#!/usr/bin/env bash
# Shared setup for jarvis bats suites.
# Redirects HOME to TEST_DIR; sets JARVIS_HOME to a per-test tmp.

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_HELPER_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_HELPER_LOADED=1

jarvis_common_setup() {
  # Resolve framework dir BEFORE redirecting HOME so $HOME expansion is real.
  export CLIFT_FRAMEWORK_DIR="${CLIFT_FRAMEWORK_DIR:-$HOME/.clift}"
  if [[ ! -d "$CLIFT_FRAMEWORK_DIR" ]]; then
    printf 'jarvis tests require clift framework — set CLIFT_FRAMEWORK_DIR or install at $HOME/.clift\n' >&2
    printf '  current value: %q\n' "$CLIFT_FRAMEWORK_DIR" >&2
    printf '  install hint:  git clone https://github.com/tj-smith47/clift "$HOME/.clift"\n' >&2
    exit 1
  fi
  TEST_DIR="$(mktemp -d)"
  export HOME="$TEST_DIR"
  export JARVIS_HOME="$TEST_DIR/jarvis-state"
  export JARVIS_PROFILE="test"
  export JARVIS_DIR="${BATS_TEST_DIRNAME}/.."
  mkdir -p "$JARVIS_HOME"
}

jarvis_common_teardown() {
  if [[ -n "${TEST_DIR:-}" && -d "$TEST_DIR" ]]; then
    rm -rf "$TEST_DIR"
  fi
}
