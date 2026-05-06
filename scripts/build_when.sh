#!/usr/bin/env bash
# build_when.sh — Stages jarvis-when as an executable script in bin/.
#
# jarvis-when is single-file pure-stdlib Python (no pip install, no zipapp).
# Build = copy + chmod. Source lives at jarvis-when/src/jarvis_when.py.
#
# Must be invoked from the jarvis CLI root so the
# Taskfile's relative paths resolve correctly.

set -euo pipefail

JARVIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$JARVIS_DIR/jarvis-when/src/jarvis_when.py"
DEST="$JARVIS_DIR/bin/jarvis-when"

if [[ ! -f "$SRC" ]]; then
  printf 'build_when: missing source %s\n' "$SRC" >&2
  exit 1
fi

mkdir -p "$JARVIS_DIR/bin"
# Copy via temp + mv so a partial copy never appears under DEST.
tmp="$DEST.tmp.$$"
cp "$SRC" "$tmp"
chmod +x "$tmp"
mv "$tmp" "$DEST"
