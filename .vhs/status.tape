# Story: single-screen dashboard. Open tasks, focus minutes today, scheduled
# reminders, jira in-flight count. `--json` emits a frozen-schema object for
# piping into tmux/Polybar/etc.
#
# Run via the hermetic recorder: scripts/record-demos.sh status

Output ".vhs/gifs/jarvis-status.gif"

Set Shell "bash"
Set Theme "Dracula"
Set FontSize 20
Set Width 1200
Set Height 900
Set Padding 20
Set TypingSpeed 50ms

# Seed a couple of tasks so the dashboard isn't empty + a reminder so
# the Reminders section shows a "next in Nm" row.
Hide
Type "jarvis task add 'Wire up jarvis demos' --priority high --profile demo >/dev/null"
Enter
Type "jarvis task add 'Audit flock paths' --priority med --profile demo >/dev/null"
Enter
Type "jarvis remind 'standup' --in 25m --profile demo >/dev/null"
Enter
Sleep 200ms
Type "clear"
Enter
Sleep 100ms
Show

# Dashboard render.
Type "jarvis status --profile demo"
Enter
Sleep 4s

# JSON shape — frozen schema, pipeline-friendly.
Type "clear && jarvis status --json --profile demo | jq ."
Enter
Sleep 4s
