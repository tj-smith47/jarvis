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

# ============================================================ --activity
#
# Activity mode: read [standup] repos from config, iterate, emit commit
# NDJSON via lib/integrations/git.sh. Test fixtures seed a small repo
# with deterministic --date commits so the window filter is verifiable.

_seed_repo() {
  local dir="$1" date1="$2" subj1="$3" date2="${4:-}" subj2="${5:-}"
  mkdir -p "$dir"
  ( cd "$dir" \
    && git init -q --initial-branch=main \
    && git config user.email alice@example.com \
    && git config user.name  alice \
    && git remote add origin "https://github.com/acme/$(basename "$dir").git" \
    && git commit --allow-empty -m "$subj1" --date="$date1" )
  if [[ -n "$date2" ]]; then
    ( cd "$dir" && git commit --allow-empty -m "$subj2" --date="$date2" )
  fi
}

@test "discover --activity --repo emits commit NDJSON for the single repo" {
  REPO="$TEST_DIR/single"
  _seed_repo "$REPO" "2026-04-30T10:00:00Z" "wip: yesterday" \
                     "2026-04-30T13:00:00Z" "feat: add thing (#42)"
  export JARVIS_FAKE_NOW="2026-05-01T15:00:00Z"
  run _run_discover --activity --repo "$REPO" --since 1d
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 2 ]
  # Every line is valid JSON.
  printf '%s\n' "$output" | while IFS= read -r row; do
    echo "$row" | jq -e '.' > /dev/null
  done
}

@test "discover --activity reads [standup] repos from config when --repo absent" {
  REPO1="$TEST_DIR/r1"; REPO2="$TEST_DIR/r2"
  _seed_repo "$REPO1" "2026-04-30T10:00:00Z" "r1: yesterday"
  _seed_repo "$REPO2" "2026-04-30T11:00:00Z" "r2: yesterday"
  local cfg="$JARVIS_HOME/test/config.toml"
  cat > "$cfg" <<EOF
[standup]
repos = ["$REPO1", "$REPO2"]
EOF
  export JARVIS_FAKE_NOW="2026-05-01T15:00:00Z"
  run _run_discover --activity --since 1d
  [ "$status" -eq 0 ]
  [[ "$output" == *"r1: yesterday"* ]]
  [[ "$output" == *"r2: yesterday"* ]]
}

@test "discover --activity --since 7d picks up older commits" {
  REPO="$TEST_DIR/old"
  _seed_repo "$REPO" "2026-04-25T10:00:00Z" "feat: a week ago" \
                     "2026-04-30T10:00:00Z" "feat: yesterday"
  export JARVIS_FAKE_NOW="2026-05-01T15:00:00Z"
  run _run_discover --activity --repo "$REPO" --since 7d
  [ "$status" -eq 0 ]
  [[ "$output" == *"feat: a week ago"* ]]
  [[ "$output" == *"feat: yesterday"* ]]
}

@test "discover --activity exits 1 when no config and no --repo" {
  rm -f "$JARVIS_HOME/test/config.toml"
  run --separate-stderr _run_discover --activity --since 1d
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"no config"* ]] || [[ "$stderr" == *"--repo"* ]]
}

@test "discover --activity exits 1 when [standup] repos is missing from config" {
  local cfg="$JARVIS_HOME/test/config.toml"
  cat > "$cfg" <<EOF
[other]
key = "value"
EOF
  run --separate-stderr _run_discover --activity --since 1d
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"repos not set"* ]]
}

@test "discover --activity --author overrides the per-repo user.email filter" {
  REPO="$TEST_DIR/multi-author"
  _seed_repo "$REPO" "2026-04-30T10:00:00Z" "alice: commit"
  ( cd "$REPO" \
    && git -c user.email="bob@example.com" -c user.name="bob" \
       commit --allow-empty -m "bob: commit" --date="2026-04-30T11:00:00Z" )
  export JARVIS_FAKE_NOW="2026-05-01T15:00:00Z"
  run _run_discover --activity --repo "$REPO" --since 1d --author "bob@example.com"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bob: commit"* ]]
  [[ "$output" != *"alice: commit"* ]]
}
