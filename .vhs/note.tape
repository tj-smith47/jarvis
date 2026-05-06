# jarvis note — folder-tree note store with YAML frontmatter and tags.
# `note current` layers onto today's daily note; `note list` filters by folder.
# Run standalone: vhs .vhs/jarvis-note.tape

Output .vhs/gifs/jarvis-note.gif

Set Shell "bash"
Set FontSize 20
Set Width 1200
Set Height 900
Set Padding 20
Set TypingSpeed 75ms

# Drop a quick note into inbox with tags.
Type "jarvis note add 'k3s upgrade plan: drain etcd quorum first' --tag k3s --tag arch"
Enter
Sleep 1s

# Daily-folder note — date-stamped slug.
Type "jarvis note daily 'standup notes for today'"
Enter
Sleep 1s

# List by kind; tag filter.
Type "jarvis note list --kind inbox"
Enter
Sleep 2s
Type "clear && jarvis note list --tag k3s"
Enter
Sleep 3s
