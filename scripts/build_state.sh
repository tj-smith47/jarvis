#!/usr/bin/env bash
# build_state.sh — Compiles jarvis-state (Go) and stages it at bin/jarvis-state.
#
# Static-linked by default (CGO_ENABLED=0); strips DWARF + Go symbol table
# so the binary stays small and fast to mmap.

set -euo pipefail

JARVIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$JARVIS_DIR/jarvis-state"
DEST="$JARVIS_DIR/bin/jarvis-state"

if [[ ! -f "$SRC_DIR/go.mod" ]]; then
  printf 'build_state: missing %s\n' "$SRC_DIR/go.mod" >&2
  exit 1
fi

mkdir -p "$JARVIS_DIR/bin"

# Build into a tmp path then atomic-rename, so a partial build never replaces
# a working binary in place.
tmp="$DEST.tmp.$$"
(
  cd "$SRC_DIR"
  CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o "$tmp" .
)
chmod +x "$tmp"
mv "$tmp" "$DEST"
