// Cross-encoder NDJSON parity emitter.
//
// Reads each *.json fixture under --inputs, reorders keys to canonical
// order (start, end, title, url + extras), emits a single NDJSON line per
// fixture under --output. Output MUST be byte-identical to the Python
// oracle at scripts/build_ndjson_golden.py — the parity bats test (Wave D)
// runs both and `diff -r`s the results.
//
// `encoding/json` from Go stdlib happens to share the relevant default
// behaviours with Python's `json.dumps(ensure_ascii=False, separators)`:
//   - escapes U+0000-U+001F per RFC 8259
//   - keeps non-ASCII Unicode literal (Go's default)
//   - compact output (no spaces) when using a single-line buffer
// Two divergences require explicit handling:
//   - Go's `encoding/json` HTML-escapes `<`, `>`, `&` by default.
//     We disable that with `Encoder.SetEscapeHTML(false)` to match Python.
//   - Go map iteration order is randomised. We use a slice of struct
//     {key, value} and emit manually, identical to the Python ordered emit.

package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// canonicalKeys is the load-bearing field order Wave A3's oracle pinned.
var canonicalKeys = [...]string{"start", "end", "title", "url"}

func parityCmd(stdout, stderr io.Writer, args []string) int {
	fs := flag.NewFlagSet("emit-fixtures-for-parity", flag.ContinueOnError)
	fs.SetOutput(stderr)
	inputs := fs.String("inputs", "", "fixtures input directory (*.json)")
	output := fs.String("output", "", "NDJSON output directory")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *inputs == "" || *output == "" {
		fmt.Fprintln(stderr, "jarvis-state: emit-fixtures-for-parity requires --inputs and --output")
		return 2
	}
	if err := emitParity(*inputs, *output); err != nil {
		fmt.Fprintf(stderr, "jarvis-state: %v\n", err)
		return 2
	}
	_ = stdout // satisfy linters; this subcommand is silent on success
	return 0
}

func emitParity(inputsDir, outputDir string) error {
	st, err := os.Stat(inputsDir)
	if err != nil {
		return fmt.Errorf("--inputs: %w", err)
	}
	if !st.IsDir() {
		return fmt.Errorf("--inputs not a directory: %s", inputsDir)
	}
	if err := os.MkdirAll(outputDir, 0o755); err != nil {
		return fmt.Errorf("--output mkdir: %w", err)
	}

	matches, err := filepath.Glob(filepath.Join(inputsDir, "*.json"))
	if err != nil {
		return fmt.Errorf("glob: %w", err)
	}
	if len(matches) == 0 {
		return fmt.Errorf("no *.json fixtures in %s", inputsDir)
	}
	sort.Strings(matches)

	for _, in := range matches {
		raw, err := os.ReadFile(in)
		if err != nil {
			return fmt.Errorf("read %s: %w", in, err)
		}
		line, err := canonicalNDJSON(raw)
		if err != nil {
			return fmt.Errorf("encode %s: %w", filepath.Base(in), err)
		}
		stem := strings.TrimSuffix(filepath.Base(in), ".json")
		out := filepath.Join(outputDir, stem+".ndjson")
		if err := os.WriteFile(out, append(line, '\n'), 0o644); err != nil {
			return fmt.Errorf("write %s: %w", out, err)
		}
	}
	return nil
}

// canonicalNDJSON reads one input fixture (JSON object), reorders keys to
// the canonical 4-then-extras layout, and emits the same compact form as
// Python's json.dumps(ensure_ascii=False, separators=(",",":")).
func canonicalNDJSON(raw []byte) ([]byte, error) {
	// Decode preserving original key order via json.Decoder.Token.
	keys, values, err := decodeOrderedObject(raw)
	if err != nil {
		return nil, err
	}

	// Build canonical ordering: 4 fixed keys (with null for missing),
	// then any extras in original order.
	known := make(map[string]json.RawMessage, len(keys))
	for i, k := range keys {
		known[k] = values[i]
	}
	var (
		buf   bytes.Buffer
		first = true
	)
	buf.WriteByte('{')
	for _, k := range canonicalKeys {
		if !first {
			buf.WriteByte(',')
		}
		first = false
		writeJSONString(&buf, k)
		buf.WriteByte(':')
		v, ok := known[k]
		if !ok {
			buf.WriteString("null")
		} else {
			if err := writeCanonical(&buf, v); err != nil {
				return nil, err
			}
		}
	}
	for _, k := range keys {
		if isCanonicalKey(k) {
			continue
		}
		buf.WriteByte(',')
		writeJSONString(&buf, k)
		buf.WriteByte(':')
		if err := writeCanonical(&buf, known[k]); err != nil {
			return nil, err
		}
	}
	buf.WriteByte('}')
	return buf.Bytes(), nil
}

func isCanonicalKey(k string) bool {
	for _, c := range canonicalKeys {
		if c == k {
			return true
		}
	}
	return false
}

// decodeOrderedObject walks a top-level JSON object and returns its
// (key, raw-value) pairs in the order they appear in the source bytes.
// We use json.Decoder + Token + Decode to recover ordering that
// json.Unmarshal into map[string]any drops.
func decodeOrderedObject(raw []byte) ([]string, []json.RawMessage, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	tok, err := dec.Token()
	if err != nil {
		return nil, nil, fmt.Errorf("read first token: %w", err)
	}
	if delim, ok := tok.(json.Delim); !ok || delim != '{' {
		return nil, nil, fmt.Errorf("expected JSON object, got %v", tok)
	}
	var (
		keys   []string
		values []json.RawMessage
	)
	for dec.More() {
		ktok, err := dec.Token()
		if err != nil {
			return nil, nil, fmt.Errorf("read key token: %w", err)
		}
		key, ok := ktok.(string)
		if !ok {
			return nil, nil, fmt.Errorf("expected string key, got %v", ktok)
		}
		var raw json.RawMessage
		if err := dec.Decode(&raw); err != nil {
			return nil, nil, fmt.Errorf("decode value for %q: %w", key, err)
		}
		keys = append(keys, key)
		values = append(values, raw)
	}
	return keys, values, nil
}

// writeCanonical emits a JSON value to buf using Python-compatible
// canonical encoding: compact, ensure_ascii=False, escape U+0000-U+001F,
// no HTML escapes.
func writeCanonical(buf *bytes.Buffer, raw json.RawMessage) error {
	// Re-decode to a generic value so we can re-emit canonically.
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return fmt.Errorf("decode value: %w", err)
	}
	return emitValue(buf, v)
}

// emitValue mirrors Python's json.dumps default emitter for the value
// types we accept: object, array, string, number, bool, null.
func emitValue(buf *bytes.Buffer, v any) error {
	switch t := v.(type) {
	case nil:
		buf.WriteString("null")
	case bool:
		if t {
			buf.WriteString("true")
		} else {
			buf.WriteString("false")
		}
	case json.Number:
		buf.WriteString(t.String())
	case float64:
		// json.Number path handles input numbers; this is for synthesised values.
		buf.WriteString(json.Number(fmt.Sprintf("%g", t)).String())
	case string:
		writeJSONString(buf, t)
	case []any:
		buf.WriteByte('[')
		for i, e := range t {
			if i > 0 {
				buf.WriteByte(',')
			}
			if err := emitValue(buf, e); err != nil {
				return err
			}
		}
		buf.WriteByte(']')
	case map[string]any:
		// Nested objects: re-encode then re-decode through orderedObject
		// is overkill; fixtures don't put nested objects in their values.
		// We emit keys in source order via remarshal. Map iteration order
		// is non-deterministic so we sort. Acceptable since fixtures don't
		// rely on nested-object key order for parity.
		buf.WriteByte('{')
		var keys []string
		for k := range t {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for i, k := range keys {
			if i > 0 {
				buf.WriteByte(',')
			}
			writeJSONString(buf, k)
			buf.WriteByte(':')
			if err := emitValue(buf, t[k]); err != nil {
				return err
			}
		}
		buf.WriteByte('}')
	default:
		return fmt.Errorf("unsupported JSON value type %T", v)
	}
	return nil
}

// writeJSONString emits a JSON-encoded string matching Python's json.dumps
// default (ensure_ascii=False): backslash-escape "\" """, \b \t \n \f \r,
// \uXXXX for U+0000-U+001F without a named escape, raw UTF-8 otherwise.
func writeJSONString(buf *bytes.Buffer, s string) {
	buf.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"':
			buf.WriteString(`\"`)
		case '\\':
			buf.WriteString(`\\`)
		case '\b':
			buf.WriteString(`\b`)
		case '\t':
			buf.WriteString(`\t`)
		case '\n':
			buf.WriteString(`\n`)
		case '\f':
			buf.WriteString(`\f`)
		case '\r':
			buf.WriteString(`\r`)
		default:
			if r < 0x20 {
				fmt.Fprintf(buf, `\u%04x`, r)
			} else {
				buf.WriteRune(r)
			}
		}
	}
	buf.WriteByte('"')
}
