# Story: morning rollup. Calendar / PRs / Jira / Deploys / Oncall in one
# themed render — and crucially, every PR row shows <owner>/<repo>#<num>
# so a multi-repo reviewer can tell which PR they're being asked about.
#
# Run via the hermetic recorder:
#   scripts/record-demos.sh brief
# (The recorder seeds JARVIS_HOME/demo with config.toml + cal.ics + deploys.log
# and shims gh/jira/gcalcli on PATH. HOME is also redirected to a tempdir.)

Output ".vhs/gifs/jarvis-brief.gif"

Set Shell "bash"
Set FontSize 20
Set Width 1200
Set Height 700
Set Padding 20
Set TypingSpeed 50ms

# Seed a couple of tasks so the dashboard isn't empty.
Hide
Type "jarvis task add 'Wire jarvis demos' --priority high --profile demo >/dev/null"
Enter
Type "jarvis task add 'Audit flock paths' --priority med --profile demo >/dev/null"
Enter
Sleep 200ms
Type "clear"
Enter
Sleep 100ms
Show

# Pretty render — Calendar, PRs (with repo!), Jira, Deploys (with HH:MM), Oncall.
Type "jarvis brief --profile demo"
Enter
Sleep 4s

# Compact one-liner — counts + oncall.
Type "clear && jarvis brief --short --profile demo"
Enter
Sleep 3s
