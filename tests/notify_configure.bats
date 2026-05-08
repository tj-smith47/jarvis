#!/usr/bin/env bats
# `jarvis notify configure <channel>` — interactive prompt + TOML write.
# Tests use --non-interactive to drive the prompt loop from a here-string.

bats_require_minimum_version 1.5.0

load 'helper'

setup() {
  jarvis_common_setup
  mkdir -p "$JARVIS_HOME/test"
  printf '1\n' > "$JARVIS_HOME/test/state.version"
}
teardown() { jarvis_common_teardown; }

_run_configure() {
  FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR" CLI_DIR="$JARVIS_DIR" \
    bash "$JARVIS_DIR/cmds/notify/notify.configure.sh" "$@"
}

@test "configure with no channel exits 2 with usage" {
  run _run_configure
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]] || [[ "$output" == *"notify configure"* ]]
}

@test "configure unknown channel exits 2" {
  run _run_configure pushover
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown channel"* ]]
}

@test "configure gotify --dry-run prints the [notify.gotify] block" {
  run bash -c '
    FRAMEWORK_DIR="$1" CLI_DIR="$2" \
    bash "$2/cmds/notify/notify.configure.sh" gotify --non-interactive --dry-run \
      <<<"https://gotify.example.com
my-token
7"
  ' _ "$CLIFT_FRAMEWORK_DIR" "$JARVIS_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[notify.gotify]"* ]]
  [[ "$output" == *"https://gotify.example.com"* ]]
  [[ "$output" == *"my-token"* ]]
  [[ "$output" == *"priority = 7"* ]]
  # Dry-run does NOT touch config.toml.
  [ ! -f "$JARVIS_HOME/test/config.toml" ]
}

@test "configure gotify writes [notify.gotify] to config.toml" {
  run bash -c '
    FRAMEWORK_DIR="$1" CLI_DIR="$2" \
    bash "$2/cmds/notify/notify.configure.sh" gotify --non-interactive \
      <<<"https://gotify.example.com
mytoken
"
  ' _ "$CLIFT_FRAMEWORK_DIR" "$JARVIS_DIR"
  [ "$status" -eq 0 ]
  local cfg="$JARVIS_HOME/test/config.toml"
  [ -f "$cfg" ]
  [ "$(dasel -i toml notify.gotify.url < "$cfg" | tr -d \')" = "https://gotify.example.com" ]
  [ "$(dasel -i toml notify.gotify.token < "$cfg" | tr -d \')" = "mytoken" ]
  # Empty default → priority falls back to "5".
  [ "$(dasel -i toml notify.gotify.priority < "$cfg")" = "5" ]
}

@test "configure gotify rejects URL missing scheme with exit 2" {
  run bash -c '
    FRAMEWORK_DIR="$1" CLI_DIR="$2" \
    bash "$2/cmds/notify/notify.configure.sh" gotify --non-interactive \
      <<<"gotify.example.com
mytoken
5"
  ' _ "$CLIFT_FRAMEWORK_DIR" "$JARVIS_DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"http://"* ]] || [[ "$output" == *"https://"* ]]
}

@test "configure gotify rejects empty required field with exit 3" {
  # Empty URL line → exits 3 ("user aborted / required field missing").
  run bash -c '
    FRAMEWORK_DIR="$1" CLI_DIR="$2" \
    bash "$2/cmds/notify/notify.configure.sh" gotify --non-interactive \
      <<<"

mytoken
5"
  ' _ "$CLIFT_FRAMEWORK_DIR" "$JARVIS_DIR"
  [ "$status" -eq 3 ]
}

@test "configure slack writes webhook" {
  run bash -c '
    FRAMEWORK_DIR="$1" CLI_DIR="$2" \
    bash "$2/cmds/notify/notify.configure.sh" slack --non-interactive \
      <<<"https://hooks.slack.com/services/A/B/C"
  ' _ "$CLIFT_FRAMEWORK_DIR" "$JARVIS_DIR"
  [ "$status" -eq 0 ]
  local cfg="$JARVIS_HOME/test/config.toml"
  [ "$(dasel -i toml notify.slack.webhook < "$cfg" | tr -d \')" = "https://hooks.slack.com/services/A/B/C" ]
}

@test "configure email writes to + transport with defaults" {
  run bash -c '
    FRAMEWORK_DIR="$1" CLI_DIR="$2" \
    bash "$2/cmds/notify/notify.configure.sh" email --non-interactive \
      <<<"me@example.com



"
  ' _ "$CLIFT_FRAMEWORK_DIR" "$JARVIS_DIR"
  [ "$status" -eq 0 ]
  local cfg="$JARVIS_HOME/test/config.toml"
  [ "$(dasel -i toml notify.email.to < "$cfg" | tr -d \')" = "me@example.com" ]
  [ "$(dasel -i toml notify.email.transport < "$cfg" | tr -d \')" = "auto" ]
  [ "$(dasel -i toml notify.email.subject_prefix < "$cfg" | tr -d \')" = "[jarvis]" ]
}

@test "configure email rejects invalid recipient with exit 2" {
  run bash -c '
    FRAMEWORK_DIR="$1" CLI_DIR="$2" \
    bash "$2/cmds/notify/notify.configure.sh" email --non-interactive \
      <<<"not-an-email
"
  ' _ "$CLIFT_FRAMEWORK_DIR" "$JARVIS_DIR"
  [ "$status" -eq 2 ]
}

@test "configure gotify replaces existing [notify.gotify] section" {
  local cfg="$JARVIS_HOME/test/config.toml"
  cat > "$cfg" <<EOF
[other]
key = "preserved"

[notify.gotify]
url = "https://old.example.com"
token = "old-token"
priority = 1

[also]
keep = "this"
EOF
  run bash -c '
    FRAMEWORK_DIR="$1" CLI_DIR="$2" \
    bash "$2/cmds/notify/notify.configure.sh" gotify --non-interactive \
      <<<"https://new.example.com
new-token
9"
  ' _ "$CLIFT_FRAMEWORK_DIR" "$JARVIS_DIR"
  [ "$status" -eq 0 ]
  # New values land.
  [ "$(dasel -i toml notify.gotify.url < "$cfg" | tr -d \')" = "https://new.example.com" ]
  [ "$(dasel -i toml notify.gotify.token < "$cfg" | tr -d \')" = "new-token" ]
  [ "$(dasel -i toml notify.gotify.priority < "$cfg")" = "9" ]
  # Surrounding sections survive.
  [ "$(dasel -i toml other.key < "$cfg" | tr -d \')" = "preserved" ]
  [ "$(dasel -i toml also.keep < "$cfg" | tr -d \')" = "this" ]
}
