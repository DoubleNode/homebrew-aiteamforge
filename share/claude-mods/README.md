# claude-mods

The AITeamForge Claude Code mods, as one folder marketplace (`aiteamforge-mods`, see `.claude-plugin/marketplace.json`).

## The shared switch file

Every mod reads one file, `~/.claude/mods/switches.json` (`$HOME` based), flat JSON:

```json
{ "agent-watch": false, "ticket-lamp:hidden": true }
```

| Key | Meaning |
|---|---|
| `"<mod>": false` | Off. The mod does no work and draws nothing. |
| `"<mod>": true` | On (only meaningful for a mod that ships off). |
| `"<mod>:hidden": true` | Hidden. The mod keeps working but draws nothing. |
| key absent | On and shown. |

A missing, empty or malformed file, and any value that is not a boolean, means the defaults. Nothing throws and nothing draws wrongly. Writers (`/mods`, and each mod's own `/<mod> on|off|hide|show`) read the whole file, change their keys, write a temp file and rename it into place, so other keys survive and a reader never sees half a file. A file a writer cannot read as an object is left alone.

**blast-radius is the one exception to "missing means on": it ships off.** Its key must be `true` to hold anything.

Hard enable and disable stay with `enabledPlugins` in `settings.json`. The switch file is the soft layer on top: it never loads or unloads a plugin.

Off has two strengths. `claude plugin disable <mod>@aiteamforge-mods` and `/mods off <mod>` are soft: the mod stays installed and `aiteamforge upgrade` leaves it off. `claude plugin uninstall <mod>@aiteamforge-mods` is a permanent opt-out: upgrades will not re-add that mod until you run `claude plugin install <mod>@aiteamforge-mods` yourself. If `aiteamforge-mods` is registered at a path of your own, upgrades warn and leave it; set `AITEAMFORGE_MODS_REPOINT=1` for one run to repoint it. See `docs/claude-plugins-fleet.md` section 16.

### One reader, nine copies

A marketplace install copies each mod on its own, so a mod cannot import a sibling's file. `hooks/switches.ts`, `tests/switch-fixture.ts`, `tests/switches.test.ts` and the small `switch-io` block in each mod's hooks file are therefore byte-identical copies. `tests/test-claude-mods-switches-sync.sh` fails when one drifts. To change the reader, edit one copy and copy it over the rest.

The engine's hook checker also refuses to let the engine handle `$` itself be passed into another module, and wants literal names for `$.env.get`. That is why the shared file takes plain functions, and each mod builds them in its `switch-io` block.

## The /mods pane

`mods-switchboard` (`/mods`) lists the mods and toggles these keys. See its README.

## Dev-only mods

`DEV-ONLY` lists mods that live here but never ship: they are not in `.claude-plugin/marketplace.json` and `sync-tap.sh` will not mirror them (it refuses to run if one leaks). None are listed today: `cache-clock` (third-party, no licence), the last one, was retired by XACA-1639-017. `scripts/check-claude-mods.sh` still validates and tests them. See `docs/claude-plugins-fleet.md` section 16.
