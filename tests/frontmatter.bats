#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

load helper

setup() {
  jarvis_common_setup
  source "$JARVIS_DIR/lib/frontmatter.sh"
  NOTE="$TEST_DIR/sample.md"
  cat > "$NOTE" <<'EOF'
---
title: sample
slug: sample
kind: inbox
tags: [a, b]
append:
  timestamp: true
  format: "## %Y-%m-%d %H:%M"
---
body line one

body line two
EOF
}
teardown() { jarvis_common_teardown; }

@test "fm_parse returns JSON with top-level and nested keys" {
  run fm_parse "$NOTE"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.title' <<< "$output")" = "sample" ]
  [ "$(jq -r '.tags | length' <<< "$output")" = "2" ]
  [ "$(jq -r '.append.timestamp' <<< "$output")" = "true" ]
}

@test "fm_parse returns {} for file without frontmatter" {
  printf 'no fm here\n' > "$NOTE"
  run fm_parse "$NOTE"
  [ "$output" = "{}" ]
}

@test "fm_body strips frontmatter and preserves body" {
  run fm_body "$NOTE"
  [[ "$output" == *"body line one"* ]]
  [[ "$output" != *"title: sample"* ]]
}

@test "fm_get returns nested key" {
  run fm_get "$NOTE" "append.format" ""
  [[ "$output" == *"%Y-%m-%d"* ]]
}

@test "fm_get returns default for missing key" {
  run fm_get "$NOTE" "nonexistent" "fallback"
  [ "$output" = "fallback" ]
}

@test "fm_get addresses object keys that look like integers" {
  cat > "$NOTE" <<'EOF'
---
scores:
  "2024": 100
  "2025": 200
tags: [a, b]
---
body
EOF
  run fm_get "$NOTE" "scores.2024" ""
  [ "$output" = "100" ]
  run fm_get "$NOTE" "scores.2025" ""
  [ "$output" = "200" ]
  run fm_get "$NOTE" "tags.0" ""
  [ "$output" = "a" ]
  run fm_get "$NOTE" "tags.1" ""
  [ "$output" = "b" ]
}

@test "fm_set mutates scalar in place preserving body" {
  fm_set "$NOTE" "title" "new-title"
  run fm_get "$NOTE" "title" ""
  [ "$output" = "new-title" ]
  run fm_body "$NOTE"
  [[ "$output" == *"body line one"* ]]
}

@test "fm_emit produces --- fences" {
  run fm_emit '{"title":"x","tags":["a","b"]}'
  [[ "$output" == "---"* ]]
  [[ "$output" == *"title: x"* ]]
}

@test "fm_merge: overrides win on pinned keys" {
  local tmpl='{"title":"tmpl","slug":"tmpl","kind":"meeting"}'
  local ovr='{"slug":"actual","kind":"inbox","created_at":"now","updated_at":"now"}'
  run fm_merge "$tmpl" "$ovr"
  [ "$(jq -r '.slug' <<< "$output")" = "actual" ]
  [ "$(jq -r '.kind' <<< "$output")" = "inbox" ]
  [ "$(jq -r '.created_at' <<< "$output")" = "now" ]
}

@test "fm_merge: template wins on non-pinned keys" {
  local tmpl='{"title":"Template Title","attendees":[]}'
  local ovr='{"slug":"x","kind":"meeting"}'
  run fm_merge "$tmpl" "$ovr"
  [ "$(jq -r '.title' <<< "$output")" = "Template Title" ]
  [ "$(jq '.attendees | type' <<< "$output")" = "\"array\"" ]
}

@test "fm_merge: tags are set-unioned" {
  run fm_merge '{"tags":["a","b"]}' '{"tags":["b","c"]}'
  local tags
  tags="$(jq -r '.tags | sort | join(",")' <<< "$output")"
  [ "$tags" = "a,b,c" ]
}

# --- Regression suite for commit 25728d8 follow-up fixes -------------------

# C1: fm_set must preserve exactly one trailing newline on body, and
# repeated fm_set invocations must leave byte-count stable after the first
# mutation (no progressive newline loss).
@test "fm_set preserves a single trailing newline on the body" {
  local f="$TEST_DIR/c1.md"
  printf -- '---\nfoo: 1\n---\nbody\n' > "$f"
  fm_set "$f" "foo" "2"
  # Last byte must be a single newline, and the previous byte must NOT be newline.
  local last prev
  last="$(tail -c 1 "$f" | od -An -c | tr -d ' ')"
  prev="$(tail -c 2 "$f" | head -c 1 | od -An -c | tr -d ' ')"
  [ "$last" = '\n' ]
  [ "$prev" != '\n' ]
}

@test "fm_set is idempotent in byte-count across repeated mutations" {
  local f="$TEST_DIR/c1b.md"
  printf -- '---\nfoo: 1\n---\nbody\n' > "$f"
  fm_set "$f" "foo" "2"
  local size1
  size1="$(wc -c < "$f")"
  fm_set "$f" "foo" "3"
  fm_set "$f" "foo" "4"
  local size3
  size3="$(wc -c < "$f")"
  [ "$size1" = "$size3" ]
}

# C2: fm_get must return literal `false` / `0` (not the default).
@test "fm_get returns literal 'false' for falsy boolean (not the default)" {
  local f="$TEST_DIR/c2.md"
  cat > "$f" <<'EOF'
---
enabled: false
count: 0
---
body
EOF
  run fm_get "$f" "enabled" "yes"
  [ "$output" = "false" ]
}

@test "fm_get returns literal '0' for zero (not the default)" {
  local f="$TEST_DIR/c2b.md"
  cat > "$f" <<'EOF'
---
enabled: false
count: 0
---
body
EOF
  run fm_get "$f" "count" "99"
  [ "$output" = "0" ]
}

# I1: fm_set must preserve JSON scalar typing (boolean / number / string).
@test "fm_set writes booleans as booleans (not quoted strings)" {
  local f="$TEST_DIR/i1.md"
  printf -- '---\ntitle: x\n---\nbody\n' > "$f"
  fm_set "$f" "enabled" "false"
  local t
  t="$(fm_parse "$f" | jq -r '.enabled | type')"
  [ "$t" = "boolean" ]
}

@test "fm_set writes numbers as numbers (not quoted strings)" {
  local f="$TEST_DIR/i1b.md"
  printf -- '---\ntitle: x\n---\nbody\n' > "$f"
  fm_set "$f" "count" "5"
  local t
  t="$(fm_parse "$f" | jq -r '.count | type')"
  [ "$t" = "number" ]
}

@test "fm_set writes plain words as strings" {
  local f="$TEST_DIR/i1c.md"
  printf -- '---\ntitle: x\n---\nbody\n' > "$f"
  fm_set "$f" "label" "hello"
  local t
  t="$(fm_parse "$f" | jq -r '.label | type')"
  [ "$t" = "string" ]
}

# I2: fm_merge must pass through override-only keys (non-pinned keys
# present on override but absent from template).
@test "fm_merge preserves override-only keys not declared on template" {
  run fm_merge '{"title":"T"}' '{"slug":"s","runtime_field":"observed"}'
  [ "$(jq -r '.runtime_field' <<< "$output")" = "observed" ]
}

@test "fm_merge: template wins on non-pinned collision" {
  run fm_merge '{"title":"T"}' '{"title":"O"}'
  [ "$(jq -r '.title' <<< "$output")" = "T" ]
}

# I4: fm_parse must fail loudly on malformed YAML.
@test "fm_parse exits nonzero with stderr diagnostic on malformed YAML" {
  local f="$TEST_DIR/i4.md"
  printf -- '---\n: bad yaml: here\n---\nbody\n' > "$f"
  run fm_parse "$f"
  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed YAML"* ]]
}
