#!/usr/bin/env python3
"""
Generate canonical NDJSON golden output from input fixtures.

Independent oracle -- does NOT use Go or Rust. Wave B's jarvis-state and
jarvis-cal binaries must emit byte-identical NDJSON for the same inputs.

Canonical encoding rules (all six are load-bearing):
  1. UTF-8 encoding, no BOM.
  2. Escape U+0000..U+001F per RFC 8259 (json.dumps does this by default
     when ensure_ascii=False -- the low codepoints are always escaped).
  3. ensure_ascii=False -- preserve non-ASCII Unicode as literal UTF-8
     (emoji, CJK, Arabic, Hebrew, combining characters, etc.).
  4. Compact separators (',', ':') -- no spaces after delimiters.
  5. Key order: start, end, title, url (LOAD-BEARING -- Go/Rust must match).
     The script reorders every object before serializing regardless of input
     key order, so fixtures can be authored in any order.
  6. One JSON object per line, terminated with a single newline.

Key-order note: Python's json.dumps does not guarantee dict insertion order
on output unless the dict is already ordered. We build an OrderedDict-style
list of (key, value) pairs in canonical order and pass it to json.dumps as
a plain dict via dict(). CPython 3.7+ preserves insertion order for dict,
so the output order is deterministic.

Usage:
  python3 scripts/build_ndjson_golden.py               # write to golden/
  python3 scripts/build_ndjson_golden.py --output DIR  # write to DIR
  python3 scripts/build_ndjson_golden.py --check       # diff vs committed golden; exit 1 on drift

Exit codes match the jarvis native binary contract:
  0  success
  1  config/tool missing (missing input directory, etc.)
  2  validation error (malformed input fixture)
  5  internal error
"""

from __future__ import annotations

import argparse
import difflib
import json
import os
import sys
from pathlib import Path

# Canonical key order -- matches the NDJSON contract spec in docs/ndjson-contract.md.
# Go (encoding/json) and Rust (serde_json) encoders must emit keys in this order.
CANONICAL_KEYS: list[str] = ["start", "end", "title", "url"]


def _inputs_dir(script_dir: Path) -> Path:
    return script_dir.parent / "tests" / "fixtures" / "ndjson-parity" / "inputs"


def _committed_golden_dir(script_dir: Path) -> Path:
    return script_dir.parent / "tests" / "fixtures" / "ndjson-parity" / "golden"


def _reorder(obj: dict) -> dict:
    """Return a new dict with keys in CANONICAL_KEYS order.

    Extra keys beyond the four canonical ones are appended in their original
    order (future-proofing for schema extension without breaking the oracle).
    Missing keys are set to None so the output always has all four fields --
    this ensures Wave B binaries can always compare shape, not just content.
    """
    result = {}
    for key in CANONICAL_KEYS:
        result[key] = obj.get(key, None)
    for key in obj:
        if key not in result:
            result[key] = obj[key]
    return result


def encode_event(obj: dict) -> str:
    """Serialize one event dict to canonical NDJSON line (no trailing newline)."""
    ordered = _reorder(obj)
    return json.dumps(ordered, ensure_ascii=False, separators=(",", ":"))


def generate(inputs_dir: Path, output_dir: Path) -> None:
    """Read all input fixtures and write .ndjson golden files to output_dir."""
    output_dir.mkdir(parents=True, exist_ok=True)

    input_files = sorted(inputs_dir.glob("*.json"))
    if not input_files:
        print(
            f"error: no *.json fixtures found in {inputs_dir}",
            file=sys.stderr,
        )
        sys.exit(1)

    for inp in input_files:
        try:
            with inp.open(encoding="utf-8") as fh:
                obj = json.load(fh)
        except json.JSONDecodeError as exc:
            print(f"error: {inp.name}: {exc}", file=sys.stderr)
            sys.exit(2)

        if not isinstance(obj, dict):
            print(
                f"error: {inp.name}: top-level value must be a JSON object",
                file=sys.stderr,
            )
            sys.exit(2)

        stem = inp.stem  # e.g. "01-ascii-baseline"
        out_path = output_dir / f"{stem}.ndjson"
        line = encode_event(obj)
        with out_path.open("w", encoding="utf-8", newline="\n") as fh:
            fh.write(line + "\n")


def check(inputs_dir: Path, committed_golden_dir: Path) -> None:
    """Regenerate in-memory and diff against committed golden. Exit 1 on drift."""
    input_files = sorted(inputs_dir.glob("*.json"))
    if not input_files:
        print(
            f"error: no *.json fixtures found in {inputs_dir}",
            file=sys.stderr,
        )
        sys.exit(1)

    drifted = False
    for inp in input_files:
        try:
            with inp.open(encoding="utf-8") as fh:
                obj = json.load(fh)
        except json.JSONDecodeError as exc:
            print(f"error: {inp.name}: {exc}", file=sys.stderr)
            sys.exit(2)

        stem = inp.stem
        golden_path = committed_golden_dir / f"{stem}.ndjson"
        expected_line = encode_event(obj) + "\n"

        if not golden_path.exists():
            print(f"MISSING golden: {golden_path.name}", file=sys.stderr)
            drifted = True
            continue

        with golden_path.open(encoding="utf-8", newline="\n") as fh:
            actual = fh.read()

        if actual != expected_line:
            diff = list(
                difflib.unified_diff(
                    [expected_line],
                    [actual],
                    fromfile=f"generated/{stem}.ndjson",
                    tofile=f"committed/{stem}.ndjson",
                )
            )
            print(f"DRIFT: {stem}.ndjson", file=sys.stderr)
            for dl in diff:
                print(dl, end="", file=sys.stderr)
            drifted = True

    # Check for extra golden files with no corresponding input
    golden_files = set(p.stem for p in committed_golden_dir.glob("*.ndjson"))
    input_stems = set(p.stem for p in input_files)
    orphans = golden_files - input_stems
    for orphan in sorted(orphans):
        print(f"ORPHAN golden (no input): {orphan}.ndjson", file=sys.stderr)
        drifted = True

    if drifted:
        sys.exit(1)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate or check canonical NDJSON golden output.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "--output",
        metavar="DIR",
        help="Write golden files to DIR instead of the committed golden/ directory.",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Regenerate in-memory and diff against committed golden; exit 1 on drift.",
    )
    args = parser.parse_args()

    script_dir = Path(__file__).parent.resolve()
    inputs_dir = _inputs_dir(script_dir)

    if not inputs_dir.is_dir():
        print(f"error: inputs directory not found: {inputs_dir}", file=sys.stderr)
        sys.exit(1)

    if args.check:
        committed = _committed_golden_dir(script_dir)
        check(inputs_dir, committed)
    elif args.output:
        generate(inputs_dir, Path(args.output))
    else:
        generate(inputs_dir, _committed_golden_dir(script_dir))


if __name__ == "__main__":
    main()
