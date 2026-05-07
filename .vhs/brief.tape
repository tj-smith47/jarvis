# jarvis brief — morning concierge rollup. Date, oncall, tasks, reminders,
# calendar, PRs, deploys — all in one themed render.
# Run standalone: VHS_NO_SANDBOX=true vhs .vhs/brief.tape

Output ".vhs/gifs/jarvis-brief.gif"

Set Shell "bash"
Set FontSize 20
Set Width 1200
Set Height 700
Set Padding 20
Set TypingSpeed 50ms

# --- Isolated demo HOME (no real-FS leak) ---
Hide
Type "export HOME=$(mktemp -d) PATH=/opt/repos/jarvis/bin:$PATH PS1='$ '"
Enter
Sleep 300ms
Type "jarvis task add 'Wire jarvis' --priority high >/dev/null"
Enter
Sleep 200ms
Type "jarvis task add 'Audit flock paths' --priority med >/dev/null"
Enter
Sleep 200ms
Type "clear"
Enter
Sleep 100ms
Show

# Pretty render — sections, bold headers, themed counts.
Type "jarvis brief"
Enter
Sleep 4s

# Compact mode — single-line oncall + counts, terminal-friendly.
Type "clear && jarvis brief --short"
Enter
Sleep 3s
