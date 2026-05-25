# Changelog

All notable changes to the AITeamForge Homebrew Tap.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html)

## [Unreleased]

### Bugfix: XACA-0559 — `aiteamforge setup` now fully refreshes the runtime on upgrade; bare setup offers Upgrade/Preserve/Reconfigure

`aiteamforge setup --upgrade` behaved identically to a plain run: the `IS_UPGRADE`
flag was set but never read, so there was no "force refresh" path. Worse, when an
upgrade resolved an empty team list, `install-kanban.sh` returned *before* the
shared-component installs, leaving kanban hooks / LCARS UI / helper scripts stale
(the "gate stayed 0" symptom). Bare `aiteamforge setup` on an existing install only
offered a yes/no "Upgrade?" prompt — anything but `yes` exited, with no clean way to
refresh components while keeping config.

This is the `setup` wizard counterpart to XACA-0558's fix for the standalone
`aiteamforge upgrade` command; the two share no code.

- **`bin/aiteamforge-setup.sh`** — `IS_UPGRADE` now drives behavior. On upgrade the
  wizard hydrates `SELECTED_TEAMS`, per-team working dirs, and the feature flags from
  the existing `.aiteamforge-config` (via `jq`; degrades to interactive if jq/config
  is missing or unparseable), forces `INSTALL_KANBAN=yes`, and skips the team- and
  feature-selection prompts so it refreshes exactly the installed teams in place.
  Boards are preserved (`init_kanban_board` already skips existing boards).
  - Bare setup on an existing install now shows a three-way prompt:
    **[U] Upgrade** (default — refresh components, keep teams/config),
    **[P] Preserve** (exit, change nothing), **[R] Reconfigure** (re-run the full
    wizard). Accepts case-insensitive `U`/`P`/`R` or the full words; re-prompts on
    unrecognized input. Non-interactive mode and the `--upgrade` flag auto-upgrade
    without prompting (preserves prior behavior).
- **`libexec/installers/install-kanban.sh`** — `install_kanban_system()` no longer
  early-returns when no teams resolve. Shared components (helpers, board-check, hooks,
  LCARS UI, profile script, iTerm2 window manager, port management, backup,
  LaunchAgents) now ALWAYS refresh when the function is invoked; only the per-team
  `init_kanban_board` loop is gated on teams being non-empty. Empty-team runs warn
  "refreshed shared components only" and return cleanly.
- **bash 3.2 / `set -u` robustness** — guarded the empty-array iterations the upgrade
  path now reaches (`install-kanban.sh` board-init loop and `_get_team_working_dir`;
  macOS `/bin/bash` 3.2 throws *unbound variable* on `"${arr[@]}"` when `arr` is empty).
  Config-derived team ids are passed through `_sanitize_id` before being interpolated
  into `eval`'d variable names, and the sanitizer is defined ahead of the hydration
  block so the upgrade and interactive paths share one copy.

### Bugfix: XACA-0558 — `aiteamforge upgrade` now syncs kanban-hooks + helper scripts (in-place upgrades left them stale)

`aiteamforge upgrade` only re-synced LCARS UI, templates, shell helpers, skills, and
LaunchAgents. It never synced `share/kanban-hooks` or several standalone helper scripts,
so an in-place `brew upgrade` that shipped a new `kanban-hooks/aiteamforge_paths.py` to the
Cellar left the runtime copy stale. The visible symptom was a LCARS warning
`cannot import name build_team_code_map` (XACA-0542) followed by a fall back to hardcoded
directories. Fresh installs were unaffected because `install-kanban.sh` recopies these
components — the defect bit in-place upgrades only.

- **`libexec/commands/aiteamforge-upgrade.sh`** — adds two sync stages, wired into the run
  sequence after `update_lcars`:
  - `update_kanban_hooks()` — additive `rsync` of `share/kanban-hooks/` → `kanban-hooks/`
    (no `--delete`, preserves operator-added hooks) + `chmod +x` on `*.py`. Mirrors
    `install_kanban_hooks`. This is the primary fix.
  - `update_aux_scripts()` — refreshes the standalone scripts `install-kanban.sh` copies
    individually but the upgrade path skipped: `kanban-board-check.sh`,
    `kanban-restore-helper.sh`, `kanban-backup.py` (→ working-dir root) and `kb-cr.sh`
    (→ `scripts/`). Uses the existing per-file `-nt || --force` freshness + `chmod +x`
    convention; only refreshes scripts already installed.
  - `--help` "What Gets Updated" list updated to mention kanban hooks and helper scripts.
- **Audit note:** `lcars-ports` is *not* synced — the tap does not ship `share/lcars-ports`,
  and the runtime directory holds stateful per-team port/theme/order assignments that an
  upgrade must never overwrite.

### Bugfix: XACA-0557 — Make `aiteamforge-port-fix` reachable as a command, add `--check` gate, wire into startup

`kb-port-fix.py` shipped without an exec bit and had no PATH-accessible bin stub, making
it unreachable after a tap install. Added `--check` mode for script-usable gating, and
wired the check into `aiteamforge start` so port collisions are caught before LCARS servers
attempt to bind.

- **`libexec/commands/kb-port-fix.py`** — exec bit added (100644 → 100755). New `--check`
  flag: exits 0 when all ports are unique and non-null, exits 1 if any collision or null
  port is detected. Suitable for use in startup scripts and CI. Bare-invocation behaviour
  (detect mode, exit 2 on issues) is unchanged. Updated argparse description and
  `_print_report` to reference `aiteamforge-port-fix` bin stub name.
- **`Formula/aiteamforge.rb`** — adds `aiteamforge-port-fix` bin stub (analogous to the
  existing `aiteamforge-doctor` stub) that invokes `python3 <libexec>/libexec/commands/kb-port-fix.py`.
  Matching `chmod 0755` and `assert_path_exists` in `test do`. Formula passes `ruby -c` syntax check.
- **`libexec/commands/aiteamforge-start.sh`** — `check_port_health()` function runs
  `aiteamforge-port-fix --check` (falling back to the libexec path) before LCARS servers
  are launched. On failure, prints an actionable message naming the exact remedy command
  (`aiteamforge-port-fix --apply`) and aborts startup. If the tool is not installed, warns
  but continues (degrade gracefully). Gate is wired into both `all` and `lcars|kanban` service paths.
- **`libexec/commands/test_kb_port_fix.py`** — four new `TestCheckMode` test cases covering:
  clean config → exit 0, collision → exit 1, null port → exit 1, `main()` dispatch → exit 0.
- **Review follow-up (PR #472):** `check_port_health()` now holds its resolved command in a
  bash array and invokes it as `"${port_fix_cmd[@]}" --check`, so a libexec path containing
  spaces survives without word-splitting.

### Bugfix: XACA-0555 — `aiteamforge start` launches server.py without LCARS_TEAM (server FATALs on boot)

`aiteamforge start` (and `start lcars`) launched `nohup python3 server.py <port>` with no
`LCARS_TEAM` in the environment. The 0.12.0 server enforces the team-id contract
(`validate_lcars_team_or_die`, team-id-contract §6) and hard-exits at boot with
`FATAL: LCARS_TEAM is not set`, so the dashboard never came up — `/tmp/lcars-server.log`
showed only the fatal.

- **`libexec/commands/aiteamforge-start.sh`** — `start_lcars()` now loops the configured
  team instances (`get_configured_teams`), resolves each team's LCARS port from the
  `aiteamforge_paths` registry (`aiteamforge_team_lcars_port`, via `libexec/lib/aiteamforge-paths.sh`),
  and launches one server per team with `LCARS_TEAM=<team> LCARS_SESSION_NAME=<team>-lcars`
  set — matching the per-team startup scripts. Teams without an allocated port are skipped
  with a warning; ports already serving are treated as already-running. Liveness is now
  verified per port via an HTTP poll (replacing the old single-PID `kill -0` check), and the
  startup log is appended (`>>`) so concurrent team servers don't clobber each other's output.
- **Brew venv python (XACA-0486)** — the launch resolves `$(brew --prefix aiteamforge)/libexec/venv/bin/python3`
  when present (falling back to system `python3`) so runtime imports (pyzipper, requests, …)
  resolve on tap-installed machines.
- **Review hardening (PR #470):** `get_configured_teams` is now `|| true`-guarded so a missing
  config file can't `set -e`-abort `aiteamforge start` before the graceful "no teams" path
  (#001); `aiteamforge-paths.sh` is sourced at top-of-file alongside the other libs for
  consistency (#002). (A larger anti-drift refactor sharing the canonical launch helper — #003 —
  is deferred to its own PR.)

## [0.12.0] - 2026-05-23

### Refactor: XACA-0550 — Narrow damage-control firewall (Homebrew cleanup false-positives)

- **`share/templates/claude/hooks/damage-control/bash-tool-damage-control.py`** — two surgical narrowings of the Bash firewall, mirrored from the canonical `claude-hooks/` source:
  - **Absolute-path anchoring** in `check_path_patterns`: literal absolute paths (`/bin/`, `/usr/`, `/etc/`, …) now match only at a path-component boundary via a `(?<![\w./-])` lookbehind, so a readOnly `/bin/` no longer false-matches `rm /opt/homebrew/bin/claude`. Real system-path ops (space/quote before the path) still match — strictly fewer false positives.
  - **Allowlist** (`allowPatterns`, checked first): a command matching an allow pattern is permitted outright.
- **`share/templates/claude/hooks/damage-control/patterns.yaml`** — adds an `allowPatterns` section seeded with two Homebrew-maintenance exceptions: standalone `brew cleanup|uninstall|untap`, and standalone `rm`/`sudo rm` of Homebrew-managed *subpaths* (`/opt/homebrew/...`, `/usr/local/Cellar|Homebrew/...`). Every allow pattern is anchored `^...$` to a single command so a dangerous op cannot be smuggled via chaining (`&&`, `;`); whole-prefix nukes (`rm -rf /opt/homebrew`) are NOT allowlisted.
- **Verified** with a 24-case battery: Homebrew cleanup now passes; `rm -rf /`, real `/bin`+`/usr` ops, `~/.ssh` access, whole-prefix nuke, and compound-command smuggling all still BLOCK.

- **`share/scripts/teams/freelance-startup.sh`** — snapshot re-synced to its canonical source (byte-identical). The freelance LCARS port is now read from the per-team `lcars-ports/<team>-lcars.port` file (lockstep with `team-paths.json`) instead of being recomputed from a `cksum` of the project name on each launch; cksum is kept only as a fallback for teams with no port file. Prevents reconciled freelance teams (XACA-0547) from silently re-diverging at the next startup.

### Chore: XACA-0547 — Reconcile divergent LCARS ports (mirror sync)

- **`share/kanban-hooks/aiteamforge_paths.py`, `libexec/lib/aiteamforge-paths.sh`** — `DEFAULT_TEAMS` / `_AITEAMFORGE_DEFAULT_TEAMS_DATA` `lcars_port` values for 9 teams reconciled to their authoritative `team-paths.json` ports via `kb-port-reconcile --apply` (canonical source in dev-team): finance-personal→8360, freelance-doublenode-{appplanning→8500, awaysentry→8501, caravan→8502, lifeboard→8503, starwords→8504, workstats→8506}, freelance-liquidstyle-agentbadges-ios→8970, legal-coparenting→8320. Resolves pre-existing three-way divergence so the shipped registry matches the live overlay.

### Feat: XACA-0545 — Tap startup snapshot adopts kb-init-team-guard (auto-init on startup)

Follow-up to XACA-0542. The tap's manual startup-script snapshot (XACA-0483) did not source the new `kb_ensure_team_initialized` guard, so shipped installs never got auto-init-on-startup detection. Closes the full chain: snapshot sources the guard → installer deploys the guard → install-time path rewrite aligns the two.

- **`share/scripts/teams/{finance,freelance,legal,medical}-startup.sh`** — Each now sources `kb-init-team-guard.sh` (immediately after the `lcars-launch-helpers.sh` source) and calls `kb_ensure_team_initialized` at the same logical point as its canonical counterpart. Per-team correct: `legal-startup.sh` has no `SESSION_PREFIX`, so it uses the inline `"legal-${PROJECTID}"`; `freelance-startup.sh` uses the parent-of-`develop` kanban dir. Each snapshot is once again byte-identical to its canonical `*-startup.sh` source.
- **`libexec/installers/install-team.sh`** — The parametric (`_PARAMETRIC_MODE`) install path now deploys `kb-init-team-guard.sh` and `kb-init-team` to `$AITEAMFORGE_DIR/scripts/` via `_xaca0483_install_script`, mirroring the existing `lcars-launch-helpers.sh` treatment. Without this the snapshot's guard `source` line (rewritten from `$HOME/dev-team` to `$AITEAMFORGE_DIR` at install time) would point at a file that was never deployed, and `|| true` would silently no-op the guard.
- **`share/scripts/kb-init-team-guard.sh`, `share/scripts/kb-init-team`** — Materialized into the tap via the re-added `sync-tap.sh` mirror lines (canonical source in dev-team).

### Feature: XACA-0541 — Auto-name Claude sessions + pin session UUID at launch

- **`share/templates/aliases/cc-aliases.sh`** — Ported the dev-side `_cc_launch`/`_cc_save_session` changes into the shipped installer template so installed teams get the same behavior:
  - **`_cc_launch`** now sets a session display name via `claude -n/--name`. The name is taken from the `CC_SESSION_NAME` env var (set by the kb-run*/kb-work* launchers as `<ITEM-ID>: <title>` with `[Review]`/`[Test]`/`[Debug]` mode prefixes), falling back to the kanban/transcript-derived name from `_cc_derive_session_name`. Sanitized (newlines, carriage returns, and pipes collapsed) and truncated to 40 chars; the flag is omitted entirely when empty. The name surfaces in the `/resume` picker, prompt box, and terminal title instead of "Untitled".
  - **`_cc_launch`** also pre-generates a lowercase UUID and passes `claude --session-id <uuid>` so the session id is known before launch. Both flags are feature-detected against `claude --help` and spliced via an array so unsupported/empty values vanish cleanly.
  - **`_cc_save_session`** accepts the pinned UUID as an optional `$1`; when supplied it is used directly, retiring the `ls -t *.jsonl | head -1` heuristic on the fresh-launch path. The heuristic is preserved as the fallback for `ccc`'s `--resume`/`--continue` calls (which remain untouched — `--session-id` is incompatible with `--resume` without `--fork-session`).
- **Scope.** Single change point in `_cc_launch`; `cc`, `ccc`, and the resume/continue paths are unchanged.

### Fix: XACA-0535 — Tap-hygiene guard allow-lists freelance-<client> configs

- **`scripts/check-tap-hygiene.sh`** — Check 3 (XACA-0252 debrand guard) did a blanket case-insensitive `git ls-files | grep -iE 'doublenode'`, which flagged the 6 legitimate freelance CLIENT configs created by XACA-0521 (`share/lcars-ui/team_transfer/config/freelance-doublenode-{appplanning,awaysentry,caravan,lifeboard,starwords,workstats}.yaml`) as stale rebrand debt. These are not rebrand leftovers — `doublenode` is the client name (working dir `/Users/Shared/Development/DoubleNode/...`), parallel to `freelance-liquidstyle-*`; renaming would break team_transfer identity + `amb-session-map.json` refs.
- **Fix.** Added `REBRAND_ALLOWLIST_DIR="share/lcars-ui/team_transfer/config"` alongside the existing exact-match allow-list; the skip loop excuses only DIRECT children matching `freelance-*.yaml` via a `case` glob plus a `dirname` guard. The dirname guard rejects any nested path the glob's `*` would otherwise span (e.g. `config/freelance-X/evil-doublenode.yaml` still fails), and quoting the dir keeps the pattern a literal glob so no SC2254 suppression is needed. A genuine rebrand leftover — elsewhere in the tree or nested under this dir — still fails.
- **`tests/xaca-0361-tap-hygiene-guard.bats`** — Added Test 5 (a freelance client config with `doublenode` in its name is allow-listed → exits 0), Test 6 (allow-list stays narrow: a `doublenode` file outside the config dir still fails even when a legit freelance config is present), and Test 7 (dirname guard: a nested path under the config dir still fails while the direct-child config stays excused). All 7 tests pass; shellcheck clean.
- **Context.** Surfaced during XACA-0528 tap sync, which was committed with `--no-verify` to bypass this false-positive.

### Refactor: XACA-0524 — Consolidate Fleet Monitor port-scan range to shared constant

- **`libexec/lib/constants.sh`** — Adds `FLEET_MONITOR_PORT_SCAN_RANGE` (default `3000 3001 3002`) using the same `: "${VAR:=value}"` + `readonly` idiom established by XACA-0516 and XACA-0519. Documented with consumer list, override semantics, and cross-reference to `FLEET_MONITOR_PORT_DEFAULT`.
- **`libexec/commands/aiteamforge-start.sh`** — Sources `lib/constants.sh`; replaces two literal `for port in 3000 3001 3002` loops with `for port in $FLEET_MONITOR_PORT_SCAN_RANGE` (SC2086 suppressed at each loop — intentional word-splitting). Loop bodies and `break` statements preserved verbatim.
- **`libexec/commands/aiteamforge-status.sh`** — Sources `lib/constants.sh`; replaces one literal triplet loop. Same treatment.
- **`libexec/commands/aiteamforge-doctor.sh`** — Sources `lib/constants.sh`; replaces one literal triplet loop. Same treatment.
- **Sibling-drift sweep clean.** `grep -rn "3000 3001 3002" libexec/` returns only the canonical definition in `constants.sh` — zero consumer occurrences.
- **Behavior preserved.** Default scan order 3000 → 3001 → 3002 and early-`break` unchanged. Env-var override (`FLEET_MONITOR_PORT_SCAN_RANGE='3000 3001'` set before sourcing) is honored.
- **Test results.** `test-cli.sh` 18/18 pass. `test-doctor-fix.sh` 53/53 pass. Zero new shellcheck warnings.
- **Pattern lineage.** XACA-0516 (`KANBAN_BACKUP_INTERVAL_DEFAULT`) → XACA-0519 (`FLEET_MONITOR_PORT_DEFAULT`) → XACA-0524 (this scan range). Third and final outstanding sibling-drift literal in the tap command files.

### Fix: XACA-0516 — Consolidate `KANBAN_BACKUP_INTERVAL` default to a shared constant

- **`libexec/lib/constants.sh`** (NEW) — Single source of truth for shared shell constants. Uses `: "${VAR:=default}"` followed by `readonly` so the file is safe to source twice, env-var overrides set before sourcing still win, and the value cannot be mutated after the fact.
- **`libexec/installers/install-kanban.sh`** — Sources `lib/constants.sh`; the literal `KANBAN_BACKUP_INTERVAL=900` is replaced with `${KANBAN_BACKUP_INTERVAL:-$KANBAN_BACKUP_INTERVAL_DEFAULT}`. Side-effect improvement: the value now respects an env-var override (it was previously a hard-set), matching how upgrade.sh and migrate.sh already treat it.
- **`libexec/commands/aiteamforge-upgrade.sh`** — Sources `lib/constants.sh`; the local mirror constant `XACA_0510_KANBAN_BACKUP_INTERVAL_DEFAULT` and its three-line "change one, change the other" NOTE comment are removed. The render function consumes `${KANBAN_BACKUP_INTERVAL:-$KANBAN_BACKUP_INTERVAL_DEFAULT}` directly.
- **`libexec/commands/aiteamforge-migrate.sh`** — Sources `lib/constants.sh`; the local `XACA_0512_KANBAN_BACKUP_INTERVAL_DEFAULT` mirror is removed and the NOTE comment is trimmed to mention only `FLEET_MONITOR_PORT_DEFAULT` (the next sibling-drift consolidation candidate — captured as a follow-up).
- **Sibling-drift pattern eliminated.** Three production sites previously each defined `=900` with hand-written "if you change one, change the other" comments. All three now read from `lib/constants.sh`. The `k501-sibling-heuristic-drift-pattern` lesson (XACA-0501, XACA-0476) drove the explicit post-hoc sweep in subitem 005.
- **Behavior preserved.** Default still resolves to `900` seconds (15 minutes); env-var override (`KANBAN_BACKUP_INTERVAL=<n>`) still wins. Test fixtures intentionally retain literal `900` env injections — they assert the rendered plist value, so coupling them to the production constant would defeat the test.
- **Out of scope (follow-up).** `aiteamforge-migrate.sh` also carries `XACA_0512_FLEET_MONITOR_PORT_DEFAULT=3000` mirroring `install-fleet-monitor.sh:15`. Same sibling-drift pattern, scoped to its own ticket. Test fixture `tests/test-xaca-0512-migrate-launchagent-render.sh:83` retains a stale `XACA_0512_KANBAN_BACKUP_INTERVAL_DEFAULT` declaration discovered by subitem 005 — dead weight, doesn't affect tests, cleanup candidate for the same follow-up.
- **Test results.** Six test files exercising the migrated paths all pass (159/159): `test-xaca-0510-launchagent-render.sh` (15), `test-xaca-0512-migrate-launchagent-render.sh` (17), `test-installers.sh` (32), `test-migration.sh` (18), `test-lifecycle.sh` (22), `test-board-template.sh` (55). An explicit default-path test (5 cases — default-resolves, override-wins, empty-string-falls-through, double-source idempotent, readonly-blocked) passes — the existing fixtures only exercise the override path.
- **Origin.** XACA-0510-013 review subitem from PR #30 flagged the duplication between install-kanban.sh:16 and aiteamforge-upgrade.sh's local constant. XACA-0512 inherited the same pattern. This ticket consolidates all three sites.

### Fix: XACA-0512 — Rework `aiteamforge-migrate.sh::update_launchagents` to render from templates

- **`libexec/commands/aiteamforge-migrate.sh`** — Replaced the in-place `sed -i.bak` / `sed -i.bak2` path-rewrite loop in `update_launchagents()` with a render-from-template flow that mirrors `install-kanban.sh` (and the XACA-0510 fix in `upgrade.sh`). The old code never rendered from canonical templates — it patched whatever plist already existed at `~/Library/LaunchAgents/<agent>`, leaving `.bak`/`.bak2` files behind and silently failing to recover from any drift or hand-editing of the on-disk plist.
- **Three-agent, per-template-family dispatch.** The agent set spans two template directories with incompatible substitution maps, so a single `sed` expression can't serve all three (the XACA-0510 wrinkle that doesn't apply to `upgrade.sh`):
  - `com.aiteamforge.kanban-backup.plist` → `share/templates/kanban/backup-plist.template` via `_render_kanban_template()` — substitutes `{{USER_HOME}}`, `{{AITEAMFORGE_DIR}}`, `{{BACKUP_INTERVAL}}`, `{{PYTHON3_PATH}}`.
  - `com.aiteamforge.lcars-health.plist` → `share/templates/kanban/lcars-health-plist.template` via the same kanban renderer (harmless extras prevent sibling-drift bugs).
  - `com.aiteamforge.fleet-monitor.plist` → `share/templates/fleet-monitor/fleet-launchagent.template.plist` via `_render_fleet_template()` — substitutes `{{NODE_PATH}}`, `{{FLEET_SERVER_PATH}}`, `{{LOG_DIR}}`, `{{HOMEBREW_PREFIX}}`, `{{HOME_DIR}}`, `{{FLEET_PORT}}`, `{{AITEAMFORGE_DIR}}`.
- **Migrate-specific semantic:** `{{AITEAMFORGE_DIR}}` resolves to `${NEW_DATA_DIR}` (the migration's destination), not `${WORKING_DIR}` as in `upgrade.sh`. This is what makes the rendered plist correct after a migration — the rewritten plist now points to the migrated data location.
- **Defaults consolidated for sibling-drift consolidation (XACA-0516):** module-level `readonly XACA_0512_KANBAN_BACKUP_INTERVAL_DEFAULT=900` (mirrors `install-kanban.sh:16`) and `XACA_0512_FLEET_MONITOR_PORT_DEFAULT=3000` (mirrors `install-fleet-monitor.sh:15`). Honors `KANBAN_BACKUP_INTERVAL` / `FLEET_MONITOR_PORT` env overrides at render time.
- **Semantics preserved:** `FORCE=true` re-renders even when target is up to date; `DRY_RUN=true` writes nothing and prints `[DRY RUN] Would update`; `launchctl unload` runs before `mv`, `launchctl load` runs after (both tolerate failure via `2>/dev/null || true`); agents absent from `~/Library/LaunchAgents/` are skipped — migrate must not silently materialise agents the user opted out of at install time.
- **`LAUNCHAGENTS_DIR` seam** — function respects `LAUNCHAGENTS_DIR` env var (defaults to `$HOME/Library/LaunchAgents`) so tests can inject a sandbox path without touching the real user LaunchAgents dir (M3Pro tap-install ban). Same seam pattern as XACA-0510.
- **`_cleanup_migrate_tmpfiles()` + `RETURN` trap** — any `*.new` tempfile created during the render loop is cleaned up on early return or interrupt. No `*.new` leakage on no-op, DRY_RUN, or missing-template paths.
- **`tests/test-xaca-0512-migrate-launchagent-render.sh`** — 17 test cases covering: all three targets absent → all skipped; explicit `.bak`/`.bak2` regression assertion (the old in-place `sed -i.bak` behavior must be gone); kanban + fleet-monitor render with no `{{…}}` placeholders; rendered kanban plist contains resolved `NEW_DATA_DIR` (not `WORKING_DIR`); fleet-monitor renders all seven fleet-specific placeholders and resolves the `FLEET_PORT` default; selective opt-in (kanban present, fleet absent → fleet not materialised); second run no-op (mtime unchanged, no tempfile leak); `FORCE=true` re-renders; `DRY_RUN=true` preserves sentinel content with no tempfile leak on *both* the kanban renderer (3 cases) and the fleet-monitor renderer (1 case, added per PR #32 [Review] subitem XACA-0512-002); missing template warns without crashing; all-three-present rendered cleanly; DRY_RUN + no-change reports "All LaunchAgents up to date".
- **Audit-only on `aiteamforge-migrate-check.sh`** — that script's `analyze_launchagents()` (line 381) has the same `EXPECTED_AGENTS` list but is read-only (presence + `launchctl list` check, no render logic). No change required; documented for completeness.
- **Sibling-heuristic drift, third datapoint:** XACA-0476 (missing `share/` prefix) → XACA-0510 (no template render in `upgrade.sh`) → XACA-0512 (no template render in `migrate.sh`). All three sites in the launchagent-render surface are now consistent.

### Fix: XACA-0510 — Rework `update_launchagents` to render from templates

- **`libexec/commands/aiteamforge-upgrade.sh`** — Added `_render_launchagent_template()` private helper that applies the full `sed` substitution map (`USER_HOME`, `AITEAMFORGE_DIR`, `BACKUP_INTERVAL`, `PYTHON3_PATH`) to any plist template. All four substitutions are applied to every template — harmless extras prevent sibling-drift bugs (per the pattern catalogued in XACA-0501).
- **`update_launchagents()`** reworked from a plain `cp source target` loop to a render-from-template loop: iterate a `"plist-name:template-basename"` pairing, render the template to a `*.new` tempfile, diff the rendered output against the live target (not the raw template — templates always look different due to `{{VAR}}` placeholders), and reload via `launchctl unload → mv → launchctl load` only on change. Tempfiles are cleaned up on all no-op paths (no `*.new` leakage).
- **Source path change is load-bearing:** the old loop looked for pre-built plists at `${FRAMEWORK_DIR}/share/launchagents/<agent>` — a directory the tap does not ship. Templates live at `${FRAMEWORK_DIR}/share/templates/kanban/<basename>`. This is what caused the silent no-op introduced by the original code (XACA-0476 corrected the prefix but couldn't unblock the absent-source early-out).
- **Semantics preserved:** `FORCE=true` re-renders even when target is up to date; `DRY_RUN=true` writes nothing and prints "Would update"; `launchctl unload` runs before `mv`, `launchctl load` runs after (both tolerate failure via `2>/dev/null || true`); agents absent from `~/Library/LaunchAgents/` are skipped — upgrade does not silently install agents the user opted out of.
- **`LAUNCHAGENTS_DIR` seam** — Function respects `LAUNCHAGENTS_DIR` env var (defaults to `$HOME/Library/LaunchAgents`) so tests can inject a sandbox path without touching the real user LaunchAgents dir (M3Pro tap-install ban).
- **`tests/test-xaca-0510-launchagent-render.sh`** — 12 test cases covering: both targets absent → both skipped; fresh render → content written with no `{{…}}` placeholders; rendered content contains resolved `WORKING_DIR`; second run → no-op (mtime unchanged, no tempfile leak); `FORCE=true` → mtime changes; `DRY_RUN=true` → sentinel content preserved, "Would update" printed, no tempfile leak; missing template → warning without crash; both sentinels → both rendered clean.
- **Predecessor:** XACA-0476 corrected the `share/` path prefix; this ticket unblocks the actual render. Sibling site `aiteamforge-migrate.sh::update_launchagents` has a different defect class (in-place sed path rewrite, no template render) tracked separately as XACA-0512.
- **Three confirmed datapoints of sibling-heuristic drift** in this surface: XACA-0476 (missing prefix), XACA-0510 (no template render in upgrade), XACA-0512 (no template render in migrate).
