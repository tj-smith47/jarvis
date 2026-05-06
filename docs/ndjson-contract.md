# NDJSON Contract

## Authoritative reference

`tests/fixtures/ndjson-parity/inputs/` and `tests/fixtures/ndjson-parity/golden/`
are the authoritative corpus. If any encoder's output diverges from the golden
files, the encoder is wrong — not the golden.

## Canonical encoding rules

All six rules are load-bearing. Both Wave B encoders (`jarvis-state` in Go,
`jarvis-cal` in Rust) must produce byte-identical output to the Python oracle.

| # | Rule | Detail |
|---|------|--------|
| 1 | UTF-8, no BOM | All output is UTF-8 encoded; no byte-order mark. |
| 2 | Escape U+0000–U+001F | Low codepoints always escaped as `\uXXXX` per RFC 8259 §7. This includes `\t` (U+0009), `\n` (U+000A), `\r` (U+000D), and `\b` (U+0008). `json.dumps` in Python, `encoding/json` in Go, and `serde_json` in Rust all do this by default. |
| 3 | No ensure_ascii | Non-ASCII Unicode (emoji, CJK, RTL, combining diacritics, supplementary plane) is emitted as literal UTF-8, not `\uXXXX` escapes. |
| 4 | Compact separators | `','` and `':'` with no surrounding spaces (`separators=(',',':')` in Python; `serde_json` compact mode in Rust; `json.Marshal` in Go). |
| 5 | Key order: `start`, `end`, `title`, `url` | Every output object emits exactly these four keys in this fixed order. The oracle reorders input dicts before serializing. Go and Rust must use a fixed-field struct or ordered map, not reflect-based marshaling that may reorder alphabetically. |
| 6 | One object per line, `\n` terminated | Each NDJSON line is a single JSON object followed by exactly one `\n`. No trailing blank line at EOF. |

## Corpus categories

| Range | Category | Count |
|-------|----------|-------|
| 01–05 | ASCII baseline | 5 |
| 06–13 | Unicode (emoji, ZWJ, CJK, RTL, combining, math, supplementary) | 8 |
| 14–21 | Control characters (U+0000, U+0001, U+0007, U+0008, U+0009, U+000A, U+000D, U+001F) | 8 |
| 22–24 | HTML-significant (`<>&"'` in title; injection in URL) | 3 |
| 25–28 | Embedded escapes (backslash, double-quote, mixed, RFC 5545 sequences) | 4 |
| 29–31 | Long content (>1KB title, all RFC 3986 reserved chars in URL, deep combining) | 3 |
| 32–36 | Empty / null (empty title, null url, empty start, missing fields, all-empty) | 5 |
| 37–41 | Time-shaped (ISO UTC, ISO offset, basic `YYYYMMDDTHHMMSSZ`, far future, far past) | 5 |
| 42–50 | Mixed-realistic (Outlook, Google Calendar, Apple iCal, all-day, RRULE, emoji+url, collapsed description, cancelled, full Outlook) | 9 |
| **Total** | | **50** |

## Per-encoder regeneration commands

### Python oracle (independent reference — use to regenerate golden)

```bash
# Write to committed golden directory
python3 scripts/build_ndjson_golden.py

# Write to a specific directory (for diff testing)
python3 scripts/build_ndjson_golden.py --output /tmp/golden-check

# Check for drift against committed golden (exit 1 if any file differs)
python3 scripts/build_ndjson_golden.py --check
```

### Rust — `jarvis-cal` (Wave B)

```bash
# Emit the Rust encoder's version of the golden for parity comparison
cargo run --bin jarvis-cal -- emit-fixtures-for-parity --input tests/fixtures/ndjson-parity/inputs --output /tmp/rust-golden
diff -r tests/fixtures/ndjson-parity/golden /tmp/rust-golden
```

### Go — `jarvis-state` (Wave B)

```bash
# Emit the Go encoder's version of the golden for parity comparison
go run ./cmd/jarvis-state emit-fixtures-for-parity --input tests/fixtures/ndjson-parity/inputs --output /tmp/go-golden
diff -r tests/fixtures/ndjson-parity/golden /tmp/go-golden
```

Both Wave B subcommands (`emit-fixtures-for-parity`) are hidden from end-user
help but always present in the binary. The parity bats test (`jarvis_ndjson_corpus_sanity.bats`)
invokes them and diffs against the committed golden, so cross-encoder agreement
is verified on every CI run — not just self-consistency.

## Exit code table

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Config or tool missing (binary not found, required config absent, input directory missing) |
| 2 | Validation error (malformed input, bad timestamp, unknown field) |
| 3 | State corruption (lock contention timeout, index inconsistency) |
| 4 | Explicit integration missing (integration not configured; caller must surface actionable message) |
| 5 | Internal binary error (Rust panic caught by `catch_unwind`, Go unrecovered panic, Python unhandled exception) |

## Control character encoding decision

RFC 8259 §7 requires U+0000–U+001F to be escaped as `\uXXXX` (with shortcuts
`\b`, `\f`, `\n`, `\r`, `\t` for U+0008, U+000C, U+000A, U+000D, U+0009).
All three standard library encoders (Python `json`, Go `encoding/json`, Rust
`serde_json`) implement this identically by default. No special handling is
needed — the oracle uses `json.dumps(obj, ensure_ascii=False, separators=(',',':'))`.

## RFC 5545 escape sequences

ICS files use backslash-escaping: `\n` means newline, `\,` means literal comma,
`\;` means literal semicolon. These are **ICS-level escapes**, not JSON-level
escapes. `jarvis-cal` (Rust, Wave B) is responsible for expanding ICS escapes
before emitting NDJSON. The fixture `28-escape-rfc5545-sequences.json` contains
the literal two-character sequences `\n`, `\,`, `\;` in the `title` field —
these are stored as-is (two chars each) in the input fixture, so the oracle's
golden contains them JSON-escaped as `\\n`, `\\,`, `\\;`. This tests that the
encoder does **not** re-interpret them — that is `jarvis-cal`'s job upstream.
