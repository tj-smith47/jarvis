// focus pairs | stats today | stats top-topics
//
// Replaces the multi-pass jq filter at lib/focus/log.sh:79-228 with one
// streaming pass over focus.log:
//   - paired sessions: topic-keyed stack of opens; emit closed pairs
//   - orphan starts:   leftover opens after the stream ends (used by
//                      `doctor --reap-focus-orphans`)
//
// `stats today` returns a single integer (minutes today, local tz).
// `stats top-topics` returns a JSON array of {topic, minutes, sessions}
// grouped over the last N days.

package main

import (
	"bufio"
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

func focusCmd(stdout, stderr io.Writer, args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "usage: jarvis-state focus pairs|stats ...")
		return 2
	}
	switch args[0] {
	case "pairs":
		return focusPairsCmd(stdout, stderr)
	case "stats":
		return focusStatsCmd(stdout, stderr, args[1:])
	default:
		fmt.Fprintf(stderr, "jarvis-state focus: unknown subcommand %q\n", args[0])
		return 2
	}
}

func focusLogPath() (string, error) {
	pd, err := profileDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(pd, "focus.log"), nil
}

type focusRow struct {
	TS       string `json:"ts"`
	Event    string `json:"event"`
	Duration string `json:"duration,omitempty"`
	Topic    any    `json:"topic"`
}

type focusPair struct {
	StartTS        string `json:"start_ts"`
	EndTS          string `json:"end_ts"`
	Duration       string `json:"duration"`
	Topic          any    `json:"topic"`
	ElapsedSeconds int64  `json:"elapsed_seconds"`
}

func focusPairsCmd(stdout, stderr io.Writer) int {
	pairs, _, err := focusPairAndOrphans()
	if err != nil {
		fmt.Fprintf(stderr, "jarvis-state: %v\n", err)
		return 3
	}
	for _, p := range pairs {
		raw, err := json.Marshal(p)
		if err != nil {
			fmt.Fprintf(stderr, "jarvis-state: encode pair: %v\n", err)
			return 5
		}
		if _, err := fmt.Fprintln(stdout, string(raw)); err != nil {
			return 5
		}
	}
	return 0
}

func focusStatsCmd(stdout, stderr io.Writer, args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "usage: jarvis-state focus stats today | top-topics [--days N --limit M]")
		return 2
	}
	switch args[0] {
	case "today":
		return focusStatsToday(stdout, stderr)
	case "top-topics":
		return focusStatsTopTopics(stdout, stderr, args[1:])
	default:
		fmt.Fprintf(stderr, "jarvis-state focus stats: unknown subcommand %q\n", args[0])
		return 2
	}
}

func focusStatsToday(stdout, stderr io.Writer) int {
	pairs, _, err := focusPairAndOrphans()
	if err != nil {
		fmt.Fprintf(stderr, "jarvis-state: %v\n", err)
		return 3
	}
	today := todayLocalDate()
	var totalSec int64
	for _, p := range pairs {
		if dateOf(p.StartTS) == today {
			totalSec += p.ElapsedSeconds
		}
	}
	fmt.Fprintln(stdout, totalSec/60)
	return 0
}

func focusStatsTopTopics(stdout, stderr io.Writer, args []string) int {
	fs := flag.NewFlagSet("focus stats top-topics", flag.ContinueOnError)
	fs.SetOutput(stderr)
	days := fs.Int("days", 7, "look-back window in days")
	limit := fs.Int("limit", 5, "max rows in result")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	pairs, _, err := focusPairAndOrphans()
	if err != nil {
		fmt.Fprintf(stderr, "jarvis-state: %v\n", err)
		return 3
	}
	cutoff := nowUTC().Add(-time.Duration(*days) * 24 * time.Hour)
	type agg struct {
		Topic    string `json:"topic"`
		Minutes  int64  `json:"minutes"`
		Sessions int    `json:"sessions"`
	}
	bucket := map[string]*agg{}
	for _, p := range pairs {
		topicStr, ok := topicAsString(p.Topic)
		if !ok || topicStr == "" {
			continue
		}
		ts, err := time.Parse("2006-01-02T15:04:05Z", p.StartTS)
		if err != nil || ts.Before(cutoff) {
			continue
		}
		a, ok := bucket[topicStr]
		if !ok {
			a = &agg{Topic: topicStr}
			bucket[topicStr] = a
		}
		a.Minutes += p.ElapsedSeconds / 60
		a.Sessions++
	}
	rows := make([]*agg, 0, len(bucket))
	for _, a := range bucket {
		rows = append(rows, a)
	}
	sort.SliceStable(rows, func(i, j int) bool { return rows[i].Minutes > rows[j].Minutes })
	if *limit > 0 && len(rows) > *limit {
		rows = rows[:*limit]
	}
	enc := json.NewEncoder(stdout)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(rows); err != nil {
		fmt.Fprintf(stderr, "jarvis-state: encode top-topics: %v\n", err)
		return 5
	}
	return 0
}

// focusPairAndOrphans walks focus.log once, producing paired sessions
// and any leftover orphan starts. Topic-keyed stack — same model as the
// jq filter at lib/focus/log.sh:79-100.
func focusPairAndOrphans() ([]focusPair, []focusRow, error) {
	path, err := focusLogPath()
	if err != nil {
		return nil, nil, err
	}
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil, nil
		}
		return nil, nil, err
	}
	defer f.Close()

	var pairs []focusPair
	open := map[string][]focusRow{}

	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024) // tolerate long rows
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		var row focusRow
		if err := json.Unmarshal([]byte(line), &row); err != nil {
			return nil, nil, fmt.Errorf("parse %s line: %w", path, err)
		}
		key := topicKey(row.Topic)
		switch row.Event {
		case "start":
			open[key] = append(open[key], row)
		case "end":
			stack := open[key]
			if len(stack) > 0 {
				start := stack[len(stack)-1]
				open[key] = stack[:len(stack)-1]
				if pair, ok := buildPair(start, row); ok {
					pairs = append(pairs, pair)
				}
			}
		}
		// coffee + unknown events: ignored for the pair model.
	}
	if err := sc.Err(); err != nil {
		return nil, nil, err
	}

	var orphans []focusRow
	for _, stack := range open {
		orphans = append(orphans, stack...)
	}
	return pairs, orphans, nil
}

func buildPair(start, end focusRow) (focusPair, bool) {
	startT, err := time.Parse("2006-01-02T15:04:05Z", start.TS)
	if err != nil {
		return focusPair{}, false
	}
	endT, err := time.Parse("2006-01-02T15:04:05Z", end.TS)
	if err != nil {
		return focusPair{}, false
	}
	return focusPair{
		StartTS:        start.TS,
		EndTS:          end.TS,
		Duration:       start.Duration,
		Topic:          start.Topic,
		ElapsedSeconds: int64(endT.Sub(startT).Seconds()),
	}, true
}

func topicKey(topic any) string {
	s, _ := topicAsString(topic)
	return s
}

func topicAsString(topic any) (string, bool) {
	if topic == nil {
		return "", true
	}
	if s, ok := topic.(string); ok {
		return s, true
	}
	return "", false
}

// dateOf returns the YYYY-MM-DD prefix of an ISO timestamp.
func dateOf(iso string) string {
	if i := strings.Index(iso, "T"); i >= 0 {
		return iso[:i]
	}
	return iso
}

func nowUTC() time.Time {
	if fake := os.Getenv("JARVIS_FAKE_NOW"); fake != "" {
		if t, err := time.Parse("2006-01-02T15:04:05Z", fake); err == nil {
			return t.UTC()
		}
	}
	return time.Now().UTC()
}

// todayLocalDate honours JARVIS_TODAY > JARVIS_FAKE_NOW > system clock,
// matching the lib/native/clock.sh contract for `today`.
func todayLocalDate() string {
	if td := os.Getenv("JARVIS_TODAY"); td != "" {
		return td
	}
	if fake := os.Getenv("JARVIS_FAKE_NOW"); fake != "" {
		if t, err := time.Parse("2006-01-02T15:04:05Z", fake); err == nil {
			return t.UTC().Format("2006-01-02")
		}
	}
	return time.Now().Local().Format("2006-01-02")
}
