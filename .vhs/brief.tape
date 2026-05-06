# jarvis brief — morning concierge rollup. Date, oncall, tasks, reminders,
# calendar, PRs, deploys — all in one themed render.
# Run standalone: vhs .vhs/jarvis-brief.tape

Output .vhs/gifs/jarvis-brief.gif

Set Shell "bash"
Set FontSize 20
Set Width 1200
Set Height 900
Set Padding 20
Set TypingSpeed 75ms

# Pretty render — sections, bold headers, themed counts.
Type "jarvis brief"
Enter
Sleep 4s

# Compact mode — single-line oncall + counts, terminal-friendly.
Type "clear && jarvis brief --short"
Enter
Sleep 3s
