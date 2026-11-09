# gate-board

Part of the AITeamForge mods marketplace (`aiteamforge-mods`). Sources live in `claude-mods/gate-board/`.

- **Draws:** `⛭ GATES`: tester and reviewer bot verdicts, CI, and open protected subitems for the current PR.
- **Command:** `/gate-board`; `on|off|help`
- **Calls on the host:** `git` (branch, common dir); `gh pr view` (read-only; draws nothing without gh auth)
- **Turn it off:** `/gate-board off`, or the `/mods` switchboard (shared `~/.claude/mods/switches.json`)
- **Degrades to:** drawing nothing when its inputs are missing; it never shows a guessed figure.
- **Tests:** `claude plugin test claude-mods/gate-board`; validate with `claude plugin validate claude-mods/gate-board`.
