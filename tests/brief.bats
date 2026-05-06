#!/usr/bin/env bats
# brief: real-data sections + --short snapshot.
# Sections gate on lib output; --short emits a frozen one-liner.

bats_require_minimum_version 1.5.0

load 'helper'
load 'shim_helper'

setup() {
  jarvis_common_setup
  shim_setup
  cp -R "${BATS_TEST_DIRNAME}/fixtures/status-profile" "$JARVIS_HOME/test"
  # Augment the fixture profile with an oncall block + ICS calendar source
  # so brief has every section to render. status-profile/config.toml already
  # carries [jira]; we append rather than rewrite.
  cat >> "$JARVIS_HOME/test/config.toml" <<EOF

[oncall]
primary = "alex"
secondary = "you"
pager = "quiet"

[calendar]
provider = "ics"

[calendar.ics]
source = "$JARVIS_HOME/test/cal.ics"
EOF
  cp "${BATS_TEST_DIRNAME}/fixtures/calendar.ics" "$JARVIS_HOME/test/cal.ics"
  cat > "$JARVIS_HOME/test/deploys.log" <<EOF
2026-05-01T13:00:00Z	api	v1.12.3	ok
2026-05-01T08:00:00Z	web	v0.47.1	ok
EOF
  shim_install gh '
case "$1" in
  pr) cat <<EOF2
[{"number":482,"title":"feat(router): persistent flags","url":"https://github.com/org/repo/pull/482","headRepository":{"name":"repo","owner":{"login":"org"}}}]
EOF2
   exit 0 ;;
esac'
  export JARVIS_FAKE_NOW="2026-05-01T15:00:00Z"
}

teardown() {
  jarvis_common_teardown
}

@test "brief shows all sections when configured" {
  run bash "${JARVIS_DIR}/cmds/brief/brief.sh" --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"Calendar"* ]]
  [[ "$output" == *"PRs"* ]]
  [[ "$output" == *"Deploys"* ]]
  [[ "$output" == *"Oncall"* ]]
  [[ "$output" == *"alex"* ]]
  [[ "$output" == *"v1.12.3"* ]]
  [[ "$output" == *"#482"* ]]
}

@test "brief --short matches snapshot byte-for-byte" {
  run bash "${JARVIS_DIR}/cmds/brief/brief.sh" --short --profile test
  [ "$status" -eq 0 ]
  diff <(printf '%s\n' "$output") "${BATS_TEST_DIRNAME}/fixtures/brief-short.txt"
}

@test "brief --short pluralizes counts (0 / 1 / N)" {
  # Drop the gh shim to get 0 PRs; clear deploys log to get 0 deploys.
  rm -f "$SHIM_DIR/gh"
  rm -f "$JARVIS_HOME/test/deploys.log"
  run bash "${JARVIS_DIR}/cmds/brief/brief.sh" --short --profile test
  [ "$status" -eq 0 ]
  # Zero is plural ("0 PRs", "0 deploys") — matches goreleaser-style English.
  [[ "$output" == *"0 PRs"* ]]
  [[ "$output" == *"0 deploys"* ]]

  # Re-shim gh to emit 1 PR.
  shim_install gh 'cat <<EOF2
[{"number":1,"title":"a","url":"u","headRepository":{"name":"r","owner":{"login":"o"}}}]
EOF2'
  printf '2026-05-01T08:00:00Z\tweb\tv1\tok\n' > "$JARVIS_HOME/test/deploys.log"
  run bash "${JARVIS_DIR}/cmds/brief/brief.sh" --short --profile test
  [[ "$output" == *"1 PR "* ]]
  [[ "$output" == *"1 deploy "* ]]
}

@test "brief --short omits oncall when no [oncall] config" {
  # Strip the [oncall] section by overwriting config.toml without it.
  cat > "$JARVIS_HOME/test/config.toml" <<EOF
[calendar]
provider = "ics"
[calendar.ics]
source = "$JARVIS_HOME/test/cal.ics"
EOF
  run bash "${JARVIS_DIR}/cmds/brief/brief.sh" --short --profile test
  [ "$status" -eq 0 ]
  [[ "$output" != *"oncall"* ]]
}

@test "brief --short shows primary only when no secondary" {
  cat > "$JARVIS_HOME/test/config.toml" <<EOF
[oncall]
primary = "alex"

[calendar]
provider = "ics"
[calendar.ics]
source = "$JARVIS_HOME/test/cal.ics"
EOF
  run bash "${JARVIS_DIR}/cmds/brief/brief.sh" --short --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *"oncall: alex"* ]]
  [[ "$output" != *" / "* ]]
}

@test "brief --skip-calendar hides Calendar but keeps others" {
  run bash "${JARVIS_DIR}/cmds/brief/brief.sh" --skip-calendar --profile test
  [ "$status" -eq 0 ]
  [[ "$output" != *"Calendar"* ]]
  [[ "$output" == *"PRs"* ]]
  [[ "$output" == *"Deploys"* ]]
}

@test "missing gh hides PRs section" {
  rm -f "$SHIM_DIR/gh"
  run bash "${JARVIS_DIR}/cmds/brief/brief.sh" --profile test
  [ "$status" -eq 0 ]
  [[ "$output" != *"PRs awaiting"* ]]
}

@test "calendar cache populated after first brief run" {
  bash "${JARVIS_DIR}/cmds/brief/brief.sh" --profile test > /dev/null
  bash "${JARVIS_DIR}/cmds/brief/brief.sh" --profile test > /dev/null
  [ -f "$JARVIS_HOME/test/cache/calendar.json" ]
}
