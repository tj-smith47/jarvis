#!/usr/bin/env bash
# YAML frontmatter parse/emit/mutate/merge for jarvis notes.
# Reuses dasel (project-wide dep) for YAML<->JSON. Body operations stay in pure bash.
#
# Library — intentionally does NOT set `set -euo pipefail`; options are
# inherited from the caller (matches lib/slug.sh, lib/state/*.sh convention).
# fm_emit output ends with a newline; callers using "$(fm_emit ...)" will lose
# it due to command-substitution stripping — use printf '%s\n' or redirect.

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_FRONTMATTER_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_FRONTMATTER_LOADED=1

# fm_split <file> <body-var> <fm-var>
# Populates body-var and fm-var. fm is empty if no frontmatter present.
# NOTE: command substitution in `$(<"$file")` strips any trailing newline
# from the file — callers that re-emit the body must normalize it back.
fm_split() {
  # Local names are underscore-prefixed to avoid shadowing caller-supplied
  # variable names (e.g. callers typically pass "body" and "fm").
  local _fm_file="$1" _fm_body_var="$2" _fm_fm_var="$3"
  local _fm_content _fm_out_fm="" _fm_out_body=""
  _fm_content="$(<"$_fm_file")"
  if [[ "$_fm_content" == "---"$'\n'* ]]; then
    local _fm_rest="${_fm_content#---$'\n'}"
    if [[ "$_fm_rest" == *$'\n'---$'\n'* ]]; then
      _fm_out_fm="${_fm_rest%%$'\n'---$'\n'*}"
      _fm_out_body="${_fm_rest#*$'\n'---$'\n'}"
    elif [[ "$_fm_rest" == *$'\n'--- ]]; then
      _fm_out_fm="${_fm_rest%$'\n'---}"
      _fm_out_body=""
    else
      _fm_out_fm=""
      _fm_out_body="$_fm_content"
    fi
  else
    _fm_out_body="$_fm_content"
  fi
  printf -v "$_fm_body_var" '%s' "$_fm_out_body"
  printf -v "$_fm_fm_var" '%s' "$_fm_out_fm"
}

fm_parse() {
  local file="$1"
  local body="" fm=""
  fm_split "$file" body fm
  if [[ -z "$fm" ]]; then
    printf '{}\n'
    return 0
  fi
  local json
  if ! json="$(dasel -i yaml -o json <<< "$fm" 2>/dev/null)"; then
    printf 'frontmatter: malformed YAML in %s\n' "$file" >&2
    return 1
  fi
  printf '%s\n' "$json"
}

fm_body() {
  local file="$1"
  local body="" fm=""
  fm_split "$file" body fm
  printf '%s' "$body"
}

fm_emit() {
  local json="$1"
  local yaml
  yaml="$(dasel -i json -o yaml <<< "$json")"
  printf -- '---\n%s\n---\n' "$yaml"
}

# fm_get <file> <dotted-key> [default]
# Dotted-key paths use "." as separator. Keys containing literal dots are not
# addressable via this API; use fm_parse + jq directly for those.
# Path segments are resolved type-aware: digit-only segments index arrays
# numerically (so "tags.0" works), but are treated as literal string keys
# when the current node is an object (so "scores.2024" still resolves
# against `{ "scores": { "2024": ... } }`).
# Returns the literal scalar (including `false` / `0`); default fires only when
# the key is absent (path resolves to null / missing).
fm_get() {
  local file="$1" key="$2" default="${3:-}"
  local json val
  if ! json="$(fm_parse "$file")"; then
    printf '%s\n' "$default"
    return 0
  fi
  val="$(jq -r --arg k "$key" '
    def walk($path; $idx):
      if . == null then null
      elif ($idx == ($path | length)) then .
      else
        ($path[$idx]) as $seg |
        if (type == "array" and ($seg | test("^[0-9]+$"))) then
          ($seg | tonumber) as $i |
          (if $i < length then .[$i] else null end) | walk($path; $idx + 1)
        elif (type == "object" and (has($seg))) then
          .[$seg] | walk($path; $idx + 1)
        else
          null
        end
      end;
    ($k | split(".")) as $path |
    walk($path; 0) as $v |
    if $v == null then empty else $v end
  ' <<< "$json" 2>/dev/null)"
  if [[ -z "$val" ]]; then
    printf '%s\n' "$default"
  else
    printf '%s\n' "$val"
  fi
}

# fm_set <file> <dotted-key> <value>
# Atomic in-place mutation (tmp + rename). Dotted-key semantics match fm_get.
# Value typing: the argument is parsed as a JSON scalar where possible — so
# `false`/`true` become booleans, integers/floats become numbers, otherwise
# the value is stored as a string. Edge case: a literal string `"5"` is
# coerced to the number `5`; use fm_parse + jq directly if you need to force
# a quoted string for a numeric-looking value.
fm_set() {
  local file="$1" key="$2" value="$3"
  local body="" fm="" fm_json updated yaml tmp value_json
  fm_split "$file" body fm
  if [[ -z "$fm" ]]; then
    fm_json="{}"
  else
    if ! fm_json="$(dasel -i yaml -o json <<< "$fm" 2>/dev/null)"; then
      printf 'frontmatter: malformed YAML in %s\n' "$file" >&2
      return 1
    fi
  fi
  # Auto-detect JSON-typed scalars (boolean / number / null); fall back to
  # string for anything else (including parse failures).
  value_json="$(jq -n --arg v "$value" '
    (try ($v | fromjson) catch $v) as $parsed |
    if ($parsed | type) | IN("boolean","number","null") then $parsed
    else $v
    end
  ')"
  updated="$(jq --arg k "$key" --argjson v "$value_json" '
    ($k | split(".")) as $p | setpath($p; $v)
  ' <<< "$fm_json")"
  yaml="$(dasel -i json -o yaml <<< "$updated")"
  # Normalize body to end in exactly one newline. fm_split drops the file's
  # trailing newline via command substitution; without this, repeated fm_set
  # calls would progressively truncate the body.
  case "$body" in
    '') ;;           # empty body — no trailing newline needed
    *$'\n') ;;       # already ends in a single newline
    *) body="${body}"$'\n' ;;
  esac
  tmp="${file}.tmp.$$.$BASHPID.$RANDOM"
  {
    printf -- '---\n%s\n---\n' "$yaml"
    printf '%s' "$body"
  } > "$tmp"
  mv -f "$tmp" "$file"
}

# fm_merge <template-json> <overrides-json>
# Precedence:
#   - pinned keys (slug|kind|created_at|updated_at): overrides win
#   - any other key declared on template: template wins
#   - keys present only on overrides (non-pinned): passed through so callers
#     can supply runtime data (e.g. attendees_present) without declaring it
#     in the template
#   - tags: set-union of both sides
fm_merge() {
  local template="$1" overrides="$2"
  jq -n --argjson t "$template" --argjson o "$overrides" '
    def pinned: ["slug","kind","created_at","updated_at"];
    def uniq_tags($a; $b): (($a // []) + ($b // [])) | unique;
    ($t // {}) as $T |
    ($o // {}) as $O |
    # Seed with overrides so override-only keys survive, then let template
    # win on collisions, then re-apply override pinned keys on top.
    ($O + $T
      + ($O | with_entries(select(.key as $k | pinned | index($k))))
    ) as $base |
    $base
      | (if ($T.tags or $O.tags) then .tags = uniq_tags($T.tags; $O.tags) else . end)
  '
}
