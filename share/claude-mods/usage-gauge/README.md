# usage-gauge

Part of the AITeamForge mods marketplace (`aiteamforge-mods`). Sources live in `claude-mods/usage-gauge/`.

- **Draws:** `◔ PLAN`: 5-hour and weekly usage windows, reset time, pace and session cost.
- **Command:** `/usage-gauge` pane; `on|off|warn <a> <b>|status`
- **Calls on the host:** `date +%z`
- **Turn it off:** `/usage-gauge off`, or the `/mods` switchboard (shared `~/.claude/mods/switches.json`)
- **Degrades to:** drawing nothing when its inputs are missing; it never shows a guessed figure.
- **Tests:** `claude plugin test claude-mods/usage-gauge`; validate with `claude plugin validate claude-mods/usage-gauge`.
