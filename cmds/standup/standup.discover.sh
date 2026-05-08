#!/usr/bin/env bash
# standup discover — walk $HOME for git repos and populate the
# `[standup] repos = [...]` config so `--all-repos` stops being a manual
# list-maintenance task.
#
# Default: shallow walk ($HOME, max depth 4) excluding common dotdir +
# package-store paths (.git/, .Trash, node_modules, .cache/, Library/, etc.).
# Behavior is deterministic (sorted output) so re-running yields the same
# config.
#
# Modes:
#   default:           print discovered paths to stdout, prompt y/N to write
#   --write:           skip prompt; overwrite [standup].repos in config.toml
#   --append:          merge into existing repos (de-duplicate)
#   --json:            emit a JSON array (no prompt, no write)
#   --max-depth N:     override the default maxdepth=4
#   --root <DIR>:      override the default root ($HOME)
#
# Exit codes:
#   0   wrote config / printed json / user accepted prompt
#   1   no repos found in the walk
#   2   bad flag
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
      {"name":"yes","short":"y","type":"bool"}]' \
    "$@"
fi

want_write="${CLIFT_FLAGS[write]:-}"
want_append="${CLIFT_FLAGS[append]:-}"
want_json="${CLIFT_FLAGS[json]:-}"
want_yes="${CLIFT_FLAGS[yes]:-}"
max_depth="${CLIFT_FLAGS[max-depth]:-4}"
root="${CLIFT_FLAGS[root]:-$HOME}"

if [[ ! "$max_depth" =~ ^[0-9]+$ ]]; then
  clift_exit 2 "invalid --max-depth: $max_depth (expected positive integer)"
fi
if [[ ! -d "$root" ]]; then
  clift_exit 2 "--root path not found: $root"
fi

profile_dir="$(state_profile_dir)"
cfg="$profile_dir/config.toml"

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
