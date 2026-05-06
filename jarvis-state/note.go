// note index update | rebuild | batch  +  note resolve <prefix>
//
// Replaces the per-update 8-fork bash pipeline in lib/note/index.sh:
//   fm_split (1) -> dasel yaml->json (1) -> 5x jq (5) -> jq merge (1) -> = 8 forks/note.
// In Go this is one process, ~8 syscalls (open/read/parse/write).
//
// .index.json schema (one row per kind/slug):
//   {
//     "<kind>/<slug>": {
//       "path": "<kind>/<slug>.md",
//       "kind": "<kind>",
//       "title": "<title>",
//       "tags": [...],
//       "updated_at": "YYYY-MM-DDTHH:MM:SSZ",
//       "archived": <bool>,
//       "original_kind": "<kind>" | null
//     }, ...
//   }
//
// `note resolve <prefix>` mirrors lib/note/resolve.sh (kind/slug exact +
// kind-prefixed glob), exit 1 if nothing matches or matches are ambiguous.

package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

func noteCmd(stdout, stderr io.Writer, args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "usage: jarvis-state note index update|rebuild|batch | resolve <prefix>")
		return 2
	}
	switch args[0] {
	case "index":
		return noteIndexCmd(stderr, args[1:])
	case "resolve":
		return noteResolveCmd(stdout, stderr, args[1:])
	default:
		fmt.Fprintf(stderr, "jarvis-state note: unknown subcommand %q\n", args[0])
		return 2
	}
}

func noteIndexCmd(stderr io.Writer, args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "usage: jarvis-state note index update|rebuild|batch")
		return 2
	}
	switch args[0] {
	case "update":
		if len(args) != 2 {
			fmt.Fprintln(stderr, "usage: jarvis-state note index update <kind/slug>")
			return 2
		}
		return noteIndexUpdate(stderr, args[1])
	case "rebuild":
		return noteIndexRebuild(stderr)
	case "batch":
		return noteIndexBatch(stderr)
	default:
		fmt.Fprintf(stderr, "jarvis-state note index: unknown subcommand %q\n", args[0])
		return 2
	}
}

// noteRow mirrors lib/note/index.sh's row schema.
type noteRow struct {
	Path         string   `json:"path"`
	Kind         string   `json:"kind"`
	Title        string   `json:"title"`
	Tags         []string `json:"tags"`
	UpdatedAt    string   `json:"updated_at"`
	Archived     bool     `json:"archived"`
	OriginalKind *string  `json:"original_kind"`
}

func notesRoot() (string, error) {
	pd, err := profileDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(pd, "notes"), nil
}

func noteIndexFile() (string, error) {
	root, err := notesRoot()
	if err != nil {
		return "", err
	}
	return filepath.Join(root, ".index.json"), nil
}

func noteIndexUpdate(stderr io.Writer, key string) int {
	if err := updateOneNote(key); err != nil {
		fmt.Fprintf(stderr, "jarvis-state: %v\n", err)
		if errIsNotFound(err) {
			return 1
		}
		return 3
	}
	return 0
}

func noteIndexRebuild(stderr io.Writer) int {
	if err := rebuildIndexFromDisk(); err != nil {
		fmt.Fprintf(stderr, "jarvis-state: %v\n", err)
		return 3
	}
	return 0
}

// noteIndexBatch reads `<kind/slug>` lines on stdin and applies all
// updates under ONE flock (vs N per-key flocks), which is the path
// `note_index_rebuild` would naturally take. Used by bash dispatchers
// that walk the FS for bulk reindex.
func noteIndexBatch(stderr io.Writer) int {
	indexPath, err := noteIndexFile()
	if err != nil {
		fmt.Fprintf(stderr, "jarvis-state: %v\n", err)
		return 1
	}
	if err := os.MkdirAll(filepath.Dir(indexPath), 0o755); err != nil {
		fmt.Fprintf(stderr, "jarvis-state: %v\n", err)
		return 1
	}

	keys := []string{}
	sc := bufio.NewScanner(os.Stdin)
	for sc.Scan() {
		k := strings.TrimSpace(sc.Text())
		if k != "" {
			keys = append(keys, k)
		}
	}
	if err := sc.Err(); err != nil {
		fmt.Fprintf(stderr, "jarvis-state: stdin: %v\n", err)
		return 1
	}

	err = withFlock(indexPath, func() error {
		idx, err := readIndex(indexPath)
		if err != nil {
			return err
		}
		for _, k := range keys {
			row, err := computeNoteRow(k)
			if err != nil {
				if errIsNotFound(err) {
					delete(idx, k)
					continue
				}
				return err
			}
			idx[k] = row
		}
		return writeIndex(indexPath, idx)
	})
	if err != nil {
		fmt.Fprintf(stderr, "jarvis-state: %v\n", err)
		return 3
	}
	return 0
}

func updateOneNote(key string) error {
	indexPath, err := noteIndexFile()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(indexPath), 0o755); err != nil {
		return err
	}
	row, err := computeNoteRow(key)
	if err != nil {
		return err
	}
	return withFlock(indexPath, func() error {
		idx, err := readIndex(indexPath)
		if err != nil {
			return err
		}
		idx[key] = row
		return writeIndex(indexPath, idx)
	})
}

func rebuildIndexFromDisk() error {
	root, err := notesRoot()
	if err != nil {
		return err
	}
	indexPath, err := noteIndexFile()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(indexPath), 0o755); err != nil {
		return err
	}
	idx := map[string]noteRow{}

	err = filepath.Walk(root, func(path string, info os.FileInfo, walkErr error) error {
		if walkErr != nil {
			if os.IsNotExist(walkErr) {
				return nil
			}
			return walkErr
		}
		if info.IsDir() {
			return nil
		}
		base := filepath.Base(path)
		if !strings.HasSuffix(base, ".md") || strings.HasPrefix(base, ".") {
			return nil
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		key := strings.TrimSuffix(rel, ".md")
		row, err := computeNoteRow(key)
		if err != nil {
			if errIsNotFound(err) {
				return nil
			}
			return err
		}
		idx[key] = row
		return nil
	})
	if err != nil {
		return err
	}
	return withFlock(indexPath, func() error { return writeIndex(indexPath, idx) })
}

func computeNoteRow(key string) (noteRow, error) {
	root, err := notesRoot()
	if err != nil {
		return noteRow{}, err
	}
	file := filepath.Join(root, key+".md")
	st, err := os.Stat(file)
	if err != nil {
		if os.IsNotExist(err) {
			return noteRow{}, &notFoundError{path: file}
		}
		return noteRow{}, err
	}
	raw, err := os.ReadFile(file)
	if err != nil {
		return noteRow{}, err
	}
	fm, _ := splitFrontmatter(raw)

	row := noteRow{
		Path:      key + ".md",
		Tags:      []string{},
		UpdatedAt: st.ModTime().UTC().Format("2006-01-02T15:04:05Z"),
	}
	if len(bytes.TrimSpace(fm)) == 0 {
		row.Kind = noteKindOf(key)
		return row, nil
	}
	var meta map[string]any
	if err := yaml.Unmarshal(fm, &meta); err != nil {
		return noteRow{}, fmt.Errorf("parse frontmatter %s: %w", file, err)
	}
	if k, ok := meta["kind"].(string); ok && k != "" {
		row.Kind = k
	} else {
		row.Kind = noteKindOf(key)
	}
	if t, ok := meta["title"].(string); ok {
		row.Title = t
	}
	row.Tags = readTags(meta["tags"])
	if a, ok := meta["archived"].(bool); ok {
		row.Archived = a
	}
	if ok, val := readStringPtr(meta["original_kind"]); ok {
		row.OriginalKind = val
	}
	return row, nil
}

func readTags(v any) []string {
	out := []string{}
	switch t := v.(type) {
	case []any:
		for _, x := range t {
			if s, ok := x.(string); ok {
				out = append(out, s)
			} else {
				out = append(out, fmt.Sprintf("%v", x))
			}
		}
	case []string:
		out = append(out, t...)
	}
	return out
}

// readStringPtr returns (true, nil) for missing/empty/null and (true, &"x")
// for a non-empty string. Anything else -> (false, nil).
func readStringPtr(v any) (bool, *string) {
	if v == nil {
		return true, nil
	}
	s, ok := v.(string)
	if !ok {
		return false, nil
	}
	if s == "" {
		return true, nil
	}
	return true, &s
}

func noteKindOf(key string) string {
	if i := strings.Index(key, "/"); i >= 0 {
		// Top-level kind for `<kind>/<slug>` and `projects/<proj>/<slug>`.
		switch key[:i] {
		case "inbox", "daily", "meetings", "ref", "archive", "templates":
			return key[:i]
		case "projects":
			return "project"
		}
		return key[:i]
	}
	return ""
}

func readIndex(path string) (map[string]noteRow, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return map[string]noteRow{}, nil
		}
		return nil, err
	}
	if len(bytes.TrimSpace(raw)) == 0 {
		return map[string]noteRow{}, nil
	}
	var idx map[string]noteRow
	if err := json.Unmarshal(raw, &idx); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	if idx == nil {
		idx = map[string]noteRow{}
	}
	return idx, nil
}

func writeIndex(path string, idx map[string]noteRow) error {
	keys := make([]string, 0, len(idx))
	for k := range idx {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	var buf bytes.Buffer
	buf.WriteByte('{')
	for i, k := range keys {
		if i > 0 {
			buf.WriteByte(',')
		}
		writeJSONString(&buf, k)
		buf.WriteByte(':')
		row := idx[k]
		rowJSON, err := json.Marshal(&row)
		if err != nil {
			return fmt.Errorf("encode row %s: %w", k, err)
		}
		buf.Write(rowJSON)
	}
	buf.WriteByte('}')
	buf.WriteByte('\n')
	return atomicWrite(path, buf.Bytes())
}

// note resolve <prefix>
//
// Folder-aware match — accepts either `<kind>/<slug>` (exact) or `<slug>`
// (cross-folder unique-prefix). Mirrors lib/note/resolve.sh:1-160 rules:
//   - Exact `<kind>/<slug>` -> 0 with that key
//   - `<slug>` -> if exactly one `*/<slug>.md` exists, print its key
//   - Prefix scan over .index.json keys; exit 1 on miss/ambiguous
func noteResolveCmd(stdout, stderr io.Writer, args []string) int {
	if len(args) != 1 {
		fmt.Fprintln(stderr, "usage: jarvis-state note resolve <prefix-or-key>")
		return 2
	}
	query := args[0]
	indexPath, err := noteIndexFile()
	if err != nil {
		fmt.Fprintf(stderr, "jarvis-state: %v\n", err)
		return 1
	}
	idx, err := readIndex(indexPath)
	if err != nil {
		fmt.Fprintf(stderr, "jarvis-state: %v\n", err)
		return 3
	}
	keys := make([]string, 0, len(idx))
	for k := range idx {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	// 1. Exact full key.
	for _, k := range keys {
		if k == query {
			fmt.Fprintln(stdout, k)
			return 0
		}
	}
	// 2. Bare slug (no slash) -> match any key whose tail equals query.
	if !strings.Contains(query, "/") {
		var tail []string
		for _, k := range keys {
			parts := strings.Split(k, "/")
			if parts[len(parts)-1] == query {
				tail = append(tail, k)
			}
		}
		if len(tail) == 1 {
			fmt.Fprintln(stdout, tail[0])
			return 0
		}
		if len(tail) > 1 {
			fmt.Fprintf(stderr, "ambiguous %q — candidates:\n", query)
			for _, k := range tail {
				fmt.Fprintf(stderr, "  %s\n", k)
			}
			return 1
		}
	}
	// 3. Prefix match across full keys.
	var pref []string
	for _, k := range keys {
		if strings.HasPrefix(k, query) {
			pref = append(pref, k)
		}
	}
	switch len(pref) {
	case 0:
		fmt.Fprintf(stderr, "no note matches %q\n", query)
		return 1
	case 1:
		fmt.Fprintln(stdout, pref[0])
		return 0
	default:
		fmt.Fprintf(stderr, "ambiguous prefix %q — candidates:\n", query)
		for _, k := range pref {
			fmt.Fprintf(stderr, "  %s\n", k)
		}
		return 1
	}
}

type notFoundError struct{ path string }

func (e *notFoundError) Error() string { return "not found: " + e.path }

func errIsNotFound(err error) bool {
	if err == nil {
		return false
	}
	_, ok := err.(*notFoundError)
	return ok
}
