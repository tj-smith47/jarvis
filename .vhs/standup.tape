# Story: standup draft from real data. Yesterday's git log + jira comments,
# today's open tasks + jira "In Progress" rows, tagged blocker notes.
# `--join` opens the next standup meeting URL from calendar.
#
# Run via the hermetic recorder: scripts/record-demos.sh standup
# (gh/jira/gcalcli are shimmed; JARVIS_HOME is seeded with config.toml.)

Output ".vhs/gifs/jarvis-standup.gif"

Set Shell "bash"
Set FontSize 20
Set Width 1200
Set Height 800
Set Padding 20
Set TypingSpeed 50ms

# Seed today's "in flight" with two open tasks. The standup demo is
# read-only — yesterday's git log section is empty (no real repo here)
# but jira_today + open_tasks fill the Today column.
Hide
Type "jarvis task add 'Wire up jarvis demos' --priority high --profile demo >/dev/null"
Enter
Type "jarvis task add 'Audit flock paths' --priority med --profile demo >/dev/null"
Enter
Sleep 200ms
Type "clear"
Enter
Sleep 100ms
Show

# Default --since 1d window: yesterday + today, jira pulled via shim.
Type "jarvis standup --since 1d --profile demo"
Enter
Sleep 4s

# Tighter window — past 4 hours.
Type "clear && jarvis standup --since 4h --profile demo"
Enter
Sleep 3s
