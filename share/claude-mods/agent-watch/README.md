# agent-watch

Part of the AITeamForge mods marketplace (`aiteamforge-mods`). Sources live in `claude-mods/agent-watch/`.

- **Draws:** `◎ AGENTS` above the prompt: the main chat and every helper agent, its model, task and status, and which skills ran.
- **Command:** `/agent-watch` pane; `on|off|clear|status|lint [warn|deny|off|reset]|help`
- **Pane:** each agent row shows model, calls, tokens, the effort its first request carried, and how long it has run (live while running, fixed once done). Below: per-model totals, the dispatch lint counters, and "This chat used" (files read and written, deduped, newest first, `/tmp` and tool-results spill files left out; MCP calls per server).
- **Dispatch lint** (rubric: `claude/MODEL_SELECTION.md` §2, `hooks/rubric.ts`):
  - A `general-purpose`, `Explore` or `Plan` spawn with no `model` inherits the parent (usually Opus). `warn` (default) lets it run and shows a notice naming the rule; `deny` refuses it with "re-dispatch with `model: sonnet` or `model: opus`"; `off` does nothing. Forks, named personas, workflow-script agents, resumed agents and any spawn while `CLAUDE_CODE_SUBAGENT_MODEL` forces the subagent model are never flagged. A model forced some other way, with no environment variable, cannot be seen from a mod and is still counted. Set with `/agent-watch lint warn|deny|off`; stored as `"agent-watch:lint"` in `~/.claude/mods/switches.json` (absent means warn).
  - Each subagent's first request is also judged once: `opus` + `low` effort, and `max` effort outside the `opus` + `max` escalation rung. These are warnings in every mode (the engine's spawn event carries no effort, so this cannot refuse anything).
  - `/agent-watch status` and the pane show the session counters (missing-model, opus+low, max-effort); they survive `/agent-watch clear` (they are the evidence for a deny-by-default decision) and `/agent-watch lint reset` zeroes them. Every spawn finding is a notice under the Agent call and also a dim transcript line, since the notice is dropped when no call dialog is open.
- **Calls on the host:** none beyond the engine
- **Turn it off:** `/agent-watch off`, or the `/mods` switchboard (shared `~/.claude/mods/switches.json`)
- **Gotchas:** the pane ticks once a second while an agent is running (a redraw, no requests). The lint runs on its own setting: `/agent-watch off` or `hide` stops the band and tracking but not the lint (only `lint off` does). It reads one environment variable, `CLAUDE_CODE_SUBAGENT_MODEL` (a host read to list in the hook review). It adds no model calls and is deterministic.
- **Degrades to:** drawing nothing when its inputs are missing; it never shows a guessed figure.
- **Tests:** `claude plugin test claude-mods/agent-watch`; validate with `claude plugin validate claude-mods/agent-watch`.
