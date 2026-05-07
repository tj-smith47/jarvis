# jarvis status — single-screen dashboard. Open tasks, focus minutes today,
# active reminders, oncall, integration health.
# `--json` emits a frozen-schema golden for piping into other tools.
# Run standalone: VHS_NO_SANDBOX=true vhs .vhs/status.tape

Output ".vhs/gifs/jarvis-status.gif"

Set Shell "bash"
Set FontSize 20
Set Width 1200
Set Height 900
Set Padding 20
Set TypingSpeed 50ms

Hide
Type "export HOME=$(mktemp -d) PATH=/opt/repos/jarvis/bin:$PATH PS1='$ '"
Enter
Sleep 200ms
# Seed a couple of tasks so the dashboard isn't empty.
Type "jarvis task add 'Wire up jarvis' --priority high >/dev/null"
Enter
Sleep 200ms
Type "jarvis task add 'Audit flock paths' --priority med >/dev/null"
Enter
Sleep 200ms
Type "clear"
Enter
Sleep 100ms
Show

# Dashboard render.
Type "jarvis status"
Enter
Sleep 4s

# JSON shape — stable schema, useful for tmux/Polybar consumers.
Type "clear && jarvis status --json | jq ."
Enter
Sleep 4s
