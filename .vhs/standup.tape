# jarvis standup — Yesterday/Today/Blockers from real data: git log + open
# tasks + tagged blocker notes. `--join` opens the next standup meeting URL.
# Run standalone: vhs .vhs/jarvis-standup.tape

Output .vhs/gifs/jarvis-standup.gif

Set Shell "bash"
Set FontSize 20
Set Width 1200
Set Height 900
Set Padding 20
Set TypingSpeed 75ms

# Seed today's "in flight" with a couple of open tasks.
Type "jarvis task add 'Wire up jarvis' --priority high"
Enter
Sleep 1s
Type "jarvis task add 'Audit flock paths' --priority med"
Enter
Sleep 1s

# Default --since 1d window: yesterday's git activity, today's open tasks,
# tagged blocker notes if any.
Type "clear && jarvis standup --since 1d"
Enter
Sleep 4s

# Custom window — past 4 hours.
Type "clear && jarvis standup --since 4h"
Enter
Sleep 3s
