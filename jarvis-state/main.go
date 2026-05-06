// jarvis-state — typed JSON store + frontmatter helper for the jarvis CLI.
//
// Replaces the per-note 8-fork bash pipeline (fm_split → dasel → 5×jq →
// jq merge under flock) with a single in-process binary. On a 50-note
// rebuild, this drops the wall-clock from ~1.9s → <50ms (38× speedup) and
// scales to thousands of notes without re-walking the same file 8 times.
//
// Subcommands (see `--help` for full list):
//   frontmatter parse|emit|set
//   note index update|rebuild|batch
//   note resolve <prefix>
//   slug normalize <text>
//   focus pairs|stats
//   task list|add|done|edit|remove
//   stats weekly|monthly
//   emit-fixtures-for-parity (hidden, parity gate)
//
// All time-sensitive reads honour JARVIS_TODAY then JARVIS_FAKE_NOW; all
// state reads honour JARVIS_PROFILE and JARVIS_HOME (matching the bash
// state/profile.sh resolver).

package main

import (
	"fmt"
	"io"
	"os"
)

const protocolVersion = 1

func main() {
	os.Exit(run(os.Stdout, os.Stderr, os.Args[1:]))
}

func run(stdout, stderr io.Writer, args []string) int {
	if len(args) == 0 || args[0] == "-h" || args[0] == "--help" {
		usage(stdout)
		return 0
	}
	if args[0] == "--protocol-version" {
		fmt.Fprintln(stdout, protocolVersion)
		return 0
	}
	rest := args[1:]
	switch args[0] {
	case "frontmatter":
		return frontmatterCmd(stdout, stderr, rest)
	case "note":
		return noteCmd(stdout, stderr, rest)
	case "task":
		return taskCmd(stdout, stderr, rest)
	case "slug":
		return slugCmd(stdout, stderr, rest)
	case "focus":
		return focusCmd(stdout, stderr, rest)
	case "stats":
		return statsCmd(stdout, stderr, rest)
	case "emit-fixtures-for-parity":
		return parityCmd(stdout, stderr, rest)
	default:
		fmt.Fprintf(stderr, "jarvis-state: unknown subcommand %q\n", args[0])
		return 2
	}
}

func usage(w io.Writer) {
	fmt.Fprint(w, `jarvis-state — state + frontmatter helper for the jarvis CLI.

Subcommands:
  frontmatter parse <file>             YAML frontmatter -> compact JSON
  frontmatter emit                     stdin: JSON  -> stdout: ---\nyaml\n---\n
  frontmatter set <file> <key> <val>   in-place set (atomic via tmp+rename)

  note index update <kind/slug>        patch a single row under flock
  note index rebuild                   regenerate .index.json from disk
  note index batch                     keys on stdin, batched updates

  note resolve <prefix>                prefix-resolve a note slug

  task list [--filter k=v ...]         JSON array of tasks
  task add <desc> [--priority] [--due] [--project]
  task done <slug>
  task edit <slug> [...]
  task remove <slug>

  slug normalize <text> [--collision-dir DIR --ext json|md]

  focus pairs                          NDJSON of paired sessions
  focus stats today                    integer minutes today
  focus stats top-topics [--days N --limit M]

  stats weekly                         markdown rollup table (--json for JSON)
  stats monthly                        same, monthly window

  --protocol-version                   prints '1' (jarvis pin checker)
  --help                               this text

Environment:
  JARVIS_HOME      state-dir root (default $XDG_DATA_HOME/jarvis or ~/.local/share/jarvis)
  JARVIS_PROFILE   active profile (default 'default')
  JARVIS_FAKE_NOW  UTC ISO 8601 — pins 'now' for tests
  JARVIS_TODAY     YYYY-MM-DD — pins 'today' (overrides JARVIS_FAKE_NOW for the date)
`)
}