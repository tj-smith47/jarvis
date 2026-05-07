# jarvis doctor — health rollup: profile path, schema version, dep presence,
# integration enablement (with reason for each disabled item), focus.log
# orphan check, scheduler heartbeat. Static by default; --integrations-live
# invokes providers to surface upstream errors.
# Run standalone: VHS_NO_SANDBOX=true vhs .vhs/doctor.tape

Output ".vhs/gifs/jarvis-doctor.gif"

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

# Default static rollup — no network calls.
Type "jarvis doctor"
Enter
Sleep 5s
