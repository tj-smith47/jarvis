# Story: schedule one-shot or recurring reminders. Channels are local desktop
# notification, gotify push, slack webhook, email. A cron or systemd-timer
# tick polls due reminders and dispatches. `--dry-run` previews without
# writing — useful for tab-completion / muscle-memory checks.
#
# Run via the hermetic recorder: scripts/record-demos.sh remind

Output ".vhs/gifs/jarvis-remind.gif"

Set Shell "bash"
Set Theme "Dracula"
Set FontSize 18
Set Width 1400
Set Height 700
Set Padding 20
Set TypingSpeed 50ms

Hide
Type "clear"
Enter
Sleep 100ms
Show

# Preview only — --dry-run prints the schedule line and exits.
Type "jarvis remind 'stretch break' --in 30m --dry-run --profile demo"
Enter
Sleep 2s

# Persist a one-shot via local channel.
Type "jarvis remind 'stretch break' --in 30m --via local --profile demo"
Enter
Sleep 2s

# Recurring weekday morning, multi-channel.
Type "jarvis remind 'review PRs' --at 09:00 --repeat weekdays --via local,slack --profile demo"
Enter
Sleep 2s

# List — status, channels, next-fire timestamps.
Type "clear && jarvis remind list --profile demo"
Enter
Sleep 4s
