# jarvis remind — schedule one-shot or recurring reminders. Channels: local
# desktop notification, gotify push, slack webhook, or email via mail/sendmail.
# A cron or systemd-timer tick polls due reminders and dispatches.
# Run standalone: vhs .vhs/jarvis-remind.tape

Output .vhs/gifs/jarvis-remind.gif

Set Shell "bash"
Set FontSize 20
Set Width 1200
Set Height 900
Set Padding 20
Set TypingSpeed 75ms

# One-shot in 30 minutes via local channel.
Type "jarvis remind 'stretch break' --in 30m --via local"
Enter
Sleep 1s

# Recurring weekday morning to slack.
Type "jarvis remind 'review PRs' --at 09:00 --repeat weekdays --via slack"
Enter
Sleep 1s

# List with status, channels, next-fire timestamps.
Type "clear && jarvis remind list"
Enter
Sleep 4s
