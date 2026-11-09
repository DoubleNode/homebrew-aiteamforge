# agent-watch

Part of the AITeamForge mods marketplace (`aiteamforge-mods`). Sources live in `claude-mods/agent-watch/`.

- **Draws:** `◎ AGENTS` above the prompt: the main chat and every helper agent, its model, task and status, and which skills ran.
- **Command:** `/agent-watch` pane; `on|off|clear|help`
- **Calls on the host:** none beyond the engine
- **Turn it off:** `/agent-watch off`, or the `/mods` switchboard (shared `~/.claude/mods/switches.json`)
- **Degrades to:** drawing nothing when its inputs are missing; it never shows a guessed figure.
- **Tests:** `claude plugin test claude-mods/agent-watch`; validate with `claude plugin validate claude-mods/agent-watch`.
