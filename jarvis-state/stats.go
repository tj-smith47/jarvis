// stats weekly | monthly  — analytics rollups over the jarvis state store.
//
// Reads:
//   * focus.log    paired sessions -> minutes / sessions per topic, totals
//   * tasks/*.json done counts in the window
//   * notes/.index.json  rows with updated_at in the window (note velocity)
//
// Output:
//   default  -> markdown rollup table (suitable for `glow` rendering)
//   --json   -> JSON object {focus:{...}, tasks:{...}, notes:{...}}

package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"sort"
	"strings"
	"time"
)

func statsCmd(stdout, stderr io.Writer, args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "usage: jarvis-state stats weekly|monthly [--json]")
		return 2
	}
	window := args[0]
	rest := args[1:]
	var days int
	switch window {
	case "weekly":
		days = 7
	case "monthly":
		days = 30
	default:
		fmt.Fprintf(stderr, "jarvis-state stats: unknown window %q\n", window)
		return 2
	}
	fs := flag.NewFlagSet("stats "+window, flag.ContinueOnError)
	fs.SetOutput(stderr)
	asJSON := fs.Bool("json", false, "emit JSON instead of markdown")
	if err := fs.Parse(rest); err != nil {
		return 2
	}
	roll, err := buildStatsRollup(days)
	if err != nil {
		fmt.Fprintf(stderr, "jarvis-state: %v\n", err)
		return 3
	}
	if *asJSON {
		enc := json.NewEncoder(stdout)
		enc.SetEscapeHTML(false)
		enc.SetIndent("", "  ")
		if err := enc.Encode(roll); err != nil {
			fmt.Fprintf(stderr, "jarvis-state: encode: %v\n", err)
			return 5
		}
		return 0
	}
	fmt.Fprint(stdout, renderStatsMarkdown(window, days, roll))
	return 0
}

type statsRollup struct {
	WindowDays  int         `json:"window_days"`
	WindowStart string      `json:"window_start"`
	WindowEnd   string      `json:"window_end"`
	Focus       focusRollup `json:"focus"`
	Tasks       tasksRollup `json:"tasks"`
	Notes       notesRollup `json:"notes"`
}

type focusRollup struct {
	Sessions     int            `json:"sessions"`
	TotalMinutes int64          `json:"total_minutes"`
	TopTopics    []topicMinutes `json:"top_topics"`
}

type topicMinutes struct {
	Topic    string `json:"topic"`
	Minutes  int64  `json:"minutes"`
	Sessions int    `json:"sessions"`
}

type tasksRollup struct {
	DoneInWindow int `json:"done_in_window"`
	OpenSnapshot int `json:"open_snapshot"`
}

type notesRollup struct {
	UpdatedInWindow int            `json:"updated_in_window"`
	ByKind          map[string]int `json:"by_kind"`
}

func buildStatsRollup(days int) (statsRollup, error) {
	end := nowUTC()
	start := end.Add(-time.Duration(days) * 24 * time.Hour)
	roll := statsRollup{
		WindowDays:  days,
		WindowStart: start.Format("2006-01-02T15:04:05Z"),
		WindowEnd:   end.Format("2006-01-02T15:04:05Z"),
	}

	pairs, _, err := focusPairAndOrphans()
	if err != nil {
		return roll, err
	}
	topicAgg := map[string]*topicMinutes{}
	for _, p := range pairs {
		ts, err := time.Parse("2006-01-02T15:04:05Z", p.StartTS)
		if err != nil || ts.Before(start) || !ts.Before(end) {
			continue
		}
		roll.Focus.Sessions++
		roll.Focus.TotalMinutes += p.ElapsedSeconds / 60
		topicStr, _ := topicAsString(p.Topic)
		if topicStr == "" {
			continue
		}
		a, ok := topicAgg[topicStr]
		if !ok {
			a = &topicMinutes{Topic: topicStr}
			topicAgg[topicStr] = a
		}
		a.Minutes += p.ElapsedSeconds / 60
		a.Sessions++
	}
	for _, a := range topicAgg {
		roll.Focus.TopTopics = append(roll.Focus.TopTopics, *a)
	}
	sort.SliceStable(roll.Focus.TopTopics, func(i, j int) bool {
		return roll.Focus.TopTopics[i].Minutes > roll.Focus.TopTopics[j].Minutes
	})
	if len(roll.Focus.TopTopics) > 5 {
		roll.Focus.TopTopics = roll.Focus.TopTopics[:5]
	}

	tasks, err := loadAllTasks()
	if err == nil {
		for _, t := range tasks {
			status, _ := t["status"].(string)
			if status == "open" {
				roll.Tasks.OpenSnapshot++
			}
			doneAt, _ := t["done_at"].(string)
			if doneAt == "" {
				continue
			}
			done, err := time.Parse("2006-01-02T15:04:05Z", doneAt)
			if err != nil {
				continue
			}
			if !done.Before(start) && done.Before(end) {
				roll.Tasks.DoneInWindow++
			}
		}
	}

	roll.Notes.ByKind = map[string]int{}
	indexPath, err := noteIndexFile()
	if err == nil {
		idx, err := readIndex(indexPath)
		if err == nil {
			for _, row := range idx {
				updated, err := time.Parse("2006-01-02T15:04:05Z", row.UpdatedAt)
				if err != nil {
					continue
				}
				if !updated.Before(start) && updated.Before(end) {
					roll.Notes.UpdatedInWindow++
					roll.Notes.ByKind[row.Kind]++
				}
			}
		}
	}

	return roll, nil
}

func renderStatsMarkdown(window string, days int, roll statsRollup) string {
	var b strings.Builder
	fmt.Fprintf(&b, "# jarvis %s rollup (%dd)\n\n", window, days)
	fmt.Fprintf(&b, "Window: `%s` → `%s`\n\n", roll.WindowStart, roll.WindowEnd)
	fmt.Fprint(&b, "## Focus\n\n")
	fmt.Fprintf(&b, "* Sessions: **%d**\n", roll.Focus.Sessions)
	fmt.Fprintf(&b, "* Total minutes: **%d**\n", roll.Focus.TotalMinutes)
	if len(roll.Focus.TopTopics) > 0 {
		fmt.Fprint(&b, "\n| Topic | Minutes | Sessions |\n|---|---:|---:|\n")
		for _, t := range roll.Focus.TopTopics {
			fmt.Fprintf(&b, "| %s | %d | %d |\n", t.Topic, t.Minutes, t.Sessions)
		}
	}
	fmt.Fprint(&b, "\n## Tasks\n\n")
	fmt.Fprintf(&b, "* Done in window: **%d**\n", roll.Tasks.DoneInWindow)
	fmt.Fprintf(&b, "* Open snapshot: **%d**\n", roll.Tasks.OpenSnapshot)
	fmt.Fprint(&b, "\n## Notes\n\n")
	fmt.Fprintf(&b, "* Updated in window: **%d**\n", roll.Notes.UpdatedInWindow)
	if len(roll.Notes.ByKind) > 0 {
		var kinds []string
		for k := range roll.Notes.ByKind {
			kinds = append(kinds, k)
		}
		sort.Strings(kinds)
		fmt.Fprint(&b, "\n| Kind | Updates |\n|---|---:|\n")
		for _, k := range kinds {
			fmt.Fprintf(&b, "| %s | %d |\n", k, roll.Notes.ByKind[k])
		}
	}
	return b.String()
}
