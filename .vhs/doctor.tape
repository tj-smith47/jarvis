# jarvis doctor — health rollup: profile path, schema version, dep presence,
# integration enablement (with reason for each disabled item), focus.log
# orphan check, scheduler heartbeat. Static by default; --integrations-live
# invokes providers to surface upstream errors.
# Run standalone: vhs .vhs/jarvis-doctor.tape

Output .vhs/gifs/jarvis-doctor.gif

Set Shell "bash"
Set FontSize 20
Set Width 1200
Set Height 1000
Set Padding 20
Set TypingSpeed 75ms

# Default static rollup — no network calls.
Type "jarvis doctor"
Enter
Sleep 5s

# State path — useful for cd-ing into the profile dir.
Type "clear && jarvis doctor --path"
Enter
Sleep 2s
