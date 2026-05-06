#!/usr/bin/env bats
# Regression: jarvis standalone-argv helper.
#
# Standalone test invocations of jarvis command scripts can't rely on the
# router/parser pipeline having pre-populated CLIFT_FLAGS. This helper is
# the shared fallback — each command sources it and declares a JSON spec.

bats_require_minimum_version 1.5.0

load helper

setup() {
  jarvis_common_setup
  # Clear any residual globals from prior tests in the same shell (bats
  # reuses one shell per file unless @test blocks fork).
  unset CLIFT_FLAGS
  # shellcheck source=/dev/null
  source "$JARVIS_DIR/lib/runtime/standalone_argv.sh"
}
teardown() { jarvis_common_teardown; }

@test "scalar + bool + positional" {
  local spec='[{"name":"on","type":"string"},{"name":"no-ts","type":"bool"}]'
  jarvis_standalone_argv_parse "$spec" "body text" --on inbox/foo --no-ts
  [ "${CLIFT_FLAGS[on]}" = "inbox/foo" ]
  [ "${CLIFT_FLAGS[no-ts]}" = "true" ]
  [ "$CLIFT_POS_1" = "body text" ]
  [ "$CLIFT_POS_COUNT" = "1" ]
}

@test "list flag collects multiple values" {
  local spec='[{"name":"tag","type":"list"}]'
  jarvis_standalone_argv_parse "$spec" "x" --tag a --tag b --tag c
  [ "$CLIFT_FLAG_TAG_COUNT" = "3" ]
  [ "$CLIFT_FLAG_TAG_1" = "a" ]
  [ "$CLIFT_FLAG_TAG_2" = "b" ]
  [ "$CLIFT_FLAG_TAG_3" = "c" ]
  [ "$CLIFT_POS_1" = "x" ]
}

@test "--flag=value form" {
  local spec='[{"name":"on","type":"string"}]'
  jarvis_standalone_argv_parse "$spec" --on=inbox/foo "body"
  [ "${CLIFT_FLAGS[on]}" = "inbox/foo" ]
  [ "$CLIFT_POS_1" = "body" ]
}

@test "-- terminates flag parsing" {
  local spec='[{"name":"tag","type":"list"}]'
  jarvis_standalone_argv_parse "$spec" --tag hello -- --not-a-flag "positional"
  [ "$CLIFT_FLAG_TAG_COUNT" = "1" ]
  [ "$CLIFT_FLAG_TAG_1" = "hello" ]
  [ "$CLIFT_POS_1" = "--not-a-flag" ]
  [ "$CLIFT_POS_2" = "positional" ]
  [ "$CLIFT_POS_COUNT" = "2" ]
}

@test "dashed flag name normalizes to underscored env var" {
  local spec='[{"name":"multi-word","type":"list"}]'
  jarvis_standalone_argv_parse "$spec" --multi-word a --multi-word b
  [ "$CLIFT_FLAG_MULTI_WORD_COUNT" = "2" ]
  [ "$CLIFT_FLAG_MULTI_WORD_1" = "a" ]
  [ "$CLIFT_FLAG_MULTI_WORD_2" = "b" ]
}

@test "invalid spec returns 2" {
  run jarvis_standalone_argv_parse "not-json" x
  [ "$status" -eq 2 ]
}
