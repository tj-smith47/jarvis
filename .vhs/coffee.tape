# jarvis coffee — gum spinner + log_success themed exit. Writes a focus.log
# row so the morning routine is self-documenting.
# Run standalone: VHS_NO_SANDBOX=true vhs .vhs/coffee.tape

Output ".vhs/gifs/jarvis-coffee.gif"

Set Shell "bash"
Set FontSize 22
Set Width 1200
Set Height 400
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

# Default: medium, no milk.
Type "jarvis coffee"
Enter
Sleep 4s

# Ceremonial: large + milk.
Type "jarvis coffee --size large --milk"
Enter
Sleep 5s
