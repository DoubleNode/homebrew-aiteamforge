# usage-gauge

Part of the AITeamForge mods marketplace (`aiteamforge-mods`). Sources live in `claude-mods/usage-gauge/`.

- **Draws:** `◔ PLAN`: 5-hour and weekly usage windows, reset time, pace and session cost. A second line above the prompt, only while idle: the prompt cache warm (countdown to cold, with its 5m or 1h lifetime) or cold (since when, and the context a cold message re-writes (at 1.25x the input rate on 5m, 2x on 1h)). In the footer: `Effort <level>` when the main chat's last request carried a different effort than the `/config` menu holds.
- **Command:** `/usage-gauge` pane; `on|off|warn <a> <b>|status|cold-guard on|off|status`
- **Calls on the host:** `date +%z`; `tail -c 400000 <session transcript>` once after each main reply (reads the cache lifetime); `$HOME` and `CLAUDE_CONFIG_DIR` to find the transcript. It never sends a request of its own: no keep-warm.
- **Turn it off:** `/usage-gauge off`, or the `/mods` switchboard (shared `~/.claude/mods/switches.json`)
- **Degrades to:** drawing nothing when its inputs are missing; it never shows an unlabelled guess (an assumed cache lifetime is marked `(guess)`).
- **Tests:** `claude plugin test claude-mods/usage-gauge`; validate with `claude plugin validate claude-mods/usage-gauge`.

## Cache clock and cold-send guard (XACA-1639)

- The lifetime is read from the newest main-thread assistant record of the session transcript that wrote the cache (`usage.cache_creation` 5m/1h split); mixed writes count as 5m. If the transcript is readable but never shows a split, the line says `(guess)` and assumes 5m. If the transcript cannot be found or read, the line is not drawn.
- The transcript may lag the end of a reply by a moment, so the lifetime shown can be that of the reply before; the countdown itself starts at the reply's end.
- Cold-send guard, **default off**: `/usage-gauge cold-guard on` holds a prompt once when the cache is cold and the context is 50k+ tokens. It states the re-write cost (1.25x the input rate on a 5m cache, 2x on 1h; a warm read is 0.1x). Send again to proceed. The engine offers no non-destructive hold (a `prompt.submit` hook can only pass or drop), so a hold is a drop plus a `prompt.fill` of the text. Because that can only restore plain text into the local box, **only a person's own composer prompt that is plain text with no attachment is ever held**, and only after `prompt.fill` confirms the box has the text again. Remote Control (bridge) prompts, anything with an image, audio or document, empty or unrecognised shapes, task notifications, scheduled prompts, peer messages, SDK or `claude -p` runs, slash commands and prompts typed over a running turn always pass straight through. The key is `usage-gauge:cold-guard` in `~/.claude/mods/switches.json`.
- Effort label: the reference is the `/config` effort row when the engine lists one with a level. If it lists none (the engine types name no effort row), the label flags a change from the first effort this session sent.
- Cache line switch: `/usage-gauge cache on|off` (default on, key `usage-gauge:cache` in `~/.claude/mods/switches.json`). Off removes only the cache line; the plan line stays. `/usage-gauge hide` still hides both. The cold-send guard is independent of it.
