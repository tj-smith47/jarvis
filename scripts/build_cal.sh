#!/usr/bin/env bash
# build_cal.sh — Compiles jarvis-cal (Rust) and stages it at bin/jarvis-cal.
#
# Uses cargo's offline mode so the build is reproducible against the cached
# crates registry; pass JARVIS_CAL_OFFLINE=0 to allow cargo to fetch deps
# (first-time setup or dependency bumps).

set -euo pipefail

JARVIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE="$JARVIS_DIR/jarvis-cal"
DEST="$JARVIS_DIR/bin/jarvis-cal"

if [[ ! -f "$CRATE/Cargo.toml" ]]; then
  printf 'build_cal: missing %s\n' "$CRATE/Cargo.toml" >&2
  exit 1
fi

mkdir -p "$JARVIS_DIR/bin"

cargo_args=(build --release --manifest-path "$CRATE/Cargo.toml")
if [[ "${JARVIS_CAL_OFFLINE:-1}" == "1" ]]; then
  cargo_args+=(--offline)
fi

cargo "${cargo_args[@]}"

cp "$CRATE/target/release/jarvis-cal" "$DEST.tmp.$$"
chmod +x "$DEST.tmp.$$"
mv "$DEST.tmp.$$" "$DEST"
