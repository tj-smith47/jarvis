# Story: pomodoro session with gum spinner + EXIT-trap-safe end log.
# Every start writes a NDJSON row to focus.log; the EXIT trap guarantees
# an end row even on Ctrl+C / SIGTERM. `focus stats` rolls minutes per topic.
#
# Run via the hermetic recorder: scripts/record-demos.sh focus

Output ".vhs/gifs/jarvis-focus.gif"

Set Shell "bash"
Set FontSize 20
Set Width 1200
Set Height 600
Set Padding 20
Set TypingSpeed 50ms

Hide
Type "clear"
Enter
Sleep 100ms
Show

# Short session so the demo runs in seconds; --on tags the topic.
Type "jarvis focus 4s --on 'write VHS tapes' --profile demo"
Enter
Sleep 6s

# Stats roll up by topic from the NDJSON log.
Type "jarvis focus stats --profile demo"
Enter
Sleep 3s
