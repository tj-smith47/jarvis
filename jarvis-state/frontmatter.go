// frontmatter parse | emit | set — YAML frontmatter operations.
//
// `parse <file>`  : read file with optional `---\nyaml\n---\n` frontmatter,
//                   emit the frontmatter as a compact JSON object on stdout.
//                   Empty/missing frontmatter -> "{}".
//
// `emit`          : read a JSON object on stdin, emit `---\nyaml\n---\n` on
//                   stdout (no body — callers concatenate body separately).
//
// `set <file> <key> <val>` : in-place atomic mutate; preserves body
//                   trailing-newline (unlike the bash fm_set workaround).
//
// Replaces lib/frontmatter.sh's dasel + jq pipeline. Drains the
// fm_split trailing-newline drift hazard the bash impl documents.

package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"

	"gopkg.in/yaml.v3"
)

func frontmatterCmd(stdout, stderr io.Writer, args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "usage: jarvis-state frontmatter parse|emit|set ...")
		return 2
	}
	switch args[0] {
	case "parse":
		return fmParse(stdout, stderr, args[1:])
	case "emit":
		return fmEmit(stdout, stderr, args[1:])
	case "set":
		return fmSet(stderr, args[1:])
	default:
		fmt.Fprintf(stderr, "jarvis-state frontmatter: unknown subcommand %q\n", args[0])
		return 2
	}
}

func fmParse(stdout, stderr io.Writer, args []string) int {
	if len(args) != 1 {
		fmt.Fprintln(stderr, "usage: jarvis-state frontmatter parse <file>")
		return 2
	}
	raw, err := os.ReadFile(args[0])
	if err != nil {
		fmt.Fprintf(stderr, "jarvis-state: %v\n", err)
		return 1
	}
	fm, _ := splitFrontmatter(raw)
	if len(bytes.TrimSpace(fm)) == 0 {
		fmt.Fprintln(stdout, "{}")
		return 0
	}
	var node yaml.Node
	if err := yaml.Unmarshal(fm, &node); err != nil {
		fmt.Fprintf(stderr, "frontmatter: malformed YAML in %s: %v\n", args[0], err)
		return 3
	}
	out, err := yamlNodeToJSON(&node)
	if err != nil {
		fmt.Fprintf(stderr, "frontmatter: %s: %v\n", args[0], err)
		return 3
	}
	if _, err := fmt.Fprintln(stdout, string(out)); err != nil {
		return 5
	}
	return 0
}

func fmEmit(stdout, stderr io.Writer, args []string) int {
	if len(args) != 0 {
		fmt.Fprintln(stderr, "usage: jarvis-state frontmatter emit  (reads JSON on stdin)")
		return 2
	}
	raw, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintf(stderr, "jarvis-state: stdin: %v\n", err)
		return 1
	}
	if len(bytes.TrimSpace(raw)) == 0 {
		raw = []byte("{}")
	}
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		fmt.Fprintf(stderr, "jarvis-state: stdin not JSON: %v\n", err)
		return 2
	}
	yamlBytes, err := yaml.Marshal(v)
	if err != nil {
		fmt.Fprintf(stderr, "jarvis-state: yaml encode: %v\n", err)
		return 5
	}
	if _, err := fmt.Fprintf(stdout, "---\n%s---\n", yamlBytes); err != nil {
		return 5
	}
	return 0
}

func fmSet(stderr io.Writer, args []string) int {
	if len(args) != 3 {
		fmt.Fprintln(stderr, "usage: jarvis-state frontmatter set <file> <dotted-key> <value>")
		return 2
	}
	file, key, value := args[0], args[1], args[2]
	raw, err := os.ReadFile(file)
	if err != nil {
		fmt.Fprintf(stderr, "jarvis-state: %v\n", err)
		return 1
	}
	fm, body := splitFrontmatter(raw)

	var fmObj map[string]any
	if len(bytes.TrimSpace(fm)) == 0 {
		fmObj = map[string]any{}
	} else {
		if err := yaml.Unmarshal(fm, &fmObj); err != nil {
			fmt.Fprintf(stderr, "frontmatter: malformed YAML in %s: %v\n", file, err)
			return 3
		}
		if fmObj == nil {
			fmObj = map[string]any{}
		}
	}

	parsedValue := autoTypeScalar(value)
	if err := setDotted(fmObj, key, parsedValue); err != nil {
		fmt.Fprintf(stderr, "jarvis-state: %v\n", err)
		return 2
	}

	yamlBytes, err := yaml.Marshal(fmObj)
	if err != nil {
		fmt.Fprintf(stderr, "jarvis-state: yaml encode: %v\n", err)
		return 5
	}

	// Normalise body to end with exactly one newline (matches the bash
	// fm_set fix at lib/frontmatter.sh:148-155 — repeated fm_sets must
	// not progressively truncate trailing newlines).
	body = ensureTrailingNewline(body)

	out := append([]byte("---\n"), yamlBytes...)
	out = append(out, []byte("---\n")...)
	out = append(out, body...)

	if err := atomicWrite(file, out); err != nil {
		fmt.Fprintf(stderr, "jarvis-state: %v\n", err)
		return 1
	}
	return 0
}

// splitFrontmatter splits a `---\n...\n---\n<body>` document. If no
// frontmatter delimiter is present, fm is empty and body == content.
// `---\n` opener at offset 0 is required (matches the bash fm_split
// shape at lib/frontmatter.sh:20-43).
func splitFrontmatter(content []byte) (fm, body []byte) {
	if !bytes.HasPrefix(content, []byte("---\n")) {
		return nil, content
	}
	rest := content[4:]
	// Look for closing `\n---\n` or trailing `\n---` at EOF.
	closer := []byte("\n---\n")
	i := bytes.Index(rest, closer)
	if i >= 0 {
		return rest[:i], rest[i+len(closer):]
	}
	if bytes.HasSuffix(rest, []byte("\n---")) {
		return rest[:len(rest)-len("\n---")], nil
	}
	return nil, content
}

// ensureTrailingNewline returns body verbatim except: empty body unchanged;
// any non-empty body is guaranteed to end with exactly ONE '\n' (no trim
// of multi-newline blank lines; we just don't strip them).
func ensureTrailingNewline(body []byte) []byte {
	if len(body) == 0 {
		return body
	}
	if body[len(body)-1] == '\n' {
		return body
	}
	return append(body, '\n')
}

// autoTypeScalar coerces "true"/"false"/"null"/"3"/"3.14" to typed values;
// anything else stays a string. Matches the bash fm_set behaviour at
// lib/frontmatter.sh:138-143.
func autoTypeScalar(s string) any {
	switch s {
	case "true":
		return true
	case "false":
		return false
	case "null":
		return nil
	}
	if i, err := strconv.ParseInt(s, 10, 64); err == nil {
		return i
	}
	if f, err := strconv.ParseFloat(s, 64); err == nil {
		return f
	}
	return s
}

func setDotted(obj map[string]any, key string, value any) error {
	if key == "" {
		return fmt.Errorf("empty key")
	}
	parts := splitDots(key)
	cur := obj
	for i, p := range parts[:len(parts)-1] {
		next, ok := cur[p]
		if !ok {
			m := map[string]any{}
			cur[p] = m
			cur = m
			continue
		}
		nextMap, ok := next.(map[string]any)
		if !ok {
			return fmt.Errorf("%s: %s is not an object", key, splitDotsJoin(parts[:i+1]))
		}
		cur = nextMap
	}
	cur[parts[len(parts)-1]] = value
	return nil
}

func splitDots(s string) []string {
	var out []string
	start := 0
	for i := 0; i < len(s); i++ {
		if s[i] == '.' {
			out = append(out, s[start:i])
			start = i + 1
		}
	}
	return append(out, s[start:])
}

func splitDotsJoin(parts []string) string {
	if len(parts) == 0 {
		return ""
	}
	out := parts[0]
	for _, p := range parts[1:] {
		out += "." + p
	}
	return out
}

// atomicWrite renames a tmp file over `dest` so partial writes never
// produce a torn frontmatter file. Mirrors the bash fm_set tmp+mv idiom.
func atomicWrite(dest string, data []byte) error {
	dir := filepath.Dir(dest)
	tmp, err := os.CreateTemp(dir, filepath.Base(dest)+".tmp.*")
	if err != nil {
		return fmt.Errorf("temp %s: %w", dir, err)
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath) // no-op after successful rename
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("write %s: %w", tmpPath, err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("close %s: %w", tmpPath, err)
	}
	if err := os.Rename(tmpPath, dest); err != nil {
		return fmt.Errorf("rename %s -> %s: %w", tmpPath, dest, err)
	}
	return nil
}

// yamlNodeToJSON serialises a yaml.Node tree to compact JSON, matching
// the dasel-i-yaml-o-json semantics the bash callers depend on.
//
// Why a yaml.Node walk instead of `yaml.Unmarshal(_, &any)` + json.Marshal?
//   - yaml.v3 by default decodes maps with `interface{}` keys (strings,
//     ints, bools, etc.). Re-marshalling such maps via encoding/json fails
//     with "unsupported type: map[interface {}]interface {}".
//   - Walking yaml.Node lets us coerce keys to strings (matching the JSON
//     model) without a custom unmarshaller per type.
func yamlNodeToJSON(root *yaml.Node) ([]byte, error) {
	var top *yaml.Node = root
	if root.Kind == yaml.DocumentNode && len(root.Content) > 0 {
		top = root.Content[0]
	}
	v, err := convertYAMLNode(top)
	if err != nil {
		return nil, err
	}
	if v == nil {
		// `---\n---\n` (empty document) → emit `{}` rather than `null`.
		v = map[string]any{}
	}
	return json.Marshal(v)
}

func convertYAMLNode(n *yaml.Node) (any, error) {
	if n == nil {
		return nil, nil
	}
	switch n.Kind {
	case yaml.ScalarNode:
		return convertYAMLScalar(n)
	case yaml.SequenceNode:
		out := make([]any, 0, len(n.Content))
		for _, c := range n.Content {
			v, err := convertYAMLNode(c)
			if err != nil {
				return nil, err
			}
			out = append(out, v)
		}
		return out, nil
	case yaml.MappingNode:
		out := make(map[string]any, len(n.Content)/2)
		for i := 0; i+1 < len(n.Content); i += 2 {
			k, err := convertYAMLNode(n.Content[i])
			if err != nil {
				return nil, err
			}
			ks := fmt.Sprintf("%v", k)
			v, err := convertYAMLNode(n.Content[i+1])
			if err != nil {
				return nil, err
			}
			out[ks] = v
		}
		return out, nil
	case yaml.AliasNode:
		return convertYAMLNode(n.Alias)
	default:
		return nil, fmt.Errorf("unsupported yaml node kind: %v", n.Kind)
	}
}

func convertYAMLScalar(n *yaml.Node) (any, error) {
	// Honour explicit tags first.
	switch n.Tag {
	case "!!str":
		return n.Value, nil
	case "!!int":
		if i, err := strconv.ParseInt(n.Value, 0, 64); err == nil {
			return i, nil
		}
	case "!!float":
		if f, err := strconv.ParseFloat(n.Value, 64); err == nil {
			return f, nil
		}
	case "!!bool":
		switch n.Value {
		case "true", "True", "TRUE":
			return true, nil
		case "false", "False", "FALSE":
			return false, nil
		}
	case "!!null":
		return nil, nil
	}
	// Tag-less scalar: fall back to YAML 1.1 plain-scalar resolution.
	v := n.Value
	if n.Style == yaml.DoubleQuotedStyle || n.Style == yaml.SingleQuotedStyle {
		return v, nil
	}
	switch v {
	case "":
		// Empty unquoted scalar -> null (YAML 1.1).
		return nil, nil
	case "true", "True", "TRUE":
		return true, nil
	case "false", "False", "FALSE":
		return false, nil
	case "null", "Null", "NULL", "~":
		return nil, nil
	}
	if i, err := strconv.ParseInt(v, 0, 64); err == nil {
		return i, nil
	}
	if f, err := strconv.ParseFloat(v, 64); err == nil {
		return f, nil
	}
	return v, nil
}
