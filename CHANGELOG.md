# Changelog

All notable changes to the AITeamForge Homebrew Tap.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html)

## [Unreleased]

### Fix: XACA-0510 — Rework `update_launchagents` to render from templates

- **`libexec/commands/aiteamforge-upgrade.sh`** — Added `_render_launchagent_template()` private helper that applies the full `sed` substitution map (`USER_HOME`, `AITEAMFORGE_DIR`, `BACKUP_INTERVAL`, `PYTHON3_PATH`) to any plist template. All four substitutions are applied to every template — harmless extras prevent sibling-drift bugs (per the pattern catalogued in XACA-0501).
- **`update_launchagents()`** reworked from a plain `cp source target` loop to a render-from-template loop: iterate a `"plist-name:template-basename"` pairing, render the template to a `*.new` tempfile, diff the rendered output against the live target (not the raw template — templates always look different due to `{{VAR}}` placeholders), and reload via `launchctl unload → mv → launchctl load` only on change. Tempfiles are cleaned up on all no-op paths (no `*.new` leakage).
- **Source path change is load-bearing:** the old loop looked for pre-built plists at `${FRAMEWORK_DIR}/share/launchagents/<agent>` — a directory the tap does not ship. Templates live at `${FRAMEWORK_DIR}/share/templates/kanban/<basename>`. This is what caused the silent no-op introduced by the original code (XACA-0476 corrected the prefix but couldn't unblock the absent-source early-out).
- **Semantics preserved:** `FORCE=true` re-renders even when target is up to date; `DRY_RUN=true` writes nothing and prints "Would update"; `launchctl unload` runs before `mv`, `launchctl load` runs after (both tolerate failure via `2>/dev/null || true`); agents absent from `~/Library/LaunchAgents/` are skipped — upgrade does not silently install agents the user opted out of.
- **`LAUNCHAGENTS_DIR` seam** — Function respects `LAUNCHAGENTS_DIR` env var (defaults to `$HOME/Library/LaunchAgents`) so tests can inject a sandbox path without touching the real user LaunchAgents dir (M3Pro tap-install ban).
- **`tests/test-xaca-0510-launchagent-render.sh`** — 12 test cases covering: both targets absent → both skipped; fresh render → content written with no `{{…}}` placeholders; rendered content contains resolved `WORKING_DIR`; second run → no-op (mtime unchanged, no tempfile leak); `FORCE=true` → mtime changes; `DRY_RUN=true` → sentinel content preserved, "Would update" printed, no tempfile leak; missing template → warning without crash; both sentinels → both rendered clean.
- **Predecessor:** XACA-0476 corrected the `share/` path prefix; this ticket unblocks the actual render. Sibling site `aiteamforge-migrate.sh::update_launchagents` has a different defect class (in-place sed path rewrite, no template render) tracked separately as XACA-0512.
- **Three confirmed datapoints of sibling-heuristic drift** in this surface: XACA-0476 (missing prefix), XACA-0510 (no template render in upgrade), XACA-0512 (no template render in migrate).
