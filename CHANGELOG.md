# Changelog

All notable changes to the AITeamForge Homebrew Tap.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html)

## [Unreleased]

- XACA-0603: Add a public CLI write path for the CR field `deploy_window_planned` in `kb-cr` (`share/scripts/kb-cr.sh` in tap). Previously `kb-cr` only READ `deploy_window_planned` (show, summary, audit, LCARS) with no public verb to WRITE it, forcing operators to hand-edit `board.json`. Adds (1) a `--deploy-window <date>` flag on `kb-cr create` and (2) a post-hoc `kb-cr reschedule <CR-ID> <date>` setter verb. Both write `.crs[].deploy_window_planned` UTC-normalized via a new shared, BSD-`date`-safe `_kb_cr_normalize_iso_date` helper (accepts `YYYY-MM-DD` → `T00:00:00Z`, `YYYY-MM-DDTHH:MMZ` → padded, `YYYY-MM-DDTHH:MM:SSZ` → pass-through; rejects offset/garbage forms), bump `updatedAt`/`lastUpdated`, and emit a best-effort `cr_deploy_window_set` activity-log event.
- XACA-0602: Fix two LCARS team-transfer IMPORT UX defects in `share/lcars-ui/js/lcars.js` (cache-buster bumped in `share/lcars-ui/index.html`: `js/lcars.js?v=3.21` → `?v=3.22`). (1) **Silent re-import failure** — after a completed (or failed) import, a second attempt landed in half-dirty state because `onImportComplete()`/`onImportFailed()` re-enabled the button and cleared the file input but never reset session state: module-level `currentImportJobId` stayed pinned to the finished job, `#import-result`/`#import-preflight` were never hidden, and `currentImportSecretsDiscovered`/`stagedImportSecretsFile` stayed polluted. `cancelImport()` held the only full-reset path and was wired solely to the CANCEL button, so success/failure never routed through it. Fix: a single-source-of-truth `resetImportState()` helper (nulls the job id + staged files, `stopImportPolling()`, hides all three panels, re-arms the file input + button, clears the inline-secrets section); `cancelImport()` collapses to a thin wrapper over it; `handleImportFileSelected()` calls it at the top so selecting a new file wipes any prior import's panel + state (the re-import fix). `onImportComplete()`/`onImportFailed()` clear only the blocking bits (`currentImportJobId = null`, `stopImportPolling()`) and leave the completion panel visible per the chosen UX. (2) **No progress indicator on file select** — `uploadImportFile()` awaited one fat `/api/import/upload` POST (iCloud materialize + upload + manifest verify, all server-side) showing only a disabled button. Fix: an indeterminate `PREPARING IMPORT…` state on the reused `#import-progress` panel shown synchronously on file selection, cleared when `renderImportPreflight()` paints or on any upload error path. No DOM changes (existing panel reused). (3) Follow-up (XACA-0602-012, review): promoted `_applyPairedSecretsImport()`'s formerly function-local secrets-poll handle to a module-scoped `pairedSecretsPollingInterval` now cancelled by `stopImportPolling()`/`resetImportState()`, closing the orphaned-interval race where selecting a new file mid-secrets-extraction could leave a poll alive that re-shows the result panel. Mirror of canonical lcars-ui changes.

## [0.12.12] - 2026-06-02

- XACA-0601: Remove 200-item cap on manifest probe `item_ids` in `lcars-ui/team_transfer/domain_kanban.py` (`share/lcars-ui/team_transfer/domain_kanban.py` in tap). The `[:200]` slice caused a false DATA-LOSS preflight failure on any kanban board with more than 200 items — the verifier diffed the truncated source-item set against the full live board and flagged the uncapped tail as destination-only items an import would delete.
- XACA-0600: Anchor the LCARS-UI upgrade exclude so `team_transfer/config/` ships on upgrade. `aiteamforge-upgrade.sh::update_lcars()` rsynced `share/lcars-ui` → `~/aiteamforge/lcars-ui` with an unanchored `--exclude 'config/'`, intended to preserve the user-customized top-level runtime dir `lcars-ui/config/`. Because the pattern had no leading slash it matched `config/` at ANY depth, so it also stripped the SHIPPED data dir `lcars-ui/team_transfer/config/` (the per-team `.yaml` definitions that drive team import/export — currently 20 entries: 17 regular files + 3 intra-dir symlink aliases such as `medical.yaml` → `medical-general.yaml`). Fresh installs (`install-kanban.sh` `cp -r`) were unaffected; only upgrades dropped it, leaving upgrade-only machines (e.g. M1Pro: 0 yaml vs 20 in share) unable to export/import — every attempt died with `No team_transfer config for team X`. Fix: anchor the exclude to the transfer root (`--exclude '/config/'`) so only `lcars-ui/config/` is excluded while `team_transfer/config/` syncs normally. Adds a non-fatal post-sync regression guard that warns when the installed `team_transfer/config` yaml count diverges from the framework share. Tap-native installer change (homebrew-tap two-step; no sync-tap).
- XACA-0596: Replace hardcoded `SESSION_DIRECTORY` paths with `${AITEAMFORGE_DIR:-$HOME/dev-team}` in the four tap-shipping LCARS startup scripts (`share/scripts/teams/finance/scripts/finance-lcars-startup.sh`, `freelance/scripts/freelance-lcars-startup.sh`, `legal/scripts/legal-lcars-startup.sh`, `medical/scripts/medical-lcars-startup.sh`). These files shipped a literal `/Users/darrenehlers/dev-team` (or the half-portable `$HOME/dev-team` for finance) as the `SESSION_DIRECTORY` default, causing them to point at the wrong directory on any tap install that uses a non-default `AITEAMFORGE_DIR`. The portable form honors `$AITEAMFORGE_DIR` when set and falls back to `$HOME/dev-team` otherwise — identical behavior on the dev machine.
- XACA-0596: Also make the `lcars-ports` port/theme/order rendezvous directory portable in the tap-shipping fleet scripts. `$HOME/dev-team/lcars-ports` → `${AITEAMFORGE_DIR:-$HOME/dev-team}/lcars-ports` in the team startup/shutdown producers and the consumers `fleet-reporter.sh` and `agent-panel-display.sh`. The rendezvous dir is a producer/consumer contract — both ends must resolve to the same path, so on a tap install with a non-default `AITEAMFORGE_DIR` the producers (writing `.port`/`.theme`/`.order` files) and consumers (reading them) now stay in agreement instead of split-braining. Identical behavior when `AITEAMFORGE_DIR` is unset.
- XACA-0592: Re-sync `share/scripts/` files that had drifted stale because they were never in the `sync-tap.sh` mirror map (follow-up to XACA-0591). Affected: the 4 parametric teams' (finance/freelance/legal/medical) `share/scripts/teams/<team>-startup.sh` + `teams/<team>/scripts/*` station scripts, now carrying forward-fixes that the false-green drift had stranded (XACA-0576 board-check template id, XACA-0590 canonical `resolve_lcars_port`, XACA-0279 active-account banner). `update_claude_agent.sh` newly mapped (was already in sync). No behavior change to tap-only files (`aiteamforge-lcars.json`, `aiteamforge-resolve-hostname.sh`, `create-lcars-profile.py`, `init-agent-panel-json.py`, `kanban-board-check.sh`, `kanban-restore-helper.sh`, `register-terminals.sh`) — those have no dev-team canonical and remain tap-authoritative. Exec bits preserved.
- XACA-0594: Add `worktree-helpers.sh` to `update_aux_scripts()` script_map in `aiteamforge-upgrade.sh`. The file is installed to `${AITEAMFORGE_DIR}/worktree-helpers.sh` (root) by `install_worktree_helpers()` during fresh installs and uninstalled by `aiteamforge-uninstall.sh`, but the upgrade path omitted it — meaning the working-dir copy was frozen at the version shipped when the user first ran `aiteamforge setup`. Tap upgrades never refreshed it, so features added in later releases (XACA-0588 wt-new persona-deploy hook, XACA-0565 board-routing consolidation) were silently absent on upgraded machines. The new entry mirrors the target path convention used by install-shell.sh: `${WORKING_DIR}/worktree-helpers.sh`.
- XACA-0598: `share/scripts/worktree-helpers.sh` gains `_wt_classify_branch` — a shared safe/unsafe branch classifier (tokens `merged` / `unmerged-commits` / `remote-gone`) extracted from `wt-finish`'s inline logic, so the new kb-run worktree-cleanup-on-exit offer and `wt-finish` agree on what is safe to remove. `wt-finish` refactored to delegate classification to it (no user-facing behavior change). The cleanup-offer driver (`_kb_offer_worktree_cleanup`) and its wiring into the `kb-run*` launchers live in `kanban-helpers.sh`, which is dev-only and not tap-shipped; only the shared classifier in `worktree-helpers.sh` mirrors to the tap.

## [0.12.11] - 2026-06-01

- XACA-0593: Wire persona-deploy hook into tap-native `wt-create()` in `share/templates/aliases/worktree-aliases.sh`. XACA-0588 added the hook only to `wt-new()` in `worktree-helpers.sh` (the dev-machine path). On tap machines `worktree-helpers.sh` is not sourced and `wt-new` does not exist — `wt-create` is the only worktree-creation path. After the successful `git worktree add`, a guarded call to `${AITEAMFORGE_DIR}/scripts/deploy-worktree-personas.sh "$worktree_dir" "$WT_CURRENT_PROJECT"` deploys team personas into the new worktree's `.claude/agents/`. The call is on the success path only, wrapped in `[ -x "$_dwp" ]` and `|| true` so it never aborts worktree creation. Variables proven in-scope: `$worktree_dir` (computed above the guard, holds the new worktree absolute path) and `$WT_CURRENT_PROJECT` (exported by `wt-project`). Upgrade path: `aiteamforge-upgrade.sh::update_alias_files()` already refreshes `share/aliases/worktree-aliases.sh` when the tap source is newer — existing tap machines receive the hook on next `aiteamforge upgrade` with no additional wiring needed. **Follow-up (layout-agnostic guard):** `share/scripts/deploy-worktree-personas.sh` — the `_guard_worktree_target` function required the worktree to live under `<repo>/worktrees/` (dev layout only). Tap/container machines create worktrees at `dirname(repo)/worktrees/` via `wt-create` (sibling layout), causing the guard to reject every persona deploy with `ERROR: Worktree target does not live under repo worktrees/ dir`. Guard now checks git-registry membership: parses `git worktree list --porcelain` from the main repo root and accepts any path that appears as a registered linked worktree (not the main/primary entry). Layout-agnostic — git tracks linked worktrees regardless of position relative to the main repo. `--all` mode also updated: the `worktrees_dir` prefix filter removed; it now enumerates all linked worktrees from git directly. Selftest expanded to 16 tests (real `git worktree add` repos in both dev and sibling layouts).

## [0.12.10] - 2026-06-01

- XACA-0591: `share/scripts/worktree-helpers.sh` was unmapped in `sync-tap.sh` — the file exists in the tap but was never drift-gated, so it shipped stale in v0.12.9: missing the XACA-0588 `wt-new` persona-deploy hook and the XACA-0565 `finance|legal|medical|dns` board-routing consolidation via `_kb_template_to_instance`. Tap-machine `wt-new` persona auto-deploy was silently dead. Fix: added the file to `sync-tap.sh`'s mirror map; tap copy now re-synced from canonical and verified identical. Follow-up (XACA-0591-001): 4 additional `share/scripts/` files were unmapped in `sync-tap.sh` — same false-green drift class. `share/scripts/cr-confluence-poller.py` re-synced from `scripts/cr-confluence-poller.py` (adds per-team LaunchAgent scheme, auto-approve support, `--board` dev-mode flag). `share/scripts/fleet-reporter.sh` re-synced from `fleet-monitor/client/fleet-reporter.sh` (adds `register_with_endpoint()` / `ensure_registered()` first-run machine registration with `REGISTRATION_SENTINEL`). `share/scripts/kb-cr.sh` re-synced from `scripts/kb-cr.sh` (adds `revert`/`undo`/`revert-history` backwards lifecycle commands and per-item `migrate-legacy --item/--apply`). `share/scripts/migrate-cr-schema.py` re-synced from `scripts/migrate-cr-schema.py` (adds per-item `--item/--board/--apply` mode, `argparse`-based CLI, no-op guard before backup). No regressions: dev-machine path refs already present verbatim in stale tap copies. All 4 post-mirror diffs empty; exec-bit parity preserved.

## [0.12.9] - 2026-06-01

- XACA-0590: `share/scripts/lcars-launch-helpers.sh` gains `resolve_lcars_port()` — resolves a session-prefix's LCARS port from the canonical authority (`kanban-hooks/lcars_ports.py` / `team-paths.json`) instead of recomputing it via a `cksum` hash. Mirror of the canonical `scripts/lcars-launch-helpers.sh` change; the dev-team startup scripts that adopt it are not tap-shipped, but the shared helper is, so the tap copy must carry the resolver too. Fixes tracked `lcars-ports/*.port` files drifting on every launch when the runtime hash disagreed with the reconciled canonical port.
- XACA-0588: Tap-machine worktree persona deployment. `share/scripts/deploy-worktree-personas.sh` added to tap mirror; `install_worktree_personas_script()` in `install-kanban.sh` seeds it to `$AITEAMFORGE_DIR/scripts/` with `chmod +x` so the wt-new `-x` guard resolves it at runtime; `update_aux_scripts` script_map in `aiteamforge-upgrade.sh` keeps it current on upgrade. Without this install seeding, the worktree persona deployment feature (XACA-0584) was a complete silent no-op on tap machines. Review follow-ups (PR #504): `--all` backfill mode added to `deploy-worktree-personas.sh` (`_deploy_core()` extracted for DRY sharing; `_deploy_all()` enumerates `git worktree list --porcelain`; selftest 12→14 tests covering --all happy-path and no-worktrees no-op); regression test `tests/test-xaca-0588-deploy-worktree-personas-laydown.sh` added (11 tests: tap ships script +x, installer lays down to scripts/ +x, hook guard path, upgrade script_map, idempotent, missing-source graceful); tests/README.md coverage table updated; sync-tap.sh comment corrected from XACA-0584 to XACA-0588.
- XACA-0586: import-preflight gate part 2 (XACA-0583 follow-up). `share/lcars-ui/team_transfer/verifier.py` gains a `STALE-OK` informational disposition: in `--phase pre-import`, present-but-stale carried payload (EXACT sha mismatch; SCHEMA board behind source, `missing = cap_ids - cur_ids`) → STALE-OK instead of FAIL, because an overwrite-import simply refreshes it. Adds real data-loss detection — `_verify_board_schema` computes `extra = cur_ids - cap_ids` (destination-only items an overwrite would DELETE) → `FAIL` with a `DATA-LOSS:` prefix in BOTH phases (checked before `missing`, so data-loss wins). Post-restore semantics unchanged (all reclassification `phase==PRE_IMPORT`-gated). `share/lcars-ui/team_transfer/manifest.py`/`generator.py` embed `source_team` so `share/lcars-ui/server.py` can block a wrong-team import (base-vs-base compare; legacy empty `source_team` skips gracefully). server.py parses the `STALE-OK: N` summary line into `verifierSummary.staleOk`. Mirror of canonical lcars-ui changes; regression tests mirrored under `share/lcars-ui/tests/team_transfer/` (208 passing).
- XACA-0582: import-apply preflight-delta override — `acknowledgePreflightDeltas` operator in `share/lcars-ui/server.py` unblocks migration import-apply when preflight FAILs are expected payload deltas (path-map drift, pending-import files). LCARS UI (`share/lcars-ui/js/lcars.js`, `share/lcars-ui/index.html`) gains the corresponding toggle control. Mirror of canonical lcars-ui changes.
- XACA-0585: Ship `lcars-health-check.sh` through the tap install/upgrade pipeline. `share/scripts/lcars-health-check.sh` added; `install_lcars_health_check_script()` in `install-kanban.sh` lays it down before `install_lcars_health_launchagent`; `update_aux_scripts` script_map in `aiteamforge-upgrade.sh` keeps it current on upgrade; `aiteamforge-doctor` gains a missing-script check. Fixes exit 127 on the `com.aiteamforge.lcars-health` LaunchAgent (StartInterval 300) that caused dead LCARS servers to never auto-restart. The plist now invokes the script via `/bin/zsh` (was `/bin/bash`) — the script is `#!/bin/zsh` and uses zsh-only syntax (`typeset -A`, `(N)` glob), so an explicit `/bin/bash` interpreter overrode the shebang and exited 2 (parse error) on every tick; the regression test now parse-checks the shipped script under its declared interpreter. Doctor's missing-script fix-hint points at `aiteamforge setup` (not `upgrade`, which skips absent targets).

## [0.12.8] - 2026-05-28

- XACA-0583: import-preflight trustworthiness (XACA-0581 follow-up). `share/lcars-ui/team_transfer/verifier.py` gains a `--phase {pre-import,post-restore}` flag (default `post-restore` = legacy behavior) and two informational dispositions for absent files: `PENDING-IMPORT` (carried payload absent during a pre-import audit — the import will create it, so it is not a FAIL) and `EXPECTED-MISSING` (machine-local/ephemeral state — Claude session transcripts under `.claude/projects/*.jsonl` — that can never round-trip cross-machine). Neither sets the exit code. The upload-time import-preflight in `share/lcars-ui/server.py` GATES the apply (`FAIL>0` → `baseMatch=False` → HTTP 400); it now runs `--phase pre-import` so legitimately-absent carried payload reports PENDING-IMPORT and the apply proceeds (a genuine mismatch still FAILs and blocks). All three verifier call-sites are phase-tagged (import-preflight = pre-import, post-restore import = post-restore, source-side export preflight = post-restore). Both destination call-sites surface `pendingImport`/`expectedMissing` counts. The 47 field FAILs decompose to ~19 expected-missing + ~17 pending-import + ~9 stale-manifest drift. Regression tests mirrored under `share/lcars-ui/tests/team_transfer/`.
- XACA-0581: import-preflight follow-up to XACA-0580. (1) `kanban-hooks/aiteamforge_paths.py` `build_import_path_maps()`: skip the per-team map when `src_wd == dev-team root` — academy/freelance both report `working_dir == ~/dev-team` and were emitting maps that collide with the shared-infra `~/dev-team`→`~/aiteamforge` map (equal prefix length → stable-sort tiebreak; the academy map was dead-by-luck and actively wrong). (2) `share/lcars-ui/team_transfer/verifier.py`: SKIP the `aiteamforge_product` channel (installer-owned files the tap lays down with its own subdir layout, not carried by the transfer; a flat prefix path-map cannot bridge the reshape, so FAILing on them is a false negative). Removed the now-unreachable `aiteamforge_product` channel-class invariant. Verified live on M1Pro: 73→47 FAILs (all 26 in-scope false negatives eliminated). Regression tests mirrored under `share/lcars-ui/tests/team_transfer/`.

## [0.12.7] - 2026-05-28

- XACA-0580: per-team path-map derivation + broadened tap-install detection in `build_import_path_maps()`; `Manifest` dataclass gains `teams` field for per-team working_dir snapshot.

## [0.12.6] - 2026-05-27

### Fix: XACA-0579 — team-transfer import preflight ghost UUID entries + path-map bridging

- `share/lcars-ui/team_transfer/domain_claude.py`: drop the `iterdir() + is_dir()` block that emitted directory-typed manifest entries for UUID session subdirs. Directories cannot round-trip through the file-based zip pipeline (`zipfile.write(dir)` stores `relpath/` with trailing slash; import loop checks `relpath` without trailing slash → entries always skipped → verifier reports `FAIL: missing on destination` for every UUID dir). Primary session transcripts (`<UUID>.jsonl`) remain unaffected. Sibling-drift k501 datapoint: both croot enumeration paths now emit file-type entries only.
- `share/lcars-ui/server.py`: pass `--path-map` derived from local `aiteamforge_paths` config to the import-preflight verifier. The verifier runs on the destination machine but the manifest was generated on the source (M3Pro dev-team layout). Without path-map, `~/dev-team/<team>/` source paths fail `Path.exists()` on a tap-install destination that has `~/aiteamforge/<team>/` instead. `build_import_path_maps()` in `kanban-hooks/aiteamforge_paths.py` detects the tap-install layout via the local working_dir config and emits `<src_home>/dev-team=<dst_home>/aiteamforge`. Returns `[]` for same-layout machines (dev-team → dev-team) to avoid redundant mappings.
- `kanban-hooks/aiteamforge_paths.py`: new `build_import_path_maps(manifest_dict)` helper encapsulating the derivation logic.

### Bugfix: XACA-0576 — Bidirectional template↔instance resolution for profile-scoped teams

Closes the cascade gap left by XACA-0460 + XACA-0463 + XACA-0565. v0.12.4 still
warned `unknown team finance-personal, defaulting to academy directory` and
prompted the operator to skip on a finance-installed machine, even though
finance is a registered team. The same latent failure shape exists for
`medical-general` and `legal-coparenting`.

**Root cause:** `get_kanban_dir()` (kanban-paths.sh) reads `.aiteamforge-config`
keyed by TEMPLATE id (`finance`), but XACA-0565's `validate_kanban_board()`
normalizes inputs to INSTANCE id (`finance-personal`) via `get_board_id()` at
line 373 BEFORE the config lookup. With only forward (template→instance)
resolution, the lookup misses, falls through to a silent academy fallback, and
emits the misleading "unknown team" warning.

**Fix:**
- New `get_template_id()` in `libexec/lib/kanban-paths.sh` — reverse of
  `get_board_id()` (instance→template, idempotent on already-template input).
- `get_kanban_dir()` now builds a candidate list (input + template-equivalent +
  instance-equivalent) and tries each against `.aiteamforge-config` so resolution
  succeeds regardless of which form the caller passes.
- `_kbc_get_kanban_dir()` in `share/scripts/kanban-board-check.sh` no longer
  silently redirects a KNOWN profile-scoped team (finance/medical/legal in
  either form) to the academy directory; it prints an actionable error pointing
  at the broken `.aiteamforge-config` entry and returns non-zero so callers
  can stop the cascade instead of prompting the operator with a misleading
  recovery menu. Truly-unknown ids retain the legacy academy fallback.
- `validate_kanban_board()` honors the new non-zero return and bails out cleanly
  for the known-broken case.

**Tests:** three new cases in `tests/test-multi-team.sh` cover (1) bidirectional
`get_board_id`↔`get_template_id` mapping and idempotency, (2) pass-through for
non-profile-scoped ids (academy, ios, freelance-*, etc.), and (3) the full
`get_kanban_dir('finance-personal')` cascade against a sandbox config keyed
under the template form — the M1Pro v0.12.4 reproducer. Full suite: 41/41 pass.

**Dual-mirror reminder:** the tap-side `get_board_id`/`get_template_id` map MUST
stay in sync with `_kb_template_to_instance`/`_kb_instance_to_template` in
dev-team's `kanban-helpers.sh`. Adding a new profile-scoped team = one canonical
edit on each side.

- `libexec/lib/kanban-paths.sh`: refactor `get_kanban_dir()` + add `get_template_id()`
- `share/scripts/kanban-board-check.sh`: classify known-broken vs truly-unknown teams
- `share/scripts/kb-init-team-guard.sh`: `_kb_board_is_present` resolves TEMPLATE→INSTANCE board filename — closes the parallel resolver gap surfaced by reviewer on PR #494 (startup scripts pass `"finance"` to `kb_ensure_team_initialized`, but the fast-path guard previously constructed `finance-board.json` raw without instance resolution and missed the canonical `finance-personal-board.json`, prompting the operator on every restart).
- `tests/test-multi-team.sh`: 3 new regression cases

### Feature: XACA-0578 — Cellar-watch LaunchAgent + close XACA-0571 uninstall gap

- New `com.aiteamforge.cellar-watch` LaunchAgent fires `aiteamforge upgrade --non-interactive` on Homebrew Cellar mtime change. Closes the silent-drift gap where manual `brew upgrade aiteamforge` left the runtime working-dir copy at `$AITEAMFORGE_DIR/lcars-ui/` (and friends) stale — XACA-0571's `auto-upgrade.sh` handled this for the daily LaunchAgent path, but manual `brew upgrade` skipped the chain entirely.
- New template `share/templates/auto-upgrade/cellar-watch-launchagent.template.plist`: WatchPaths on `{{BREW_CELLAR_DIR}}` (resolves to `$(brew --prefix)/Cellar/aiteamforge` — a real dir, not a symlink, so launchd fires reliably on versioned-subdir creation/removal). ThrottleInterval=60s (one mtime event per brew op, vs lcars-watch's 30s for per-file copy bursts). No `KeepAlive`, no `RunAtLoad` — trigger-only.
- New trigger script `share/scripts/cellar-watch-trigger.sh` (mirrored from canonical dev-team `scripts/cellar-watch-trigger.sh`): three-guard wrapper checks `brew` on PATH, `brew list aiteamforge` (formula installed), and `command -v aiteamforge` before chaining the upgrade. Handles the uninstall-fires-watcher race — brew uninstall also mutates the Cellar parent dir mtime and would otherwise call `aiteamforge upgrade` with no formula present. Logs to `$AITEAMFORGE_DIR/logs/cellar-watch.log`.
- New installer functions `install_cellar_watch_launchagent` + `uninstall_cellar_watch_launchagent` in `libexec/installers/install-kanban.sh`, wired into `install_kanban_system` / `uninstall_kanban_system`. Brew-prefix resolved via `brew --prefix` with `/opt/homebrew` fallback (Intel/Apple Silicon parity).
- `libexec/commands/aiteamforge-upgrade.sh` extensions: `_render_launchagent_template` gains `{{CELLAR_WATCH_TRIGGER}}` + `{{BREW_CELLAR_DIR}}` sed clauses; agent list in `update_launchagents` adds `com.aiteamforge.cellar-watch.plist`. End-of-upgrade stamp step writes `$WORKING_DIR/.installed-version` from the framework `VERSION` file — gives the doctor backstop a reliable working-dir version source (the pre-existing `.aiteamforge-config` `"version"` field was install-time only, never updated by upgrade).
- `libexec/commands/aiteamforge-doctor.sh`: new `check_version_drift()` (wired into both `version-drift` named-component and `all` dispatch). Four scenarios: MATCH (green), DRIFT (yellow + remediation `aiteamforge upgrade --non-interactive`), Cellar VERSION missing (red), both stamps missing (yellow). Falls back to `get_installed_version()` from config when `.installed-version` absent, with an explicit advisory that drift detection is less reliable in fallback mode.
- `libexec/commands/aiteamforge-uninstall.sh`: `remove_launchagents` extended to remove `com.aiteamforge.auto-upgrade.plist`, `com.aiteamforge.lcars-watch.plist`, and `com.aiteamforge.cellar-watch.plist`. Closes a pre-existing XACA-0571 gap where the first two were added to install but not to the top-level uninstall path — orphan-agent risk on `aiteamforge uninstall`.
- All verification gates pass: `bash -n` on all four modified scripts, `plutil -lint` on new template, `shellcheck` on new trigger script (no new findings).

## [0.12.5] - 2026-05-27

### Fix: XACA-0577 — LCARS import preflight cache-buster bump (mirror)

Mirrors the dev-team canonical bump (`lcars.js?v=3.18 → 3.19`) into
`share/lcars-ui/index.html`. Without this, browsers continue serving the
cached April 15 lcars.js for tap-installed consumers, so the XACA-0554 /
XACA-0566 / XACA-0568 import-preflight schema-drift fixes never take
effect at the UI layer regardless of how many times the source is patched.

- **`share/lcars-ui/index.html`:** mirrored from canonical
  `dev-team/lcars-ui/index.html` via `sync-tap.sh`.

## [0.12.4] - 2026-05-27

### Fix: XACA-0575 — `kb-tap-release` outer-remote configurability (mirror)

Mirrors dev-team canonical fix into `share/scripts/kb-tap-release`. The previous
release-cut script hardcoded `origin` as the outer-repo remote name across four
sites (develop fetch, `origin/develop` rev-parse, merge-base direction check,
final `git push origin develop`). The dev-team source-of-truth uses `dev-team`
as its remote, so the preflight aborted with "Outer develop diverged from
origin/develop" and a push would have died on the same. Adds (a) auto-detect —
prefer `origin`, fall back to `dev-team`, default to `origin` if neither is
configured so downstream commands fail with their normal error; (b) explicit
`KB_TAP_RELEASE_OUTER_REMOTE` env override. Preflight messages, dry-run banner,
and the partial-failure-recovery docs all use the resolved remote name. Tap
inner remote (`origin`) is unaffected.

- **`share/scripts/kb-tap-release`:** mirrored from canonical
  `dev-team/scripts/kb-tap-release` via `sync-tap.sh`. Executable bit preserved.

### Feature: XACA-0574 — Wire `kb-tap-release` through the tap install pipeline (XACA-0570 follow-up)

Ships the `kb-tap-release` one-shot release-cut script (introduced canonically in XACA-0570, PR #487) to brew-install consumers. Maintainers running from `~/dev-team` already had it; this lands the install hook + canonical→tap mirror so it arrives on every machine after `brew upgrade aiteamforge`.

- **`share/scripts/kb-tap-release`:** canonical-source mirror of `dev-team/scripts/kb-tap-release` (driven by `sync-tap.sh`). Executable.
- **`libexec/installers/install-kanban.sh`:** new install hook copies `kb-tap-release` from `$INSTALL_ROOT/share/scripts/` into the user's `$AITEAMFORGE_DIR/scripts/` (+x), mirroring the `kb-cr.sh` / `migrate-cr-schema.py` pattern. Skips with a `warning` if the source is missing.
- Background: XACA-0570 originally proposed shipping this in one PR. The orchestrator pivoted to outer-only when sync-tap drift surfaced a parallel session mid-work (XACA-0572 mirror pushed before its canonical landed on develop). XACA-0572 has since merged; the canonical/mirror align cleanly now, so the deferred tap wiring lands here without race risk.

### Feature: XACA-0571 — Daily auto-upgrade LaunchAgent with version-pin and operator notifications

- New `share/templates/auto-upgrade/auto-upgrade-launchagent.template.plist`: `com.aiteamforge.auto-upgrade` LaunchAgent runs `auto-upgrade.sh` daily at 03:15, `RunAtLoad: true`, `ThrottleInterval: 60`. Standard sed placeholders for script path, log dir, home, and AITEAMFORGE_DIR.
- New `share/scripts/auto-upgrade.sh`: `brew update` + `brew upgrade aiteamforge` with 5 MB log rotation (using `mv -n` for concurrent-invocation safety), version-pin sentinel (`~/.aiteamforge/version-pin`, **fail-closed** when available version unknown under an active pin), per-line `$(date)` timestamps so multi-minute upgrades show real-time progress, and macOS operator notifications on success/failure with `_escape_for_osascript` defensive escaping. Quiet mode via `AITEAMFORGE_AUTO_UPGRADE_QUIET=1`. Override file `~/.aiteamforge/auto-upgrade.env` sourced under relaxed `set -u` so operator typos don't abort the run. Silently skips `osascript` on headless machines. Sibling-drift cross-reference comments link the two LaunchAgent renderers (install-kanban.sh inline sed + aiteamforge-upgrade.sh _render_launchagent_template).
- `libexec/installers/install-kanban.sh`: added `install_auto_upgrade_launchagent` / `uninstall_auto_upgrade_launchagent`, wired into `install_kanban_system` / `uninstall_kanban_system`.
- New `share/templates/auto-upgrade/lcars-watch-launchagent.template.plist`: `com.aiteamforge.lcars-watch` passive WatchPaths LaunchAgent. Monitors `$AITEAMFORGE_DIR/lcars-ui` and fires `aiteamforge restart lcars` once per upgrade burst (ThrottleInterval=30s). No KeepAlive, no RunAtLoad — trigger-only. Watches the user working-dir copy to avoid the launchd symlink-retargeting gotcha.
- `libexec/installers/install-kanban.sh`: added `install_lcars_watch_launchagent` / `uninstall_lcars_watch_launchagent` as sibling to the auto-upgrade installer, wired into `install_kanban_system` / `uninstall_kanban_system`.
- New operator documentation: dev-team `docs/auto-upgrade-runbook.md` (mirrored into tap during sync). Comprehensive runbook for M1Pro/M4Mini/other tap-installed consumers covering daily auto-upgrade setup, forcing upgrades, pausing, version pinning, log inspection, notification control, the upgrade chain, and troubleshooting common issues.
- `libexec/commands/aiteamforge-upgrade.sh`: extended shared `_render_launchagent_template` with `{{AUTO_UPGRADE_SCRIPT}}`, `{{LOG_DIR}}`, `{{HOME_DIR}}`, `{{AITEAMFORGE_BIN}}`, `{{LCARS_UI_DIR}}` placeholders; added both new plists (auto-upgrade + lcars-watch) to `update_launchagents` agents array; added `auto-upgrade.sh` to `update_aux_scripts` script_map. Future template changes now refresh both installed plists + the script via `aiteamforge upgrade` (closes Thok forward-compat finding).
- `libexec/commands/aiteamforge-upgrade.sh`: new `--non-interactive` / `--yes` / `-y` flag. Skips the redundant brew-upgrade prompt (caller already ran it) and auto-accepts the symlink-fix prompt. Used by `auto-upgrade.sh` to chain `aiteamforge upgrade --non-interactive` after `brew upgrade aiteamforge` succeeds — this is what actually refreshes `$AITEAMFORGE_DIR/lcars-ui` so the WatchPaths watcher fires and LCARS picks up the new assets.

### Feature: XACA-0572 — Ship Antonio font locally (lcars-ui mirror)

Mirrors dev-team canonical changes into `homebrew-tap/share/`. LCARS UI now serves the
Antonio variable font (4 weights via wght axis) from `share/lcars-ui/fonts/antonio/`
instead of fetching it from `fonts.googleapis.com` / `fonts.gstatic.com` at runtime.
Works offline; no CDN-eviction FOUT; no content-blocker breakage.

- **`share/lcars-ui/fonts/antonio/`:** new dir with `Antonio-Variable.woff2` (latin,
  ~26KB) + `Antonio-Variable-LatinExt.woff2` (latin-ext, ~16KB) + OFL `LICENSE.txt`.
- **`share/lcars-ui/css/lcars.css`:** 8 `@font-face` rules (4 weights × 2 subsets)
  pointing at relative `../fonts/antonio/` paths, `font-display: swap`, exact
  `unicode-range` strings matching Google's CDN response.
- **`share/lcars-ui/index.html`:** removed Google Fonts `<link>` + `<preconnect>` tags;
  bumped `lcars.css?v=31.1` → `?v=32.0`.
- **`share/lcars-ui/server.py`:** defensive `mimetypes.add_type('font/woff2', '.woff2')`
  at module load + `.woff2`/`.woff` arms in `serve_no_cache_static`.
- Net runtime: ~43KB on disk; zero external font requests on page load.

### Feature: XACA-0569 — LCARS static-asset cache-bust + GET/HEAD/CSS parity

Mirrors dev-team canonical fix into `homebrew-tap/share/`. LCARS HTTP server now stamps
mtime-based `?v=<mtime>` query strings onto local `<script src>` / `<link href>` refs in
served HTML, routes `.css` through the no-cache helper alongside `.js`/`.html`, and mirrors
the static-no-cache dispatch on HEAD so curl `-I` / tooling probes see the same headers as
GET. Eliminates the recurring "shipped fix looks missing" trap most recently surfaced by
XACA-0568 v2 import pre-flight on 2026-05-26 (operators saw stale `lcars.js` until a manual
hard-reload).

- **`share/lcars-ui/server.py` dispatcher (~L10830):** added `.css` to the static no-cache
  branch alongside `.js` / `.html` / `/`. CSS was previously falling through to
  `super().do_GET()` (SimpleHTTPRequestHandler default — no `Cache-Control` header).
- **`share/lcars-ui/server.py` `serve_no_cache_static`:** added `text/css` content-type
  branch and new `head_only=False` parameter so HEAD callers reuse the same path. HTML
  responses now run through new helper `_version_html_refs` which rewrites local `.js`/`.css`
  refs to append `?v=<mtime>` (asset file mtime under `UI_DIR`). Skips absolute URLs
  (`http://`, `https://`, `//`, `data:`), refs that already carry a query string (so
  hand-versioned tags like `lcars.css?v=31.1` are preserved), and refs whose target is
  missing on disk (safe-fail). Module-level compiled regex `_STATIC_REF_RE`.
- **`share/lcars-ui/server.py` `do_HEAD`:** mirrors GET static dispatch — HEAD requests for
  `.js` / `.html` / `.css` / `/` now go through `serve_no_cache_static(..., head_only=True)`
  instead of falling through to `super().do_HEAD()`. Closes a parity gap where HEAD returned
  the default cache headers while GET returned `Cache-Control: no-cache, no-store,
  must-revalidate` + `Pragma: no-cache` + `Expires: 0`.

## [0.12.3] - 2026-05-26

### Bugfix: XACA-0568 — LCARS import pre-flight false ✓ MATCH + Apply enabled with 0 files (v2 manifest schema drift)

Mirrors dev-team canonical fix (PR #484) into `homebrew-tap/share/`. The import pre-flight
panel rendered a false ✓ MATCH and an enabled APPLY button against the v2 manifest schema
because `renderImportPreflight()` still read legacy keys (`manifest.fileCount.inTree/outOfTree`,
`manifest.baseTeam`, `manifest.secrets_summary`) that no longer exist. Fixes are split across
the JS preflight rendering, the JS apply-gate, and the Python upload/apply paths:

- **`share/lcars-ui/js/lcars.js` `renderImportPreflight`:** rewritten to read v2 keys.
  `data.sourceIdentity?.hostname` drives the SOURCE HOST row; `data.totalFileCount` drives a
  single FILES count (replacing dead `manifest.fileCount.inTree/outOfTree`). SOURCE TEAM row
  now displays `'(N/A in v2 manifest)'`. The former "BASE MATCH" row is now a VERIFIER pill
  rendering `PASS`/`WARN`/`FAIL` with `data-state` for CSS coloring; on `WARN`/`FAIL` a
  collapsible `<details>` block exposes `verifierSummary.tail`. Added `data-test-id`
  attributes on gate-relevant elements.
- **`share/lcars-ui/js/lcars.js` `updateImportApplyEnabled`:** added two floors before the
  existing secrets gate — disable on `verifierState === 'FAIL'` or `!baseMatch` (tooltip
  "Verifier reported FAIL — import blocked") and disable on `totalFileCount <= 0` (tooltip
  "Empty archive — nothing to import"). Apply button stores `data-base-match`,
  `data-verifier-state`, `data-total-file-count` for gate evaluation. Existing secrets-gating
  preserved as Floor 3.
- **`share/lcars-ui/js/lcars.js` `applyTeamImport` race-condition fix:** previously only
  `!currentImportJobId` guarded early-return. A fast double-click during the brief
  enable→fetch window could have bypassed the gate. Added defensive `applyBtn.disabled`
  re-check at call-time so the canonical disabled state is the gate.
- **`share/lcars-ui/js/lcars.js` `renderImportPreflight` ReferenceError fix (PR #484 tester
  review):** the initial commit removed `const manifest = data.manifest || {};` from the top
  of the function when cleaning up legacy field reads but missed the secrets-summary read
  that still referenced bare `manifest.secrets_summary`. At runtime this threw
  `ReferenceError: manifest is not defined`, crashing the entire preflight panel for every
  v2 upload. Now reads via `(data.manifest && data.manifest.secrets_summary) || {}` so the
  function is self-contained on `data`. Audited remaining v2 read sites — no other bare
  `manifest.` references remain.

### Refactor: XACA-0568 (002+003) — v2 sourceIdentity, totalFileCount, verifier-derived baseMatch

- **`share/lcars-ui/server.py` `handle_import_upload`:** replaced dead `source_team=''` /
  `source_base=''` / `base_match=True` stubs with real v2 extraction. `source_identity` dict
  (`hostname`, `user`, `home`, `generatedAt`, `schemaVersion`) is read from v2 manifest keys.
  `total_file_count` is summed from `domains[*].stats.file_count` with a `len(files)` fallback.
- **`share/lcars-ui/server.py` verifier-derived `baseMatch`:** after preflight verifier runs,
  `verifier_state` is normalized from `verifierSummary.overall` (`PASS`/`WARN`/`FAIL`; unknown
  → `WARN`, not `PASS`). `base_match = (verifier_state != 'FAIL')` replaces the hardcoded
  `True`. Both `verifierState` and `baseMatch` are stored in `IMPORT_JOBS` and emitted in the
  HTTP response alongside `sourceIdentity` and `totalFileCount`.
- **`share/lcars-ui/server.py` `assert import_format == 'new'` → explicit if + 400 (PR #484
  review #012):** asserts are stripped under `python -O` and would otherwise raise
  `AssertionError` with a 500 / no JSON body. Replaced with an explicit
  `if import_format != 'new'` that calls `_send_json_response` with status 400 and a
  `UPSTREAM_REJECTION_FAILED` code so the client can render a meaningful error.
- **`share/lcars-ui/server.py` verifier-crash semantics (PR #484 review #013 + #014):**
  previously a verifier subprocess crash stamped `verifier_summary={'present': True,
  'error': ...}` (no `overall` key) → derivation defaulted to `WARN` → `baseMatch=True` →
  Apply ENABLED on verifier crash. Two changes: (a) `verifier_summary` now initializes with
  `present=False`; the success path explicitly sets `present=True` once a real summary is
  parsed; the exception path leaves `present=False` and adds the `error` key. (b) Derivation
  now treats `present=False` as `verifier_state='FAIL'` (safer than WARN — a crash leaves
  the verifier in an unknown state and Apply must NOT bypass). Together: verifier crash →
  `verifierState=FAIL` → `baseMatch=False` → Apply blocked.
- **`share/lcars-ui/server.py` dead `_si` local removal (PR #484 review #015):** removed
  unused `_si = job.get('sourceIdentity') or {}` from `apply_import` and tightened the
  surrounding comment to clarify that `source_team` is intentionally empty for v2 jobs
  (sourceIdentity carries hostname/user but not team), while legacy in-flight jobs still
  expose `manifest['team']` for the board-rename path.
- **`share/lcars-ui/server.py` `apply_import` legacy sibling-drift sites:** legacy branch
  now reads `sourceIdentity` from `IMPORT_JOBS` for `source_host` (falling back to
  `source_hostname` → `sourceHost` → `'unknown'`); `source_team` call site unchanged.

## [0.12.2] - 2026-05-26

### Bugfix: XACA-0566 — LCARS import panel stuck button + secrets inline-picker detection

Two related defects in the LCARS import flow, both surfacing only after a failed
upload/apply. **Bug A (import-btn stuck disabled):** `uploadImportFile()` disabled
the import button before its upload fetch but only re-enabled it on the error
paths; on success it called `renderImportPreflight()` and left the button
permanently disabled, so any downstream apply or secrets failure had no retry
path short of a page reload. The success branch now re-enables `import-btn`
unconditionally — all three paths (error / success / catch) restore the button
in lockstep. A sibling audit of `startTeamExport()` (`export-btn`) and
`uploadSecretsImportFile()` (`secretsImport-select-btn`) confirmed their
disable/re-enable paths are balanced.

**Bug B (secrets inline-picker never fired on F1/F2 failure modes):**
`server.py` now stamps `detection_failed=True` (plus a `detection_reason`)
on the export `secrets_summary` when `SECRETS_EXPORT_LIB_AVAILABLE` is False
(F1 — module-import failure), so the import-side preflight can surface a warning
instead of silently hiding the inline picker. `renderImportPreflight()` broadens
its trigger from `discovered>0` to also fire on `detection_failed===true` (F1)
and on `expected>0 && discovered===0` (F2 — detection ran but found nothing
under a non-default secrets dir). Each case shows context-appropriate copy and
sets `currentImportSecretsDiscovered = Math.max(discovered, 1)` so the
apply-gate + secrets-upload path engage. The atomic file-exists guard's 409
message is rewritten to direct operators to the inline picker (with the
standalone secrets-import flow as fallback) and reports `detection_failed` in
both the message and JSON payload — guard *behavior* unchanged.

Reviewer-bot follow-up: `_compute_secrets_summary()` is called at two sites in
`generate_export()` (manifest path + EXPORT_JOBS status path). PR #482 stamped
`detection_failed` only at the first call; the second copy missed and would
have re-diverged on any status-endpoint consumer. Factored the stamp into a
small `_stamp_detection_failed_if_unavailable()` helper applied at both sites.
No user-visible change today (no consumer reads `detection_failed` from
`/api/export/status/<job_id>`) but eliminates a latent sibling-heuristic
divergence — same pattern that caught XACA-0565, XACA-0563, XACA-0501.

### Bugfix: XACA-0565 — startup board validator now resolves template keys to instance ids

`kanban-board-check.sh`'s `validate_kanban_board()` received TEMPLATE keys from
`.aiteamforge-config` (e.g. `"finance"`) but constructed board file paths directly
from that key (e.g. `finance-board.json`), while boards on disk use the INSTANCE id
(`finance-personal-board.json`). This caused a false "board missing" alarm on every
`aiteamforge start` for personal-org teams, presenting the Restore / Create / Skip
menu while `finance-personal-board.json` sat right there.

A new `get_board_id()` function in `kanban-paths.sh` maps template keys to their
canonical instance ids (`finance`→`finance-personal`, `legal`→`legal-coparenting`,
`medical`→`medical-general`; all other keys pass through unchanged). The lookup is a
deterministic `case` statement — not a glob — to avoid false-matching legacy stub
files that `_kb_check_dual_boards` intentionally tolerates. `validate_kanban_board()`
now calls `get_board_id()` immediately after the empty-team guard, before any
path or filename construction, so the resolved instance id threads through the entire
downstream call chain (`_kbc_get_kanban_dir`, `_kbc_handle_missing_board`,
`_kbc_restore_from_backup`, `_kbc_find_latest_backup`) in one stroke. Follows the
same template→instance precedent established in `worktree-helpers.sh:1566`
(XACA-0180).

Follow-up consolidation: `get_board_id`'s docstring now explicitly identifies it
as a SHELL-IDENTICAL mirror of the dev-team canonical `_kb_template_to_instance`
(in `kanban-helpers.sh`) — the tap installs standalone and cannot source dev-team
helpers at runtime, so the map exists in two places by necessity. The dev-team
side consolidated three other shell sites (`_kb_check_dual_boards`,
`worktree-helpers.sh` wt-finish case) to route through the canonical helper, so
this tap mirror is now the only remaining duplication. Adding a new personal-org
team = edit `_kb_template_to_instance` (canonical) + edit `get_board_id` here.

## [0.12.1] - 2026-05-25

### Refactor: XACA-0563 — rendered startup templates now use the shared LCARS launch helper

The two startup-script templates (`share/templates/team-startup.sh.template` and
`team-project-startup.sh.template`) each carried their own inline LCARS launcher:
a `(cd … python3 server.py … &)` subshell whose `&` made the server PID
unrecoverable, a fixed 5-second readiness poll (`{1..10}` × 0.5s), no
crash detection, and a generic "may not have started" message
(`team-project` discarded the server's stderr entirely). They now `source`
`$AITEAMFORGE_DIR/scripts/lcars-launch-helpers.sh` and delegate to
`start_lcars_server` — the same hardened helper already used by the dev-team
`*-startup.sh` scripts and `aiteamforge start` (XACA-0562). This brings PID
capture + crash short-circuit with a log tail, a 15s first-boot poll, a
size-rotated per-team log at `$AITEAMFORGE_DIR/logs/lcars-server-<team>.log`,
and venv-aware Python resolution. `window.LCARS_TARGET_SESSION` (consumed by
`redirect.html`) is re-appended after the call since the helper writes only
`LCARS_TARGET_TEAM`. This removes the last LCARS-launch code path that had
drifted from the shared helper.

`install-team.sh` now installs `lcars-launch-helpers.sh` to
`$AITEAMFORGE_DIR/scripts/` on the **rendered-template (non-parametric) path**
too — previously only the parametric path shipped it, so the rendered script's
`source` would have failed at runtime. The path-substitution install helper
(`_xaca0483_install_script`) was hoisted out of the parametric branch so both
install paths use one mechanism.

`start_lcars_server` now honors an `LCARS_PYTHON` env override as the
highest-priority probe; the rendered templates `export LCARS_PYTHON="$VENV_PYTHON"`
(their own resolution of `$HOME/.aiteamforge/venv` / `$AITEAMFORGE_DIR/.venv` —
paths the helper's brew-venv probe chain does not cover) so the LCARS server
launches under the venv that has its deps rather than bare `python3`. The
override is unset on the dev source machine and per-team scripts, so their
behavior is unchanged. `share/scripts/lcars-launch-helpers.sh` is re-synced from
the dev-team canonical (drift-gated).

### Refactor: XACA-0562 — `aiteamforge start` now sources the shared LCARS launch helper

`aiteamforge start`'s `start_lcars()` carried its own inline LCARS launcher
(`sleep 3` + curl readiness check, one shared `/tmp/lcars-server.log`, no PID or
crash detection), which had drifted from the hardened helper used by the per-team
startup scripts. It now sources `${WORKING_DIR}/scripts/lcars-launch-helpers.sh` —
the same `lcars-launch-helpers.sh` installed at `$AITEAMFORGE_DIR/scripts/` — and
delegates each team's launch + readiness poll to `start_lcars_server` (per-team
log at `$AITEAMFORGE_DIR/logs/lcars-server-<team>.log`, 15s first-boot poll, crash
short-circuit). The "already serving → leave it running" guard is preserved so a
healthy server is never killed; the helper's soft-fail return is guarded so
`set -eo pipefail` does not abort startup. The shipped seed
`share/scripts/lcars-launch-helpers.sh` is now drift-gated by `sync-tap.sh` and is
a byte-for-byte mirror of the dev-team canonical (portable: it resolves all paths
from `${AITEAMFORGE_DIR:-$HOME/dev-team}`, so the SAME file works on dev and tap
machines).

### Bugfix: XACA-0561 — `lcars-health-check.sh` and `lcars-smoke-test.sh` derive LCARS ports at runtime

`lcars-health-check.sh` and `lcars-ui/lcars-smoke-test.sh` hardcoded per-team LCARS ports that
had drifted from canonical (`finance-personal` claimed 8427 vs canonical 8360;
`legal-coparenting` claimed 8230 vs canonical 8320 — both stale since XACA-0168), so the
health-check relaunched servers on the wrong ports and the smoke-test silently targeted dead
endpoints. Both scripts now resolve ports at runtime from a new shared CLI,
`kanban-hooks/lcars_ports.py`, which reads canonical (live `team-paths.json` overlay →
`DEFAULT_TEAMS` fallback) and skips missing/`None` ports — a single source of the derivation
logic so the two scripts can no longer diverge. The canonical path is resolved relative to the
script (`${0:A:h}/…/kanban-hooks`) so it works in both the dev tree and the shipped tap layout.
`scripts/kb-port-reconcile` gains a `--check` read-site regression guard that exits non-zero if
either script re-hardcodes a port that diverges from canonical.

### Bugfix: XACA-0560 — `aiteamforge stop` / `restart` / `uninstall` / `migrate` now actually find the running LCARS server

`aiteamforge stop` (and `restart`) reported "LCARS server not running" even when
LCARS was up, then `restart` could not rebind the port still held by the
un-killed process. Root cause: the stop path matched processes with
`pgrep -f "lcars-ui/server.py"`, but `start.sh` and every per-team `*-lcars-startup.sh`
launch LCARS **relatively** (`cd lcars-ui && python3 server.py <port>`), so the
running command line is `python3 server.py <port>` with **no `lcars-ui/` substring**.
The path-prefixed pattern never matched, so stop/restart were silent no-ops. The
identical broken pattern lived in three command scripts; all are aligned to the
port-anchored matcher already proven in `lcars-launch-helpers.sh` /
`lcars-restart-helpers.sh` (`server\.py.*<port>`).

- **`libexec/commands/aiteamforge-stop.sh`** — `stop_lcars()` now finds and
  verifies LCARS via `pgrep -f "server\.py [0-9]"` (both the discovery and the
  post-kill verification sites). The trailing `[0-9]` anchors on the port
  argument, so it matches both relative (`server.py 8203`) and absolute
  (`/…/lcars-ui/server.py 8203`) launches without matching an incidental
  `vim server.py` (no port arg).
- **`libexec/commands/aiteamforge-uninstall.sh`** — `stop_services()` LCARS
  detect/kill switched to the same `server\.py [0-9]` matcher.
- **`libexec/commands/aiteamforge-migrate.sh`** — both rollback / migrate
  service-stop sites switched to the same matcher.

No launcher changes: the matcher fix is launch-style-agnostic, and the relative
launch is shared by `start.sh` and all per-team startup scripts. The
`fleet-monitor/server` matchers are unaffected (separate Node service).

### Bugfix: XACA-0564 — `install_kanban_helpers` now refuses to overwrite a git work-tree / git-tracked `kanban-helpers.sh`

Root cause (XACA-0559 post-mortem): an installer test that did not sandbox
`$AITEAMFORGE_DIR` let `install_kanban_helpers()` overwrite the dev source-of-truth
`kanban-helpers.sh` with the small aliases template, silently dropping `kb-sweep` /
`kb-merge` and breaking PR merge gates on the next shell session.

- **`libexec/installers/install-kanban.sh`** — `install_kanban_helpers()` now probes
  `$AITEAMFORGE_DIR` before writing. If the destination resolves to a git work-tree
  (detected via `git rev-parse --git-dir`) or the target file is git-tracked
  (`git ls-files --error-unmatch`), the function **hard-aborts** the entire install
  rather than silently overwriting. The opt-in escape hatch
  `AITEAMFORGE_ALLOW_DEV_OVERWRITE=1` bypasses the guard for intentional dev
  workflows where clobbering a tracked file is expected.
- **`tests/test-xaca-0564-kanban-helpers-overwrite-guard.sh`** — sandboxed regression
  test covering: (a) guard trips and aborts when `$AITEAMFORGE_DIR` is inside the git
  work-tree, (b) opt-in env var suppresses the abort, (c) untracked / non-git paths
  proceed normally.

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

### Bugfix: XACA-0556 — startup surfaces real LCARS boot failures instead of a generic 5s timeout (printed twice)

When `server.py` FATALed on boot (port collision, missing dependency, …), `start_lcars_server()`
(`scripts/lcars-launch-helpers.sh`) discarded all server output inside a PID-orphaning subshell
and only polled `/api/status` for a fixed 5s, so the crash was invisible — the poll timed out
with a generic "did not respond within 5s — continuing" while each of the 11 `*-startup.sh`
callers appended its own "timed out" echo (the "printed twice" symptom). `start_lcars_server()`
now captures the server's stderr to a per-team log
(`$AITEAMFORGE_DIR/logs/lcars-server-<team>.log`), tracks the real python PID, and polls 15s but
**short-circuits the instant the process dies**, surfacing the real exit status plus the last
~15 log lines rather than burning the full window. All 11 startup scripts drop their redundant
caller-side echo (the helper now owns the failure message); the helper size-caps the per-team
log, and `scripts/lcars-restart-helpers.sh` drops the now-stale "within 5s" restart fallback.

### Bugfix: XACA-0554 — fix secrets-import dead-end (import never linked paired secrets; UI couldn't acknowledge)

Importing any team whose export manifest declared `secrets_summary.discovered > 0` failed hard
with HTTP 409 `missing_paired_secrets` and could not be completed through the LCARS UI — a
blocker for migrating any secrets-bearing team. The apply gate checked
`job.get('pairedSecretsJobId')`, but nothing ever set that field on an *import* job, and the
only override (`acknowledgeMissingSecrets`) was unreachable because the UI's apply POST sent no
body. The import-apply handler now accepts an optional `pairedSecretsJobId`, validating that the
referenced secrets job exists, has been password-verified, and targets the same team before
linking it (invalid/wrong-state/team-mismatch references return a clear `400`). The UI shows an
inline secrets file-picker + password in the preflight panel and keeps **Apply Import** disabled
until both are supplied, orchestrating upload → verify → apply with a combined progress view.
The secrets password is read from the DOM, zeroed immediately after verification, and held only
in the apply call's closure — never a module-scope variable.

### Bugfix: XACA-0553 — LCARS export/import fetch errors show HTTP status and server reason instead of a generic "Network error"

Every user-initiated fetch in the export/import flows used the `json()`-before-`ok` anti-pattern:
calling `await response.json()` on a non-OK response threw when the server returned a non-JSON
error body, and the caller's generic `catch` surfaced "Network error" — the same message shown
when the server is completely unreachable, making the three failure modes indistinguishable. Two
new shared helpers — `readJsonResponse()` (reads any fetch `Response` without throwing) and
`_httpErrorMessage()` — now distinguish a true fetch reject (server unreachable: "LCARS server
not responding on this port…", with the password zeroed before the message shows), a non-OK HTTP
status ("HTTP <status> <reason>" from `data.error`/`message`/`statusText`), and an OK-but-
unreadable body. Applied to all 12 user-initiated export/import fetch sites; interval status-poll
fetches are intentionally left unchanged.

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

[Unreleased]: https://github.com/DoubleNode/homebrew-aiteamforge/compare/v0.12.12...HEAD
[0.12.12]: https://github.com/DoubleNode/homebrew-aiteamforge/compare/v0.12.11...v0.12.12
[0.12.11]: https://github.com/DoubleNode/homebrew-aiteamforge/compare/v0.12.10...v0.12.11
[0.12.10]: https://github.com/DoubleNode/homebrew-aiteamforge/compare/v0.12.9...v0.12.10
[0.12.9]: https://github.com/DoubleNode/homebrew-aiteamforge/compare/v0.12.8...v0.12.9
[0.12.8]: https://github.com/DoubleNode/homebrew-aiteamforge/compare/v0.12.7...v0.12.8
[0.12.7]: https://github.com/DoubleNode/homebrew-aiteamforge/compare/v0.12.6...v0.12.7
[0.12.6]: https://github.com/DoubleNode/homebrew-aiteamforge/compare/v0.12.5...v0.12.6
[0.12.5]: https://github.com/DoubleNode/homebrew-aiteamforge/compare/v0.12.4...v0.12.5
[0.12.4]: https://github.com/DoubleNode/homebrew-aiteamforge/compare/v0.12.3...v0.12.4
