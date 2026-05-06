#!/usr/bin/env bash
# Shared PATH-shim helpers for jarvis bats suites.
# Lets tests intercept calls to crontab, systemctl, curl, osascript,
# notify-send, etc. without invoking the real binaries. Each shim records
# its invocations to a log so the test can assert on them.
#
# Usage:
#   load 'jarvis_shim_helper'
#
#   setup() {
#     jarvis_common_setup
#     shim_setup
#     shim_install curl 'echo "curl: $*" >> "$0.log"; exit 0'
#   }
#
#   @test "..." {
#     run something_that_invokes_curl
#     [ -f "$(shim_log_path curl)" ]
#   }

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_SHIM_HELPER_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_SHIM_HELPER_LOADED=1

shim_setup() {
  : "${TEST_DIR:?shim_setup: jarvis_common_setup must run first}"
  export SHIM_DIR="$TEST_DIR/shimbin"
  mkdir -p "$SHIM_DIR"
  export PATH="$SHIM_DIR:$PATH"
}

# shim_install <name> <body>
# Writes an executable shim that runs <body>. The shim's own path is $0; logs
# conventionally go to "$0.log" so tests can locate them via shim_log_path.
shim_install() {
  local name="$1" body="$2"
  : "${SHIM_DIR:?shim_install: shim_setup must run first}"
  local f="$SHIM_DIR/$name"
  cat > "$f" <<EOF
#!/usr/bin/env bash
$body
EOF
  chmod +x "$f"
}

shim_uninstall() {
  local name="$1"
  : "${SHIM_DIR:?shim_uninstall: shim_setup must run first}"
  rm -f "$SHIM_DIR/$name" "$SHIM_DIR/$name.log"
}

shim_log_path() {
  local name="$1"
  : "${SHIM_DIR:?shim_log_path: shim_setup must run first}"
  printf '%s/%s.log\n' "$SHIM_DIR" "$name"
}

# Convenience: append "<name>: <args...>" to log AND exit 0. Common case for
# fire-and-forget shims (curl success, systemctl success).
shim_record_ok() {
  printf 'shim_record_ok %q\n' "$@" >> "$0.log"
  exit 0
}
