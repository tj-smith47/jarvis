// slug normalize <text> [--collision-dir DIR --ext json|md] [--prefix-of DIR]
//
// Mirrors lib/slug.sh:13-98 byte-for-byte:
//   - first-line-only, lowercase, [^a-z0-9] -> '-', collapse '--', trim edges
//   - cap at 100 chars (room for collision suffix + .ext sidecars)
//   - non-empty enforcement (exit 2 on empty input)
//   - --collision-dir D: append `-2`, `-3`, ... if `D/<slug>.<ext>` exists
//   - --prefix-of D: prefix-resolve against `D/*.<ext>`; print unique slug or
//     candidates list + exit 1 (matches slug_resolve_prefix())

package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

func slugCmd(stdout, stderr io.Writer, args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "usage: jarvis-state slug normalize <text> [--collision-dir DIR --ext EXT] | --prefix-of DIR")
		return 2
	}
	switch args[0] {
	case "normalize":
		return slugNormalize(stdout, stderr, args[1:])
	default:
		fmt.Fprintf(stderr, "jarvis-state slug: unknown subcommand %q\n", args[0])
		return 2
	}
}

func slugNormalize(stdout, stderr io.Writer, args []string) int {
	known := map[string]*string{
		"--collision-dir": ptr(""),
		"--ext":           ptr("json"),
		"--prefix-of":     ptr(""),
	}
	rest, err := parseInterspersed(args, known)
	if err != nil {
		fmt.Fprintf(stderr, "slug normalize: %v\n", err)
		return 2
	}
	collDir := *known["--collision-dir"]
	ext := *known["--ext"]
	prefixOf := *known["--prefix-of"]
	if len(rest) != 1 {
		fmt.Fprintln(stderr, "usage: jarvis-state slug normalize <text> [--collision-dir DIR --ext EXT | --prefix-of DIR]")
		return 2
	}

	if prefixOf != "" {
		return slugResolvePrefix(stdout, stderr, rest[0], prefixOf, ext)
	}

	base := slugFromDesc(rest[0])
	if base == "" {
		fmt.Fprintln(stderr, "jarvis-state slug: input produced empty slug")
		return 2
	}

	if collDir == "" {
		fmt.Fprintln(stdout, base)
		return 0
	}
	resolved := slugResolveCollision(base, collDir, ext)
	fmt.Fprintln(stdout, resolved)
	return 0
}

// slugFromDesc — port of lib/slug.sh::slug_from_desc.
//
// Exposed for use by note/task subcommands later; behaviour pinned by
// the bash fixtures (slug.bats).
func slugFromDesc(raw string) string {
	if i := strings.Index(raw, "\n"); i >= 0 {
		raw = raw[:i]
	}
	lowered := strings.ToLower(raw)
	var b strings.Builder
	b.Grow(len(lowered))
	for _, r := range lowered {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
		} else {
			b.WriteByte('-')
		}
	}
	collapsed := b.String()
	for strings.Contains(collapsed, "--") {
		collapsed = strings.ReplaceAll(collapsed, "--", "-")
	}
	collapsed = strings.Trim(collapsed, "-")
	if len(collapsed) > 100 {
		collapsed = strings.TrimRight(collapsed[:100], "-")
	}
	return collapsed
}

// slugResolveCollision — port of lib/slug.sh::slug_resolve_collision.
func slugResolveCollision(base, dir, ext string) string {
	candidate := base
	n := 2
	for {
		path := filepath.Join(dir, candidate+"."+ext)
		if _, err := os.Stat(path); os.IsNotExist(err) {
			return candidate
		}
		candidate = fmt.Sprintf("%s-%d", base, n)
		n++
	}
}

// slugResolvePrefix — port of lib/slug.sh::slug_resolve_prefix.
//
// Behaviour:
//   - Exact match on `<dir>/<query>.<ext>` -> print query, exit 0.
//   - Otherwise, every `<dir>/<query>*.<ext>` file is a candidate. Unique
//     -> print, exit 0. Multi -> list candidates on stderr, exit 1.
//   - No matches -> diagnostic on stderr, exit 1.
func slugResolvePrefix(stdout, stderr io.Writer, query, dir, ext string) int {
	exact := filepath.Join(dir, query+"."+ext)
	if _, err := os.Stat(exact); err == nil {
		fmt.Fprintln(stdout, query)
		return 0
	}
	matches, err := filepath.Glob(filepath.Join(dir, "*."+ext))
	if err != nil {
		fmt.Fprintf(stderr, "jarvis-state slug: glob: %v\n", err)
		return 2
	}
	var prefixed []string
	for _, m := range matches {
		base := strings.TrimSuffix(filepath.Base(m), "."+ext)
		if strings.HasPrefix(base, query) {
			prefixed = append(prefixed, base)
		}
	}
	switch len(prefixed) {
	case 0:
		fmt.Fprintf(stderr, "no task matches %q\n", query)
		return 1
	case 1:
		fmt.Fprintln(stdout, prefixed[0])
		return 0
	default:
		sort.Strings(prefixed)
		fmt.Fprintf(stderr, "ambiguous prefix %q — candidates:\n", query)
		for _, p := range prefixed {
			fmt.Fprintf(stderr, "  %s\n", p)
		}
		return 1
	}
}
