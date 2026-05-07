# jarvis task — CRUD over per-slug JSON files. Add, list, done, in three lines.
# Slug auto-generated from description; collision suffixes on repeat.
# Run standalone: VHS_NO_SANDBOX=true vhs .vhs/task.tape

Output ".vhs/gifs/jarvis-task.gif"

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
Type "clear"
Enter
Sleep 100ms
Show

# Add a few tasks — slug echoed on stdout for piping.
Type "jarvis task add 'Wire up jarvis' --priority high --due today"
Enter
Sleep 1s
Type "jarvis task add 'Audit flock paths' --priority med --project release"
Enter
Sleep 1s
Type "jarvis task add 'Ship VHS demos' --priority low"
Enter
Sleep 1s

# List with priority colors + columns.
Type "clear && jarvis task list"
Enter
Sleep 3s

# Mark one done; it drops out of the default open-only listing.
Type "jarvis task done wire-up-jarvis"
Enter
Sleep 1s
Type "jarvis task list --all"
Enter
Sleep 3s
