# jarvis status — single-screen dashboard. Open tasks, focus minutes today,
# active reminders, oncall, integration health.
# `--json` emits a frozen-schema golden for piping into other tools.
# Run standalone: vhs .vhs/jarvis-status.tape

Output .vhs/gifs/jarvis-status.gif

Set Shell "bash"
Set FontSize 20
Set Width 1200
Set Height 1000
Set Padding 20
Set TypingSpeed 75ms

# Seed a couple of tasks so the dashboard isn't empty.
Type "jarvis task add 'Wire up jarvis' --priority high"
Enter
Sleep 1s
Type "jarvis task add 'Audit flock paths' --priority med"
Enter
Sleep 1s

# Dashboard render.
Type "clear && jarvis status"
Enter
Sleep 4s

# JSON shape — stable schema, useful for tmux/Polybar consumers.
Type "clear && jarvis status --json | jq ."
Enter
Sleep 4s
