#!/usr/bin/env bash
# standup discover — two modes, one config.
#
#   --scan (default)
#     Walk a root (default ~/src if it exists, else $HOME) for `.git`
#     directories, then write `[standup] repos = [...]` to the profile's
#     config.toml. This is the one-shot setup helper for `--all-repos`.
#
#   --activity [--since 1d] [--repo <dir>]
#     Read `[standup] repos` from config (or use --repo for ad-hoc),
#     iterate each repo, and emit commit NDJSON via
#     lib/integrations/git.sh::git_commits_since. Filtered by the local
#     repo's `git config user.email`. The standup cmd consumes the same
#     NDJSON shape, so this is the underlying activity feed surfaced as
#     its own command for inspection / piping.
#
# Mode is determined by --activity presence; otherwise --scan is implicit.
#
# Scan flags:
#   --write           skip prompt; overwrite [standup].repos
#   --append          merge into existing repos (de-duplicate)
#   --json            emit JSON array (no prompt, no write)
#   --max-depth N     override the default maxdepth=4
#   --root <DIR>      override the default root
#   --yes / -y        skip prompt; assume yes
#
# Activity flags:
#   --since <window>  Ns / Nm / Nh / Nd / Nw (default 1d).
#                     d / w units anchor to start-of-day UTC, matching
#                     the standup cmd's window semantics.
#   --repo <DIR>      single-repo override; skips the config read.
#   --author <EMAIL>  override the per-repo user.email author filter.
#
# Exit codes:
#   0   ok (wrote / printed / emitted)
#   1   no repos found (scan) / no [standup].repos configured (activity)
#   2   bad flag / invalid arg
#   3   user declined the y/N prompt

set -euo pipefail

: "${FRAMEWORK_DIR:=${CLIFT_FRAMEWORK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}}"
: "${CLI_DIR:=${JARVIS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"

# shellcheck source=/dev/null
source "${FRAMEWORK_DIR}/lib/log/log.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/profile.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/config.sh"

if ! declare -p CLIFT_FLAGS >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/runtime/standalone_argv.sh"
  jarvis_standalone_argv_parse \
    '[{"name":"write","type":"bool"},
      {"name":"append","type":"bool"},
      {"name":"json","type":"bool"},
      {"name":"max-depth","type":"string"},
      {"name":"root","type":"string"},
      {"name":"yes","short":"y","type":"bool"},
      {"name":"activity","type":"bool"},
      {"name":"since","short":"S","type":"string"},
      {"name":"repo","short":"r","type":"string"},
      {"name":"author","type":"string"}]' \
    "$@"
fi

want_write="${CLIFT_FLAGS[write]:-}"
want_append="${CLIFT_FLAGS[append]:-}"
want_json="${CLIFT_FLAGS[json]:-}"
want_yes="${CLIFT_FLAGS[yes]:-}"
want_activity="${CLIFT_FLAGS[activity]:-}"
max_depth="${CLIFT_FLAGS[max-depth]:-4}"
since_flag="${CLIFT_FLAGS[since]:-1d}"
repo_flag="${CLIFT_FLAGS[repo]:-}"
author_flag="${CLIFT_FLAGS[author]:-}"

profile_dir="$(state_profile_dir)"
cfg="$profile_dir/config.toml"

# ============================================================ activity
# Reads [standup] repos (or --repo) and emits commit NDJSON. Uses the
# same git.sh helper that standup consumes so the two views are
# guaranteed to agree.
if [[ "$want_activity" == "true" ]]; then
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/integrations/git.sh"
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/native/clock.sh"

  # --since resolution mirrors standup.sh: d/w units anchor to
  # start-of-day UTC; sub-day units are rolling. Bad input → 1d.
  now_iso="$(native_now_iso)"
  now_epoch="$(native_now_epoch)"
  anchor_epoch="$now_epoch"
  if [[ "$since_flag" =~ ^([0-9]+)([smhdw])$ ]]; then
    n="${BASH_REMATCH[1]}"; u="${BASH_REMATCH[2]}"
    case "$u" in
      s) sec=$n ;;
      m) sec=$((n*60)) ;;
      h) sec=$((n*3600)) ;;
      d) sec=$((n*86400));  anchor_epoch="$(native_resolve_to_epoch "$(native_day_start "$now_iso")")" ;;
      w) sec=$((n*604800)); anchor_epoch="$(native_resolve_to_epoch "$(native_day_start "$now_iso")")" ;;
    esac
  else
    sec=86400
    anchor_epoch="$(native_resolve_to_epoch "$(native_day_start "$now_iso")")"
  fi
  since_epoch=$(( anchor_epoch - sec ))
  since_iso="$(native_epoch_to_iso "$since_epoch")"

  # Build the repo list. --repo wins; otherwise read from config.
  repos=()
  if [[ -n "$repo_flag" ]]; then
    repos=("$repo_flag")
  else
    if [[ ! -f "$cfg" ]]; then
      printf 'standup discover --activity: no config at %s; run `standup discover` to populate or pass --repo\n' "$cfg" >&2
      exit 1
    fi
    if ! command -v dasel >/dev/null 2>&1; then
      printf 'standup discover --activity: dasel not on PATH (needed to read [standup] repos)\n' >&2
      exit 1
    fi
    repos_json="$(dasel -i toml -o json standup.repos < "$cfg" 2>/dev/null || true)"
    if [[ -z "$repos_json" || "$repos_json" == "null" ]]; then
      printf 'standup discover --activity: [standup] repos not set in %s\n' "$cfg" >&2
      exit 1
    fi
    while IFS= read -r r; do
      [[ -n "$r" ]] && repos+=("$r")
    done < <(jq -r '.[]?' <<< "$repos_json" 2>/dev/null)
  fi

  if (( ${#repos[@]} == 0 )); then
    printf 'standup discover --activity: no repos to scan\n' >&2
    exit 1
  fi

  # Each git_commits_since call streams its own NDJSON. Missing repos /
  # no user.email cases return 1 — we tolerate them silently here (the
  # stderr from git.sh itself surfaces the user.email diagnostic for the
  # user; tooling consumers can pipe stderr away).
  rc=0
  for r in "${repos[@]}"; do
    git_commits_since "$r" "$since_iso" "$now_iso" "$author_flag" || rc=$?
  done
  # rc=1 from a single missing repo isn't fatal — the activity stream is
  # still valid, just smaller. Exit 0 unless every repo failed (we don't
  # currently distinguish; one-line stderr makes it visible).
  exit 0
fi

# ============================================================ scan (default)
# Walk a root for .git directories and write/print the result. Default
# root: ~/src if it exists (platform engineers' convention), else $HOME.
default_root="$HOME"
if [[ -z "${CLIFT_FLAGS[root]:-}" && -d "$HOME/src" ]]; then
  default_root="$HOME/src"
fi
root="${CLIFT_FLAGS[root]:-$default_root}"

if [[ ! "$max_depth" =~ ^[0-9]+$ ]]; then
  clift_exit 2 "invalid --max-depth: $max_depth (expected positive integer)"
fi
if [[ ! -d "$root" ]]; then
  clift_exit 2 "--root path not found: $root"
fi

# Walk the root for `.git` directories, then strip the trailing `/.git` to
# yield repo roots. Filters: depth-bounded, dotdir-suppressed, common
# package-cache + system-bundle paths excluded so we don't traverse
# `~/.cargo/registry/.../some-crate-1.2.3/.git` etc.
_discover() {
  # `find -prune` shape: list each unwanted dir, then `-prune -o` to
  # short-circuit traversal under it; the -name '.git' clause comes last
  # with -print so only the survivors emit. Patterns include both leaf
  # names (.cache) and path components (.cargo/registry).
  find "$root" -maxdepth "$max_depth" \
    \( -type d \( \
         -name '.cache' -o -name '.Trash' -o -name 'node_modules' -o \
         -name 'Library' -o -name '.local' -o -name '.cargo' -o \
         -name '.rustup' -o -name '.npm' -o -name '.gem' -o \
         -name 'vendor' -o -name 'target' -o -name 'dist' -o \
         -name '__pycache__' -o -name '.venv' -o -name 'venv' \
       \) -prune \) -o \
    \( -type d -name '.git' -print \) 2>/dev/null \
    | sed 's:/\.git$::' \
    | sort -u
}

discovered="$(_discover || true)"
if [[ -z "$discovered" ]]; then
  printf 'standup discover: no git repos under %s (max-depth %s)\n' \
    "$root" "$max_depth" >&2
  exit 1
fi

# JSON mode: emit and exit; no prompt, no write.
if [[ "$want_json" == "true" ]]; then
  printf '%s\n' "$discovered" | jq -Rcs 'split("\n") | map(select(length > 0))'
  exit 0
fi

# Pretty-print the list to stderr so the prompt + count is informative
# even when stdout is captured.
count="$(printf '%s\n' "$discovered" | grep -c .)"
printf 'discovered %d git repos under %s:\n' "$count" "$root" >&2
printf '%s\n' "$discovered" | sed 's/^/  /' >&2

# Default behavior: prompt y/N. --yes / --write skip the prompt.
should_write=0
if [[ "$want_write" == "true" || "$want_append" == "true" || "$want_yes" == "true" ]]; then
  should_write=1
elif [[ -t 0 ]]; then
  printf '\nwrite to %s as [standup].repos? [y/N] ' "$cfg" >&2
  read -r ans
  case "${ans,,}" in
    y|yes) should_write=1 ;;
    *)     should_write=0 ;;
  esac
else
  # Non-interactive without --write/--yes/--append → just printed; exit 0.
  exit 0
fi

if (( should_write == 0 )); then
  printf 'standup discover: declined; nothing written.\n' >&2
  exit 3
fi

# Build the new repos array. --append merges with the existing list
# (preserves existing entries, dedupes); --write replaces it.
# Build the merged JSON list. --append uses the existing repos array as
# a starting set; --write replaces. Existing array is read via dasel
# (read-only — dasel v3 dropped the put subcommand, so writes happen via
# section-rewrite below).
existing_json='[]'
if [[ "$want_append" == "true" && -f "$cfg" ]] && command -v dasel >/dev/null 2>&1; then
  existing_json="$(dasel -i toml -o json standup.repos < "$cfg" 2>/dev/null || printf '[]')"
  [[ "$existing_json" == "null" || -z "$existing_json" ]] && existing_json='[]'
fi
discovered_json="$(printf '%s\n' "$discovered" | jq -Rcs 'split("\n") | map(select(length > 0))')"
merged_json="$(jq -nc --argjson e "$existing_json" --argjson d "$discovered_json" \
  '($e + $d) | unique')"
merged_count="$(jq -r 'length' <<< "$merged_json")"

# Section-rewrite write path. dasel v3 has no in-place edit subcommand,
# and embedding a stable third-party TOML editor is more dep weight than
# this is worth, so we hand-rewrite just the `[standup]` section:
#
#   1. If config.toml is missing → create with [standup] block.
#   2. If config.toml exists with no [standup] section → append one.
#   3. If config.toml exists with [standup] → replace that section
#      verbatim, preserving everything before / after.
#
# A more complete TOML mutator would need to track in-flight tables,
# array-of-tables, and inline arrays; this is scoped to one section so
# the awk scanner stays under 20 lines.
mkdir -p "$profile_dir"
new_section="$(
  printf '[standup]\nrepos = [\n'
  jq -r '.[]' <<< "$merged_json" | awk '{printf "  \"%s\",\n", $0}'
  printf ']\n'
)"

if [[ ! -f "$cfg" ]]; then
  printf '%s\n' "$new_section" > "$cfg"
elif ! grep -qE '^\[standup\]' "$cfg"; then
  # Existing config without a [standup] section — append.
  {
    [[ -s "$cfg" ]] && printf '\n'
    printf '%s\n' "$new_section"
  } >> "$cfg"
else
  # Existing [standup] section — replace it. awk:
  #   skip lines from `[standup]` up to (but not including) the next
  #   `[<other>]` table header or EOF; emit the new section in place.
  tmp="$(mktemp)"
  awk -v new_section="$new_section" '
    BEGIN { in_section = 0; emitted = 0 }
    /^\[standup\][[:space:]]*$/ {
      in_section = 1
      print new_section
      emitted = 1
      next
    }
    in_section && /^\[[^]]+\][[:space:]]*$/ {
      in_section = 0
    }
    !in_section { print }
  ' "$cfg" > "$tmp"
  mv "$tmp" "$cfg"
fi

log_success "wrote ${merged_count} repos to ${cfg}"
