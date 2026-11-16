# ticket-lamp

Part of the AITeamForge mods marketplace (`aiteamforge-mods`). Sources live in `claude-mods/ticket-lamp/`.

- **Draws:** One line with this session's kanban ticket: status, subitems resolved/total, release and epic; green when really done. Follows the session onto later tickets (v0.2.x) and keeps earlier ones at the front.
- **Lane lines (release sessions):** while an orchestrated run (`kb-run <REL-ID>` auto-run) is active, one indented line per lane sits under the release line, truncated rather than wrapped. The cap mirrors the writer's `lanes_view`: every occupied lane is drawn at any lane number (a stalled, crashed or failed ticket keeps its lane above `maxParallel` and must stay visible), an empty lane only when numbered 1..`maxParallel`, in lane order:
  `├ L1 XACA-1801 · PR #1320 gates · subs 3/5 · +2 queued · 1.2M tok · <short title>`. The title is last so a narrow terminal truncates it before the verdict. With no active run, a closed run, an archived release, or the mod hidden/off, the output is identical to a plain release line.
  - **Verdicts**, each with a glyph or word so colour is never the only signal: `implementing`, `PR #N gates` (or `in review`), `merged ✓`, `question !`, `stalled !`, `crashed ✗`, `failed ✗`, `dispatching…`, `idle` (a freed lane), `cancelled –`. Anything the lamp does not recognise, or that is malformed, is a dim `?`, never green and never a check mark.
  - **Tokens:** `1.2M tok` is the current ticket's input + cache-create + cache-read + output from `release.orchestration.tokens.perItem` (XACA-1808). Nothing is shown when the block or the ticket is missing; a malformed block shows `tok ?`, never 0.
  - **`/ticket`** in a release session adds every lane with its current ticket, verdict, full queue (ids and titles), the tickets the run has finished, per-ticket tokens and the cache-read share. "open tickets" leaves out the tickets already listed under the run (lane currents and queues) and says how many.
  - **Data comes from the board only:** the same single `jq` pass that reads the release (`release.orchestration` lanes, `maxParallel`, `activeRunId`, `closedAt`, `items`, `tokens`, joined with `backlog[]` titles and subitems). Nothing is read from tmux panes or the run ledger.
- **Command:** `/ticket`; `pin <ID>|auto|on|off|help`
- **Calls on the host:** `grep` and `jq` on the team boards named in `$AITEAMFORGE_CONFIG` (default `~/.aiteamforge/team-paths.json`); reads `CC_SESSION_NAME` set by kb-run
- **Turn it off:** `/ticket off`, or the `/mods` switchboard (shared `~/.claude/mods/switches.json`)
- **Degrades to:** drawing nothing when its inputs are missing; it never shows a guessed figure.
- **Tests:** `claude plugin test claude-mods/ticket-lamp`; validate with `claude plugin validate claude-mods/ticket-lamp`.
