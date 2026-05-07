# Story: folder-tree note store with YAML frontmatter and tags. `note new`
# captures by kind; `note list` filters by kind / tag; daily notes auto-rotate
# by date.
#
# Run via the hermetic recorder: scripts/record-demos.sh note

Output ".vhs/gifs/jarvis-note.gif"

Set Shell "bash"
Set FontSize 20
Set Width 1200
Set Height 800
Set Padding 20
Set TypingSpeed 50ms

Hide
Type "clear"
Enter
Sleep 100ms
Show

# Drop a quick note into inbox with tags.
Type "jarvis note new 'k3s upgrade plan: drain etcd quorum first' --tag k3s --tag arch --no-edit --profile demo"
Enter
Sleep 2s

# Daily note — date-stamped slug.
Type "jarvis note daily 'standup notes for today' --no-edit --profile demo"
Enter
Sleep 2s

# List by kind; tag filter.
Type "clear && jarvis note list --kind inbox --profile demo"
Enter
Sleep 3s

Type "clear && jarvis note list --tag k3s --profile demo"
Enter
Sleep 3s
