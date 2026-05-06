#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

load helper

setup() { jarvis_common_setup; }
teardown() { jarvis_common_teardown; }

@test "state_profile_dir returns JARVIS_HOME/JARVIS_PROFILE" {
  source "$JARVIS_DIR/lib/state/profile.sh"
  run state_profile_dir
  [ "$status" -eq 0 ]
  [ "$output" = "$JARVIS_HOME/test" ]
}

@test "state_profile_dir defaults profile to 'default' when unset" {
  unset JARVIS_PROFILE
  source "$JARVIS_DIR/lib/state/profile.sh"
  run state_profile_dir
  [ "$status" -eq 0 ]
  [ "$output" = "$JARVIS_HOME/default" ]
}

@test "state_ensure_tree creates all required subdirs" {
  source "$JARVIS_DIR/lib/state/profile.sh"
  state_ensure_tree
  [ -d "$JARVIS_HOME/test/tasks" ]
  [ -d "$JARVIS_HOME/test/reminders" ]
  [ -d "$JARVIS_HOME/test/notes/inbox" ]
  [ -d "$JARVIS_HOME/test/notes/daily" ]
  [ -d "$JARVIS_HOME/test/notes/meetings" ]
  [ -d "$JARVIS_HOME/test/notes/ref" ]
  [ -d "$JARVIS_HOME/test/notes/archive" ]
  [ -d "$JARVIS_HOME/test/notes/templates" ]
  [ -d "$JARVIS_HOME/test/cache" ]
}

@test "state_ensure_tree writes state.version=1 on first call" {
  source "$JARVIS_DIR/lib/state/profile.sh"
  state_ensure_tree
  [ -f "$JARVIS_HOME/test/state.version" ]
  [ "$(< "$JARVIS_HOME/test/state.version")" = "1" ]
}

@test "state_ensure_tree is idempotent (preserves existing state.version)" {
  source "$JARVIS_DIR/lib/state/profile.sh"
  state_ensure_tree
  printf '2\n' > "$JARVIS_HOME/test/state.version"
  state_ensure_tree
  [ "$(< "$JARVIS_HOME/test/state.version")" = "2" ]
}
