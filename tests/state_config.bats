#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

load helper

setup() {
  jarvis_common_setup
  source "$JARVIS_DIR/lib/state/profile.sh"
  source "$JARVIS_DIR/lib/state/config.sh"
  state_ensure_tree
  cat > "$JARVIS_HOME/test/config.toml" <<'EOF'
[notify]
default = "local,gotify"

[notify.slack]
webhook_url = "https://hooks.example/abc"

[calendar]
provider = "gcalcli"
EOF
}
teardown() { jarvis_common_teardown; }

@test "config_get returns scalar by dotted key" {
  run config_get notify.default ""
  [ "$status" -eq 0 ]
  [ "$output" = "local,gotify" ]
}

@test "config_get returns nested scalar" {
  run config_get notify.slack.webhook_url ""
  [ "$status" -eq 0 ]
  [ "$output" = "https://hooks.example/abc" ]
}

@test "config_get returns default when key missing" {
  run config_get notify.email.from "unset@example.com"
  [ "$status" -eq 0 ]
  [ "$output" = "unset@example.com" ]
}

@test "config_get returns default when config.toml missing" {
  rm "$JARVIS_HOME/test/config.toml"
  run config_get notify.default "none"
  [ "$status" -eq 0 ]
  [ "$output" = "none" ]
}

@test "config_get with explicit profile reads that profile's config" {
  mkdir -p "$JARVIS_HOME/work"
  cat > "$JARVIS_HOME/work/config.toml" <<'EOF'
[notify.gotify]
url = "https://gotify.work.example"
EOF
  run config_get notify.gotify.url "" work
  [ "$status" -eq 0 ]
  [ "$output" = "https://gotify.work.example" ]
}

@test "config_get with explicit profile does not mutate \$JARVIS_PROFILE" {
  mkdir -p "$JARVIS_HOME/other"
  cat > "$JARVIS_HOME/other/config.toml" <<'EOF'
key = "other-val"
EOF
  local before="$JARVIS_PROFILE"
  config_get key "" other >/dev/null
  [ "$JARVIS_PROFILE" = "$before" ]
}

@test "config_get with explicit profile honors profile-specific defaults" {
  # Reading a key from a profile that doesn't exist falls to default,
  # without touching the current profile's config.
  run config_get notify.default "fallback" nonexistent-profile
  [ "$status" -eq 0 ]
  [ "$output" = "fallback" ]
}

@test "config_get two profiles return distinct values in same shell" {
  mkdir -p "$JARVIS_HOME/work" "$JARVIS_HOME/home"
  cat > "$JARVIS_HOME/work/config.toml" <<'EOF'
who = "work"
EOF
  cat > "$JARVIS_HOME/home/config.toml" <<'EOF'
who = "home"
EOF
  run config_get who "" work
  [ "$output" = "work" ]
  run config_get who "" home
  [ "$output" = "home" ]
}
