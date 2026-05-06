#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

load helper

setup() {
  jarvis_common_setup
  mkdir -p "$JARVIS_HOME/test/tasks"
  printf '1\n' > "$JARVIS_HOME/test/state.version"
  export FRAMEWORK_DIR="$CLIFT_FRAMEWORK_DIR"
  export CLI_DIR="$JARVIS_DIR"
}
teardown() { jarvis_common_teardown; }

invoke() {
  # Usage: invoke <cmd-script> [flag=val ...] -- [pos1]
  local script="$1"; shift
  local -A flags=()
  local pos1=""
  local saw_sep=0
  for arg in "$@"; do
    if [[ "$arg" == "--" ]]; then saw_sep=1; continue; fi
    if (( saw_sep )); then pos1="$arg"; continue; fi
    flags["${arg%%=*}"]="${arg#*=}"
  done
  local assign=""
  for k in "${!flags[@]}"; do
    assign="$assign [$k]=\"${flags[$k]}\""
  done
  bash -c '
    set -euo pipefail
    declare -A CLIFT_FLAGS=('"$assign"')
    export CLIFT_POS_1="'"$pos1"'"
    source "$1"
  ' _ "$CLI_DIR/cmds/task/$script"
}

@test "full round-trip: add -> list -> done -> list excludes -> edit -> remove" {
  # 1. Add two tasks.
  run invoke task.add.sh priority=high -- "Fix k3s etcd"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "fix-k3s-etcd" ]

  run invoke task.add.sh priority=med due=today -- "Ship VHS demos"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "ship-vhs-demos" ]

  # 2. list --json shows both open.
  run invoke task.list.sh json=true --
  [ "$status" -eq 0 ]
  [ "$(jq -r 'length' <<< "$output")" = "2" ]

  # 3. done via prefix.
  run invoke task.done.sh -- "fix-k3s"
  [ "$status" -eq 0 ]

  # 4. list excludes done by default.
  run invoke task.list.sh json=true --
  [ "$(jq -r 'length' <<< "$output")" = "1" ]
  [ "$(jq -r '.[0].slug' <<< "$output")" = "ship-vhs-demos" ]

  # 5. list --all includes done.
  run invoke task.list.sh all=true json=true --
  [ "$(jq -r 'length' <<< "$output")" = "2" ]

  # 6. edit --priority.
  run invoke task.edit.sh priority=high -- "ship-vhs"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.priority' "$JARVIS_HOME/test/tasks/ship-vhs-demos.json")" = "high" ]

  # 7. remove.
  run invoke task.remove.sh -- "ship-vhs-demos"
  [ "$status" -eq 0 ]
  [ ! -f "$JARVIS_HOME/test/tasks/ship-vhs-demos.json" ]

  # 8. final list: only the done fix-k3s-etcd (when --all).
  run invoke task.list.sh all=true json=true --
  [ "$(jq -r 'length' <<< "$output")" = "1" ]
  [ "$(jq -r '.[0].slug' <<< "$output")" = "fix-k3s-etcd" ]
  [ "$(jq -r '.[0].status' <<< "$output")" = "done" ]
}

@test "collision path: same description twice yields <slug> and <slug>-2" {
  run invoke task.add.sh -- "Audit flock path"
  [ "${lines[-1]}" = "audit-flock-path" ]
  run invoke task.add.sh -- "Audit flock path"
  [ "${lines[-1]}" = "audit-flock-path-2" ]
  [ -f "$JARVIS_HOME/test/tasks/audit-flock-path.json" ]
  [ -f "$JARVIS_HOME/test/tasks/audit-flock-path-2.json" ]
}
