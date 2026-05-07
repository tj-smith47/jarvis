# Story: CRUD over per-slug JSON files. Add / list / done in three lines.
# Slug auto-generated from description; collision suffixes on repeat.
#
# Run via the hermetic recorder: scripts/record-demos.sh task

Output ".vhs/gifs/jarvis-task.gif"

Set Shell "bash"
Set FontSize 20
Set Width 1200
Set Height 900
Set Padding 20
Set TypingSpeed 50ms

Hide
Type "clear"
Enter
Sleep 100ms
Show

# Add a few tasks — slug echoed on stdout for piping.
Type "jarvis task add 'Wire up jarvis demos' --priority high --due today --profile demo"
Enter
Sleep 1s
Type "jarvis task add 'Audit flock paths' --priority med --project release --profile demo"
Enter
Sleep 1s
Type "jarvis task add 'Ship VHS demos' --priority low --profile demo"
Enter
Sleep 1s

# List with priority colors + columns.
Type "clear && jarvis task list --profile demo"
Enter
Sleep 3s

# Mark one done; it drops out of the default open-only listing.
Type "jarvis task done wire-up-jarvis-demos --profile demo"
Enter
Sleep 1s
Type "jarvis task list --all --profile demo"
Enter
Sleep 3s
