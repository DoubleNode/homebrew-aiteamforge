# inbox-lamp

Part of the AITeamForge mods marketplace (`aiteamforge-mods`). Sources live in `claude-mods/inbox-lamp/`.

- **Draws:** `✉ INBOX`: unread kb-msg count for this terminal; red on freeze or merge-order mail.
- **Command:** `/inbox-lamp`; `on|off|help`
- **Calls on the host:** `tmux display-message` (own pane's session name); `python3 <AITEAMFORGE_DIR|~/aiteamforge|~/dev-team>/kanban-hooks/msg-store.py inbox --json` (read-only)
- **Turn it off:** `/inbox-lamp off`, or the `/mods` switchboard (shared `~/.claude/mods/switches.json`)
- **Degrades to:** drawing nothing when its inputs are missing; it never shows a guessed figure.
- **Tests:** `claude plugin test claude-mods/inbox-lamp`; validate with `claude plugin validate claude-mods/inbox-lamp`.
