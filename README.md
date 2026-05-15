# jarvis — personal ops concierge CLI

Daily driver for notes, tasks, focus sessions, reminders, standup drafts, and calendar
integration. Built on [clift](https://github.com/tj-smith47/clift), the Task-based CLI
framework.

## Demo

![morning brief — calendar, PRs, deploys, oncall](.vhs/gifs/jarvis-brief.gif)

## What it is

jarvis is a shell CLI for personal productivity. It manages focus sessions, note capture,
task tracking, reminders, and morning briefings — all profile-aware so work and home
contexts stay separate. Data lives in plain files (`~/.jarvis-state/<profile>/`); no
database, no daemon.

The CLI exercises the full clift framework surface: parsed and passthrough commands,
persistent flags, override slots, NDJSON integration contracts, Go + Rust + Python native
helpers compiled via `task build`. It functions both as a working daily-use tool and as
the reference dogfood implementation for clift development.

## Quick start

```bash
# Prerequisites: bash 4+, task (go-task), jq, yq
# Optional: gum (pretty prompts), go 1.21+, rust 1.70+, python 3.8+

# 1. Install clift framework:
git clone https://github.com/tj-smith47/clift "$HOME/.clift"
export PATH="$HOME/.clift/bin:$PATH"

# 2. Clone jarvis:
git clone https://github.com/tj-smith47/jarvis "$HOME/.jarvis"
cd "$HOME/.jarvis"

# 3. Build native helpers:
task build

# 4. Bootstrap the CLI (writes bin/jarvis wrapper + .env for *this* machine —
#    the committed .env is a template that points at relative dev paths):
task setup:cli

export PATH="$HOME/.jarvis/bin:$PATH"
jarvis --help
```

## Commands

Twelve top-level commands. Every command is profile-aware (`--profile <name>`)
and has `--help` for its full flag set.

| Command | Purpose |
|---------|---------|
| [`brief`](#brief)     | Morning rollup — calendar, PRs, jira, tasks, deploys, oncall |
| [`coffee`](#coffee)   | Themed coffee timer; writes to focus.log |
| [`cleanup`](#cleanup) | Prune stale state (focus orphans, expired reminders) |
| [`doctor`](#doctor)   | Health check — profile path, schema version, integrations |
| [`focus`](#focus)     | Pomodoro session + per-topic rollups |
| [`meeting`](#meeting) | "Next meeting" lookup + join |
| [`note`](#note)       | Folder-tree note store with tags + daily/meeting notes |
| [`notify`](#notify)   | Configure notification channels (slack / gotify / email) |
| [`remind`](#remind)   | One-shot or recurring reminders, multi-channel |
| [`standup`](#standup) | Yesterday/Today/Blockers draft from git + jira + tasks + notes |
| [`status`](#status)   | One-screen dashboard with `--json` shape for tmux/Polybar |
| [`task`](#task)       | Per-slug JSON task tracker with priorities and tags |

### `brief`

Morning rollup. Calendar, PRs awaiting review, Jira in flight, tasks, focus
streak, reminders today, deploys, oncall — every section gated off when its
provider returns nothing.

```bash
jarvis brief                                # full themed render
jarvis brief --short                        # single-line counts + oncall
jarvis brief --skip-jira --skip-prs         # selective filtering
jarvis brief --notify gotify                # render + dispatch to a channel
jarvis brief install                        # write a cron line for it
```

### `coffee`

```bash
jarvis coffee                               # medium, no milk
jarvis coffee --size large --milk           # ceremonial
```

### `cleanup`

```bash
jarvis cleanup                              # prune focus orphans + expired reminders
jarvis cleanup install                      # schedule periodic via cron/systemd
```

### `doctor`

```bash
jarvis doctor                               # static rollup, no network
jarvis doctor --path                        # print state dir and exit
jarvis doctor --integrations-live           # probe gh/jira/calendar live
jarvis doctor --rebuild-index               # regenerate notes/.index.json
jarvis doctor --reap-focus-orphans          # close dangling focus sessions
```

### `focus`

```bash
jarvis focus 25m --on "review auth PR"      # pomodoro; logs start+end rows
jarvis focus stats                          # today + top topics (last 7d)
jarvis focus stats --days 30 --limit 5
```

### `meeting`

```bash
jarvis meeting next                         # next event from the calendar provider
jarvis meeting join                         # open next event's URL
```

### `note`

```bash
jarvis note new "k3s upgrade plan" --tag k3s --tag arch
jarvis note daily                           # today's daily, auto-rotates by date
jarvis note meeting "standup"
jarvis note tag <slug> +blocker -wip        # add 'blocker', remove 'wip'
jarvis note list --kind inbox
jarvis note list --tag blocker
jarvis note search "etcd"
jarvis note show <slug>
jarvis note edit <slug>                     # opens $EDITOR
jarvis note archive <slug>
```

### `notify`

```bash
jarvis notify configure slack               # interactive prompts for webhook
jarvis notify configure gotify              # url + token + priority
jarvis notify configure email               # to + from + transport
printf 'https://hooks.slack.com/...\n' \
  | jarvis notify configure slack --non-interactive
```

### `remind`

```bash
jarvis remind "stretch break" --in 30m
jarvis remind "stretch break" --in 30m --dry-run
jarvis remind "review PRs" --at 09:00 --repeat weekdays --via local,slack
jarvis remind list
jarvis remind cancel <slug>
jarvis remind install                       # cron or systemd timer (per config)
jarvis remind tick                          # one dispatch sweep (cron entry)
```

Channels: `local` (desktop notification), `gotify`, `slack`, `email`. Each
must be configured via `jarvis notify configure <channel>` first — `remind`
validates `[notify.<channel>]` at schedule time and refuses to write a
reminder it cannot deliver.

### `standup`

Yesterday/Today/Blockers draft, fully auto-derived:

| Section | Source |
|---|---|
| Yesterday | git log (within `--since`, author = local repo's `user.email`) + jira comments |
| Today | open tasks in `<profile>/tasks/*.json` + jira "In Progress" issues |
| Blockers | notes tagged `blocker` (non-archived) + tasks tagged `blocker` |

Blockers are **never written directly** — tag a note or task with `blocker`
and it surfaces here. The blocker scan is age-unbounded, so a five-day-old
blocker without a recent edit still shows up.

```bash
jarvis standup                              # default --since 1d
jarvis standup --since 6h --repo /opt/repos/cfgd
jarvis standup --all-repos                  # uses [standup] repos = […]
jarvis standup discover                     # walk ~/src, populate [standup] repos
jarvis standup --join                       # open today's standup meet URL
```

### `status`

```bash
jarvis status                               # one-screen dashboard
jarvis status --json | jq .                 # frozen schema for tmux/Polybar
```

### `task`

```bash
jarvis task add "ship vhs demos" --priority high --due today
jarvis task add "investigate freeze" --tag blocker     # → surfaces in standup
jarvis task add "audit flock paths" --project release
jarvis task list                            # open only
jarvis task list --all                      # include done
jarvis task list --tag blocker --json
jarvis task done <slug>                     # slug prefix matching ok
jarvis task remove <slug>
jarvis task edit <slug>
```

## Recordings

Each command has a tape in [`.vhs/`](.vhs/) — re-render with `VHS_NO_SANDBOX=true vhs .vhs/<name>.tape`.

| | |
|---|---|
| **brief** — morning rollup | ![brief](.vhs/gifs/jarvis-brief.gif) |
| **coffee** — themed brew | ![coffee](.vhs/gifs/jarvis-coffee.gif) |
| **doctor** — health check | ![doctor](.vhs/gifs/jarvis-doctor.gif) |
| **focus** — pomodoro + stats | ![focus](.vhs/gifs/jarvis-focus.gif) |
| **note** — folder-tree notes | ![note](.vhs/gifs/jarvis-note.gif) |
| **remind** — schedule + list | ![remind](.vhs/gifs/jarvis-remind.gif) |
| **standup** — yesterday/today/blockers | ![standup](.vhs/gifs/jarvis-standup.gif) |
| **status** — dashboard + JSON | ![status](.vhs/gifs/jarvis-status.gif) |
| **task** — add/list/done | ![task](.vhs/gifs/jarvis-task.gif) |

## Profiles

jarvis is profile-aware. Pass `--profile <name>` (or `-p <name>`) before or after any
command; the flag is persistent so it applies across the whole invocation. Profile names
are unconstrained — `work` is the default seed, but you can name profiles whatever fits
your contexts (`home`, `oncall`, `opensource`, `clientx`, …). State directories, calendar
sources, Slack webhooks, and standup repo lists are all per-profile.

```bash
jarvis --profile home status
jarvis -p work brief --short
```

## Configuration

Two surfaces, two purposes:

**`.env`** — framework wiring, set once at install time by `task setup:cli`. Stores
`CLI_DIR`, `FRAMEWORK_DIR`, `CLIFT_MODE`, `LOG_THEME`. Not profile-specific.

**`~/.jarvis-state/<profile>/config.toml`** — per-profile credentials and preferences:

```toml
[calendar]
provider = "ics"          # ics | gcalcli | applescript | none

[calendar.ics]
source = "https://example.com/calendar.ics"

[notify.slack]
webhook = "https://hooks.slack.com/..."

[standup]
repos = ["owner/repo-a", "owner/repo-b"]

[scheduler]
backend = "cron"          # cron | systemd

[oncall]
primary   = "alex"
secondary = "you"
pager     = "+1555..."
until     = "2026-05-09"  # optional rotation expiry; surfaced in `brief`
```

**`~/.jarvis-state/<profile>/deploys.log`** — append-only TSV of recent
deploys. `brief` and `standup` read this; nothing in jarvis writes to it.
Pipe your CI/deployment system's output here, or append manually:

```
<ts>\t<service>\t<version>\t<status>
2026-05-07T08:14:00Z	api	v3.2.1	ok
2026-05-07T07:51:00Z	shelly	v0.4.0	ok
2026-05-06T22:14:00Z	api	v3.2.0	rolled-back
```

`<ts>` must be UTC ISO-8601. `<status>` is free-form; common values are
`ok`, `failed`, `rolled-back`. Lines beginning with `#` are ignored.

**`~/.jarvis-state/<profile>/notify.log`** — channel-attempt audit trail
written by every `notify_dispatch` call. NDJSON, one row per attempt
(`{ts, channel, ok, message[, error]}`). Mode `0600` because message
bodies can carry secrets/PII. Today this is read-only outside of
`status` and `standup` aggregations; not meant for user editing.

## Architecture

Application conventions and sourced-library rules: [`CLAUDE.md`](CLAUDE.md)

Integration NDJSON contract (calendar, gh, jira, deploys, oncall): [`docs/ndjson-contract.md`](docs/ndjson-contract.md)

Native helpers:
- `jarvis-state` (Go) — state file reads/writes, frontmatter, focus log
- `jarvis-cal` (Rust) — ICS + gcalcli TSV to unified NDJSON event stream
- `jarvis-when` (Python, stdlib only) — natural-language time parsing for `remind`

## Development

```bash
export CLIFT_FRAMEWORK_DIR=/path/to/clift   # or $HOME/.clift

# Build native helpers:
task build

# Run full test suite:
bats tests/

# Lint:
shellcheck lib/**/*.sh cmds/**/*.sh

# Rust unit tests:
cargo test --manifest-path jarvis-cal/Cargo.toml
```

## License

MIT. See [LICENSE](LICENSE).
