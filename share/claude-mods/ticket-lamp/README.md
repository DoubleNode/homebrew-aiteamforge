# ticket-lamp

Part of the AITeamForge mods marketplace (`aiteamforge-mods`). Sources live in `claude-mods/ticket-lamp/`.

- **Draws:** One line with this session's kanban ticket: status, subitems resolved/total, release and epic; green when really done. Follows the session onto later tickets (v0.2.x) and keeps earlier ones at the front.
- **Command:** `/ticket`; `pin <ID>|auto|on|off|help`
- **Calls on the host:** `grep` and `jq` on the team boards named in `$AITEAMFORGE_CONFIG` (default `~/.aiteamforge/team-paths.json`); reads `CC_SESSION_NAME` set by kb-run
- **Turn it off:** `/ticket off`, or the `/mods` switchboard (shared `~/.claude/mods/switches.json`)
- **Degrades to:** drawing nothing when its inputs are missing; it never shows a guessed figure.
- **Tests:** `claude plugin test claude-mods/ticket-lamp`; validate with `claude plugin validate claude-mods/ticket-lamp`.
