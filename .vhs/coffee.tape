# Story: gum spinner + log_success themed exit. Writes a focus.log row so
# the morning routine is self-documenting.
#
# Run via the hermetic recorder: scripts/record-demos.sh coffee

Output ".vhs/gifs/jarvis-coffee.gif"

Set Shell "bash"
Set Theme "Dracula"
Set FontSize 22
Set Width 1200
Set Height 400
Set Padding 20
Set TypingSpeed 50ms

Hide
Type "clear"
Enter
Sleep 100ms
Show

# Default: medium, no milk.
Type "jarvis coffee --profile demo"
Enter
Sleep 4s

# Ceremonial: large + milk.
Type "jarvis coffee --size large --milk --profile demo"
Enter
Sleep 5s
