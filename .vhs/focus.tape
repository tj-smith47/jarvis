# jarvis focus — pomodoro session with gum spinner + EXIT-trap-safe end log.
# Every start writes a NDJSON row to focus.log; the EXIT trap guarantees an
# end row even on Ctrl+C / SIGTERM. `focus stats` rolls minutes per topic.
# Run standalone: vhs .vhs/jarvis-focus.tape

Output .vhs/gifs/jarvis-focus.gif

Set Shell "bash"
Set FontSize 20
Set Width 1200
Set Height 700
Set Padding 20
Set TypingSpeed 75ms

# Short session so the demo runs in seconds; --on tags the topic.
Type "jarvis focus 4s --on 'write VHS tapes'"
Enter
Sleep 6s

# Stats roll up by topic from the NDJSON log.
Type "jarvis focus stats"
Enter
Sleep 3s
