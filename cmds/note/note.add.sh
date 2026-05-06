#!/usr/bin/env bash
set -euo pipefail

# Resolve framework/CLI dirs with fallback so this script runs standalone in tests.
: "${FRAMEWORK_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
: "${CLI_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# shellcheck source=/dev/null
source "${FRAMEWORK_DIR}/lib/log/log.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/profile.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/lock.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/json.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/slug.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/frontmatter.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/note/resolve.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/note/index.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/note/store.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/note/current.sh"

# CLIFT_FLAGS may not be declared when invoked standalone (tests, direct
# calls). In that case, parse argv via the shared jarvis helper — the
# router path leaves $@ empty and sets CLIFT_FLAGS + CLIFT_FLAG_TAG_*, and
# the helper mirrors that contract from raw argv.
if ! declare -p CLIFT_FLAGS >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/runtime/standalone_argv.sh"
  jarvis_standalone_argv_parse \
    '[{"name":"tag","type":"list"},{"name":"on","type":"string"},{"name":"no-timestamp","type":"bool"},{"name":"format","type":"string"}]' \
    "$@"
fi

body="${CLIFT_POS_1:-}"
on="${CLIFT_FLAGS[on]:-}"
no_ts="${CLIFT_FLAGS[no-timestamp]:-}"
fmt="${CLIFT_FLAGS[format]:-}"

if [[ -z "$body" ]]; then
  clift_exit 2 "usage: jarvis note <body> [--tag NAME]... [--on TARGET] [--no-timestamp] [--format STRFTIME]"
fi

state_ensure_tree

# Collect tags (list flag) into a JSON array.
tag_count="${CLIFT_FLAG_TAG_COUNT:-0}"
tags_json="[]"
if (( tag_count > 0 )); then
  tag_args=()
  for (( i=1; i<=tag_count; i++ )); do
    var="CLIFT_FLAG_TAG_${i}"
    tag_args+=("${!var}")
  done
  tags_json="$(printf '%s\n' "${tag_args[@]}" | jq -R . | jq -sc .)"
fi

# Build append-flag array with safe expansion under `set -u`.
append_flags=()
if [[ "$no_ts" == "true" || "$no_ts" == "1" ]]; then
  append_flags+=(--no-timestamp)
fi
if [[ -n "$fmt" ]]; then
  append_flags+=(--format "$fmt")
fi

# _create_in_inbox <title> — mint a new inbox/<slug> note from a title string.
# Emits the resolved key on stdout. Tolerates the create-race: if a concurrent
# writer already claimed the same slug, re-resolve and yield the next free
# candidate. The final return value is the key that *this* invocation creates.
_create_in_inbox() {
  local title="$1"
  local base
  base="$(slug_from_desc "$title")" || clift_exit 2 "title is empty after slug normalization"
  local inbox_dir
  inbox_dir="$(note_root)/inbox"
  mkdir -p "$inbox_dir"
  local candidate="$base" n=2
  # Retry loop: slug_resolve_collision, then attempt note_store_new. If the
  # store reports "already exists" (another writer won), bump the suffix and
  # retry. Cap at 50 attempts — beyond that, something is broken.
  local attempt=0 max=50
  while (( attempt < max )); do
    while [[ -e "$inbox_dir/$candidate.md" ]]; do
      candidate="${base}-${n}"
      n=$((n + 1))
    done
    if note_store_new inbox "$candidate" "$title" --tags "$tags_json" >/dev/null 2>&1; then
      printf '%s\n' "inbox/$candidate"
      return 0
    fi
    # Collision with a concurrent writer — bump and retry.
    candidate="${base}-${n}"
    n=$((n + 1))
    attempt=$((attempt + 1))
  done
  clift_exit 1 "inbox create-retry exhausted for: $title"
}

# _ensure_daily <kind/slug> — create daily/<date> from the daily template if
# absent. No-op (including under concurrent creation) if the file lands on
# disk by the time we re-check. Echoes the key.
_ensure_daily() {
  local key="$1"
  local date="${key#daily/}"
  local file
  file="$(note_path "$key")"
  if [[ ! -f "$file" ]]; then
    # Tolerate races: if two writers hit this simultaneously, one wins the
    # store's collision guard and the other sees "already exists" — either
    # way, as long as the file ends up on disk, we're good.
    note_store_new daily "$date" "$date" \
      --template "$CLI_DIR/templates/daily.md" \
      --tags "$tags_json" >/dev/null 2>&1 || true
    [[ -f "$file" ]] || clift_exit 1 "daily auto-create failed: $key"
  fi
  printf '%s\n' "$key"
}

# Resolve --on TARGET, distinguishing miss (create) from ambiguous (abort).
# Returns the resolved key on stdout, or clift_exits on the ambiguous path.
_resolve_on_target() {
  local query="$1"
  local resolved rc
  # Capture stderr into a variable while keeping stdout for the key.
  # Run note_resolve in a subshell and reconstruct: stdout → key, stderr → msg,
  # exit code → branch.
  local stderr_tmp stdout_tmp
  stderr_tmp="$(mktemp)"
  stdout_tmp="$(mktemp)"
  set +e
  note_resolve "$query" >"$stdout_tmp" 2>"$stderr_tmp"
  rc=$?
  set -e
  resolved="$(<"$stdout_tmp")"
  local msg
  msg="$(<"$stderr_tmp")"
  rm -f "$stdout_tmp" "$stderr_tmp"
  case "$rc" in
    0)
      printf '%s\n' "$resolved"
      return 0
      ;;
    1)
      # Miss → create in inbox.
      _create_in_inbox "$query"
      return 0
      ;;
    2)
      # Ambiguous → surface candidates and abort.
      [[ -n "$msg" ]] && printf '%s\n' "$msg" >&2
      clift_exit 2 "refusing to create on ambiguous target: $query"
      ;;
    *)
      [[ -n "$msg" ]] && printf '%s\n' "$msg" >&2
      clift_exit "$rc" "note_resolve failed for: $query"
      ;;
  esac
}

target=""
if [[ -n "$on" ]]; then
  # --on TARGET: resolve (and create on miss; abort on ambiguity).
  target="$(_resolve_on_target "$on")"
else
  # No --on: consult current-note state via the single-source-of-truth resolver.
  set +e
  current_key="$(note_current_resolve 2>/dev/null)"
  current_rc=$?
  set -e
  case "$current_rc" in
    0)
      # Current is set. kind=daily may point to a file that doesn't exist yet;
      # slug=<kind>/<slug> must point to an existing note.
      case "$current_key" in
        daily/*)
          target="$(_ensure_daily "$current_key")"
          ;;
        *)
          [[ -f "$(note_path "$current_key")" ]] \
            || clift_exit 1 "current note target missing: $current_key"
          target="$current_key"
          ;;
      esac
      ;;
    1)
      # No current set → quick-capture: mint inbox/<slug-from-body>.
      target="$(_create_in_inbox "$body")"
      log_success "$target"
      exit 0
      ;;
    2|*)
      clift_exit 1 "current note state malformed"
      ;;
  esac
fi

# Append path (used for --on and current-note routing).
note_store_append "$target" "$body" ${append_flags[@]+"${append_flags[@]}"}
log_success "$target"
