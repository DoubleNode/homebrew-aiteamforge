# goal-meter

Part of the AITeamForge mods marketplace (`aiteamforge-mods`). Sources live in `claude-mods/goal-meter/`.

- **Draws:** `◆ GOAL`: task-list progress bar, ETA and the running task.
- **Slow:** a running task past twice the average task time turns the bar and the `▶` amber and also adds the words `· slow` (band and pane), so the state never rests on colour alone.
- **Command:** `/goals` pane; `on|off|clear|help`
- **Calls on the host:** none beyond the engine
- **Turn it off:** `/goals off`, or the `/mods` switchboard (shared `~/.claude/mods/switches.json`)
- **Degrades to:** drawing nothing when its inputs are missing; it never shows a guessed figure.
- **Tests:** `claude plugin test claude-mods/goal-meter`; validate with `claude plugin validate claude-mods/goal-meter`.
