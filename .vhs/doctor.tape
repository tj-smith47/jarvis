# Story: health rollup. Profile path, state schema version, every shipped
# dependency (jq / dasel / rg / glow / task / curl / git), per-integration
# enablement with the *reason* a section is disabled, focus.log orphan
# check, scheduler heartbeat.
#
# Run via the hermetic recorder: scripts/record-demos.sh doctor

Output ".vhs/gifs/jarvis-doctor.gif"

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

# Default static rollup — no network calls.
Type "jarvis doctor --profile demo"
Enter
Sleep 5s
