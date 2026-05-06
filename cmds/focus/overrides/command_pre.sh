#!/usr/bin/env bash
# command_pre override — runs before the user script. Overrides run outside
# the runtime prelude, so CLIFT_FLAGS assoc array isn't declared yet; use
# the always-exported CLIFT_FLAG_<NAME> env-var form here.
log_info "▶ focus session starting: ${CLIFT_POS_1:-?} on ${CLIFT_FLAG_ON:-unspecified}"
