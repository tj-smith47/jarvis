#!/usr/bin/env bash
# Task record store for jarvis.
# Builds on state/{profile,lock,json}.sh — expects them sourced first.

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_TASK_STORE_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_TASK_STORE_LOADED=1

task_store_dir() {
  printf '%s/tasks\n' "$(state_profile_dir)"
}

task_store_now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

task_store_path() {
  printf '%s/%s.json\n' "$(task_store_dir)" "$1"
}

task_store_exists() {
  [[ -f "$(task_store_path "$1")" ]]
}

# Monotonic per-profile sequence. Persisted at tasks/.seq, flock-guarded.
# Initialization is performed inside the lock to avoid a TOCTOU race where
# a late initializer could clobber an already-advanced counter.
#
# Seq-gap invariant: the sequence is bumped before the task file is
# written, so a write failure between bump and persist consumes a number
# without producing a record. Gaps are invisible to users (seq is an
# internal ordering key, never displayed); the cap on slug length and
# atomic-rename writes make the failure window negligible. Revisit if a
# downstream consumer ever depends on contiguity.
task_store_next_seq() {
  local dir seq_file
  dir="$(task_store_dir)"
  mkdir -p "$dir"
  seq_file="$dir/.seq"
  # The leading single-quoted segment ends before $seq_file so the path is
  # embedded as a literal in the eval'd command string; the trailing segment
  # resumes single quoting. SC2016 fires on the literal text in between.
  # shellcheck disable=SC2016
  state_with_lock "$seq_file" '
    sf='"'$seq_file'"'
    [[ -s "$sf" ]] || printf "0\n" > "$sf"
    current=$(< "$sf")
    next=$(( current + 1 ))
    printf "%s\n" "$next" > "$sf"
    printf "%s\n" "$next"
  '
}

# task_store_build <slug> <desc> <priority> <due> <project> <seq> <jira_key>
# Empty due/jira_key → JSON null. Emits one JSON object.
task_store_build() {
  local slug="$1" desc="$2" priority="$3" due="$4" project="$5" seq="$6" jira="$7"
  local now
  now="$(task_store_now_iso)"
  jq -n \
    --arg slug "$slug" \
    --arg desc "$desc" \
    --arg priority "$priority" \
    --arg due "$due" \
    --arg project "$project" \
    --arg now "$now" \
    --argjson seq "$seq" \
    --arg jira "$jira" \
    '{
      slug: $slug,
      desc: $desc,
      status: "open",
      priority: $priority,
      due: (if $due == "" or $due == "null" then null else $due end),
      project: $project,
      created_at: $now,
      updated_at: $now,
      done_at: null,
      seq: $seq,
      jira_key: (if $jira == "" or $jira == "null" then null else $jira end)
    }'
}

task_store_get() {
  state_json_read "$(task_store_path "$1")"
}

# Slug shape per slug_from_desc: lowercase alnum + internal hyphens, must
# start and end with alnum. Reject anything outside that — most importantly
# dot-prefixes (would silently vanish from `*.json` globs in
# task_store_list) and `..`/`/` traversal.
_task_store_valid_slug() {
  [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]
}

task_store_put() {
  local slug="$1" payload="$2"
  if ! _task_store_valid_slug "$slug"; then
    printf 'task_store_put: invalid slug "%s"\n' "$slug" >&2
    return 2
  fi
  state_json_write "$(task_store_path "$slug")" "$payload"
}

task_store_delete() {
  local slug path
  slug="$1"
  path="$(task_store_path "$slug")"
  rm -f "$path" "$path.lock"
  # Tmp sidecars left from an aborted state_json_write/mutate.
  # Save/restore nullglob so the unquoted glob behaves identically
  # regardless of caller shell options (matches task_store_list pattern).
  # Note: this intentionally does NOT touch .seq or .seq.lock — those are
  # per-profile, persisting across individual task lifetimes.
  local had_nullglob=0
  shopt -q nullglob && had_nullglob=1
  shopt -s nullglob
  local sidecars=("$path".tmp.*)
  (( had_nullglob )) || shopt -u nullglob
  if (( ${#sidecars[@]} > 0 )); then
    rm -f "${sidecars[@]}"
  fi
}

# task_store_list [status]
# Emits slugs one-per-line in seq order. Filters by status when given.
# Saves/restores nullglob so callers' shell options are untouched.
# Skips corrupt records with a stderr warning rather than aborting the
# whole list — one hand-edited bad file shouldn't lose visibility on the
# rest of the user's tasks.
task_store_list() {
  local status="${1:-}"
  local dir
  dir="$(task_store_dir)"
  [[ -d "$dir" ]] || return 0
  local had_nullglob=0
  shopt -q nullglob && had_nullglob=1
  shopt -s nullglob
  local files=("$dir"/*.json)
  (( had_nullglob )) || shopt -u nullglob
  (( ${#files[@]} )) || return 0

  local valid=()
  local f
  for f in "${files[@]}"; do
    if jq -e . "$f" >/dev/null 2>&1; then
      valid+=("$f")
    else
      printf 'task_store_list: skipping corrupt record %s\n' "$f" >&2
    fi
  done
  (( ${#valid[@]} )) || return 0

  if [[ -n "$status" ]]; then
    jq -r --arg s "$status" -s 'map(select(.status == $s)) | sort_by(.seq) | .[].slug' "${valid[@]}"
  else
    jq -r -s 'sort_by(.seq) | .[].slug' "${valid[@]}"
  fi
}

task_store_set_done() {
  local slug="$1"
  local now
  now="$(task_store_now_iso)"
  state_json_mutate "$(task_store_path "$slug")" \
    ".status = \"done\" | .done_at = \"$now\" | .updated_at = \"$now\""
}

# task_store_mutate <slug> <jq-filter> [--arg NAME VALUE ...]
# Applies filter to existing record, bumps updated_at, rewrites.
# Read → jq → write runs inside a single flock window (state_json_mutate),
# so concurrent mutators on the same slug serialize without lost updates.
# Optional --arg pairs thread through to jq, letting callers bind values
# safely as \$NAME instead of embedding them in the filter text.
task_store_mutate() {
  local slug="$1" filter="$2"
  shift 2
  local now
  now="$(task_store_now_iso)"
  state_json_mutate "$(task_store_path "$slug")" \
    "$filter | .updated_at = \"$now\"" "$@"
}
