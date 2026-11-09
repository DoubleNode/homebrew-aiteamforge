# Mods Switchboard

`/mods` lists every AITeamForge mod, shows where each one is loaded from, and switches it on or off, hidden or shown, in every chat at once. Written for AITeamForge (own code; the idea of a switchboard pane is not new, no code is copied from anyone else's).

## Use

| Command | What it does |
|---|---|
| `/mods` | Opens the Mods pane. On a terminal too narrow for a pane it prints the list instead. |
| `/mods list` | The same list as text. |
| `/mods on <mod>` / `/mods off <mod>` | Turn a mod on or off in every chat. Off means it does no work and draws nothing. |
| `/mods hide <mod>` / `/mods show <mod>` | Hide a mod's drawing but keep it working, or show it again. |
| `/mods open <mod>` | Open the mod's side pane (agent-watch, goal-meter, usage-gauge, replay-theater). |

The pane has the same actions as buttons: On or Off, Hide or Show, Open pane.

## What it reads

- **The list:** `<this mod's folder>/../.claude-plugin/marketplace.json` (the folder marketplace the mods are installed from), plus every entry of `CLAUDE_CODE_PLUGIN_DIRS`. A mod found in both shows both places. With no marketplace next to it (for example loaded with `--plugin-dir`) it lists `CLAUDE_CODE_PLUGIN_DIRS` only and says so.
- **The state:** `~/.claude/mods/switches.json`, the one file every mod reads (see `../README.md`). A missing, empty or malformed file means the defaults, the pane says so, and it never overwrites a file it cannot read.
- **Not loaded:** a mod whose `enabledPlugins` entry in `~/.claude/settings.json` (or `$CLAUDE_CONFIG_DIR/settings.json`) is false, and not true anywhere, is shown as "not loaded" with no toggle. Claude Code does not load it, so nothing here can change that. To load it, run `claude plugin enable <mod>@aiteamforge-mods` (or use `/plugin`), then restart the session; the pane and the `/mods on|off` reply print that exact line. The pane only reads that file.
- **blast-radius** ships off: a missing key means off, so "On" writes `"blast-radius": true`.

The pane never starts `claude` and never writes `settings.json`.

## Install

```
claude plugin marketplace add <path to claude-mods>
claude plugin install mods-switchboard@aiteamforge-mods --scope user
```

## Notes

- `/mods open <mod>` hands the run to a short timer, because the engine refuses a slash command run from inside another slash command's hook. A button press runs it directly.
- The pane polls every 3 seconds while it is open, so a change made in another chat shows up.
- The mod's own row has no Off or Hide: there must always be a way to bring the others back.

Tests: `claude plugin test .` here, and `tests/test-claude-mods-pane-commands.sh` at the repo root checks the pane's tables of pane commands and ships-off mods against the mods themselves.
