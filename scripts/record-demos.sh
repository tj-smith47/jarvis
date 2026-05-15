#!/usr/bin/env bash
# Record VHS demo GIFs for the README.
# Requires: vhs (https://github.com/charmbracelet/vhs), a TTY.
#
# Usage:   scripts/record-demos.sh [tape-name…]    (no args -> all tapes)
# Output:  .vhs/gifs/*.gif (committed; referenced by README + Recordings table)
#
# Hermetic environment:
#   - HOME is redirected to a tempdir; a neutral .bashrc (no aliases /
#     prompt customization / history) is dropped in.
#   - JARVIS_HOME, JARVIS_PROFILE, JARVIS_FAKE_NOW are set so timestamps
#     are deterministic and tapes pick up a frozen synthetic dataset.
#   - PATH is prefixed with a shim dir that mocks gh / jira / gcalcli /
#     curl / osascript / notify-send / open. Real tools are never invoked.
#   - Trap restores the original HOME on EXIT/INT/TERM.
#
# Tripwire: HOME redirection happens BEFORE vhs spawns bash, so any rc-file
# write inside the demo lands in the tempdir and is rm'd on exit. If you
# add a tape that mutates the developer's real $HOME, fix the tape — do
# not relax this guard.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v vhs >/dev/null 2>&1; then
  echo "error: vhs not installed. Install: go install github.com/charmbracelet/vhs@latest" >&2
  exit 1
fi

# Chrome won't run as root without --no-sandbox; VHS reads this env var.
export VHS_NO_SANDBOX=true

# Pin a synthetic "now" so timestamps don't drift between runs.
export JARVIS_FAKE_NOW="2026-05-01T15:00:00Z"
export JARVIS_PROFILE="demo"

DEMO_HOME="$(mktemp -d)"
SHIM_DIR="$DEMO_HOME/shims"
JARVIS_HOME="$DEMO_HOME/jarvis-state"
ORIG_HOME="$HOME"
trap 'rm -rf "$DEMO_HOME"; export HOME="$ORIG_HOME"' EXIT INT TERM

mkdir -p "$SHIM_DIR" "$JARVIS_HOME/$JARVIS_PROFILE"
export JARVIS_HOME

# ---------- neutral bashrc (no aliases / history / prompt customization) ----------
cat > "$DEMO_HOME/.bashrc" <<'STUB'
# Recording stub — no user customization leaks into committed .gif files.
set +H
unset PROMPT_COMMAND
export PS1='$ '
export HISTFILE=/dev/null
export HISTSIZE=0
STUB
cp "$DEMO_HOME/.bashrc" "$DEMO_HOME/.bash_profile"
export HOME="$DEMO_HOME"

# ---------- shimmed external tools ----------
# Each shim is a 2-line script: deterministic JSON / TSV / no-op response.
# Real binaries are never invoked from inside the demo recording.

cat > "$SHIM_DIR/gh" <<'GH'
#!/usr/bin/env bash
case "$1" in
  pr)
    cat <<'JSON'
[
  {"number":482,"title":"feat(router): persistent flags","url":"https://github.com/tj-smith47/clift/pull/482","headRepository":{"name":"clift","owner":{"login":"tj-smith47"}}},
  {"number":91,"title":"fix(notify): X-Gotify-Key header","url":"https://github.com/tj-smith47/jarvis/pull/91","headRepository":{"name":"jarvis","owner":{"login":"tj-smith47"}}}
]
JSON
    ;;
  auth) echo "ok: signed in" ;;
  *)    echo "shim:gh $*" ;;
esac
exit 0
GH
chmod +x "$SHIM_DIR/gh"

cat > "$SHIM_DIR/jira" <<'JIRA'
#!/usr/bin/env bash
case "$1" in
  me) echo "demo.user@example.com" ;;
  issue)
    # Minimal --plain TSV: header row + 2 data rows.
    cat <<'TSV'
KEY	SUMMARY	STATUS
PROJ-101	Audit notify-send fallback	In Progress
PROJ-104	ICS TZID handling	In Progress
TSV
    ;;
  *) echo "shim:jira $*" ;;
esac
exit 0
JIRA
chmod +x "$SHIM_DIR/jira"

cat > "$SHIM_DIR/gcalcli" <<'GC'
#!/usr/bin/env bash
# Stub — calendar provider is configured to ICS in the demo profile, so
# gcalcli is not actually called. Present on PATH so doctor's "available"
# probe lights up green.
exit 0
GC
chmod +x "$SHIM_DIR/gcalcli"

cat > "$SHIM_DIR/curl" <<'CURL'
#!/usr/bin/env bash
# Demo curl: never reach the network. doctor's probe runs `curl --version`
# so emit a short, deterministic version line for clean rendering. ICS
# fetches go to a local file path, not http(s).
case "${1:-}" in
  --version) echo "curl 8.5.0 (demo)"; exit 0 ;;
  *) exit 0 ;;
esac
CURL
chmod +x "$SHIM_DIR/curl"

cat > "$SHIM_DIR/osascript" <<'OSA'
#!/usr/bin/env bash
exit 0
OSA
chmod +x "$SHIM_DIR/osascript"

cat > "$SHIM_DIR/notify-send" <<'NS'
#!/usr/bin/env bash
exit 0
NS
chmod +x "$SHIM_DIR/notify-send"

cat > "$SHIM_DIR/open" <<'OPEN'
#!/usr/bin/env bash
exit 0
OPEN
chmod +x "$SHIM_DIR/open"

# Hermetic `jarvis` wrapper for the recording. Bypasses bin/jarvis (which
# trusts the committed .env, whose relative FRAMEWORK_DIR=../.. resolves
# to nonsense from inside a tempdir HOME) and dispatches directly to the
# cmd script. Subcommands like `note new` route to cmds/note/note.new.sh.
cat > "$SHIM_DIR/jarvis" <<JARVIS_W
#!/usr/bin/env bash
set -euo pipefail
export CLI_DIR="$REPO_ROOT"
export CLIFT_FRAMEWORK_DIR="\${CLIFT_FRAMEWORK_DIR:-/opt/repos/clift}"
cmd="\${1:-}"
[[ -z "\$cmd" ]] && exec bash "\$CLI_DIR/cmds/brief/brief.sh"
shift
sub="\${1:-}"
if [[ -n "\$sub" && -f "\$CLI_DIR/cmds/\$cmd/\$cmd.\$sub.sh" ]]; then
  shift
  exec bash "\$CLI_DIR/cmds/\$cmd/\$cmd.\$sub.sh" "\$@"
fi
exec bash "\$CLI_DIR/cmds/\$cmd/\$cmd.sh" "\$@"
JARVIS_W
chmod +x "$SHIM_DIR/jarvis"

# Suppress notify side-effects entirely during recording.
export JARVIS_NOTIFY_DRYRUN=1

# ---------- seed deterministic data in JARVIS_HOME/demo ----------
PROFILE_DIR="$JARVIS_HOME/$JARVIS_PROFILE"

# Calendar (ICS file path). The brief tape's config.toml points provider here.
cat > "$PROFILE_DIR/cal.ics" <<'ICS'
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//jarvis//demo//EN
BEGIN:VEVENT
DTSTART:20260501T140000Z
DTEND:20260501T150000Z
SUMMARY:Standup
URL:https://meet.example.com/standup
END:VEVENT
BEGIN:VEVENT
DTSTART:20260501T170000Z
DTEND:20260501T173000Z
SUMMARY:1on1 with sam
URL:https://meet.example.com/sam
END:VEVENT
END:VCALENDAR
ICS

# Per-profile config: ICS calendar + oncall + notify channels.
# notify.slack/gotify URLs are deterministic stubs; the curl shim never hits
# the network, so the demo can exercise multi-channel reminders without
# leaking a real webhook into the committed gif.
cat > "$PROFILE_DIR/config.toml" <<TOML
[calendar]
provider = "ics"

[calendar.ics]
source = "$PROFILE_DIR/cal.ics"

[oncall]
primary = "alex"
secondary = "you"

[notify.slack]
webhook = "https://hooks.slack.example/T000/B000/demo"

[notify.gotify]
url   = "https://gotify.example"
token = "demo-token"

[notify.email]
to   = "demo@example.com"
from = "jarvis@example.com"
TOML

# Deploy log — two rows from "today" so brief surfaces both with HH:MM.
cat > "$PROFILE_DIR/deploys.log" <<'DEP'
2026-05-01T13:00:00Z	api	v1.12.3	ok
2026-05-01T08:00:00Z	web	v0.47.1	ok
DEP

# ---------- PATH: shims first, then jarvis bin, then system. ----------
export PATH="$SHIM_DIR:$REPO_ROOT/bin:$PATH"

# ---------- per-tape recording ----------
mkdir -p "$REPO_ROOT/.vhs/gifs"

# Filter to a subset if args were passed; otherwise record all.
TAPES=()
if (( $# > 0 )); then
  for name in "$@"; do
    TAPES+=("$REPO_ROOT/.vhs/${name%.tape}.tape")
  done
else
  while IFS= read -r tape; do
    TAPES+=("$tape")
  done < <(find "$REPO_ROOT/.vhs" -maxdepth 1 -name '*.tape' | sort)
fi

if (( ${#TAPES[@]} == 0 )); then
  echo "no tapes to record" >&2
  exit 1
fi

# Purge stale GIFs only when recording the full set, so a single-tape
# re-record doesn't wipe siblings.
if (( $# == 0 )); then
  echo "Purging stale gifs..."
  find "$REPO_ROOT/.vhs/gifs" -maxdepth 1 -type f -name 'jarvis-*.gif' -delete
fi

echo "Recording (HOME=$HOME, JARVIS_HOME=$JARVIS_HOME)..."
# Per-tape state reset: each tape is its own scene. Mutable artifacts
# (tasks, reminders, focus.log, notes) get wiped between tapes so a tape
# that re-seeds its own data doesn't show counters bumped by an earlier
# tape's writes. The static fixtures (config.toml, cal.ics, deploys.log)
# are restored on each iteration so the demo profile is fully self-contained.
for tape in "${TAPES[@]}"; do
  if [[ ! -f "$tape" ]]; then
    echo "  skip (not found): $tape" >&2
    continue
  fi
  name="$(basename "$tape" .tape)"
  echo "  recording $name..."
  rm -rf \
    "$PROFILE_DIR/tasks" \
    "$PROFILE_DIR/reminders" \
    "$PROFILE_DIR/notes" \
    "$PROFILE_DIR/focus.log" \
    "$PROFILE_DIR/notify.log" \
    "$PROFILE_DIR/cache"
  vhs "$tape"
done

echo ""
echo "Done. GIFs in .vhs/gifs/"
