# jarvis note — folder-tree note store with YAML frontmatter and tags.
# `note current` layers onto today's daily note; `note list` filters by folder.
# Run standalone: VHS_NO_SANDBOX=true vhs .vhs/note.tape

Output ".vhs/gifs/jarvis-note.gif"

Set Shell "bash"
Set FontSize 20
Set Width 1200
Set Height 800
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

# Drop a quick note into inbox with tags.
Type "jarvis note new 'k3s upgrade plan: drain etcd quorum first' --tag k3s --tag arch"
Enter
Sleep 2s

# Daily-folder note — date-stamped slug.
Type "jarvis note daily 'standup notes for today' --no-edit"
Enter
Sleep 2s

# List by kind; tag filter.
Type "clear && jarvis note list --kind inbox"
Enter
Sleep 3s

Type "clear && jarvis note list --tag k3s"
Enter
Sleep 3s
