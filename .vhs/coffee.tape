# jarvis coffee — gum spinner + log_success themed exit. Writes a focus.log
# row so the morning routine is self-documenting.
# Run standalone: vhs .vhs/jarvis-coffee.tape

Output .vhs/gifs/jarvis-coffee.gif

Set Shell "bash"
Set FontSize 22
Set Width 1200
Set Height 500
Set Padding 20
Set TypingSpeed 75ms

# Default: medium, no milk.
Type "jarvis coffee"
Enter
Sleep 4s

# Ceremonial: large + milk.
Type "jarvis coffee --size large --milk"
Enter
Sleep 5s
