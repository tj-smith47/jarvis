#!/usr/bin/env bats
# `jarvis standup discover` — walk $HOME for git repos, populate
# [standup].repos in config.toml. Tests pin a synthetic --root with known
# layout so the walk is deterministic and the assertions don't depend on
# what's on the runner's actual home dir.

bats_require_minimum_version 1.5.0

load 'helper'

setup() {
  jarvis_common_setup
  mkdir -p "$JARVIS_HOME/test"
  printf '1\n' > "$JARVIS_HOME/test/state.version"
  # Build a synthetic walk root: 4 git repos at depths 1, 2, 2, 3 plus
  # one excluded path under a node_modules/ to verify pruning.
  mkdir -p "$TEST_DIR/walk-root/proj-a/.git"
  mkdir -p "$TEST_DIR/walk-root/group/proj-b/.git"
  mkdir -p "$TEST_DIR/walk-root/group/proj-c/.git"
  mkdir -p "$TEST_DIR/walk-root/deep/sub/proj-d/.git"
  mkdir -p "$TEST_DIR/walk-root/proj-a/node_modules/some-pkg/.git"
}
teardown() { jarvis_common_teardown; }

_run_discover() {
  FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR" CLI_DIR="$JARVIS_DIR" \
    bash "$JARVIS_DIR/cmds/standup/standup.discover.sh" "$@"
}

@test "discover --json emits a sorted JSON array of repo roots" {
  run _run_discover --root "$TEST_DIR/walk-root" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r 'length' <<< "$output")" = "4" ]
  # First entry comes from sort -u: proj-a then deep/sub/proj-d, etc.
  # Just assert each expected path appears.
  [[ "$output" == *"$TEST_DIR/walk-root/proj-a"* ]]
  [[ "$output" == *"$TEST_DIR/walk-root/group/proj-b"* ]]
  [[ "$output" == *"$TEST_DIR/walk-root/group/proj-c"* ]]
  [[ "$output" == *"$TEST_DIR/walk-root/deep/sub/proj-d"* ]]
}

@test "discover prunes node_modules + dotdir paths" {
  run _run_discover --root "$TEST_DIR/walk-root" --json
  [ "$status" -eq 0 ]
  # The node_modules-buried .git must NOT be in the output.
  [[ "$output" != *"node_modules"* ]]
}

@test "discover --max-depth limits traversal" {
  # `find -maxdepth N` walks N directory levels from root. With maxdepth 2
  # it descends through proj-a/ (depth 1) and reaches proj-a/.git (depth 2).
  # With maxdepth 3 it adds group/proj-b/.git (depth 3). 3 keeps proj-a +
  # proj-b + proj-c, drops the deeper proj-d.
  run _run_discover --root "$TEST_DIR/walk-root" --max-depth 3 --json
  [ "$status" -eq 0 ]
  # 3 repos at depth ≤ 3: proj-a, group/proj-b, group/proj-c. proj-d is
  # at depth 4 (deep/sub/proj-d/.git) — excluded.
  [ "$(jq -r 'length' <<< "$output")" = "3" ]
  [[ "$output" != *"proj-d"* ]]
}

@test "discover empty walk root exits 1 with stderr message" {
  empty="$TEST_DIR/empty"
  mkdir -p "$empty"
  run --separate-stderr _run_discover --root "$empty" --json
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"no git repos"* ]]
}

@test "discover --write writes [standup].repos to config.toml" {
  run _run_discover --root "$TEST_DIR/walk-root" --write
  [ "$status" -eq 0 ]
  local cfg="$JARVIS_HOME/test/config.toml"
  [ -f "$cfg" ]
  # Read back via dasel and verify all 4 repos are persisted.
  local got
  got="$(dasel -i toml -o json standup.repos < "$cfg")"
  [ "$(jq -r 'length' <<< "$got")" = "4" ]
}

@test "discover --append merges into existing repos (de-duped)" {
  local cfg="$JARVIS_HOME/test/config.toml"
  cat > "$cfg" <<EOF
[standup]
repos = ["$TEST_DIR/walk-root/proj-a", "/some/other/repo"]
EOF
  run _run_discover --root "$TEST_DIR/walk-root" --append --yes
  [ "$status" -eq 0 ]
  local got
  got="$(dasel -i toml -o json standup.repos < "$cfg")"
  # 4 discovered + /some/other/repo + the 1 overlap (proj-a) → 5 unique
  [ "$(jq -r 'length' <<< "$got")" = "5" ]
  [[ "$(jq -r '.[]' <<< "$got")" == *"/some/other/repo"* ]]
}

@test "discover --root not-a-dir → exit 2" {
  run _run_discover --root /nope/not/here --json
  [ "$status" -eq 2 ]
}

@test "discover invalid --max-depth → exit 2" {
  run _run_discover --root "$TEST_DIR/walk-root" --max-depth abc --json
  [ "$status" -eq 2 ]
}
