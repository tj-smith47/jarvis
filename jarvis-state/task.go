// task list | add | done | edit | remove
//
// Per-item JSON files at $JARVIS_HOME/<profile>/tasks/<slug>.json (matches
// the bash store layout — git-sync friendly, per-item conflict surface).
//
// `task list` is the hot subcommand: aggregates `tasks/*.json`, filters
// via repeated `--filter k=v`, emits a stable sorted JSON array on stdout.
//
// add/done/edit/remove are convenience wrappers — most bash dispatchers
// today own the file mutations directly. Implementing here keeps the
// surface uniform and slug+collision logic in one place.

package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

func taskCmd(stdout, stderr io.Writer, args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "usage: jarvis-state task list|add|done|edit|remove ...")
		return 2
	}
	switch args[0] {
	case "list":
		return taskList(stdout, stderr, args[1:])
	case "add":
		return taskAdd(stdout, stderr, args[1:])
	case "done":
		return taskDone(stderr, args[1:])
	case "edit":
		return taskEdit(stderr, args[1:])
	case "remove":
		return taskRemove(stderr, args[1:])
	default:
		fmt.Fprintf(stderr, "jarvis-state task: unknown subcommand %q\n", args[0])
		return 2
	}
}

func taskDir() (string, error) {
	pd, err := profileDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(pd, "tasks"), nil
}

func taskList(stdout, stderr io.Writer, args []string) int {
	fs := flag.NewFlagSet("task list", flag.ContinueOnError)
	fs.SetOutput(stderr)
	var filters multiFlag
	fs.Var(&filters, "filter", "k=v constraint (repeatable, all must match)")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if len(fs.Args()) > 0 {
		fmt.Fprintln(stderr, "task list: unexpected positional args")
		return 2
	}

	tasks, err := loadAllTasks()
	if err != nil {
		fmt.Fprintf(stderr, "jarvis-state: %v\n", err)
		return 3
	}

	parsedFilters, err := parseFilters(filters)
	if err != nil {
		fmt.Fprintf(stderr, "jarvis-state: %v\n", err)
		return 2
	}

	out := make([]map[string]any, 0, len(tasks))
	for _, t := range tasks {
		if !matchesFilters(t, parsedFilters) {
			continue
		}
		out = append(out, t)
	}
	sort.SliceStable(out, func(i, j int) bool {
		return slugOf(out[i]) < slugOf(out[j])
	})

	enc := json.NewEncoder(stdout)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(out); err != nil {
		fmt.Fprintf(stderr, "jarvis-state: encode: %v\n", err)
		return 5
	}
	return 0
}

func taskAdd(stdout, stderr io.Writer, args []string) int {
	// Intersperse flags + positional desc so callers can write either
	// `task add "Buy milk" --priority high` or
	// `task add --priority high "Buy milk"` (matches bash clift parser).
	known := map[string]*string{
		"--priority": ptr(""),
		"--due":      ptr(""),
		"--project":  ptr(""),
	}
	descTokens, err := parseInterspersed(args, known)
	if err != nil {
		fmt.Fprintf(stderr, "task add: %v\n", err)
		return 2
	}
	priority := *known["--priority"]
	due := *known["--due"]
	project := *known["--project"]
	if len(descTokens) == 0 {
		fmt.Fprintln(stderr, "usage: jarvis-state task add <description> [--priority] [--due] [--project]")
		return 2
	}
	desc := strings.Join(descTokens, " ")

	dir, err := taskDir()
	if err != nil {
		fmt.Fprintf(stderr, "jarvis-state: %v\n", err)
		return 1
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		fmt.Fprintf(stderr, "jarvis-state: %v\n", err)
		return 1
	}
	base := slugFromDesc(desc)
	if base == "" {
		fmt.Fprintln(stderr, "jarvis-state task add: description produced empty slug")
		return 2
	}
	slug := slugResolveCollision(base, dir, "json")

	now := nowISO()
	row := map[string]any{
		"slug":       slug,
		"desc":       desc,
		"status":     "open",
		"created_at": now,
		"updated_at": now,
	}
	if priority != "" {
		row["priority"] = priority
	}
	if due != "" {
		row["due"] = due
	}
	if project != "" {
		row["project"] = project
	}

	if err := writeTaskFile(dir, slug, row); err != nil {
		fmt.Fprintf(stderr, "jarvis-state: %v\n", err)
		return 1
	}
	fmt.Fprintln(stdout, slug)
	return 0
}

func taskDone(stderr io.Writer, args []string) int {
	if len(args) != 1 {
		fmt.Fprintln(stderr, "usage: jarvis-state task done <slug>")
		return 2
	}
	if err := mutateTask(args[0], func(t map[string]any) {
		t["status"] = "done"
		t["done_at"] = nowISO()
		t["updated_at"] = nowISO()
	}); err != nil {
		fmt.Fprintf(stderr, "jarvis-state: %v\n", err)
		if errIsNotFound(err) {
			return 1
		}
		return 3
	}
	return 0
}

func taskEdit(stderr io.Writer, args []string) int {
	fs := flag.NewFlagSet("task edit", flag.ContinueOnError)
	fs.SetOutput(stderr)
	desc := fs.String("desc", "", "")
	priority := fs.String("priority", "", "low | med | high")
	due := fs.String("due", "", "YYYY-MM-DD or 'clear'")
	project := fs.String("project", "", "project name or 'clear'")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	rest := fs.Args()
	if len(rest) != 1 {
		fmt.Fprintln(stderr, "usage: jarvis-state task edit <slug> [--desc|--priority|--due|--project VAL]")
		return 2
	}
	slug := rest[0]
	if *desc == "" && *priority == "" && *due == "" && *project == "" {
		fmt.Fprintln(stderr, "task edit: at least one of --desc/--priority/--due/--project required")
		return 2
	}
	if err := mutateTask(slug, func(t map[string]any) {
		if *desc != "" {
			t["desc"] = *desc
		}
		if *priority != "" {
			t["priority"] = *priority
		}
		if *due != "" {
			if *due == "clear" {
				delete(t, "due")
			} else {
				t["due"] = *due
			}
		}
		if *project != "" {
			if *project == "clear" {
				delete(t, "project")
			} else {
				t["project"] = *project
			}
		}
		t["updated_at"] = nowISO()
	}); err != nil {
		fmt.Fprintf(stderr, "jarvis-state: %v\n", err)
		if errIsNotFound(err) {
			return 1
		}
		return 3
	}
	return 0
}

func taskRemove(stderr io.Writer, args []string) int {
	if len(args) != 1 {
		fmt.Fprintln(stderr, "usage: jarvis-state task remove <slug>")
		return 2
	}
	dir, err := taskDir()
	if err != nil {
		fmt.Fprintf(stderr, "jarvis-state: %v\n", err)
		return 1
	}
	path := filepath.Join(dir, args[0]+".json")
	if err := os.Remove(path); err != nil {
		if os.IsNotExist(err) {
			fmt.Fprintf(stderr, "jarvis-state: no task %q\n", args[0])
			return 1
		}
		fmt.Fprintf(stderr, "jarvis-state: %v\n", err)
		return 3
	}
	return 0
}

func loadAllTasks() ([]map[string]any, error) {
	dir, err := taskDir()
	if err != nil {
		return nil, err
	}
	matches, err := filepath.Glob(filepath.Join(dir, "*.json"))
	if err != nil {
		return nil, err
	}
	out := make([]map[string]any, 0, len(matches))
	for _, m := range matches {
		raw, err := os.ReadFile(m)
		if err != nil {
			return nil, fmt.Errorf("read %s: %w", m, err)
		}
		var t map[string]any
		if err := json.Unmarshal(raw, &t); err != nil {
			return nil, fmt.Errorf("parse %s: %w", m, err)
		}
		out = append(out, t)
	}
	return out, nil
}

func writeTaskFile(dir, slug string, t map[string]any) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	raw, err := json.MarshalIndent(t, "", "  ")
	if err != nil {
		return err
	}
	raw = append(raw, '\n')
	return atomicWrite(filepath.Join(dir, slug+".json"), raw)
}

func mutateTask(slug string, mut func(map[string]any)) error {
	dir, err := taskDir()
	if err != nil {
		return err
	}
	path := filepath.Join(dir, slug+".json")
	st, err := os.Stat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return &notFoundError{path: path}
		}
		return err
	}
	_ = st
	raw, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var t map[string]any
	if err := json.Unmarshal(raw, &t); err != nil {
		return fmt.Errorf("parse %s: %w", path, err)
	}
	mut(t)
	return writeTaskFile(dir, slug, t)
}

func parseFilters(filters []string) (map[string]string, error) {
	out := map[string]string{}
	for _, f := range filters {
		i := strings.Index(f, "=")
		if i <= 0 {
			return nil, fmt.Errorf("--filter %q: expected k=v", f)
		}
		out[f[:i]] = f[i+1:]
	}
	return out, nil
}

func matchesFilters(t map[string]any, filters map[string]string) bool {
	for k, want := range filters {
		got, ok := t[k]
		if !ok {
			return false
		}
		if fmt.Sprintf("%v", got) != want {
			return false
		}
	}
	return true
}

func slugOf(t map[string]any) string {
	if s, ok := t["slug"].(string); ok {
		return s
	}
	return ""
}

// nowISO honours JARVIS_FAKE_NOW (UTC ISO 8601) for deterministic tests.
func nowISO() string {
	if fake := os.Getenv("JARVIS_FAKE_NOW"); fake != "" {
		// Pass-through if it parses cleanly; otherwise fall back to system clock.
		if t, err := time.Parse("2006-01-02T15:04:05Z", fake); err == nil {
			return t.UTC().Format("2006-01-02T15:04:05Z")
		}
	}
	return time.Now().UTC().Format("2006-01-02T15:04:05Z")
}

// multiFlag implements flag.Value for repeatable flags like --filter.
type multiFlag []string

func (m *multiFlag) String() string     { return strings.Join(*m, ",") }
func (m *multiFlag) Set(v string) error { *m = append(*m, v); return nil }

func ptr(s string) *string { return &s }

// parseInterspersed walks args once, populating `known` (a flag-name ->
// destination map) and returning leftover positional tokens. Supports:
//
//	--flag value        consumed as two tokens
//	--flag=value        single token, '=' separator
//	--                  end-of-flags marker; remaining tokens are positional
//
// Any unknown `--*` token is an error (so typos surface early).
func parseInterspersed(args []string, known map[string]*string) ([]string, error) {
	var positional []string
	i := 0
	for i < len(args) {
		tok := args[i]
		if tok == "--" {
			positional = append(positional, args[i+1:]...)
			break
		}
		if strings.HasPrefix(tok, "--") {
			name := tok
			val := ""
			if eq := strings.Index(tok, "="); eq >= 0 {
				name = tok[:eq]
				val = tok[eq+1:]
				dst, ok := known[name]
				if !ok {
					return nil, fmt.Errorf("unknown flag %q", name)
				}
				*dst = val
				i++
				continue
			}
			dst, ok := known[name]
			if !ok {
				return nil, fmt.Errorf("unknown flag %q", name)
			}
			if i+1 >= len(args) {
				return nil, fmt.Errorf("flag %q requires a value", name)
			}
			*dst = args[i+1]
			i += 2
			continue
		}
		positional = append(positional, tok)
		i++
	}
	return positional, nil
}
