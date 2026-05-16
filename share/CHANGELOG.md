# Changelog

All notable changes to the Academy (dev-team) infrastructure.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html)

## [Unreleased]

### Chore: XACA-0476 — Bump `homebrew-tap` submodule pointer → `78aa0a96` (FRAMEWORK_DIR cluster path fix + omnibus sync-tap drift)

- **`homebrew-tap` submodule:** advanced recorded pointer from `2f1d5768` to `78aa0a96` (DoubleNode/homebrew-aiteamforge#28, squash-merged to tap `main`). That tap PR bundles two distinct change-sets per explicit user direction:
  1. **Path fix (XACA-0476 primary):** 7 path strings + 1 comment in `libexec/commands/aiteamforge-upgrade.sh` corrected from `${FRAMEWORK_DIR}/<dir>` to `${FRAMEWORK_DIR}/share/<dir>` for `update_templates()` (l.160/167), `update_lcars()` (l.217), `update_shell_helpers()` (l.249/251), `update_skills()` (l.337), `update_launchagents()` (l.397), and `show_changelog()` (l.442). All six previously hit a directory-existence guard and silently no-op'd because Formula's `libexec.install Dir["*"]` maps source `share/` → `libexec/share/`, not to the libexec root. Origin: XACA-0343 Outlier 3 flagged only line 217; an audit-first subitem (XACA-0476-001) caught the cluster — **second confirmed datapoint after XACA-0501 for the sibling-heuristic-drift anti-pattern**.
  2. **Omnibus sync-tap drift (37 files):** tap-side mirrors of already-merged dev-team work from XACA-0135 (fleet-monitor `package.json` test wiring, ~6 weeks dark), XACA-0463 (`server.py` startup guard + 2 guard tests), XACA-0478 (`lcars.js` HTML comment strip), XACA-0488/0490/0491/0492/0496 (`team_transfer/*` migration domain modules + tests), and XACA-0497 (14 avatar PNGs compressed ~1.7 MB → ~120 KB each). All originating dev-team PRs are merged; this commit lands the tap-side mirrors that prior `sync-tap.sh` runs missed.
- **Two compound-bug follow-ups filed:** XACA-0510 (`update_launchagents()` still silently no-ops after prefix fix — no `.plist` files ship at `share/launchagents/`, only `.template` files) and XACA-0511 (`show_changelog()` still silently no-ops — no `share/CHANGELOG.md` ships, only component-specific `share/lcars-ui/CHANGELOG.md`). These are pure path-prefix fixes; the missing-source-file problem at each call site is a separate design decision.
- **CI delta at tap merge:** `Node.js Tests (18/20/22)` in `fleet-monitor/server` failed at merge time and were bypassed via `--admin` per omnibus-PR governance. Likely related to XACA-0135's `package.json` test wiring landing without its companion `dashboard-routes.test.js` file in the sync mirror — flagged for follow-up triage, NOT a regression introduced by XACA-0476's path fix.
- **Why bundled rather than split:** explicit user direction. The runway-clearing sync was discovered during XACA-0476-002 execution when the tap working tree showed 37 dirty files from 9 prior tickets. User chose to ship in one commit rather than split into a separate "Chore: Sync tap" PR — accepted the larger diff for the smaller PR count.

### Chore: XACA-0509 — Bump `homebrew-tap` submodule pointer → `2f1d5768` (shellcheck noise cleanup)

- **`homebrew-tap` submodule:** advanced recorded pointer from `6041a1b5` to `2f1d5768` (DoubleNode/homebrew-aiteamforge#27, squash-merged to tap `main`). That tap PR resolves seven pre-existing shellcheck warnings in `libexec/installers/install-team.sh` (5) and `libexec/lib/aiteamforge-paths.sh` (2): four `# shellcheck disable=SC1091` directives co-resident with existing `source=` hints (covers `|| true`-guarded optional sources that default-mode shellcheck cannot follow), one `# shellcheck disable=SC1003` with rationale on the `_sanitize_free_text` `tr -d '|"\\'` arg (false positive — the `\\` is two literal backslashes in the tr deletion class, not a shell quote-escape), one dead-code deletion of an unused `REGISTRY_DESC` jq-extraction (verified via grep — only references remaining are stale doc comments at lines 1521/1595 describing pre-XACA-0486 migration history), and one `ls *.txt | wc -l` → `find -maxdepth 1 -type f -name '*.txt' | wc -l` migration for the `PROMPT_COUNT` calculation. No dev-team code change in this commit — pure pointer bump.
- **Why:** Originally surfaced as XACA-0463 PR #22 review subitem 17 ("baseline shellcheck noise — pre-existing"). Split off into XACA-0509 to keep the per-instance LCARS port allocation work scope-tight; merging the noise fix in its own PR makes it easier to bisect future regressions and prevents review-fatigue on the larger XACA-0463 diff.
- **Behavior preserved exactly.** Pre-PR test gate (Thok subagent): `tests/test-installers.sh` 32/32, `tests/test-team-banner.sh` 62/62, `tests/test-multi-team.sh` 38/38. The fourth relevant tap test (`tests/test-org-config.sh`) baseline-failed on `origin/main` before this PR — not a regression introduced here.
- **Reusable pattern documented for future tap noise-cleanup PRs:** co-resident `# shellcheck source=<path>` + `# shellcheck disable=SC1091` co-exist cleanly. The disable silences default-mode noise today; the source= hint becomes active automatically when CI flips to `-x` mode (no follow-up rework needed). Avoids the false dichotomy of "either suppress or migrate to -x".

### Chore: XACA-0508 — Bump `homebrew-tap` submodule pointer → `6041a1b5` (head: block for --HEAD install)

- **`homebrew-tap` submodule:** advanced recorded pointer from `31a9f0f` to `6041a1b5` (DoubleNode/homebrew-aiteamforge#26, squash-merged to tap `main`). That tap PR adds a `head "URL", branch: "main"` one-liner to `Formula/aiteamforge.rb`, enabling `brew install --HEAD aiteamforge` as an opt-in path for developers validating formula `test do` changes on a sandbox before the next tag bump. The pinned `tag: "v0.11.11"` / `version "0.11.11"` stable install path is unchanged.
- **M3Pro hard rule:** `brew install --HEAD aiteamforge` MUST NOT run on this machine (XACA-0212/XACA-0219 stub-pollution prohibition). Smoke-test path deferred to sandbox (M1Pro / M4Mini / CI runner) per plan doc.
- **Why:** Implements Option 2 from the XACA-0506 tag-vs-HEAD decision note (`docs/tag-vs-head-model.md`). Closes the gap where formula `test do` changes could not be validated against tap HEAD without waiting for a tag bump.

### Docs: XACA-0505 — Doctor-fix stub-message test unskipped on CI (tap commit `d2c775da`)

- **Documentation stanza only — no dev-team code or gitlink change in this entry.** The XACA-0505 tap PR (`d2c775da`, DoubleNode/homebrew-aiteamforge#25) was merged to tap `main` on 2026-05-15 between the prior submodule bump (XACA-0503 → `31a9f0f`, PR #416) and the XACA-0508 bump (PR #418 → `6041a1b5`, which leapfrogged past `d2c775da`). The XACA-0508 entry above bumps the gitlink directly from `31a9f0f` to `6041a1b5`; this stanza fills the documentation gap for the intermediate tap commit so future readers grepping for XACA-0505 or "doctor-fix stub message" find the rationale here.
- **What the tap PR did:** removes the `if [ -z "${CI:-}" ]` gate added in XACA-0499 around the `"--fix without failures (warnings only) does not show stub message"` test in `tests/test-doctor-fix.sh` and rewrites the assertion to use `--fix --check config` so it runs on every CI build. The original full-`--fix` invocation tripped framework/dependency failures on vanilla GHA `macos-latest` runners (no aiteamforge tap installed) and rendered the legitimate `"Auto-fix not yet implemented"` stub the test was meant to catch.
- **Strategy (recorded for future readers):** `--check config` is bounded by `AITEAMFORGE_DIR` / `HOME` which the test fixture already mocks (`_FAKE_AITEAMFORGE`). With `_write_config` writing a valid `.aiteamforge-config`, the config component reports pass + warnings, zero failures — preserving the original assertion semantics (no stub when there are no failures) without re-shipping half of `setup --upgrade` as a mock framework directory.
- **CI count delta:** `tests/test-doctor-fix.sh` now runs **53/53** under `CI=1` (previously 52/52 with the gated test skipped). The +1 is exactly the unskipped test passing. Follow-up to XACA-0499.

### Test: XACA-0289 — Port 8 legacy `tests/test-*.sh` scripts to formal bats harness

- **8 new `.bats` files in `tests/bats/`** — `kb-knowledge-promote-stdout-clean.bats`, `kb-knowledge-promote-tier.bats`, `kb-knowledge-add-index-scaffold.bats`, `kb-knowledge-crossref.bats`, `kb-knowledge-curated-title-roundtrip.bats`, `kb-audit.bats`, `kb-sweep-stubs.bats`, `kb-subitem-numbering.bats`. Each is hermetic via `setup_kb_sandbox` (per-test mktemp sandbox; `KB_KNOWLEDGE_GLOBAL_ROOT` isolated; `_kb_log_activity` neutralized inside the `zsh -c` shell-out so tests never mutate real kanban state). Adds 84 new tests to the bats suite (baseline 196 → 280 total; pass count 161 → 245; pre-existing 35 `kb-cr-*` failures unchanged).
- **8 legacy `tests/test-*.sh` scripts deleted** — `test-kb-audit.sh` (743 LOC), `test-kb-sweep-stubs.sh` (395 LOC), `test-knowledge-add-index-scaffold.sh` (127 LOC), `test-knowledge-crossref.sh` (340 LOC), `test-knowledge-curated-title-roundtrip.sh` (329 LOC), `test-knowledge-promote-stdout-clean.sh` (106 LOC), `test-knowledge-promote-tier.sh` (241 LOC), `test-subitem-numbering.sh` (751 LOC). Total ~3,032 LOC removed. The 4 remaining one-shot regression scripts (`test-kanban-helpers-nounset.sh`, `test-kb-cr.sh`, `test-pre-push-worktree.sh`, `test-xaca-0494-banner-defensiveness.sh`) are intentionally kept — out of scope for XACA-0289.
- **T3 SPEC §7 correction in `kb-knowledge-promote-tier.bats`** — the legacy `.sh` script's T3 asserted `subjects → agents` promotion should succeed, which contradicts SPEC §7 ("Entries flow upward through tiers as their applicability broadens. Downward movement does not happen."). The bats port inverts the assertion: T3 now asserts the downward promotion is refused (`status != 0`, target file not written, error output contains the SPEC §7 guard phrase). Aligns the test with the documented rank-guard behavior in `_kb_knowledge_tier_rank` (`kanban-helpers.sh:9484`). The legacy `.sh` test had been silently failing T3 in every run; bats migration surfaced it.
- **`tests/bats/README.md`** — "When to add a bats test vs a one-shot regression script" section rewritten to reflect XACA-0289 completion: the 8 knowledge/kb-* scripts are ported and removed, the bats harness is the canonical home for new shell coverage, and the 4 remaining one-shots are narrow regression guards.
- **Why now:** XACA-0271 stood the bats harness up on 2026-05-01 with a 5-test seed. XACA-0289 was intentionally held until 2026-05-15 (2-week soak window) so any rough edges in `tests/bats/helpers.bash` surfaced against the seed before being multiplied across 8 ports. The soak proved clean — no helpers.bash changes were needed for the port batch.
- **No `kanban-helpers.sh` changes** — XACA-0289 brief locks production code out of scope. The T3 rewrite changes only the test assertion, not the rank-guard implementation.

### Fix: XACA-0475 — Centralize sync-tap.sh `__pycache__`/`*.pyc` exclusions + post-sync sanity check

- **`sync-tap.sh`** — Added a comment-anchored documentation block above `sync_dir()` naming the Python-bytecode exclusion rule (XACA-0343/XACA-0475), explaining WHY (.pyc is CPython-version-specific and CPU-arch-specific; shipping silently breaks consumers on a different Python minor version), and citing the two `find` predicates that enforce it (`-not -name "*.pyc"` and `-not -path "*/__pycache__/*"` at lines ~164, ~169). The comment also warns future refactorers not to remove the predicates without also removing the post-sync `BYTECODE-GUARD` block.
- **`sync-tap.sh`** — Added a `BYTECODE-GUARD` post-sync sanity check after section 5 (docs sync) and before the final summary. In non-`--check` mode, the guard pre-cleans any runtime-generated `__pycache__/` directories under `$TAP/share/` and `$TAP/fleet-monitor/` (Python auto-generates these on import in the tap tree — they don't come from sync, and they should never ship in a bottle). Then a final `find` scans both surfaces for any `*.pyc` files or `__pycache__/` dirs and exits 2 (matching the "tap not initialized" exit-code convention for broken state) with a clear diagnostic listing up to 5 offending paths and a pointer to XACA-0475/XACA-0343 Outlier 1. The check runs in `--check` mode too (read-only) — it just doesn't pre-clean.
- **One-shot remediation:** Pre-existing stray `__pycache__/` directories under `homebrew-tap/share/scripts/` and `homebrew-tap/share/kanban-hooks/` (Python import side-effects, NOT from sync — confirmed by XACA-0475-001 audit) were removed manually from the main repo before pushing this branch so the new guard wouldn't trip on its first invocation during the `pre-push` `--check` hook.
- **No behavior change** to the existing `sync_dir()` exclusion patterns; the authoritative mirrored count remains **629** (XACA-0343 audit confirmed). This commit hardens the guarantee without modifying behavior.

### Chore: XACA-0506 — Bump `homebrew-tap` submodule pointer → `8925ab8b` (v0.11.11 formula + assert restoration)

- **`homebrew-tap` submodule:** advanced recorded pointer from `77933fd6` to `8925ab8b` (DoubleNode/homebrew-aiteamforge#21, now on `tap/main`). That tap PR bumps `Formula/aiteamforge.rb` `tag:`/`version` from `v0.11.10` → `v0.11.11` and restores the previously-commented `assert_path_exists libexec/"share/scripts/worktree-helpers.sh"` check in the formula's `test do` block. The file was shipped in v0.11.11 via XACA-0494, but the formula had remained pinned at v0.11.10 — leaving the assertion as a TODO and `brew test aiteamforge` blind to a regression that would have failed against the live tarball.
- **Also includes** `homebrew-tap/docs/tag-vs-head-model.md` — decision note capturing the recurring tag-vs-HEAD lag pattern surfaced by XACA-0499 (10 commits past v0.11.10 at the time the formula was last touched). The note evaluates Option 1 (tag-only, current) vs Option 2 (add `head:` block, opt-in `--HEAD`) and records the chosen direction. **XACA-0508** tracks the optional `head:` block follow-up.
- **Why now:** XACA-0506 is the dev-team-side carrier ticket for the tap PR's effects. The tap PR landed on `tap/main` at `8925ab8b`; this bump aligns dev-team's submodule view with the published tap so anyone cloning dev-team gets the v0.11.11 formula state.

### Refactor: XACA-0478 — `kb-retro-path` marker-aware plan-doc pick + LCARS HTML comment strip

- **`kanban-helpers.sh`** — Added two internal helpers, `_kb_filter_canonical_plan_docs` and `_kb_pick_plan_doc`, that implement a two-pass plan-doc resolver: prefer any doc carrying `<!-- plan_doc: canonical -->` (full-file `grep -q`, marker may appear anywhere); fall back to `sort | head -1` for un-migrated or single-doc directories (XACA-0472 behavior preserved bit-for-bit). Both the flat-layout branch and the `plans/<ID>/` subdir fallback in `kb-retro-path` now call `_kb_pick_plan_doc` instead of inline `find | sort | head -1`. The marker is greppable in pure shell — no YAML parser, no external dependencies. Multiple marked docs are tie-broken by `sort | head -1` (deterministic). The comment block above `kb-retro-path` is updated to document the two-pass strategy and remove the "A future ticket may upgrade this" note (this ticket is that upgrade).
- **`lcars-ui/js/lcars.js` (`renderMarkdown`)** — Added a pre-strip step at the top of the function (`content = content.replace(/<!--[\s\S]*?-->/g, '');`) that removes HTML comments before `escapeHtml()` runs. Without this, `escapeHtml()`'s `div.textContent` assignment encodes `<` as `&lt;` and `>` as `&gt;`, causing `<!-- plan_doc: canonical -->` to render as visible literal text in the LCARS UI. The strip step runs before code-block extraction so there is no interaction with the XACA-0292-013 XSS guard. Aligns LCARS with CommonMark spec behavior (HTML comments are not rendered in GitHub or Confluence).
- **`skills/Project Planner/SKILL.md`** (Phase 5 plan-doc template) — Template now begins with `<!-- plan_doc: canonical -->` on line 1 above the H1, so every plan doc generated by `/plan-project` automatically carries the marker the resolver looks for. Added the marker as item 0 of the "Minimum Content Requirements" list and as item 0 of the Phase-5b verification checklist box, plus a "Marker Convention" callout explaining when the marker applies (canonical plan docs only — side-docs MUST NOT carry it). Live `~/.claude/skills/...` and tracked `skills/...` copies kept in sync to avoid live-vs-tracked drift.
- **Why this approach** — HTML comment marker is invisible in GitHub, Confluence, and LCARS (after this patch); greppable in one shell line; requires no schema changes to existing plan docs; opt-in (un-migrated dirs still resolve via fallback). Rejected alternatives: YAML frontmatter (requires full doc migration), bold metadata line (visible), filename-pattern heuristics (too brittle across existing tree).
- **`tests/bats/kb-retro-path-plans-subdir.bats` (T5)** — Replaced the T5 test body that was locking the old broken XACA-0472 lexicographic behavior (asserted `audit_report` wins because it sorts before `main_plan`). The replacement writes the canonical marker into `main_plan.md` only and asserts `main_plan_RETROSPECTIVE.md` is chosen, locking the new marker-wins behavior (XACA-0478).
- **`tests/bats/kb-retro-path-canonical-marker.bats`** (new, 7 tests → 9 tests) — Full positive + negative bats coverage for the marker-aware resolver. M1: marker in plans-subdir wins even when it sorts last; M2: marker wins in flat kanban-root layout; M3: tie-break among multiple marked docs uses sort+head-1; M4: fallback to lexicographic pick when no markers present (locks XACA-0472 backward compat path); M5: marker detected anywhere in file (not restricted to line 1); M6: retro files carrying the marker are excluded by the find filter; M7: empty-value `<!-- plan_doc: -->` does NOT trigger the marker path (locks the literal marker-string contract). Item IDs use the all-numeric `XACA-990x` range to pass the format validation regex `^X[A-Z]{3}-[0-9]+$`. Uses `printf '%s\n' 'content'` form throughout to avoid bash's `printf` rejecting leading-dash format strings in the bats/bash harness. M8a + M8b (added post-initial-commit): lock the intentional `find -type f` symlink exclusion — M8a asserts a real file coexisting with a symlink sibling is the only candidate; M8b asserts a symlink-only directory yields a non-zero resolver exit. If symlinked plan docs are ever needed the resolver must move to `find -L -type f` and M8a/M8b must be rewritten.

### Fix: XACA-0463 (subitems 013-016) — install-team.sh team-paths.json writer hardening

- Backup snapshot (`shutil.copy2`) before write (parity with `kb-port-fix.py`)
- `tempfile.mkstemp` for concurrency-safe atomic write
- `_safe_teams`-normalise malformed root / non-dict teams value (parity with kb-port-fix XACA-0463-013 fix)
- Preserve target file's mode bits across atomic rename (`os.stat` + `os.chmod` before `os.replace`)

PR-22 follow-up addressing all four [Review] subitems from the reviewer's pass.

### Fix: XACA-0463 (subitem 013) — kb-port-fix robustness for malformed team-paths.json

- **`homebrew-tap/libexec/commands/kb-port-fix.py`** — Defend against non-dict root and non-dict `teams` value. Added `_safe_teams()` helper; updated `_load_team_paths()` to normalise a non-dict root to `{"teams": {}}`; `_build_port_map()` and `_collect_null_ports()` route through `_safe_teams()` and skip non-dict entries. Fixes `AttributeError` crash when `team-paths.json` contains `null`, `[]`, or scalar at the root, or when `teams` is `null`/`[]`/non-dict entries (subitem 008 QA finding).
- **`homebrew-tap/libexec/commands/test_kb_port_fix.py`** — Added `TestMalformedRootGuard` class with 10 new cases: null root, array root, null teams, array teams, non-dict entry, plus equivalent paths for `_collect_null_ports`, `_build_plan`, and `_load_team_paths`. Test count: 15 → 25, all pass.

### Test: XACA-0463 (subitem 008) — Comprehensive QA pass

- Re-ran all 4 Python unit-test suites: 11 tests (test_aiteamforge_paths) + 15 tests (test_kb_port_fix) + 10 tests (test_xaca0463_guard) = 36 Python tests; all pass.
- Re-ran 2 shell test suites: 11 tests (test-xaca-0463-allocator.sh) + 13 tests (test-xaca-0463-port-allocation.sh) = 24 shell tests; all pass. Total: 60 tests, 0 failures.
- Verified Python-mirror byte identity: `kanban-hooks/aiteamforge_paths.py` == `homebrew-tap/share/kanban-hooks/aiteamforge_paths.py` (diff empty, XACA-0408 contract satisfied).
- Lint sweep: all 7 Python files compile clean; all 5 shell files pass `bash -n`; `shellcheck` shows no new warnings beyond pre-existing baseline (SC1091/SC2034/SC1003/SC2012 on `install-team.sh`, SC1091 on `aiteamforge-paths.sh`; `kanban-helpers.sh` zsh-glob `bash -n` failure is pre-existing).
- Regression tests: 4 test-runner-framework tests (test-multi-team, test-org-config, test-team-banner, test-validate-install, test-xaca-0483-parametric) fail identically on baseline and feature branch — not regressions; they require the tap test-wizard runner.
- kb-port-fix detect-mode on live `~/.aiteamforge/team-paths.json` confirmed working: 2 collision groups (port 8234: command/mainevent; port 8505: 7 freelance instances), 4 null ports. Real file verified unchanged via `diff` against backup.
- CHANGELOG completeness: subitems 001-007 all have entries; subitem 008 entry added here.
- Bug found (Category A): `kb-port-fix.py` raises `AttributeError` when `team-paths.json` contains `null` or `[]` at the root level instead of a JSON object. Filed as XACA-0463-013 `[Test]` subitem (merge-blocking). All other exploratory findings were Category B (pre-existing limitation) or Category C (verified correct).
- **Known limitation (Category B — not a regression):** Concurrent `install-team.sh` invocations can race the allocator → both select the same port. The allocator reads `team-paths.json` at line 290, but the write occurs ~1400 lines later after all brew-dep installation. Two parallel installers both see an empty-ish state and can choose the same port. `kb-port-fix` is the recovery path. Fix requires file locking in a future ticket.
- `git status --porcelain` shows only changes within named XACA-0463 scope. No scope creep.

### Test: XACA-0463 (subitem 007) — Add tap-side port allocation integration test

- **`homebrew-tap/tests/test-xaca-0463-port-allocation.sh`** — New executable test script (standalone + test-runner compatible). Verifies the installer wiring for per-instance LCARS port allocation end-to-end: (a) Case 1: two `finance` instances (`--project personal`, `--project business`) get distinct adjacent in-band ports (8360, 8361) with both values asserted to be in `[8360, 8370)`; (b) Case 2: `freelance` band size honoured — two instances (`doublenode/starwords`, `doublenode/workstats`) get ports 8500 and 8501 from the 100-slot band; (c) Case 3: `team-paths.json` correctly records the per-instance port for each install — also includes a structural assertion confirming finance is in parametric mode (template-keyed `finance-startup.sh`, not instance-keyed), documenting WHY port verification targets JSON and not script files; (d) Case 4: unknown template exits non-zero with a recognisable error phrase in combined stdout+stderr (the conf-not-found guard writes to stdout; the allocator guard writes to stderr — both are checked); (e) Case 5: band-exhaustion for `legal` (10-slot band fully pre-populated in sandbox) exits non-zero with "exhausted" in stderr. All writes go to `$TEST_TMP_DIR` (mktemp, canonicalised via `pwd -P` for macOS symlink compatibility); real `$HOME` and `~/.aiteamforge/team-paths.json` are never touched. `bash -n` clean; `shellcheck` clean.

### Feat: XACA-0463 (subitem 006) — LCARS server startup conflict guard

- **`lcars-ui/server.py`** — Added two functions: `_xaca0463_load_team_paths()` (loads `team-paths.json` via `aiteamforge_paths.load_config()`, falls back to direct JSON read when module unavailable, raises on unreadable/malformed file) and `_xaca0463_assert_no_port_conflicts(team_paths_data, active_instance)` (scans all entries for port collisions, checks whether the active `LCARS_TEAM` instance has a null `lcars_port`, exits with code 2 and a loud scannable stderr error naming every offender and pointing at `kb-port-fix --apply`). Also added `load_config as _aiteamforge_load_config` to the aiteamforge_paths import. Guard is wired into `main()` between `validate_lcars_team_or_die()` and the banner print — before `serve_forever()` bind. Null ports on non-active instances are NOT a startup blocker (only the active instance's null port blocks; foreign nulls are another server's concern). Exit code 2 distinguishes guard failure from OS bind errors (exit 1). `python3 -m py_compile` clean.
- **`lcars-ui/tests/test_xaca0463_guard.py`** — New test file with 10 unit tests (8 required + 2 coverage extras): `test_guard_no_conflicts_no_op` (clean data → None, empty stderr), `test_guard_collision_exits_nonzero` (shared port → SystemExit(2)), `test_guard_collision_names_offenders` (offender ids appear in stderr), `test_guard_collision_points_at_kb_port_fix` (stderr contains "kb-port-fix"), `test_guard_active_null_port_exits` (null active port → SystemExit(2)), `test_guard_inactive_null_port_ignored` (null on non-active instance → no exit), `test_guard_handles_missing_file` (missing team-paths.json → empty teams → no crash), `test_guard_handles_malformed_json` (garbage JSON → no unhandled exception), `test_guard_multiple_collisions_all_reported` (two distinct collision ports both appear), `test_guard_collision_and_null_active_both_reported` (compound case). All 10 pass.
- Smoke test against real `~/.aiteamforge/team-paths.json`: guard correctly refused with exit 2, naming 2 collision groups (port 8234: command/mainevent; port 8505: 7 freelance instances) and pointing at `kb-port-fix`. Real LCARS server NOT restarted during testing.

### Feat: XACA-0463 (subitem 005) — Add `kb-port-fix` migration tool

- **`homebrew-tap/libexec/commands/kb-port-fix.py`** — New Python script. Detect mode (default, no args): loads `~/.aiteamforge/team-paths.json` (or `$AITEAMFORGE_CONFIG`), builds a `port → [instance_ids]` map, identifies collision groups (len > 1) and null-port entries, prints a formatted human-readable report naming every offending instance with its collision group and proposed action. Exit 0 if no work needed; exit 2 if changes are required (machine-checkable by server guard). `--json` flag emits a machine-readable JSON report for consumption by subitem 006 server guard. Apply mode (`--apply`): computes full plan with concrete new ports using running-state allocation (each renumber sees prior allocations, ensuring no two newly-renumbered entries share a port), prints plan, asks for interactive confirmation (`[y/N]`; `--yes` skips on non-interactive stdin), backs up `team-paths.json` to `.bak-xaca0463-<utctimestamp>`, applies atomically (tmp + `os.replace`). Winner selection: earliest `addedAt` ISO timestamp wins; entries WITH `addedAt` outrank entries WITHOUT; alphabetical instance-id tiebreaker when no `addedAt` exists. Imports `compute_instance_port` and `_resolve_template_band` from `aiteamforge_paths.py` via bootstrap path search. `python3 -m py_compile` clean.
- **`homebrew-tap/libexec/commands/test_kb_port_fix.py`** — 15 unit tests (11 required + 4 coverage extras): `test_detect_no_collisions`, `test_detect_single_collision`, `test_detect_multi_collision_freelance`, `test_renumbers_have_distinct_ports_freelance`, `test_detect_null_port`, `test_null_port_gets_finance_band_port`, `test_winner_selection_addedat`, `test_winner_selection_missing_addedat_falls_back`, `test_winner_selection_partial_addedat`, `test_apply_does_not_reuse_renumbered_ports`, `test_apply_atomic_write`, `test_apply_creates_backup`, `test_detect_no_work_exit_0`, `test_detect_with_work_exit_2`, `test_apply_success_exit_0`. All pass.
- **`kanban-helpers.sh`** — Added `kb-port-fix()` shell function. Resolves `kb-port-fix.py` at runtime (dev-tree path first, then tap-installed path); passes all args through to `python3 "$_kpf_script" "$@"`. `shellcheck` clean. Follows the existing shell-function-shelling-out-to-Python pattern used by other kb-* helpers.
- Smoke test against real `~/.aiteamforge/team-paths.json` (detect mode only, no mutations): correctly identified 2 collision groups (port 8234: command/mainevent; port 8505: 7 freelance instances) and 4 null-port entries. File verified unchanged via `diff` against backup.
- Subitem 006 adds the LCARS server startup guard that calls this tool via `--json`.

### Feat: XACA-0463 (subitem 004) — Wire install-team.sh to allocator; persist per-instance lcars_port to team-paths.json

- **`homebrew-tap/libexec/installers/install-team.sh`** — Sourced `aiteamforge-paths.sh` unconditionally near the top of the script (after `aiteamforge-org-paths.sh`). Added XACA-0463 port allocation block immediately after `INSTANCE_ID` is finalized and validated: calls `aiteamforge_compute_instance_port "$TEAM_ID"` and overwrites `$TEAM_LCARS_PORT` with the allocated per-instance port; all downstream consumers (connect/disconnect/startup sed substitutions at former lines 451/484/850/912/956/973, the `LCARS Port:` echo, and the agent-port derivation `AGENT_PORT=$((TEAM_LCARS_PORT + AGENT_INDEX))`) automatically receive the correct per-instance value. Added XACA-0463 team-paths.json writer block in the full-install path (after the connect-only early exit, after `KANBAN_DIR` and `TEAM_WORKING_DIR` are finalized): inline Python3 script upserts the `INSTANCE_ID` entry with `kanban_dir`, `working_dir`, and `lcars_port`; write is atomic (write-to-tmp + `os.replace`). Removed the `TODO(XACA-0460)` two-line comment at the startup-template sed block; replaced with a single XACA-0463 resolution note. `bash -n` clean; `shellcheck` clean (no new errors beyond pre-existing SC1091 info for the two sourced libs, SC2034 for REGISTRY_DESC, SC1003 in tr, SC2012 for ls). Subitem 005 lands the `kb-port-fix` migration tool for existing installs.

### Feat: XACA-0463 (subitem 003) — Implement `compute_instance_port` allocator helper

- **`kanban-hooks/aiteamforge_paths.py`** (canonical) and **`homebrew-tap/share/kanban-hooks/aiteamforge_paths.py`** (tap mirror, byte-identical) — Added `_resolve_template_band(template_id)` private helper and `compute_instance_port(template_id, existing_team_paths)` public function. Deterministic, pure, fail-loud per contract §4.1. Three-step lookup: (1) direct `DEFAULT_TEAMS` key match, (2) tolerant input — strip to first dash-component and retry, (3) prefix scan — find any DEFAULT_TEAMS entry whose key starts with `<template_id>-` (handles "finance" → "finance-personal"). Used ports collected cross-template; lowest free port in `[base, base+range)` returned. Raises `ValueError` on unknown template, undeclared band, or exhausted band.
- **`homebrew-tap/libexec/lib/aiteamforge-paths.sh`** — Added `aiteamforge_compute_instance_port <template_id> [<team_paths_json>]` function with matching three-step lookup (direct → dash-strip → heredoc prefix scan). Uses `jq` with `python3` fallback for used-port parsing. Stdout: chosen port; exit >0 with descriptive stderr on failure. Passes `bash -n` and `shellcheck` (no new errors beyond pre-existing SC1091 info).
- **`kanban-hooks/test_aiteamforge_paths.py`** — New unittest file. 11 test methods: empty state, partial fill, mid-band skip, band exhausted, unknown template, tolerant-instance-id input, cross-template collision, null-port entries ignored, freelance band base (8500), freelance band size honored (>10 instances), input dict non-mutation. All pass.
- **`homebrew-tap/tests/test-xaca-0463-allocator.sh`** — New shell test file. 11 test cases mirroring Python suite. Standalone-runnable (bootstraps its own TEST_TMP_DIR and helpers) and compatible with test-runner.sh. Uses `AITEAMFORGE_CONFIG` sandboxing — never touches real `$HOME`. All pass.
- Subitem 004 wires the installer to call this helper at install time.

### Feat: XACA-0463 (subitem 002) — Extend port-band schema into conf files, DEFAULT_TEAMS mirrors, and heredoc

- **`homebrew-tap/share/teams/*.conf` (9 files)** — Replaced the single `TEAM_LCARS_PORT` scalar with three lines per file: `TEAM_LCARS_PORT_BASE` (band start), `TEAM_LCARS_PORT_RANGE` (inclusive count), and legacy `TEAM_LCARS_PORT` (deprecated, equal to BASE for backward compatibility). Band values taken from the authoritative table in `docs/architecture/team-id-contract.md` §4.1. `command` corrected from `8180` (dns band) to `8230` (its own band); `freelance` corrected from `8300` (gap) to `8500` (its authoritative band start with range 100).
- **`kanban-hooks/aiteamforge_paths.py`** (canonical) and **`homebrew-tap/share/kanban-hooks/aiteamforge_paths.py`** (tap mirror) — `DEFAULT_TEAMS` dict: added `lcars_port_base` and `lcars_port_range` to every entry. Entries with `lcars_port: None` (parameterized instances: `finance-personal`, `legal-coparenting`, `medical-general`, `medical` alias) now carry their template's band values. Freelance instances keep their existing (colliding) `lcars_port` values — deliberate, collision resolution is subitem 005 (`kb-port-fix`). Updated docstring to document new fields and mark `lcars_port` deprecated. Both files confirmed byte-identical (XACA-0408 contract).
- **`homebrew-tap/libexec/lib/aiteamforge-paths.sh`** — `_AITEAMFORGE_DEFAULT_TEAMS_DATA` heredoc schema bumped from 4 to 6 TAB-separated columns per row (`team_id`, `kanban_dir`, `working_dir`, `lcars_port`, `lcars_port_base`, `lcars_port_range`). All 21 data rows updated with the two new fields. `_aiteamforge_write_defaults` inline Python extended to read columns 5 and 6 and write `lcars_port_base`/`lcars_port_range` into the JSON config. `_aiteamforge_get_field` `while IFS=$'\t' read -r ...` loop extended with `lcars_port_base` and `lcars_port_range` variables; `case` statement extended with two new field matchers.
- **Mainevent renumber (deliberate):** `mainevent` moves from `lcars_port: 8234` to `lcars_port: 8400`. `8234` is in `command`'s band `[8230, 8240)` — the existing `command`/`mainevent` collision. `mainevent`'s authoritative band is `[8400, 8410)`. Because `mainevent` is a backward-compat alias (no concrete `team-paths.json` entry distinguishable from `command`'s entry), this is the one schema-time renumber applied in this subitem. Live `team-paths.json` migration is subitem 005.
- **Subitem 003** lands `compute_instance_port` — the allocator function that uses these band values.

### Docs: XACA-0463 (subitem 001) — Formalize per-instance LCARS port allocation in team-id-contract.md

- **`docs/architecture/team-id-contract.md` §4** — Updated "Template id is used for" bullet: a template now declares a port *band* (`TEAM_LCARS_PORT_BASE` + `TEAM_LCARS_PORT_RANGE`) rather than a single port offset. Updated "Instance id is used for" bullet: the dedicated per-instance port is allocated from the template's band at install time by `compute_instance_port` and persisted to `team-paths.json` as `lcars_port`.
- **`docs/architecture/team-id-contract.md` §4.1 (new)** — "Port allocation rule" subsection. Specifies band declaration in `.conf` files and `DEFAULT_TEAMS` mirrors, the initial authoritative band-layout table (11 templates, `freelance` gets a 100-port block at 8500–8599), allocator contract (`compute_instance_port` is deterministic + pure), persistence requirement (atomic write to `team-paths.json`), and single-instance vs. multi-instance template behavior.
- **`docs/architecture/team-id-contract.md` §6** — Added install-time validation rule 9 (allocator MUST be called; resolved port MUST be in-band, free, and persisted in the same write; failure is fatal). Added LCARS server-startup rule 4 (server MUST scan for duplicate `lcars_port` values, MUST name every offending instance id, MUST point user at `kb-port-fix`, MUST refuse to start on null `lcars_port` for the running instance).
- **`docs/architecture/team-id-contract.md` §8** — Added XACA-0463 reference entry.
- No code changes in this subitem. Subitem 002 lands the schema values into `.conf` files and `DEFAULT_TEAMS` mirrors; subitems 003–007 implement the allocator, installer wiring, migration helper, and server guard.

### Fix: XACA-0501 — `kb-done` / `kb-retro-check` retro-detection false-negative on canonical plan-doc path

- **`kanban-helpers.sh:3352`** (`kb-done` KNOWLEDGE CAPTURE REMINDER banner) and **`kanban-helpers.sh:8546`** (`kb-retro-check` audit) — replaced the legacy `find "${kanban_dir}" -maxdepth 1 -type f -name "${id}_*_RETROSPECTIVE.md"` heuristic with the canonical `kb-retro-path "$id"` resolver gated on `[[ -f ]]`. Both sites now mirror the `kb-sweep` reference implementation at line 3163.
- **Why the bug existed** — Retros now live under `kanban/plans/<ID>/<ID>_*_RETROSPECTIVE.md` (nested), but `find -maxdepth 1` only scans `kanban/` itself. The `kb-sweep` heuristic was updated to use `kb-retro-path` when the path canonicalized; the two sibling sites in `kb-done` and `kb-retro-check` were not. Result: the same `kb-done` run whose subitem sweep correctly detected the retro then immediately false-negatived in the banner block and emitted a "No retrospective found" reminder for a retro that demonstrably existed (XACA-0498 was the trigger case). Captured separately as `project_kb_done_retro_path_mismatch.md`.
- **`kanban-helpers.sh:8530`** — Hoisted `retro_path_result` into the pre-loop `local` declaration block in `kb-retro-check`. Initial patch landed `local retro_path_result` *inside* the `while IFS= read -r item_json` loop, which under zsh emits the variable's current value as an `assignment=value` line to stdout on every iteration after the first — polluting the audit's table output. Hoist + drop-the-`local`-keyword resolves the leak; the `kb-done` site was already correct (its `local` lives inside an `if`, not a loop). Caught by Thok in PR-#410 first-round QA.
- **Acceptance** — `kb-retro-check --team academy` now reports XACA-0498 as `Yes` (was `No`). A direct path-resolution exercise on the same item returns the canonical retro file. Negative case (XACA-0501, retro not yet written) returns NOT FOUND, as expected.

### Chore: Bump `homebrew-tap` submodule pointer → `77933fd6` (tap/main)

- **`homebrew-tap` submodule:** advanced recorded pointer from `3bfcfc51` to `77933fd6` (current `tap/main` tip). Brings the parent repo's submodule view in lockstep with the published tap. The bump includes two upstream commits:
  - **`77933fd6`** — `Docs: Project Planner — Three-gate verification on Sync Local Develop subitem (#19)`. Mirror of the dev-team source-of-truth change committed earlier in this Unreleased section. Tap copy is now in lockstep with `skills/Project Planner/SKILL.md`.
  - **`5b72257`** — `Fix: XACA-0499 — Repair CI rot on homebrew-aiteamforge (workflow vs layout drift) (#18)`. Upstream tap CI repair, not dev-team work; carried along by the pointer bump.
- **Why now:** previously deferred per "Source only — skip submodule for now" call during the Sync-Local-Develop enhancement session. Both upstream PRs have since merged on tap/main; the bump aligns dev-team's submodule view with reality.

### Feat: XACA-0500 — Instrument `kb-knowledge-search` with JSONL usage telemetry

- **`kanban-helpers.sh:9180`** — After the existing result-count summary in `kb-knowledge-search`, appended a telemetry block that logs one JSONL line per search to `~/dev-team/kanban-logs/kb-search.jsonl`. Fields: `ts` (ISO 8601 UTC), `persona` (`$LCARS_TEAM` or `$KB_DETECTED_TEAM`, falls back to `unknown`), `query`, `tier`, `agent`, `subject`, `project`, `tag`, `results` (integer hit count — distinguishes hit from miss), `cwd`. The block sits **after** the early `return 1` help path so usage-display invocations are not counted as searches.
- **JSON-escape contract for all string fields** — Every interpolated string (including `persona`, which was missed in the first pass and caught by review) runs through a five-step escape: backslash `\` → `\\`, double-quote `"` → `\"`, newline → `\n`, carriage return → `\r`, tab → `\t`. **Order matters:** backslash MUST be doubled first, before any control-char substitution introduces literal `\n`/`\r`/`\t` escape sequences that the doubling step would otherwise re-double. Bats coverage verifies every escape path round-trips through `jq -r .field` back to the original byte sequence.
- **`tests/bats/kb-knowledge-search.bats`** (new, 12 tests) — Regression suite covering hit/miss counts, help-path-no-log, opt-out flag, JSON-escape correctness for query AND persona (backslash + quote + newline + CR + tab), filter capture (`--agent`/`--tier`), defensive contract under a read-only log dir, and the `unknown` persona fallback when both env vars are missing. Uses the existing `helpers.bash` sandbox (`KB_KNOWLEDGE_GLOBAL_ROOT` + `HOME` redirected to a `mktemp -d` dir per test) so the real `~/knowledge` tree and `~/dev-team/kanban-logs` are never touched.
- **Defensive contract** — `mkdir -p` auto-creates the log dir on first write; the entire telemetry block is wrapped in `{ … } || true` and `>>` is `2>/dev/null` so a full disk, read-only filesystem, or permission error cannot break the user's actual search. Opt out via `KB_SEARCH_TELEMETRY_DISABLED=1` (default on — the point of this feature is to **have** data).
- **`.gitignore:74`** — Added `kanban-logs/` under the existing Logs section. The existing `logs/` pattern matches only directories named exactly `logs`, not `kanban-logs/`; needed an explicit entry so the JSONL log never accidentally lands in a commit.
- **Why this exists** — The 2026-05-14 KB-system audit found zero usage telemetry across all search and read paths. The Explore-agent recon could enumerate the 512-entry corpus and grade intake health, but could not answer the actual question (*"is anyone reading this?"*) because no signal existed. This patch is the prerequisite for a data-driven KB-effectiveness audit two weeks out.
- **Subagent-shell footnote** — The same audit reported `kb-knowledge-validate` as "not found." That was a false positive: subagent shells don't auto-source `kanban-helpers.sh`, so all `kb-knowledge-*` shell functions appear missing. The validate function actually works (430 passed / 16 warnings / 247 errors on a fresh run — separate cleanup workstream surfaced for a future ticket). Captured this gotcha as a feedback memory so future audit-agent prompts begin with `source ~/dev-team/kanban-helpers.sh`.

### Docs: Project Planner — Three-gate verification on "Sync Local Develop Branch" subitem

- **`skills/Project Planner/SKILL.md:759`** — Replaced the loose bullet checklist in the mandatory `Sync Local Develop Branch` subitem with three explicit gates that the planner now instructs every agent to verify before calling `kb-done`: **(1) Worktree clean** (`git status --porcelain` must be empty; cites XACA-0347 as the cautionary case for uncommitted work stranded on develop in the main repo), **(2) PR fully merged** (`gh pr view <N> --json state --jq '.state'` must be `"MERGED"` — guards against the "approved but not merged" and `--admin`-with-silent-failure cases), and **(3) Develop synced** (main-repo `git checkout develop && git pull origin develop`, then `git log --grep="<ITEM-ID>"` to confirm the merge commit actually landed locally).
- **Removed `git worktree remove` instruction** — The old block told agents to clean up the worktree after merge confirmation. That contradicted the standing user feedback rule that agents NEVER run `git worktree remove`. Replaced with an explicit `⛔ DO NOT` line in the same block citing it as a standing user rule.
- **Tap copy:** The matching change to `homebrew-tap/share/skills/Project Planner/SKILL.md` is uncommitted in the submodule (currently on `feature/xaca-0499`) and will be bundled into a deliberate submodule update separately — not in this commit.

### Fix: `scripts/lcars-launch-helpers.sh` — wm_script path drift (LCARS tab creation)

- **`scripts/lcars-launch-helpers.sh:142`** — `local wm_script` pointed to `$HOME/dev-team/scripts/iterm2_window_manager.py`, but the script ships at the **repo root** (`$HOME/dev-team/iterm2_window_manager.py`). Every Academy team startup printed three `LCARS tab creation attempt N/3 failed` retries and then opened without the LCARS Web tab. Aligned with the tap copy (`homebrew-tap/share/scripts/lcars-launch-helpers.sh:148`), which already had the correct path.
- **Origin** — Introduced by XACA-0486 `b61e4852` ("mirror venv-python fix on dev-team source"), which copied the tap helper back to dev but mis-typed the path in the process. Same shape as the `CLAUDE.md` tracked-vs-live drift pattern: a tap→dev sync silently regressed the dev source.
- **Acceptance** — `ls $HOME/dev-team/iterm2_window_manager.py` resolves; next Academy team startup creates the LCARS tab on the first attempt with no retry warnings.

### Feat: XACA-0479 — Auto-restart team LCARS server in post-merge hook (opt-in)

- **`scripts/hooks/post-merge`** — New `LCARS_PREFIXES` array (`lcars-ui/`, `lcars-hooks/`, `fleet-monitor/server/`) that gates the new restart branch. These prefixes are deliberately NOT added to `DEPLOYABLE_PREFIXES` because `deploy-to-production.sh` does not install lcars sources — including them there produces a no-op deploy run with confusing output.
- **`scripts/lcars-restart-helpers.sh`** (new) — Houses `detect_active_lcars_team` and `restart_team_lcars`. Sourced by the hook; uses `$repo_root` from the calling scope to locate `scripts/lcars-launch-helpers.sh`.
- **`detect_active_lcars_team`** — Returns the active team slug via three-tier detection: (1) `$LCARS_TEAM` env var (slug-validated against `[a-z0-9-]+`), (2) newest `/tmp/lcars-<team>-<port>.log` whose `server.py` process is still alive (`pgrep`-verified, slug + port both validated), (3) empty stdout + advisory to stderr (no-op).
- **`restart_team_lcars <team>`** — Resolves port from `~/dev-team/lcars-ports/<team>-lcars.port`, validates it as digits-only, emits a 3-second Ctrl-C cancellation window, then delegates to `start_lcars_server` from `scripts/lcars-launch-helpers.sh`.
- **Opt-in gate:** `CLAUDE_LCARS_AUTORESTART=1` — default off because restart drops browser sessions. When unset and LCARS files changed, a single hint line is printed with the manual restart command.
- **Worktree gate:** `git rev-parse --git-common-dir` check — restart is skipped silently when the hook runs from a feature worktree.
- **Never blocks the merge:** `restart_team_lcars` failure is caught with `|| true`; the hook always exits 0.

### Feat: XACA-0498 — Installer guard parity: `TEAM_WORKING_DIR=$HOME/<team>` protection

- **`homebrew-tap` submodule bump → `fbbef24`** — Adds a second installer guard to `libexec/installers/install-team.sh` (after the XACA-0485 augmentation block, before any filesystem writes). Refuses installation when, on a dev-source machine, the resolved `TEAM_WORKING_DIR` is a direct child of `$HOME` AND there is no path containment in either direction with `AITEAMFORGE_DIR`. Detection signal: `$HOME/dev-team/.aiteamforge-source-tree` sentinel (shipped in XACA-0497). Closes the parallel-writer gap that re-created `~/academy` on 2026-05-12 — XACA-0497's guard only covered the `AITEAMFORGE_DIR` vector (writer 1: `generate_per_agent_startup_scripts`); this guard adds the `TEAM_WORKING_DIR` vector (writer 2: persona refresher / board writer).
- **`homebrew-tap/tests/test-xaca-0498-twd-guard.sh`** (new) — 5-case sandbox harness: preflight + Branch A (DENY: sentinel + depth-1 `TEAM_WORKING_DIR`) + Branch B (ALLOW: Command monorepo, AITF inside TWD) + Branch C (ALLOW: no sentinel — end-user machine) + Branch D (ALLOW: depth-2 project team). All assertions use `TEST_TMP_DIR` sandboxing with canonical (`pwd -P`) path resolution; never touches real `$HOME` paths. Pre-populates `$HOME/.aiteamforge/organization.yaml` since the org-config check at line ~306 fires before the new guard.
- **Decision-matrix verification** — Guard rule checked against all 9 team confs (`academy`, `android`, `ios`, `firebase`, `command`, `finance`, `freelance`, `legal`, `medical`). Depth-1 stub paths (`$HOME/academy`, `$HOME/android`, `$HOME/ios`, `$HOME/firebase`) DENY on M3Pro; depth-2 project-augmented paths (`$HOME/finance/personal`, `$HOME/medical/general`, `$HOME/legal/default`, `$HOME/freelance/<client>/<project>`) ALLOW. Command (`$HOME/dev-team`) DENIES by default — must be installed with `AITEAMFORGE_DIR` inside `$HOME/dev-team` for the legitimate monorepo case, matching the existing pattern.
- **Context** — XACA-0497's retrospective ("Multiple installer writers, single guard fixed only one") and the academy-stub forensic doc ("Recommendations for follow-up" #2) both documented this gap as a known follow-up. The 2026-05-12 stub had been created three weeks after XACA-0219's "final" cleanup of the same path. Two writers, one guard, partial coverage. This ticket closes the parity gap.

### Fix: XACA-0482 — kb-release-create team-port routing + kb-show zsh `$status` collision

- **`kanban-helpers.sh` — new `_kb_team_lcars_port()` helper (line ~11287)** — Single source of truth for team→LCARS port mapping. Tries `aiteamforge_team_lcars_port` first (canonical loader from XACA-0168), falls back to a built-in `case` table mirroring the per-team ports (ios=8260, android=8280, firebase=8240, academy=8203, dns=8180, freelance variants, command/mainevent=8234, liquidstyle agentbadges 8960/8970). Returns non-zero with no output for unknown teams so callers can decide whether to fall back or hard-fail.
- **Three call sites refactored to use `_kb_team_lcars_port`** — `_kb_release_sync` (line 705), `kb-restart` (line 11161), `kb-release-sync-board` (line 11705). Each previously held its own copy of the port table; any change required a 3-place sync that was easy to miss. Refactor replaces ~22-line inline blocks with 4-line helper calls. No behavior change — output messages and fallback semantics preserved.
- **`kb-release-create` refactored (~lines 11402–11464)** — Was hardcoded to `http://localhost:8080/api/releases` (Academy LCARS) and omitted `team` from the POST payload entirely. Non-Academy callers got releases that landed on the Academy board, were tagged `firebase` by the server default, and became unfindable by `kb-release-list`/`kb-release-assign` from the caller's team. Now: derives caller's team via `_kb_detect_context`, resolves port via `_kb_team_lcars_port`, POSTs to `http://localhost:${port}/api/releases` with `team: $team` in the JSON payload. Success message now reports the team + port the release landed in for operator transparency. Error message on connection failure includes the actual port that was attempted, not the misleading 8080.
- **`kb-show` `$status` collision fixed (lines 10777–10784)** — `for status in "${statuses[@]}"` failed under zsh because `$status` is a zsh read-only special parameter (alias for `$?`). Function would print the header then die with `kb-show:21: read-only variable: status`. Renamed loop variable to `item_status` throughout the loop body; bash unaffected.
- **Zsh-special variable audit (`status`, `path`, `pwd`, `cdpath`, `manpath`, `fpath`, `fignore`, `mailpath`, `psvar`, `signals`, `argv`, `pipestatus`, `LINENO`, `RANDOM`, `SECONDS`, `EPOCHSECONDS`, `HISTCMD`, `OLDPWD`)** — Clean. Zero other collisions in `kanban-helpers.sh`. The `$status` in `kb-show` was the only instance.
- **Origin:** Handed off from Android team (Dr. McCoy) after both bugs surfaced during the v2.11.3 hotfix workflow (XAND-0656). Source trackers XAND-0659 + XAND-0660 cancelled; transferred to Academy via `/Users/Shared/Development/Main Event/dev-team/handoff/Academy_kanban_helpers_infra_bugs.md`. Both bugs had inline workarounds (`curl` direct-POST + `jq` direct-query) but bit every non-Academy team on every use.
- **Acceptance:** Helper resolves 7+ teams correctly; unknown teams return rc=1; `kb-show <ITEM>` runs cleanly under zsh with no read-only error; `kb-show` output unchanged from prior bash behavior; `zsh -n kanban-helpers.sh` passes. Pre-existing `bash -n` failure at line 9015 (`(.DN)` zsh glob qualifier) confirmed present on develop — not introduced by this branch.
- **Hardened `_kb_team_lcars_port` to require numeric output from `aiteamforge_team_lcars_port` before trusting it; non-numeric output (error strings, debug noise) now falls through to the built-in case table instead of reaching `curl` with garbage and producing an opaque error (XACA-0482-010 [Review] follow-up, PR #408).**

### Feat: XACA-0497 — Dev-source protection guard + logo canonicalization

- **`.aiteamforge-source-tree`** (new sentinel at repo root) — Marks this directory as the AITeamForge dev-team source-of-truth. Read by the installer guard added to `homebrew-tap` in this commit; refuses installation when `AITEAMFORGE_DIR` resolves to a directory containing this file.
- **`homebrew-tap` submodule bump → `3c86964`** — Adds the dev-source protection guard to `libexec/installers/install-team.sh` (after arg parsing, before any filesystem writes). Two-test coverage: positive (aborts with clear message when `AITEAMFORGE_DIR=<dev-tree>`) and negative (clean `mktemp -d` target proceeds normally).
- **`fleet-monitor/server/public/avatars/{academy,freelance}_*_logo.png`** (13 files overwritten) — Synced from canonical `<team>/terminals/logos/` versions per source-of-truth decision: logos in the `~/dev-team/` team-folder tree are originals; fleet-monitor copies are deployment-ready derivatives. Affected: 5 academy (chancellor, engineering, lcars, medical, training) + 8 freelance (command, comms, engineering, helm, lcars, science, sickbay, tactical) section logos.
- **Context** — XACA-0489's develop-sync cleanup recovered 95 untracked files from an installer-rendered pollution event (Brunt script header `AITEAMFORGE_GENERATED_VERSION=0.11.7`). Root cause: `AITEAMFORGE_DIR=/Users/darrenehlers/dev-team` was exported in the dev shell environment, inherited by `install-team.sh`, overrode the safe `:-$HOME/aiteamforge` default. Existing `TEAM_WORKING_DIR` guard at line 596 did not protect this code path. All 95 snapshot files triaged as DISCARD across four research subagents (subitems 001–004): 6 finance startup scripts (installer-generated, no precedent for tracking), 20 `.port`/`.order`/`.theme` files (no consumer — `get_team_lcars_port()` only looks up `<prefix>-lcars.port` after suffix-strip), 64 PNGs (0 genuinely new; 63 byte-dups of fleet-monitor, 6 byte-dups of `<team>/terminals/logos/`). The 13 logo divergences synced in this commit existed pre-snapshot (not introduced by the pollution event) and were reconciled here for hygiene.
- **Snapshot branch `feature/xaca-0497-per-persona-assets`** is being deleted as part of this PR — every byte was either already tracked elsewhere or installer-generated derivative.

### Docs: XACA-0493 — Rewrite team-transfer RUNBOOK.md for new 7-channel design

- **`docs/team-transfer/RUNBOOK.md`** — Major rewrite (336 → 498 lines) restructured around the 7-channel architecture that landed in XACA-0488 and the auto-generated `PRE_EXPORT_CHECKLIST.md` from XACA-0490. Replaced the legacy "What each channel covers" table with five detailed per-channel sections (`aiteamforge_product`, `user_state`, `export_kanban`, `export_database`, `secrets_export`), each documenting *what files it covers / tool or command that carries it / what the verifier checks / how to remediate failures*. Renamed all deprecated channel mentions (`aiteamforge` → `aiteamforge_product`; `export` → `export_kanban` / `export_database`) in config examples, generator output samples, per-channel verifier-report samples, and onboarding bullets. Added "Reading PRE_EXPORT_CHECKLIST.md alongside this runbook" anchor subsection clarifying the concept-vs-current-export split between runbook and generated checklist. Added "## Troubleshooting — failure modes from the M3Pro→M1Pro migration" section catalogging the five real incidents that drove XACA-0487 through XACA-0491 (`.git/` false-positives, `aiteamforge` product/user_state conflation, path layout mismatch, ambiguous non-git transport, secrets-import double-nesting), each follows Symptom → Root cause → Diagnosis → Fix. Updated `--path-map` references from "pending" to shipped. Collapsed the obsolete Roadmap section into "Recently completed milestones".
- **`kanban/XACA-0493_runbook_rewrite_RETROSPECTIVE.md`** (new, in main repo not worktree) — 104-line retrospective documenting subitem flow, the secrets-section-as-template generalization, parallel subagent delegation pattern, and reverse-engineering of the implicit "5 failure modes" from sibling tickets.
- **Knowledge:** Captured three reusable patterns — K114 (section-as-template), K115 (concept-vs-instance documentation), K116 (reverse-engineer implicit lists from sibling tickets).
- **No code changes.** Docs-only.

### Feat: XACA-0490 — Migration generator emits PRE_EXPORT_CHECKLIST.md

- **`lcars-ui/team_transfer/checklist.py`** — New module. `emit_pre_export_checklist()` renders `PRE_EXPORT_CHECKLIST.md` from a finalized `Manifest` object: auto-channel summary table, and per-section operator instructions for `export_database` (LCD-rsync), `secrets_export` (per-file scp; always emitted, zero-file variant when channel is empty), and `user_state` (two rsync commands split on `.claude/projects/` vs `knowledge/agents/` prefix). Stdlib-only; deterministic output. The secrets_export section (both variants) carries an explicit "no secret values in filenames" warning — ZIP central-directory entries are not encrypted.
- **`lcars-ui/team_transfer/generator.py`** — Calls `emit_pre_export_checklist()` immediately after writing the manifest JSON. Writes `PRE_EXPORT_CHECKLIST.md` alongside the manifest in the same `docs/migration/` directory. Skipped when `--output` is outside `$HOME` (temp/CI path), consistent with the existing self-entry guard.
- **`lcars-ui/team_transfer/checksum.py`** — Added `**/docs/migration/PRE_EXPORT_CHECKLIST.md` to `ALWAYS_EXCLUDE_GLOBS`. The checklist is generator-owned derived output; without this exclusion, a prior run's checklist would be swept up by `domain_git` on the next run and pollute the manifest. Surfaced by `test_generator_checklist_not_in_manifest`.
- **`docs/team-transfer/RUNBOOK.md`** — Updated to reference the generated checklist; simplified the "Pre-export checklist — Secrets channel" section to point to the generated file (single source of truth); marked XACA-0490 as DONE in the roadmap.
- **`lcars-ui/tests/team_transfer/test_migration_checklist.py`** — New: 42 tests covering happy-path emission, channel inclusion policy (including `secrets_export` always-emit), `user_state` two-tree split logic, deterministic byte-identical output, representative-paths cap with Unicode ellipsis (`… and N more.` per spec §10 note 6), thousands-separator byte formatting, generator-level skip-when-output-outside-HOME, no self-reference in the manifest, UTF-8 + trailing newline, and the "no secret values in filenames" warning in both secrets_export variants.

### Test: XACA-0492 — Add synthetic-migration end-to-end integration test

- **`lcars-ui/tests/team_transfer/conftest_synthetic_e2e.py`** (new) — Synthetic source topology covering all 7 migration channels (`git`, `export_kanban`, `export_database`, `secrets_export`, `aiteamforge_product`, `user_state`, `icloud_excluded`). Provides helper builders for each subtree (kanban dir, secrets dir, knowledge tree, git repo fixture, team YAML config, sqlite3 db fixture). Fully isolated via `tmp_path`.
- **`lcars-ui/tests/team_transfer/test_synthetic_migration_e2e.py`** (new) — 1 golden-path round-trip test (`test_synthetic_e2e_golden_round_trip`): runs generator subprocess → in-process `_destructive_move` → verifier with `--path-map SRC=DST` (XACA-0489). 9 fault-injection tests assert the verifier MUST detect: missing EXACT-class file, missing SCHEMA-class file, SHA mismatch, layout drift, schema probe drift, database probe drift, secrets partial move, missing path-map, and PRESENT-class removal.
- **Why:** The 36 XFIN-0019 unit tests exercised components in isolation but never ran the full generator → move → verifier pipeline. That gap is how the M3Pro→M1Pro design-flaw class survived unit testing and shipped. 84 team_transfer tests passing (was 75), no regressions.

### Fix: XACA-0496-018 — Exclude SQLite WAL/SHM sidecars from manifest

- **`lcars-ui/team_transfer/checksum.py`** — Added `**/*.db-shm` and `**/*.db-wal` to `ALWAYS_EXCLUDE_GLOBS`. SQLite sidecars are transient state regenerated when the database is reopened on the destination; they were tripping XACA-0488's new `export_database` channel-class invariant (which requires `cls=schema`) because they naturally fall into `cls=present`. Surfaced by the E2E round-trip introduced in this PR: 2 spurious FAILs per export → 0 after the fix.
- **`lcars-ui/tests/team_transfer/test_migration_domains.py`** — Extended `test_excluded_paths_skipped` to assert the sidecar exclusion plus a positive case that `*.db` itself is NOT excluded (must stay in the manifest).

### Fix: XACA-0496-012/013/017 — Generator dedup, self-entry temp-path skip, server.py smoke tests

- **`lcars-ui/team_transfer/generator.py`** — Added `_dedupe_cross_domain()`: walks domains in priority order (claude > knowledge > kanban > devteam > git_repo), drops file entries whose `path` was already claimed by a higher-priority domain. Fixes XACA-0496-012 where a file claimed by both `git_repo` (broad sweep) and a specific domain (e.g. `knowledge`) appeared twice in the manifest, producing a `zipfile.UserWarning` at package time.
- **`lcars-ui/team_transfer/generator.py`** — Guard the self-entry block on `out.relative_to(home)`. When `--output` is outside `$HOME` (e.g. `/tmp/foo` in a CI run), the self-entry is skipped with an info line. Fixes XACA-0496-013 where the temp manifest path got embedded as a `PRESENT`-class entry; the verifier — which checks files at destination `$HOME` — would always produce a spurious FAIL on same-machine round-trips because the temp file had been cleaned up before verification.
- **`lcars-ui/tests/team_transfer/test_xaca_0496_server_integration.py`** — New: 5 smoke tests covering the XACA-0496-004/005 server.py integration paths. Exercises the same `team_transfer.generator → team_transfer.verifier` subprocess chain that `generate_export` uses; validates the regex contract used to parse PASS/WARN/FAIL counts into `verifierSummary`. Closes XACA-0496-017.
- **`lcars-ui/tests/team_transfer/test_migration_verifier.py`** — Updated `test_generator_self_includes_manifest_in_output` to match the new contract: split into `_when_under_home` (asserts self-entry IS present) + `_skips_self_entry_when_output_outside_home` (asserts the new skip). Added `test_generator_dedupes_cross_domain_duplicates` (XACA-0496-012 regression guard).
- **E2E impact:** kb-team-export → kb-team-import round-trip on finance now yields 312 PASS / 0 WARN / 0 FAIL / exit 0 (previously 313 PASS / 0 WARN / 1 FAIL / exit 1).

### Fix: XACA-0496-014/015/016 — PR #401 review feedback

- **`scripts/kb-team-import`** — Wired `--force` to actually distinguish WARN-only verifier runs from clean PASS runs. The verifier output is now `tee`'d through a temp file and parsed for `WARN: N` / `FAIL: N` counts; default exit is now `1` when WARNs are present with no FAILs (per the documented exit-code surface), and `--force` correctly suppresses that to `0`. Previous behavior matched the help text only by accident because the verifier never produced exit `1` for WARN-only runs. Toggle of `pipefail` around the `tee` pipe keeps `set -euo pipefail` from aborting before `PIPESTATUS[0]` can be captured.
- **`scripts/kb-team-import`** — Added defense-in-depth zip entry-name validation in the Python extraction block: entries with absolute paths, `..` segments, or Windows drive letters are skipped with a stderr WARN. Python's `zipfile` already sanitizes these as of 3.6.2, but the explicit guard surfaces malicious archives in the log and catches future regressions.
- **`lcars-ui/server.py`** — Removed redundant `import re` inside the `XACA-0496-004` block in `generate_export`; the module-level `import re` at line 29 was already in scope.

### Feat: XACA-0496-001/002/003/006 — Zip packaging/extraction in kb-team-{export,import}; --dry-run/--force flags

- **`scripts/kb-team-export`** — Replaced "Step 3: File packaging (STUB)" with real implementation: walks `manifest.domains[*].files`, skips entries with `channel == "icloud_excluded"`, and packs remaining files using Python's `zipfile.ZIP_DEFLATED` (no dependency on system `zip` binary). Embeds `manifest.json` at the archive root. Skipped/missing source files emit a WARN to stderr; skipped count is surfaced in the final summary line (`Files packed: N (skipped: M)`). Progress indicators print every file for archives <=200 files; every 25th file (+ first + last) for larger archives.
- **`scripts/kb-team-import`** — Replaced "Archive mode (STUB)" block with real extraction: unpacks the archive to a `mktemp -d` staging directory using Python's `zipfile` module, reads `manifest.json` from the archive root, then runs the verifier against it. Staging directory is removed on EXIT via `trap`. Default mode is verify-only. Added `--dry-run` flag (explicit verify-only; no placement — forward-compatible with future placement code) and `--force` flag (exit 0 when only WARNs found; FAIL always exits 2). Both flags added to argparse and usage text. Per-file extraction progress uses same 25-file throttle as export.

### Feat: XACA-0496-004/005 — Embed team_transfer manifest + verifier in export/import HTTP endpoints

- **`lcars-ui/server.py` (`generate_export`)** — After the main zip is written, appends `team_transfer/manifest.json` (generated via `team_transfer.generator`) and `team_transfer/verifier-report.txt` (captured from `team_transfer.verifier`) as supplementary audit artifacts. Exposes a `verifierSummary` block (exit code, PASS/WARN/FAIL counts, embedded paths) in subsequent `GET /api/export/status/<job_id>` responses. All team_transfer steps are resilient — any failure sets `verifierSummary.error` and logs a WARN; the core export is never affected. Handles derived team IDs (e.g. `finance-personal`) by falling back to `base_team` if no per-team YAML config is found for the full `team_id`.
- **`lcars-ui/server.py` (`handle_import_upload`)** — When a `team_transfer/manifest.json` is present in the uploaded archive, auto-extracts it to a temp dir and runs the verifier. Returns a `teamTransferVerifierSummary` field alongside the existing pre-flight JSON (exit code, PASS/WARN/FAIL counts, last-20-lines tail for UI display). Legacy archives without `team_transfer/manifest.json` return `{"present": false}` — no failure. Also stores the summary in the in-memory `IMPORT_JOBS` dict for later status polling.

### Feat: XACA-0488 — Migration channel redesign: split aiteamforge → product+user_state, split export → kanban+database

- **`lcars-ui/team_transfer/channels.py`** — Two channel splits land. `aiteamforge` → `aiteamforge_product` (installer-carried product files, e.g. `~/dev-team/<team>/*` and `~/finance/.claude/agents/*`) plus `user_state` (NOT carried by installer: `~/.claude/projects/<UUID>/memory/`, session `.jsonl`, `~/knowledge/agents/<persona>/`). `export` → `export_kanban` (tool-carried kanban/worktrees state) plus `export_database` (`data/*.db` requiring explicit `scp`/`rsync` per runbook). Deprecated aliases `AITEAMFORGE` and `EXPORT` remain as module-level `__getattr__` shims that emit a one-shot `DeprecationWarning` on first access; aliases drop next sprint.
- **`lcars-ui/team_transfer/verifier.py`** — `_CHANNEL_CLASS_INVARIANTS` enforces per-channel cls semantics in `_check_one`: `aiteamforge_product = {present}` (installer mutates these on dest; SHA would false-FAIL), `user_state = {exact, present}` (mixed: EXACT for authored memory/knowledge, PRESENT for churning session logs), `export_kanban = {exact, present, schema}` (EXACT for authored EPIC-*.md/retros/plan docs, PRESENT for locks, SCHEMA for board JSON), `export_database = {schema}` (DB structural probe only). Misclassified manifest entries fail fast with a clear channel-class violation message instead of producing confusing downstream SHA-mismatch reports.
- **`lcars-ui/team_transfer/config/finance.yaml`** — Rules rewritten in place to use new channel names; back-compat aliases ensure existing tests/external callers still resolve until next sprint's alias drop.
- **`lcars-ui/team_transfer/config/CHANNELS.md`** — New reference doc: channel taxonomy table, per-channel verifier semantics, decision tree for authoring new team yamls, migration recipe, and operator runbook deltas (explicit `rsync --exclude='*.jsonl'` for `user_state`; explicit `scp`/`rsync` for `export_database`).
- **Domain modules** (`domain_devteam`, `domain_claude`, `domain_knowledge`, `domain_kanban`, `domain_git`) updated to route entries to the new channel constants. `domain_git.py`'s dead `EXPORT` import dropped.
- **Tests** (`tests/team_transfer/test_migration_channels.py`, `test_migration_verifier.py`) — 3 renamed (legacy `_to_export` → split-specific names), 9 new resolution tests, 7 verifier invariant tests covering accept/reject for each new channel + git no-constraint baseline. 53 tests passing, zero failures.
- **Why:** Conflated channels masked which kind of migration failure actually occurred (database FAIL and board-JSON FAIL have completely different recovery paths). Splitting also unblocks a clean operator runbook with explicit per-channel manual steps for paths the installer does not carry. Closes XACA-0488 (Issues #1 + #2). See `kanban/plans/XACA-0488/ADR-channel-split.md` for the decision record.

### Docs: XACA-0491 — Document secrets_export channel intent + scp transport shape in runbook

- **`lcars-ui/team_transfer/channels.py`** — Added comment block on `SECRETS_EXPORT` constant explaining it is real and load-bearing, that transport is operator-driven scp (not git-bundled), and that `secrets/test-secrets.txt` is an intentional end-to-end path validator, not dead code.
- **`docs/team-transfer/RUNBOOK.md`** — Added "Secrets Channel (secrets_export)" section covering: when to use it vs dotenv, the scp command shape for seeding real material before export, encryption contract (AES-256 / separate bundle / metadata visibility), and a pre-export checklist for the channel.
- **`.gitignore`** — Added `/secrets/` and `/.scratch/` so operator-seeded secret material (the channel's staging area) and per-ticket scratchpad diagnosis docs cannot be accidentally committed. Confirmed no existing tracked file lives under either path.
- **Why:** The channel had exactly one file in production with no explanation, making it indistinguishable from dead code. This commit records the deliberate design decision (XACA-0491) so future operators and maintainers understand the transport surface.

### Fix: XACA-0491 — Correct secrets-import double-prefix bug (secrets/secrets/ → secrets/)

- Fix secrets-import double-prefix bug — files now extract to `./secrets/*` instead of `./secrets/secrets/*` (XACA-0491).
- **`lcars-ui/secrets_export_lib.py`** — Auto-detect branch of `discover_secrets_sources()` now returns `target=""` instead of `target="secrets"`. `target_root` already encodes the `"secrets/"` prefix; `target` is a subpath *under* `target_root`, not a repeat of it.
- **`lcars-ui/secrets_export_lib.py`** — Added defensive warning in `validate_secrets_manifest()`: warns when any `sources[].target` value duplicates `targetRoot`, catching the same footgun in operator-written manifests before it produces corrupt archive paths.
- **`lcars-ui/server.py`** — Arc-name builder (lines 711–718) now computes `arc_prefix` cleanly when `target_rel` is empty, avoiding `"secrets//file.txt"` double-slash on auto-detect paths.
- **`lcars-ui/tests/test_secrets_export_lib.py`** — New regression test `test_discover_secrets_sources_auto_detect_target_is_empty` asserts `target == ""` post-fix.
- **`lcars-ui/tests/test_secrets_workers.py`** — New end-to-end regression test `TestExportImportNoDoublePrefix.test_round_trip_no_double_prefix` builds a real `secrets/` source tree, exports it, verifies arc names in the zip are `"secrets/<file>"` (not `"secrets/secrets/<file>"`), imports into a fresh project root, and asserts extracted files land at `<root>/secrets/foo.txt` and `<root>/secrets/sub/bar.txt` — and that `<root>/secrets/secrets/` does NOT exist.

### Feat: XACA-0489 — Add `--path-map SRC=DST` flag to migration verifier (cross-layout verification)

- **`lcars-ui/team_transfer/verifier.py`** — New `--path-map SRC=DST` CLI flag (multiple allowed, stdlib-only). Each mapping is a path-prefix rewrite applied to manifest entries before any filesystem check; mappings apply in order with first-match-wins. The existing home-prefix rewrite remains as a fallback when no `--path-map` matches, so single-machine runs are unchanged. The report header now prints one `Path map: SRC -> DST` line per mapping for run-log visibility.
- **Module docstring** — Documented the two canonical machine layouts (M3Pro dev `~/dev-team/<team>/...` vs. user-machine tap install `~/aiteamforge/<team>/...` plus `~/<team>/personal/personas/`) with a worked `--path-map` example for translating between them. Future channel-rule authors can encode the layout difference from this reference.
- **Why:** Manifests captured on the M3Pro dev source-of-truth contain absolute `/Users/.../dev-team/<team>/...` paths that don't exist on M1Pro user machines running the AITeamForge tap, where the equivalent content lives under `~/aiteamforge/<team>/`. The verifier previously reported everything missing on cross-layout runs. `--path-map` bridges the two layouts without requiring per-team config or breaking single-machine workflows. Closes Issue #3 against the migration toolkit promoted in XACA-0495.
- **Testing** — 7/7 functional cases pass (help text, malformed rejection, first-match ordering, fallback behavior, no-match passthrough, multi-mapping headers, default-empty equivalence). Existing 37-test suite in `lcars-ui/tests/team_transfer/` still green. **PR #398 review pass** added 10 unit tests in `test_migration_verifier.py` (TestPathMap class) covering single-map, first-match-wins, no-match passthrough, malformed-rejection (rc=2), DST-with-`=`, home-prefix fallback, multi-map, default-empty, and trailing-slash normalization. Total suite: 47 passing. Also: trailing-slash normalization (`rstrip("/")` on both SRC and DST at parse) so `/foo/=/bar`, `/foo=/bar`, and `/foo/=/bar/` are equivalent; report header refactored to a single `=== ACTIVE REWRITES ===` block that only prints when at least one rewrite is active.
### Feat: XACA-0495 — Promote migration toolkit from finance_platform → dev-team (team-agnostic audit suite)

- **`lcars-ui/team_transfer/`** — New package: 12-module migration audit toolkit promoted from `finance_platform.migration`. Flat module layout with no dependencies on Finance-specific code. Toolkit audits multi-team exports (file manifest, channel-rule application, database integrity opt-in). 37 tests passing at new home (`lcars-ui/tests/team_transfer/`): 36 carried over from finance + 1 new `.git/` exclusion regression test for XACA-0487.
- **`lcars-ui/team_transfer/config/<team>.yaml`** — Per-team channel-rule schema introduced. `finance.yaml` shipped as the worked example; teams opt into feature-block scanning, message-channel mapping, and optional database-integrity audits via the `databases:` block (omit if no database). Finance CHANGELOG updated in companion PR; see `~/finance/personal/CHANGELOG.md` Unreleased section.
- **`docs/team-transfer/RUNBOOK.md`** — Operational runbook for running exports and validating rule application. Covers single-team and multi-team scenarios, error interpretation, and rollback procedures.
- **`docs/team-transfer/CONFIG_SCHEMA.md`** — Complete reference for `config/<team>.yaml` structure: channel-rules subsection (glob patterns, merge strategies, skip-heuristics), database block semantics, and worked example from finance.yaml.
- **`scripts/kb-team-export` and `scripts/kb-team-import`** — Shell helper wrappers that auto-run manifest generation and verification. Stub-level implementation; full packaging (zip bundle creation, HTTP endpoint integration) deferred to XACA-0496 on EPIC-0035.
- **Fixed: XACA-0487** — `.git/` directories were previously included in migration file walks, causing ~281 false-positive SHA256 mismatches when file copies were validated on fresh-clone destinations. `**/.git/**` and `**/.git` now excluded in `ALWAYS_EXCLUDE_GLOBS`; regression test added.
- **Changed** — `db_integrity.py` is now opt-in via the team YAML `databases:` block. Teams without a database simply omit the block. Previously hardcoded against `finance.db`.
- **Why:** Closes EPIC-0035 Phase 1 (audit toolkit promotion). Finance migration feature is now agnostic to team structure, allowing expansion to other parametric teams (medical/legal/freelance) without code duplication. XACA-0487 fix prevents false-alarm SHA256 mismatches on fresh-cloned destinations. XACA-0496 (deferred to Phase 2) will complete the export/import packaging and HTTP integration.

### Fix: XACA-0494 — Address PR #396 review subitems 009-012

- **`tests/test-xaca-0494-banner-defensiveness.sh`** — T4 temp file renamed to `/tmp/xaca0494_t4_stderr.$$.txt` (PID suffix) to prevent collision when parallel CI runners share the same machine (009). Added `cleanup_test_artifacts()` function with `trap ... EXIT INT TERM` to remove `FAKE_HOME` and `T4_STDERR` at test exit, preventing cruft accumulation on CI runners (010).
- **`.github/workflows/banner-defensiveness.yml`** — Added `.github/workflows/banner-defensiveness.yml` to the `push:develop` paths filter; previously a workflow-only push to develop would not re-trigger the test (011).
- **`finance/scripts/finance-banner.sh`**, **`medical/scripts/medical-banner.sh`**, **`legal/scripts/legal-banner.sh`** — Normalized unconditional `source ~/dev-team/worktree-helpers.sh` to the guarded pattern (`if ! command -v wt-current >/dev/null 2>&1; then source ...; fi`) used by ios/academy/command/dns banners. Source becomes a no-op if `wt-current` is already in scope from a parent shell (cheaper, idempotent) (012).

### Chore: XACA-0494-005 — Bump homebrew-tap submodule to v0.11.11

- **`homebrew-tap`** submodule pointer advanced from v0.11.10 (0db72a0) to v0.11.11 (764380b). Bundled with the PR so dev-team CI resolves the new tap files (worktree-helpers.sh, legal-banner.sh stubs, env loader source line) on first run rather than requiring a separate post-merge bump commit.

### Fix: XACA-0494-004 — Close legal-banner defensive-guard gap in tap; wire CI

- **`homebrew-tap/share/scripts/teams/legal/scripts/legal-banner.sh`** — Added missing defensive stubs for `wt-current` and `wt-project` (same two-line guard already in medical/finance/freelance tap banners). Caught by regression test T5-tap-legal. Now all four tap banners (finance, freelance, medical, legal) are uniformly guarded.
- **`.github/workflows/banner-defensiveness.yml`** — New dev-team CI workflow that runs `tests/test-xaca-0494-banner-defensiveness.sh` on every PR and develop push touching team banners, tap banner copies, worktree-helpers.sh, or the test itself. Stages repo at `$HOME/dev-team` (symlink) so tap-path and dev-team-path references resolve without installation.

### Test: XACA-0494-003 — Regression coverage for banner wt-helper defensiveness

- **`tests/test-xaca-0494-banner-defensiveness.sh`** — New regression test suite (300 lines, 33 cases) asserting:
  - `worktree-helpers.sh` ships in the tap and defines `wt-current()` and `wt-project()`
  - `install-shell.sh` calls and defines `install_worktree_helpers()`
  - `aiteamforge-env.sh` sources `worktree-helpers.sh` after `worktree-aliases.sh` (ordering check)
  - `wt-project` init messages ("Project context set", "Base:", "Worktrees:") appear in STDERR, not STDOUT
  - Every shipped banner (11 dev-team + 4 tap) survives `PATH=/usr/bin:/bin` with zero `wt-*` command-not-found errors
  - `wt-project status-name` returns exactly one clean line on stdout after full env load
- **Finding:** T5-tap-legal FAILS — `homebrew-tap/share/scripts/teams/legal/scripts/legal-banner.sh` is missing the `command -v wt-current` defensive guard that was added to medical/finance/freelance in tap commit 74b2c61. Requires a follow-up tap fix before this test can be marked green.

### Fix: XACA-0494 — Tap-ship worktree-helpers.sh + harmonize banner defensive guards

- **`homebrew-tap/share/scripts/worktree-helpers.sh`** — Added: full worktree-helpers.sh now ships in the tap installer payload. Provides `wt-current`, `wt-project status-name/code/short`, and all wt-* functions that team banners call. Previously absent from the tap; only `worktree-aliases.sh` (which lacks `wt-current` and the `status-*` subcommands) was shipped.
- **`homebrew-tap/libexec/installers/install-shell.sh`** — New `install_worktree_helpers()` function copies `share/scripts/worktree-helpers.sh` to `$AITEAMFORGE_DIR/worktree-helpers.sh` during shell install. Non-fatal (banners fall back to stubs if file missing).
- **`homebrew-tap/share/templates/aiteamforge-env.sh`** — Added: sources `$AITEAMFORGE_DIR/worktree-helpers.sh` after `worktree-aliases.sh` so the full `wt-project` (with status-* subcommands) overrides the minimal alias version.
- **`homebrew-tap/share/templates/aliases/worktree-aliases.sh`** — Fixed: bare `wt-project()` init messages (3 lines) now redirect to stderr (`>&2`) instead of stdout, stopping banner layout corruption when banners call `wt-project status-name` in a subshell.
- **`homebrew-tap/Formula/aiteamforge.rb`** — Added: `assert_predicate` test for `share/scripts/worktree-helpers.sh` to catch future regressions.
- **Dev-team banners** — Harmonized defensive guards across all 7 previously-unguarded or partially-guarded banners:
  - `ios-banner.sh` — Added source guard + stubs
  - `firebase-banner.sh`, `android-banner.sh`, `command-banner.sh`, `dns-banner.sh`, `academy-banner.sh` — Added stubs (already had source guard)
  - `mainevent-banner.sh` — Added stubs (already had source guard + USE_WORKTREE gate)
- **Tap banners** — Added stubs to `medical-banner.sh`, `finance-banner.sh`, `freelance-banner.sh` in `homebrew-tap/share/scripts/teams/`
- **Why:** M1Pro tap installs fail at banner-launch time with `command not found: wt-current` / `command not found: wt-project` because the tap installer never shipped worktree-helpers.sh. Smoke tests now pass with simulated minimal PATH (no dev-team on PATH).
### Chore: Bump homebrew-tap submodule to v0.11.10

- **`homebrew-tap`** — Bumped pinned pointer to `0db72a0` (tag `v0.11.10`). 0.11.10 ships the venv-path correction for XACA-0486 that M1Pro smoke caught (the p071 gate working as designed). `start_lcars_server` now sources `$(brew --prefix)/var/aiteamforge/env.sh` and uses `$AITEAMFORGE_PYTHON` (canonical Formula contract) instead of the wrong-path `libexec/venv` from 0.11.9.
- **Why:** M1Pro 0.11.9 install passed venv-resolution structurally (tests green) but the path `${brew --prefix aiteamforge}/libexec/venv/bin/python3` didn't actually exist — the Formula installs the venv at `${HOMEBREW_PREFIX}/var/aiteamforge/venv`. Without the p071 smoke gate, this would have been XACA-0487 chained off XACA-0486. Instead, fix landed as 0.11.10 follow-up inside the original ticket.
- **XACA-0486 chain closed:** XACA-0460 → 0483 → 0484 → 0485 → 0486 install-side install-time contract chain ended (p072 documents the smoke-gate validation).

### Chore: Bump homebrew-tap submodule to v0.11.9

- **`homebrew-tap`** — Bumped pinned pointer to `3bd9bcb` (tag `v0.11.9`). 0.11.9 packages XACA-0486 which fixes (a) LCARS server launching with brew venv python instead of bare python3 (so requirements.txt deps reach runtime), and (b) board field semantics matching academy-board.json model (teamName=brand-upper, organization=template-id-upper, subtitle=theme-upper). XACA-0484 migration extended to detect duplicate-brand bug and re-derive. medical/legal/command conf TEAM_THEME values made distinct from TEAM_NAME.
- **`scripts/lcars-launch-helpers.sh`** — Mirror fix on dev-team source: `start_lcars_server` resolves brew venv python with fallback chain.
- **Why:** Closes the XACA-0460 → 0483 → 0484 → 0485 → 0486 install-side contract chain. Per p071 lesson, kanban XACA-0486 stays OPEN until M1Pro smoke confirms end-to-end.

### Chore: Bump homebrew-tap submodule to v0.11.8

- **`homebrew-tap`** — Bumped pinned pointer to `fffe2a0` (tag `v0.11.8`). 0.11.8 packages XACA-0485 which fixes `install-team.sh`'s `KANBAN_DIR` resolution to append the project component for parametric teams. Installer now writes/patches boards at the SAME path the LCARS server reads — XACA-0484's stub-board migration finally operates on the correct file.
- **Why:** M1Pro 0.11.7 still showed DOUBLENODE / Unknown Vessel after a clean reinstall because the migration was patching `~/finance/kanban/finance-personal-board.json` while LCARS reads from `~/finance/personal/kanban/finance-personal-board.json`. 0.11.8 closes the XACA-0460 → 0483 → 0484 → 0485 install-side contract chain.

### Fix: defensive wt-current / wt-project stubs in team banners

- **`finance/scripts/finance-banner.sh`**, **`medical/scripts/medical-banner.sh`**, **`legal/scripts/legal-banner.sh`** — Added stub-function fallback for `wt-current` / `wt-project` before the worktree-display block. Tap installs don't ship `worktree-helpers.sh`; without the stubs the banner prints `command not found: wt-current` at line 97 on every agent terminal launch. Stubs return `"(no worktree)"` so the banner renders cleanly in any shell context.
- **`freelance/scripts/freelance-banner.sh`** — Existing defensive `source ~/dev-team/worktree-helpers.sh` block kept as a first attempt, with stub fallback now appended for the source-fails case (tap install context).
- **Why:** Surfaced on M1Pro 0.11.7 install today during agent terminal launch. Cosmetic only — agents launch fine — but every Nagus/Bar/Vault/FCA/Workshop terminal printed the error. Fix is dev-team-source-only for now; tap copies will pick it up on next release sync.

### Feat: XACA-0484 — Ship per-agent scripts + fix stub-board branding (XACA-0483 follow-up)

- **`freelance/scripts/freelance-banner.sh`** — Added trailing newline (POSIX text-file convention). Mirrors the [Review]-driven fix in the tap-shipped copy.
- **`homebrew-tap` PR #12 (merged at 4730ae4)** — Companion ship work. Adds 32 per-agent + banner scripts under `share/scripts/teams/<team>/scripts/` for all four parametric teams. Extends install-team.sh's parametric branch to copy them with path substitution. Fixes the LCARS "DOUBLENODE / Unknown Vessel" branding fallback by adding `ship` field to install-time board init AND a stub-board migration that patches null `teamName`/`organization`/`ship`/`subtitle` from current registry+conf via `jq // $default` coalescing (non-destructive).
- **`homebrew-tap` submodule** — Bumped pinned pointer to `630e188` (0.11.7).
- **Why:** M1Pro 0.11.6 install today: `./finance-startup.sh personal` ran but 6 agent tmux sessions failed because per-agent scripts didn't ship. LCARS UI loaded but showed "DOUBLENODE / VESSEL: UNKNOWN VESSEL" because a May 4 stub `finance-personal-board.json` had all branding fields null. Both gaps were noted in the XACA-0483 retrospective; XACA-0484 closes them.

### Chore: Bump homebrew-tap submodule to v0.11.6

- **`homebrew-tap`** — Bumped pinned pointer from `c762715` → `0f983bf` (tag `v0.11.6`). 0.11.6 packages the XACA-0483 parametric startup/shutdown work for `finance`/`medical`/`legal`/`freelance` so it ships to installer consumers.
- **`homebrew-tap@v0.11.6`** — Single commit since v0.11.5: XACA-0483 parametric script restoration (Path A — ship dev-team source verbatim, installer copies with `~/dev-team` → `$AITEAMFORGE_DIR` substitution, non-destructive migration of legacy per-instance scripts).

### Feat: XACA-0483 — Restore parametric startup/shutdown for finance/medical/legal/freelance

- **`docs/architecture/team-id-contract.md`** — Amended §6 invariant 8 to split into parametric-mode and legacy-instance-keyed-mode clauses. Parametric mode (template_id-keyed filename + runtime project args) restored for the four template-parameterized teams. Legacy instance-keyed mode preserved for all other templates. Status line updated to note XACA-0483 amendment.
- **`freelance-startup.sh`, `freelance-shutdown.sh`** — De-branded usage examples: `DoubleNode WorkStats` → `AcmeCorp WidgetTracker` (XACA-0139 compliance for tap-shipped copies).
- **`homebrew-tap` PR #11 (merged at c762715)** — Companion change: installer detects parametric mode (TEAM_HAS_PROJECTS=true + shipped parametric source) and copies the dev-team scripts verbatim with path substitution (~/dev-team → $AITEAMFORGE_DIR). Migration auto-renames legacy per-instance scripts on disk with `.stale-pre-XACA-0483` suffix. 18 new regression tests at `tests/test-xaca-0483-parametric.sh`.
- **`homebrew-tap` submodule** — Bumped pinned pointer to `c762715` (post-merge tap main).
- **Why:** A real M1Pro 0.11.5 install today crashed because a stale `finance-startup.sh` from a prior install hardcoded `LCARS_TEAM=finance` (template id), which the new XACA-0460 contract enforcement in server.py rejects. XACA-0460 added server-side enforcement; XACA-0483 closes the install-side gap so the parametric scripts ship correctly going forward.

### Chore: Bump homebrew-tap submodule to v0.11.5

- **`homebrew-tap`** — Bumped pinned pointer from `0fb961b` → `9719ca1` (tag `v0.11.5`). The intermediate three sync commits on tap `main` (XACA-0347 / XACA-0346 / XACA-0474 docs) were already on the local submodule HEAD; this commit reconciles the dev-team gitlink with the published tap release.
- **`homebrew-tap@v0.11.5`** — Includes XACA-0460 quarantine-stub/instance-id/registry-keyed branding, XACA-0361 tap-hygiene-guard pre-commit hook, XACA-0358 cc-aliases.sh 3-field sidecar sync, and XACA-0477 Cellar post_install symlinks CONTRIBUTING note.

### Fix: XACA-0481 — wt-finish branch deletion order + surface real errors

- **`worktree-helpers.sh`** — Reordered `wt-finish()` so worktree removal happens BEFORE branch deletion. Git refuses to `git branch -D` a branch checked out in another worktree, so the old "Step 1 delete branch / Step 2 remove worktree" ordering silently failed on every run (errors swallowed by `2>/dev/null`, then a misleading "may already be gone" fallback). 32 orphan local branches with `: gone` upstream tracking had accumulated as evidence.
- **`worktree-helpers.sh`** — All four force-delete call sites in `wt-finish` now use the `_err=$(git branch -D "$branch" 2>&1)` capture pattern and echo git's real error message on failure. The one remaining suppressed call is the documented intentional safe-delete probe (`git branch -d`, used to detect whether a branch is fully merged); kept with an explanatory comment.
- **`worktree-helpers.sh`** — Step 1 / Step 2 banner labels and the SUMMARY block reordered to match new execution order. The "This will:" preview text updated for both auto-merge and interactive paths.
- **One-shot data repair** — Swept the 32 accumulated orphan branches from the dev-team repo. Post-sweep `git branch -vv | grep -c ': gone\]'` = 0.

- **`worktree-helpers.sh`** — `wt-pr-merged()` and `wt-cleanup()`: same `_err=$(... 2>&1)` capture pattern applied to their `git branch -D` and `git worktree remove` / `git push --delete` calls. They already had the correct ordering, but suffered the identical silent-failure pattern. Surfaces real git errors uniformly across all three cleanup functions.
- **`worktree-helpers.sh`** — `wt-finish()`: handles the "directory manually deleted, git registration still exists" edge case. When `$wt_path` is missing but `git worktree list --porcelain` shows a stale registration, the branch is looked up from the porcelain output and cleanup proceeds normally (previously the function bailed early with "Worktree not found").

### Feat: XACA-0477 — sync-tap drift sentinel + CI workflow documentation

- **`sync-tap.sh`** — Added drift sentinel block (~line 187) that walks `lcars-ui/` for symlinks targeting `fleet-monitor/server/public/lcars/` and warns if the count diverges from the known `_KNOWN_OVERLAP_COUNT=3`. Non-blocking (warns to stderr, never exits non-zero). Surfaces the case where someone adds a new lcars-ui→fleet-monitor symlink in the dev-tree without extending the formula's `overlap_pairs` array.
- **`.github/workflows/sync-tap-check.yml`** — Added a comment block documenting the symlink-at-install behavior. The two CI jobs (`sync-tap-drift` using `find -type f`, and `tap-lockstep-check` comparing paths not bytes) are unaffected by the post_install transformation.

### Docs: XACA-0477 — Document post_install ln_s symlink for lcars-ui↔fleet-monitor overlap

- **`kanban/EPIC-0018_shared_script_ssot.md`** — Updated status section to mark symlink rescope XACA-0477 as DELIVERED. Three specific CSS/JS assets (lcars-fleet.css, lcars-fleet-theme.css, lcars-fleet-core.js) now redirect from lcars-ui to fleet-monitor via post_install symlinks in the formula.
- **`kanban/EPIC-0018_audit_findings.md`** — Updated Outlier 2 (lcars-ui ↔ fleet-monitor overlap) to document resolution: post_install `ln_s` block constructs relative symlinks that dangle in cellar but resolve correctly in user-dir sibling layout after `cp -r`. Fleet-monitor remains canonical (matching dev-tree convention). Full rationale and second-order effects detailed in `kanban/plans/XACA-0477/PLAN.md`.
- **`homebrew-tap/CONTRIBUTING.md`** — Added subsection "Cellar post_install symlinks (XACA-0477)" explaining the three symlinks, how sync-tap.sh interacts with them (dereferences dev-tree symlinks; copies real files into both tap sections), and how to extend the formula's `overlap_pairs` array if new lcars-ui↔fleet-monitor symlinks are added in the dev-tree. References XACA-0477-001 sentinel check and plan doc for implementation rationale.

### Feat: XACA-0474 — BACKLOG epic dropdown grouped by derived state

- **`lcars-ui/js/lcars-filter-bar.js`** — `_populateEpicOptions()` now
  buckets epics into three subgroups under the BACKLOG screen's `EPIC:`
  dropdown, ordered PLANNED → ACTIVE → ARCHIVED, each preceded by a
  disabled `── STATE ──` header option. Within each group, epics sort
  alphabetically by title (case-insensitive). Empty groups are omitted.
  Epics missing the derived `state` field (e.g. when served by a stale
  pre-XACA-0474 server) bucket into ACTIVE — the safe middle. Header
  options are `disabled` so the browser prevents selection; the existing
  fallback in `_populateEpicOptions` recovers any persisted target value
  that no longer maps to a real option.
- The flat `─────` separator is replaced; the existing ALL/ASSIGNED/
  UNASSIGNED group above the epics is unchanged.

### Fix: XACA-0472 — kb-retro-path searches plans/<ID>/ subdir (planner-skill layout)

- **`kanban-helpers.sh`** — `kb-retro-path` now searches `kanban/plans/<ITEM-ID>/`
  for a plan doc in addition to the legacy flat `kanban/<ITEM-ID>_*.md` layout.
  The fallback triggers only when the flat search finds nothing and the subdir exists,
  preserving backward compatibility. Retrospective path is returned co-located with
  the plan doc (same directory), so retros land alongside their plan docs instead of
  always in the kanban root. Error output now includes both expected paths when neither
  layout is found. Bug surfaced during XACA-0358-007 retrospective where
  `kb-backlog sub done` could not locate the retro file because the plan doc was in
  the planner-skill `plans/` subdir.
- **`tests/bats/kb-retro-path-plans-subdir.bats` (new)** — Seven bats parity tests:
  T1 (flat layout regression), T2 (plans-subdir layout), T3 (neither layout — non-zero
  exit + both error message hints in stderr), T4 (both present — flat wins, search order
  documented), T5 (multiple plan docs in `plans/<ID>/` — sort+head gives deterministic
  lexicographic pick), T6 (depth boundary — nested plan doc not picked up under
  `maxdepth 1`), T7 (slug with spaces and dots preserved through `basename`/`dirname`).
  Tests use a synthetic tmpdir and override `_kb_get_kanban_dir()` in the zsh subshell
  so the real kanban tree is never touched.
- **Determinism hardening (PR review follow-up):** Both `find` calls now pipe through
  `sort` before `head -1`. Real-world case: `kanban/plans/XACA-0456/` already holds
  multiple plan-adjacent docs (audit report + canonical plan doc); without `sort` the
  picked doc was filesystem-ordering-dependent. `sort` gives stable lexicographic
  selection. A name-aware "prefer the canonical plan doc" upgrade is tracked separately.

### Feat: XACA-0347 — kb-edit-shared follow-up: Makefile target, extended docs, kanban-hooks surface tightening

Layered improvements on top of XACA-0346's `kb-edit-shared` (#388):

- **`Makefile` (new)** — Top-level Makefile with `help` (default goal) and `edit-shared` targets. `make edit-shared FILE=<canonical-or-tap-path>` dispatches to `kb-edit-shared` via `zsh -c 'source ./kanban-helpers.sh && kb-edit-shared "$$0"' "$(FILE)"`. Provides discoverability for users who prefer make targets over shell functions. Empty/missing `FILE` prints usage and exits non-zero.
- **`docs/homebrew-tap/EDIT-SHARED-WORKFLOW.md` (new, ~145 lines)** — End-user companion doc to CONTRIBUTING.md's brief reference: covers the problem (forgetting sync-tap → drift → pre-push hook blocks), the mirror surface as a table, shell + make usage, four worked examples (canonical edit, tap-mirror reverse-map with same-name and different-name cases, unmirrored rejection, the friction of forgetting the helper), and a worktree note explaining that `kb-edit-shared` requires the `homebrew-tap/` submodule to be initialized — run from the main repo or use `sync-tap.sh --source-dir/--reference-dir` from a worktree. Cross-references CONTRIBUTING.md (XACA-0346) and LOCKSTEP-CHECK.md (XACA-0344).
- **`kanban-helpers.sh`** — Tightened `kb-edit-shared`'s canonical-side acceptance to precisely match `sync-tap.sh`'s actual mirror surface for `kanban-hooks/`. The XACA-0346 implementation accepted any path under `kanban-hooks/` via the blanket `kanban-hooks/*` case alternation, but sync-tap only mirrors top-level `*.py` (`maxdepth 1 -name "*.py"`) plus the `integrations/` subtree — `tests/`, `migrations/`, and `*.sh` helpers are NOT mirrored. Replaced the blanket with an explicit `if/elif` depth-check before falling into the case (POSIX `case` lets `*` match `/`, so the depth restriction can't be expressed purely in alternation). Updated the rejection error message section list to reflect the new precision. Verified: `kanban-hooks/tests/foo.py` and `kanban-hooks/foo.sh` now correctly REJECTED; `kanban-hooks/foo.py`, `kanban-hooks/integrations/foo.py`, and `kanban-hooks/integrations/sub/deep/foo.py` still ACCEPTED; lcars-ui / scripts/<mapped> / fleet-monitor / docs/homebrew-tap regression checks pass.

### Chore: XACA-0362 — sync homebrew-tap submodule to current develop sources

- **`homebrew-tap` (gitlink)** — Advance from `2250ef7` to `5c5c6ca` to absorb pre-existing source-side drift that accumulated across XACA-0344, XACA-0466, and XACA-0346 without being mirrored. Two stacked tap commits: (a) `ffcb98c` mirrors 47 source mods + 2 new files (`share/kanban-hooks/kanban_icloud_paths.py`, `docs/LOCKSTEP-CHECK.md`); (b) `5c5c6ca` mirrors lcars-ui/{server.py,index.html,css/lcars.css,js/lcars.js} from XACA-0346. Required because the XACA-0362 fix (below) makes `sync-tap-check.yml` actually look at the submodule — the existing drift would otherwise fail PR CI for every future PR.

### Fix: XACA-0362 — sync-tap-check.yml: init submodule on checkout + add fleet-monitor to paths filter

- **`.github/workflows/sync-tap-check.yml`** — Added `with: submodules: recursive` to the Checkout step so `homebrew-tap/` is initialized before `sync-tap.sh --check` runs (prevents false-positive "all files NEW" drift). Added `"fleet-monitor/**"` to both the PR and push-to-develop paths filters so the workflow triggers when fleet-monitor sources change (sync-tap.sh §4 maps `fleet-monitor/server/` → tap).
- **`.githooks/pre-push`** — Fixed "both missing" branch (XACA-0455 XACA-0362): when both the worktree and main repo lack `homebrew-tap/share/`, the hook now exits 0 cleanly with an informative message instead of falling through to `sync-tap.sh --check`. Falling through produced a false-positive block on every push (tap destination absent → all source files appear as NEW). Users are directed to `git submodule update --init --recursive homebrew-tap` to restore enforcement.

### XACA-0474 — Derived epic state (PLANNED / ACTIVE / ARCHIVED)

- Backend: `/api/epics` and `/api/epics/<id>` now include a read-only `state`
  field (UPPERCASE enum) and a fully-typed `itemCounts` rollup. New `?state=`
  query filter accepts case-insensitive single or comma-separated values.
  Invalid values return 400.
- LCARS UI: Three-button PLANNED / ACTIVE / ARCHIVED filter row above the
  Epics dashboard, mirroring the Releases UX. Default ACTIVE, persists to
  `localStorage`. Per-card classes `epic-state-{planned,active,archived}`
  give a soft visual treatment (ARCHIVED is dimmed). No actions are disabled
  on ARCHIVED — derived state auto-reverts when any item is reopened.
- CLI: `kb-epic show` displays the derived state. `kb-epic help` documents
  the new state model.
- No data migration, no mutation API, no on-disk schema change.
- Contract: `kanban/plans/XACA-0474/STATE_CONTRACT.md`

### Docs: XACA-0346 — Canonical-source-first rule documented across three surfaces

- **`CONTRIBUTING.md` (new file at repo root, ~97 lines)** — Memorializes the lesson XACA-0340 taught: when a file is mirrored between dev-team source and the homebrew-tap submodule, fixes MUST land on the canonical dev-team source first. Tap-side patches without a matching source commit get silently overwritten on the next forward sync via `sync-tap.sh`, the bug returns, and the regression looks like a haunting until someone diffs canonical against tap. New section "Shared scripts and the canonical source" covers: what's mirrored (lcars-ui, kanban-hooks, mapped scripts, fleet-monitor/server, docs/homebrew-tap), the one-way direction (dev-team → tap), the lockstep-broken trap, the `kb-edit-shared` helper as the recommended workflow, the manual workflow as fallback, and how to detect mirrored files via `./sync-tap.sh --check`. Pairs with XACA-0344's `tap-lockstep-check` CI guard: XACA-0344 catches violations programmatically; XACA-0346 documents *why* and how to follow the rule in the first place.
- **`claude/CLAUDE.md`** — 5-line callout inside the existing "Git Submodules — homebrew-tap Workflow (XACA-0300)" section so subagents inherit the rule by reading CLAUDE.md. Defers to CONTRIBUTING.md for the authoritative full text. Footer "Last Updated" entry added.
- **`sync-tap.sh`** — 4-line `CANONICAL-SOURCE-FIRST RULE` callout in the header comment block (after the "Direction" paragraph) and 2 cross-reference lines appended to the `--help` output. Anyone touching the sync tooling now sees the rule at the source. No behavior changes — comment + help-text only.
- **`kanban-helpers.sh`** — New `kb-edit-shared <path>` helper (~140 lines including header comment) that programmatically enforces the canonical-source-first rule. Accepts either a tap path or a source path, resolves to the canonical dev-team source via the same path mappings sync-tap.sh uses, opens the source in `$EDITOR`, runs `sync-tap.sh` on save, and stages both the canonical file and the homebrew-tap submodule pointer. Errors loudly on non-mirrored paths, paths outside dev-team, missing canonical files, or sync failures. Smoke tests cover: usage error, non-mirrored source path rejection, non-mirrored tap path rejection, out-of-tree path rejection, source-path → canonical resolution, tap-path → canonical resolution, nonexistent-canonical rejection.
- **Knowledge capture (out-of-tree).** Retrospective at `kanban/XACA-0346_canonical_source_first_rule_RETROSPECTIVE.md` (kanban/ is gitignored at repo root by convention; retrospectives live there per `kb-retro-path` helper, not in PR diffs). Subject-tier knowledge entry at `~/knowledge/subjects/homebrew-tap/canonical-source-first-rule.md` (Knowledge Base lives outside any single repo per the project's tier schema; tags: `#pattern`, `#gotcha`).

### Feat: XACA-0466 — iCloud secondary archive for kanban backups (per-host)

- **Two-tier backup model:** Local primary at `~/aiteamforge-backups/kanban/` (15-min interval, unchanged) now paired with iCloud secondary at `~/Library/Mobile Documents/com~apple~CloudDocs/AITeamForge/kanban-backups/$(hostname -s)/` (30-min interval, new). Both run as independent launchd jobs.
- **Hostname-rooted iCloud paths** — The `$(hostname -s)` subdir on iCloud prevents collision when M3Pro/M1Pro/M4Mini all sync to the same iCloud account. Each machine maintains separate versioned backups; cross-machine recovery is straightforward (copy from any dated dir).
- **New `kanban-icloud-sync.py`** — Daemon script (30-min interval via launchd) syncs local backups to iCloud. Supports `--sync`, `--status`, `--dry-run`, `--once` flags. Writes structured status to `icloud-sync-status.json` and JSONL logs to `icloud-sync.log`. Fail-soft design: iCloud unavailable → exit with logged error; local backups unaffected.
- **New `kanban-icloud-bootstrap.sh`** — One-time migration script; copies existing backups to iCloud target, validates checksum parity, supports `--dry-run` and `--verify` flags. The `setup-kanban-backup.sh` installer auto-prompts for bootstrap if iCloud target is empty.
- **New helper modules** — `kanban-icloud-paths.sh` (bash sourcer) and `kanban-hooks/kanban_icloud_paths.py` (canonical path logic). Both implement the same hostname-rooted path construction to keep bash/Python in sync.
- **Extended `setup-kanban-backup.sh`** — Now installs both live-backup AND iCloud-sync launchd jobs. Dual-job uninstall support. Auto-bootstrap logic for fresh iCloud setups.
- **Extended `kanban-backup-health.py`** — Added `--icloud-only` flag to probe iCloud freshness; verifies latest sync timestamp against configurable threshold (default 60 min).
- **Diagnostics** — On iCloud sync stall, check `~/aiteamforge-backups/kanban/icloud-sync.log` (JSONL), `icloud-sync-status.json` (latest run state), and `icloud-sync.stderr.log` (launchd stderr). Both daemons write to the same `~/aiteamforge-backups/kanban/` log directory.
- **Bug fix (helper)** — Path-helper bash word-splitting bug: `awk -F' : '` now used instead of `$NF` to extract paths containing spaces from colon-delimited strings. Single-entry paths still work; multi-entry handling preserved.
- **Comment hygiene (round 3)** — Updated stale comment at `kanban-icloud-sync.py:295`. The previous comment referenced "combine stdout+stderr for stats parsing" — which became misleading after `_parse_rsync_stats()` was removed in round 2 and `capture_output=False` was kept (output streams to terminal/launchd log; the daemon only consumes the rsync exit code). Comment-only edit; no behavior change. Closes XACA-0466-020.

### Fix: XACA-0344 — Address bot review subitems (PR #385)

- **`scripts/check-tap-only-edits.sh`** — Fail-loud (exit 2) when base ref does not exist instead of silently returning OK via `|| true` (fixes 011, 016). Added `REMOTE_NAME` env var (default: `origin`) so local runs against `dev-team` remote work correctly without masking missing-ref errors. Added bash 4+ version guard near top with macOS install hint (fixes 012). Replaced pipe-delimited `VIOLATIONS` array with parallel `VIOLATION_FILES`/`VIOLATION_CANONICALS` arrays to avoid fragility with filenames containing `|` (fixes 014). Added coupling warning comment to `dir_py` entry explaining that it mirrors `sync-tap.sh maxdepth 1 -name "*.py"` and must be updated if that expands (fixes 015). Updated Usage comment block to document `REMOTE_NAME` usage and bash 4+ requirement. Updated exit-code table to include `2 — environment error`.
- **`.github/workflows/sync-tap-check.yml`** — Removed unused `GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}` from `tap-lockstep-check` job env block; script reads PR labels from `GITHUB_EVENT_PATH` (static JSON), not the GitHub API (fixes 013).

### CI: XACA-0344 — Add tap-lockstep-check job to sync-tap-check.yml

- **`.github/workflows/sync-tap-check.yml`** — New `tap-lockstep-check` job (PR events only) runs `scripts/check-tap-only-edits.sh` with `fetch-depth: 0` and an explicit base-branch fetch so the script's `git diff origin/${GITHUB_BASE_REF}...HEAD` range resolves correctly. Permissions scoped to `contents: read` + `pull-requests: read`. `GH_TOKEN` passed for future label-API enhancements. Updated COUPLING WARNING comment to include `scripts/check-tap-only-edits.sh` alongside the existing path-list reminder. Closes the lockstep-broken regression class (XACA-0340).

### Docs: XACA-0344 — Document tap-lockstep-check escape hatches

- **`docs/homebrew-tap/LOCKSTEP-CHECK.md`** (new) — Comprehensive guide to the tap-lockstep-check system: explains the XACA-0340 problem (mirror/canonical divergence), how the check works, when and how to use escape hatches (commit trailer `Tap-Only-Edit: intentional` preferred; PR label `tap-only-intentional` fallback), which files have canonical sources (with lookup tables), examples covering normal fixes, tap-only exceptions, and troubleshooting. Includes guidance on when each escape hatch is appropriate and clear warnings about when genuine canonical edits are required.
- **GitHub label `tap-only-intentional`** (created) — Label for PR-based escape-hatch bypass when commit trailer is unavailable. Description: "Bypass tap-lockstep-check (XACA-0344) — edit is genuinely tap-only with no canonical source". Color: FBCA04 (yellow).
- **`README.md`** — Added mention in Contributing section (item 5) with link to `docs/homebrew-tap/LOCKSTEP-CHECK.md` for escape-hatch guidance, tying the new documentation into the main entry point for developers.

### Fix: XACA-0471 — kanban-helpers set -u safety contract documentation + bats parity test

- **Scope reduced from original ticket.** XACA-0471 was filed before the author knew XACA-0467 (#380, already on develop) had merged its en-masse `${N-}` defaulting sweep across 271 sites in 87 functions. Audit confirmed only 2 bare `"$N"` matches remain in `kanban-helpers.sh` and both are inside historical-context comments. `scripts/kb-cr.sh` public dispatcher already uses `${1:-help}`. Subitems 002 (helpers patch) and 003 (kb-cr patch) cancelled as superseded.
- **`kanban-helpers.sh`** — Added a 12-line module-level header comment block stating the strict-mode safety contract: public kb-* entry points must remain callable from caller shells with `set -u` / `setopt nounset` enabled; optional positional args MUST use `${N-}` defaulting; required args don't (set -u correctly catches genuine missing-arg bugs there). Cross-references the regression coverage and cites XACA-0462 / XACA-0467 / XACA-0471 history. No code/logic changes — comment-only edit between the existing banner and the Configuration section.
- **`tests/bats/kanban-helpers-nounset.bats` (new)** — Bats parity wrapper for the existing `tests/test-kanban-helpers-nounset.sh` zsh test. 14 tests mirror the same 13 entry points (kb-sweep, kb-done, kb-cancel, kb-context-set, kb-status, kb-task, kb-plan, kb-pause, kb-pick, kb-run, kb-work, kb-backlog, kb-import) plus T1 (sourcing under nounset). Each test wraps `zsh -c 'setopt nounset; source kanban-helpers.sh; <cmd>'` via a `run_nounset()` helper; assertions guard against `parameter not set` / `unbound variable` aborts in the captured output (a usage-message non-zero exit is acceptable). Bats orchestrates while the actual source happens in zsh because the helper file uses zsh-only features (`setopt`, `local -A`).
- **Smoke-tested the three originally-crashing patterns** from the ticket (`kb-done` no-arg, `kb-done <id>`, `kb-backlog sub add` no-args under `bash -uo pipefail`): all three now exit cleanly with usage / error messages, no nounset abort. Result already on develop via XACA-0467; XACA-0471 ratifies the behavior with bats coverage and adds the contract comment so future contributors don't regress it.

### Fix: XACA-0455 — sync-tap pre-push hook spurious drift in worktrees

- **PR #381 review nits (follow-up commit):** Addressed 4 non-blocking code-review items: (1) `sync-tap.sh` now guards `--commit` mode against `SOURCE_DIR != REFERENCE_DIR` — refuses with exit 2 and a clear error rather than silently producing a broken commit from a worktree (XACA-0455-011); (2) added diagnostic message assertion test validating both "submodule not initialized" text and the `git submodule update --init` remediation hint (XACA-0455-010); (3) added negative test for missing required flag value (`--source-dir` with no path), confirming `${2:?…}` guard exits non-zero (XACA-0455-012); (4) fixed Test 6 description from misleading "no SYNC_TAP_PATHS-relevant files" to accurate "drift-clean: SYNC_TAP_PATHS files touched but tap in sync" (XACA-0455-013). Test count: 10 → 14 all passing.
- **`sync-tap.sh`** — Added `--source-dir <path>` and `--reference-dir <path>` CLI flags. When provided, source files are read from `--source-dir` and tap copies compared against `--reference-dir/homebrew-tap`. Backward compat: invoking without flags falls back to `$DEV_TEAM` as before. Added precondition check: if `$TAP/share` does not exist, exits 2 with a clear "submodule not initialized" diagnostic instead of flooding false-positive drift. Exit codes: 0 = clean, 1 = drift, 2 = broken state.
- **`.githooks/pre-push`** — Added worktree-aware detection before invoking sync-tap: if `homebrew-tap/share/` is absent in the current worktree, computes the main repo root via `git rev-parse --git-common-dir` (handles both `.git` relative form and absolute worktree path). If the main repo has the tap initialized, passes `--source-dir "$WORKTREE_ROOT" --reference-dir "$MAIN_REPO_ROOT"` to sync-tap, eliminating the false-positive push block. If both are missing (genuinely broken state), falls through to let sync-tap produce its diagnostic.
- **`claude/CLAUDE.md`** — Documented auto-detection behavior: added "Worktree Pushes — sync-tap Auto-Detection" section explaining that no env vars or escape hatches are needed for normal worktree pushes; `SKIP_SYNC_TAP_CHECK=1` remains available for genuine emergencies.

### Refactor: XACA-0360 — Relocate authoritative homebrew-tap docs to dev-team/docs/homebrew-tap/ + sync-tap.sh

- **`docs/homebrew-tap/` (new: 17 files)** — Authoritative editing location for all tap-shipping user and architecture docs. Populated from `homebrew-tap/docs/` (16 files + tap's `USER_GUIDE.md`). After this change, the tap's `docs/` is a read-only mirror; edits belong here.
- **`docs/aiteamforge-internal/` (new: 6 files)** — Destination for dev-team-internal aiteamforge docs that are NOT shipped to the tap: `ENVIRONMENT_INVENTORY.md`, `KANBAN_INSTALLER_NOTES.md`, `MIGRATION_GUIDE.md`, `PHASE_10_SUMMARY.md`, `PHASE_6_CLAUDE_CONFIG_COMPLETE.md`, and the Academy Phase-6 strategic `USER_GUIDE.md`. Previously all 6 lived alongside the tap-shipping docs in `docs/homebrew-tap/`.
- **`USER_GUIDE.md` collision resolved** — Two files shared the name: the tap's 909-line end-user manual (now at `docs/homebrew-tap/USER_GUIDE.md`) and the Academy Phase-6 736-line strategic doc (moved to `docs/aiteamforge-internal/USER_GUIDE.md`). Both preserved; no content modified.
- **`sync-tap.sh` (Section 5 added, Section 5 → 6 renumbered)** — New `sync_dir` block propagates `docs/homebrew-tap/` → `tap/docs/` on each sync run. Outer `git add` updated to include `docs/`. No excludes needed — directory layout enforces the tap/internal separation by design.
- **`homebrew-tap` submodule** — Submodule pointer advances to a chore-sync commit on branch `feature/xaca-0360-sync` (SHA `bdc69cc`) which absorbs 47 pre-existing source-file drift files in `lcars-ui/`, `fleet-monitor/server/`, and `kanban-hooks/`. No XACA-0360 docs work in the submodule diff — the docs sync runs against the new dev-team `docs/homebrew-tap/` source on next `sync-tap.sh --commit` cycle.

### Feat: XACA-0361 — advance homebrew-tap submodule pointer (tap-hygiene-guard hook)

- **`homebrew-tap` (gitlink)** — Advance submodule pointer from `0d321b6` to `2250ef7` (PR #9 merged to `DoubleNode/homebrew-aiteamforge:main`).
- **New `scripts/check-tap-hygiene.sh`** — Three-check tap-internal hygiene guard: orphan formula files, VERSION/Formula version consistency, stale `*doublenode*` rebrand filenames.
- **`.githooks/pre-commit`** — Extended with hygiene trigger paths (Formula/, VERSION, fleet-monitor/); XACA-0173 setup-wizard guard preserved.
- **`.github/workflows/tests.yml`** — New `tap-hygiene-guard` job (ubuntu-latest, parallel to drift-guard).
- **`tests/xaca-0361-tap-hygiene-guard.bats`** — 4 bats tests (clean tree + 3 negative cases).
- **Pre-flight cleanup** — VERSION aligned to 0.11.4 (matching Formula); 6 stale `*doublenode*` files removed from fleet-monitor/plugins/.

### Fix: XACA-0465 — cr-confluence-poller cr_proper_url corrective fix (IT Connect URL, not Confluence)

- **`scripts/cr-confluence-poller.py`** — Corrective follow-up to XACA-0461 (PR #372/#373) which conflated two distinct CAB systems. `cr_proper_url` is the **IT Connect ticket URL** (`https://itconnect.daveandbusters.com/a/changes/<NNNN>?...`), D&B's official change-management system; `cr_confluence_url` is the Confluence wiki request DOC. They are NOT interchangeable. The XACA-0461 fallback wrote `cr_confluence_url` directly into `cr_proper_url` and transitioned, corrupting the field. Four CRs were stuck-then-incorrectly-transitioned (CR-ANDROID-20260505-0001, CR-ANDROID-20260508-0002, CR-IOS-20260505-0618, CR-IOS-20260505-0632); rolled back to cr-drafted on 2026-05-08.
- **New `ITCONNECT_URL_PATTERN`** module constant matching `https://itconnect.daveandbusters.com/...` (case-insensitive).
- **`extract_cr_proper_link`** — New highest-priority Rule 0: return the LAST anchor whose href matches `ITCONNECT_URL_PATTERN`. Rules 1 (text /cr.?proper/i) and 2 (Confluence URL after cr-proper heading) retained as fallback for legacy/customised pages. Function was previously broken for itconnect anchors entirely — neither legacy rule matched the canonical `[#NNNN] <title> | Dave & Buster's` form.
- **New `_fetch_confluence_html_by_url(url, team, creds, label)` helper** — fetches a Confluence page by direct URL using the existing `_confluence_page_id_from_url` + `urllib.request` + `_make_auth_header` pattern (no new imports). Used by the one-stage fallback.
- **`scan_team` Pass 1** — Replaced the wrong XACA-0461 fallback. When `fetch_request_page_content` returns None and `cr_confluence_url` is populated: fetch the page via `_fetch_confluence_html_by_url`, run `extract_cr_proper_link` on the resulting HTML, and only call `transition_cr` when an itconnect URL is recovered. Never substitute `cr_confluence_url` for `cr_proper_url`.
- **`tests/bats/cr-confluence-poller.bats`** — Replaced 4 XACA-0461 tests (which asserted the wrong substitution behavior) with 4 corrective tests: (a) `extract_cr_proper_link` returns itconnect URL when Rule 0 matches; (b) returns None with no rule match; (c) one-stage fallback transitions when itconnect anchor exists; (d) one-stage fallback does NOT transition when no itconnect anchor exists. 34/34 pass.
- **`kanban/plans/XACA-0458/{audit,recommendations}.md`** — Banner correction at top, strike-through of the misleading "treat that URL as if it WERE the CR-Proper URL" recommendation, supersession callout pointing here. Added "Corrective recommendations (XACA-0465)" summary section.
- **Sequencing**: XACA-0464 (poller dev-mode write-path bugs — `set -u` + cross-team `_kb_detect_context` override) shipped first as PR #377; XACA-0462 (kb-sweep protected-subitem gate + kb-done set-u safety) shipped as PR #378; this branch was rebased onto post-merge develop after each.

### Fix: XACA-0462 — kb-sweep protected-subitem gate + kb-done set-u safety

- **`kanban-helpers.sh` `kb-sweep()`** — Added an explicit protected-subitem detector that scans the parsed subitem list for titles starting with `[Review]` or `[Test]` in todo/in_progress/blocked state and prints a distinct "🚫 PROTECTED SUBITEMS UNRESOLVED (N)" block listing each id, title, and status. Block runs after the existing legend and before the retrospective validator, so the PR auto-merge dual-gate monitoring loop in `claude/CLAUDE.md` and human reviewers both get an unambiguous signal that a merge gate is active. Function still returns 1 in this path (existing remaining-count logic unchanged), but the message is now louder and protected-specific instead of the generic "N remaining" line.
- **`kanban-helpers.sh` `kb-sweep()` arg-handling** — Replaced `[[ -n "$1" ]]` with `[[ -n "${1-}" ]]` (default expansion) at the working-id resolution. The auto-merge monitoring loop runs in a zsh shell with `setopt nounset`/`set -u`-equivalent strict mode; an unguarded positional reference threw `parameter not set` and broke the gate flow when the function was invoked without an explicit item id.
- **`kanban-helpers.sh` `kb-done()` arg-handling** — Same fix at the working-id branch and the `--force` flag check (`[[ -n "${1-}" ]]`, `[[ "${1-}" == "--force" ]] || [[ "${2-}" == "--force" ]]`). Closes the `$1: unbound variable` error the monitoring loop hit at line 3024 of the deployed copy on 2026-05-08 immediately after PR #372 merge, which prevented the post-merge `kb-done` call from advancing the kanban item.
- **Discovered**: 2026-05-08 — PR #372 (XACA-0461) merged with `[Review]` subitem XACA-0461-007 still in `todo`, and the trailing `kb-done` aborted under nounset. Both surfaces share the auto-merge flow defined in `claude/CLAUDE.md`.

### Fix: XACA-0464-001 — kanban-helpers.sh SESSION_TYPE default for set -u compatibility

- **`kanban-helpers.sh`** — Replaced 7 bare `$SESSION_TYPE` / `"$SESSION_TYPE"` reads (lines 12281, 12286, 12305, 12310, 12350, 12355, 12395) with `${SESSION_TYPE:-}` form. Under `set -euo pipefail`, referencing an unset variable without a default aborts the source; this caused `kb-cr.sh` to never load when `cr-confluence-poller.py` ran its bash_cmd subprocess (via `zsh -c`) or launchd started the poller (neither environment sets `SESSION_TYPE`). The result was `_kb_cr_find_container` missing and the CR write path failing silently.

### Fix: XACA-0464-002 — cr-confluence-poller cross-team kb-cr override (all three call sites)

- **`scripts/cr-confluence-poller.py`** (`transition_cr` / `record_approval_candidate` / `_auto_approve_cr`) — Inject `_kb_detect_context` shell function override before each `kb-cr` call. Without this, `kb-cr submit` / `kb-cr activity record` / `kb-cr approve` resolve the board via `_kb_detect_context`, which reads tmux session name (or cwd-fallback) — always returning `academy` on M3Pro — so cross-team CRs fail with "CR not found on board academy". `KB_TEAM` env is set in all three sites but `_kb_detect_context` does not consult it, so the env was ineffective. Each override emits the `--team` value passed to the poller. (`transition_cr` was the originally-reported failure; XACA-0464-006 review found the same defect at the other two sites — all three are now patched.)

### Feat: XACA-0460 — LCARS Import dual-board pre-flight + template-vs-instance contract enforcement

- **`docs/architecture/team-id-contract.md`** (new) — Architectural contract formalizing the template-vs-instance team-id distinction. §3 instance-id formation rule (`template[-client]-project`, lowercase, components match `^[a-z0-9_]+$`); §4 where each id type belongs (template = branding/conf lookup; instance = paths/env/sockets/ports); §5 `compute_instance_id` pseudocode; §6 install-time and server-startup validation invariants; §7 forward-compat for medical-pediatric, freelance-{client}-{project}, etc.
- **`lcars-ui/server.py` `_filter_contract_violating_teams` (new)** — Strips bare-template ids of parameterized templates (e.g. `freelance`, `medical`) from `TEAM_KANBAN_DIRS` at server build time with a loud warning pointing at `~/.aiteamforge/team-paths.json`. Prevents the new `LCARS_TEAM` validator from accepting a bogus bare-template install.
- **`lcars-ui/server.py` `_detect_dual_boards` / `check_all_dual_boards_or_die` (new)** — Detector returns a state object instead of `sys.exit`-ing. Startup check now iterates ALL known stub mappings (`legal-coparenting`, `medical-general`, `finance-personal`) regardless of `LCARS_TEAM`. Old `check_dual_boards_or_die(team)` kept as compatibility shim.
- **`lcars-ui/server.py` `validate_lcars_team_or_die` (new)** — At `main()` entry, refuses to start if `LCARS_TEAM` is unset, a bare-template id for a parameterized template (suggests likely instance id), or unknown. `LCARS_SKIP_TEAM_VALIDATION=1` bypass for tests. Exit 1 in all error cases.
- **`lcars-ui/server.py` `handle_import_upload`** — After manifest validation but before staging, calls `_detect_dual_boards(LCARS_TEAM)`. On hit: deletes the staged zip and returns HTTP 409 with structured `dual_board_state` JSON (team, message, remediation array referencing `kb-quarantine-stub`). The destructive `finance-personal → finance` rename prompt is never reached.
- **`lcars-ui/server.py` `serve_kanban_data` + `_load_registry_branding` (new)** — When the served board JSON is missing `organization` / `teamName` / `subtitle`, hydrates from `homebrew-tap/share/teams/registry.json` keyed on `_split_team_id(LCARS_TEAM)[0]` (template). Returns HTTP 503 `branding_unresolved` if registry has no entry for the template. Fixes the "DOUBLENODE only" header symptom.
- **`tests/test_dual_board_detection.py`** (new) — pytest function-level integration test. Six cases (dual-board hit, stub-only, canonical-only, empty, unknown team, medical-general forward-compat) using `monkeypatch.setitem` to redirect `LEGACY_STUB_PATHS` and `TEAM_KANBAN_DIRS` to sandbox paths. 6/6 pass in 0.50s.
- **`homebrew-tap`** (submodule pointer bump) — pulls in the matching tap commit: kb-quarantine-stub shipped to tap aliases, tap-side drift test, TROUBLESHOOTING.md dual-board section, installer instance-id computation, installer registry-keyed branding. See tap CHANGELOG for the per-file breakdown.
- **Discovered**: 2026-05-08 during Finance team import on M1Pro fresh install (Chancellor session). Same failure mode latent in `medical-general`, `legal-coparenting`, every `freelance-{client}-{project}` instance.
- **Follow-up filed**: XACA-0463 (per-instance LCARS port allocation policy + migration of existing collisions in `~/.aiteamforge/team-paths.json`).

### Fix: XACA-0454 — kanban-helpers context detection in non-tmux agent shells

- **`kanban-helpers.sh` `_kb_detect_context()`** — Added a 4-layer resolution chain so background subagents, CI runners, and any shell without a tmux pane can resolve team/terminal context. Layer 1 (existing) is `tmux display-message` from `$TMUX_PANE`. Layer 2 (new) reads `KB_TEAM` (canonical) or `AITEAMFORGE_TEAM` (alias) plus optional `KB_TERMINAL`/`KB_WINDOW_INDEX`/`KB_WINDOW_NAME`. Layer 3 (new) walks up from `$PWD` looking for a `.kb-team` sentinel file (format: `team[:terminal[:window_index[:window_name]]]`, whitespace stripped). Layer 4 returns the existing `ERROR:ERROR:0:unknown` only after all fallbacks are exhausted. Output format is unchanged, so all 44 call sites continue working unmodified.
- **`kanban-helpers.sh` `_kb_resolve_context_fallback()`** (NEW helper) — Encapsulates layers 2–3. Called from `_kb_detect_context` only when tmux resolution fails. Keeps the tmux-success path byte-identical for zero performance impact in interactive shells.
- **`kanban-helpers.sh` `_kb_get_kanban_dir()`** — Added `[ -d "$_result" ]` guard around the path returned by `aiteamforge_team_kanban_dir`. Stale entries in `~/.aiteamforge/team-paths.json` (e.g. from removed worktrees, `/tmp` paths cleaned by macOS periodic) are now ignored and resolution falls through to the built-in case statement instead of returning a path that does not exist on disk. Closes the silent-corruption surface that downstream `jq` operations would hit with cryptic errors.
- **`kanban-helpers.sh` `kb-context-set <team> [<terminal>]`** (NEW user command) — Exports `KB_TEAM` (and optional `KB_TERMINAL`) for the current shell. Documented, supported way for subagents and CI to set context explicitly. No-arg invocation prints usage and returns exit 1 (no silent empty-env-var pollution).
- **`kanban-helpers.sh` `kb-context-show`** (NEW user command) — Diagnoses what `_kb_detect_context` resolves to and which layer of the chain produced it (`tmux (TMUX_PANE=…)`, `tmux (current pane)`, `env (KB_TEAM=…)`, `env (AITEAMFORGE_TEAM=…)`, `sentinel (<path>)`, or `none (resolution will fail)`). On failure, prints actionable remediation steps inline.
- **`claude/CLAUDE.md`** — Added "kanban-helpers context in non-tmux shells (XACA-0454)" subsection under Worktree Agent Rules. Documents the 4-layer chain, when to use env vars vs sentinel, the subagent one-liner pattern, and `kb-context-show` as the diagnostic.
- **`.gitignore`** — Added `.kb-team` sentinel under new "Kanban Helper Sentinels (XACA-0454)" section. Per-repo team-context markers should never be committed.
- **Project knowledge** — `kanban/knowledge/project/p059-subagent-context-resolution-chain-xaca-0454.md` (gitignored, kanban-backup-covered) captures the full pattern for future subagents.
- **No call-site changes required.** All 44 existing `_kb_detect_context` call sites and 8 existing `_kb_get_kanban_dir` call sites work unchanged because the output format is preserved. Test suites that override `_kb_detect_context` with hardcoded fixtures (`test-kb-cr.sh`, `test-subitem-numbering.sh`, `test-sub-rename-id.sh`) continue to pass — the override replaces the whole function, so the new fallback chain is correctly bypassed in tests. Total existing-suite pass: 194/194.

### Fix: XACA-0457 — team-paths.json corruption hardening (server guard + test sandbox + schema integrity)

Three-layer defense added after the 2026-05-07 15:54 CDT regression that collapsed `~/.aiteamforge/team-paths.json` from 20 teams to academy-only and bypassed the standard backup mechanism. Forensics traced the writer fingerprint to `tests/bats/cr-automation4-summary.bats` (defensive setup/teardown safety net was bypassed — most likely Ctrl+C mid-run or manual heredoc extraction).

- **Detection — `kanban-hooks/aiteamforge_paths.py` `load_config()`** — Added schema-integrity check after JSON parse. Configs missing `schema_version` OR missing required canonical teams (academy + at least one of ios/android/firebase/dns) now log `[aiteamforge-paths] WARNING: ... appears corrupt ... — bootstrapping defaults` and re-bootstrap, instead of silently returning the partial config. New module-level constants `CANONICAL_REQUIRED_TEAMS = frozenset({"academy"})` and `CANONICAL_AT_LEAST_ONE_TEAMS = frozenset({"ios", "android", "firebase", "dns"})` define the canonical set. The integrity-check block also proactively snapshots the corrupt file before nulling config, so the TTY `_bootstrap` path (which skips `_write_defaults`) still leaves a forensic trail (XACA-0457-012).
- **Detection — `lcars-ui/server.py` `_build_team_kanban_dirs()`** — Extended the 2026-04-22 empty-config guard to also require canonical teams before caching `TEAM_KANBAN_DIRS`. Partial corruption (e.g. academy-only) now logs a precise `[LCARS] WARNING: list_teams() returned partial config (missing required: ...; none of [ios, android, firebase, dns] present)` line and falls back to `_hardcoded_team_kanban_dirs()`. Without this, an LCARS server started during a partial-write race would have served academy-only configs for its lifetime. Warning message distinguishes missing-required from missing-at-least-one for operator clarity (XACA-0457-011).
- **Forensics — `kanban-hooks/aiteamforge_paths.py` `wizard_hook_create_config()` and `_write_defaults()`** — Both writers now snapshot the existing config to `<name>.bak-YYYYMMDD-HHMMSS` before overwriting. The 2026-05-07 incident left no `.bak` snapshot because this step did not exist. Backup failures are non-fatal (logged WARNING, write continues).
- **Prevention — `tests/bats/cr-automation4-summary.bats`** — `setup()` now captures the original mode of `$HOME/.aiteamforge/team-paths.json` and `chmod 444` it before the test heredocs run; `teardown()` restores the original mode before the existing backup-restore step. Belt-and-suspenders against any future test that escapes its `$KB_CR_FAKE_HOME` sandbox: writes fail loud (Permission denied) instead of silently corrupting the live file. macOS/Linux portable via `stat -f` / `stat -c` fallback.
- **Audit (XACA-0457-001)** — Confirmed `cr-automation4-summary.bats` is the only bats test that touches `~/.aiteamforge/*`. No other tests need the chmod 444 fixture pattern.
- **Test coverage (XACA-0457-006)** — Validated all three layers via tmp-dir corruption fixtures: (a) missing `schema_version` triggers WARNING + bootstrap + .bak snapshot; (b) academy-only config (the 2026-05-07 fingerprint) triggers `has_canonical_subset=False` warning + bootstrap; (c) healthy 3-team config passes through unchanged with no rewrite. LCARS server smoke test confirmed academy-only input falls back to the 20-team hardcoded dirs. Bats suite: 12/19 pass (7 pre-existing zsh PATH failures unrelated).

### Fix: XACA-0461 — cr-confluence-poller cr_confluence_url fallback for direct-publish CRs

- **`scripts/cr-confluence-poller.py` `scan_team()` Pass 1** — When `fetch_request_page_content()` returns `None` (i.e., `cr_doc_link` is absent), the poller now checks `cr_confluence_url` on the CR record. If populated, it skips the HTML-scrape stage and treats `cr_confluence_url` directly as `cr_proper_url`, then calls `transition_cr()`. This unblocks CRs published via the one-stage Main Event CR skill, which writes `cr_confluence_url` but not `cr_doc_link`. The two-stage `cr_doc_link` path is unchanged. Fixes all four stuck `cr-drafted` CRs identified in the XACA-0458 audit (field-contract mismatch case d).

### Feat: XACA-0459 — cr-confluence-poller dev-mode invocation path (M3Pro fallback)

- **`scripts/cr-confluence-poller.py`** — Added two override surfaces so the poller can run from `~/dev-team/scripts/` without the AITeamForge installer or per-team launchd agents (forbidden on M3Pro per CLAUDE.md):
  - `$KB_CR_POLLER_CREDS_FILE` env var — points `load_credentials()` at an alternate creds JSON. Resolved at call time via new `_resolve_creds_file()` helper; existing `DEFAULT_CREDS_FILE` (`~/.config/aiteamforge/confluence-credentials.json`) remains the fallback for installer-driven invocations.
  - `--board PATH` flag — bypasses the `kanban-helpers.sh` `_kb_get_board_file` shell-out and points `_board_file_for_team()` at any team's shared board JSON. Validated to require `--team` (board files are single-team) and to refer to a readable file. Stored in module-level `_BOARD_OVERRIDE` so prod default behavior (no env, no flag) is byte-identical.
- **Header docstring** — New "Dev-Mode Invocation (XACA-0459 — M3Pro fallback)" section documenting use cases (heuristic dev, incident response, pre-poll validation), both override surfaces, an example invocation, and the explicit non-goal: dev mode does not install LaunchAgents, write plists, or touch installer-managed paths.
- **No installer / launchd impact** — No code paths write to `~/Library/LaunchAgents/`, invoke `launchctl`, or otherwise pollute installer behavior.
- **Read/write parity for dev-mode (XACA-0459-001)** — When `--board` is set, the poller exports `KB_CR_POLLER_BOARD_OVERRIDE_PATH` into the subprocess env used by the write-path shell heredocs. The heredocs resolve `BOARD_FILE` as `${KB_CR_POLLER_BOARD_OVERRIDE_PATH:-$(_kb_get_board_file ...)}`, so reads and writes target the same file. New `_poller_env()` helper centralizes the env construction across all three write call sites.
- **Path canonicalization (XACA-0459-002)** — `--board` arg is now resolved via `Path(...).expanduser().resolve()`, matching the docstring's "absolute path" guidance and ensuring writes receive the same path the user sees in the override-active log line.
- **Test coverage (XACA-0459-003)** — Added 6 new bats cases to `tests/bats/cr-confluence-poller.bats` covering `--help` flag presence, `--team` requirement, path validation, `_resolve_creds_file` env handling, `_board_file_for_team` override semantics, and `_poller_env` env injection. Full suite: **30/30 pass** (24 pre-existing + 6 new).

### Fix: XACA-0456 — Gate add-item doc materialization on _KB_CR_SKIP_DOC_FILE; fix docs/CR_WORKFLOW.md view.id reference

- **`scripts/kb-cr.sh` `_kb_cr_container_add_item()`** — Doc materialization block (line 2408) now checks `_KB_CR_SKIP_DOC_FILE != "1"` before creating the doc on first item link. This prevents `_kb_cr_draft` (which calls `_kb_cr_container_add_item` internally) from pre-empting draft's own explicit `_kb_cr_create_doc_file` call, which caused two bugs: (1) docs produced by `kb-cr draft` had `(add a description)` placeholder instead of the real item description; (2) `_kb_cr_create_doc_file` emitted a spurious `NOTE: CR doc already exists` on every `kb-cr draft` call.
- **`scripts/kb-cr.sh` `_kb_cr_draft()`** — The `_kb_cr_container_add_item` call (line 3090) now uses the `_KB_CR_SKIP_DOC_FILE=1 cmd` inline-env idiom to suppress the add-item doc materialization. The guard is no longer dead code — it is now actively used by both `_kb_cr_container_create` (via export/unset) and `_kb_cr_container_add_item` (via inline env). Resolves PR #370 reviewer issues #1, #2, and #3.
- **`docs/CR_WORKFLOW.md`** — Corrected `view.firstItemId` reference at line 120 to `view.id` (the normalized property name set by `_normalizeCR` in `lcars-cr-tab.js`). Resolves PR #370 reviewer issue #4.

### Fix: XACA-0456-002 — kb-cr emit cr_created activity-log + defer doc creation to first add-item

- **`scripts/kb-cr.sh` `_kb_cr_container_create()`** — Appends a `cr_created` activity-log event (best-effort, matches existing transition entry schema: `type`, `actor`, `ts`, `to_state`, `note`) after the CR record write succeeds. Removed the unconditional `_kb_cr_create_doc_file` call that was creating orphan `cr-docs/<CR-ID>-CR.md` files invisible to the LCARS UI resolver. Updated success message to inform operators that the doc materializes on first `kb-cr add-item`.
- **`scripts/kb-cr.sh` `_kb_cr_container_add_item()`** — Reads the pre-update `itemIds` length and `type` from the CR record. On first item linked (pre-count == 0), calls `_kb_cr_create_doc_file` with `item_id` as arg 7, producing `cr-docs/<item-id>-CR.md` — the canonical filename the LCARS UI endpoint resolves. Idempotent on subsequent calls.

### Docs: XACA-0456-005 — Document unified CR-doc convention

- **`docs/CR_WORKFLOW.md`** — New comprehensive section "Local CR Markdown Documents — Canonical Convention (XACA-0456)" documenting: (1) canonical path and filename rule (`<team-kanban>/cr-docs/<item-id>-CR.md` keyed on first-linked item ID); (2) materialization timing table showing when markdown is created via `kb-cr draft`, `kb-cr create` (deferred), and `kb-cr add-item` (on first link); (3) example workflows for both `kb-cr draft` and standalone-then-link patterns; (4) activity-log independence and preservation rules; (5) pre-XACA-0456 orphan-file note explaining the historical bug and fix; (6) cross-team applicability; (7) LCARS UI integration (URL construction, 404 messaging); (8) code locations for implementers (doc writers, resolver, client fetch, activity-log helpers, event types). Addresses Spock's 2026-05-07 handoff request for unified documentation and operator source-of-truth reference.

### Fix: XACA-0456-003 — LCARS UI CR-doc 404 + stale fallback text

- **`lcars-ui/server.py`** — `serve_cr_content` 404 message updated to mention both `kb-cr draft <item-id>` and `kb-cr add-item <CR-ID> <item-id>` as paths to materialize the local CR doc. Pure text change; no resolver logic touched.
- **`lcars-ui/js/lcars-cr-tab.js`** — `.catch()` fallback error message updated from stale `change-requests/${cr_id}*.md` path to canonical `cr-docs/${view.id}-CR.md`, with updated guidance referencing `kb-cr draft` / `kb-cr add-item`. Comment at line 1147 (internal code documentation) left unchanged — it describes a legacy path example, not a user-facing string.

### Feat: XACA-0296 — CAB Workflow Phase 6: View 3 Throughput Comparison + Automation 4 Bi-Weekly Summary (EPIC-0017 Phase 6)

- **`scripts/kb-cr-audit.py`** — View 3 + Automation 4 generators. New constants: `BASELINE_CUTOVER_DATE = 2026-04-07 UTC` (CAB workflow ship date), `ESTIMATE_TOLERANCE_HOURS = 24`, `DEFAULT_REPORT_PERIOD = 14 days`. New view generators: `_view_throughput_comparison()` (ISO-weekly pre/post-cutover bucketing with delta column), `_view_throughput_trend()` (pre-avg / post-avg / pct-improvement headline with division-by-zero guard), `build_throughput_comparison()` (audit-JSON entry-point that mirrors `build_volume_by_*`). New summary sub-generators: `_generate_estimate_accuracy_report()` (per-CR delta in hours plus aggregate hit/miss rate using the ±24h tolerance band), `_generate_cycle_time_report()` (7-segment median/P25/P75 table covering Draft → Prod), `_generate_pushback_report()` (rejection reasons, hold reasons, retry count from per-CR activity logs), `_kb_cr_summary_report()` (8-section orchestrator), `emit_summary_report()` + `summary-report` argparse subcommand. SCHEMA_VERSION bumped 1.1 → 1.2 (additive — `throughputComparison` block added to audit JSON alongside `volumeByType` / `volumeByApprover`; no fields removed).
- **`scripts/kb-cr.sh`** — New `kb-cr summary` CLI subcommand (Automation 4). Helper `_kb_cr_summary_main()` argparses `--team <slug>` (REQUIRED), `--period 2w/4w/7d` (default `2w`), `--from`/`--to` (ad-hoc window override), `--output FILE.md` (tee), `--verbose`. Helper `_kb_cr_summary_help()` prints usage. Output is plain markdown — explicitly **no auto-publish to Confluence** (Academy team boundaries; operators copy-paste the markdown into email/Slack/Confluence themselves).
- **`tests/bats/cr-view3-throughput.bats`** (NEW) — 11 cases for View 3: pre-only / post-only / spanning-cutover datasets, empty-week rendering, trend math, division-by-zero guard, audit-JSON wiring, schemaVersion bump, parseable-date filtering, markdown column order, baseline-cutover constant.
- **`tests/bats/cr-automation4-summary.bats`** (NEW) — 19 cases for Automation 4: CLI argument validation (missing `--team`, invalid `--period`, uppercase team, `--from`/`--to` overrides `--period`), inverted-window error, all-8-sections smoke test, `--output` tee behavior, estimate tolerance boundary (±24h), aggregate hit-rate math (60% on 3/5), cycle-time 7-segment ordering and "—" for missing timestamps, pushback rejection grouping + retry count, empty-period messaging, constants (`ESTIMATE_TOLERANCE_HOURS`, `DEFAULT_REPORT_PERIOD`), `_render_markdown_table` empty/single-row, `cr_is_in_window` boundary inclusion. 30/30 pass; full suite 142/142 pass with zero regressions.
- **`docs/homebrew-tap/USER_GUIDE.md`** — New section: "Phase 6: View 3 Throughput & Bi-Weekly Summary". Covers View 3 table interpretation (Pre-CAB / Post-CAB / Delta / Baseline?), trend headline, audit-JSON location, BASELINE_CUTOVER_DATE configuration; covers `kb-cr summary` invocation patterns, the 8 report sections, output destination guidance (no auto-publish), edge cases, exit codes. Version bumped 1.0 → 1.1; TOC updated.
- Plan doc and retrospective live in the local `kanban/plans/XACA-0296/` directory (gitignored); EPIC-0017 row updated locally. Not part of this PR — they're local-only working artifacts per Academy convention (matching XACA-0291–XACA-0295).

### Test: XACA-0453 — [Review] subitem hardening: regex-metachar contract, repeated-prefix, whitespace-only label (PR #368)

- **`lcars-ui/server.py`** — `_strip_label_prefix`: added `or not label.strip()` guard so whitespace-only labels (e.g. `"   "`, `"\t"`) are treated as no-op, matching the documented None/empty behaviour (XACA-0453-010).
- **`lcars-ui/tests/test_server.py`** — Three new test methods in `TestStripLabelPrefix`: `test_label_with_regex_metacharacters` (locks in plain-string-ops contract — `REL.*`, `v(2.10.0)`, `REL[1]`, `REL+QA` all strip literally; XACA-0453-008); `test_repeated_prefix_strips_once` (documents single-pass behaviour — `REL - REL - Sprint 5` → `REL - Sprint 5`; XACA-0453-009); `test_whitespace_only_label_is_noop` (verifies whitespace-only label leaves name unchanged; XACA-0453-010). Total: 175 → 178 tests, all pass.

### Feat: XACA-0453 — strip release shortTitle prefix from name on save (subitem 002)

- **`lcars-ui/server.py`** — Wired `_strip_label_prefix(name, label)` into `handle_create_release` (POST /api/releases) and `handle_update_release` (PUT /api/releases/<id>). On create, if both `name` and `shortTitle` are present, the name is normalized before persisting. On update, if the patch includes `name`, the effective `shortTitle` (from patch or existing record) is used to strip any duplicate prefix before the record is saved; label-only patches do not retroactively rewrite stored names. The `_update_items_release_name` propagation call also receives the normalized name so board items stay consistent.
- **`lcars-ui/tests/test_server.py`** — Added 9 integration-style unit tests covering create-strip, create-no-op, update-both-fields, update-name-only (label from existing record), update-label-only (name unchanged), update-no-op-clean, items-propagation-receives-normalized-name. All 175 tests pass.
### Refactor: XACA-0295 polish — review-bot suggestions addressed (PR #367)

- **`scripts/kb-cr-audit.py`** — Refactor in response to PR #367 review feedback. Extracted `_assign_bucket(cr_ep, first_bucket_ep, num_buckets)` helper so `build_volume_by_type` and `build_volume_by_approver` no longer carry duplicated bucket-lookup loops (reviewer subitem 010). Switched `_iso_week_buckets` to UTC-only week boundaries — every week is exactly 604800 s wide, eliminating the 1-hour DST-week label drift that would have appeared with fixed-offset tzinfo arithmetic (subitem 013). Bucket lookup now O(1) integer division `(cr_ep - first_ep) // 604800` instead of O(n*weeks) linear scan (subitem 014). Added `_cr_created_epoch` helper to centralize the `cr_created_at` / `createdAt` fallback parse. `volumeByApprover` JSON now emits a `bucketOrder` array so the renderer can surface columns from data instead of importing the constant.
- **`scripts/kb-cr-audit-render.py`** — `render_volume_by_approver` now reads `volumeByApprover.bucketOrder` from the audit JSON and derives column headers from the bucket keys (with an acronym map keeping `cab → CAB`); fallback to the legacy default order is in place for older audit JSON readers (subitem 011).
- **`docs/homebrew-tap/USER_GUIDE.md`** — Trimmed Phase 4 inline detail (Automation 1/2/3 fire conditions, examples, configuration knobs) to a 3-bullet summary plus a single-source-of-truth cross-reference to `docs/CR_WORKFLOW.md` (subitems 009 + 012). Phase 5 sections, Emergency Deploy Runbook, and Phase 4 troubleshooting flow are unchanged.
- All polish changes are behaviour-preserving against the existing 112-test bats suite (zero regressions) and produce identical markdown output for the academy-board smoke run.

### Docs: XACA-0295-004 — Phase 5 user guide sections + plan document (EPIC-0017 Phase 5)

- **`docs/homebrew-tap/USER_GUIDE.md`** (NEW) — Comprehensive operator guide for XACA-0295 Phase 5 deliverables. Sections: Views 5 & 6 analytics (how to read, update approver roster); Emergency Deploy Runbook (step-by-step procedure for retroactive CR filing, timestamp verification, false-alarm handling, revert workflow with audit trail). Includes example transcripts and troubleshooting. Target audience: on-call engineers + operations team.
- **`kanban/plans/XACA-0295/XACA-0295_phase5.md`** (NEW) — Phase 5 plan document. Mirrors Phase 4 structure with design decisions (DD1–8: view reuse, ISO week bucketing, empty-week rendering, unattributed-approver handling, median vs mean, E2E-test strategy). Schema additions (none—reuses Phase 1 fields). Files table, architecture (view generators, approver map), emergency-deploy validation flowchart, 9-case test plan, risks/mitigations, out-of-scope deferral. 300+ line reference for Phase 5 reviewers and Phase 6 implementors.

### Test: XACA-0295-003 — Emergency Deploy E2E bats validation (EPIC-0017 Phase 5)

- **`tests/bats/kb-cr-emergency-e2e.bats`** (NEW) — 7-test bats suite covering the EPIC-0017 Phase 5 verification gate. Exercises the full emergency deploy retro-CR flow and validates the timestamp-ordering invariant (`cr_emergency_deployed_at < cr_submitted_at < cr_approved_at`). Tests: (1) retro-CR happy path — inject deploy timestamp, submit, approve, assert invariant and CIO sign-off; (2) break-glass emergency-deploy subcommand writes correct state + timestamps; (3) missing `--justification` exits non-zero with audit trail message; (4) revert from `emergency-deployed` without `--reason` exits non-zero; (5) revert with `--reason` exits 0, strips emergency evidence, records `revert_history`; (6) disabled-team isolation — exits 0 with standard disabled message, board byte-identical; (7) break-glass from `cr-submitted` state (not just `cr-drafted`). Audit JSON cross-check (Test 4 original scope) deferred to XACA-0295-005 smoke pass — `kb-cr-audit.py` board resolution cannot be sandboxed without fragile filesystem coupling. All fixtures live in tmpdirs — no live board ever touched. 112/112 full suite pass with zero regressions.

### Feat: XACA-0295 — CR audit Views 5 & 6 (volumeByType + volumeByApprover) + SCHEMA_VERSION 1.0 → 1.1

- **`scripts/kb-cr-audit.py`** — Added `build_volume_by_type` (View 5) and `build_volume_by_approver` (View 6) builders. Both produce chronological ISO-week bucket lists covering [windowFrom, windowTo] with zero-row weeks for continuity. Shared `_iso_week_buckets` helper avoids duplicated boundary logic. Added `bucket_approver()` helper mapping `cr.approver.login` to `APPROVER_BUCKETS` roster (cab/klohn/sanjeev/ehlers/other/unattributed); matching is case-insensitive. `APPROVER_BUCKETS` and `APPROVER_BUCKET_ORDER` module constants are roster-editable. `emit()` now includes `volumeByType` and `volumeByApprover` keys after `workflowOverhead`. Bumped `SCHEMA_VERSION` 1.0 → 1.1 (additive, no removals).
- **`scripts/kb-cr-audit-render.py`** — Added `render_volume_by_type` and `render_volume_by_approver` section renderers. Both produce GFM tables with one row per week bucket. Empty windows print "No CRs in window."; non-zero `_excludedNoCreatedAt` prints an italic exclusion note. Both sections slot between `render_metrics` and `render_anomalies` in `render()`.

### Fix: XACA-0363 — Remediate SSH command injection in remote-kanban-access.sh (CRITICAL CWE-78)

The `exec` action passed its argument verbatim into an SSH double-quoted command string with no validation, enabling arbitrary remote code execution on the control host. Any string reaching the entry point — including kanban item titles or AMB ping bodies — could be injected.

- **`scripts/remote-kanban-access.sh` `action_exec()`** — Replaced free-form `$command` interpolation with a two-layer defence: (1) an explicit allowlist `case` statement permitting only named read-only `kb-*` commands (`kb-list`, `kb-status`, `kb-show`, `kb-my-status`, `kb-help`, `kb-backlog`, `kb-epic`, `kb-release-list`, `kb-release-show`, `kb-release`, `kb-knowledge-search`, `kb-knowledge-validate`, `kb-sweep`, `kb-audit`, `kb-index-rebuild`, `kb-index-rebuild-all`); (2) a metacharacter scan rejecting any command string containing shell operators (`;`, `&`, `|`, `$`, `` ` ``, `(`, `)`, `<`, `>`, `\`, or control characters) even if the base command word is allowlisted. Write commands (`kb-done`, `kb-run`, `kb-pr`, etc.) are intentionally excluded. `printf %q` escaping applied as defence-in-depth before SSH invocation. 23 unit tests verified allowlist correctness against both legitimate and malicious payloads.
- **Finding reference:** XACA-0338-F-03-001 (CRITICAL, CWE-78 OS Command Injection / CWE-77 Command Injection)

### Feat: XACA-0359 — Formalize CSS and HTML header templates; extend `kb-header()` (EPIC-0015 follow-up)

Amendment to `COPYRIGHT_POLICY.md` formalizing CSS and HTML header templates per §9 (Amendment Process) with Chancellor approval. `kb-header()` native support added for both.

- **Policy amendment:** §4.8 CSS template (block comment `/* */` with Unicode ©); §4.9 HTML template (`<!-- -->` after `<!DOCTYPE>`, ASCII `(c)`); prior §4.8 Year Range Formats renumbered to §4.10. Approval per §9.1 confirmed by user 2026-05-06.
- **`kanban-helpers-additions.sh` `kb-header()` extension:** New `css` rendering option (block-comment style with `/* */` + Unicode ©); `html` option mapped to existing `html-comment` branch. Previously both fell through to hash-style `#` headers.
- **Context:** EPIC-0015 follow-up from XACA-0336. During the LCARS UI + Fleet Monitor copyright backfill, CSS and HTML headers were hand-crafted ad-hoc; now formalized in policy with native tooling support.

### Fix: XACA-0306 — Drop misleading `.sh` extension dance from `cc-aliases`

The dev-team source copy of `claude_code_cc_aliases.sh` defined every `cc-*` alias to launch a `*-prompt.sh` path, but `_cc_launch` immediately stripped the extension via `${prompt_file%.sh}.txt` and read the `.txt` instead. The `.sh` shim files were vestigial — they only re-read the `.txt` — and the swap obscured the real prompt source from anyone reading the alias path. Removing the dance surfaces the actual prompt file in the alias and makes maintenance obvious.

- **`claude_code_cc_aliases.sh`** — Every `cc-ios-*` / `cc-firebase-*` / `cc-android-*` / `cc-freelance-*` / `cc-mainevent-*` / `cc-dns-*` / `cc-academy-*` / `cc-command-*` / `cc-finance-*` alias now passes the `-prompt.txt` path directly to `_cc_launch` (54 alias bodies updated). `_cc_launch` no longer derives `txt_file` from `${prompt_file%.sh}.txt`; it reads the argument as-is and reports errors against `$prompt_file`. The context-aware `cc()` launcher's path-derivation line and `[[ -f ... ]]` guard updated to match.
- **No prompt files deleted in this commit** — the `.sh` shims remain on disk for now (cleaned up in follow-up commit XACA-0306-004 below). A parallel PR mirrors this fix in the `homebrew-tap` template that ships to installer-class systems.

#### XACA-0306-004 — Delete vestigial `*-prompt.sh` shims; migrate `.zshrc_*` to load `.txt` directly

Follow-up cleanup that removes the orphaned shims left behind by the parent commit and migrates the remaining consumers (`home-scripts/.zshrc_*` terminal configs and the master `home-scripts/.zshrc`) to load the `.txt` prompt files directly via a new shared helper. Each shim was a 16–24-line file that did exactly two things — read its sibling `.txt` into `CLAUDE_SYSTEM_PROMPT` via `$(<file)` and define `show_<persona>_prompt` / `copy_<persona>_prompt` helpers (the latter advertised to users by team `*-banner.sh` scripts). Centralizing both behaviors into one helper deletes ~1,500 lines of near-duplicate shell across teams and makes the prompt source path the literal `.txt` file shown in the `.zshrc_*` config (no indirection).

- **`cc-prompt-helpers.sh`** *(NEW, root)* — Single function `cc_load_prompt <txt-path> <persona>` that (a) reads the prompt via `$(<file)` (does not consume stdin, vs. heredocs/cat-pipes which break Claude's TTY initialization) and exports `CLAUDE_SYSTEM_PROMPT`, and (b) defines `show_<persona>_prompt` / `copy_<persona>_prompt` dynamically via `eval` so the helper functions stay backwards-compatible with anything that called them (the team `*-banner.sh` scripts in `ios/`, `android/`, `finance/`, `medical/`, `legal/` advertise these to users on shell startup, plus the `dns-framework/DNS_FRAMEWORK_TEAM_SUMMARY.md` documentation references them by name). `eval` is the only portable zsh path to dynamically name a function; persona names come from controlled `.zshrc_*` source files (not user input) so injection risk is bounded. Comment block at top documents the API and the stdin-consumption rationale.
- **`home-scripts/.zshrc_*` (55 files migrated)** — Every per-terminal config that used to end with `source ~/dev-team/${SESSION_TYPE}/scripts/prompts/${SESSION_CODE}-prompt.sh` (Pattern A: 42 files), `source "$HOME/dev-team/${SESSION_TYPE}/scripts/prompts/${SESSION_CODE}-prompt.sh"` (Pattern B: 5 command files), or `source "$HOME/dev-team/${SESSION_TYPE}/scripts/prompts/${SESSION_TYPE}-${SESSION_NAME}-prompt.sh"` (Pattern C: 7 mainevent files) now ends with the equivalent two-line block: `source ~/dev-team/cc-prompt-helpers.sh` followed by `cc_load_prompt ~/dev-team/${SESSION_TYPE}/scripts/prompts/${SESSION_TYPE}-${SESSION_NAME}-prompt.txt ${SESSION_TYPE}_${SESSION_NAME}`. Migration script (`/tmp/migrate_zshrc.py`, not committed) verified zero residual `-prompt.sh` references after the rewrite.
- **`home-scripts/.zshrc_dns_*` (7 files, special case)** — Every DNS terminal config carried two prompt-loading lines: a (broken) templated `source ~/dev-team/${SESSION_TYPE}/scripts/prompts/${SESSION_CODE}-prompt.sh` that resolved to `~/dev-team/dns/...` (the on-disk dir is `dns-framework/`, not `dns/`), plus a hardcoded `if [ -f ~/dev-team/dns-framework/scripts/prompts/<name>-prompt.sh ]; then source ...; fi` block that was the actually-working source. Both blocks were replaced by one helper call with the correct hardcoded `dns-framework/` path: `cc_load_prompt ~/dev-team/dns-framework/scripts/prompts/dns-<name>-prompt.txt dns_<name>`. The broken templated line was a long-standing latent bug (would have produced "file not found" if anyone had relied on it) — silently obviated now that the redirect is gone.
- **`home-scripts/.zshrc` master (50 alias bodies)** — The master `.zshrc` (copied to `~/.zshrc` on dev machines) carried 50 stale-duplicate `alias cc-X='source <SHIM.sh> && claude --system-prompt "$CLAUDE_SYSTEM_PROMPT" "..."'` lines that pre-dated `claude_code_cc_aliases.sh` becoming the canonical cc-* source. Each alias body's `source <SHIM.sh>` was rewritten to `cc_load_prompt <TXT> <persona>` (preserving the trailing `&& claude ...` chain unchanged), and a single `source ~/dev-team/cc-prompt-helpers.sh` added before the iOS alias section so the helper is loaded before any alias fires.
- **67 `*-prompt.sh` shim files deleted** — `academy/scripts/prompts/*.sh` (4) · `android/scripts/prompts/*.sh` (7) · `command/scripts/prompts/*.sh` (5) · `dns-framework/scripts/prompts/*.sh` (7) · `finance/scripts/prompts/*.sh` (5) · `firebase/scripts/prompts/*.sh` (7) · `freelance/scripts/prompts/*.sh` (7) · `ios/scripts/prompts/*.sh` (6) · `legal/scripts/prompts/*.sh` (6) · `mainevent/scripts/prompts/*.sh` (7) · `medical/scripts/prompts/*.sh` (6). All shared the same shape (verified by lint scan). The `.txt` siblings were preserved — they remain the SSOT for prompt content and are now read directly by `cc_load_prompt` and `_cc_launch`.
- **`scripts/tests/test-cc-aliases-smoke.sh` (NEW)** — XACA-0306-006: zsh smoke test that sources `claude_code_cc_aliases.sh`, discovers every `cc-<team>-<terminal>` function, runs each under `CC_DEBUG=1`, and asserts the alias resolves a non-empty `.txt` prompt. Exit 0 only when 55/55 (current count) pass. Catches typo/rename regressions before they ship — the `.sh` dance silently swapped extensions, so `grep '\.sh'` was never enough; this exercises the launcher end-to-end.
- **Verified zero residual `-prompt.sh` references** across `*.sh` / `*.zsh` / `*.bash` / `*.json` files in the repo (excluding `kanban/` history and the dormant historical migration tooling at `academy/scripts/fix-prompt-scripts.{sh,py}`). Smoke test 55/55 pass.
- **`medical/terminals/.zshrc_medical_*` (6) + `legal/terminals/.zshrc_legal_*` (6)** — XACA-0306-007: caught in PR #361 re-review. The original 004 sweep only covered `home-scripts/.zshrc_*` and missed these personal-team configs that live under `<team>/terminals/` and ship to `$HOME` via `<team>/scripts/install-zshrc.sh`. Without this fix, re-deploying medical/legal terminals after the shim deletion would print `source: no such file or directory`. All 12 files migrated to the same two-line `cc_load_prompt` block; verified by sourcing a sample (`zshrc_legal_chambers` produces a 3,590-char `CLAUDE_SYSTEM_PROMPT` and defines `show_legal_chambers_prompt`).
- **`cc-prompt-helpers.sh` persona-arg sanitization** — XACA-0306-009: defense-in-depth. The persona argument is interpolated into a function name via `eval`. Callers today pass static literals from controlled config files, but the helper now rejects any persona that doesn't match `[a-zA-Z_][a-zA-Z0-9_]*` (the C/POSIX identifier rule) before reaching `eval`. Bounds the blast radius if a future caller passes user input. Verified: `cc_load_prompt /tmp/x 'bad;name'` exits 1 with a clear error message; `cc_load_prompt finance/scripts/prompts/finance-nagus-prompt.txt finance_nagus` continues to work.
- **`scripts/archived/` + `scripts/archived/README.md`** — XACA-0306-010: moved `academy/scripts/fix-prompt-scripts.{sh,py}` and `academy/scripts/new-aliases.txt` to `scripts/archived/`. All three are dormant historical migration tooling whose target files were deleted in the parent commits. Kept on-disk so the historical trail is reconstructable; README explains what each was and the criterion for restoring it (don't, unless the active code can't do what you need).
- **`scripts/tests/test-cc-aliases-smoke.sh` phase 2** — XACA-0306-011: smoke test now also exercises every `<team>/terminals/.zshrc_*` config (12 files for medical + legal). Each is sourced in a clean `zsh -f` subshell with the appropriate `SESSION_TYPE` / `SESSION_NAME` / `SESSION_CODE` env vars and `CLAUDE_SYSTEM_PROMPT` unset; if it remains unset after source, the test fails. Phase 2 cleanly skips when `~/dev-team/cc-prompt-helpers.sh` isn't at the canonical path (worktrees pre-merge) — phase 1 still runs and is the primary regression target. CI workflow installs a symlink to enable phase 2 coverage.
- **`.github/workflows/cc-aliases-smoke.yml` (NEW)** — XACA-0306-008: GitHub Actions workflow that runs the smoke test on every PR or develop push that touches `claude_code_cc_aliases.sh`, `cc-prompt-helpers.sh`, the smoke test itself, any `*-prompt.txt`, or any `.zshrc_*`. Symlinks `$HOME/dev-team` → `$GITHUB_WORKSPACE` so the helper resolves at the canonical path and phase 2 runs end-to-end.

### Chore: XACA-0336 — LCARS UI + Fleet Monitor copyright header backfill (EPIC-0015)

Apply DoubleNode copyright headers to all in-scope source files under `lcars-ui/` and `fleet-monitor/`, per `COPYRIGHT_POLICY.md` §2.1/2.2/2.3 (academy team config: range template, year `2026 - 2025`, owner `DoubleNode.com`, license `MIT`). Closes the EPIC-0015 child for these two trees.

- **Header coverage:** 168 in-scope files now carry a copyright header (~159 modified + 9 already-headered preserved). Vendor/minified bundles in `lcars-ui/js/vendor/` are excluded (third-party).
- **Templated languages via `kb-header`:** shell (`#`), Python (`#`), JS/TS (`//`), Markdown (`<!--  -->`).
- **Hand-crafted templates** for languages not in §4 of the policy:
  - **CSS** — `/* … */` block comment (matches the markdown HTML-comment visual style).
  - **HTML** — `<!--  -->` comment block. When `<!DOCTYPE html>` is present it stays on line 1 and the header inserts on line 2 (browsers require DOCTYPE first).
- **Shebang rule honored:** for shell/Python files starting with `#!`, line 1 is preserved unchanged and the header is inserted on line 3 with a blank-line separator.
- **Idempotency / skip detection:** the apply helper skips files whose first 20 lines already contain `Copyright (c)|Copyright ©`. Three files were initially false-positive-skipped because the word `DoubleNode` appears in their content (not in a copyright line) — `lcars-ui/css/lcars.css`, `fleet-monitor/server/public/lcars2/lcars-doublenode.html`, `fleet-monitor/server/public/lcars2/js/lcars-doublenode-app.js` — those were patched manually by the main agent. A future iteration should tighten the heuristic to `Copyright \(c\)|Copyright ©` only.
- **Test verification:** `fleet-monitor/server` Node tests **137/137 PASS**. `lcars-ui` pytest passes 556 tests; 8 pre-existing flaky failures in `tests/test_ccusage_weekly_heuristics.py::TestTimeToReset` (clock-relative assertions against unmocked `datetime.now()`) are reproducible on `develop` without these changes — not introduced by this work.

### Feat: XACA-0177 — Save and restore worktree/project dir on `ccc` resume

`ccc` now `cd`s back into the project directory that was active when a Claude session was saved, before running `claude --resume`. Prevents orphaned saved sessions when the shell drifts back to the default team-repo path between exit and resume — common when users `cd ~` between sessions or jump in/out of worktrees.

- **`claude_code_cc_aliases.sh` `_cc_save_session`** — Sidecar file format extended from `<uuid>|<name>` to `<uuid>|<name>|<project_dir>`. The new third field is `$PWD` at save time. Header comment updated to document the format.
- **`claude_code_cc_aliases.sh` `_cc_derive_session_name`** — Strips `|` from the derived name (replacing with space) before truncation. Closes a record-corruption hole where a kanban task title or transcript-derived name containing a literal pipe could split into trailing fields and leak into the dir slot.
- **`claude_code_cc_aliases.sh` `_cc_saved_session_label`** — Reads three vars instead of two so `saved_name` no longer absorbs `name|dir` (zsh `read` puts excess fields into the last var). Without this, every team's banner script was about to start displaying `Task Name|/Users/.../worktree-path` instead of just the task name.
- **`claude_code_cc_aliases.sh` `ccc()`** — Reads the third field, `cd`s into it before `--resume` if it's non-empty, differs from current `$PWD`, and exists. Fallback path warns to stderr and continues from current `$PWD` if the saved dir is gone; no abort.
- **Backward compat** — Legacy 1-field (uuid only) and 2-field (uuid + name) sidecars still work. Empty trailing vars from `IFS='|' read` fall through the `[[ -n "$saved_dir" ]]` guard. No migration step needed.
- **Cross-repo follow-up** — `homebrew-tap/share/templates/aliases/cc-aliases.sh` (separate repo, not in this PR) reads sidecars with a raw `$(<"$session_file")` and will need a parallel update before the next tap release; otherwise installed systems will pass `uuid|name|dir` to `claude --resume` and fail UUID validation. Tracked separately because the tap is prohibited from this dev machine (per CLAUDE.md M3Pro rule).
- **Test coverage** — 7-case verification: syntax check, pipe-strip in derive, 3-field write contract, label reader 3-field round-trip, 2-field legacy compat, four `ccc` cd subcases (empty / matches PWD / differs and exists / dir gone), and end-to-end name-display invariant.

### Fix: XACA-0357 — CR tab: surface activity log + repair state-change refresh

Two LCARS UX gaps reported against the CHANGE REQ tab:

1. **Activity log was unreachable for CRs without a doc file.** The per-row DOCS button was gated on `cr_doc_link` / `cr_confluence_url` presence (`_renderRow` in `lcars-cr-tab.js`). Test CRs and freshly-drafted records have no doc link, so the button — and therefore the activity-log fetch nested inside the modal it opens — was hidden. The activity endpoint `/api/kanban/cr/<id>/activity` is purely CR-keyed and works fine without a doc.
2. **State changes left the table stale.** The success and 409-RELOAD paths in `_doSubmitTransition` both reached for `window.refreshBoardData(...)`, an undefined global (zero definitions in the entire repo). The `typeof === 'function'` guard silently fell through, so after a successful state transition the dialog closed but the row's STATE badge kept showing the old value until the next periodic auto-refresh.

Fixes:
- **`lcars-ui/js/lcars-cr-tab.js`** — DOCS column renamed to **DETAIL** in both the column header and the per-row button. The button is now always emitted (no `hasCRDoc` gate); clicking it opens the existing CR detail modal which already handles the no-doc case with friendly guidance ("No local CR document found.") plus the metadata block and activity log. Modal title rewritten from `CR DOCUMENT:` to `CR DETAIL:` to match. The two `window.refreshBoardData` call sites swapped to the canonical `loadBoardData()` (defined in `lcars.js`, returns a Promise) followed by an explicit `renderChangeReqList()` — `renderBoard()` doesn't itself re-render the CR table, so the explicit call is required to repaint the STATE badge after the underlying JSON is reloaded. Fallback path (server echoes `data.cr` but `loadBoardData` is unavailable) also now calls `renderChangeReqList()` so the row reflects the new state. `loadBoardData` added to the eslint globals comment.
- **`lcars-ui/css/lcars-cr-tab.css`** — Removed the now-unused `.cr-docs-placeholder` rule (the empty-cell span it styled is no longer emitted).

### Docs: XACA-0294-009 — CR workflow operator runbook + Phase 4 automation documentation

Comprehensive operator-facing documentation for Phase 4 CR automations, including
installation, configuration, troubleshooting, and schema reference.

- **`docs/CR_WORKFLOW.md` (NEW)** — Complete operator runbook for the CR workflow
  and Phase 4 automations (XACA-0294). Sections:
  - Overview: Purpose of CR workflow and Phase 4 automation landscape
  - Automation 1: 24h drafted reminder — trigger conditions, jitter explanation,
    idempotency, output format, state filtering, and disable mechanism
  - Automation 2: Approval-signal detection — scaffolding-only behavior (manual
    default), the two heuristics (label match + heading regex), false-positive
    risk analysis, per-team configuration, and recommended monitoring period
    before enabling auto-approve
  - Automation 3: Deploy-window delay flag — one-shot idempotency, trigger
    condition, output format, lifecycle, and per-team disable option
  - Operator runbook: install (dry-run first, then install), verify (LaunchAgent
    status, log inspection), manual testing (--once with flags), status check, and
    uninstall procedure
  - Troubleshooting: diagnosis steps and resolutions for six common scenarios
    (daemon not firing, reminders firing too often, Auto 2 candidate detected
    but not approved, LaunchAgent flap-restart, etc.)
  - Configuration reference: cr-automations.json schema, per-team fields, default
    values, and three worked examples (conservative, strict, custom)
  - Schema fields reference: cr_drafted_reminder_last_at, delay_flagged_at,
    cr_approval_candidate_at — type, lifecycle, when to manually edit
  - Cross-references to design doc, feasibility report, and glossary
- **No homebrew-tap template parity changes required.** The kanban-helpers.template.sh
  sources kb-cr.sh from the scripts directory; Phase 4 daemon changes are
  installed separately and don't require template updates.

### Test: XACA-0294-008 — Bats coverage for cr-lifecycle-monitor + schema fields

Comprehensive, isolated, deterministic bats test coverage for the Phase 4
daemon and schema idempotency fields.

- **`tests/bats/cr-lifecycle-monitor.bats` (NEW)** — 42 tests covering the
  full `cr-lifecycle-monitor.py` state machine via Python-level unit tests
  (no board I/O, no shell side effects, no LaunchAgent installation).
  - Auto 1: 9 cases — fire at 27h, periodic reminder, recent-reminder no-op,
    under-min-jitter no-op, state filter (non-drafted), crSupport gate,
    dry-run log prefix, jitter spread (low-jitter fires at 24h / high-jitter
    does not), missing/malformed createdAt.
  - Auto 3: 13 cases — fires when window passed, DD4 one-shot idempotency,
    future window, null/missing/empty window, all four terminal states (DD5),
    cleanup posture (delay_flagged_at stays set on terminal CRs), dry-run log,
    malformed window, hours_late computation.
  - Cross-cutting: 5 cases — --team scoping, --no-auto3-enabled disables Auto3
    only, auto3_enabled=True calls both, flap-prevention exit 0, crSupport gate
    short-circuits both autos.
  - CLI contract: 3 cases — --help flags, --auto3-enabled default True,
    --no-auto3-enabled sets False.
  - Helper unit tests: 7 cases — jitter range/determinism, _parse_iso,
    get_team_automations_config, TERMINAL_CR_STATES constant.
  - All tests use deterministic jitter math (SHA-1 precomputed for fixture IDs)
    to construct ages guaranteed inside/outside the firing window.
- **`tests/bats/kb-cr-container.bats`** — Extended with 16 new tests (34 total,
  18 existing all pass):
  - Round-trip preservation (3 cases): `cr_drafted_reminder_last_at`,
    `delay_flagged_at`, and `cr_approval_candidate_at` survive subsequent
    `kb-cr add-item` and `kb-cr submit` invocations without mutation.
  - Schema validator (13 cases): `cr-schema-validator.py` invoked against
    fixture boards with each Phase 4 field set to valid ISO 8601 (pass),
    malformed string (fail + field named in error output), null (pass),
    absent (pass); plus one combined test with all three fields valid.

### Feat: XACA-0294-006 — Per-team LaunchAgent installer for cr-lifecycle-monitor

Ships the per-team LaunchAgent infrastructure for `cr-lifecycle-monitor.py`,
mirroring the XACA-0350 pattern used by the Confluence poller.

- **`homebrew-tap/share/templates/kanban/cr-lifecycle-monitor-plist.template`
  (NEW)** — Plist template using `{{PYTHON3_PATH}}`, `{{AITEAMFORGE_DIR}}`,
  `{{USER_HOME}}`, `{{TEAM_NAME}}` substitution (identical convention to
  `cr-confluence-poller-plist.template`). `StartInterval` is 86400 s (24h,
  per DD6). Daemon invoked with `--daemon --team <T> --interval 86400
  --auto3-enabled` so Auto 3 is active out-of-the-box when XACA-0294-005
  lands. `KeepAlive: false` prevents launchd flap-restart on config errors.
- **`homebrew-tap/libexec/installers/install-cr-lifecycle-monitor.sh` (NEW)**
  — Standalone installer with `--install` (default), `--uninstall`, `--status`,
  and `--dry-run` modes. Reads `~/.config/aiteamforge/cr-automations.json`
  (primary) or `confluence-credentials.json` (fallback) for the team list.
  Graceful exit-0 when neither file exists. Team-name regex guard
  `[a-zA-Z0-9_-]+` and jq preflight mirror XACA-0350-014/016 fixes.
- **`homebrew-tap/libexec/installers/install-kanban.sh`** — Added
  `install_cr_lifecycle_monitor_launchagent()` and
  `uninstall_cr_lifecycle_monitor_launchagent()` functions; wired both into
  `install_kanban_system()` and `uninstall_kanban_system()` so the full setup
  wizard installs the lifecycle monitor alongside the confluence poller.
- **`homebrew-tap/share/config/cr-automations.json.example` (NEW)** — Sample
  config documenting the Phase 4 per-team automation schema with default
  values for `ios`, `android`, and `firebase` teams. `auto_approve_enabled`
  ships `false` per DD2 (false-positive safety).

### Feat: XACA-0294-003 — Auto 1: cr-lifecycle-monitor.py 24h drafted reminder

New daemon `scripts/cr-lifecycle-monitor.py` implements Auto 1 of the XACA-0294
Phase 4 lifecycle automations: scans CR container records on team board JSON files
and fires a 24h reminder once per window for every CR in `cr-drafted` state.

- **`scripts/cr-lifecycle-monitor.py` (NEW)** — Daemon mirroring the shape of
  `cr-confluence-poller.py`. Flags: `--once`, `--daemon`, `--interval` (default
  86400 = 24h), `--team`, `--dry-run`, `--verbose`, `--auto3-enabled` (reserved
  for XACA-0294-005). Reads optional `~/.config/aiteamforge/cr-automations.json`
  for per-team overrides; falls back to defaults if absent.
  - Auto 1 (`_auto1_drafted_reminder_pass`): fires when `crState == cr-drafted`
    and age >= 24h × per-CR-deterministic jitter. Jitter is SHA-1(cr_id)[:8]
    mapped to [0.9, 1.1] — same CR always gets the same jitter factor; spread
    across a population eliminates thundering-herd. Idempotency key:
    `cr_drafted_reminder_last_at` on the CR record (written via `_kb_jq_update`
    and activity event via `kb-cr activity record drafted_reminder
    hours_in_drafted=<N>`). State filter: skips non-`cr-drafted` CRs entirely.
  - Auto 3 hook (`_auto3_delay_flag_pass`): stub that returns False; scan loop
    already calls it behind `--auto3-enabled` guard so XACA-0294-005 only needs
    to implement the function body — no loop restructuring required.
  - Per-team LaunchAgent isolation: exits 0 on team-scoped config issues to
    prevent launchd flap-restart (mirrors confluence-poller flap-prevention rules).
  - Uses `zsh -c` (not `bash -c`) for subprocesses — kanban-helpers.sh requires
    zsh for glob qualifier syntax (.DN); bash parse fails at line 8789.
  - LaunchAgent install ships separately in XACA-0294-006.

### Feat: XACA-0294-004 — Auto 2: Confluence approval-signal detection (cr-submitted → cr-approved candidate)

Extends `cr-confluence-poller.py` with a second scan pass (Auto 2) that detects
approval-readiness signals on CR-Proper Confluence pages for cr-submitted CRs.
Ships scaffolding-only by default (`--auto-approve` off). Per DD2 in the design doc,
false-positive auto-approvals in CAB workflow are catastrophic; this is opt-in.

- **`scripts/cr-confluence-poller.py`**
  - `AUTOMATIONS_CONFIG_FILE` constant + `load_automations_config()` / `get_team_automations_config()` — reads `~/.config/aiteamforge/cr-automations.json` for per-team overrides. Missing file is silent; all teams use defaults (`auto_approve_enabled=false`).
  - `find_cr_submitted_crs(team)` — mirrors `find_cr_drafted_crs`; returns cr-submitted CRs with `_board_file` augmented.
  - `fetch_cr_proper_page_data(team, cr, creds)` — fetches labels + storage HTML from the CR-Proper Confluence page in a single `?expand=body.storage,metadata.labels` request.
  - `_ApprovalHeadingParser` — HTMLParser subclass that collects h1/h2/h3 with next-`<p>` approver capture.
  - `detect_approval_signal(page_data, team_automations)` — applies two independent heuristics (label match, heading regex) and returns `(signal_source, approver_name)` or `None`.
  - `record_approval_candidate(...)` — writes `cr_approval_candidate_at` idempotency field, records `cr_approval_candidate_detected` activity event, and (if `--auto-approve` + `auto_approve_enabled`) calls `kb-cr approve`.
  - `scan_team_approval(team, ...)` — second-pass orchestrator; honours idempotency and `cr_proper_url`-absent guard.
  - `scan_team()` — refactored to run Pass 1 (cr-drafted) then Pass 2 (`scan_team_approval`). Signature extended with `team_automations` and `auto_approve` params.
  - `--auto-approve` CLI flag added (default `False`). Description emphasises opt-in nature.
- **`homebrew-tap/share/templates/kanban/cr-schema.json`** — schema bumped to v2.2.0. Adds `cr_approval_candidate_at` optional ISO 8601 field to `crContainer` (Auto 2 idempotency key). Also adds `cr_drafted_reminder_last_at` and `delay_flagged_at` as explicit crContainer fields (previously documented in description only; now first-class schema entries).
- **`scripts/cr-schema-validator.py`** — updated to v2.2 reference. check 2b validates all three new optional timestamp fields: if present, must match ISO 8601 UTC format; absent is silently valid.
- **`tests/bats/cr-confluence-poller.bats` (NEW)** — 24 bats cases covering label detection, heading regex detection, per-team config overrides, idempotency guard, --auto-approve scaffolding, and no-signal no-op path. All 24 pass.
- **`kanban/plans/XACA-0294/XACA-0294_auto2_feasibility.md` (NEW)** — Feasibility report: heuristic rationale, false-positive risk analysis, recommended default (`auto_approve_enabled: false` for all teams), and operator runbook for enabling auto-approve after a 30-day monitoring period.

### Feat: XACA-0294-005 — Auto 3: deploy-window delay flag in cr-lifecycle-monitor.py

Implements `_auto3_delay_flag_pass` in `scripts/cr-lifecycle-monitor.py` — the
deploy-window delay flag automation (XACA-0294 Phase 4, Auto 3).  Full state
machine per DD4 (one-shot) and DD5 (skip terminal states).

- **`scripts/cr-lifecycle-monitor.py`**
  - `_auto3_delay_flag_pass(cr, team, dry_run)` — replaces stub with full
    implementation. State machine:
    - `crState IN {deployed-prod, cr-rejected, cr-closed, emergency-deployed}` → no-op
      (DD5: terminal filter; cleanup posture matches Auto 1 — field left set,
      LCARS suppresses badge via `delay_flagged_at != null AND crState NOT IN terminal`).
    - `deploy_window_planned` null/empty → no-op.
    - `delay_flagged_at` already set → no-op (one-shot — DD4).
    - `now_utc <= parse_iso(deploy_window_planned)` → no-op (window not yet passed).
    - All other conditions → fire: record `deploy_window_delayed` activity event
      with `deploy_window_planned=<ISO> hours_late=<N>` metadata; write
      `delay_flagged_at = now_iso` via `_kb_jq_update` (same atomic-write path
      as Auto 1's `cr_drafted_reminder_last_at`).
    - `--dry-run`: logs `[DRY-RUN] would set delay_flagged_at for <id>
      (hours_late=<N>, deploy_window_planned=<ISO>)` without writing.
  - `--auto3-enabled` flag default changed from `False` to `True`
    (`argparse.BooleanOptionalAction`). Rationale: Phase 4 ships all three
    automations enabled; LaunchAgent installer (XACA-0294-006) will use the
    default. Use `--no-auto3-enabled` for emergency disable or staged rollout.
    Per-team `auto3_enabled` override in `cr-automations.json` is a planned
    enhancement (not yet implemented; noted in flag help text).
  - `_scan_team` default for `auto3_enabled` param updated from `False` → `True`
    to match argparse default.
  - Module docstring updated: Auto 3 is now fully described including one-shot
    semantics and cleanup posture.

### Feat: XACA-0294-007 — LCARS CHANGE REQ tab: drafted-24h + delayed automation badges

Surfaces Phase 4 automation state visually on each CR row in the CHANGE REQ tab. No API or server change — both fields are read directly from the CR record (committed to the schema in XACA-0294-002).

- **`lcars-ui/js/lcars-cr-tab.js`**
  - `_normalizeCR`: passes `cr_drafted_reminder_last_at` and `delay_flagged_at` through from the raw CR record into the view-object.
  - `_DELAY_TERMINAL`: constant Set of terminal states that suppress the DELAYED badge (`deployed-prod`, `cr-rejected`, `cr-closed`, `emergency-deployed`).
  - `_automationBadges(item)`: new helper returning HTML for zero, one, or both badges. Returns empty string when neither condition is met — rows with no active automations are byte-equivalent to pre-XACA-0294-007.
    - ⏰ DRAFTED 24h+: rendered when `cr_drafted_reminder_last_at` is non-empty AND `crState == 'cr-drafted'`. Tooltip: last-reminder ISO timestamp.
    - ⚠ DELAYED: rendered when `delay_flagged_at` is non-empty AND `crState` is not in `_DELAY_TERMINAL`. Tooltip: `deploy_window_planned` + `delay_flagged_at` ISO timestamps.
  - `_renderRow`: calls `_automationBadges(item)`. When badges are present, wraps the EDIT STATE button + badge block in `.cr-edit-cell-wrap` (flex column) inside `cr-col-edit`. No new column; no layout change to rows with no active automations.
- **`lcars-ui/css/lcars-cr-tab.css`**
  - `.cr-edit-cell-wrap` — flex-column wrapper for EDIT STATE button + badges stack.
  - `.cr-automation-badges` — flex-column container for one or both badge spans.
  - `.cr-automation-badge` — shared base (8px Antonio, border-radius 3px, padding 1px 6px; mirrors `.cr-badge`).
  - `.cr-badge-drafted-24h` — amber palette: `var(--lcars-amber, #ffcc00)` on `rgba(255,204,0,0.16)` background. Reuses the existing amber token already in use for `cr-badge-major` and `cr-state-submitted`.
  - `.cr-badge-delayed` — crimson palette: `var(--lcars-crimson, #ff4466)` on `rgba(255,68,102,0.16)` background. Reuses the existing crimson token already in use for `cr-badge-emergency` and `cr-state-emergency`.

### Feat: XACA-0294 — CR schema v2.1: Phase 4 automation idempotency keys

Bumps `cr-schema.json` to v2.1.0 and updates the validator to accept two new optional fields on the `crContainer` record. Both fields are forward-compatible — absent means the automation has not yet fired for that CR; no board rewrite required.

- **`homebrew-tap/share/templates/kanban/cr-schema.json`** — `_meta.schema_version` bumped from `2.0.0` to `2.1.0`. Two optional ISO 8601 UTC string fields added to `crContainer`:
  - `cr_drafted_reminder_last_at` — idempotency key for Auto 1 (24h drafted-reminder daemon). Set each time a reminder fires while `crState == cr-drafted`; cleared when the CR transitions out of `cr-drafted`. Missing = reminder has never fired.
  - `delay_flagged_at` — idempotency key for Auto 3 (deploy-window delay daemon). Set once on first detection that `now > deploy_window_planned` and the CR is not in a terminal state. Cleared on transition to `deployed-prod`, `cr-rejected`, or `cr-closed`. Missing = not delayed. One-shot: subsequent scans are no-ops while the field is present.
- **`scripts/cr-schema-validator.py`** — Updated to v2.1 reference. Adds `_is_iso8601_utc()` helper and per-field validation in check 2 for both new fields: if present, must be a non-empty ISO 8601 UTC string matching `YYYY-MM-DDTHH:MM:SSZ` (fractional seconds permitted); if absent, silently accepted as "automation not yet fired."
### Feat: XACA-0252 — sync-tap.sh expansion for fleet-monitor/server

Adds dev-team→tap sync coverage for `fleet-monitor/server/` via the existing
`sync_dir` helper in `sync-tap.sh`, which now accepts trailing `find` predicates
as additional exclusions. The fleet-monitor caller passes these inline:

- **Deploy infra:** `Dockerfile`, `.dockerignore`, `fly.toml`, `deploy.sh`
- **Legacy debranded files (hyphen-only):** `doublenode.*`, `doublenode-*`, `mainevent.*`, `mainevent-*`, `lcars-doublenode.*`, `lcars-doublenode-*`, `lcars-mainevent.*`, `lcars-mainevent-*` (XACA-0139 sweep). Underscore variants (`mainevent_doctor_avatar.png`, etc.) are CURRENT shippable team assets and DO sync.
- **Dev-only:** `tests/` directory (base `sync_dir` already excludes `node_modules/`).

Files that exist in source AND tap (e.g. `public/lcars/js/lcars-charts.js`) are
overwritten by source — source is authoritative. Tap-only files with no source
counterpart (`lib/`, `routes/`, `vendor/`) are preserved untouched — `sync_dir`
only copies from source, never deletes.
The `--commit` mode updated to also stage `fleet-monitor/server/` in the inner
submodule git add step.

### Feat: XACA-0335 — CHANGE REQ tab: AGE column (XACA-0305 review verdict)

Adds an **AGE** column to the LCARS CHANGE REQ tab between STAGE AGE and DOCS, fulfilling the verdict in `kanban/plans/XACA-0305/REVIEW.md` (CAB-stakeholder review of "AGE vs REQUESTED-AT vs both vs neither").

- **`lcars-ui/js/lcars-cr-age-helpers.js` (NEW)** — Pure-JS module with `AGE_TERMINAL_STATES` set, `computeCRAgeMs(item, now?)`, and `formatRelativeAge(ms)` (15m/3h/2d/3w/2mo bucketing). Dual export: `window.lcarsCrAgeHelpers` for the browser bundle, `module.exports` for Node-side unit tests. Mirrors the `lcars-cr-metrics.js` SSOT pattern. Loaded from `index.html` immediately before `lcars-cr-tab.js`.
- **`lcars-ui/js/lcars-cr-tab.js`** — Consumes the extracted helpers via `window.lcarsCrAgeHelpers`; the only AGE-specific code that stays in the IIFE is `_ageCell(item)` (touches the DOM contract: `escapeHtml` + `.cr-age` / `.cr-age-empty` CSS classes) and the AGE branch of `_sortItems`. `<td class="cr-col-age">` and `<th class="cr-col-age">AGE</th>` inserted between STAGE AGE and DOCS. `CR_COL_COUNT` bumped to 12 after the rebase that brought in XACA-0349's EDIT column (children-row colspan tracks the constant automatically). Each cell carries a `title=""` tooltip with the absolute ISO `cr_created_at` so the REQUESTED-AT use case is satisfied via hover instead of a second column.
- **Sort integration** — `'AGE'` added to filter-bar `SORT_VALUES`. `_sortItems` gains an `AGE` branch that mirrors the existing STAGE-AGE pattern (oldest-first; nulls/terminal states sink to the bottom). Default sort remains STATE.
- **Terminal-state suppression** — AGE renders as `—` when `crState ∈ {deployed-prod, emergency-deployed, cr-rejected}` or both timestamp sources are absent. Once a CR is done, "how old is it" stops being a queue-management signal and would just add visual noise. The terminal-state set is the canonical SSOT used by both the helpers module and the existing `SAVED_VIEWS['active-pipeline']` predicate.
- **`lcars-ui/css/lcars-cr-tab.css`** — New `.cr-col-age` width rule (75px, center, nowrap) plus `.cr-age` / `.cr-age-empty` text styling. Responsive hide rule at `<600px` matches DEPLOY WINDOW behavior so the table stays readable on narrow viewports.
- **`lcars-ui/tests/test_cr_age_helpers.js` (NEW)** — 34 unit tests covering all `formatRelativeAge` boundary buckets (0/30m/59m/60m/23h/23h59m/24h/6d/6d23h/7d/21d/29d/30d/60d/365d + clock-skew tolerance), `computeCRAgeMs` happy path with injectable `now`, terminal-state suppression for each of the three terminal states, fallback chain (`cr_created_at` → `addedAt`, both empty, both missing), and invalid-input guards (null/undefined item, garbage date string). Includes an SSOT invariant test that greps `lcars-cr-tab.js` for the canonical `TERMINAL` set and asserts membership equivalence with `AGE_TERMINAL_STATES` — fails CI if either set drifts without the other being updated.
- **Header comment** — "9-column tabular layout" → "10-column tabular layout"; the count had drifted across XACA-0293/0308-004/0353 and this brings it back into agreement with the rendered layout.

### Feature: XACA-0329 — kb-cr revert / undo / revert-history (backwards lifecycle)

Three new `kb-cr` subcommands walk a CR backwards through its lifecycle as an **administrative correction**, distinct from `cr-rejected` (which records a CAB-process pushback). All three are container-only operations — multi-item CRs propagate atomically because state lives on `.crs[i]` and all `itemIds[]` siblings read from the container.

- **`kb-cr revert <CR-ID|item-id> [--to <state>] [--reason "<text>"]`** — walks back to any earlier canonical state. `--to` defaults to a heuristic predecessor (the candidate state with the latest timestamp on the container; ties broken by preferring the higher rank, so rapid same-second forward writes still land on the most recent canonical step). Forward walks (target rank ≥ current) are refused. `--reason` is REQUIRED when reverting from `emergency-deployed` (mandatory audit trail for break-glass corrections).
- **`kb-cr undo <CR-ID|item-id> [--reason "<text>"]`** — one-step convenience: same as `revert` with no `--to`. Rejects the `--to` flag.
- **`kb-cr revert-history <CR-ID|item-id>`** — read-only display of `.crs[i].revert_history[]` entries with timestamps, actor, operation type (revert/undo), from→to states, reasons, stripped state list, and per-state field-snapshot audit trail.
- **Schema:** new `.crs[i].revert_history[]` array. Each entry preserves the snapshot of every stripped field — nothing is lost. `pushback_count` and `pushback_notes` are PRESERVED on revert from `cr-rejected`/`cr-held`: those CAB events did happen and the audit trail of them stays. Revert is a correction of the state-write itself, not erasure of CAB process history.
- **Per-state strip table** (canonical state ladder, ranks 0–60): cr-drafted → no fields; cr-submitted → `cr_submitted_at`; cr-rejected → `cr_rejected_at`; cr-held → `cr_held_at`; cr-approved → `cr_approved_at` + `approver`; implementing → `cr_started_dev_at` + `cr_started_test_at`; deployed-dev → `cr_deployed_dev_at`; deployed-prod → `cr_deployed_prod_at`; emergency-deployed → `cr_emergency_deployed_at` + `emergency_justification`.
- **Item-id dispatcher** routes `kb-cr revert TITEM-XXXX` through `crAssignment.crId` to the container variant; items without `crAssignment` are refused (no v1 per-item revert path — revert is container-only by design).
- **Built on XACA-0327** (unified dispatcher + draft-to-container bridge). Activity log entries of type `cr_state_reverted` are emitted alongside the `revert_history[]` write so audit consumers see the operation.
- **Regression coverage:** 56 new tests in `tests/test-kb-cr.sh` (T11–T20) — revert-to-drafted, revert-across-approval, forward-walk-refused, multi-item propagation, undo, revert-history rendering, pushback_count preservation, emergency-deployed reason enforcement, no-crAssignment refusal. Suite total: 124 passed / 0 failed.
- **Gotcha banked for AMB:** zsh's lowercase `path` parameter is bound to `PATH`; declaring `local path=""` inside a function empties PATH for the function's lifetime. Use `field_path` or any other name. Cost me 30 minutes during 002 — the `_kb_jq_update` failure mode (`mktemp not found`) is the diagnostic to look for.

### Fix: XACA-0353 — CR table: deploy-window TZ display + column polish

iOS team's two CRs with `deploy_window_planned: "2026-05-11T00:00:00Z"` were rendering as **May 10** in the LCARS CR tab. Root cause: `_formatDeployWindow` parsed the value via `new Date(...)` then called `toLocaleDateString` without a `timeZone`, so a date stored as midnight UTC formats to the *prior* calendar day for any viewer west of UTC. The stored value is correct; only the display layer was wrong.

- **`lcars-ui/js/lcars-cr-tab.js` `_formatDeployWindow`** — Detect midnight-UTC values (the convention for date-only fields) and format them with `timeZone: 'UTC'` so the calendar date label is preserved regardless of viewer TZ. Non-midnight values (a real planned deploy time) are still formatted in the local timezone, now with date *and* time so the clock face is visible to the reader.
- **TYPE / STATE merged into one column** (`cr-col-typestate`) — TYPE badge stacked above STATE badge in a single cell. Cell auto-sizes to its content (`width: 1%; white-space: nowrap`). Drops the separate `cr-col-type` and `cr-col-state` `<th>`/`<td>` and their width rules.
- **TITLE wraps to 2 lines** — `.cr-title-text` switched from `white-space: nowrap` + ellipsis to a `-webkit-line-clamp: 2` clamp; full title still available via `title=""` tooltip.
- **PUBLISHED column removed** — Confluence link is already reachable via the DOCS popup, and `cr-drafted` semantically *means* "uploaded to Confluence". Drops `<th class="cr-col-published">`, `<td>`, `publishedCell` rendering, `confluenceUrl` local in `_renderRow`, the `.cr-published-link` CSS block, and the responsive `display: none` rule. `CR_COL_COUNT` 12 → 10 (children-row colspan tracks it automatically). Confluence URL still flows through to the DOCS modal — only the dedicated table column is gone.

### Chore: XACA-0342 — Migrate `inject-time-context.sh` to install.sh-based deployment; remove dev-team copy

The `UserPromptSubmit` time/date injection hook has been moved to install.sh-based deployment via the DoubleNode/claude-context-tick package. The dev-team-tracked copy at `claude-hooks/inject-time-context.sh` is being removed in favor of the OSS-distributed version installed to `~/.claude/hooks/inject-time-context.sh` by the package's `scripts/install.sh`.

- **Removed:** dev-team-tracked copy of `claude-hooks/inject-time-context.sh`. No longer a source of truth; the OSS repo (DoubleNode/claude-context-tick) is authoritative.
- **Changed:** UserPromptSubmit hook in `~/.claude/settings.json` now invokes `~/.claude/hooks/inject-time-context.sh` installed by the OSS package, decoupling dev-team deployment from the hook's release cycle.
- **Added:** SessionEnd hook entry pointing at `~/.claude/hooks/session-end.sh` (new in claude-context-tick v0.2.0) for lazy-sweep garbage collection of per-session state files. Depends on XACA-0341 release.

### Fix: XACA-0348 — kb-cr detach leaves legacy v1 fields on backlog item

`kb-cr detach <item-id>` correctly cleared the v2 `crAssignment` object but left the legacy v1 flat fields (`cr_id`, `cr_type`, `cr_created_at`, `crState`) populated on the backlog item. The attach/draft path writes all four for backward compat with LCARS v1 readers; detach was only undoing one side of that write, leaving stale CR linkage that confused LCARS, `kb-cr ls`, and downstream scrubs (discovered during XACA-0308 CR scrub on 2026-05-06).

- **`scripts/kb-cr.sh`** (`_kb_cr_container_remove_item`) — Extended the `del()` in the atomic `_kb_jq_update` to clear `crAssignment, cr_id, cr_type, cr_created_at, crState` together, mirroring the four fields written by attach/draft. `del()` is a safe no-op on items that lack a given key, so v2-only items (no legacy fields) are unaffected.

### Refactor: XACA-0350 — Per-team cr-confluence-poller LaunchAgents

Refactors the CR Confluence Poller from a single global LaunchAgent to one
LaunchAgent per team. Isolates failures: a bad team config only affects that
team's poller; others keep running independently.

- `homebrew-tap/share/templates/kanban/cr-confluence-poller-plist.template` —
  parameterized with `{{TEAM_NAME}}` in Label, `--team` arg, and per-team log
  paths (`~/Library/Logs/aiteamforge/cr-poller/<team>.{out,err}.log`)
- `homebrew-tap/libexec/installers/install-kanban.sh` — installer reads
  `confluence-credentials.json` teams dict via jq; renders and loads one plist
  per team; migrates (unload + rm) the legacy global plist; uninstaller
  glob-removes all `com.aiteamforge.cr-confluence-poller.*.plist`
- `scripts/cr-confluence-poller.py` — updated module docstring; edge cases:
  when `--team` is given but not found in credentials (or the credentials
  file itself is absent), daemon now warns and exits 0 (clean) instead of 1
  so launchd does not flap-restart per-team agents

### Feat: XACA-0349 — `cr-closed` terminal CR state + per-row EDIT STATE button

Adds `cr-closed` as a manual-only terminal state to the CR lifecycle (10th state, alongside the existing 9). Closed CRs are hidden from the default ALL filter and only surface when the new gray/dim CLOSED filter pill is active — keeps the active-pipeline view focused without losing archive history. The EDIT STATE button moves from the CR-DOCS modal header to a per-row control on the main CR tab so state edits don't require opening the docs modal first.

- **`scripts/kb-cr.sh`** — New `kb-cr close <CR-ID> [--reason "<text>"]` verb. Container-only; reachable from any non-closed state; writes `cr_closed_at` timestamp via the standard `_kb_cr_lifecycle_advance` flock-safe path. **Does NOT increment `pushback_count`** (this is an archive operation, not a rejection cycle). Optional `--reason` is appended to a new `closed_reason` field. The `transition` verb's allowlist is also extended so the operational state-edit dropdown reaches `cr-closed`. Idempotent guard rejects re-close on already-closed CRs.
- **`lcars-ui/server.py`** — `_CR_VALID_STATES` (frozenset) and `_CR_REQUIRED_FIELDS` (dict) extended with `cr-closed` (zero required fields — no extra payload needed for archive close).
- **`lcars-ui/css/lcars-cr-tab.css`** — New `.cr-state-closed` slot: dimmed gray (`rgba(107,114,128,...)`) with `text-decoration: line-through` to read as archived rather than active or errored.
- **`lcars-ui/index.html`** — New CLOSED filter pill at the end of the CR-state pill group.
- **`lcars-ui/js/lcars-cr-tab.js`**:
  - `CR_STATE_CLASS`, `_CR_STATES`, `_CR_STATE_FIELDS`, `_STAGE_ANCHOR` all extended with `cr-closed`.
  - `_itemMatchesFilters` reworked: `stateFilter === 'all'` now explicitly excludes `cr-closed`; the new explicit `cr-closed` filter still shows them. Saved-view presets that use `'all'` inherit the new "hide closed" behavior.
  - EDIT STATE button removed from `_showCRDocModal` header; new per-row `cr-col-edit` column added (CR_COL_COUNT 12 → 13) with click handler wiring through `_crByIdCache[crId]` → `_showCRStateChangeDialog(view)`.
  - `_doSubmitTransition` made modal-aware via `wasDocsModalOpen` flag — guards `_hideCRDocModal()` / `_showCRDocModal(freshView)` calls so the dialog works whether launched from the docs modal or the per-row button.
- **`tests/cr-lifecycle/cat4-schema-validity.bats`** — Hardcoded `crStates length is exactly 9` and the expected-list assertion updated to 10 with `cr-closed` appended.
- **`tests/cr-lifecycle/cat5-container-commands.bats`** — Local `statuses[]` validation array extended with `cr-closed`.
- **Schema PR (separate repo):** Counterpart change to `share/templates/kanban/cr-schema.json` lives in `DoubleNode/homebrew-aiteamforge` PR #5. Submodule pointer bump in dev-team is deferred until that PR merges — operational state lists in `server.py` and `kb-cr.sh` are independent of the schema validator, so the dev-team change ships standalone.

### Fix: XACA-0352 — iTerm2 window-width shrink on layout-update tick

Sibling of XACA-0340 (height) on the horizontal axis. Even after the height-feedback fix shipped, the **whole iTerm2 window** continued to narrow over time. Root cause: `resize_pane_by_env` and `reset_all_agent_panels` set only the agent panel's `preferred_size = (30, target_h)` and call `await tab.async_update_layout()`. The main pane's `preferred_size` is set once in `split_agent_panel` to `(170, 50)` and never tracks user-driven window growth, so `async_update_layout` sees a preferred-sum of ~200 cols and pulls the window down toward it on every tick where the agent panel has drifted outside the shell-side ±5 col tolerance.

- **`iterm2_window_manager.py`** (both `resize_pane_by_env` and `reset_all_agent_panels`) — Capture the parent `Window` frame with `async_get_frame()` *before* calling `async_update_layout`, restore it with `async_set_frame()` *after*. Cancels the layout-driven horizontal pull without disturbing pane ratios.
- **No flicker in steady state.** Both functions early-return when the agent panel is already at `target_cols`; the get/update/set frame sequence only runs when an actual resize is needed.
- **Mirrored to `homebrew-tap/share/scripts/iterm2_window_manager.py`** so the next dev-team→tap sync does not regress (per the sync-direction-inversion lesson logged in XACA-0340 / EPIC-0018).

### Fix: XACA-0340 — Restore iTerm2 height-feedback fix in dev-team source

Agent panels were slowly shrinking iTerm2 windows over time. Root cause: commit `09b98f57` (2026-04-16, *"Prevent iTerm2 window height growth via pane resize feedback loop"*) patched `homebrew-tap/share/scripts/iterm2_window_manager.py` only — the dev-team source copy `~/dev-team/iterm2_window_manager.py` was never updated. A subsequent dev-team→tap sync (commit `13c68d98`) then overwrote the tap-side fix with the still-broken dev-team copy, silently reverting the fix in both directions.

This is a textbook **sync-direction inversion**: a tap-side fix without a dev-team-side counterpart gets quietly reverted on the next forward sync. Tracked under `EPIC-0018` (Single-source-of-truth for shared scripts) for a structural prevention.

- **`iterm2_window_manager.py`** — Port commit `09b98f57` byte-for-byte onto the dev-team source. Adds `min_rows` parameter (default 50) to `resize_pane_by_env` and `reset_all_agent_panels`; stops round-tripping `session.grid_size.height` into `preferred_size.height` (chrome/divider padding mismatch causes the loop), preserving the stable preferred height when the pane is already tall enough.
- **`--min-rows` CLI flag** exposed on both `resize-pane` and `reset-panels` actions for tunability without code changes.
- **Diff stats match the original fix exactly** (37 lines changed, 30+/7-).

### Chore: XACA-0337 — Publish `inject-time-context.sh` as public OSS (DoubleNode/claude-context-tick)

The `UserPromptSubmit` time/date injection hook (`claude-hooks/inject-time-context.sh`) has been extracted to a standalone public-facing repository at https://github.com/DoubleNode/claude-context-tick. The OSS release ships a sanitized hook (no internal paths or ticket references), `install.sh`/`uninstall.sh` ergonomics that safely merge into `~/.claude/settings.json`, a portable test suite (7 tests), and a GitHub Actions CI workflow covering macOS + Ubuntu.

- **Header pointer added.** The dev-team-side copy of the hook now carries a public-source-of-truth comment block pointing to the DoubleNode repo. The internal copy may drift; the OSS repo is authoritative for new portability fixes and functionality.
- **No behavioral change** to the dev-team-side hook. D1/D2/D3 fixes (stdin-read of session_id, silent best-effort state I/O, positive-whitelist sanitization) are byte-identical between the internal and OSS versions at this release.
- **CI catch:** OSS test runner originally used bash-4-only `mapfile`; macOS GitHub runners ship bash 3.2. Replaced with a portable `while IFS= read -r` loop. Worth flagging for any other shell scripts we might publish — local Homebrew bash 5.x masks this on developer machines.

### Fix: XACA-0339 — CR tab linked-item ID pill readability

The linked-item ID pills (`XIOS-####`) under each expanded CR row were rendering with browser-default `<button>` chrome — `.cr-child-id-copy` had no CSS, so the UA stylesheet's bevelled box was showing through, making the IDs visually muddy and hard to read against the dim children-row background. The top-level `CR-IOS-...` IDs read dim too: `.cr-id-mono` was pastel cyan `#99ccff` at 10 px Courier with no weight.

- **`lcars-ui/css/lcars-cr-tab.css`** — `.cr-id-mono` bumped to `font-weight: 700` and a brighter `#ccddff` so every CR/item ID renders crisply at 10 px monospace.
- **`lcars-ui/css/lcars-cr-tab.css`** — `.cr-child-id-copy` folded into the same selector group as `.cr-id-copy` (transparent LCARS pill, hover state, copied-flash green). Replaces the UA-default button chrome with proper LCARS styling and brings the green copy-confirmation flash to linked-item pills as well.

### Fix: XACA-0333 — Team Config UI hardening (XACA-0332 advisory follow-ups)

Resolves five `[Review]` subitems deferred from PR #342. All changes are in `lcars-ui/server.py` and `lcars-ui/js/lcars.js`; no user-facing behavior change beyond more robust placeholder detection.

- **XACA-0333-001 — Stale lock cleanup.** The advisory `*.json.lock` files used by `_write_copyright_config` and `handle_update_team_config` are now `unlink()`-ed in the `finally` branch after `LOCK_UN`, so a successful POST no longer leaves zero-byte clutter in `~/.aiteamforge/` or the kanban dir. A startup `_sweep_stale_locks()` removes stranded zero-byte locks (mtime > 60s old) left by killed prior processes; targets `~/.aiteamforge/*.lock` and every canonical `<team>-board.json.lock` reachable via `TEAM_KANBAN_DIRS`.
- **XACA-0333-002 — GET caching for `/api/team-config`.** `_read_copyright_config` now uses an mtime-based class-level cache keyed by `team-paths.json`'s `st_mtime_ns`. Read path: stat → match → reuse. Write path: invalidate cache after the atomic `os.replace` succeeds. Thread-safe via `_TEAM_PATHS_CACHE_LOCK`. Eliminates the disk read on every Team Config UI visit.
- **XACA-0333-003 — Server-side `is_placeholder` flag.** Server is now the single source of truth for the TBD-sentinel string set (`_COPYRIGHT_PLACEHOLDER_VALUES = {'<TBD-per-engagement>', '<TBD>'}`). The GET and POST responses surface a per-field `copyright.is_placeholder = { copyright_owner: bool, ... }` map. The JS `_COPYRIGHT_TBD_VALUES` hardcoded list is gone — `_populateCopyrightFields` reads `is_placeholder[key]` and applies the `tbd-warning` class accordingly. Adding new placeholder strings is now a one-line server change.
- **XACA-0333-004 — Skip board write on copyright-only saves.** `handle_update_team_config` now wraps the board.json fcntl lock + read + merge + atomic write in `if clean_team_config:`. A copyright-only POST sets `board_data = None` and skips the board entirely. Eliminates a needless lock + 4-syscall fsync on the most common admin save.
- **XACA-0333-005 — Complete POST response payload.** Response now always includes the saved `teamConfig.copyright` block (with `is_placeholder`), read fresh via `_read_copyright_config(team)` after the writes succeed. When 004's guard skips the board write, the response re-reads the board for `crSupport`. The JS local-form fallback in `saveTeamConfigCopyright` is removed (dead code).
- **XACA-0333-006 — Harden `teamConfig: null` guard.** PR #347 review advisory. `dict.get('teamConfig', {})` only uses the default when the key is absent — not when it's `None`. A hand-edited board JSON with `"teamConfig": null` would crash `setdefault`. Switched to `dict.get('teamConfig') or {}` in the GET handler (line 6849) and the POST response builder (line 7088 + 7091). Cannot happen via server-written boards but cheap defensive guard.

Files changed: `lcars-ui/server.py` (+~155 / -~25), `lcars-ui/js/lcars.js` (+7 / -6).

### Refactor: XACA-0304 — Converge BACKLOG and CHANGE REQ filter bars onto `lcars-filter-bar.js`

The CHANGE REQ tab previously carried its own bespoke filter-bar implementation
(~180 LOC of duplicate state, wiring, persistence, and UI-sync code) that
paralleled the canonical `createFilterBar()` factory used by BACKLOG. This
change converges both consumers onto the shared component. No end-user
behavior change.

- **`lcars-ui/js/lcars-filter-bar.js`**: extended with four optional config
  blocks — `searchIds`, `pillGroups[]` (multi/single pill modes),
  `sortControl` (N-value cycle button), and `customDropdowns[]` (generic
  `<select>` wiring). Defaults preserve original BACKLOG behavior; BACKLOG
  init unchanged.
- **`lcars-ui/index.html`**: CR filter-bar HTML is now static markup (was
  JS-injected via a `container.innerHTML` template literal).
- **`lcars-ui/js/lcars-cr-tab.js`**: deleted `_filterState`,
  `_loadFilterState`, `_saveFilterState`, `_wireCRFilterBar`,
  `_syncStatePills`, `_syncTypePills`, plus `FILTER_KEY` / `SORT_VALUES`
  constants (~180 LOC). Replaced with a single `createFilterBar({...})`
  call. Net: −81 lines in this file.
- Saved-view chips (THIS WEEK / AWAITING APPROVAL / EMERGENCY 30D) now drive
  `fb.setState(preset)`; an `_applyingSavedView` re-entrancy guard plus a
  non-sort-fields snapshot prevent the active chip from clearing on sort
  cycles or self-applied presets.
- localStorage keys unchanged (`lcars-queue-filter` for BACKLOG,
  `lcars-change-req-filter` for CR) — no migration needed.

#### Round 2 — PR #344 review feedback (2 items)

- **CR platform dropdown `.active` parity** (`lcars-ui/index.html`,
  `lcars-ui/js/lcars-cr-tab.js`): added `id="cr-platform-wrap"` to the
  wrapping `<div>` and pointed the `customDropdowns` `dropdownId` at the
  wrapper instead of the `<select>` itself, so `.active` toggles on the
  same element type as the OS / release / epic / category dropdowns.
- **`fb.snapshot(keys)` hoist** (`lcars-ui/js/lcars-filter-bar.js`,
  `lcars-ui/js/lcars-cr-tab.js`): moved the CR-tab's hand-coded
  `_filterSnap` helper into `createFilterBar` as a public method.
  Deterministic across array values (sort + join) and null/undefined
  (empty string). CR tab now calls
  `_filterBar.snapshot(SAVED_VIEW_DIVERGE_KEYS)` — future consumers can
  request their own non-sort snapshots without duplicating field lists.

### Fix: XACA-0308 PR #345 review feedback (013, 014, 015, 016)

- **013** — `_kb_cr_publish` was invoking `claude --no-interactive` but the real CLI flag is `-p` / `--print`. Replaced with `claude -p` so the live publish path actually runs the skill (dry-run path was unaffected). Mirrored in `homebrew-tap/share/scripts/kb-cr.sh`.
- **014** — `_kb_cr_create_doc_file` template lookup #1 hardcoded `~/dev-team/worktrees/xaca-0308/templates/...`. Replaced with `git rev-parse --show-toplevel` so any active worktree finds its own `templates/cr-doc-template.md`. Same fix mirrored in homebrew-tap.
- **015** — `serve_cr_exists` now `.resolve()`s the full `cr_docs_dir` path (matches `serve_cr_content`). Eliminates a low-risk inconsistency where a `cr-docs/` symlink could pass the prior containment check unresolved.
- **016** — `migrate-cr-schema-phase3.py::_locate_template` had the same hardcoded worktree path as 014. Replaced with `Path(__file__).resolve().parent.parent` (script-relative repo-root resolution) so the migration uses whichever repo's template ships with the running script.

### Fix: XACA-0308-012 — kb-cr draft no longer creates orphan CR container when item already has crAssignment

- **Defect** found by Phase 3 testing (subitem 007): `kb-cr draft <ID>` re-run on an item that already had a `crAssignment.crId` would mint a SECOND CR container in `.crs[]`, leaving the original orphaned and the item with two CRs in scope.
- **Fix:** `_kb_cr_draft` now reads `crAssignment.crId` after preamble; if non-empty, prints a NOTE referencing the existing CR + doc path and exits 0. Pattern matches the existing "doc already exists" idempotency message.
- Mirrored in `homebrew-tap/share/scripts/kb-cr.sh`.

### Chore: XACA-0308-006 — Apply Phase 3 CR schema migration to all crSupport.enabled boards

- **Migration executed** against 3 boards where `crSupport.enabled=true`: academy (no-op — zero CR records), android, ios.
- **iOS board** (`ios-board.json`): `CR-IOS-20260505-0618` and `CR-IOS-20260505-0632` — `cr_doc_link` (Confluence URLs) moved to `cr_confluence_url`; `cr_doc_link` removed from both CR container records. Atomic write via `.tmp` rename. Backup written: `ios-board.json.bak-xaca0308-phase3-20260506-151202`.
- **iOS stubs created**: `kanban/cr-docs/XIOS-0618-CR.md` and `kanban/cr-docs/XIOS-0632-CR.md` from Phase 3 template with migration note header.
- **Android board** (`android-board.json`): `CR-ANDROID-20260505-0001` had no `cr_doc_link` — no board JSON changes needed. Stub `kanban/cr-docs/XAND-0643-CR.md` created.
- **Command/Firebase** boards skipped (`crSupport.enabled=false`).
- **XIOS-0631 finding**: item has `cr_id=null` and is not in any CR container's `itemIds[]` — no stub was created (correct behavior; plan doc reference predates subitem 001 board state).
- **Idempotency confirmed**: second `--apply` produced zero writes.
- **Migration log**: `scripts/migration-logs/XACA-0308-phase3-20260506-151202.txt`

### Feat: XACA-0308-005 — Main Event CR skill v5.0.0: Phase 3 Publish Mode (read local md as source, write Confluence URL back)

- **`~/.claude/skills/Main Event CR/SKILL.md` v5.0.0** — New **Phase 3 Publish Mode** section added. Skill now supports being invoked by `kb-cr publish` with a local markdown file path as the authoritative content source (`<team-kanban>/cr-docs/<ITEM-ID>-CR.md`). Mode is additive — existing Release / Deploy / On-Demand Mode paths are fully preserved.
  - **Trigger detection** — Mode detection priority updated: Phase 3 triggers ("Scope source: local markdown file at", path ending in `-CR.md`, "publish this CR doc") are checked FIRST, before all other mode checks. When triggered, skips Steps 1–2 and executes Phase 3 steps only.
  - **Content sourcing** — Skill reads the local md verbatim as the page body. No generation from RELNOTES or PRs. Does not strip or reformat — the file is the source of truth.
  - **Platform auto-detection** — Item ID prefix routes to platform parent page: `XIOS` → iOS (2867494915), `XAND` → Android (2867265546), `XFBS` → Firebase (2867068932). Fallback to CR folder root.
  - **Create-vs-update idempotency** — When `existing_confluence_url` hint is provided: extracts page ID from URL path, fetches current version via `getConfluencePage`, calls `updateConfluencePage` with `version.number + 1`, same title. When no existing URL: calls `createConfluencePage`. If update fails with 404-equivalent, falls back to create.
  - **Parseable output line** — Emits `Confluence URL: <full-url>` exactly once on its own line (no ANSI, no decoration) as required by `kb-cr publish`'s grep parser (XACA-0308-002 contract).
  - **Board write-back** — After successful publish, calls `bash -c 'source ~/dev-team/kanban-helpers.sh && kb-cr _set_confluence_url <ITEM_ID> <URL>'`. Failure is logged clearly and exits non-zero — no silent failure.
  - **Activity log** — Written by `_set_confluence_url` (type=confluence_published); skill does NOT duplicate the log entry.
  - **Dry-run path** — When `--dry-run` is present in invocation or `KB_CR_PUBLISH_DRY_RUN=1`: reports what would be published without calling MCP tools or `_set_confluence_url`; emits `[DRY-RUN] Confluence URL: (not published — dry-run mode)`.
- **`~/.claude/skills/Main Event CR/README.md` v5.0.0** — Updated to list Phase 3 Publish Mode as the fourth CR mode; version history entry added.
- **Skill install chain** — Skill lives at `/Users/Shared/Development/Main Event/dev-team/skills/Main Event CR/` (source of truth); exposed via two-hop symlink: `~/dev-team/skills/Main Event CR/` → `~/.claude/skills/Main Event CR/`. Not in the worktree git history — skill changes noted in PR description.

### Feat: XACA-0308-004 — LCARS UI: CR popup footer link + CHANGE REQ PUBLISHED column

- **`lcars-ui/js/lcars.js` `switchDocTab`** — CR tab branch: after rendering markdown body, appends `.cr-confluence-footer` link block when `data.confluenceUrl` is truthy in the `cr-content` response. Empty string = no footer rendered. Applies only to `tabType === 'cr'`; plan and retro tabs unchanged.
- **`lcars-ui/js/lcars-cr-tab.js` `_normalizeCR`** — Passes `cr_confluence_url` from the raw CR container record through to the normalized view object.
- **`lcars-ui/js/lcars-cr-tab.js` `_renderRow`** — `hasCRDoc` check extended to include `cr_confluence_url`; new `confluenceUrl` local; PUBLISHED column cell rendered with `&#128196;` page icon link when `confluenceUrl` is set, empty otherwise.
- **`lcars-ui/js/lcars-cr-tab.js` `renderChangeReqList`** — PUBLISHED column header (`<th class="cr-col-published">PUBLISHED</th>`) added between PUSHBACKS and DOCS.
- **`lcars-ui/js/lcars-cr-tab.js` `CR_COL_COUNT`** — Incremented from 10 to 11 to match the new column (keeps `colspan` on child rows correct).
- **`lcars-ui/js/lcars-cr-tab.js` `_showCRDocModal`** — `cr-content` fetch success path: appends `.cr-confluence-footer` block when `data.confluenceUrl` is set.
- **`lcars-ui/css/lcars-cr-tab.css`** — `.cr-col-published` column width (60px, centered); `.cr-published-link` icon link style using `--lcars-cyan`; `.cr-confluence-footer` separator + link block using `--lcars-cyan`; `.cr-confluence-icon` sizing; responsive: `.cr-col-published` hidden below 600px.

### Feat: XACA-0308-002 — kb-cr CLI: draft writes Phase 3 canonical path; new publish subcommand

- **`scripts/kb-cr.sh` `_kb_cr_create_doc_file`** — Rewired to write `<team-kanban>/cr-docs/<ITEM-ID>-CR.md` (Phase 3 canonical path). Template resolution checks worktree path first, then main-repo, then `AITEAMFORGE_DIR`, then homebrew-tap. Substitutes Phase 3 placeholders: `{{ITEM_ID}}`, `{{CR_ID}}`, `{{CR_TYPE}}`, `{{DRAFT_DATE}}`, `{{TEAM}}`, `{{CR_STATE}}`, `{{TITLE}}`, `{{SUMMARY}}`, `{{DEPLOY_WINDOW}}`, `{{ITEM_LIST}}`, `{{CONFLUENCE_URL}}`. Idempotent: if `<ITEM-ID>-CR.md` already exists, emits NOTE and returns 0 without overwrite. Does NOT write `cr_doc_link`. Echoes canonical path as last stdout line for callers.
- **`scripts/kb-cr.sh` `_kb_cr_draft`** — Uses `_KB_CR_SKIP_DOC_FILE` export guard to suppress doc creation inside `_kb_cr_container_create` subshell, then calls `_kb_cr_create_doc_file` directly with `item_id` as 7th arg so filename is `<ITEM-ID>-CR.md` not `<CR-ID>-CR.md`.
- **`scripts/kb-cr.sh` `_kb_cr_publish`** (new) — Reads canonical local md, verifies existence, resolves CR container, prints invocation block. `KB_CR_PUBLISH_DRY_RUN=1` stops before skill call. Live path invokes `claude --no-interactive` with Main Event CR skill On-Demand Mode prompt; captures Confluence URL from output; calls `_kb_cr_set_confluence_url` to write URL back to `.crs[]` record.
- **`scripts/kb-cr.sh` `_kb_cr_set_confluence_url`** (new internal) — Writes `cr_confluence_url` on `.crs[cr_container_idx]` (container record, not backlog item — consistent with where `cr_doc_link` lived). Appends `confluence_published` activity log event. Exposed as `kb-cr _set_confluence_url <id> <url>` for skill use (subitem 005).
- **`scripts/kb-cr.sh` `_kb_cr_show`** — Phase 3 block appended: prints local md path (exists or hint to run `kb-cr draft`) and `cr_confluence_url` when set, or hint to run `kb-cr publish`. Always visible regardless of which display branch fired.
- **`scripts/kb-cr.sh` dispatch table** — `publish` and `_set_confluence_url` entries added.
- **`scripts/kb-cr.sh` `_kb_cr_help`** — `draft`, `publish`, `_set_confluence_url`, `show` help text updated for Phase 3.
- **`homebrew-tap/share/scripts/kb-cr.sh`** — Mirror committed on homebrew-tap `main` branch (commit `6272ecc`); outer submodule pointer advanced.

### Feat: XACA-0308-003 — server.py: cr-content + cr-exists look up canonical Phase 3 path

- **`lcars-ui/server.py` `serve_cr_exists`** — Refactored to return `true` iff `crSupport.enabled` AND `<team-kanban>/cr-docs/<item-id>-CR.md` exists on disk. Item ID sanitized (alphanumeric + dash only). Containment check narrowed to `<team-kanban>/cr-docs/`. All `cr_id` / `crAssignment` back-pointer lookups removed.
- **`lcars-ui/server.py` `serve_cr_content`** — Refactored to read canonical local md directly. Returns 404 with `"run kb-cr draft <id> first"` message when file absent. Containment check narrowed to `<team-kanban>/cr-docs/`. `crSupport.enabled` check enforced (disabled team returns 404, no info leak). `cr_confluence_url` read from matching `crs[]` record and surfaced in response payload as `confluenceUrl` for popup footer rendering (subitem 004). All `cr_doc_link` reads, legacy URL/path fallback chain, and `change-requests/` directory glob removed.

### Feat: XACA-0308-001 — CR doc Phase 3 foundation (template + migration script + kb-cr.sh doc strings)

- **`templates/kanban/cr-doc-template.md`** — Updated CAB-required sections: Summary, Scope, Risk & Impact (table), Rollback Plan, Deploy Window, Approvers (table), Test Evidence (checklist), Pushback History. Added `{{ITEM_ID}}`, `{{DRAFT_DATE}}`, `{{TEAM}}`, `{{CONFLUENCE_URL}}` placeholders. Header comment explains canonical path (`<team-kanban>/cr-docs/<ITEM-ID>-CR.md`) and publish workflow.
- **`scripts/migrate-cr-schema-phase3.py`** — New idempotent migration script. Dry-run by default; `--apply` required to write. Iterates every team board where `crSupport.enabled=true`. For each crs[] record with `cr_doc_link`: moves Confluence URLs to `cr_confluence_url` (if not already set), deletes non-URL paths. For residual v1 items with direct `cr_doc_link`: same logic. Creates `<team-kanban>/cr-docs/<ITEM-ID>-CR.md` stubs from template when missing. Primary item ID selected by matching numeric suffix to CR ID (e.g. XIOS-0618 for CR-IOS-20260505-0618). Backs up board JSON before any write; atomic write via `.tmp` rename. Dry-run confirmed clean across all `crSupport.enabled` teams.
- **`scripts/kb-cr.sh`** — Doc strings + help text updated: header Phase 3 section describes `cr_confluence_url`, canonical `cr-docs/<ITEM-ID>-CR.md` path, and `cr_doc_link` deprecation. `set-doc-link` function comment marked deprecated. `_kb_cr_create_doc_file` comment notes the v002 path change. `_kb_cr_help` adds Phase 3 schema section, `publish` and `draft` Phase 3 notes. No behavior change.
- **`homebrew-tap/share/scripts/kb-cr.sh`** — Same doc-string updates applied to installer mirror. No behavior change.

### Feat: XACA-0293 — CAB Workflow Phase 3: Active CR Pipeline + Cycle-Time Dashboard

- View 1 — Active CR Pipeline saved-view chip (filters non-terminal cr-* states) + STAGE AGE column with color-coded aging badge (green/yellow/red, tunable in Phase 7).
- View 2 — PIPELINE | CYCLE TIME sub-tab toggle inside #section-change-req. 8 chart-card tiles: 7 segment rollups (avg/median/sample count over rolling 14-day window) + estimate-vs-actual tile (avg deploy_estimate_delta_days + HIT/EARLY/LATE percentage breakdown, color-coded by aggregate health).
- New modules (browser-only, dependency-free, flag-gated): lcars-cr-metrics.js (pure-JS cycle-time derivation per cr-schema.json crDerived; reusable by Phase 6 Automation 4), lcars-cr-segment-tiles.js (7 segment tiles), lcars-cr-estimate-tile.js (8th tile), lcars-cr-poll-bus.js (single shared 5s poll bus serving all tile modules).
- Largest-remainder (Hamilton) rounding in rollupEstimateDelta so HIT + EARLY + LATE sum to exactly 100%.
- Tile renderers bail when CYCLE TIME pane has [hidden] attribute — no wasted innerHTML writes when user is on PIPELINE sub-tab.
- 6-CR fixture (cr-metrics-fixture.json) with hand-computed expected values + reconciliation doc + Node smoke check + 15-case node:test suite (test_cr_metrics.js).
- Schema invariants honored: derived cycle-time fields computed at READ TIME only — never persisted. Flag-off invisibility preserved (no fetches, no DOM writes when crSupport.enabled=false).

### Fix: XACA-0332 follow-up — splash placement (round 2) + Component Label width

- **Splash copyright placement** (`lcars-ui/css/lcars.css`): Switched from `margin-top: auto` (flex-based bottom alignment, which overflowed the viewport because total content exceeded available height on smaller windows) to `position: absolute; bottom: 12px` anchored to a `position: relative` `.startup-container`. The data-scroll animation goes back to its original `flex: 1; min-height: 100px` (fills available space naturally); the copyright sits glued to the bottom independent of content height. Container's bottom padding bumped from 20px to 48px to leave room for the absolutely-positioned copyright. `pointer-events: none` so the copyright doesn't intercept the splash's click-to-skip handler.
- **Team Config "Component Label" field width** (`lcars-ui/css/lcars.css`, `lcars-ui/index.html`): Added `.team-config-input-wide` modifier (460px) and applied it to the Component Label input. The default 220px field was cramped for typical values like `DoubleNode Dev-Team Infrastructure (AITeamForge)` (47 chars).

### Feat: XACA-0332 — Surface copyright config in Team Config UI + fix splash placement

- **Team Config screen** — surfaces the per-team copyright fields (`copyright_owner`, `license_type`, `component_label`, `year_start`, `notice_template`) from `~/.aiteamforge/team-paths.json` (schema v2). Previously only `crSupport.enabled` was shown.
  - Backend (`lcars-ui/server.py`): `serve_team_config` now joins the copyright block into the response under `teamConfig.copyright`. `handle_update_team_config` accepts a `copyright` payload, validates types + enum values (license_type ∈ {MIT, Proprietary, Client-Owned, BSD-3-Clause}, notice_template ∈ {range, single}, year_start 1990–2100), and persists via fcntl-locked atomic write with a timestamped backup of `team-paths.json`. Other team blocks and the team's own `kanban_dir`/`working_dir`/`lcars_port` fields are untouched.
  - Frontend (`lcars-ui/index.html`, `js/lcars.js`, `css/lcars.css`): new "Copyright Configuration" section with five form rows. Freelance teams whose `copyright_owner` is the `<TBD-per-engagement>` placeholder render with a bright TBD-warning border so the operator sees they need filling.
- **LCARS startup splash placement** (`lcars-ui/css/lcars.css`): copyright footer now sits at the bottom of the splash screen via `margin-top: auto`, with `.startup-status` no longer flex-growing and `.startup-data-scroll` given a fixed 220px height. Animation visually moves up the page; copyright footer is anchored to the bottom under it.
- **Three follow-up `[Review]` subitems** under XACA-0332 (advisory, not blocking):
  - 002: stale `team-paths.json.lock` cleanup on server kill (matches existing board JSON locking pattern)
  - 003: no caching on `/api/team-config` GET (fine for low-visit admin UI; flag if call frequency grows)
  - 004: TBD-detection in JS uses a hardcoded placeholder string list — fragile if XACA-0251 ever changes the placeholder format

### Fix: XACA-0331 PR #341 round-2 — review feedback (3 items)

- **`kb-cr show` ITEMS row literal `[0:12]` rendering** — the row formatter had unbalanced parens in the jq slice expression, leaking literal jq syntax into every output row. Replaced complex inline jq formatting with a clean TSV-emitter + shell `printf` for column padding (one batched `_kb_jq_read` call still — same perf, simpler logic). New regression test (#16) asserts `[0:12]` / `[0:15]` / `[0:40]` never appear in `kb-cr show` output.
- **CHANGELOG heading regression** — round-1 commit accidentally clobbered the `### Fixed: XACA-0330 — Post-review fixes from PR #339 review pass` heading, orphaning four XACA-0330 bullet points under the new XACA-0331 section. Heading restored.
- **migrate_board pass-2 ignored `item_filter`** — when two v1 items shared the same `cr_id`, pass-1 (CR-record builder) correctly added only the named item to `itemIds[]`, but pass-2 (crAssignment writer) processed BOTH siblings. Net effect: unnamed sibling got `crAssignment.crId` written but never appeared in `.crs[].itemIds`, breaking the bidirectional invariant. Pass-2 now also respects `item_filter`. Two new regression tests (#17 single-named scope; #18 second-sibling-via-existing-CR-branch completion).

### Feat: XACA-0331 — kb-cr container ergonomics: set-doc-link + migrate-legacy + show enrichment + bats

Follow-up to closed PR #336 (XACA-0326). XACA-0327 (#337) merged to develop with overlapping
attach/detach work using a different signature, so this PR ships only the truly unique remainder
that survives independent of XACA-0327.

- **`kb-cr set-doc-link <CR-ID> <url>`** — new container subcommand. Records a Confluence (or other external) doc URL on a CR record via a single atomic `_kb_jq_update`. Writes `cr_doc_link` + `updatedAt` + board `lastUpdated`. Honours the `crSupport.enabled` gate.
- **`kb-cr migrate-legacy <item-id> [--apply]`** — new shell wrapper around `scripts/migrate-cr-schema.py`. Lifts a single v1-shape backlog item into the v2 container shape (record under `.crs[]` + `crAssignment` back-pointer). Idempotent: no-op on already-v2 items. Defaults to dry-run. Returns the underlying Python exit code (5 = item not found, 6 = no CR data) so programmatic callers can distinguish failure modes.
- **`scripts/migrate-cr-schema.py`**: added `--item <ID>` and `--apply` flags + `migrate_item()` function + `item_filter` parameter on `migrate_board()`. Backwards-compatible with positional batch invocation.
- **`kb-cr show <CR-ID>` enrichment**: layered on top of XACA-0327's single-pass row formatter, adds (a) per-item kanban status column, (b) ROLLUP summary line derived from item-statuses via `group_by` (no hardcoded bucket allowlist), (c) LIFECYCLE progress arrow with `[CURRENT]` marker that uses smart anchored truncation to keep the marker visible across all 6 main-path states + off-path states, and (d) stale-`crTitle` warning when any item's `crAssignment.crTitle` snapshot diverges from the container's current title.
- **`tests/bats/kb-cr-container.bats`** — 16 new bats tests covering: migrate-legacy idempotency / `--apply` / no-CR-data exit-6 / scope-to-named-item regression / set-doc-link write + missing-CR / set-doc-link disabled-team isolation / set-doc-link & migrate-legacy missing-arg branches / lifecycle submit + submit→approve→deploy-dev propagation / `kb-cr show` LIFECYCLE rendering across early/mid/late states / `kb-cr show` ITEMS row render-bleed regression. Complementary to XACA-0327's `tests/test-kb-cr.sh` (which covers attach/detach).

### Fixed: XACA-0330 — Post-review fixes from PR #339 review pass

- `scripts/kb-cr.sh` `_kb_cr_backfill_deploy_timestamps` (XACA-0330-017): silent data loss
  in `--apply` mode — `update_filter+=( … )` array-append converted the string variable
  to an array and dropped `updatedAt`/`lastUpdated` writes. Now uses string-append.
- `scripts/kb-cr-audit.py` `build_workflow_overhead` (XACA-0330-018, XACA-0330-021):
  removed dead `std_ratios` and `median_ratio` aliases.
- `scripts/kb-cr-audit.py` `process_tax.ratioInterpretation` (XACA-0330-019): copy fix —
  ratio is dimensionless (cycle_sec / deploy_sec), not "hours per hour".
- `scripts/kb-cr.sh` `_kb_cr_audit` (XACA-0330-020): added `--team` slug allowlist
  (`[a-z0-9_-]+`) to block path-traversal via output filenames.

### Added: XACA-0330-022 — Shared audit utils module

- `scripts/kb_cr_audit_utils.py` — extracted `humanize_duration` from renderer +
  publisher into a single source of truth. Single function with `min_unit` and `na`
  parameters preserves both call-site styles (renderer: precise/seconds/"n/a";
  publisher: coarse/minutes/"—"/"< 1m"). Both downstream scripts now import.

### Feat: XACA-0328 — CAB Workflow Phase 3.5: CR state lifecycle + activity log + Confluence poller + manual state UI

- **State semantics** — `cr-drafted` now means the CR markdown has been
  published to Confluence as the request page; `cr-submitted` means a
  CR-Proper page link has been appended at the bottom of that request
  page. New `cr_proper_url` field on the CR container record holds the
  detected URL. (`homebrew-tap/share/templates/kanban/cr-schema.json`,
  `lcars-ui/js/lcars-cr-tab.js` for CR-DOCS modal render row.)
- **Per-CR activity log** — new file at
  `kanban/teams/<team>/change-requests/activity/<CR-ID>.json`
  (append-only events[]; oldest-first). Five event types:
  `cr_created`, `cr_published`, `cr_proper_detected`,
  `cr_state_changed`, `cr_field_update`. Writer hooked into
  `_kb_cr_lifecycle_advance` so every transition emits an event
  automatically. Public CLI: `kb-cr activity record|list <CR-ID>`.
  Server endpoint `GET /api/kanban/cr/<CR-ID>/activity`. LCARS modal
  "ACTIVITY LOG" timeline section with type pills (state changes =
  orange, field updates = blue/cyan, lifecycle markers = amber).
- **Confluence poller daemon** (`scripts/cr-confluence-poller.py`) —
  stdlib-only; scans cr-drafted CRs across all teams every 10 min,
  detects appended CR-Proper links via two-rule heuristic (last `<a>`
  matching "CR-Proper" text, fallback to anchor after "CR-Proper"
  heading), writes `cr_proper_url`, transitions cr-drafted →
  cr-submitted via existing kb-cr machinery, emits
  `cr_proper_detected` activity event. LaunchAgent
  `com.aiteamforge.cr-confluence-poller` installed by the aiteamforge
  installer; doctor + validate-install integration. Per-team auth
  config under user config dir; missing config = clean exit with hint.
- **Manual state-change UI** — EDIT STATE button on CR-DOCS modal
  opens an overlay dialog with target-state dropdown (all 9 crStates)
  and per-state conditional fields (approver, pushback_notes,
  hold_reason, emergency_justification, deploy_estimate,
  cr_proper_url). Optimistic concurrency token `expectedUpdatedAt`.
  409 Conflict path renders inline error with RELOAD button.
- **Manual state-change endpoint** —
  `POST /api/kanban/cr/<CR-ID>/transition`. Validates required fields
  per target state; checks `expectedUpdatedAt` against current
  `cr.updatedAt` and returns 409 + `currentUpdatedAt` on stale token;
  applies state + field updates atomically via kb-cr (single
  Perl-flock locking path); writes `cr_state_changed` and any
  `cr_field_update` events; returns updated CR record.

### Added: XACA-0330-004 — CAB Workflow Audit Confluence publish path

- `scripts/kb-cr-audit-publish.py` — Confluence publish path for CAB workflow audit
  (dry-run by default; --apply to publish). Reads collector JSON (from
  `kb-cr-audit.py`), renders Confluence storage format (XHTML macros for callouts,
  tables for metrics/anomalies/per-CR summary), and resolves team → parent page ID
  from built-in config (ios/android/firebase/mainevent). Unknown teams require
  `--parent-page-id` override. Page title defaults to
  `CAB Audit — <Team> — <from> → <to>`. On `--apply`, prints MCP call instructions
  for agent-level create/update (Python cannot call MCP tools directly).

### Added: XACA-0330-005 — `kb-cr audit` dispatch hook

- `kb-cr audit` subcommand — orchestrates collector + renderer + optional Confluence publish for team-scoped CAB workflow audits.

### Added: XACA-0330-007 — skill symlinked into ~/.claude/skills/

- `~/.claude/skills/cab-workflow-audit` symlinked to worktree skill source (temporary).
  **Post-merge action required:** re-symlink to `/Users/darrenehlers/dev-team/skills/cab-workflow-audit`
  once `feature/xaca-0330` lands on develop (tracked in XACA-0330-012).

### Added: XACA-0330-006 — `/cab-workflow-audit` Claude Code skill

- `skills/cab-workflow-audit/SKILL.md` — Claude Code skill wrapping the team-scoped CAB workflow audit pipeline.
  Provides user-friendly command surface and documentation for the audit collector, renderer, and Confluence publisher.
  Supports per-team audit with configurable time window, output formats (JSON/markdown/both), and Confluence publishing.

### Added: XACA-0330-003 — CAB Workflow Audit markdown renderer

- `scripts/kb-cr-audit-render.py` — markdown renderer for CAB workflow audit JSON.
  Consumes the JSON emitted by `kb-cr-audit.py` and produces a structured GFM report:
  header + caveats callout, executive summary, workflow overhead (process tax, component
  breakdown, pushback cost, emergency vs standard, worst offenders), CR performance
  metrics (approval rate, cycle time, state dwell, pushback, emergency rate, platform/type
  breakdowns), anomalies, and per-CR detail with chronology tables.
  CLI: `--in` (default stdin), `--out` (default stdout), `--format md` (confluence slot
  reserved for 004 as NotImplementedError). Module-level `render(dict) -> str` is
  importable by 004. Handles empty windows (n=0) gracefully throughout.

### Added: XACA-0330-002 — CAB Workflow Audit collector

- `scripts/kb-cr-audit.py` — team-scoped CAB workflow audit report collector.
  Reads a team's board JSON and linked activity logs; emits a single JSON document
  per the XACA-0330-001 data model (summary, metrics, workflowOverhead, anomalies,
  per-CR chronology). CLI: `--team` (required), `--from`, `--to`, `--out`, `--pretty`.
  Exit 0 success, 1 unexpected error, 2 user/arg error.
- `kb-cr backfill --deploy-timestamps` — scrapes activity logs for `deploy_started`/
  `deploy_completed` action entries across all items attached to container CRs, then
  proposes `deployStartAt`/`deployCompletedAt` writes as a diff. Dry-run by default;
  requires `--apply` to write. Routed through the existing `backfill` verb.

### Feat: XACA-0251 — Copyright audit, policy, and license decision (gating EPIC-0015 work)

- **Decision:** dev-team root licensed MIT; copyright `Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.`
- **`COPYRIGHT_POLICY.md`** (new, root): canonical policy doc — scope, exclusions, per-language header templates (sh/py/js/ts/rb/md/swift/kt/java), shebang and `(c)` vs `©` rules, year-range formats (`range` vs `single`), application tooling, review discipline, exceptions process. Modeled on DNSFramework conventions.
- **`LICENSE`** (new, root): standard MIT license text with the canonical copyright line.
- **`README.md`**: added `## Credits` and `## License` sections matching DNSFramework canonical pattern.
- **`~/.aiteamforge/team-paths.json`** schema bump v1 → v2: added per-team `copyright_owner`, `license_type`, `component_label`, `year_start`, `notice_template` fields. Self-heal migration applied with sensible defaults for all 20 registered teams (academy, ios, android, firebase, mainevent, command, dns, freelance-*, finance, medical, legal). Backup at `~/.aiteamforge/team-paths.json.v1-backup-*`.
- **`kanban-helpers-additions.sh`** (new, staging): `kb-header` helper — reads team config + file extension, emits canonical comment block per language. Supports `range` (`YYYY - YYYY`, current-year first) and `single` (`YYYY`) templates; auto-detects shebang to insert header at correct position; refuses to render for teams with TBD `copyright_owner` (exit 2). To be integrated into `kanban-helpers.sh` in a follow-up PR.
- **Pilot headers applied** to one file per language (sh/py/js/md), validated against language interpreters/syntax checkers. Templates ratified for bulk-application work under EPIC-0015 children.
- **LCARS UI splash** (`lcars-ui/index.html`, `lcars-ui/css/lcars.css`): added a small copyright footer at the bottom of the startup splash screen — small Antonio uppercase, `var(--lcars-orange)` at 0.5 opacity, software attribution to DoubleNode (the LCARS UI software itself is DoubleNode-owned regardless of which team's data it displays).
- **Bulk-application structure recommendation** (`kanban-tmp/XACA-0251-006-*.md`): two-track EPIC-0015 plan — Track A covers academy team (dev-team + tap; 5 child items), Track B covers other teams (Main Event, DNS, freelance, personal — enabled by schema v2). Cross-cutting rules include preserving file permissions during bulk-apply temp-file insertion (pilot ISSUE-1).
- **Out of scope (deferred):** Homebrew-tap LICENSE/README/Formula header changes were attempted during the audit and reverted; tap is now its own future child item under EPIC-0015 Track A (open question on tap LICENSE format to be resolved in that child).
- **Fix XACA-0251-013** — `homebrew-tap/libexec/lib/aiteamforge-paths.sh` schema-version warning whitelist updated to accept v2; previously emitted `WARNING: schema_version=2 unsupported` on every `_aiteamforge_get_field` call after the audit's schema bump (log noise only; functionality unaffected). Tap commit `f625cb5`; submodule pointer advanced.

### Feat: XACA-0310 Phase 2.5 — BACKLOG CR filter dropdown (gated on crSupport.enabled)

- **XACA-0310-006** (`lcars-ui/js/lcars-filter-bar.js`): `createFilterBar()` accepts
  a new `crsProvider` callback option (synchronous; no server route required). When
  provided, wires a `<select id="cr-filter-select">` with `_syncCRStyle()`,
  `_populateCROptions()`, and `_wireCRDropdown()` following the release/epic pattern.
  Active CR states shown: `cr-drafted`, `cr-submitted`, `cr-approved`, `implementing`,
  `deployed-dev`. Sorted by crState priority then `createdAt` desc. State key
  `crFilter: 'all'` added to DEFAULT_STATE and `_loadState()` persistence. Public API
  gains `populateCROptions()` mirroring `populateReleaseOptions()`. `_syncAllUI()`
  now calls `_syncCRStyle()`.
- **XACA-0310-003** (`lcars-ui/index.html`): Added `cr-filter-dropdown` HTML mount
  point after `category-filter-dropdown`; hidden by default (`style="display:none"`).
- **XACA-0310-003** (`lcars-ui/js/lcars.js`): `initQueueFilterBar()` passes
  `crsProvider` and gates dropdown visibility on `boardData.teamConfig.crSupport.enabled`.
  Listens to `crsupport-changed` to show/hide and resets `crFilter` to `'all'` on
  disable. `itemMatchesFilter()` checks `backlogFilterState.crFilter` against
  `item.crAssignment.crId`; `'none'` matches items with no crAssignment. New stub
  `populateCRFilterOptions()` forwarded from `renderBoard()` so options refresh on
  every board reload.

### Chore: XACA-0310-004 — verify DOCS popup CR tab uses CR-record cr_doc_link

- Audited `lcars-ui/js/lcars.js` for per-item legacy `cr_doc_link` reads: none found.
- `checkPlanExists` trusts `data.crExists` from server; `serve_plan_exists` reads both `item.crAssignment.crId` (new) and `item.cr_id` (legacy compat) — no client fix needed.
- `switchDocTab` for `tabType === 'cr'` fetches `/api/kanban/<id>/cr-content`; `serve_cr_content` resolves via `crAssignment.crId → board.crs[].cr_doc_link`. Chain confirmed intact.
- `lcars-cr-tab.js` `cr_doc_link` reads operate on CR records from `board.crs[]`, not per-item fields — correct.

### Fix: XACA-0327-001 — _kb_cr_draft bridges into v2 .crs[] container

- `kb-cr draft <item> --type <type>` now produces a complete v2 record in one
  transaction: a `.crs[]` container record AND a `crAssignment` back-pointer
  on the backlog item. Previously wrote only legacy flat per-item fields
  (`cr_id`, `cr_type`, `cr_created_at`, `crState`), leaving CRs invisible
  to the LCARS UI and unadvanceable through the v2 lifecycle.
- Implementation calls `_kb_cr_container_create` followed by
  `_kb_cr_container_add_item` (DD1 from plan: bridge, don't refactor).
- Legacy flat fields are still written for backward compat — the LCARS UI
  reads `cr_id`/`cr_type` directly. Marked `# DEPRECATED` in source for
  follow-up cleanup once UI migration completes.

### Feat: XACA-0327-002 — kb-cr attach/detach CLI sugar

- New `kb-cr attach <item-id> --to <CR-ID>` — item-perspective alias for
  `kb-cr add-item`. Refuses (non-zero exit, clear stderr) if the item is
  already attached to a different CR. De-dupes against existing membership.
- New `kb-cr detach <item-id>` — resolves the item's `crAssignment.crId`
  automatically; no `--from` flag required (items can only be in one CR).
  Refuses (exit 1) if the item has no `crAssignment`.
- Both are thin wrappers over `_kb_cr_container_add_item` /
  `_kb_cr_container_remove_item` — all validation lives in those helpers
  (DD3 from plan).

### Feat: XACA-0327-003 — kb-cr dispatcher propagates item-id lifecycle verbs via crAssignment.crId

- Added `_kb_cr_dispatch_item_lifecycle` helper (DD2 from plan): when a lifecycle
  verb is called against an item-id that has a `crAssignment.crId` back-pointer,
  the dispatcher transparently routes to the container variant against that CR-ID,
  advancing all siblings atomically.
- Falls through to the v1 per-item helper for items without `crAssignment` (legacy
  single-item CRs unaffected), items not found on the board, and orphaned
  `crAssignment` pointers (no matching container — logs WARNING to stderr).
- Prints `kb-cr: routing to <CR-ID> — <gerund> N items in this CR.` to stderr
  before routing (Risk #3 mitigation from plan).
- Direct CR-ID calls (`kb-cr submit CR-…`) continue to route via the existing
  `CR-*) ...` arm without touching the dispatch helper.
- Verbs propagated: submit, approve, reject, hold, start-dev, start-test,
  deploy-dev, deploy-prod. `complete` is not propagated — no container variant
  exists yet; noted for future XACA item.

### Feat: XACA-0327-004 — kb-cr show <item> renders sibling list

- `kb-cr show <item-id>` for an item with `crAssignment` now appends a
  `SIBLINGS ON CR [<CR-ID>] (N items):` section listing all sibling items in
  the CR, with the current item marked `→`.
- Items without `crAssignment` render exactly as before (no behavior change).
- Orphaned `crAssignment.crId` (points to a missing `.crs[]` container)
  emits a non-fatal `║ WARNING:` line — useful diagnostic for stale records.

### Docs+Test: XACA-0327-005, -006 — kb-cr help, header docblock, regression suite

- `kb-cr.sh` header docblock rewritten with v2.0 unified-lifecycle section:
  dispatcher routing logic, `crAssignment` back-pointer schema, legacy
  flat-field backward-compat note, propagated-vs-non-propagated verb table.
- `_kb_cr_help` restructured: container-perspective verbs grouped, item-
  perspective lifecycle verbs annotated with "[propagates if crAssignment
  present]", `attach`/`detach` documented, `complete`/`emergency`/`backfill`
  flagged as v1-only, `show` documents sibling-list rendering.
- v1 helper audit (12 helpers): all retained as silent fallback per DD4.
  No runtime deprecation warnings (operators shouldn't see noise when
  boards have legacy single-item CRs).
- New `tests/test-kb-cr.sh` — 8 scenarios, 55 assertions (later expanded
  to 10/68 in -008). Covers: draft creates v2 record, attach + cross-CR
  refusal, detach round-trip, lifecycle propagation across siblings,
  legacy fallback, sibling rendering, direct CR-ID dispatch, orphaned-
  pointer warning + v1 fallback. Re-sources worktree's `scripts/kb-cr.sh`
  after `kanban-helpers.sh` (which hard-codes the main-repo path).

### Fix: XACA-0327-008 — kb-cr show renders attach-only items + zsh local-in-loop noise

- `_kb_cr_show` was silently early-returning when the legacy `cr_id` flat
  field was absent — items attached via the new `kb-cr attach` verb (modern
  `crAssignment`-only schema, no flat fields) produced ZERO output, making
  the SIBLINGS section -004 added unreachable. Fix reads `crAssignment.crId`
  before the early-return decision: both absent → stderr "no CR assignment"
  + exit 1; `cr_id` only → legacy block (unchanged); `crAssignment` only →
  minimum item view + siblings section; both → legacy block + siblings.
- Sibling-rendering loop declared `local sibling_title marker` inside the
  while body. zsh emits assignment values to stdout on subsequent
  iterations of a re-declared `local`, polluting rendered output. Fix:
  hoist `local` declarations above the loop.
- Test suite expanded 55 → 68 assertions (8 → 10 scenarios) covering both
  new edge cases.

### Refactor: XACA-0327 follow-ups — single-jq sibling rendering + pre-existing local-in-loop fix

- `_kb_cr_container_show` had the same `local item_title` re-declared
  inside the per-itemId rendering loop (pre-existing on develop, surfaced
  by tester subagent during PR #337 review as `[Test]` follow-up).
  Hoisted out of the loop; same fix as -008.
- Both `_kb_cr_container_show` and the new `_kb_cr_show` sibling section
  used to call `jq` once per sibling for title extraction (O(N) jq
  spawns; ~14 invocations on a release CR). Replaced with a single
  `_kb_jq_read` invocation that joins `itemIds → titles`, computes the
  per-row marker (`→` for self when applicable), and streams printf-
  ready rows. O(1) jq invocations regardless of sibling count.

### Feat: XACA-0325 — main-event-cr skill v4.2.0 (On-Demand Mode)

### Fix: serve_cr_content — look up CR record by legacy cr_id when crAssignment absent

- Half-migrated boards may have a CR record in `crs[]` while the linked
  backlog item still carries only the legacy top-level `cr_id`. The CR-record
  lookup was gated on `crAssignment.crId`, so legacy-only items resolved
  `confluenceUrl` to `''` and the CR tab on the item DOCS modal failed with
  "Error loading CR document / CR document not found".
- Lookup key is now `(crAssignment.crId OR legacy cr_id)`, so the server
  finds the CR record (and its `cr_doc_link`) regardless of which schema
  shape the item is in.
- Backfilled `change-requests/CR-IOS-20260505-0632_*.md` from the CR record
  metadata so the iOS team's two existing CRs both have local source-of-
  truth files.

### Test: XACA-0172-016 — unit tests for secrets export/import flow (resolves PR #333 [Review])

- **`lcars-ui/tests/test_secrets_export_lib.py`** (13 tests) — covers `pyzipper_available`,
  `validate_secrets_manifest` (8 schema cases: valid, missing kind/version/sources/targetRoot,
  wrong kind, invalid source entry, non-JSON), `discover_secrets_sources`
  (manifest resolution, auto-detect, empty), and manifest constants.
- **`lcars-ui/tests/test_secrets_workers.py`** (9 tests) — covers `generate_secrets_export`
  (skipped/no-sources, happy path with zip content + manifest validation, wrong-password
  unreadability), `apply_secrets_import` (wrong-password exact error string, corrupt zip,
  no-clobber atomicity, path-traversal absolute, path-traversal relative `../` escape).
- Retry-budget exhaustion (test 21) skipped — counter logic lives in the HTTP preflight
  handler and requires a running server; documented for follow-up integration test.
- All 22 tests pass via `python3 -m unittest discover -s lcars-ui/tests -p 'test_secrets_*.py'`.

### Fix: XACA-0172 — path-traversal containment + filename sanitization (PR #333 review)

- **Path traversal containment in `apply_secrets_import`** — arc-name entries from
  `zf.namelist()` were used directly in path joins. A crafted zip with absolute
  paths or `../`-prefixed entries could write outside `project_root`. Server
  binds to all interfaces and is reachable from tailnet peers — real attack
  vector. Fix mirrors the existing pattern at the CR doc handler: reject
  absolute arc paths, `resolve()` candidate, `relative_to()` containment check
  before any file operation.
- **`Content-Disposition` filename sanitization** — `filename="../../foo"`
  joined with `job_dir` could write the staged upload outside the staging dir.
  Now uses `Path(raw_name).name` to strip directory components; falls back to
  `secrets.zip` if sanitization yields empty.
- **Misleading preflight warning text** — UI claimed "Existing files will be
  overwritten" but backend hard-fails on collision. Corrected to reflect the
  no-clobber atomic policy.

### Fix: XACA-0172-013 — corrupt-zip handler catches pyzipper.zipfile.BadZipFile

- `pyzipper.zipfile.BadZipFile` is not a subclass of stdlib `zipfile.BadZipFile`.
- Both `apply_secrets_import` and the preflight handler now check `isinstance` against
  the tuple `(zipfile.BadZipFile, pyzipper.zipfile.BadZipFile)` so corrupt-zip uploads
  produce the documented HTTP 400 error instead of a connection reset.

### Feat: XACA-0172-006 — error handling + edge case hardening (secrets flow)

- **Missing handler methods added** — `handle_create_secrets_export`, `serve_secrets_export_status`,
  `serve_secrets_export_download` were called in the router but never defined; all three implemented.
- **Empty secrets dir** — `generate_secrets_export()` returns `status="skipped"` cleanly; UI
  surfaces info message without error icon. Verified OK.
- **Wrong-password retry budget** — preflight handler tracks `wrongPasswordAttempts` per job; after
  5 failures staged zip is deleted and user must re-upload. `attemptsRemaining` returned in error
  response; UI shows count and auto-resets to file picker on budget exhaustion.
- **Staged zip retained on wrong-password** — preflight retains staged zip on each wrong-password
  attempt so re-upload is not needed until budget is exhausted.
- **Corrupt zip clean error** — both preflight handler and worker now surface exact string
  `"Invalid or corrupt secrets zip — please re-export and try again."`. Corrupt zip is
  non-retryable; staged file removed on detection.
- **Permission errors wrapped** — `mkdir` and `shutil.move` in atomic extraction now catch
  `PermissionError` and re-raise with actionable message including the failing path.
- **Base-team mismatch visible in preflight** — preflight handler checks `manifest.team` vs
  `job['targetTeam']` and includes a `warning` key in the HTTP response. UI renders a highlighted
  `preflight-row-warning` row. Worker already sets `job['message']`. Warn-only, does not block.
- **TTL prune** — `_prune_old_secrets_jobs()` prunes both secrets job dicts entries older than
  1 hour with terminal status. Called from `handle_create_secrets_export`.
- **Password audit** — confirmed zero occurrences of password values in any log, job dict key, or
  status response across `server.py` and `lcars.js`.
- **Threat model docstring** — added to `secrets_export_lib.py` covering channel separation, AES-256
  content encryption, metadata visibility, password handling rules, and retry budget.
- **Zip metadata leak comment** — added near `pyzipper.AESZipFile` call in `generate_secrets_export`.

### Feat: XACA-0172-005 — frontend Import UI for encrypted secrets zip

- SECRETS IMPORT (ENCRYPTED ZIP) subsection added inside the Import section of `lcars-ui/index.html`.
- Separate file picker (`secretsImport-file-input`) hits `/api/import/secrets/upload` with multipart `file` + `team` fields.
- Password panel shown after upload; wrong-password error (HTTP 400 / exact string match) shown inline with input cleared for immediate retry — no re-upload required.
- Password kept in DOM input through preflight verify so apply can reuse it; zeroed from input immediately after the apply POST resolves.
- Preflight panel renders target team, source host, file count, target root, and per-source paths + file counts from manifest.
- Progress bar polling via `/api/import/secrets/status/<jobId>` at 1500ms intervals; completed shows "Extracted N files to <targetRoot>" message; failed drops back to password panel if wrong-password detected at extraction time.
- Cancel resets all panels and re-enables file picker without re-upload.
- Navigation away mid-import: polling interval is tracked in `secretsImportPollingInterval`; `cancelSecretsImport()` clears it. No auto-cancel on page leave — extraction continues server-side.

### Feat: XACA-0172-004 — frontend Export UI for secrets zip

- SECRETS EXPORT (OPTIONAL) subsection added to `lcars-ui/index.html` Export/Import section.
- Opt-in checkbox (`secrets-export-toggle`) defaults to unchecked; reveals password panel on check.
- Password + confirm fields with strength hint; GENERATE button disabled until fields match and non-empty.
- Progress bar (reuses `progress-bar-container`/`progress-bar`/`progress-percent`/`progress-message` classes) hidden until job starts.
- DOWNLOAD SECRETS button hidden until `status=completed`; re-downloadable until navigation.
- New JS functions in `lcars-ui/js/lcars.js`: `toggleSecretsExportPanel`, `validateSecretsPasswords`, `startSecretsExport`, `pollSecretsExportStatus`, `stopSecretsExportPolling`, `updateSecretsExportProgress`, `downloadSecretsExport`, `resetSecretsExportUI`.
- Password cleared from DOM and local variable immediately after POST resolves (success or fail); never logged.
- `status=skipped` surfaces clean info message ("No secrets directory found…"), not an error.
- `pairedExportId` automatically wired to `currentExportJobId` when a main export has completed.

### Feat: XACA-0172-003 — backend secrets import (password-verified extraction)

- `SECRETS_IMPORT_JOBS` dict in `lcars-ui/server.py` for job tracking (mirrors `IMPORT_JOBS` shape).
- `SECRETS_IMPORT_STAGING_DIR = Path("/tmp/lcars-secrets-imports")` staging constant.
- `apply_secrets_import(job_id, password)` worker:
  - Verifies AES-256 password via pyzipper; bad password yields retryable `status='awaiting-password'`.
  - Validates manifest `kind` and `version` against `SECRETS_EXPORT_MANIFEST_KIND`/`_VERSION`.
  - Team mismatch is warn-only (cross-team transfer allowed); hard-fails on bad manifest schema.
  - No-clobber: any existing target file hard-fails with atomic guarantee (zero files extracted).
  - Atomic extraction via temp staging dir; on any failure temp dir is blown away, targets untouched.
  - Creates target dirs as needed (`mkdir -p` semantics).
  - On success: `status='completed'`, staged zip deleted.
  - Password held in thread-local scope only; never stored or logged.
- Routes:
  - `POST /api/import/secrets/upload` — `handle_secrets_import_upload()`: multipart, `file` + optional `team` fields.
  - `POST /api/import/secrets/preflight/<job_id>` — `handle_secrets_import_preflight()`: verify password, return manifest without extracting.
  - `POST /api/import/secrets/apply/<job_id>` — `handle_secrets_import_apply()`: spawn worker thread.
  - `GET /api/import/secrets/status/<job_id>` — `serve_secrets_import_status()`: poll job state; `stagedPath` stripped from response.

### Feat: XACA-0172-001 — secrets source mapping + pyzipper dep

- Add `lcars-ui/requirements.txt` with `pyzipper>=0.3.6` for AES-256 zip support.
- Add `lcars-ui/secrets_export_lib.py`: contract layer for subitems 002/003.
  - `discover_secrets_sources(team_id)` — manifest-override or auto-detect `<project_root>/secrets/`.
  - `validate_secrets_manifest(path)` — schema validation for `kanban/<team>/secrets-manifest.json`.
  - `pyzipper_available()` — graceful dep probe for callers.
  - `SECRETS_EXPORT_MANIFEST_KIND` / `SECRETS_EXPORT_MANIFEST_VERSION` constants.

### Feat: CR docs — local `*.md` is the source of truth, Confluence is secondary

- New convention: every CR has a local markdown file at
  `<team-kanban-dir>/change-requests/<CR-ID>_<slug>.md`. The LCARS CR-doc
  modal renders this file as the primary body; the Confluence page is
  generated FROM the local md, so the local file is the editable source.
- New template at `homebrew-tap/share/templates/kanban/cr-doc-template.md`
  (mirrored to `templates/kanban/`) with placeholder fields for ID, type,
  state, title, summary, deploy window, items, and Confluence URL.
- `kb-cr create` (both `scripts/kb-cr.sh` and the homebrew-tap mirror) now
  calls a new `_kb_cr_create_doc_file` helper that writes the populated
  template to `change-requests/<CR-ID>_<slug>.md`. Non-fatal if the
  template is missing or the file already exists.
- `lcars-ui/server.py` `serve_cr_content` now globs
  `change-requests/<CR-ID>*.md` (resolved via the item's
  `crAssignment.crId` back-pointer) and returns
  `{ content, filename, confluenceUrl }`. Falls back to the legacy
  external-URL path when no local file exists.
- `lcars-cr-tab.js` `_showCRDocModal` always fetches the markdown content
  and renders it as the modal body; the metadata block at the top still
  shows the Confluence launch button when one is set. Modal width
  matched to the item plan-doc modal (`max-width: 1200px`,
  `min-width: 500px`, `width: 90%`) so long markdown bodies have room.
- Backfilled `CR-IOS-20260505-0618` from its existing CR-record metadata
  so the iOS team's only CR has its source-of-truth md file in place.

### Fix: XACA-0309 PR #332 review feedback — 8 subitems addressed (012-019)

- **XACA-0309-012** (`scripts/kb-cr.sh`) — `_kb_cr_container_emergency_deploy`: moved `_kb_cr_board_preamble` + disabled gate above `--justification` validation so disabled-board callers receive the standard "CR support disabled" exit-0 message instead of a validation error exit-1.
- **XACA-0309-013** (`scripts/kb-cr.sh`) — Added `_kb_cr_container_start_dev` and `_kb_cr_container_start_test` v2 container lifecycle helpers. `start-dev` (CR-ID): cr-approved → implementing, writes `timestamps.cr_started_dev_at`. `start-test` (CR-ID): implementing → state unchanged, writes `timestamps.cr_started_test_at` (no ready-for-test state in schema). Updated dispatcher to route CR-ID args to the new container functions. Added 5 new bats tests in cat5.
- **XACA-0309-014** (`tests/cr-lifecycle/cat1-disabled-parity.bats`) — Added 30 new @test cases covering all 12 v2 container commands (create, add-item, remove-item, list, transition, submit, approve, reject, hold, deploy-dev, deploy-prod, emergency-deploy, show, start-dev, start-test) under crSupport disabled (absent and explicit false). Each case: exit 0, output contains "disabled", board SHA byte-identical.
- **XACA-0309-015** (`scripts/kb-cr.sh`) — Updated LOAD-BEARING INVARIANT header comment: replaced "No reads" claim with accurate description — disabled teams perform a single read (the gate check) but no writes.
- **XACA-0309-016** (`scripts/migrate-cr-schema.py`) — No-op detection now runs BEFORE writing the backup. If crs[] and nextCrSeq already exist and no items have deprecated cr_* fields, prints "No CR data to migrate. Skipping backup." and exits 0 without creating a backup file.
- **XACA-0309-017** (`scripts/kb-cr.sh`) — `_kb_cr_container_show`: replaced silent `return 0` on disabled board with `_kb_cr_disabled_exit "$_cr_team"` so the container show command emits the standard disabled message. Per-item `_kb_cr_show` path unchanged.
- **XACA-0309-018** (`scripts/kb-cr.sh`) — `_kb_cr_container_show`: replaced per-item loop calling `_kb_jq_read` once per item ID with a single batched jq query that builds a `{id: title}` map for all itemIds. Reduces complexity from O(itemIds×backlog_size) to O(backlog_size).
- **XACA-0309-019** (`scripts/kb-cr.sh`) — Added code comment in `_kb_cr_container_add_item` explaining that `crTitle` is a snapshot at assign-time and does not propagate title updates. No code change.
- **Total bats tests**: 107 (cat1: 54, cat2: 6, cat3: 3, cat4: 11, cat5: 33). All PASS.

### Test: XACA-0309-007 — bats coverage, schema validator, idempotency + flag-off verification

- **`tests/cr-lifecycle/cat5-container-commands.bats`** — New. 28 tests covering the v2.0 container command surface: create (valid/invalid type), add-item (conflict guard), remove-item, show (found/not-found), list (unfiltered + --state filter), transition (valid + invalid state), submit, approve, reject (pushback count), hold, deploy-dev, deploy-prod, emergency-deploy (--justification required guard), state predecessor validation (approve from cr-drafted, reject from cr-drafted, deploy-dev from cr-drafted, double-submit guard), and multi-item CR (assign two items, idempotent add, full lifecycle roundtrip).
- **`tests/cr-lifecycle/cat2-migration.bats`** — Rewrote to match actual script interface (positional arg, no --board flag, no --dry-run, no pre-existing backup requirement). 6 tests: missing file exits 2, malformed JSON exits 3, no-op board exits 0, per-item cr_* fields lifted to crs[], crs[]+nextCrSeq added on first run, idempotent re-run keeps crs[] count stable.
- **`tests/cr-lifecycle/cat4-schema-validity.bats`** — Fixed 3 tests that incorrectly counted total dict keys (including `_deprecated` and `_description` meta-keys) as field counts. Updated to exclude meta-keys (keys starting with `_`) from crFields and crTimestamps counts and key assertions.
- **`tests/cr-lifecycle/helpers.bash`** — Fixed CR_SCHEMA_FILE and MIGRATE_SCRIPT paths: CR_SCHEMA_FILE now resolves via `git rev-parse --git-common-dir` to the main repo's homebrew-tap (worktree submodule is un-initialised); MIGRATE_SCRIPT now points to `scripts/migrate-cr-schema.py` in the worktree.
- **`tests/cr-lifecycle/run-all.sh`** — Updated to include cat5; fixed SCHEMA_FILE and MIGRATE_SCRIPT path resolution using git-common-dir.
- **`scripts/cr-schema-validator.py`** — New. Validates migrated boards: (1) crs[] and nextCrSeq present, (2) every CR has required fields and valid crState, (3) every crAssignment.crId references a known CR, (4) every CR.itemIds[] references known items, (5) no item has both crAssignment and deprecated cr_* fields, (6) nextCrSeq > max CR sequence. Validated all 5 migrated boards: PASS.
- **Schema validator results**: iOS PASS, Android PASS, Firebase PASS, MainEvent/command PASS, Academy PASS.
- **Idempotency**: all 5 boards exit 0 on re-run, crs[]/item counts unchanged; SHA drift is one trailing-newline cosmetic difference from json.dumps normalization — no data changes.
- **Flag-off no-op**: all 13 container subcommands (create, add-item, remove-item, list, transition, show, submit, approve, reject, hold, deploy-dev, deploy-prod, emergency-deploy) exit 0 with no board writes when crSupport is disabled (explicit false) or absent. Note: `show` exits 0 silently (no "disabled" message) — consistent with its dispatch path.
- **Total bats tests**: 72 (cat1: 24, cat2: 6, cat3: 3, cat4: 11, cat5: 28). All PASS.

### Chore: XACA-0309-006 — sync homebrew-tap submodule: kb-cr namespace + migration script in installer

- **`homebrew-tap/share/scripts/kb-cr.sh`** — Updated to full lifecycle version (subitems 003+004): 1854 lines covering create/add-item/remove-item/show/list/transition + submit/approve/reject/hold/deploy-dev/deploy-prod/emergency-deploy subcommands.
- **`homebrew-tap/share/scripts/migrate-cr-schema.py`** — New file (460 lines). One-shot migration tool that upgrades kanban board JSON from pre-v2.0.0 `cr_*` fields to the `crs[]` container schema. Operators run manually after upgrading if they have existing CR data.
- **`homebrew-tap/libexec/installers/install-kanban.sh`** — Added `migrate-cr-schema.py` install step in `install_lcars_profile_script()`, deploying it to `${AITEAMFORGE_DIR}/scripts/migrate-cr-schema.py` alongside `kb-cr.sh`. Uses same guard pattern (non-fatal warning if file missing).
- **`homebrew-tap/Formula/aiteamforge.rb`** — Added three test assertions: `share/scripts/kb-cr.sh`, `share/scripts/migrate-cr-schema.py`, and `share/templates/kanban/cr-schema.json` must be present in the installed tap payload.
- **`kanban-helpers.template.sh`** — No change required; sourcing block (line 9713) was already in place from a prior subitem, referencing `${AITEAMFORGE_DIR}/scripts/kb-cr.sh`. PATH export ensures `migrate-cr-schema.py` is directly callable post-install.
- Submodule pointer bumped: `987bb4a` → `b020797` on homebrew-tap `main` branch.

### Refactor: XACA-0309-005 — Apply CR-as-Container migration to mobile boards (iOS/Android/Firebase/MainEvent/Academy)

- **iOS** (`ios-board.json`) — Migrated 1 item (XIOS-0618) with existing `cr_id=CR-IOS-20260505-0618` into a v2.0 CR container record. `nextCrSeq` advanced to 619. `crSupport.enabled=true`.
- **Android** (`android-board.json`) — No pre-existing cr_* data. Schema initialized (`crs[]`, `nextCrSeq=1`). `crSupport.enabled=true`.
- **Firebase** (`firebase-board.json`) — No pre-existing cr_* data. Schema initialized. `crSupport.enabled=true`.
- **MainEvent** (`command-board.json`) — No pre-existing cr_* data. Schema initialized. `crSupport.enabled=true`.
- **Academy** (`academy-board.json`) — No pre-existing cr_* data. Schema initialized. `crSupport.enabled=true`. Dogfooding target for XACA-0309.
- All five boards passed idempotency check (second run: exit 0, crs[] count unchanged).
- Schema validator: not present in repo (no blocker — script has built-in round-trip JSON validation).
- iOS/Android/Firebase/MainEvent board changes are in those teams' own repos (not tracked here). Only Academy board change tracked by this commit.

### Feat: XACA-0309-004 — kb-cr lifecycle helpers: submit/approve/reject/hold/deploy-dev/deploy-prod/emergency-deploy

- **`scripts/kb-cr.sh`** — Added seven container lifecycle subcommands for the v2.0 CR-as-Container schema. Each command combines a state transition with writing the corresponding `crs[].timestamps.<key>` field atomically (jq → .tmp → mv).
- **`_kb_cr_lifecycle_advance <board> <cr_idx> <cr_id> <new_state> <ts_key> [ts_value]`** — New internal core helper. Writes `crState`, `timestamps.<ts_key>`, `updatedAt`, and board `lastUpdated` in a single `_kb_jq_update` call. All seven lifecycle subcommands delegate to this helper.
- **`_kb_cr_container_get_state <board> <cr_idx>`** — New internal helper. Reads current `crState` from a container record.
- **`kb-cr submit <CR-ID>`** — Predecessors: `cr-drafted`, `cr-held`, `cr-rejected`. Writes `timestamps.cr_submitted_at`. Refuses with non-zero exit if already submitted or in a post-submission state.
- **`kb-cr approve <CR-ID> [--approver <login>] [--approver-name "<name>"]`** — Predecessor: `cr-submitted`. Writes `timestamps.cr_approved_at`; updates `approver.{login,name}` when flags provided (preserves existing values if flags omitted).
- **`kb-cr reject <CR-ID> [--reason "<text>"]`** — Predecessors: `cr-submitted`, `cr-held`. Writes `timestamps.cr_rejected_at`; increments `pushback_count`; appends reason to `pushback_notes` (newline-separated cumulative log).
- **`kb-cr hold <CR-ID> [--reason "<text>"]`** — Predecessors: `cr-submitted`, `cr-approved`. Writes `timestamps.cr_held_at`; increments `pushback_count` and appends reason to `pushback_notes` when reason provided.
- **`kb-cr deploy-dev <CR-ID>`** — Predecessors: `cr-approved`, `implementing`. Writes `timestamps.cr_deployed_dev_at`.
- **`kb-cr deploy-prod <CR-ID>`** — Predecessor: `deployed-dev` (preferred); also accepts `cr-approved`, `implementing` with a WARNING logged to stderr about skipping the dev deployment stage. Writes `timestamps.cr_deployed_prod_at`.
- **`kb-cr emergency-deploy <CR-ID> --justification "<text>"`** — Break-glass path. `--justification` is REQUIRED (mandatory audit trail; refuses with non-zero exit without it). No predecessor state check (allowed from any state). Writes `timestamps.cr_emergency_deployed_at` + `emergency_justification` on the container record.
- **Dispatcher routing:** `submit`, `approve`, `reject`, `hold`, `deploy-dev`, `deploy-prod` now detect the first argument's prefix — `CR-*` routes to the new container path; any other prefix falls through to the existing v1 per-item functions. `emergency-deploy` is a new case entry (distinct from the v1 `emergency` subcommand).
- **crSupport gate:** all seven commands call `_kb_cr_board_preamble`; when `crSupport.enabled=false` they exit 0 with the standard disabled message and perform no side effects.
- **No deprecated field writes:** timestamps are written exclusively to `crs[].timestamps.<key>` — never to the deprecated per-item `cr_*_at` fields verified by smoke tests.

### Feat: XACA-0309-003 — kb-cr namespace: container commands (create/add-item/remove-item/show/list/transition)

- **`scripts/kb-cr.sh`** — Added six CR container subcommands implementing the v2.0 CR-as-Container schema on top of the existing per-item lifecycle commands.
- **`kb-cr create <title> [--type major|emergency|fyi] [--platform ...] [--summary ...]`** — Creates a new CR container record in `crs[]`. Auto-assigns ID from `nextCrSeq` (`CR-<TEAM>-<YYYYMMDD>-<seq>`), initializes `crState=cr-drafted`, increments counter.
- **`kb-cr add-item <CR-ID> <item-id>`** — Appends item to CR's `itemIds[]` (de-duped); writes `crAssignment{crId, crTitle, assignedAt}` back-pointer on the item. Refuses with non-zero exit if item already has a `crAssignment` to a different CR.
- **`kb-cr remove-item <CR-ID> <item-id>`** — Removes item from `itemIds[]`; deletes `crAssignment` from the item.
- **`kb-cr show <CR-ID>`** — Formatted box display: id, title, type, state, platform, deploy window, doc link, approver, pushback count, summary, emergency justification, items list (with titles), all timestamps.
- **`kb-cr list [--state <state>] [--platform <name>]`** — Tabular listing of all CRs on the board with optional state/platform filters.
- **`kb-cr transition <CR-ID> <new-state>`** — Validates new state against the schema's `crStates` list; updates `crState` + `updatedAt`. Does NOT write `cr_*_at` timestamp fields (reserved for subitem 004 lifecycle helpers).
- **`_kb_cr_show_dispatch`** — Routes `kb-cr show` by ID prefix: `CR-*` prefix → container show; any other prefix → existing per-item show. Preserves backward compatibility.
- **Gating:** All six commands call `_kb_cr_board_preamble` which checks `teamConfig.crSupport.enabled`. When `false`, prints the standard disabled message and exits 0 with no side effects — no board reads beyond the flag check, no writes.
- **Internal helpers added:** `_kb_cr_board_preamble` (board-only context, no item resolution), `_kb_cr_ensure_container_support` (idempotent `crs[]`/`nextCrSeq` init), `_kb_cr_generate_id`, `_kb_cr_increment_seq`, `_kb_cr_find_container`.

### Refactor: XACA-0309-002 — Idempotent CR schema migration script (backup-or-refuse)

- **`scripts/migrate-cr-schema.py`** — new Python 3 migration script (stdlib only, no third-party deps).
- Transforms team board JSON files from the per-item `cr_*` field pattern (schema v1) to the v2.0 CR-as-Container pattern (top-level `crs[]` + `crAssignment` back-pointers on items).
- **Backup-or-refuse safety:** writes `<board>.backup.<timestamp>` before any mutation; aborts with exit code 1 if the backup write fails (disk full, permission denied, etc.) — original board is never touched.
- **Atomic write:** stages output in memory → writes `<board>.tmp` → `os.replace()` to final path. Half-written boards impossible on mid-flight kill.
- **Idempotency:** items already carrying `crAssignment` and no deprecated `cr_*` fields are skipped. Existing `crs[]` records block duplicates by `cr_id`. Safe to re-run on already-migrated boards.
- **Multi-item CR merge:** items sharing the same `cr_id` produce ONE CR container record with all their IDs in `itemIds[]`.
- **Timestamp promotion:** all per-item `cr_*_at` fields move to the CR record's `timestamps{}` object. Approver fields `cr_approved_by`/`cr_approver_name` promote to `approver.{login,name}`.
- **nextCrSeq update:** set to `max(existing CR sequence numbers) + 1` after migration.
- **Edge cases:** empty/non-string `cr_id` → warning + skip (no abort); board with no `cr_*` data → initializes `crs: []` / `nextCrSeq: 1`, exits cleanly.
- **Exit codes:** 0 success (including no-op), 1 backup/write failure, 2 file not found/unreadable, 3 invalid JSON input, 4 migration produced invalid JSON (rollback attempted).
- Self-tested with synthetic fixtures covering: multi-item CR merge, single-item CR, emergency CR, no-cr-data board, second-pass idempotency, empty `cr_id`, non-string `cr_id`, file-not-found, invalid JSON.

### Refactor: XACA-0309-001 — CR-as-Container schema (cr-schema.json v2.0)

- **`homebrew-tap/share/templates/kanban/cr-schema.json`** bumped to schema_version 2.0.0
- Added `crContainer` section: schema for the new top-level `crs[]` collection records, mirroring `epics[]`/`releases[]`. Fields: `id`, `title`, `type`, `crState`, `deploy_window_planned`, `cr_doc_link`, `approver` (object with `login`/`name`), `itemIds[]`, `pushback_count`, `pushback_notes`, `summary`, `platform`, `emergency_justification`, `createdAt`, `updatedAt`, `timestamps`.
- Added `crAssignment` section: back-pointer object placed on kanban items, mirroring `releaseAssignment`. Fields: `crId`, `crTitle` (snapshot), `assignedAt`.
- Added `boardFields` section: documents `crs[]` (default `[]`) and `nextCrSeq` (default `1`) that `migrate-cr-schema.py` will write to board JSON when migrating.
- Deprecated all per-item `crFields` entries (`cr_id`, `cr_type`, `cr_approved_by`, `cr_approver_name`, `cr_pushback_count`, `cr_pushback_notes`, `cr_summary`, `cr_doc_link`, `deploy_window_planned`, `platform`, `emergency_justification`) via `"deprecated": true` markers and `_deprecated` section note. Fields retained for migration compatibility — removal after subitem 002 runs.
- Updated `crTimestamps` entries with `"stored_on": "crs[] container record"` annotation to clarify they no longer live on individual items post-migration.
- Updated `_meta.consumers` to include `crContainer`/`crAssignment` references.

### Fix: lcars-cr-tab — read new `crs[]` schema; CR-only DOCS modal; copyable CR IDs

- `_getCRItems()` now reads `boardData.crs[]` (current schema) and normalizes
  each CR record into the view shape the rest of the file expects. The legacy
  filter on `backlog[].cr_id` returned zero CRs after the schema migration
  moved CR records out of items into a top-level array with `crAssignment`
  back-pointers — the CHANGE REQ tab showed empty for every team.
- Platform filter is case-insensitive — board records carry lowercase platform
  values (`ios`), the dropdown sent PascalCase (`iOS`); strict `!==` hid every
  CR. Dropdown values normalized to canonical lowercase
  (`ios|android|firebase|crossplatform`) to match `kb-cr create --platform`.
- TYPE filter renamed `NORMAL` → `MAJOR` to match `kb-cr` canonical types
  (`standard|major|emergency|fyi`); badge class follows (amber, between
  STANDARD's blue and EMERGENCY's crimson).
- DOCS button on the CR list now opens a CR-only modal (`_showCRDocModal`)
  with metadata block (type, state, platform, deploy window, approver,
  pushbacks, linked item, summary) and a launch button when `cr_doc_link`
  is an http(s) URL. No longer hijacks the item plan-doc modal with a
  pre-selected CR tab.
- CR ID column in the list is tappable — delegates to the global
  `copyToClipboard()` so the upper-right `Copied: <id>` toast matches the
  one shown when item IDs are copied. Local green-flash on the cell layers
  on top of the toast for direct feedback at the click site.
- `lcars.js` `switchDocTab` handles the new `{isExternal:true, url}` response
  from `cr-content` so the item DOCS modal's CR tab renders a launch button
  instead of `renderMarkdown(undefined)`.
- `server.py`:
  - `serve_plan_exists` and `serve_cr_exists` check `item.crAssignment.crId`
    (new schema) plus legacy `cr_id` for back-compat — this is what makes the
    CR tab appear on the item DOCS button.
  - `serve_cr_content` resolves `cr_doc_link` from the CR record in `crs[]`
    via the back-pointer and returns `{url, isExternal:true}` for http(s)
    URLs (typical for Confluence-hosted CRs).

### Refactor: XACA-0311 — Soft-gate display reuses `_kb_display_item_box`

- `_kb_blocked_soft_gate` no longer renders a bespoke 53-char ASCII box with
  truncated title/blocker list and abbreviated subitems. It now prints a short
  ⚠ warning banner + blocker list, then delegates to `_kb_display_item_box`
  with title `KANBAN ITEM DETAILS (BLOCKED)` — the same renderer used for
  non-blocked items, so operators see description, tags, priority, due date,
  and full subitems exactly as they normally would.
- Helper signature: 4th argument is now the full `item_json` (was `title`).
- Helper sets caller-scope `_kb_blocked_already_displayed=1` (via dynamic
  scoping); `kb-run` / `kb-work` skip their own `_kb_display_item_box` call to
  avoid duplicate rendering.
- Removed redundant downstream "fallback re-check" loops in `kb-run` and
  `kb-work` (~30 lines × 2): the soft-gate's internal re-check already covers
  rc=0 callers, and when soft-gate doesn't run `blocked_by_ids` is empty so
  the fallback was a no-op.
- Net: ~120 lines removed; single source of truth for item display.

### Fix: XACA-0311 — Review feedback: suppress empty heading, /dev/tty read, orphan-blocked note

- `_kb_blocked_soft_gate`: suppress "Blocked by:" heading when `blockedBy` is
  empty (orphan blocked-status items now show a "manually flagged" note instead)
  (XACA-0311-007)
- `_kb_blocked_soft_gate`: change `read -r answer` to `read -r answer < /dev/tty`
  for stdin discipline parity with existing interactive reads in the file
  (XACA-0311-008)
- `_kb_blocked_soft_gate`: document orphan blocked-status design decision inline —
  empty `blockedBy` means manual flag; re-check loop iterates nothing → rc=0 →
  proceeds after user confirms Y (XACA-0311-009)

### Fix: XACA-0311 — Restore hard-exit for non-TTY blocked items (PR #331 regression)

- `_kb_blocked_soft_gate` non-TTY branch now prints the hard-error box and
  returns 2, which callers map to `return 1` (loud failure with output)
- Fixes regression where `kb-run <BLOCKED_ID> </dev/null` returned rc=0 silently:
  non-TTY was returning 1, but callers mapped rc=1 → `return 0` (graceful path),
  conflating "non-TTY" with "user said N"
- Updated rc contract comment at helper and both call sites to reflect that rc=1
  is user-said-N only; rc=2 covers both non-TTY and still-blocked-after-confirm

### Feat: XACA-0311 — Soft-gate blocked items in kb-run/kb-work

- Add `_kb_blocked_soft_gate` helper: shows a warning box with item details,
  blocker IDs, and subitems when an item is blocked
- Prompt `Continue anyway? [y/N]` (default N) on block detection in interactive TTYs
- On Y: re-queries board state; if blockers still incomplete, prints the existing
  hard-error box and exits non-zero — unchanged behaviour from before
- On N or empty: graceful exit (exit 0, no error, no work started)
- Non-interactive (no TTY, e.g. CI): preserves existing hard-exit path unchanged
- Both `kb-run` and `kb-work` wired identically — no asymmetry

### Fix: XACA-0292 follow-ups — splash hang, CR list scope, sidebar split-row

Defensive + polish fixes layered on top of the XACA-0292 merge:

- **Splash stranding fix (P055):** `loadModeSections()` now applies a rename map
  (`queue` → `backlog`) and validates each saved section against `SECTIONS`,
  rewriting localStorage when stale. `switchSection()` falls back to
  `pickDefaultSectionForMode(activeMode)` when given an unknown section instead
  of silently returning. Prior behavior left existing users stranded on the
  startup splash because `switchSection('queue')` exited early at
  `SECTIONS.indexOf === -1` with no UI feedback.
- **CHANGE REQ list always-empty fix:** `boardData` was declared with `let` at
  top-level — which does not attach to `window`. `lcars-cr-tab.js` runs in an
  IIFE and reads `window.boardData`, so the CR list always rendered "No change
  requests for this team." regardless of CR count. Switched the declaration to
  `var` so the global is exposed.
- **Sidebar/tabbar split-row:** BACKLOG + CHANGE REQ now share a
  `.sidebar-split-row` (matching WORKFLOW + DETAILS); CHG REQ is on the left,
  BACKLOG on the right. When CR support is off, CHANGE REQ's `display:none`
  drops out and BACKLOG's `flex:1` fills the row. Tabbar mirrors the order.
- **Disable-with-CRs warning:** `saveTeamConfigCRSupport()` now counts items
  with non-empty `cr_id` when the user toggles CR support OFF; if any exist, a
  `confirm()` warns the count and notes that data is preserved. Cancel reverts
  the checkbox and aborts the POST.

### Feat: XACA-0292 — LCARS CAB Workflow UI Layer (EPIC-0017 Phase 2)

Delivers the full LCARS UI surface for the Change Advisory Board (CAB) workflow
(EPIC-0017). All CHANGE REQ UI is feature-flagged behind
`teamConfig.crSupport.enabled`; existing boards see zero behavior change until
they opt in via SETTINGS → TEAM CONFIG.

- **XACA-0292-001 — BACKLOG rename:** Renamed all "queue" identifiers to "backlog"
  across `lcars-ui/index.html`, `lcars-ui/js/lcars.js`, and `lcars-ui/css/lcars.css`
  (~480 hits). localStorage key `'lcars-queue-filter'` preserved for backward
  compatibility.

- **XACA-0292-002 — SETTINGS → TEAM CONFIG checkbox:** New `GET /api/team-config`
  and `POST /api/team-config` endpoints. Checkbox in SETTINGS section toggles
  `teamConfig.crSupport.enabled` with atomic file-lock write; dispatches
  `crsupport-changed` DOM CustomEvent so downstream handlers react without a
  page reload.

- **XACA-0292-003 — `GET /api/kanban/<id>/cr-content` endpoint:** Mirrors
  `plan-content` / `retro-content`. Resolves `cr_doc_link` against the team
  kanban directory, returns `{ content, itemId, filename }`. 404 when item,
  field, or file is absent. Not gated on `crSupport.enabled`.

- **XACA-0292-004 — CR tab in item DOCS popup:**
  `showPlanDocModal(itemId, retroExists, crExists)` gains a third parameter
  (defaults `false` via `!!crExists` normalization — all existing 2-arg callers
  unaffected). CR tab renders when both `crSupport.enabled` and `item.cr_id`
  are set. New `GET /api/kanban/<id>/cr-exists` endpoint. Orange active/hover
  colors distinguish CR tab from PLAN and RETRO tabs.

- **XACA-0292-005 — Reusable filter-bar component:** New
  `lcars-ui/js/lcars-filter-bar.js` exporting `createFilterBar(options)`.
  BACKLOG consumes it; thin stubs in `lcars.js` forward legacy callers.

- **XACA-0292-006 — CHANGE REQ section shell:** Sidebar button, mobile tabbar
  button, and section element all start `style="display:none"`. `initChangeReqSection()`
  fetches `/api/team-config` on page load and calls `applyChangeReqVisibility(enabled)`;
  also listens for `crsupport-changed` events for runtime flag toggles.

- **XACA-0292-007 — CHANGE REQ list view:** New `js/lcars-cr-tab.js` and
  `css/lcars-cr-tab.css`. 9-column table (CR ID, TYPE, STATE, TITLE, PLATFORM,
  APPROVER, DEPLOY WINDOW, PUSHBACKS, DOCS) from `boardData.backlog` items with
  a non-empty `cr_id`. Filter bar with state pills (10), type pills (4), platform
  dropdown, sort cycle, and debounced search. Filter state persisted to
  `localStorage['lcars-change-req-filter']`. Per-row DOCS button opens
  `showPlanDocModal(itemId, false, true)` then calls `switchDocTab(itemId, 'cr')`
  after 20 ms. Note: filter logic is inline rather than consuming the shared
  `createFilterBar` component (Wave 3G decision); both bars are visually similar
  but not code-shared — a future ticket can unify them.

- **XACA-0292-008 — Saved-view chips:** Three chips in `#change-req-saved-views`:
  "THIS WEEK'S CRs", "AWAITING APPROVAL", "EMERGENCY (30D)". Active chip AND-s
  its predicate on top of the existing filter-bar result. State persisted to
  `localStorage['lcars-change-req-saved-view']`. Manual filter changes clear the
  active chip. Helpers `isWithinIsoWeek` / `isWithinLastNDays` added to
  `lcars-cr-tab.js`; absent timestamps return `false`.

- **Files changed:** `lcars-ui/index.html`, `lcars-ui/js/lcars.js`,
  `lcars-ui/css/lcars.css`, `lcars-ui/server.py` (modified);
  `lcars-ui/js/lcars-filter-bar.js`, `lcars-ui/js/lcars-cr-tab.js`,
  `lcars-ui/css/lcars-cr-tab.css` (new).

- **Related:** EPIC-0017 (CAB-Aware Mobile Workflow).

### Style: LCARS — drop trailing "STATUS" from main header title

- **What:** Stripped the trailing `STATUS` token from the LCARS main header title across all three responsive size variants (`.title-full`, `.title-medium`, `.title-short`) plus the browser tab `document.title`. Inline section titles (`MISSION STATUS`, `BACKUP SYSTEM STATUS`, sidebar `WORKFLOW STATUS`) are intentionally unchanged — only the top-of-page header was trimmed.
- **Why:** The word was redundant noise — the LCARS UI is a status dashboard by definition; every header title repeating "STATUS" added clutter without information.
- **Files:** `lcars-ui/js/lcars.js` (six title-builder branches in the responsive title updater), `lcars-ui/index.html` (replaced hard-coded `STATUS` placeholder in `.title-short` with `--` to match the other two placeholders).

### Feat: XACA-0301 — per-machine override mechanism for LCARS `lcars-target.js`

- **What:** New `/lcars-target.local.js` server route that serves the per-machine override file at `~/.aiteamforge/lcars-target.local.js` (404 when absent). Both `redirect.html` and `agent-panel-router.html` now chain a second script load after `lcars-target.js`: when the override file exists, its globals replace the default `LCARS_TARGET_TEAM` / `LCARS_TARGET_SESSION` values; when it's absent the chained `onerror` flips `LCARS_TARGET_LOADED` true and the router proceeds with the defaults — same wait/timeout semantics as before.
- **Why:** XACA-0300 made `homebrew-tap/share/lcars-ui/lcars-target.js` canonical (= `'command'`) inside the submodule. Developers who need to retarget LCARS to a specific team or session (e.g. `'finance-personal'`) previously had to `git update-index --skip-worktree` the file or edit it and never push — both fragile workarounds. With this override, the default file stays clean and per-machine retargeting lives entirely outside the repo.
- **HTML loader change:** Chained — not parallel — load. The override script appends only inside the default's `onload` callback, so JS execution order is guaranteed regardless of network timing. Cache-busted with `Date.now()` like the default.
- **Server route:** Reads from `Path.home() / '.aiteamforge' / 'lcars-target.local.js'` with `application/javascript` MIME and `no-cache` headers. 404 when missing, 500 with detail on read errors. Routed before the `.js` static catch-all so the path resolves to the home-dir source rather than `UI_DIR`.
- **Tested:** Live test server (port 8979): no-override → 404; override-present → 200 + correct body + `application/javascript` + no-cache; removal → 404 again; default `lcars-target.js` route untouched.
- **Companion to:** XACA-0300 (replaces the interim `git update-index --skip-worktree` workaround documented in CLAUDE.md's submodule section).

### Fix: XACA-0300 — repair `sync-tap.sh --commit` mode for submodule layout

- **Bug:** Pre-fix, `sync-tap.sh --commit` ran `git add -A homebrew-tap/share/` against outer dev-team. With the submodule conversion, that path is inside the submodule and `git add` fatals with `Pathspec 'homebrew-tap/share/' is in submodule 'homebrew-tap'`. The trailing `|| true` masked the failure → silent no-op for the outer pointer advance. Result: tap's files were committed inside the submodule, but the outer never advanced — leaving the repo in a half-committed state with the submodule showing modifications.
- **Fix:** Reorder commit blocks (inner submodule first, outer second) and replace `git add -A homebrew-tap/share/` with `git add homebrew-tap` (the gitlink). The outer commit now correctly snapshots the new inner HEAD.
- **Header note:** Added a submodule-aware comment block explaining the 2-step commit semantics. Final message updated to remind users to push BOTH repos in order (homebrew-tap first, then dev-team).
- **Detected by:** Subitem 009 validation as part of XACA-0300.

### Docs: XACA-0300 — document git submodule workflow in CLAUDE.md

- **Added:** New "Git Submodules — homebrew-tap Workflow (XACA-0300)" section in `claude/CLAUDE.md` under Git Workflow.
- **Covers:** 2-step commit cycle (tap changes + pointer advance), clone/pull procedures, rollback steps, pre-migration bundles/tags, and local LCARS retargeting workaround via `git update-index --skip-worktree`.
- **Why:** Developers need clear guidance on the new submodule arrangement now that XACA-0300 has converted `homebrew-tap/` from nested repo to true git submodule. Omitting step 2 (outer-repo pointer commit) is the most likely gotcha; documentation flags this explicitly.

### Chore: XACA-0300 — remove now-obsolete `scripts/check-tap-sync.sh` + cleanup `.gitignore`

- **Deleted:** `scripts/check-tap-sync.sh`. Drift between outer dev-team and inner homebrew-tap is no longer possible — the submodule is the single source of truth for tap content. The drift detector was a workaround for the dual-tracking arrangement that XACA-0300 eliminates structurally.
- **Cleaned `.gitignore`:** Removed the `homebrew-tap/share/templates/kanban/` tracking-exception block (lines previously needed because outer tracked tap files; now defunct since outer no longer tracks anything inside the submodule path).

### Refactor: XACA-0300 — convert `homebrew-tap/` from nested repo to git submodule

- **What:** Converts `homebrew-tap/` from a nested independent git repo (no `.gitmodules`) into a true git submodule of dev-team, pinned at inner-HEAD blob `82e1c7a4` (= `v0.11.2-4-g82e1c7a`). Outer dev-team no longer tracks the 1219 individual files; tracks only the submodule pointer + `.gitmodules`.
- **Why:** The dual-tracking arrangement was the root cause of the 2026-05-01 silent regression incident — outer-side XACA-0285 + XACA-0288 changes were invisible to the inner repo's history for 3 days because the two repos tracked the same files with separate histories and `sync-tap.sh` only covered a subset of paths. With a single source of truth, drift is structurally impossible.
- **Submodule URL:** `https://github.com/DoubleNode/homebrew-aiteamforge.git` (clean form, no embedded username — works for any tap consumer; auth handled by gh CLI / .netrc as before).
- **Pre-flight reconciliation:** Required because outer-HEAD had a per-machine `lcars-target.js` override leaked into history; resolved in the preceding commit on this branch (canonical = inner-HEAD per XACA-0300 reconciliation Q1).
- **Pre-migration baseline tags:** Created locally in both repos as `pre-xaca-0300-submodule-migration`. Bundles at `~/aiteamforge-backups/xaca-0300/{dev-team,homebrew-tap}-pre-migration.bundle` for full-history recovery if needed.

### Fix: XACA-0300 — reconcile `lcars-target.js` drift before submodule conversion

- **What:** Restores `homebrew-tap/share/lcars-ui/lcars-target.js` in outer dev-team to the canonical `'command'` single-line content that matches inner `homebrew-tap/.git` HEAD blob `d0720205`.
- **Why:** Pre-flight verification for XACA-0300 (nested-repo → submodule conversion) found one drifting file: outer dev-team had it tracked as `'finance-personal'` (a per-machine LCARS retargeting override leaked into outer's history at `730f011e`); inner had `'command'` (the public tap default). Converting to a submodule with that drift unreconciled would silently drop outer's value from history. Canonical winner is inner-HEAD per Q1=(a) of XACA-0300 reconciliation review.
- **Companion follow-up:** XACA-0301 will add a per-machine override mechanism (`/lcars-target.local.js` route serving from `~/.aiteamforge/lcars-target.local.js` + secondary script tag in `redirect.html`/`agent-panel-router.html`) so future retargeting doesn't dirty the submodule. Until that lands, developers retargeting LCARS locally can `git update-index --skip-worktree share/lcars-ui/lcars-target.js` inside the submodule.

### Tooling: `scripts/check-tap-sync.sh` — flag drift between outer dev-team and inner homebrew-tap repos

- **What:** New helper that compares blob hashes for every file outer dev-team tracks under `homebrew-tap/` against the same paths in the inner `homebrew-tap/.git` repo's HEAD. Reports drift, outer-only paths, and inner-only paths. Exits 1 on drift, 0 in sync, 2 on setup error.
- **Why:** The dual-repo arrangement (outer dev-team tracks `homebrew-tap/` files; inner `homebrew-tap/.git` also tracks them with separate history) has no automated sync for tap-only directories like `docs/`, `libexec/`, and `share/templates/`. `sync-tap.sh` only covers `lcars-ui/`, `kanban-hooks/`, and a handful of `scripts/` files. The 2026-05-01 incident (XACA-0285 + XACA-0288 changes silently regressed disk content for 3 days because an unpopped stash inside the inner repo went unnoticed) is the precedent. This tool turns that class of failure into a one-line check.
- **Modes:**
  - `scripts/check-tap-sync.sh` — human-readable report, exits 1 on drift.
  - `--quiet` — silent on success (suitable for hooks/CI).
  - `--paths` — prints drifting paths, one per line (machine-readable).
- **Future wiring (not in this commit):** A future XACA item will hook this into a pre-push gate on the outer repo so divergence is caught before it ships. For now it's a manual / on-demand utility.
- **Companion to:** the `Sync from dev-team` commit just landed in the inner `homebrew-tap/.git` repo (`82e1c7a`) which brings inner main into alignment with outer for the first time since 2026-05-01.

### Fix: XACA-0288 — recover UserPromptSubmit hook wire-up in homebrew-tap settings.json.template

- **What:** Adds back the 11-line `UserPromptSubmit` block in `homebrew-tap/share/templates/claude/settings.json.template` that wires the `inject-time-context.sh` hook into AITeamForge installs. Block content is byte-identical to the version that has been live in the inner `homebrew-tap/.git` repo since 2026-05-01 (commit 21a5b647 in that repo).
- **Why:** XACA-0288 made this template change in the inner `homebrew-tap/.git` repo only. The outer `dev-team/.git` repo never received it because `sync-tap.sh` doesn't cover `share/templates/`. Yesterday's recovery commit (this repo, 22dcd5a9) committed the hook *script* under that path but the template that references it was still stuck at outer's pre-XACA-0288 HEAD — leaving the script as an orphan with no UserPromptSubmit listener to invoke it.
- **Effect on installs:** Without this block, a clean AITeamForge install would write a `~/.claude/settings.json` with no UserPromptSubmit listener — meaning the time-context-tick hook would never fire on freshly installed machines. Existing dev environments are unaffected (the live `~/.claude/settings.json` already has it from XACA-0288's pilot).
- **Related root-cause work:** Tracked under remediation paths A (sync inner repo's HEAD with outer's) and B (expand `sync-tap.sh` coverage to `docs/`, `libexec/`, `share/templates/`) — both being executed in this branch.

### Chore: add LCARS port reservations for `finance-personal` and `legal-coparent` sub-teams

- **What:** Reserves two LCARS server ports under `lcars-ports/`:
  - `finance-personal-lcars.port` → `8427`
  - `legal-coparent-lcars.port` → `8230`
- **Why:** Each LCARS-instrumented team/sub-team needs a stable port so its server, browser bookmarks, and `lcars-target.js` redirects all agree. These two sub-teams (Finance personal, Legal co-parenting) were not yet registered. Other 193 sibling port files in the same directory follow the same convention.
- **Out of scope:** No server scripts, theme files, or order files are added — this commit reserves the port numbers only.

### Feat: XACA-0288 — homebrew-tap parity for `inject-time-context.sh` UserPromptSubmit hook

- **What:** Adds `homebrew-tap/share/templates/claude/hooks/inject-time-context.sh` so AITeamForge installs deploy the same time-context-injection hook that `~/dev-team/` uses. The shipped `homebrew-tap/share/templates/claude/settings.json.template` already wires the hook into the `UserPromptSubmit` event (committed under XACA-0288 at line ~115); this commit lands the script the template references.
- **Why:** XACA-0288 shipped the live hook (`~/.claude/hooks/inject-time-context.sh`) and the settings.json.template wire-up, but the actual hook script was never copied into the homebrew-tap template tree. Result: clean installs of AITeamForge would write a settings.json that points to a non-existent file. This commit closes that gap — no live behavior changes here, only installer parity.
- **Hook contents:** Script is byte-identical to the live deployed hook. Reads `session_id` from stdin JSON (per Claude Code UserPromptSubmit contract), sanitizes it via positive whitelist, persists per-session state at `~/.claude/state/time-inject/<sid>.json`, emits `<context-tick>` only on first-run / tz-shift / date-rollover / quarter-hour-bucket-tick. Kill-switch: `CLAUDE_TIME_INJECT=0`.

### Chore: XACA-0285 — deploy Academy personas to dev-team repo `.claude/agents/`

- **What:** Commits the 4 Academy persona files (`emh`, `nahla`, `reno`, `thok`) into `.claude/agents/` of this repo, completing the per-team persona deployment that XACA-0285 architected. Files are bit-for-bit copies of the corresponding entries under `.claude/agents-master/academy/` and were placed by `kb-sync-personas`.
- **Why:** Per XACA-0285's three-layer model, master personas live in `.claude/agents-master/<team>/` and are synced into each team repo's `.claude/agents/` for token-loaded-per-session use. Other team repos got their deployments in XACA-0285; this repo (the Academy team's own) was missed. Without this commit, opening an Academy terminal here loads no team personas.
- **`.gitignore` is already correct:** line 147 explicitly notes `.claude/agents/` is tracked (source of truth); only the per-machine `.synced-from-master` marker is ignored.



- **What:** Adds the foundation layer for the CAB (Change Advisory Board) mobile workflow tracked under EPIC-0017. Introduces a 9-state CR lifecycle (`cr-drafted`, `cr-submitted`, `cr-approved`, `cr-rejected`, `cr-held`, `implementing`, `deployed-dev`, `deployed-prod`, `emergency-deployed`), 11 metadata fields (`cr_id`, `cr_type`, `cr_approved_by`, `cr_approver_name`, `cr_pushback_count`, `cr_pushback_notes`, `cr_summary`, `cr_doc_link`, `deploy_window_planned`, `platform`, `emergency_justification`), and 9 lifecycle timestamps (`cr_created_at`, `cr_submitted_at`, `cr_approved_at`, `cr_dev_started_at`, `cr_testing_started_at`, `cr_deployed_dev_at`, `cr_deployed_prod_at`, `cr_emergency_deployed_at`, `cr_completed_at`). Cycle-time fields (`cr_cycle_*_days`, `deploy_estimate_delta_days`) are derived at read time, **never stored**.
- **Why:** Main Event mobile engineering operates under D&B's CAB framework (effective 2026-04-07) requiring a CR before each production deploy. EPIC-0017 delivers the kanban + LCARS infrastructure to operate that workflow without losing throughput; Phase 1 is the schema foundation every later phase depends on.
- **Load-bearing feature flag:** Every CR-related code path is gated behind a per-board `teamConfig.crSupport.enabled` boolean, **defaulted to `false`**. When disabled, every `kb-cr` subcommand exits 0 with a single informational message and performs zero side effects (no reads, no writes, no errors). All four migrated boards start in the disabled state — zero behavior change until each board explicitly opts in.
- **New files:**
  - `homebrew-tap/share/templates/kanban/cr-schema.json` — canonical schema document consumed by the migration script and `kb-cr` helpers.
  - `homebrew-tap/share/templates/kanban/migrate-cr-schema.py` — idempotent migration script with backup-required guard, `--dry-run`, and `--all-mobile` flags.
  - `scripts/kb-cr.sh` — `kb-cr` dispatcher with 12 subcommands (`draft`, `submit`, `approve`, `reject`, `hold`, `start-dev`, `start-test`, `deploy-dev`, `deploy-prod`, `emergency`, `complete`, `backfill`, `show`). Every state-mutating subcommand routes through `_kb_cr_preamble` + `_kb_cr_disabled_exit`.
  - `homebrew-tap/share/scripts/kb-cr.sh` — installer-shipped copy of the dispatcher (deployed to `$AITEAMFORGE_DIR/scripts/kb-cr.sh` by `install_lcars_profile_script`).
  - `tests/cr-lifecycle/` — 44-test bats suite covering disabled-state parity (24 tests), migration idempotency (6 tests), flag toggle round-trip (3 tests), and schema structural validity (11 tests). Single entry point: `tests/cr-lifecycle/run-all.sh`.
- **Modified files:**
  - `kanban-helpers.sh` — adds `kb-backlog show`/`info` rendering of CR fields when flag is enabled and `cr_id` is set; sources `kb-cr.sh` with file-existence and double-source guards.
  - `homebrew-tap/share/templates/kanban/kanban-helpers.template.sh` — mirrors the `kanban-helpers.sh` deltas using `${AITEAMFORGE_DIR}` substitution for portability across non-dev installs.
  - `homebrew-tap/libexec/installers/install-kanban.sh` — `install_lcars_profile_script` now copies `kb-cr.sh` into `$AITEAMFORGE_DIR/scripts/`.
  - `.gitignore` — adds an exception so `homebrew-tap/share/templates/kanban/` source files (cr-schema.json, migrate-cr-schema.py) are tracked while runtime `kanban/` data remains ignored.
- **Live boards migrated** (all opted-in to `crSupport.enabled=false` — no behavior change):
  - `/Users/Shared/Development/Main Event/MainEventApp-iOS/kanban/ios-board.json`
  - `/Users/Shared/Development/Main Event/MainEventApp-Android/kanban/android-board.json`
  - `/Users/Shared/Development/Main Event/MainEventApp-Functions/kanban/firebase-board.json`
  - `/Users/Shared/Development/Main Event/dev-team/kanban/command-board.json`
  - Each board has a corresponding `*.bak-cr-schema-*` backup. Re-running `migrate-cr-schema.py --all-mobile` is a no-op (verified idempotent via md5 byte-equality).
- **Bugs caught during Phase 1 verification:**
  - Backup-detection glob used `Path.stem` (drops `.json`) but the script's own user-facing instruction said to back up with the full filename. Fixed to use `Path.name`.
  - `--all-mobile` hardcoded `mainevent-board.json` for the cross-platform coordination board. EPIC-0017 line 144 specifies `command-board.json`. Fixed.
- **Out of scope for this phase:** UI changes (CHANGE REQ tab, BACKLOG rename, item DOCS popup CR tab) — those land in XACA-0292. Automations and views — XACA-0293..0297. CR document content and routing — manual operator workflow until D&B CAB integration is feasible (likely never; the system is designed for fully manual transitions).
- **Related:** EPIC-0017 (CAB-Aware Mobile Workflow), XACA-0142 (CR process for prod releases — historical context), XACA-0146 (CR skill technical depth — historical context).
- **PR-review fixes (PR #326 follow-on commit):**
  - Backfill loop refactored to a single jq invocation that emits one TSV line per eligible item, replacing a per-item loop that issued ~7 jq calls per backlog entry. O(N) → O(1) jq invocations.
  - `kb-cr show` indent for the `emergency-deployed` timestamp normalized to 4 spaces (was 2), matching the other timestamp lines.
  - `tests/cr-lifecycle/run-all.sh` banner text corrected: cat4 has 11 tests, not 10.
  - `homebrew-tap/docs/USER_GUIDE.md` — added "CR (Change Request) Schema — Opt-In Workflow" section documenting the per-board migration path (tap location, backup-required step, dry-run flow, flag-toggle workflow, and the `kb-cr` subcommand reference).
  - `homebrew-tap/docs/ARCHITECTURE.md` — added "CR (Change Request) Lifecycle Axis" subsection in Extension Points, documenting the three-orthogonal-axes model (status / releaseAssignment / crState), the derived-not-stored cycle-time invariant, and the disabled-state safety guarantee.
  - One follow-on subitem deferred to XACA-0299: homebrew-tap installer-simulation test for migrate + `kb-cr` deploy (~30 min, real but not a PR blocker).

### Feat: XACA-0216 — Genericize AITeamForge: remove Main-Event skills, sanitize generic skills, add RELNOTES Manager

- **Removed 9 Main-Event-specific skills** (8 fully discontinued from AIT, 1 renamed to its generic form): Center Management App Update, Create Center, Main Event CR (was tracked symlink → Command), Main Event RELNOTES Manager (renamed → RELNOTES Manager, then sanitized), Main Event Weekly Reports, Marketing Summary, Scrum of Scrums ME APP, Weekly Email Newsletter, Weekly Product Owner Report
- **Sanitized 5 generic skills** (decoupled from Main Event context, now applicable to any team): Release Manager, Kanban Manager, git-worktree, Project Planner, Team Mission Status
- **Sanitized 3 release personas** (geordi, scotty, obrien — decoupled from optional `/cr` Change Request integration)
- **Added 1 new generic skill:** RELNOTES Manager — manages progressive release notes lifecycle across configurable environment pipelines (DEV → QA → PROD), App Store asset generation, and marketing tie-ins for any product/team
- **Added one-shot helper:** `scripts/post-xaca-0216-cleanup.sh` — repoints 9 stale `~/.claude/skills/` symlinks to Command's repo and creates 1 new RELNOTES Manager symlink post-merge; idempotent
- Updated README.md to clarify AITeamForge generic positioning and skill boundaries
- `deploy-to-production.sh` and `claude/CLAUDE.md` were audited — both already use generic patterns (deploy iterates `skills/` dynamically; CLAUDE.md has no Main-Event-specific skill references) and required no edits

### Chore: XACA-0275 — Rename backup root from ~/dev-team-backups/ to ~/aiteamforge-backups/

- **What:** Renamed the backup directory root across all shipped scripts and configuration from `~/dev-team-backups/` to `~/aiteamforge-backups/`, aligning backup storage with the AITeamForge product naming. Affected components include homebrew-tap shipped scripts, dev-team source mirrors, launchd plist logging paths, and documentation references.
- **Why:** The `dev-team-backups` naming created confusion about ownership and scope. The backups serve the AITeamForge product ecosystem (kanban data, LCARS server state, fleet reporter snapshots, stub-guard archives, persona sync state). Reverses the path unification introduced in XACA-0181 (which had moved them under the `dev-team` umbrella) — the new naming clarifies that AITeamForge is the primary product and dev-team infrastructure is a supporting component, not the other way around.
- **Migration:** Clean break — no data is migrated. The old `~/dev-team-backups/` directory is retained on disk as a historical artifact and may be manually deleted by the operator if desired. New backup runs write to `~/aiteamforge-backups/`, which is created automatically on the first backup operation after this change lands.
- **Affected paths:**
  - `homebrew-tap/scripts/` — kanban backup scripts, fleet reporter, LCARS server backup rotations
  - `.claude/CLAUDE.md` — stub-guard reference in the default global instructions (feedback section)
  - `com.aiteamforge.*.plist` launchd agents — backup log output paths
  - `docs/`, `README.md` — backup directory references in setup and troubleshooting sections
- **Related:** XACA-0181 (path unification that this change reverses); XACA-0219 (stub-guard baseline established with `dev-team-backups/` naming, will remain compatible with both old and new paths during transitional period).

### Feat: XACA-0290 — Subagent Dispatch & Advisor Escalation convention (CLAUDE.md)

- `claude/CLAUDE.md` — Added new section "🧭 Subagent Dispatch & Advisor Escalation" between the Standard Development Workflow and PR Auto-Spawn sections. Captures two paired conventions: (1) default `model:` routing on `Agent` tool dispatches — `haiku` for read-only research/scans, `sonnet` for bounded execution/verification, `opus` for architectural reasoning/review — applied especially to `general-purpose`/`Explore`/`Plan` types that carry no frontmatter tier and otherwise inherit Opus from the parent; (2) the `NEEDS_ADVISOR:` escalation protocol that EVERY Sonnet/Haiku subagent prompt must include — a 2-attempt budget, then STOP and return a structured `NEEDS_ADVISOR:` reply with what was tried / what's blocking / specific question. The orchestrator answers in 2–3 sentences and re-dispatches with guidance prepended (escalate the *answer*, not the model).
- Inspired by Anthropic's published advisor-strategy pattern. Cost win comes from making the subagent execution loop cheap (Sonnet/Haiku) while preserving Opus judgment at decision points; the API benchmarks reported ~12% cost reduction with quality lift on SWE-bench and ~85% cost reduction on BrowseComp at the Haiku tier. Our shadow of the pattern uses the existing `model:` override on the `Agent` tool plus the `NEEDS_ADVISOR:` sentinel for the escalation channel — no harness changes required.
- Footer last-updated stamp refreshed to 2026-05-04 with the rationale for the addition.

### Fix: XACA-0288 — Linux portability: tolerate non-symlink /etc/localtime (subitem 019)

- `claude-hooks/inject-time-context.sh` — `readlink /etc/localtime` aborts the hook under `set -e` on Debian/Ubuntu installs where `/etc/localtime` is a regular file rather than a symlink. macOS always uses a symlink so M3Pro is unaffected, but the AITeamForge tap ships to other machines. Wrapped the readlink + sed pipeline in `2>/dev/null | sed ... || echo ""` so the IANA lookup degrades to an empty string on Linux failure. The decision tree's existing tz-shift comparison (`NOW_IANA != PRIOR_IANA`) treats empty-vs-empty as no shift on the steady state, and any state inherited from a prior macOS-like setup will surface as a one-time tz-shift on first Linux run — acceptable. Verified macOS path still produces `iana: "America/Chicago"`. Closes [Review] subitem 019 surfaced by reviewer on PR #322.

### Fix: XACA-0288 — Edge-case hardening: session_id sanitization + writable-dir guard (D2/D3 from edge-case test pass)

- `claude-hooks/inject-time-context.sh` — **Edge-case D3 (HIGH severity, fixed):** `STATE_FILE="${STATE_DIR}/${SESSION_ID}.json"` had no sanitization on `SESSION_ID`. A session_id containing `/` could escape the state dir; a value like `../../tmp/x` would resolve outside `~/.claude/state/time-inject/`. While Claude Code's harness today only sends UUID-shaped session_ids, "don't trust input" applies. Fixed: after JSON parse, run session_id through a positive-whitelist regex `[A-Za-z0-9._-]` and fall back to `"unknown"` if the sanitized result is empty. UUIDs and the `unknown` fallback both pass through unchanged. Verified: a path-traversal session_id `../../tmp/traversal-attack` is now sanitized to `....tmptraversal-attack` and lands inside the state dir; no file is created in `/tmp`.
- `claude-hooks/inject-time-context.sh` — **Edge-case D2 (LOW severity, fixed):** When `~/.claude/state/time-inject/` is read-only, `mktemp` fails and `set -euo pipefail` aborts with exit 1 and a stderr message. The harness treats non-empty stderr from hooks as user-visible noise. Also left a `.tmp.*` orphan if the dir was partially writable mid-run. Fixed three ways: (1) `mkdir -p ... 2>/dev/null || exit 0` before any state work; (2) `[[ -w "$STATE_DIR" ]] || exit 0` writability guard; (3) `mktemp ... 2>/dev/null || exit 0` plus `trap 'rm -f "$TMP" 2>/dev/null' EXIT` so any abort path between mktemp and mv cleans up its own orphan. Verified: with state dir at chmod 555, hook exits 0 with zero-byte stdout and no orphan files.
- **Edge-case D1 (MEDIUM severity, deferred):** Concurrent first-run race — five parallel hook invocations against a brand-new session_id all see the state file as absent and all inject. Atomic write prevents corrupt state, but the read-then-decide window is not protected. Deferred as XACA-0288-016 follow-up because Claude Code fires hooks serially today; would only manifest if the harness ever parallelizes hooks or if the same session_id is shared across windows.
- Edge-case test pass exercised T1-T8 plus an informational T9 state-file-accumulation count. T1 (malformed stdin), T2 (corrupt state file), T5a (shell metachars), T6 (multi-bucket walk), T7 (date-rollover priority), T8 (tz-shift priority) all PASS; T3, T4, T5b were the defects above.
- Regression check after fix: kill-switch, same-bucket no-op, and stdout schema validation all still PASS.

### Fix: XACA-0288 — QH bucket key missing hour component (D3 from pilot 2)

- `claude-hooks/inject-time-context.sh` — Pilot 2 (XACA-0288-006 re-run, all 6 criteria PASS) flagged an out-of-scope finding: the quarter-hour bucket key was built as `${DATE}T${MINUTE_BUCKET}` only — no hour. At 14:04 and 15:04 the key collapsed to the same `${DATE}T00`, so a session running across an hour boundary would silently skip injection on the next minute-bucket within the new hour. Fixed by including hour in the bucket key: `${DATE}T${HH}:${MM_BUCKET}` (e.g. `2026-05-01T15:00`). Verified: re-firing with same SID in same bucket → empty stdout (no-op preserved); staging prior qh to one hour earlier → injection fires with `reason=qh-tick`. State-file shape changed (`qh` field is now `YYYY-MM-DDTHH:MM` instead of `YYYY-MM-DDTMM`); pre-existing state files written under the old key will all reinject on first hook run after the fix, then settle to the new key — acceptable migration cost for a shared-state field that nothing else reads.
- This was caught by Thok's eye on the bucket math during pilot 2 review, not by any of the 6 acceptance criteria. Adding it as a regression-test target for subitem 010 (Testing & Debugging).

### Fix: XACA-0288 — Inject-time-context hook contract corrections (D1 + D2 from pilot)

- `claude-hooks/inject-time-context.sh` — Initial pilot run (XACA-0288-006) revealed two contract mismatches with Claude Code's UserPromptSubmit harness. **D1:** Claude Code does NOT export `CLAUDE_SESSION_ID` to hook child processes; it passes session metadata via stdin JSON (`{"session_id":"...","hook_event_name":"UserPromptSubmit",...}`). Original implementation read `${CLAUDE_SESSION_ID:-unknown}` from env, causing every concurrent session to collide on `unknown.json`. Fixed by consuming stdin once and parsing `session_id` via python3 (already a dependency); falls back to `"unknown"` only on empty/malformed stdin.
- `claude-hooks/inject-time-context.sh` — **D2:** Original stdout schema `{"type":"text","text":"<context-tick>..."}` was silently dropped by the harness. Canonical UserPromptSubmit injection schema per official Claude Code hooks docs is `{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"<context-tick>..."}}`. Updated the emit wrapper accordingly. The `<context-tick>...</context-tick>` content itself is unchanged; only the JSON wrapper changed.
- The decision-tree logic (first-run / tz-shift / date-rollover / qh-tick), atomic state writes (mktemp + mv), and the `CLAUDE_TIME_INJECT=0` kill-switch all worked correctly per the pilot's C3/C4/C5 results — only the harness contract layer needed correction.
- `plans/time-context-injection.md` — Added §8 "Pilot Findings" documenting both defects and the contract-vs-assumption gap. The original plan flagged R1 (`CLAUDE_SESSION_ID` availability) as MEDIUM but did not pre-verify; that risk materialized.
- Smoke-tested all four behaviors after fix: stdin-driven session_id, empty-stdin fallback to `unknown`, kill-switch with correct env scoping, same-bucket no-op (zero-byte stdout), schema validation passes (`hookSpecificOutput.hookEventName == "UserPromptSubmit"`, `<context-tick>` present in `additionalContext`).
- Live verification: after the fix landed, real concurrent Claude Code sessions began writing UUID-shaped state files to `~/.claude/state/time-inject/` (e.g. `3199e7bd-…json`, `41dda0de-…json`), confirming D1 is resolved in the real harness path. Full re-pilot (XACA-0288-006 part 2) in a fresh session is the next step.

### Feat: XACA-0288 — Time/Date context injection hook (UserPromptSubmit, subitems 001-004)

- `claude-hooks/inject-time-context.sh` — New UserPromptSubmit hook that injects a `<context-tick>DATE · TIME TZ</context-tick>` block into the user prompt only when state changes: first run, date rollover, quarter-hour bucket change, or IANA timezone shift. Emits no output within the same QH bucket, keeping the prompt cache byte-identical for cache warmth.
- Kill-switch: `CLAUDE_TIME_INJECT=0` causes immediate exit before any state reads or writes; verified no state file is created when the kill-switch is engaged.
- Per-session state at `~/.claude/state/time-inject/<session_id>.json` with atomic writes (`mktemp` + `mv` pattern per K045). State directory is auto-created on first run. State keys: `date`, `qh`, `iana`, `tz`, `reason`.
- `CLAUDE_SESSION_ID` fallback: if the harness does not export the variable (edge case per R1), the hook degrades to `session_id=unknown` — all such sessions share one state file. Verified: script works correctly with and without `CLAUDE_SESSION_ID` set.
- Smoke-tested: first-run emission, same-bucket no-op, kill-switch, no-session-ID fallback, QH rollover re-injection, atomic write (no orphaned `.tmp.*` files).
- subitems 005 (settings.json patch), 006 (pilot), 007 (tap mirror), and 008 (tap settings.json.template) are tracked separately.

### Test: XACA-0271 — Introduce bats shell test harness for kanban-helpers.sh

- `tests/bats/` — New formal shell test harness directory. dev-team previously had only ad-hoc `tests/test-*.sh` scripts that each re-implemented their own pass/fail counter machinery; bats gives us TAP output, per-`@test` `setup`/`teardown`, and isolated `mktemp` sandboxes without bespoke scaffolding. Picked bats over shunit2 because `bats-core` 1.13.0 is already installed at `/opt/homebrew/bin/bats` (no new dependency), upstream is active, and shunit2's main strength (POSIX sh portability) is moot — kanban-helpers.sh is zsh-only.
- `tests/bats/helpers.bash` — Shared setup helpers: `setup_kb_sandbox` / `teardown_kb_sandbox` (per-`@test` `mktemp -d` rooted at `KB_KNOWLEDGE_GLOBAL_ROOT`), `write_source_entry` (writes a minimal valid knowledge .md with optional `status:` and auto-attached `promoted_to:` pointer when status is `promoted`), and `run_promote` (the bash-bats → zsh-only-helper bridge — invokes `zsh -c '...' _ "$@"` so kanban-helpers.sh can be sourced under zsh while bats runs under bash; the literal `_` placeholder for `$0` is the canonical idiom for forwarding `"$@"` cleanly into the script body).
- `tests/bats/kb-knowledge-promote.bats` — Five `@test` blocks seeding kb-knowledge-promote coverage: (1) re-promote guard refuses source with `status: promoted` and leaves the source file byte-for-byte unchanged (sha256 round-trip) — locks in the XACA-0257 guard; (2) fresh promote dry-run prints the PROMOTION PLAN block, exits 0, and writes neither the stub nor the target file when `--confirm` is absent; (3-5) status-field matrix — `status` absent and `status: draft` both allow promotion to proceed in dry-run, `status: promoted` is refused with the "already a promotion stub" error.
- `tests/bats/run.sh` — Minimal runner (`exec bats "$(dirname "$0")"/*.bats`) for ergonomic invocation; equivalent to `bats tests/bats/`.
- `tests/bats/README.md` — Documents how to run, why bats was chosen, and the rule of thumb for when to add a new `.bats` file vs a one-shot `tests/test-*.sh` regression script. Existing one-shot regression scripts are NOT migrated — out of scope for this seed (per task description). Future tickets can port them piecemeal as the harness matures.
- **Verification** — `bats tests/bats/` exits 0 with `5 passed, 0 failed`. Sandbox hermeticity confirmed: no test artifacts leak to the user's real `~/knowledge/` tree. The bash-bats / zsh-helpers bridge sources `$BATS_KANBAN_HELPERS` under `set +u` (matching the existing `tests/test-knowledge-promote-stdout-clean.sh` pattern) and neutralizes `_kb_log_activity` so tests cannot mutate kanban activity state.

### Fix: XACA-0274 — kb-knowledge-promote leaks `source_tier=<value>` to stdout on `--confirm`

- `kanban-helpers.sh` — `kb-knowledge-promote` declared `local source_tier` twice in the same function scope. First declaration at the top tier-ordering guard (XACA-0260, ref-derived from `${source_ref%%:*}`), second declaration in the post-confirm frontmatter-capture block (XACA-0261, file-derived via `_kb_knowledge_yaml_field`). Under zsh, re-declaring an already-local variable with a bare `local NAME` listing (no assignment on the same line) causes the shell to echo `varname=value` to stdout — same class of leak fixed in XACA-0267 for `kb-knowledge-validate`. Result: every successful `kb-knowledge-promote --confirm` printed a stray `source_tier=agents` (or whatever the source tier was) line between the PROMOTION PLAN block and the `Wrote target` confirmation.
- `kanban-helpers.sh` — Removed `source_tier` from the second `local` declaration in the frontmatter-capture block. The variable is already declared local at the top of the function by the tier-ordering guard, so the subsequent `source_tier=$(_kb_knowledge_yaml_field ...)` assignment now correctly overwrites the existing local without re-declaring it. The other three variables in that block (`source_date`, `source_tags`, `source_source`) remain on the `local` line — they have no prior declaration so still need it.
- Verified bug reproduces on `develop` HEAD `fbf5fd5e` under zsh and is gone after the fix; bash never exhibited the leak (zsh-specific divergence on bare `local` with prior declaration).
- `tests/test-knowledge-promote-stdout-clean.sh` — New regression test with two cases: (T1) explicit assertion that `kb-knowledge-promote --confirm` stdout contains no `^source_tier=` line — the literal XACA-0274 symptom; (T2) general guard that no bare `^[a-z_][a-z_0-9]*=` line appears in stdout — catches future re-declaration leaks of any other variable in the same class. Verified the test fails against the develop HEAD (buggy) helpers and passes against the fixed worktree helpers. Existing knowledge tests (`test-knowledge-add-index-scaffold.sh`, `test-knowledge-crossref.sh`, `test-knowledge-curated-title-roundtrip.sh`, `test-knowledge-promote-tier.sh`) continue to pass with no new failures — the one pre-existing T3 failure in `test-knowledge-promote-tier.sh` (subject → agent downward promotion refused by the XACA-0260 tier-ordering guard) reproduces identically against develop HEAD and is unrelated to this fix.

### Fix: XACA-0273 — kb-knowledge-validate does not enforce tier-specific required fields

- `kanban-helpers.sh` — `kb-knowledge-validate` previously checked only the four universal frontmatter fields (`id`, `tier`, `date`, `tags`) and silently `[OK]`'d entries missing the tier-specific required fields documented in `~/knowledge/SPEC.md` §3. That gap is how XACA-0258 (`kb-knowledge-add`) and XACA-0272 (`kb-knowledge-promote` target) shipped to develop unnoticed — the validator could not catch entries created without the tier-required field. Added two conditional checks after the universal-fields block: when `expected_tier == "agent"`, the validator now requires an `agent:` frontmatter field and emits `[FAIL] Missing 'agent:' in <path> (required for tier 'agent')` when absent; when `expected_tier == "team"`, it requires a `team:` field and emits the analogous FAIL. Both failures route through `_kb_val_error` and cause non-zero exit. `has_agent`/`has_team` were added to the existing `local` declaration at the top of the function (line ~9445) to match the pre-declaration discipline established for XACA-0265 and XACA-0267 — avoids zsh trace leaks if the function is run under `xtrace` or `WARN_CREATE_GLOBAL` for future debugging.
- `scripts/tests/test-knowledge-validate-tier-required-fields.sh` — New regression test mirroring the structure of `test-knowledge-validate-resolver-rejection.sh`. Builds a `mktemp -d` fixture with one agent-tier entry missing `agent:` and one team-tier entry missing `team:`, runs the validator with `KB_KNOWLEDGE_GLOBAL_ROOT` pointed at the fixture, and asserts (1) output contains `Missing 'agent:'` plus the agent fixture filename, (2) output contains `Missing 'team:'` plus the team fixture filename, (3) both `(required for tier 'agent')` and `(required for tier 'team')` context strings are present, (4) validator exits non-zero. Cleanup uses recursive directory removal (the standard idiom for tempdir cleanup — never `find -delete` per XACA-0258). Negative-control verified: the test fails 4 of 7 assertions when run against `HEAD~1` (pre-fix validator), confirming it actually exercises the new enforcement and isn't a tautology.
- **Survey result** — Patched validator was run against the live `~/knowledge/` tree (350 entries) before merge; 0 errors and 0 warnings. No pre-existing offenders, no remediation needed in this PR. Going forward, any agent-tier entry written without an `agent:` field (or team-tier entry without `team:`) will be caught at validation time instead of silently shipping.

### Fix: XACA-0272 — kb-knowledge-promote target frontmatter missing required tier-specific field

- `kanban-helpers.sh` — `kb-knowledge-promote` wrote target frontmatter with `id` / `tier` / `date` / `tags` / `source` / `promoted_from` but never emitted the SPEC §3-required tier-specific field (`agent: <persona>` for `tier: agent` targets, `team: <team-name>` for `tier: team` targets). Promotions into the team tier therefore produced entries that failed `kb-knowledge-validate` against §3. Mirrors the `tier_field` pattern XACA-0258 introduced in `kb-knowledge-add`: `target_tier_field` is set in the `case "$target_tier"` block at the same time `target_dir`/`target_prefix` are resolved, then conditionally emitted between the `tier:` and `date:` lines in the target-write heredoc. Subjects and project tier targets are unaffected (no required tier-specific field). The agent-tier branch is wired for symmetry even though SPEC §7 makes promotion *into* agent tier unreachable in practice (agents = rank 1, the floor) — costs two lines and matches the kb-knowledge-add reference.
- Pre-existing — discovered while reviewing PR #301 (XACA-0258 fix to `kb-knowledge-add`); separate function, separate fix. Note: XACA-0273 (which landed on develop while this PR was open) wired `kb-knowledge-validate` to enforce these same tier-specific required fields — the two fixes are complementary: XACA-0272 ensures `kb-knowledge-promote` writes the field, XACA-0273 ensures the validator catches it if a future writer regresses again.
- Verified end-to-end against two throwaway sandboxes: TEST 1 (`agents:reno-test:k001 → teams:academy-test`) emits `team: academy-test` between `tier: team` and `date:` as expected; TEST 2 (`agents:reno-test:k001 → subjects:testing/sandbox`) emits no spurious tier field, frontmatter byte-identical to pre-fix behavior. Source-stub frontmatter unchanged in both cases (uses source-tier fields, not target-tier fields).
- `kanban-helpers.sh` — Added `_kb_validate_name_component` guards to the agents and teams branches of the `case "$target_tier"` block, mirroring the existing `_kb_validate_subject_path` guard on the subjects branch. The agents and teams branches previously accepted unvalidated `target_path_part` substrings, which would have allowed path-traversal sequences (`teams:../escape`) and uppercase names (`agents:Reno`) to flow through to `mkdir -p` and the target-file write. With this guard in place, malformed refs are refused with a clear error before any filesystem mutation. Subjects branch already had this protection (line 9179); this brings the other two branches into parity. Addresses XACA-0272-002 review feedback in the same PR rather than splitting it into a follow-up ticket.
- `tests/test-knowledge-promote-tier.sh` — Added `assert_frontmatter_line` and `assert_frontmatter_line_absent` helpers, then five new assertions: T1 negative-controls confirm subjects-target frontmatter does not carry the source's `agent:` field forward and does not emit a stray `team:` field; T2 positive assertion confirms `team: testing-team` is emitted in the team-target frontmatter (locks in the SPEC §3 fix). T5 adds three new cases for the target_path_part validation: T5a refuses `teams:../escape` (path traversal), T5b refuses `agents:Reno` (uppercase persona), T5c confirms `teams:academy` (well-formed) still succeeds — the positive control guards against the new validation block accidentally rejecting valid input. Suite is now 9-passing-1-failing where the single failure is the pre-existing T3 (subject → agent downward promotion refused by SPEC §7) — unchanged by this PR.

### Fix: XACA-0286 — _kb_knowledge_reindex_one clobbers hand-curated project INDEX.md title

- `kanban-helpers.sh` — `_kb_knowledge_reindex_one` derived the project tier H1 (`# Project Knowledge — <name>`) and `**Project:** <name>` line from `basename($dir)`, which for the per-repo project knowledge layout (`<repo>/kanban/knowledge/project/`) is always literally the string `"project"`. Every reindex therefore rewrote any hand-curated title (e.g. `Project Knowledge — dev-team (Academy)`) back to `Project Knowledge — project`. Surfaced more painfully by XACA-0263 because `kb-knowledge-add` now triggers reindex on every entry add, so curated titles got clobbered on the next knowledge save instead of only on explicit `kb-knowledge-reindex` calls.
- `kanban-helpers.sh` — Added project-tier H1 and `**Project:**` round-trip preservation, mirroring the existing "Relevant Subjects" preservation block. When `INDEX.md` already exists in a project knowledge dir, the H1 (first `# ` line) and the `**Project:** <value>` line are extracted and reused verbatim, so reindex output is now its own valid input (idempotent — verified across two consecutive reindex passes).
- `kanban-helpers.sh` — Added `_kb_knowledge_project_display_name()` helper near `_kb_knowledge_project_path` that produces a sensible default when no curated INDEX.md exists. Resolution order: (a) `.kb-project` sentinel file in the project knowledge dir or up to 3 ancestor levels — first non-blank trimmed line wins; (b) for the in-repo layout `*/kanban/knowledge/project`, the basename of the repo dir (so a fresh dev-team project tier resolves to `dev-team` instead of `project`); (c) fallback to `basename($dir)` for unusual layouts. Other tiers (agent/team/subject) are untouched — their basename derivation is correct.
- `kanban/knowledge/project/INDEX.md` — Restored curated title `Project Knowledge — dev-team (Academy)` and `**Project:** dev-team` so the dev-team project knowledge tree once again has a meaningful header. (File lives in main repo; gitignored per XACA-0268, so the change isn't part of this commit's diff.)
- `tests/test-knowledge-curated-title-roundtrip.sh` — New regression test with five cases: (T1) curated INDEX.md preserves the H1 and Project line through `_kb_knowledge_reindex_one`; (T2) fresh tmpdir with `.kb-project` sentinel containing `MyCoolProject` produces `# Project Knowledge — MyCoolProject` instead of the mktemp basename; (T3) zero-byte `.kb-project` sentinel falls through cleanly to the basename fallback (no empty H1); (T4) curated H1 without a `**Project:**` line — H1 preserved, Project line regenerated from helper; (T5) curated `**Project:**` line without an H1 — Project line preserved, H1 regenerated from helper. All five pass; existing knowledge-system tests (`test-knowledge-crossref.sh`, `test-knowledge-add-index-scaffold.sh`) still pass — no regressions.
- **Migration note** — Existing project `INDEX.md` files that already contain the bugged H1 `Project Knowledge — project` (or `**Project:** project`) will be preserved verbatim by the new round-trip logic — the fix protects whatever is currently on disk, it does NOT retroactively repair previously-clobbered titles. To pick up the new sentinel-derived names, do ONE of: (a) manually edit the H1 and `**Project:**` line in the existing `INDEX.md` to the desired curated value (it will then be preserved on every subsequent reindex), or (b) drop a `.kb-project` sentinel file containing the desired name into the project knowledge dir and delete the existing `INDEX.md` so the next reindex regenerates from the sentinel. Option (a) is recommended for production project trees because it preserves the `Relevant Subjects` block. The dev-team project tree itself was repaired this way as part of this commit (Subitem 2: title set to `Project Knowledge — dev-team (Academy)`).

### Fix: XACA-0267 — kb-knowledge-validate frontmatter leak to stdout

- `kanban-helpers.sh` — `xref_frontmatter` was the lone loop variable still being `local`-declared inside the per-entry loop body of `kb-knowledge-validate` (line 9490 in the prior layout). Every other variable touched in that loop was already pre-declared at function top (lines 9339–9341) precisely to avoid zsh's re-declaration trace leak — where redeclaring an already-set local with a `local NAME` statement (no assignment on the same line) under certain typeset/trace options causes zsh to echo the variable's current value to stdout. The leaked content was the YAML frontmatter slice of every entry file the validator touched. Moved the declaration into the existing pre-declaration block (added `local xref_frontmatter` at the top alongside `xref_line`/`xref`/`resolved_xref`) and dropped the redundant `local` from inside the loop, leaving only the bare `xref_frontmatter=$(awk …)` assignment. The pre-declaration block already had a comment ("Pre-declare loop variables at function top to avoid zsh local-A trace leaks on re-declaration") explaining why this pattern exists — `xref_frontmatter` was simply missed when that block was added.
- `kanban-helpers.sh` — Consistency sweep in `_kb_knowledge_reindex_one`: the three `local agent_name=$(basename "$dir")` / `local team_name=…` / `local proj_name=…` declarations inside the `{ … }` block (lines 9705/9708/9711 in the prior layout) used the assignment-form `local NAME=value`, which does NOT actively trigger the echo leak (only the bare `local NAME` followed by a separate assignment does). Even so, they were the last in-loop `local`s in this function — every other variable used inside the `{ … }` block is already pre-declared at line 9697 with the same explanatory comment. Promoted these three to the existing pre-declaration block so the entire function follows one consistent pattern, removing the smell and immunizing the function against future option-flag drift (e.g. enabling `WARN_CREATE_GLOBAL` or `xtrace` for debugging).

### Chore: XACA-0269 — Knowledge schema conformance + Android team-persona relocation

- `~/knowledge/` (separate repo) — renamed 13 entries to SPEC §2 conventions (`kNNN-kebab` / `sNNN-kebab`), closed numbering gaps in agents/emh (k071-k089 → k058-k076) and agents/thok (k008-k010 → k007-k009), regenerated 11 INDEX.md files (5 modified + 6 created). Validation: 347 entries pass, 0 warnings, 0 errors. Commit: `7764cc4` on `main`.
- `android/personas/team-persona.md` — relocated TOS Enterprise Android communication-style guide from `~/knowledge/teams/android/persona.md` to its conceptual home alongside agent-level personas. The `teams/` tier in `~/knowledge` is RESERVED per SPEC §4.2 ("scaffolded empty until team-as-bundle ships"), and `persona.md` lacked entry-shaped frontmatter — it's a style guide, not a knowledge entry. Move resolves three validation FAILs and two WARNs.

### Chore: XACA-0268 — Untrack `kanban/knowledge/project/` from dev-team repo

- `kanban/knowledge/project/` (50 entries + INDEX.md) — `git rm --cached` to remove from repo tracking. The path is in `.gitignore` (`kanban/`), but these files predated that gitignore entry and remained tracked. Canonical location is now `~/dev-team/kanban/knowledge/project/` (team tree, gitignored, persistent across worktrees). Files remain on disk in worktrees; only the tracking is removed. Companion to XACA-0268 frontmatter backfill which already populated SPEC §3 fields in the team tree.

### Refactor: XACA-0284 — Optimize Academy memory files (CLAUDE.md + MEMORY.md size reduction)

- `claude/CLAUDE.md` — Compressed from 33 KB / 663 lines to 26 KB / 477 lines (~21 % reduction). Tightened the PR Auto-Spawn section by deduping the tester and reviewer prompt templates into a single shared scaffold (saved ~50 lines of near-duplicate boilerplate). Compressed the Worktree Agent Rules forbidden-actions list, Team Boundaries section (consolidated 4 separate scope tables + 1 directory table into one combined table), Container Selection section (verbose prose → dense table), Commit Guidelines (cut the worked example), Release Notes Workflow (template fenced blocks → prose summary preserving all required field names), Troubleshooting list, AMB Knowledge Wire, and Knowledge Base Protocol. Combined the Standard Development Workflow code block onto fewer lines without dropping any command. **No rules removed** — every behavioral rule, command snippet, bot login, file path, and load-bearing example is preserved; only prose, repeated warnings, and example boilerplate were tightened.
- `~/.claude/projects/-Users-darrenehlers-dev-team/memory/MEMORY.md` (out-of-band, not in git) — Reduced from 247 lines to 54 lines (78 % reduction). Moved 7 inline detail blocks into dedicated topic files: Finance Team Shell Infrastructure, Bot Name Reference, AMB Hook Architecture, Zsh BANG_HIST and jq Filters, Tmux Pane Targeting Pattern, Review/Test Subitem Governance, Double-Subshell Idiom. Removed dangling reference to `project_xaca0137_*.md` (file did not exist; entry was in the truncated zone past line 200). Re-introduced reference to `reference_openpersona.md` (orphaned). Tightened all index entries to one-liners under 150 chars. The 247-line file was over the documented 200-line limit, meaning ~47 lines of memory had been silently truncated from every dev-team session for an unknown duration; that's now fixed with comfortable buffer.
- 7 new memory topic files created in the same out-of-band sweep (filename prefix matches type: `feedback_`, `project_`, `reference_`).
- `feedback_subagent_forbidden_actions.md` topic file — tightened from 159 lines to ~50 lines by deferring the full prompt scaffold to its canonical home at `~/knowledge/templates/subagent_prompt_template.md` (referenced in the file). Kept the rule, the standard FORBIDDEN ACTIONS block, the why-it-works explanation, and the measured-impact note.
- `project_aiteamforge_empty_teams_bug.md` topic file — tightened from 76 lines to ~45 lines by removing the dated "Out of Scope" prose and consolidating the asymmetry explanation. Diagnostic recipe, fix description, and related-memory pointers preserved.
- `project_machine_hook_paths.md` — converted to a 4-line tombstone pointing to the superseding rule (`feedback_aiteamforge_never_on_m3pro.md`). Cannot be deleted from disk on this machine (`~/.claude/` is hook-protected); tombstone is the next-best signal that the entry is no longer load-bearing.
- `kanban/XACA-0284_memory_file_optimization.md` (plan doc) — created.
- `kanban/XACA-0284_cross_team_claude_md_findings.md` (cross-team audit findings doc) — created. Documents per-team CLAUDE.md size and reduction opportunities for iOS, Android, Firebase, DNS, and others; identifies Firebase's 44 KB CLAUDE.md as the largest in the fleet outside Academy. Combined potential fleet-wide savings: ~57 KB if all team-specific optimizations land. Per team boundaries Academy cannot modify other teams' files; follow-up kanban items XFIR-0117 (Firebase), XAND-0641 (Android), XIOS-0630 (iOS), XDNS-0010 (DNS) created in those teams' boards for their agents to execute.
- Review feedback (reed PR #312): Restored the worktree-kanban-guard section in CLAUDE.md (the rule and helper commands `kb-plan-doc-path`/`kb-retro-path`/`kb-knowledge-add project` belong in CLAUDE.md, not just MEMORY.md). Restored the explicit two-line `gh-bot-{review,test}` fallback paths (the brace-expansion compression I'd attempted produced a wrong cross-product). Restored the post-sleep `LAST_SHA` re-fetch in the Reviewer Monitoring Loop (the pre-sleep cache was a real behavioral regression — the re-fetch picks up commits that land during the 30 s stabilize window).

Net effect: every dev-team session now loads ~7 KB less CLAUDE.md and a fully-visible MEMORY.md (no truncation). Cross-team optimization handed off to platform teams via tracked kanban items.

### Fix: XACA-0285 (review feedback) — Address PR #315 bot findings

- `scripts/kb-sync-personas` — Removed unused `json_deployments` variable in `_kbsp_check` (SC2034)
- `scripts/migrate-personas.sh` — Replaced literal `~` with `$HOME` in `_info` log string (SC2088)
- `scripts/kb-sync-personas` — Renamed selftest Test 1 description from "dry-run sync shows COPY actions" to "source enumeration counts match expected file count" to accurately reflect what the test validates
- `scripts/kb-sync-personas` — Replaced `eval echo` in `_expand_path` with parameter expansion (`${p/#\~/$HOME}`) plus `envsubst` for env-var references; eliminates shell-injection surface while preserving identical behavior
- `homebrew-tap/docs/ARCHITECTURE.md` — Fixed `install-claude.sh` -> `install-claude-config.sh` typo in new "Per-Team Persona Architecture" Install Flow section (step 2)
- `sync-check.sh` — Rewrote legacy script (referenced by deploy-to-production.sh and docs) to route through `kb-sync-personas check --all` instead of comparing obsolete `~/.claude/agents/<Team>/` and `~/dev-team/<team>/personas/agents/` paths
- `scripts/kb-sync-personas` — Added O(n*m) cost-analysis comment to both orphan-detection loops (`_kbsp_check` and `_kbsp_sync`); notes current ceiling (~14 files × 2 groups = ~28 inner iterations) and when a refactor to O(n+m) would be warranted

### XACA-0285-007: Documentation update

- Added "Per-Team Persona Layout" section to `claude/CLAUDE.md` explaining master/manifest/deployment architecture and `kb-sync-personas` CLI usage
- Updated `homebrew-tap/docs/ARCHITECTURE.md` with "Per-Team Persona Architecture" section covering three-layer model, install flow, sync mechanism, token savings analysis, naming disambiguation, and multi-machine sync
- Updated `homebrew-tap/docs/USER_GUIDE.md` "Claude Code Agents" / "Agent Configuration" section to reflect per-repo `.claude/agents/` layout, editing workflow via master, and token optimization benefits
- Updated `homebrew-tap/docs/MULTI_MACHINE.md` with new "Persona Synchronization Across Machines" section covering sync strategy, conflict resolution, and token efficiency across fleet

### XACA-0285-004: install-claude-config.sh persona sync

- Removed user-level `~/.claude/agents/<team>/` install logic — `install_agent_personas()` and `install_team_claude_md()` converted to no-ops with explanatory log output; the per-team loop in `install_claude_config()` is removed
- Added `invoke_persona_sync()` function that calls `kb-sync-personas sync --all` to populate per-repo `.claude/agents/` for every team repo present on the machine; falls back to direct script path (`~/dev-team/scripts/kb-sync-personas`) if the command is not yet in PATH, and emits a manual-recovery warning if neither is available
- Installer now skips missing target repos gracefully (delegated to `kb-sync-personas` warn-and-skip behavior)
- Final install banner "Next steps" updated: `ls ~/.claude/agents/` replaced with `kb-sync-personas check --all`

### Feat: XACA-0285-003 — deploy-to-production.sh + post-merge integration

- `deploy-to-production.sh` — Removed legacy Section 3 that copied 47 individual persona files from per-team `~/dev-team/<team>/personas/agents/` source dirs into `~/.claude/agents/<Team Name>/` subdirectories. Replaced with `deploy_personas_master()` function that invokes `kb-sync-personas sync --all` when `.claude/agents-master/` or `.claude/personas-manifest.json` files are in the deploy scope, or when `--sync-personas` flag is passed. Added `--sync-personas` CLI flag to force sync regardless of scope. Also removed `mkdir -p ~/.claude/agents/<Team Name>` directory creation calls.
- `scripts/hooks/post-merge` — Replaced 8 per-team persona prefixes (`academy/personas/`, `android/personas/`, `command/personas/`, `dns-framework/personas/`, `firebase/personas/`, `freelance/personas/`, `ios/personas/`, `mainevent/personas/`) in `DEPLOYABLE_PREFIXES` with `.claude/agents-master/` and `.claude/personas-manifest.json`. Added post-deploy block that detects persona-master changes in the merge diff and calls `kb-sync-personas sync --all` to propagate master to all team repos.

### Feat: XACA-0285-005 — Foundational per-team agent scoping implementation

- `.claude/agents-master/` — Created canonical master directory containing all 68 persona files organized by team slug (`academy/`, `android/`, `command/`, `dns/`, `finance/`, `firebase/`, `freelance/`, `ios/`, `legal/`, `mainevent/`, `medical/`). Copied from `~/.claude/agents/<Themed Name>/` source dirs. Applied naming disambiguation: `mainevent_janeway_leadfeature_persona.md` frontmatter `name:` changed from `janeway` to `janeway-me`; `mainevent_paris_ux_persona.md` frontmatter `name:` changed from `paris` to `paris-me` — prevents collision when command and mainevent groups are deployed to the same repo.
- `.claude/personas-manifest.json` — Manifest driving all sync operations. 13 deployment entries: academy, ios, android, firebase, command, dns, freelance-{starwords,appplanning,workstats,lifeboard}, finance, legal, medical. Verbatim from design spec (XACA-0285_sync_design.md). Passes `jq` validation.
- `scripts/kb-sync-personas` — New executable bash CLI (~280 lines). Subcommands: `list`, `check`, `sync`, `diff`, `refresh`, `selftest`, `help`. Resolves DEV_TEAM relative to script location (portable — works in worktree or live `~/dev-team/scripts/`). Safety guards: refuses `/worktrees/` paths; skips missing targetRepo with WARN; `--require` flag upgrades to error. Writes `.synced-from-master` marker (timestamp + master commit SHA + schemaVersion). `selftest` runs 6 checks against a mktemp temp dir; all pass.
- `scripts/migrate-personas.sh` — One-time migration runner for subitem 008 (M3Pro execution). Steps: sanity check master populated → print plan → user Y/n confirmation → backup `~/.claude/agents/` to timestamped `~/dev-team-backups/agents-pre-XACA-0285-*/` → pre-migration drift check → sync --all → verify per-team file counts → remove `~/.claude/agents/<Team>/` subdirectories. `--help` flag prints plan and exits 0 without touching anything.
- `kanban-helpers.sh` — Added PATH guard block (XACA-0285 migration marker): adds `~/dev-team/scripts` to PATH when not already present, making `kb-sync-personas` callable from any sourced shell.

### Fix: XACA-0264 — kb-knowledge-validate silent false-negatives on broken resolver

- `kanban-helpers.sh` — Inside `kb-knowledge-validate` cross-reference loop (~line 9495), capture `_kb_knowledge_resolve_ref`'s exit code into a local `resolver_rc` immediately after the resolver call and emit `_kb_val_error "Broken cross-ref '<ref>' in <file> (resolver rejected — invalid format)"` whenever `resolver_rc != 0`. Previously the validator only checked `[[ -n "$resolved_xref" ]]`: when the resolver rejected a malformed ref via `echo "Error: ..." >&2; return 1` it produced empty stdout and the validator silently moved on, treating the broken ref as "no ref to check". Stderr was swallowed by `2>/dev/null` on the same line, so the rejection was invisible. Result: every malformed cross-reference (invalid persona name, unknown tier, missing path segment in `subjects:`, etc.) was reported as zero errors. Now they surface with their tier/ref in the message and increment the error count, so the validator's exit code reflects reality.
- `scripts/tests/test-knowledge-validate-resolver-rejection.sh` — New regression test. Builds an isolated mktemp knowledge tree containing a fixture entry with `related: subjects:k001` (captured by the xref grep, rejected by the resolver because `subjects` requires `<path>:<entry-id>`). Sources the worktree's `kanban-helpers.sh`, runs `kb-knowledge-validate`, and asserts: validator exits non-zero, RESULTS line shows `errors >= 1`, stderr contains `'subjects:k001'`, and stderr contains the literal phrase `resolver rejected`. All four assertions pass post-fix; assertion 3 (`subjects:k001` mention) and assertion 4 (`resolver rejected` mention) both fail against a reverted scratch copy of the helper, confirming sensitivity to the bug. Cleanup uses `trap … EXIT INT TERM` with `rm -rf "$FIXTURE_ROOT"` — never `find -delete` (XACA-0258 lesson).

### Fix: XACA-0266 — kb-knowledge-validate emits malformed paths for nested subjects

- `kanban-helpers.sh` — `_kb_val_walk_subjects()` (the recursive walker for the subjects tier inside `kb-knowledge-validate`) was passing the matched directory back into the next recursion without stripping its trailing slash. zsh's `*/` glob already appends a slash to each match, so on the second descent the glob expanded `"${base}/*/"` against a slash-suffixed `base` and produced double-slash paths like `subjects/ios//swift/`. The walk continued — the kernel collapses repeated slashes — but every downstream display, INDEX-path comparison, and dir-label string contained the `//` artifact, and any logic that compared paths by string equality would have silently mismatched.
- Fix: `local base="${1%/}"` at the top of the recursive helper strips a trailing slash on each call (no-op on the initial caller-supplied path, idempotent on every nested step). One-line surgical change; no behavior change for the single-level case.
- Verified by reproducing against `/tmp/xaca0266-repro/subjects/ios/{swift,uikit}/` — pre-fix output showed `Directory: …/ios//swift/`; post-fix output shows clean `Directory: …/ios/swift/`. Full real-tree run still completes (330 passed, no new errors).

### Fix: XACA-0278 (review feedback) — Hook edge case + tap template parity

- `claude-hooks/worktree-kanban-guard.sh` — Quoted `${WORKTREE_ROOT}` inside the SUBPATH pattern-removal expansion (SC2295). Added explicit guard for the bare-directory edge case (`FILE_PATH == <worktree>/kanban` with no subpath) so the canonical path in the block message is `<main>/kanban/` instead of doubled-up garbage.
- `homebrew-tap/share/templates/kanban/kanban-helpers.template.sh` — Added `kb-plan-doc-path` mirroring template's `kb-retro-path` pattern (uses `_kb_get_kanban_dir`, no worktree logic). The AITeamForge tap doesn't have the worktree-shadow bug — its kanban dirs live outside any git repo — so this is API-consistency only, not a port of the worktree fix.

### Fix: XACA-0265 — Tier labels off-by-one in bash-array indexing in `kb-knowledge-search` and `kb-knowledge-validate`

- `kanban-helpers.sh::kb-knowledge-search` — builds two parallel arrays (`search_roots` and `root_tier_labels`) in tier order (project → team → subject → agent), then iterates both with a single `root_idx` counter. The counter was hard-coded to `root_idx=1`, which works under default zsh (1-indexed arrays) but is off-by-one under `KSH_ARRAYS` (and any 0-indexed bash/ksh-style invocation): `${root_tier_labels[1]}` returns the *second* label, so project results were displayed as `[subject]`, subject results as `[agent]`, and the last tier silently fell off the end.
- `kanban-helpers.sh::kb-knowledge-validate` — same parallel-array off-by-one (`val_dirs` / `val_tiers`, hard-coded `dir_idx=1`). Under `KSH_ARRAYS`, `expected_tier` was reading the *next* tier label for every directory: agent dirs validated as if they were `team`, subject dirs as if they were `project`, etc. Manifested as `expected prefix '<wrong>' for tier '<wrong>'` warnings and bogus `Tier mismatch` failures on otherwise-valid frontmatter.
- Replaced both hard-coded bases with the same runtime probe — declares a one-element local array `_kb_probe=("first")` and reads `[1]`; if it returns `"first"`, the shell is 1-indexed (zsh default) and `_kb_idx_base=1`; otherwise 0-indexed and `_kb_idx_base=0`. The function-local index counter (`root_idx` / `dir_idx`) initializes from `_kb_idx_base`. Robust to both shells regardless of file shebang or sourcing context. The probe is duplicated inline at both call sites rather than factored out — only two consumers, and the local-scope inlining keeps the variables from leaking into the rest of the function namespace.
- Verified `kb-knowledge-search` by reproducing the original bug under `setopt KSH_ARRAYS` (project entries mislabeled as `[subject]`) and confirming labels are correct after the fix in both default-zsh and `KSH_ARRAYS` modes; verified `kb-knowledge-validate` produces correct `expected prefix '…' for tier '…'` pairings under both modes (sibling bug found during PR review by `reed`).

### Fix: XACA-0263 — kb-knowledge-add scaffolds INDEX.md for new directories

- `kanban-helpers.sh` — `kb-knowledge-add` previously created the tier directory (when missing) and wrote the entry file, but did not generate an `INDEX.md`. The new entry remained invisible to `kb-knowledge-search` and `kb-knowledge-validate` until a separate `kb-knowledge-reindex` run was triggered. Added a single call to `_kb_knowledge_reindex_one "$target_dir"` at the end of `kb-knowledge-add` (after entry creation), with stderr/stdout suppressed and `|| true` to ensure a reindex failure cannot retroactively block entry creation (the entry file is already on disk by that point).
- `tests/test-knowledge-add-index-scaffold.sh` — new regression suite. Exercises all four tiers (agent / subject / team / project) with brand-new directories and verifies `INDEX.md` is present after each `kb-knowledge-add` invocation. T5 also verifies that adding a second entry to an existing dir refreshes the index (both entry IDs listed). Sandboxed via `KB_KNOWLEDGE_GLOBAL_ROOT` override + `mktemp` trap-cleanup, same pattern as `test-knowledge-promote-tier.sh`. Verified the test fails 0/5 against the buggy code path before the fix and passes 5/5 with the fix in place.

### Feat: XACA-0278 subitem #4 — PreToolUse hook blocks worktree kanban writes

- `claude-hooks/worktree-kanban-guard.sh` — New PreToolUse hook (Write/Edit/MultiEdit/NotebookEdit). Detects feature-worktree context via `git rev-parse --git-common-dir`; blocks writes under `<worktree-root>/kanban/` with exit 2 and an actionable error showing the canonical main-repo path. Canonicalizes git-common-dir relative to LOOKUP_DIR (not cwd) to survive symlink/relative-path edge cases.
- `claude/settings.json` — Registered guard on Edit, Write, MultiEdit, NotebookEdit PreToolUse matchers; deploys to `~/.claude/claude-hooks/worktree-kanban-guard.sh`.
- `deploy-to-production.sh` — Added `deploy_file` call for `worktree-kanban-guard.sh` in the Claude Configuration section.

### Fix: XACA-0278 — Make `_kb_knowledge_project_path` worktree-aware

- `kanban-helpers.sh` — `_kb_knowledge_project_path` now uses `git rev-parse --git-common-dir` instead of `--show-toplevel` to derive `repo_root`. In a feature worktree, `--show-toplevel` returns the worktree path; `--git-common-dir` returns the absolute main `.git` path whose parent is the main repo. Main-worktree behavior is unchanged (common-dir `.git` is relative, falls back to `show-toplevel`). Fixes `kb-knowledge-add project`, `kb-knowledge-search`, and `kb-knowledge-validate` resolving to an ephemeral worktree-local path instead of the main repo's `kanban/knowledge/project/`.

### Feature: XACA-0278 — Add kb-plan-doc-path helper to kanban-helpers.sh

- `kanban-helpers.sh` — Added `kb-plan-doc-path <ITEM-ID>` function (lines 8331–8373). Prints the canonical absolute path to `<main-repo>/kanban/plans/<ITEM-ID>/` regardless of whether cwd is the main worktree or a feature worktree. Uses the `git rev-parse --git-common-dir | xargs dirname` pattern (with `show-toplevel` fallback for the main-worktree case) to resolve the main repo root. Includes argument validation (missing arg → usage, invalid format → error), matching the error-handling style of `kb-retro-path`.

### Refactor: XACA-0277 — Move tap-to-copy IDs from queue badges to Epic/Release lists

- `lcars-ui/js/lcars.js` — `createQueueItem` no longer appends a `[ID]` chip to either the Epic or Release queue badge. The badges go back to displaying the short title only; the ID is still surfaced in the badge tooltip. Removes `queue-epic-badge-id` and `queue-release-badge-id` from queue cards entirely.
- `lcars-ui/js/lcars.js` — `renderEpicCard` and `renderReleaseCard` now make `.epic-card-id` and `.release-card-id` clickable: `role="button"`, `tabindex="0"`, `onclick="… copyToClipboard(id)"` with `event.stopPropagation()` so the card-header expand toggle does not also fire. Keyboard handler covers Enter and Space.
- `lcars-ui/js/lcars.js` — `loadEpicItems` and `loadReleaseItems` apply the same affordance to per-item `.epic-item-id` / `.release-item-id` chips inside expanded Epic and Release cards. The release-item case explicitly stops propagation because the parent `.release-item` div has a click handler that navigates to the queue item — without `stopPropagation` the chip would copy AND navigate.
- `lcars-ui/js/lcars.js` — deleted the now-unused `createCopyableIdChip(id, className, labelPrefix)` helper added in XACA-0213. The four new sites use template-literal HTML (consistent with the rest of `renderEpicCard` / `renderReleaseCard`), so the DOM-builder helper had no remaining callers.
- `lcars-ui/css/lcars.css` — removed `.queue-epic-badge-id` and `.queue-release-badge-id` rule blocks (base, `:hover`, `:focus-visible`) and the mobile-breakpoint scaling rule that depended on them. Added cursor / hover / focus-visible affordance to `.epic-card-id`, `.release-card-id`, `.epic-item-id`, and `.release-item-id` so each chip looks tappable in its new home — colors picked from the surrounding LCARS palette per chip (amber for epic-card, gold for child item IDs, green-tinted for release-card).
- `homebrew-tap/share/lcars-ui/{js/lcars.js,css/lcars.css}` — synced via `sync-tap.sh` (drift check is clean).
- Defense-in-depth (review feedback): wrapped `epic.id`, `release.id`, and `item.itemId` in `escapeHtml()` for HTML-text interpolation (chip text, `aria-label`) and added a new `jsAttrEscape()` helper for JS-string-literal interpolation inside event-handler attributes (`onclick`, `onkeydown`). `escapeHtml()` does not cover backslash or single-quote, both of which would break a single-quoted JS string literal — `jsAttrEscape()` does. Current ID taxonomies (`X[A-Z]{2,4}-\d{4}`, `E{TEAM}-NNNN`, `REL-YYYY-QN-NNN`) are server-controlled alphanumeric and contain no such metacharacters, so this is a no-op for present data, but it closes the inline-handler-injection class entirely.

Net effect: queue cards are visually quieter (Epic/Release badges shrank back to just the short title) and the `[ID]` tap-to-copy behavior now lives where users actually look up Epic and Release IDs — the dashboards and their expanded child lists.

### Feature: XACA-0276 — Backup completeness verification and regression detection

- `kanban-backup.py` — Implemented completeness guarantees to prevent silent partial backups. Each backup run now: (1) walks the source directory exactly once via `snapshot_source_dir()` to create a stable `DirSnapshot`, (2) uses that snapshot for both hashing and zipping to eliminate the TOCTOU window that previously existed between two independent rglob calls, (3) immediately verifies every successful zip against the snapshot for file count and top-level directory manifest via `_verify_zip_integrity()`, and (4) quarantines failed zips under `~/dev-team-backups/_failed/` while preserving the previous-known-good hash for retry.
- `kanban-backup.py` — Added structured per-run audit logging to `backup.log` (JSON-per-line format): `run_start` (timestamp, scope), `team_backup_ok` (file_count, uncompressed_bytes, compressed_bytes, top_level_dirs, zip_filename), and `run_end` (totals). Enables trend analysis and post-incident forensics.
- `kanban-backup.py` — Integrity failure now: renames bad zip to `_failed/<team>_<name>.FAILED` (forensics preserved), does NOT advance `stored_hashes[team]` (next run retries against previous-known-good), populates `status["boards"][team]["lastIntegrityFailure"]` with detail, and emits `[INTEGRITY-FAIL]` to stderr for LCARS pickup.
- `kanban-backup-health.py` — Added cross-run regression detection via `check_cross_run_regressions()`: compares latest 2–3 zips per team; subdirectory disappearance = always ERROR; file-count drop > 10% OR > 50 files = WARNING, > 25% = ERROR. Reported via `regression_alerts` field in health JSON. Catches source-directory content loss (the origin incident for XACA-0276).
- `kanban-backup.py` module docstring — Added "Completeness Invariants" section documenting the six guarantees that the system enforces (single snapshot, co-derived hash and zip, no silent partials, loud failures with quarantine, cross-run regressions surfaced, structured audit trail) and where each is enforced (function/line references).

### Chore: XACA-0258 — Project knowledge INDEX entry for p053

- `kanban/knowledge/project/INDEX.md` — added entry for `p053-kb-knowledge-hot-module-rebase-tax.md` (project-tier knowledge captured during XACA-0258 retrospective: the kb-knowledge-* family is a hot zone, expect rebases when shipping in parallel) and a Retrospectives row pointing at `XACA-0258_kb_knowledge_add_agent_field_RETROSPECTIVE.md`. The knowledge entry file itself and the retrospective doc are gitignored per kanban convention.

### Fix: XACA-0259 — kb-knowledge-search scope flags actually scope

- `kanban-helpers.sh` — `kb-knowledge-search --agent <name>`, `--subject <path>`, and `--project [<slug>]` were not actually narrowing the search to one tier. The scope flags only narrowed *their own tier root* (e.g. `--agent reno` narrowed the agent root from `agents/` to `agents/reno/`), but the project, team, and subject tier blocks all still ran because they gated only on `filter_tier`. End result: `--agent reno` returned all four tiers' worth of results with the agent tier slightly more focused.
- Added a tier-inference block immediately after argument parsing: when `filter_tier=""` and exactly one scope flag is set, infer `filter_tier` from that flag (`--agent`→`agent`, `--subject`→`subject`, `--project`→`project`). The four downstream per-tier blocks already gate on `filter_tier`, so inferring it is enough to scope correctly. Explicit `--tier <name>` always wins because the inference block only runs when `filter_tier=""`.
- Added an `any_scope_flag_set` boolean computed once and used to gate the unfiltered "else" branches in all four per-tier blocks. Without this, the multi-flag composition case (e.g. `--agent X --subject Y` — both filters set, so inference deliberately leaves `filter_tier=""` so each tier composes by its own filter) was leaking the project tier (49 entries on this dev box) and the team tier into results because their else-branches added their tier root unconditionally when `filter_tier=""`. The team block has an extra `|| [[ "$filter_tier" == "team" ]]` clause inside the gate so explicit `--tier team` still iterates `teams/*` (the team tier has no per-tier filter — `--team` is an alias for `--agent`).
- Extended the help-trigger guard at the top of the function to also check `filter_agent` and `filter_subject` empty so multi-flag queries (which pass through inference with `filter_tier=""` and no `search_term`) don't fall through to the usage screen.
- Hardened the `for tdir in "${team_root}"/*/;` loop with the zsh `(.DN/)` glob qualifier (D=dotglob, N=nullglob, `/`=directory-only) so an empty `teams/` directory produces an empty array instead of a fatal `no matches found` zsh error. Belt-and-suspenders alongside XACA-0255's function-scoped `setopt NO_NOMATCH`; an inline comment at the call site documents this so future readers don't remove the qualifier as redundant.
- Style: switched `[[ "$_scope_flags_set" == "1" ]]` to integer comparison `[[ "$_scope_flags_set" -eq 1 ]]` to match the surrounding numeric-comparison idiom used elsewhere in the file.
- Help text inside `kb-knowledge-search` and `~/knowledge/docs/USAGE.md` now document the implicit-tier behavior with explicit examples for single-flag, multi-flag, and explicit-`--tier` scenarios.

### Fix: XACA-0256 — Multi-level subject cross-refs broken by double-slash substitution

- XACA-0256: Multi-level subject cross-refs (e.g. `subjects:ios:swift:s001`) produced double-slashed paths due to a zsh parameter-expansion parsing quirk. Replaced `${var//:///}` with `tr ':' '/'` at both knowledge-ref and knowledge-promote resolution sites (`_kb_knowledge_resolve_ref` line ~9152 and `_kb_knowledge_promote` target-path resolver line ~8971–8973 of `kanban-helpers.sh`). Added regression test `tests/test-knowledge-crossref.sh` asserting no `//` appears in resolved paths.
- Also added `_kb_validate_subject_path` to `kb-knowledge-promote` subjects target — closes pre-existing path-traversal asymmetry surfaced during code review.

### Fix: XACA-0262 — kb-knowledge-promote writes singular tier per SPEC

- `kanban-helpers.sh` — `kb-knowledge-promote` was writing the **plural directory form** (`subjects`, `agents`, `teams`) to the promoted target file's `tier:` frontmatter field. The knowledge SPEC §3 enum requires the **singular** value (`agent | team | subject | project`), so every entry promoted between tiers shipped with a malformed tier value that violates the schema and would fail validation.
- The function parses target refs in directory-style cross-reference syntax (`subjects:ios/swift:s003-...`), which is correct for path resolution and for `promoted_from`/`promoted_to` cross-refs (those are also plural per §6). The bug was using that same plural token verbatim when emitting the frontmatter `tier:` field.
- Fix: `tier: ${target_tier%s}` strips a single trailing `s`, normalizing `subjects→subject`, `agents→agent`, `teams→team`, and leaving `project→project` unchanged.
- `tests/test-knowledge-promote-tier.sh` — new regression suite (4 cases: agent→subject, agent→team, subject→agent, agent→project) that asserts the promoted file's `tier:` line matches the singular SPEC enum. Verified the test fails on the pre-fix code and passes on the post-fix code.
- Existing promoted entries on disk that carry plural tier values will need a one-pass rewrite — out of scope here (tracked separately if needed).
- Layered on top of the XACA-0261 refactor (PR #296) that captured `source_tier`/`source_date`/`source_tags`/`source_source` into locals; this fix uses those same locals in the target-write block.

### Fix: XACA-0255 — zsh NOMATCH crash in kb-knowledge-* tools on empty dirs

- `kanban-helpers.sh` — `kb-knowledge-search`, `kb-knowledge-add`, `kb-knowledge-promote`, `kb-knowledge-validate`, and `kb-knowledge-reindex` all expand globs over `~/knowledge/{agents,subjects,projects}/<target>/`. Under zsh's default `NOMATCH` option a glob that matches nothing aborts the function with `no matches found`, so a freshly-created agent directory (or any not-yet-populated tier) crashed every one of those tools instead of reporting "no entries". Added `setopt LOCAL_OPTIONS NO_NOMATCH` at function entry to all five — `LOCAL_OPTIONS` confines the change to the function scope so option state auto-restores on return without leaking into the caller's interactive shell.
- Verified by exercising `kb-knowledge-search`, `kb-knowledge-validate`, and `kb-knowledge-reindex` against a temp `KB_KNOWLEDGE_GLOBAL_ROOT` containing empty `agents/<name>/` and `subjects/<name>/` directories: each tool now exits 0 and reports "No knowledge entries found" / "[skip] No entries" / regenerates an empty INDEX cleanly.
- Overlaps with XACA-0261 (`kb-knowledge-promote` glob → `find` replacement): the two fixes are complementary. XACA-0261 hard-fixes one specific glob; XACA-0255's function-scoped `setopt` covers every other glob in `kb-knowledge-promote` and the four sibling functions, so future glob additions don't reintroduce the same trap.
- Defensive: `_kb_knowledge_reindex_one` (the per-directory worker called by `kb-knowledge-reindex`) also gets its own `setopt LOCAL_OPTIONS NO_NOMATCH`. The helper currently inherits the option from `kb-knowledge-reindex`, but self-containment keeps it safe if a new caller is wired in later (review follow-up, PR #298).

### Fix: XACA-0261 — kb-knowledge-promote stub tier/date fields blank

- `kanban-helpers.sh` — `kb-knowledge-promote` was writing the source-side stub with empty `tier:` and `date:` frontmatter. The stub-write block used `{ ... } > "$source_file"` with `_kb_knowledge_yaml_field "$source_file" "tier"` and `"date"` called *inside* the block. Bash truncates the redirection target before executing the inner commands, so by the time `_kb_knowledge_yaml_field` ran, `$source_file` had already been emptied — every read returned blank.
- Captured `source_tier`, `source_date`, `source_tags`, and `source_source` into locals at the top of the execute block (immediately after `mkdir -p "$target_dir"`), then referenced those locals in both the target-write block and the stub-write block. The target-write block was technically unaffected today (it writes to `$target_file`, not `$source_file`) but reusing the locals removes the foot-gun and makes the four frontmatter reads happen exactly once.
- Verified by running a scratch promotion (`agents:emh:k042` → `subjects:ios/swift:s003-...`) against a tmpdir: source stub now contains populated `tier: agents` and `date: 2026-04-29`; target file frontmatter unchanged.
- Also fixed a related foot-gun in the auto-id branch (no explicit target entry id passed): the literal glob `for ef in "${target_dir}/${target_prefix}"[0-9][0-9][0-9]-*.md` aborted under zsh with `no matches found` whenever `target_dir` was empty or didn't yet exist (the common case for a first promotion into a new subjects path). Replaced with a `[[ -d "$target_dir" ]]` guard plus `find -maxdepth 1 -type f -name '...'` piped into a `while read` loop — works the same under bash and zsh, no shell-option leakage. Verified end-to-end: first promotion into a fresh `subjects/ios/swift/` correctly writes `s001-…`, second promotion into the same dir correctly writes `s002-…`.

### Fix: XACA-0260 — kb-knowledge-promote tier-ordering guard (SPEC §7)

- `kanban-helpers.sh::kb-knowledge-promote` — added a tier-ordering guard that refuses downward and same-tier moves. Previously the function had no rank check, so a call like `project:p001 → agents:emh` would write the agent file and stub the project entry, silently inverting the SPEC §7 invariant ("entries flow upward through tiers as their applicability broadens"). Now refuses with a clear multi-line error showing source rank, target rank, the canonical ordering, and remediation guidance (manual copy + obsolete the source, per SPEC §7 prose).
- Added `_kb_knowledge_tier_rank` helper: `agents=1`, `project=2`, `teams=3`, `subjects=4`. Rank ordering matches SPEC §1 scope ("one persona" → "one codebase" → "one team's workflows" → "universal/cross-cutting"). Unknown tiers in either source or target ref now produce an explicit error before any filesystem mutation.
- Same-tier moves are also refused — they aren't promotions and should be done by direct file rename, not by `kb-knowledge-promote`.
- Verified by 14 fixture-based cases under zsh (10 refuse + 4 upward pass-through): all downward/same-tier/bogus-tier inputs refuse with `Error:` + non-zero rc; legitimate upward paths (`agents → subjects`, `agents → project`, `agents → teams`, `project → subjects`) still pass through to the existing dry-run/execute logic unchanged.
- Reviewer follow-ups addressed in same PR: guard moved above source-file resolution (cheap early-exit on bogus tier pairs without touching the filesystem); dead-code default branch removed from the post-guard `case` statement.

### Fix: XACA-0258 — kb-knowledge-add missing required tier-specific frontmatter field

- `kanban-helpers.sh` — `kb-knowledge-add` was writing frontmatter with only `id`, `tier`, `date`, `tags` for every tier. Per `~/knowledge/SPEC.md` §3, `tier: agent` REQUIRES an `agent: <persona>` field and `tier: team` REQUIRES a `team: <team-name>` field. Validator passed because it only enforced the universal four; downstream consumers that filter by persona/team were getting empty sets for any entry created via the helper.
- Added a per-tier `tier_field` local that captures `agent: ${persona}` (agent tier) or `team: ${team_name}` (team tier), then composed the frontmatter via `printf` so the conditional injection is single-sourced across both heredoc paths (template-present and template-absent).
- Subject and project tiers are unaffected — they do not have a required tier-specific field per SPEC.
- Verified by sandbox run of `kb-knowledge-add` against all four tiers under a temp `KB_KNOWLEDGE_GLOBAL_ROOT`; `kb-knowledge-validate` reports `[OK]` for the agent and team test entries.

### Fix: XACA-0257 — kb-knowledge-promote refuses to re-promote stubs

- `kanban-helpers.sh` — `kb-knowledge-promote()` now reads the source file's `status:` field after resolving it and refuses to proceed when the value is `promoted`. Previously, calling promote on an already-promoted stub copied the stub's body to a fresh target file and overwrote the original `promoted_to` pointer, silently destroying the link to the real target.
- Guard fires before the dry-run plan output, so re-promote is rejected even without `--confirm` (no misleading "PROMOTION PLAN" message that suggests the operation is valid).
- Error message names the existing `promoted_to` target and tells the user to either edit the target directly or delete the stub manually if they want to start over. No automatic stub-deletion — that's a destructive operation that belongs in a separate command, not buried in a guard fallback.
- Smoke-tested in a sandboxed `_kb_knowledge_global_root` override: re-promoting a stub is rejected with the correct error and exit 1; the stub frontmatter is unchanged after the rejected call.
- Completes the kb-knowledge-promote hardening series alongside XACA-0255 (NOMATCH), XACA-0261 (stub tier/date), XACA-0260 (tier ordering), and XACA-0262 (singular tier per SPEC). All five guards live in the same function, all are independently scoped.

### Fix: XACA-0254 — install-team.sh org-config prompt buffering (tap v0.11.2)

- `homebrew-tap/libexec/installers/install-team.sh` — `_ensure_org_config()` was invisible during fresh installs because `aiteamforge-setup` pipes installer stdout through `sed 's/^/  /'` for indentation. That switches stdout to block-buffered (4KB) since it's no longer a tty, and the four `printf "...: "` prompts (no trailing newline) sat in the buffer until something flushed it. Users saw an apparent hang, pressed Enter to wake it, and the immediately-following `read -r` consumed the empty Enter — silently accepting all defaults and writing `example-org` placeholders to `~/.aiteamforge/organization.yaml`.
- Switched the four prompt+read pairs to `printf "..." > /dev/tty` and `read -r ... < /dev/tty`. `/dev/tty` always points at the controlling terminal regardless of what the parent did with stdout/stdin, so the prompt is never buffered and the read can't be tricked by pipe contents.
- Added an availability guard immediately after the existing `AITEAMFORGE_ORG_CONFIG` env-override short-circuit. The guard tests `/dev/tty` openability via `(exec 9<>/dev/tty) 2>/dev/null` rather than `[[ -r /dev/tty ]]` — the latter only checks permission bits (world-rw on macOS) and gives false positives in CI/daemon contexts where the device exists but has no controlling terminal. When the guard fires the function returns 1 with a clear three-option remediation message (run interactively, pre-populate the yaml, or set `AITEAMFORGE_ORG_CONFIG`).
- The existing `AITEAMFORGE_ORG_CONFIG` env override path is preserved verbatim and continues to short-circuit before the tty guard fires, so non-interactive/CI installs that pre-set the env var keep working.
- `homebrew-tap/Formula/aiteamforge.rb` — bumped to `v0.11.2` (patch release shipping the prompt-buffering fix to fresh installs via the tap).
- Affects every fresh aiteamforge install until shipped via tap release.

### Feature: XACA-0253 — Manual weekly-limit anchor for cc-usage widget

- **Manual weekly-limit anchor for cc-usage widget** (XACA-0253) — Replaced misleading ISO-calendar-week reset countdown with a per-machine manual anchor. Users can now enter the actual reset countdown read from claude.ai via a pencil-icon editor on the WEEKLY LIMIT card. Anchor is shared across all LCARS instances on the machine via `~/.lcars/weekly-anchor.json`. Card switches to amber "RE-SEED FROM CLAUDE.AI" state when the anchor expires. ISO-calendar fallback preserved for users who haven't set an anchor.

### Chore: homebrew-tap v0.11.1 release + pytest cache leak fix

- `sync-tap.sh` — added `*/.pytest_cache/*` to the `find` exclusion list in `sync_dir()`. Previously `.pytest_cache/` from `lcars-ui/` was being copied into the tap as part of the LCARS UI sync, leaking ephemeral test runner state into the published Homebrew formula.
- `homebrew-tap/.gitignore` — added `.pytest_cache/` so any future leak doesn't quietly slip back into a tag.
- `homebrew-tap/VERSION` and `homebrew-tap/Formula/aiteamforge.rb` — bumped to `0.11.1` (patch release rolling up debrand cleanup, org-config plumbing, plugin scaffolding, and lcars-ui sync). Tag `v0.11.1` pushed to `DoubleNode/homebrew-aiteamforge`.
- `homebrew-tap/share/lcars-ui/lcars-target.js` — synced from dev-team source via `sync-tap.sh` (closes the only remaining drift).

### Fix: stale lcars-ui tests (XACA-0247)

- `lcars-ui/tests/test_rag_engines.py` — `TestRAGEngineStatus::test_to_dict_keys_present` was asserting an 8-key set (`engineId, status, health, message, lastCheck, version, port, pid`) but `RAGEngineStatus.to_dict()` now returns 10 keys after the update-check feature added `latestVersion` and `updateAvailable`. Test was stale, not the implementation. Added the two missing keys to the expected set.
- `lcars-ui/tests/test_server.py` — `TestServeEpicsListCompletedCount::test_counts_done_and_completed` expected `itemCount == 5` for an epic with 5 items including 1 cancelled, but server.py deliberately excludes cancelled items from `itemCount` (XACA-0206 decision; `cancelledCount` is surfaced separately so the UI can explain the denominator shift). Updated the assertion to `4` with an explanatory comment.
- Discovered while propagating sync-tap drift to homebrew-tap mirror — both stale tests existed identically in dev-team source and tap mirror. Fixing dev-team source prevents next sync from re-introducing them.

### Add: LCARS team-binding smoke test (XACA-0249-005)

- `lcars-ui/lcars-smoke-test.sh` — smoke test that verifies each running LCARS server is bound to its expected team; detects silent LCARS_TEAM env-missing fallback; uses `/api/team` when available (XACA-0249-003) and falls back to `/api/status`; supports `--port <N>` and `--verbose`; exits non-zero on failure; suitable for cron or CI.
- `claude_code_cc_aliases.sh` — adds `kb-lcars-smoke` alias for discoverability.
- `lcars-health-check.sh` — corrected swapped port assignments: 8427=finance-personal, 8230=legal-coparenting (smoke test exposed this pre-existing bug).

### Fix: subitem ID collisions when subitems have been renamed (XACA-0248)

- `kanban-helpers.sh` — `kb-backlog sub add` and the `kb-run-debug` reopen helper used `length+1` to assign new subitem IDs. That collides whenever existing subitems have been renumbered (e.g., impl renamed to `-012..-016` to make room for new mandatory trailing subitems): `length=11` produces `-012`, but `-012` already exists. Replaced both call sites with `max(numeric suffix) + 1` jq scans so new IDs always pick up after the highest existing index regardless of array order.
- `kanban-helpers.sh` — Added `kb-backlog sub renumber-collision <old-id> <array-idx> <new-id>` subcommand. The existing `rename-id` matches by ID alone and rewrites every occurrence, which is wrong when repairing duplicates. The new variant targets a specific array index so the second (or Nth) occurrence can be renumbered without disturbing the first. Same validation surface as `rename-id`: format check, cross-parent rejection (rc 3), parent-existence check (rc 4), array-index range + match check (rc 5), collision check (rc 6). Rewrites `parent.workingOnId` only when the renamed subitem's status is `in_progress` (otherwise the rewrite would be ambiguous against duplicate IDs).
- Repaired 7 existing duplicate-subitem-ID errors flagged by `kb-audit`: academy `XACA-0086-007` (1 occurrence renamed to `-009`), firebase `XFIR-0052-007` (1 → `-010`), ios `XIOS-0585-012..016` (5 trailing-mandatory occurrences renamed to `-017..-021`). Post-repair `kb-audit` reports zero findings across all 17 boards.
- `tests/test-subitem-numbering.sh` — New regression test (16 tests) covering empty-parent first-id, the renumbered-subitems max+1 scenario that was hitting collisions, the full `renumber-collision` validation surface, `parent.workingOnId` and `activeWindows[].workingOnId` rewrite-only-for-in-progress semantics, and the max-scan pre-filter ignoring non-conforming subitem IDs.
- Code-review follow-ups (PR #291): the max-scan jq filter now wraps `capture()` with an explicit `select(.id | test("-[0-9]+$"))` pre-filter so the "skip subitems with non-conforming IDs" behaviour is intentional rather than relying on `capture()` returning null. The `renumber-collision` jq update also rewrites `activeWindows[].workingOnId` (in addition to `parent.workingOnId`) when the renamed subitem is in_progress, mirroring how the field is actually consumed by LCARS / kb-stop-working.

### Feature: XACA-0250 — CC-USAGE Weekly Limit Display

- **XACA-0250-003 — Weekly heuristics + API exposure**: `lcars-ui/ccusage_heuristics.py` adds `evaluate_weekly(cache, now_utc)` returning `{available, used_pct, band, time_to_reset, seconds_remaining, tokens_used, tokens_cap, calibrated, confidence, stale}`. Calibrates weekly cap empirically from `max(history.totalTokens)` (Anthropic does not publish a weekly token cap). Confidence threshold is HIGH at ≥4 weeks of history, LOW otherwise — chosen because realistic installs accumulate 4 weeks within a month, and the session path's stricter thresholds would suppress band classification indefinitely. Stale threshold is 600s (vs. 300s on session path) — weekly data changes weekly, not minute-to-minute. `band` collapses to `UNKNOWN` whenever confidence is LOW. `_format_time_to_reset` renders human-friendly "11h 18m" / "3d 4h" strings; `_parse_week_anchor` parses ISO date as UTC midnight + 7 days. `lcars-ui/server.py` `_build_usage_response()` adds one additive line `result["weekly"] = ...` — zero impact on existing 5h consumers. Tests in `lcars-ui/tests/test_ccusage_weekly_heuristics.py` (56 tests covering empty/single/multi-week history, band thresholds, time-to-reset edge cases, missing weekly key, stale cache).
- **XACA-0250-005 — Dashboard widget weekly section**: `lcars-ui/index.html` adds `<section class="usage-section usage-weekly">` between PROJECTION and 7-WINDOW HISTORY in the CC-USAGE widget. New `applyWeekly(weekly)` function inside the existing IIFE handles all states: hidden when `null`/`available:false`/`confidence:LOW`, visible-with-`--` when `band:UNKNOWN`, dimmed-with-asterisk when `stale:true`. Progress bar (`uw-weekly-fill`/`uw-weekly-bar`), percentage (`uw-weekly-pct`), band label (`uw-weekly-band`), tokens-used/cap detail (`uw-weekly-detail`), and reset row (`uw-weekly-reset`). `lcars-ui/css/usage-indicator.css` scopes a new `--weekly-color` CSS custom property to `.usage-weekly` (the section element, NOT the parent widget) — load-bearing because the parent widget's `--usage-color` tracks the 5h band; if the weekly section reused that variable, its bar would track the wrong band. All five band values (green/amber/red/unknown/none) mapped on `.usage-weekly[data-band="*"]`.
- **XACA-0250-006 — Cross-cutting graceful degradation**: Audited end-to-end failure paths and reconciled UI inconsistencies. `lcars-ui/server.py` `_unavailable_weekly(reason)` helper now emits a `weekly: {available: False, reason}` sentinel in **every** API response — including the three error paths (heuristics unavailable, cache file missing, JSON parse failure) that previously returned responses without the `weekly` key. Reconciled `band:UNKNOWN` handling: agent-panel had a redundant guard (`UNKNOWN` and `LOW confidence` are co-incident in `evaluate_weekly`), removed for consistency with the dashboard's single-LOW-guard approach. Both UIs now compute a `weeklyHiddenReason` string (e.g., "Weekly data unavailable: collector not running", "low confidence — need 4+ weeks of history") and set it as a `title` attribute on the visible parent so users can hover to discover why the row is absent. Compact stale-hatch CSS rule corrected to use `--usage-weekly-color` for the weekly bar (was incorrectly inheriting `--usage-color` from the 5h band). 24 new tests in `lcars-ui/tests/test_weekly_degradation.py` cover all `evaluate_weekly()` unavailability paths, stale detection at threshold boundaries, `ccusage_ok=False` independence, and API endpoint sentinel emission across all three error paths.
- **Collector cycle time (operational note)**: The collector now runs 3 sequential subprocess calls per cycle — blocks scan, calibration (30-day look-back), and weekly aggregation — each with a 240s timeout. Under extreme JSONL load, worst-case cycle time is up to ~12 min (3 × 240s) plus 180s sleep, approximately 15 min end-to-end. On healthy systems the typical cycle remains ~4 min. Polls are strictly sequential and never stack; a slow cycle delays the next poll rather than spawning concurrent scans.

### Feature: XACA-0250-004 — Weekly limit row in CC-USAGE agent-panel pill

- `lcars-ui/agent-panel.html`: Expanded the compact CC-USAGE pill from a single 5h row to a two-row layout. Added Row 2 (`#ui-weekly-row`, `[WK LIMIT]`) with its own label, progress bar, and stats. Row is hidden by default and shown only when `weekly.available !== false`, `weekly.confidence !== 'LOW'`, and `weekly.band !== 'UNKNOWN'`. Stats format: `PCT · time_to_reset` (e.g. `18% · 11h 18m`) with a `(stale)` suffix when `weekly.stale === true`. When `data-ok="false"` (collector offline), weekly row is hidden. Added `dominantBand()` helper that picks the more severe of the 5h and weekly bands to drive the pill container's `data-band` attribute — ensures the most-binding constraint colours the pill. Weekly band is also written to `data-band-weekly` on the container and `data-band-weekly` on the weekly row element for independent per-row coloring.
- `lcars-ui/css/usage-indicator.css`: Changed `.usage-indicator.compact` from `display:grid` to `display:flex; flex-direction:column` so each `.usage-row` is a separate horizontal strip. Added `.usage-indicator.compact .usage-row` grid rule (`auto 1fr auto`, same column structure as the original single-row layout). Added per-row `--usage-weekly-color` CSS variable driven by `[data-band-weekly="*"]` attribute selectors on `.usage-row-weekly`, plus `.usage-label-weekly`, `.usage-bar-fill-weekly`, and `.usage-stats-weekly` style rules. Weekly bar fill has its own `transition` declaration so it does not depend on `.usage-bar-fill` specificity. 5h row stale treatment (`data-stale="true"` hatch pattern) only targets `.usage-bar-fill`, not `.usage-bar-fill-weekly`, so the two bars are independently styled.
### Fix: session-reaper deleting agent files for multi-segment team sessions

- `scripts/session-reaper.sh` — `_maybe_remove_file` extracted the session code as the first two dash-delimited components of the filename (`<team>-<role>`), which collapsed multi-segment team names to a non-existent session: `lcars-agent-finance-personal-bar.json` parsed as session `finance-personal` (the live session is `finance-personal-bar`), so the reaper deleted live agent JSON files every cycle. Same bug clobbered `freelance-doublenode-caravan-*` and `legal-coparenting-*` files, plus all `lcars-amb-fpcheck-*` files (extracted as bogus `lcars-amb`).
- Replaced the strip-prefix + two-component split with longest-prefix substring matching against `LIVE_SESSIONS`. If any live tmux session name appears anywhere in the basename, the file is kept. Handles arbitrary-depth team names (`finance-personal-*`, `freelance-doublenode-caravan-*`, `legal-coparenting-*`) and any future LCARS file prefix without maintaining a strip list.
- Reproduced on Finance: panels showed "Awaiting agent…" for all 5 terminals because reaper deleted JSON within 30 minutes of banner write. Manual rerun of `display_agent_avatar` restored panels; the reaper fix prevents recurrence. Dry-run after fix flags 0 files (was 54).

### Fix: USAGE section visibility + button placement (XACA-0243 follow-up)

- `lcars-ui/css/lcars.css` — Added `.usage-section` to the `.lcars-content > *` hide-by-default and active-show rule sets, plus the `.section-bar`/`.section-title` reveal animation lists. Without these, the USAGE section was never given `position:absolute; display:none` treatment and rendered in normal flow underneath whatever section was active. Added `.legend-pill.usage-pill` styling (cyan, hover/active states) plus the 120px width rule alongside `.viewscreen-pill`/`.sound-pill`.
- `lcars-ui/js/lcars.js` — Added `'usage'` to the `SECTIONS` array so `switchSection('usage')` no longer returns at the `indexOf === -1` guard. Added a third `forEach` over `.legend-pill[data-section]` so mode-bar utility pills (now including USAGE) get `.active` toggled in lockstep with sidebar/tabbar buttons.
- `lcars-ui/index.html` — Removed the USAGE entry from the kanban-mode sidebar; added a `<div class="legend-pill usage-pill" data-section="usage">USAGE</div>` to the mode-bar `utility-cluster` next to VIEWSCREEN/SOUND. Widened the USAGE section's `data-mode` to `team kanban data settings` so the always-visible utility pill works in any mode.
- Mobile tabbar USAGE entry retained (utility cluster collapses on narrow screens).

### Docs: Highlight kanban Epic / Release / Subitem container selection

Repeated pattern of agents creating regular backlog items titled `EPIC: ...`, `RELEASE: ...`, or `TODO: ...` instead of using the dedicated containers (`kb-epic`, `/release`, `kb-backlog sub add`). Added prominent decision-tree guidance in three reinforcing locations:

- `claude/CLAUDE.md` — new "🛑 STOP — Choose the Right Container BEFORE Calling `kb-backlog add`" block in Kanban Boundaries section. Decision table maps work-shape → correct command, with "attach-to-existing first" guidance and a renaming heuristic flagging forbidden title patterns.
- `skills/Project Planner/SKILL.md` — new "Phase 0: Container Selection (MANDATORY — DO THIS FIRST)" inserted ahead of Phase 1 Requirements Analysis. Four-row decision tree, explicit list of forbidden `kb-backlog add` invocations, `kb-epic list` / `kb-release list` pre-check guidance, and a rationale paragraph explaining why first-class containers (LCARS tabs, progress aggregation, environment promotion) cannot be approximated by string-prefixed backlog items.
- `skills/Kanban Manager/SKILL.md` — new "🛑 BEFORE `kb-backlog add` — Choose the Right Container" block immediately preceding "Adding Backlog Items," so the gate fires at the point of API call. Mirrors the global rule with concrete wrong/right examples and a forbidden-title-pattern checklist.

### Fix: Epic progress excludes cancelled items from denominator

- `lcars-ui/server.py` — `serve_epics_list` now excludes cancelled items from `itemCount`/`completedCount` and surfaces a new `cancelledCount` field, mirroring the release-progress math established by XACA-0206. Calendar epic endpoint (`_get_calendar_items`) applies the same exclusion and now also returns `completedCount`/`cancelledCount`.
- `lcars-ui/js/lcars.js` — `renderEpicCard` reads `cancelledCount`, appends a `(N cancelled, excluded)` suffix to the progress line (matches release-card behavior), and treats empty/fully-cancelled epics as 100% complete. `_renderHomeEpicProgress` (home-screen progress bars) applies the same exclusion: cancelled item-IDs drop out of both numerator and denominator, the row label gains a red `(N cx)` tag when any are excluded, and a fully-cancelled epic now reads 100% instead of 0%.
- `lcars-ui/css/lcars.css` — `.epic-item-cancelled-count` reuses the existing `.release-item-cancelled-count` styling.
- Reproduced on legal-coparenting EPIC-0001: 13 linked items (12 cancelled, 1 completed) previously displayed `1/13 complete — 8%` on both the epic card and the home progress bar. Now displays `1/1 complete (12 cancelled, excluded) — 100%` and `1/1 (12 cx) • 100%` respectively.

### Feature: XACA-0243-006 — Stale-data handling for Claude Usage Monitor

- `lcars-ui/ccusage_heuristics.py`: Bumped `STALE_THRESHOLD_SECONDS` from 120s to 300s (5 minutes = 2x worst-case collector cycle) to eliminate near-constant stale badges during normal operation. Updated module docstring with full rationale.
- `lcars-ui/tests/test_ccusage_heuristics.py`: Updated `EvaluateStaleTests` boundary tests from 119/120/121s to 299/300/301s to match new threshold. Added four boundary-specific test cases (`test_cache_at_299s_is_fresh`, `test_cache_at_300s_is_fresh`, `test_cache_at_301s_is_stale`, `test_cache_older_than_threshold_is_stale`). All 28 tests pass.
- `lcars-ui/css/usage-indicator.css`: Appended `/* === Stale + Offline States (XACA-0243-006) === */` section (88 lines added). Covers: compact stale diagonal-hatch bar, compact `.usage-stale-note` styling, full stale bar hatch + `.usage-stale-badge` pill, offline `filter:saturate(0.4)` + tan bar fallback, `.usage-offline-msg` italic color, and untrustworthy-projection `::before` placeholder.
- `lcars-ui/agent-panel.html`: Updated stale label to `Xm Ys ago` format (drop seconds if zero). Offline stats now show `OFFLINE — <error truncated 60 chars> · last cap ~$XX`. Idle state explicitly sets `data-band="none"` and text `IDLE · awaiting next window`.
- `lcars-ui/index.html`: Stale badge updated to `Xm Ys ago` format. Offline message error truncated to 60 chars. Projection section now sets `data-trustworthy="true|false"` on `projSection` so CSS can suppress untrusted projections.

### Refactor: Remove redundant double-scroll on plan-doc modal (XACA-0246-001)

- XACA-0246-001: `.plan-doc-content` `overflow-y:auto` and `max-height:calc(90vh-120px)` removed from `lcars-ui/css/lcars.css`. The element carries both `.lcars-modal-body` and `.plan-doc-content` classes; `.lcars-modal-body` already provides `overflow-y:auto; flex:1; min-height:0` and the parent `.lcars-modal` is capped at `max-height:90vh`, making the inner max-height a redundant second scroll container. Removing it eliminates the double-scrollbar on long plan docs.
- XACA-0246-002: webkit scrollbar pseudo-element selectors retargeted from `.plan-doc-content::` to `.lcars-modal-overlay .lcars-modal-body.plan-doc-content::` — scopes LCARS teal scrollbar styling to the actual scroll container after XACA-0246-001 removed `overflow-y` from `.plan-doc-content`.

### Added: kb-audit kanban integrity scanner (XACA-0234)

- XACA-0234: `kb-audit` top-level command scans all kanban boards for subitem data integrity issues: prefix mismatches (subitem ID prefix does not match parent ID) and duplicate subitem IDs (within-parent and cross-parent). Reports in human-readable or `--json` format with severity levels (error/warning). `--fix` mode attempts repair via `kb-backlog sub rename-id` and reports failures honestly (rename-id rejects cross-parent renames with rc=3, which covers most prefix-mismatch cases). Exit codes: 0 clean, 1 warnings, 2 errors, 4 fix-failures (bit-OR combined). Detected 7 real duplicate-subitem-ID errors across academy, firebase, and ios boards.
- XACA-0234 (tests): `tests/test-kb-audit.sh` — 19-case shell test suite for `_kb_audit_scan_board` and `kb-audit`. Covers prefix mismatch detection (T2), within-parent duplicate IDs (T3), cross-parent duplicate IDs (T4), edge cases (clean board T1, empty subitems T5, missing subitems key T6), combined findings in one fixture (T7), end-to-end exit codes 0/1/2 (T8), JSON output shape (T9), `--help` flag (T10), `--team` validation against unknown team names (T11), and empty `teams.json` handling (T12).
- XACA-0234 (PR #276 review fixes): `--team <unknown>` now errors with non-zero exit instead of silently scanning 0 boards. Empty `.teams = {}` in `team-paths.json` now errors instead of looping zero times. Removed unused `board_labels` array, removed double-`local rename_rc` declaration inside `--fix` while loop, removed unused `rename_err`. Human-readable prefix-mismatch line now distinguishes actual prefix from expected (no longer prints the parent ID twice).

### Chore: XACA-0241 — Persona-file knowledge-path sweep (XACA-0222 follow-on)

Updates 31 persona files across 5 team dirs to the new four-tier knowledge schema. Closes the follow-on noted in XACA-0239 subitem 015.

- **Files** — 31 personas: `mainevent/` (7), `freelance/` (7), `legal/` (6), `medical/` (6), `finance/` (5).
- **Replacement** — Each persona's stale two-line block:
  - `**Agent knowledge:** \`~/dev-team/kanban/<team>/knowledge/<persona>/\``
  - `**Team knowledge:** \`~/dev-team/kanban/<team>/knowledge/TEAM/\``

  becomes the new three-tier block:
  - `**Agent knowledge:**   \`~/knowledge/agents/<persona>/\``
  - `**Subject knowledge:** \`~/knowledge/subjects/\``
  - `**Project knowledge:** \`<repo>/kanban/knowledge/project/\``
- **Mechanism** — Idempotent Python script at `/tmp/xaca-0241-persona-sweep.py`. Persona name extracted from filename (`<team>_<persona>_<descriptor>_persona.md`); hyphenated personas (`quark-fin`) preserved.
- **Verification** — `grep -rln "kanban/.*/knowledge/[A-Za-z]" --include="*persona*.md"` excluding `homebrew-tap/share/` returns zero matches after the sweep.
- **Out of scope** — `homebrew-tap/share/personas/` (19 files) is the shipped tap copy with independent drift; addressed separately.

### fix: XACA-0215 — Pre-push hook worktree-awareness + regex-metachar match

Two correctness bugs caught during PR self-review (subitem 007):

- **Worktree false positives** — hook used `git rev-parse --git-common-dir` to find
  the repo root, which always resolves to the MAIN repo's working tree. From a
  worktree, this caused the drift check to evaluate the main repo's tap state
  (potentially in any unrelated condition) instead of the worktree's own
  commits. Now uses `git rev-parse --show-toplevel` to anchor on the actual
  worktree root, and passes `DEV_TEAM=$WORKTREE_ROOT` into `sync-tap.sh` so
  the check evaluates the tree we're actually pushing.
- **Regex metachar in path-prefix match** — `grep -q "^${path_prefix}"` treated
  `iterm2_window_manager.py` and `kanban-backup.py` as regex patterns; the `.`
  could (in theory) match `iterm2_window_managerXpy`. Replaced with a `case`
  statement using shell-glob matching for proper anchored fixed-string prefix
  comparison.

Verified end-to-end: clean worktree → exit 0; injected drift → exit 1 with full
UX block; opt-out env var → exit 0 with stderr notice; baseline-only commit
(homebrew-tap/share/ paths not in hook list) → exit 0 silent.

### chore: XACA-0215 — Baseline tap sync (clean drift before protection ships)

Pre-existing drift between `dev-team/` source files and `homebrew-tap/share/`
copies (the very condition this PR adds protection against) had to be cleared
before the new GH Actions workflow could run cleanly on develop. Ran
`./sync-tap.sh` to bring the tap copies up to date — 18 files synced (lcars-ui,
kanban-hooks, mapped scripts) plus one new file (`lcars-artifact-audit.js`).
No source-file changes; this commit only updates the tap copies. Without it,
the workflow would fail on its first run on develop, immediately after the
protection ships. Atomic landing keeps protection + clean baseline together.

### test+fix: XACA-0215-005 — Drift protection test verification + bug fixes

Independent test verification surfaced two real bugs; both fixed in this PR:

- **`.githooks/pre-push`** — added `sync-tap.sh` itself to `SYNC_TAP_PATHS` so a
  developer who edits the script (e.g., to add a new mapping) without re-running
  `./sync-tap.sh` is warned by the hook, not just by CI. Added a comment
  explaining why the hook's scope filter is intentionally narrower than the GH
  Actions `paths:` filter.
- **`sync-tap.sh`** — `--check` now exits 2 when source files are MISSING (e.g.,
  `DEV_TEAM` misconfigured). Previously MISSING reports printed but `CHANGED`
  stayed 0, so the script silent-passed. Drift protection that silently passes
  on a misconfigured CI is worse than no protection. Adds a `MISSING` counter
  alongside `CHANGED`; summary line now reports both counts.

### docs: XACA-0215-004 — README with drift-protection section

- **`README.md`** — comprehensive project overview with drift-protection documentation.
  Explains the two-layer defense (pre-push hook + CI workflow), one-time bootstrap command
  (`git config core.hooksPath .githooks`), failure UX with exact fix sequence, emergency
  opt-out with strong warnings, and rationale for blocking instead of auto-fixing.
  Links to `.githooks/README.md` and design-decisions doc for deeper context.

### feat: XACA-0215-003 — GitHub Actions sync-tap drift check

- **`.github/workflows/sync-tap-check.yml`** — runs `sync-tap.sh --check` on every PR and on
  push to `develop`. Fails fast (exit 1 + `::error::` annotation) when drift is detected.
  Catches the gap the local pre-push hook can't cover (Academy direct-to-develop commits,
  developers who haven't bootstrapped `core.hooksPath`).
- **`sync-tap.sh`** — line 18: `DEV_TEAM="${DEV_TEAM:-$HOME/dev-team}"` makes the script
  portable. Default behavior unchanged on dev machines; CI sets `DEV_TEAM=$GITHUB_WORKSPACE`.

### feat: XACA-0215-002 — Pre-push hook for sync-tap.sh drift detection

- **`.githooks/pre-push`** — version-controlled zsh hook that blocks pushes when commits
  touch sync-tap.sh source paths and the tap copy has drifted. Scope-filtered: only fires
  when changed files match lcars-ui/, kanban-hooks/, mapped scripts/, iterm2_window_manager.py,
  or kanban-backup.py. Runs `./sync-tap.sh --check`; on drift prints the failure UX block
  (DRIFT lines + three fix commands + emergency bypass). Handles all-zeros SHA for new
  branches and branch deletions. Opt-out: `SKIP_SYNC_TAP_CHECK=1 git push`.
- **`.githooks/README.md`** — bootstrap command, hooks table, opt-out instructions, link to
  design doc.
- **`docs/install-on-new-mac.sh`** — idempotent bootstrap added to Phase 8: sets
  `core.hooksPath .githooks` on the dev-team repo after clone; skips if already set.
### Chore: XACA-0239 — XACA-0222 schema migration cleanup (residual gaps)

Closes residual gaps from the XACA-0222 four-tier knowledge schema rewrite. Scope: skill text, validator errors, untracked artifacts, subagent-prompt pattern codification, and a per-branch migration card.

- **Project Planner skill — schema migration (subitem 001)** — `skills/Project Planner/SKILL.md` updated from the dead pre-XACA-0222 paths (`<repo-kanban>/knowledge/<codename>/` and `<repo-kanban>/knowledge/TEAM/`) to the four-tier model: agent (`~/knowledge/agents/<persona>/`), subject (`~/knowledge/subjects/<topic>/`), project (`<repo>/kanban/knowledge/project/`). Replaced the XACA-0084 design-doc reference with the authoritative pair `~/knowledge/SPEC.md` (schema) and `~/knowledge/docs/USAGE.md` (daily ops). Manual `mkdir`/file-create flows replaced with `kb-knowledge-add` invocations. Skill version bumped 1.10.0 → 1.10.1.
- **FORBIDDEN ACTIONS subagent prompt pattern (subitem 002)** — New canonical template at `~/knowledge/templates/subagent_prompt_template.md`. Pattern was used ad-hoc during XACA-0222 to reduce subagent scope drift (~85% reduction observed); now codified as a load-bearing block (universal forbidden actions + 1–2 task-specific items per delegation). Project Planner skill embeds the pattern in its subagent scaffolds. Memory entry at `~/.claude/projects/-Users-darrenehlers-dev-team/memory/feedback_subagent_forbidden_actions.md`.
- **Frontmatter validator errors fixed (subitems 003–004)** — Triage decision: migrate, don't relax. 32 legacy entries across `agents/{dax,deanna,obrien,picard,reno,thok}/` carried only markdown-bold metadata (`**Date:**`, `**Source:**`, `**Tags:**`); a Python backfill prepended YAML frontmatter (`id`/`tier`/`agent`/`date`/`source`/`tags`) lifting the existing values. Reno's `k001-lcars-css-cache-buster-gotcha` had memory-style frontmatter (`name`/`description`/`type`); rewritten to knowledge-entry schema. `kb-knowledge-validate`: 126 errors → 0 errors.
- **Untracked `~/knowledge` housekeeping (subitem 005)** — Committed `agents/reno/k036-test-activity-log-needs-sleep.md` (XACA-0233 lesson) and the new `templates/subagent_prompt_template.md`. Deleted `.phase5-dryrun-plan.md` (stale planning artifact from XACA-0222 Phase 5 work, now merged).
- **Migration card (subitem 006)** — New `docs/migrations/XACA-0222-TEAM-to-project.md` provides a reusable pattern for branches/worktrees created before XACA-0222 Phase 4 was merged. Documents rename details, validation checklist, migration steps (rebase, search, fix, validate), and XACA-0236 worktree status (clean — no action required). Follows precedent from XACA-0219.
- **Review-feedback follow-up (subitems 013–016)** — Tightened post-merge wording in `skills/Project Planner/SKILL.md` and the migration card per reed's PR #271 review:
  - **013** Restored two clauses on the FORBIDDEN ACTIONS block ("expand scope only with explicit instruction" and "(output, files, comments)") to match `~/knowledge/templates/subagent_prompt_template.md`.
  - **014** Project-tier `kb-knowledge-add` example label changed from `<repo-path>` to `<optional-slug>` to match the helper's actual second-arg semantics.
  - **015** Migration card now flags ~60 persona files still carrying stale `kanban/knowledge/TEAM/INDEX.md` references as a follow-on sweep (pre-existing, not introduced by xaca-0236).
  - **016** Project-tier path in the skill no longer implies `<repo>/kanban/knowledge/project/` is universal — clarifies the SPEC.md §4.4 default (`$KB_KNOWLEDGE_GLOBAL_ROOT/projects/<slug>/`) and the override mechanism (`KB_KNOWLEDGE_PROJECT_PATH` env or `.knowledge-config.yml`).

### Fix: XACA-0212 — Installer profile-awareness prevents stub board recreation next to canonical boards

- **Problem** — When a profile-scoped canonical board already existed (e.g., `~/finance/personal/kanban/finance-personal-board.json`), re-running the installer would still create a stub board file (e.g., `~/finance/finance-board.json`) in the parent directory. This dual-board setup triggered the XACA-0180 warning on every installer invocation, breaking the clean user experience.
- **Root cause** — `homebrew-tap/libexec/installers/install-team.sh` had no profile-awareness when creating stub board files. It unconditionally created the stub without checking if a profile-scoped canonical board already existed.
- **Fix** — `install-team.sh` now detects when a canonical profile-scoped board exists in subdirectories (`<team>/<profile>/kanban/<team>-<profile>-board.json`) and skips stub creation if found. Check runs before any file writes; prevents dual-board warnings from regenerating.
- **New command** — `kb-quarantine-stub <team>` shipped to resolve dual-board warnings on existing installs. The command was referenced by `_kb_check_dual_boards` warnings in kanban-helpers.sh (XACA-0180) but was never implemented. XACA-0212 provides the implementation. Running the command marks an existing stub board as "quarantined" (disabled) so the warning no longer fires.
- **Validation** — Fresh installs with profile-scoped boards no longer generate stubs; existing dual-board setups can be healed with `kb-quarantine-stub`.

### Added: kb-backlog sub rename-id helper for repairing mis-prefixed subitem IDs (XACA-0233)

- **New command** — `kb-backlog sub rename-id <old-id> <new-id>` repairs subitem IDs that have the wrong parent prefix (e.g., `XACA-0136-007` attached to parent `XACA-0001`) without requiring raw JSON editing.
- **Validation** — Checks both IDs against `^[A-Z]+-[0-9]+-[0-9]{3}$` format, rejects cross-parent renames (exit 3), detects missing parent (exit 4), missing subitem (exit 5), and new-ID collision on the same parent (exit 6). Idempotent: `old == new` exits 0 with no-op message, no activity log entry.
- **Side effects** — Rewrites `parent.workingOnId` if it matches `old-id` (keeps pause/resume, statusline, and `_kb_clear_working_on` consistent). Stamps `parent.updatedAt` and `board.lastUpdated`. Calls `_kb_release_sync` for manifest re-key (non-fatal on failure). Logs `subitem_renamed` action to parent's activity file.
- **Help** — Added to `kb-backlog sub` inline usage block and to the top-level `kb help` subitems section.

### Fix: XACA-0237 — Resolve `doctor` agent name collision between iOS and MainEvent

- **Symptom** — Two agent persona files declared `name: doctor` in YAML frontmatter: `ios/personas/agents/ios_beverly_bugfix_persona.md` (Beverly Crusher, iOS) and `mainevent/personas/agents/mainevent_doctor_bugfix_persona.md` (The Doctor / EMH, MainEvent). Agent dispatch by name `doctor` was ambiguous and resolved by directory load order — MainEvent's Doctor was winning, leaving iOS Beverly invisible to the dispatcher.
- **Root cause** — Beverly Crusher's frontmatter `name:` field was incorrectly set to `doctor` (her in-universe title). Every other reference to her file/persona uses `beverly` (filename, AMB handle `beverly-crusher`, knowledge dir, avatar codename), but a number of dispatch points still routed `doctor` for iOS work — those were silently hitting MainEvent's EMH.
- **Fix** — Changed `name: doctor` → `name: beverly` in `ios/personas/agents/ios_beverly_bugfix_persona.md`. MainEvent's Doctor persona keeps `name: doctor` (correct — that IS the character's name).
- **Caller fixes (post-rename, all iOS dispatch points repointed `doctor` → `beverly`):**
  - `claude_agent_aliases.sh` — renamed `claude-doctor` → `claude-beverly`; `claude-crusher` now dispatches `beverly`; `claude-phlox` (Freelance) corrected to dispatch `phlox` (was incorrectly dispatching `doctor`).
  - `ios/scripts/ios-sickbay-startup.sh` — tmux `@claude_agent` set to `beverly` (was `doctor`).
  - `claude/agent-tracking.sh` — iOS bug-fix agent listed as `beverly`.
  - `ios/scripts/launch-ios-*.sh` (6 files) + `academy/scripts/generate-all-launchers.py` — iOS team agent context strings now list `beverly` instead of `doctor`.
  - `freelance/freelance_team_summary.md` — Phlox doc corrected to `Claude Agent: phlox`.
  - MainEvent dispatch points (`claude-emh-doctor`, `mainevent-sickbay-startup.sh`, MainEvent launch scripts, mainevent guide in `kanban-helpers.sh`, `display-agent-avatar.sh`) all preserved — `doctor` is correct for the EMH.
- **Surfaced by** — XACA-0232 classification audit; comprehensive caller sweep added during PR review (test bot caught the under-scoped initial fix).

### Fix: XACA-0222 review subitems 013-016 — security hardening and correctness

- **013 (HIGH — security)** — `kb-knowledge-add` and `_kb_knowledge_resolve_ref` now validate persona/team/subject/project parameters before constructing any filesystem path. New helpers `_kb_validate_name_component` (rejects anything not matching `^[a-z][a-z0-9_-]*$`) and `_kb_validate_subject_path` (validates each slash-separated component). Rejects path-traversal attempts like `../etc/passwd`, null bytes, backslashes, and uppercase names.
- **014 (LOW)** — `kb-knowledge-validate` cross-ref scanner now reads only YAML frontmatter via `sed -n '/^---$/,/^---$/{//!p}'` (capped at 50 lines) instead of scanning the full file body. Eliminates false-positive broken-ref warnings on cross-ref tokens in code samples, prose, and quoted text.
- **015 (MEDIUM)** — `_kb_knowledge_project_path` `.knowledge-config.yml` parser replaced whitespace-corrupting `| xargs` with parameter-expansion trim (`${config_path## }` / `${config_path%% }`). Paths with embedded spaces in `project_knowledge_path:` are now preserved correctly.
- **016 (LOW)** — `kb-knowledge-search` 3-grep-per-file consolidation deferred; added `TODO(XACA-0222)` comment noting the ~500-entry threshold at which consolidation becomes worthwhile.

### Fix: XACA-0222 Phase 8 — 5 defects in kb-knowledge-* tools (D1-D5)

- **D1 (HIGH)** — stdout trace leak (`md_files=`, `filepath=`, etc.) in `kb-knowledge-search` and `kb-knowledge-validate` from zsh `local var` re-declaration inside loops (same root cause as Phase 8 reindex_one fix). All loop-local variables pre-declared at function header; plain assignment used inside loops.
- **D2 (HIGH)** — `local root_idx=0` / `local dir_idx=0` in zsh 1-based array context caused every search result to show `[]` instead of `[agent]`/`[subject]`/etc. Fixed both to initialize at `1`.
- **D3 (MEDIUM)** — INDEX orphan check appended `.md` to entries already ending in `.md` (producing `k001-foo.md.md`), reporting every indexed file as a false-positive missing entry. Fixed with `${idx_id%.md}.md`.
- **D4 (MEDIUM)** — `kb-knowledge-promote agents:emh:k001` built path `k001.md` instead of glob-expanding to `k001-actual-slug.md`. Added `_kb_resolve_entry_path` helper with glob fallback for 3-digit numeric refs inside `_kb_knowledge_resolve_ref`.
- **D5a (MEDIUM)** — Tag map in `_kb_knowledge_reindex_one` used full slug (`k001-removeeventlistener-...`) instead of short display ID (`K001`). Fixed: extract `${eid%%-*}` then capitalize.
- **D5b (MEDIUM)** — Agent INDEX header used lowercase basename (`# thok Knowledge Index`). Fixed: capitalize first letter of `dir_name` for agent tier only.
- **D5c (MEDIUM)** — Entry summaries always emitted `*(add one-sentence summary)*` placeholder, overwriting curated content on reindex. Now pulls `summary:` frontmatter field first; falls back to first non-frontmatter body sentence via awk; placeholder only if both are empty.

### Feat: XACA-0222 Phase 6 — Knowledge system tools + zshrc wiring (kanban-helpers.sh, home-scripts)

- **`kb-knowledge-search` rewritten** — Convention-driven four-tier discovery (project > team > subject > agent) replaces hardcoded 17-entry team-path array. Reads `KB_KNOWLEDGE_GLOBAL_ROOT` (default `~/knowledge`). Supports `--agent`, `--subject`, `--project`, `--tag`, `--tier`, `--all-projects` flags. `--team` preserved as backward-compat alias for `--agent`.
- **`kb-knowledge-add`** — Scaffolds new entries with next-available ID. `kb-knowledge-add agent emh "title"` → `~/knowledge/agents/emh/kNNN-title.md`. Handles `agent`, `team`, `subject`, and `project` tiers.
- **`kb-knowledge-promote`** — Tier promotion with dry-run-by-default safety. `--confirm` to execute. Moves file, rewrites frontmatter tier, writes stub at source, reindexes both dirs.
- **`kb-knowledge-validate`** — Cross-ref integrity check, INDEX orphan detection, subject depth guard (max 4), lowercase prefix enforcement. `--quiet` and `--fix` flags.
- **`kb-knowledge-reindex`** — Regenerates `INDEX.md` from entry files. `--dir <path>` for single dir; no flag = all tiers. Preserves `Relevant Subjects` from existing project INDEXes. Builds tag map from YAML frontmatter.
- **`kb` help text updated** — Knowledge Base section now documents all five new functions with flags.
- **`KB_KNOWLEDGE_PROJECT_PATH` wired** — Exported `'{repo_root}/kanban/knowledge/project'` in all 55 `.zshrc_*` files in `home-scripts/`. Placed after `export CLAUDE_*_THEME=` with explanatory comment.
- **Stale template path refs updated** — `kanban/knowledge/TEMPLATES/` references in `kanban-helpers.sh` (×6) and `claude-hooks/kb-knowledge-capture-nudge.sh` updated to `~/knowledge/templates/`. Knowledge-entry lookup in `kb-done` and `kb-backlog sub done` flows now search `_kb_knowledge_global_root()` instead of `${kanban_dir}/knowledge`.
- **`kb-index-rebuild` preserved + annotated** — Legacy function kept for backward-compat; `COMMAND` and `TEAM` entries removed from hardcoded list; deprecation note points to `kb-knowledge-reindex`.
- **`claude-hooks/kb-knowledge-capture-nudge.sh`** — `_team_kb_dir()` replaced with convention-driven lookup using `KB_KNOWLEDGE_GLOBAL_ROOT/agents/<handle>/`. No per-team hardcoded paths.
- **`scripts/add_knowledge_base_section.py`** — Updated to write new schema paths (`~/knowledge/agents/<codename>/` and `~/knowledge/teams/<slug>/`) instead of old `kanban/knowledge/` paths.

### Chore: Kanban governance — restrict direct JSON editing to Academy only

- **Rule added** — Non-Academy teams are now explicitly prohibited from editing any kanban JSON file directly (`kanban-board.json`, release manifests, etc.). All writes must go through `kb-*` commands, Kanban MCP, or `/kanban` skill.
- **Academy exception scoped** — Academy may edit JSON directly only for infrastructure maintenance (schema migrations, bulk repairs) where the API is insufficient.
- **Motivation** — Android team manually edited JSON to create release 2.11.2 instead of using `kb-release create`. Direct edits bypass validation, break LCARS sync, and destroy audit history.
- Updated `claude/CLAUDE.md` (tracked) and `~/.claude/CLAUDE.md` (live).

### Chore: XACA-0232 — Model tuning across all agents/skills + earlier context compaction

- **Motivation** — 68 agents and 30 skill files (21 canonical + 9 homebrew-tap copies) had inconsistent or missing `model:` frontmatter. Android team was pinned to a dated Sonnet string (`claude-sonnet-4-5-20250929`) instead of the `sonnet` alias; MainEvent team had no `model:` field at all; no principled assignment existed across the Opus/Sonnet/Haiku tiers. Additionally, 1M-context sessions were running to ~83% before auto-compaction triggered, wasting tokens.
- **Model assignments** — Applied a three-tier rubric per `claude/MODEL_SELECTION.md`:
  - **Opus (15 agents, 1 skill):** lead feature devs with architectural scope (picard, kirk, sisko, archer, mariner, janeway-mainevent, house); strategic command (nahla, vance, janeway-command); security-threat roles (nechayev, tuvok); high-reasoning domain leads (zek, advocate, lawclerk); Project Planner skill.
  - **Sonnet (40 agents, 13 skills):** default for feature work, bug fixes, testing, refactoring, release engineering, moderate documentation, and most skills.
  - **Haiku (13 agents, 8 skills):** templated/narrow-scope — team doc leads (emh, sulu, sato, ransom, bashir, deanna, kim, wilson); narrow-domain automation (quark-fin, rom, courtclerk, casemanager, paris); and template-filling skills (newsletter, weekly reports, status generators, RELNOTES Manager, git-worktree, Workflow Description, Scrum of Scrums, Team Mission Status, Center Management).
  - Android team normalized from the pinned date string to the `sonnet` alias so it stays current with future Anthropic releases.
  - MainEvent agents had `model:` inserted (7 files) — this was missing entirely.
- **Context compaction** — ~~Added `env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE: "50"`~~ **Removed** (see Fix: XACA-0232 debug below). The 50% override was too aggressive for Sonnet sessions (200K context → fires at ~100K tokens). All sessions now use the default ~83% threshold.
- **New reference doc** — `claude/MODEL_SELECTION.md` (documents the rubric, current tier assignments, override process, compaction settings, and quarterly-review guidance).
- **Scope** — All edits are frontmatter-only; no logic or prompt text changes. Files touched: 68 team agent personas + 49 homebrew-tap agent copies + 22 canonical skills + 9 homebrew-tap skill copies + 1 settings.json + 1 new MODEL_SELECTION.md.
- **Future follow-ups filed** — XACA-0235 (dedup DNS / DNS Framework directories), XACA-0236 (consolidate Medical team double-file persona structure), XACA-0237 (resolve `doctor` agent name collision between iOS and MainEvent).
- **Validation** — All agent and skill files validate: YAML frontmatter parses cleanly, `model:` field present on every file, value is one of `opus`/`sonnet`/`haiku`. `settings.json` JSON validates. One skill (Bitrise Build Status) has no SKILL.md in the worktree source despite appearing on the skill map — flagged, out of scope for frontmatter work.

### Fix: XACA-0232 debug — Remove CLAUDE_AUTOCOMPACT_PCT_OVERRIDE from global settings

- **Symptom** — Sessions on Sonnet (200K context window) compacted after only ~100K tokens — too aggressively for normal development work.
- **Root cause** — `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE: "50"` was added globally in `claude/settings.json` (→ `~/.claude/settings.json`). The 50% value was correct for Opus (1M context, fires at 500K tokens) but fires at 100K on Sonnet. `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` has no per-model support (GitHub Issue #34126).
- **Fix** — Removed `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` from `claude/settings.json`. All sessions now use the Claude Code default (~83%). Updated `claude/MODEL_SELECTION.md` Section 5 to document the rationale and removal.

### Fix: XACA-0231 — Session-UUID → tab-id mapping eliminates iTerm2 "C " tab-prefix drift

- **Symptom** — After a Claude Code session exits, the iTerm2 tab's "C " prefix occasionally failed to strip. Over time, refcount files in `~/.claude/.iterm_tab_refcount/` accumulated stale entries (counts > 1 per tab with no live claude). Tier-2 recurrence of XACA-0214 / XACA-0223.
- **Root cause** — The Stop hook runs in a double-forked daemon whose inherited `TMUX`/`TMUX_PANE` env may not resolve to the same `client_tty` as the SessionStart hook. When the two hooks resolve different tab_ids, `clear_claude_active` decrements the wrong refcount file (or short-circuits on `unknown`), so the "C " prefix never strips and the real refcount never reaches 0.
- **Fix** — Capture the resolved `tab_id` at SessionStart into a file keyed by the CC hook's `session_id` (`~/.claude/.iterm_tab_refcount/sessions/<session_id>`). At Stop, look up that stored `tab_id` and pass it explicitly to `clear_claude_active` — same helper function, new optional positional arg. Tab-id drift between the two hooks is eliminated by construction.
  - `iterm2_badge_helper.sh` — `set_claude_active [tab_id]`, `clear_claude_active [tab_id]`, and `_iterm_refcount_file [tab_id]` all accept an optional explicit tab_id. Fallback to `_iterm_tab_id` when omitted — fully backwards compatible.
  - `kanban-hooks/kanban-session-start.py` — extracts `session_id` from the hook payload, resolves `tab_id` inside the bash child it already spawns, writes the mapping via atomic tmp-rename, passes `tab_id` explicitly to `set_claude_active`. All inputs plumbed via `env=` (not string interpolation) for shell-metachar safety.
  - `kanban-hooks/kanban-stop.py` — extracts `session_id`, threads it through the double-fork daemon into `_fire_iterm2_tab_clear`, reads the mapping back, passes `tab_id` to `clear_claude_active`, unconditionally unlinks the mapping file after the clear runs (session terminates either way).
  - `kanban-hooks/kanban-session-start.py` — `_sweep_orphan_session_maps()` prunes mapping files older than 7 days on every SessionStart (best-effort, capped at 10,000 files, silent on failure). Catches mappings orphaned by crashed sessions that never reached Stop.
  - `scripts/onscreen-heal.sh` — `tmux list-panes` widened from window-scope (`-t $TMUX_PANE`) to session-scope (`-s -t $TMUX_PANE`). Fixes the sibling-tmux-window false-positive where `_onscreen_heal` would strip a legitimate "C " prefix because claude was alive in a sibling window of the same iTerm2 tab, not the one `onscreen` was invoked from.
- **One-time cleanup** — `scripts/xaca-0231-cleanup.sh` (ships with the PR, NOT run automatically) audits stale refcount files and orphaned "C " prefixes. Dry-run by default; `--apply` required to mutate. Live-claude detection walks `tmux list-clients` → session → pane TTYs → `ps` to avoid the naive `ps -t <client_tty>` trap that misses processes inside tmux panes. Safety: leaves files untouched when `live > stored` (conservative; don't touch anything actively healthy).
- **Validation** — `iterm2_badge_helper.sh test-refcount` passes 11/11 (extended from 4/4 with 4 new explicit-arg tests covering file-path, resolver-vs-explicit isolation, slash sanitization, empty-arg fallthrough). Python `ast.parse` clean on both hooks. Hook-level integration tests covered SessionStart mapping-write, Stop session_id extract, orphan sweep with 7-day mtime threshold, and onscreen-heal syntax/scope — all pass without polluting the real refcount dir. Live iTerm2 end-to-end is deferred to post-merge dev sessions (every defensive path wraps in try/except with debug-log breadcrumbs).

### Fix: XACA-0230 — TODOS/HOME sidebar labels went invisible when active (CSS specificity)

- **Symptom** — In kanban mode, clicking the TODOS sidebar button made its label disappear. Same pattern on the HOME button in data mode (lavender-on-lavender).
- **Root cause** — The per-mode base recolor rules (`.lcars-container[data-mode="kanban"] .sidebar-button[data-section="todos"]` at specificity 0,4,0) outranked the generic active rule (`.sidebar-button[data-section="todos"].active` at 0,3,0) on the `background` property. The per-mode active overrides at lines 742-748 were only setting `color`, not `background`, so the active state inherited the per-mode tan/lavender background and then painted text in the same tan/lavender color — invisible.
- **Fix** — Added `background: var(--lcars-black)` to both per-mode active-state overrides (kanban+todos, data+home) in `lcars-ui/css/lcars.css`. The 0,5,0 selector now correctly wins over the 0,4,0 base rule, completing the black-bg/color-text inversion pattern used by every other sidebar button. Expanded the adjacent comment block to explain the specificity reasoning so the next editor doesn't re-break it.
- **Scope** — Only the canonical `lcars-ui/css/lcars.css` is modified. Mode-scoped, not board-scoped — fix applies across all 10 kanban boards (academy, ios, android, firebase, command, dns, freelance, mainevent, legal-coparenting, finance) automatically.
- **Validation** — Specificity math verified (0,4,0 base vs 0,5,0 fix vs 0,3,0 generic active). No other per-mode sidebar recolors exist that could exhibit the same bug. Node brace-depth parse returns clean (1924 open / 1924 close). No JS reads computed sidebar background, no visual-regression snapshots exist. Contrast check: tan (#cc9966) and lavender (#ccccff) on black both exceed 4.5:1.

### Chore: XACA-0222 Phase 4 — Knowledge system schema migration (TEAM → project, tNNN → pNNN)

- **Context** — Phase 4 of XACA-0222 knowledge system schema rewrite. Three project repos had `kanban/knowledge/TEAM/` directories using the old `tNNN` prefix and no YAML frontmatter.
- **dev-team (Academy)** — `kanban/knowledge/TEAM/` renamed to `project/` (git mv, 12 files). `tNNN` files renamed `pNNN` sequentially. YAML frontmatter (`tier: project`, `date:`, `source:`) prepended to all files. New files added: `p012-center-code-conventions.md` (from COMMAND c002), `p013-p016` (dev-team-specific reno t001/t002/t003/t008). `project/INDEX.md` rewritten with Relevant Subjects section, Tag Index, 16 entries.
- **MainEventApp-iOS** — `kanban/knowledge/TEAM/` renamed to `project/`. `t001-t015` renamed `p001-p015`. iOS data/ and picard/ deferred entries placed as `p016-p021`. YAML frontmatter added to all 22 files. INDEX rewritten with Relevant Subjects (ios, ios:swift, firebase, git).
- **MainEventApp-Android** — `kanban/knowledge/TEAM/` renamed to `project/`. Files renamed `p001-p011` (T003 scope-leakage → p003, t003 serialization → p004 to resolve naming collision). Date-format volley file retains name. Stray root t-files removed (already migrated to subjects/android/). YAML frontmatter added. INDEX rewritten with Relevant Subjects (android, firebase, git).
- **Scope** — No behavior or content changes. Pure schema migration: directory name, file prefix, frontmatter addition, index rebuild.

### Fix: XACA-0227 — Harden remaining `innerHTML` interpolation sites in `lcars.js`

- **Context** — Follow-up to XACA-0217. reed's PR #257 code review flagged ~8 additional sites in `lcars-ui/js/lcars.js` that interpolated server-returned or exception-origin strings into `innerHTML` via template literals without passing through `escapeHtml()`. Practical risk is low (internal tool, many values are enums/numerics), but consistent hardening closes the class of vulnerability and removes the surface area for a future caller to regress.
- **Fix** — Wrapped 13 server-data/exception interpolations with the existing `escapeHtml()` helper: current-status pill `win.status` (2291), Jira search error (4959), Jira verify error and success/warning branches (5088, 5096, 5098 — the two adjacent siblings of Reed's 5088 site, same pattern, same function, folded in for consistency), create-item error (5226), create-item success ticketId (5216), release items error (10776), epic items error (12537), epic-select error (13052), backup files error (14170), integrations error (14415). `statusHistory` enum strings now pass through `escapeHtml(String(s).toUpperCase())` inside the `.map()` (2306) — `getStatusColor()` in the neighboring CSS attribute is a whitelist-return function and was already safe. The `gitLines.added`/`gitLines.deleted` block (2440) was rebuilt as DOM construction with `textContent` to match the surrounding block's style — visual output identical. (Sites 2291 and 5216 were added in round 2 after reed's bot review flagged them as same-class sites that had escaped Reed's original PR #257 list.)
- **Scope** — Only the canonical `lcars-ui/js/lcars.js` is modified. The `homebrew-tap/share/lcars-ui/js/lcars.js` copy picks up on the next `sync-tap.sh` run, same as XACA-0217. `escapeHtml()` helper at line 10856 was already present — no new helpers added.
- **Validation** — `node --check` clean on the modified file. `git diff --stat` = 18 insertions / 12 deletions across one file. Each fix is either `${x}` → `${escapeHtml(x)}` (pure string escaping, semantically neutral) or DOM reconstruction preserving the visual output. No logic changes. Bots will run lint + test in CI.

### Fix: `iterm2_badge_helper.sh` dumped function bodies to terminal on CC exit

- **Symptom** — Exiting Claude Code (any team terminal) left a page of raw shell-function definitions on the user's screen: `iterm2_set_user_var () { … }`, `set_claude_badge () { … }`, `clear_claude_badge () { … }`, `set_claude_active () { … }`, and so on.
- **Root cause** — `iterm2_badge_helper.sh` ends with `export -f <name>` lines (one per public function). That directive means two different things: in **bash** it marks the function for export to child processes (silent); in **zsh** it is equivalent to `typeset -gxf <name>`, which **prints the function body to stdout**. `claude_code_cc_aliases.sh`'s `_cc_launch` wrapper (XACA-0223 deterministic tab-prefix clear) sources the helper from interactive zsh after `claude` exits — every `export -f` then dumped its function body to the terminal. Reproducible via `zsh -c 'source ~/dev-team/iterm2_badge_helper.sh'`.
- **Fix** — Wrapped the `export -f` block in `if [ -n "${BASH_VERSION:-}" ]; then … fi`. Function *definitions* run earlier in the file, so zsh still gets working functions; only the bash-specific export directive is skipped (zsh can't consume bash's exported-function env format anyway, so nothing useful is lost). The kanban-stop.py path (`bash -c "source … && clear_claude_active"`) continues to export as before.
- **Validation** — `zsh -c 'source …'` now emits zero output; `whence -v clear_claude_badge` confirms the function is defined in zsh. `bash -c 'source …'` still yields `declare -fx clear_claude_badge` (export intact). Affects every team — 55 zshrc files source `claude_code_cc_aliases.sh`.

### Fix: `kb-backlog add` silently created junk items from unparsed flags

- **Symptom** — Running `kb-backlog add --help` (or any `--flag` typo) created a real backlog item with the flag string as its title (observed: XACA-0224 and XACA-0228, both titled literally `--help`, both cancelled as junk).
- **Root cause** — `kanban-helpers.sh`'s `add` arg-parsing loop only recognized `--sub-repo`; every other argument fell through the `*)` catch-all and was treated as positional. `--help` landed in `$1` as the task title, passed the `[[ -z "$task" ]]` non-empty check, and got written to the board.
- **Fix** — Added an explicit `-h|--help` case to the arg loop (prints a concise usage and returns 0, consistent with other CLI conventions). Added a post-parse guard that rejects any task title starting with `-` — catches `--help`, `-h`, and any future typo'd flag (`--bogus`, etc.) with a clear error instead of silent ingestion.
- **Validation** — Manual: `kb-backlog add --help` and `-h` now print usage and exit 0; `kb-backlog add --bogus` prints `Error: task title cannot start with '-'` and exits 1; `kb-backlog add` with no args unchanged (prints long usage, exits 1); no board writes during testing.

### Fix: XACA-0221 — kb-sweep-stubs false positives when SCAN_ROOT is a dev-team subtree

- **Context** — XACA-0219 T6 follow-up. `kb-sweep-stubs` correctly ignored symlinks pointing into `~/dev-team`, but real (non-symlink) team-named directories under `~/dev-team` (e.g., `~/dev-team/ios`, `~/dev-team/worktrees/*/firebase`) matched the `personas/` sentinel and were flagged as stubs. Default invocation (no SCAN_ROOT, scans `$HOME`) was unaffected — the guard hook remained safe. The bug only surfaced when a user explicitly passed `$HOME/dev-team` or a worktree path as the scan root.
- **`kanban-hooks/kb-sweep-stubs` hardened** — Added `_resolve_path()` helper (tries `realpath`, falls back to `python3 os.path.realpath`). `DEV_TEAM_PATH` is now canonicalized at startup so a symlinked `~/dev-team` still matches. The main scan loop resolves each candidate and skips any whose canonical path lives under `DEV_TEAM_PATH` — covers both symlinks and real directories. When `SCAN_ROOT` itself resolves under `DEV_TEAM_PATH`, a loud stderr warning fires before the scan so the user immediately sees why their scan reports zero findings. The old `is_excluded_symlink()` function was deleted — strictly subsumed by the new realpath check, removed to eliminate divergence risk. Header docstring updated.
- **`scripts/detect-aiteamforge-stubs.sh` unchanged** — Pure `exec` pass-through; new behavior flows through automatically.
- **`tests/test-kb-sweep-stubs.sh` added** — 349 lines, 19 assertions across 6 test IDs. T1: SCAN_ROOT=`~/dev-team` yields exit 0 with SCAN_ROOT warning. T2: SCAN_ROOT inside a worktree yields exit 0 (worktree realpath resolves back under dev-team). T3: symlink to dev-team subdir still excluded (regression). T4: real fake stub under `/tmp` still flagged exit 1 (positive coverage). T5: default `$HOME` scan unchanged, no warning, correct `scan_root`. T6: compat shim pass-through parity with T1. Harness uses `set -u` without `set -e` so all tests run.
- **Validation** — 19/19 pass. Manual regression A–F clean (default scan, `~/dev-team`, worktree path, clean tmpdir, fabricated stub detection, shim parity). `aiteamforge-stub-guard.sh` emits nothing on this machine (clean XACA-0219 baseline).

### Fix: XACA-0217 — Harden `showToast()` against HTML injection

- **Context** — `showToast()` in `lcars-ui/js/lcars.js` built the toast body by interpolating its `message` argument into `toast.innerHTML` via a template literal. ~40 callers feed it server-returned strings (`result.error`, `error.message`, dashboard names, kanban item titles/IDs). No live caller currently emits HTML, but the primitive was unsafe — a future caller passing unsanitized server data would yield DOM injection in an internal tool. Flagged by reed during PR #239 (XACA-0213) code review; pre-existing, not introduced by that PR.
- **Fix** — Replaced the `innerHTML` template with DOM construction: `iconSpan`/`messageSpan` created via `document.createElement` and populated with `textContent` (spec-guaranteed to render HTML strings as literal text, not parse them); close button wired via `addEventListener('click', …)` instead of inline `onclick`. Icon mapping and `info` fallback unchanged.
- **Scope** — Only the canonical `lcars-ui/js/lcars.js` is modified. The `homebrew-tap/share/lcars-ui/js/lcars.js` copy picks up the fix on the next `sync-tap.sh` run (release-time, not per-PR). `fleet-monitor/.../lcars-dashboards-ui.js` has its own separate `showToast` method — out of scope here.
- **Validation** — Node verification harness replicated the new DOM-construction block and asserted all five cases pass: plain text renders as-is; `<img src=x onerror=alert(1)>` payload stored as literal `textContent` with zero child DOM nodes; `</span><script>alert("pwn")</script>` payload stored as literal text; close handler still removes the toast on click; icon mapping + info fallback preserved.

### Fix: XACA-0225 — LCARS Web profile reload race on team startup

- **Context** — Switching between teams could leave the LCARS Web iTerm2 tab pointed at the *previous* team's port. Two root causes: (a) iTerm2 reloads Dynamic Profile JSONs asynchronously (empirically 0.5–2s), but startup scripts created the LCARS Web tab immediately after writing the profile — iTerm2 still had the old `Initial URL` in memory; (b) `set-lcars-profile-browser.py` was invoked with `2>/dev/null` by every startup script, so write failures (missing file, corrupt JSON, missing "LCARS Web" profile) were completely invisible.
- **`scripts/set-lcars-profile-browser.py` hardened** — (002) Non-atomic `write_text` replaced with temp-file + `Path.replace()` atomic rename; added post-write readback that re-reads the JSON and confirms the `Initial URL` field matches what was written. Every failure mode now emits a `🚨`-prefixed stderr message: missing JSON, corrupt JSON, missing "LCARS Web" profile entry, write failure, readback mismatch. `main()` returns non-zero on every error path. (003) New `_wait_for_iterm2_reload()` function sleeps 1.5s (default) after a successful write, giving iTerm2 time to rescan the Dynamic Profiles directory before the caller creates the LCARS Web tab. Delay is tunable via `LCARS_PROFILE_RELOAD_WAIT` env var (clamped 0.0–10.0); `=0` skips the wait (for automated tests). Large docstring explains why we can't poll the iTerm2 Python API for `Initial URL` (API doesn't expose Dynamic-Profile-only fields) and why we don't rely on filesystem signals (iTerm2 writes nothing observable on reload).
- **`scripts/lcars-launch-helpers.sh` added** — (004) New shared helper sourced by all 11 top-level startup scripts. Provides `start_lcars_server <team> <port> [session_name]` (writes router redirect, kills stale server on port, starts new one, polls `curl /api/status` readiness up to 5s) and `open_lcars_tab <port> <window_title> <tab_name> <tmux_socket> <lcars_session> <startup_log>` (calls the hardened setter with no stderr suppression, then `iterm2_window_manager.py --action create-tab --profile "LCARS Web"` with the existing 3× retry). Functions-only (no top-level code); distinct return codes for setter failure vs tab failure so callers can react differently.
- **11 top-level startup scripts migrated** — (005) `academy-startup.sh`, `ios-startup.sh`, `android-startup.sh`, `firebase-startup.sh`, `mainevent-startup.sh`, `freelance-startup.sh`, `dns-startup.sh`, `legal-startup.sh`, `command-startup.sh`, `finance-startup.sh`, `medical-startup.sh`. Each sources `scripts/lcars-launch-helpers.sh`, replaces its inline server-start block with a `start_lcars_server` call, and replaces the LCARS branch in its per-terminal loop with `open_lcars_tab` + `continue`. The Default-profile (non-LCARS) tab path is untouched.
- **academy-startup.sh special case** — Remote branch server startup (SSH + port-forward) left intact as documented in the helper header. Local branch migrated. `open_lcars_tab` used for the LCARS browser tab in both branches since SSH port-forward makes `http://localhost:$LCARS_PORT` valid locally regardless of where the server runs.
- **mainevent / freelance / finance / medical / legal** — These teams write a second `window.LCARS_TARGET_SESSION` line to `lcars-target.js` that the helper does not write. Each script appends that line immediately after calling `start_lcars_server`.
- **Silent-fail removal (006)** — `2>/dev/null` dropped from all `set-lcars-profile-browser.py` invocations. Covers the 11 top-level scripts (via `open_lcars_tab`, which never silences stderr) and two subfolder scripts (`medical/scripts/medical-startup.sh`, `legal/scripts/legal-startup.sh`) where the setter is called directly. `grep -rn 'set-lcars-profile-browser\.py.*2>/dev/null' --include='*.sh' .` now matches only an intentional comment in `lcars-launch-helpers.sh` that documents the old anti-pattern.
- **Validation (007)** — `ast.parse()` clean on the Python script; `zsh -n` clean on all 14 modified shell files; happy-path, missing-file, corrupt-JSON, and missing-profile scenarios verified against the real Dynamic Profile (with backup/restore); env-var clamping verified across unparseable / below-min / above-max / zero cases. End-to-end team-switch race fix cannot be validated automatically (requires live iTerm2 disruption) and is flagged as a user-verification checkpoint before merge.
- **Net** — 15 files changed, new helper added, 11 startup scripts reduced by ~15–20 lines each (DRY win).
- **Review follow-ups (folded into this PR)** — (a) Added `|| { echo "fatal: …" >&2; exit 1; }` guard to the `source scripts/lcars-launch-helpers.sh` line in all 11 startup scripts so a missing helper aborts startup with a clear message instead of deferring to "command not found" further downstream. (b) Clarified the reload-wait skip message in `set-lcars-profile-browser.py` from the confusing `reload wait skipped (LCARS_PROFILE_RELOAD_WAIT=0)` to `reload wait skipped (delay=0.0s)` — accurate when the env var is set to a negative value that clamps to 0.

### Fix: XACA-0223 — Stuck iTerm2 "C " tab prefix after slow Claude exits + onscreen self-heal sweep

- **Symptom** — After XACA-0214 round-3 shipped the correctly-targeted tab prefix, real users observed stale `C ` prefixes persisting after `/exit`. The indicator appeared correctly on activation, but once a Claude session exited, the tab kept the `C ` decoration forever until the terminal itself was recycled.
- **Root cause** — `kanban-hooks/kanban-stop.py`'s `delayed_check_and_remove` daemon polls `ps` three times over 1.5 + 2.0 + 3.0 = 6.5 seconds to distinguish a real exit from a turn-end `Stop`. Claude's shutdown sequence (transcript flush, MCP-connection close, `caffeinate` teardown) routinely takes *longer* than that window. The daemon saw `claude` still in the process list on all three checks, concluded "turn-end Stop, not a real exit," and returned WITHOUT calling `_fire_iterm2_tab_clear`. Claude then finished shutting down silently — no further hook fires — leaving the prefix orphaned.
- **`claude_code_cc_aliases.sh` `_cc_launch`** — PRIMARY FIX. After `claude ...` returns (a deterministic signal that the process has exited — no heuristic needed), synchronously `source iterm2_badge_helper.sh && clear_claude_active`. This covers every `cc-*` alias launch across all teams (iOS, Android, Firebase, Academy, Command, DNS, Freelance, MainEvent, Legal, Medical, Finance). Refcount semantics still protect against over-clearing when multiple sessions share a tab.
- **`kanban-hooks/kanban-stop.py`** — SAFETY NET. Extended daemon polling schedule from `[1.5, 2.0, 3.0]` (6.5 s) to `[1.5, 2.0, 3.0, 5.0, 8.0, 13.0]` (32.5 s, Fibonacci-ish). Covers bare `claude` launches (users who skip the cc-alias). A turn-end Stop that's genuinely not an exit still waits the full 32.5 s with `claude` still running and correctly concludes "turn-end" — just with a longer idle daemon. Detached, CPU-cheap.
- **`scripts/onscreen-heal.sh`** — NEW. Shared POSIX shell helper. Defines `_onscreen_heal` which: resolves the caller's tmux `#{client_tty}`, scans every pane in the caller's current tmux WINDOW (not the whole session — a sibling window's Claude would be a separate iTerm2 tab and should not suppress healing) for a live `claude` process, and if none is found strips the `C ` prefix via `scripts/iterm2_tab_title_prefix.py --deactivate` and removes the stale refcount file. The strip+rm pair is wrapped in the same `flock` (or `mkdir` spin-lock fallback) as `set_claude_active`/`clear_claude_active` so a concurrent activate cannot slip a fresh increment between the scan and the strip. Silent no-op on every failure path (not in tmux, helper missing, Python import fails, lock timeout, etc.).
- **12 banner files patched** — `academy/scripts/academy-banner.sh`, `android/`, `command/`, `dns-framework/`, `finance/`, `firebase/`, `freelance/`, `ios/`, `legal/`, `mainevent/`, `medical/` scripts, plus `homebrew-tap/share/templates/team-banner.sh.template`. Each sources `onscreen-heal.sh` once at banner init (fallback `${HOME}/dev-team` → `${HOME}/aiteamforge`), and each `onscreen()` function now calls `_onscreen_heal` after redrawing the banner. User-facing escape hatch: typing `onscreen` in any stuck tab force-heals the prefix.
- **Not changed** — `iterm2_badge_helper.sh` (round-3 logic unchanged), `scripts/iterm2_tab_title_prefix.py` (round-3 logic unchanged), `deploy-to-production.sh` (these files live in-place under `~/dev-team/`, no deploy step needed).
- **Validation** — Unit test: invoked `_onscreen_heal` with `TMUX_PANE` overridden to point at (a) the medical tab where `claude` is running → prefix kept (correct); (b) the training tab with no claude → `C training` → `training` (correct). Refcount self-test still 4/4 green. Syntax: `bash -n` on all banners + `ast.parse` on `kanban-stop.py` + `sh -n` on `onscreen-heal.sh` — all clean.

### Fix: XACA-0209 round 5 — Release/Epic tag filter replaced with Queue-parity search + clickable item tag pills

- **Context** — Round 4 rebuilt the tag filter on pill toggles (mirroring Queue's state filter bar), but that control duplicated functionality the user actually wanted from Queue: a single search field plus clickable tag pills on each item that populate the search. This round completes the UX parity by deleting the pill filter bar entirely and replacing it with the Queue's search pattern.
- **`lcars-ui/index.html`** — Both `*-tag-filter-bar` divs removed. Each section now has a `.release-search-bar` / `.epic-search-bar` containing a `.filter-search-container` with `<input>` + `<button>×` (the same markup the Queue filter uses).
- **`lcars-ui/js/lcars.js`** — Removed the pill-filter machinery wholesale: state (`releaseTagFilterState`, `epicTagFilterState`, `releaseAvailableTags`, `epicAvailableTags`, `RELEASE_TAG_FILTER_KEY`, `EPIC_TAG_FILTER_KEY`), helpers (`loadReleaseTagFilterState`, `saveReleaseTagFilterState`, `loadEpicTagFilterState`, `saveEpicTagFilterState`, `renderTagFilterPills`, `populateTagFilterOptions`, `renderReleaseTagPills`, `renderEpicTagPills`, `toggleReleaseTagFilter`, `toggleEpicTagFilter`, `populateReleaseTagOptions`, `populateEpicTagOptions`), and DOMContentLoaded + section-switch wiring. Replaced with: `releaseSearchText` / `epicSearchText` module-scope strings keyed under new localStorage names (`lcars-release-search` / `lcars-epic-search` — old `*-tags-filter` keys are orphaned rather than migrated, since their `{selectedTags:[]}` shape no longer applies); shared `loadSearchText` / `saveSearchText` / `itemMatchesSearch` / `initSectionSearchBar` helpers; `setReleaseSearchFilter` / `setEpicSearchFilter` state mutators. `displayReleases` and `displayEpics` now apply the client-side search filter before rendering and show a "No releases match …" / "No epics match …" empty state when the filter hides everything.
- **`lcars-ui/js/lcars.js` — item tag pills** — New `buildItemTagsHtml(tags, searchScope)` emits a `.queue-tags` pill row (purple, matching Queue items) for each Release and Epic card, inserted between the card header and body. Pills are XSS-safe (`escapeHtml` + `textContent` via `innerHTML` round-trip on a trusted template) and carry `data-tag` + `data-search-scope` for delegated click routing. `bindItemTagClicks(dashboard)` wires a single dashboard-level click listener (via `dataset.tagClicksWired` idempotency flag) that stops propagation and calls `setReleaseSearchFilter` / `setEpicSearchFilter` — exactly Queue's `createTagsElement` → `setQueueSearchFilter` pattern.
- **`lcars-ui/js/lcars.js` — request shape** — `loadReleases` dropped the `&tags=` URL param; `loadEpics` dropped the `?tags=` URL param. All tag-based filtering now runs client-side after fetch.
- **`lcars-ui/server.py`** — `serve_releases_tags` (GET `/api/releases/tags`) deleted. `serve_epics_tags` (GET `/api/epics/tags`) deleted. `?tags=` query param removed from `serve_releases_list` and `serve_epics_list`. Route dispatch entries removed. Write-path `tags` validation (`handle_create_release`/`handle_update_release`/`handle_create_epic`/`handle_update_epic`) preserved unchanged.
- **`lcars-ui/css/lcars.css`** — Old `.release-tag-filter-bar` / `.epic-tag-filter-bar` / `.release-tag-filter-pill` / `.epic-tag-filter-pill` / `*-pills-empty` rulesets deleted. New `.release-search-bar` / `.epic-search-bar` containers reuse the shared `.filter-search-input` / `.filter-search-clear` classes already styled for Queue — no per-section search CSS needed. `.queue-tag` gained `max-width: 180px` + `text-overflow: ellipsis` + `white-space: nowrap` so legacy 200-char test tags no longer bloat the pill bar on any card (also benefits Queue items; the `title=` attribute carries the full tag string on hover).
- **`lcars-ui/tests/test_server.py`** — Four test classes deleted (`TestServeEpicsTags`, `TestServeEpicsListTagFiltering`, `TestServeReleasesTags`, `TestServeReleasesListTagFiltering`) — the endpoints/filters they covered are gone. Backend suite: 155 → 112 pass.
- **Net** — 7 files changed, **+220 / −904 (−684 lines)**. `node --check` clean.
- **Review follow-ups (folded into this PR)** — (a) `buildItemTagsHtml` rewritten to build pill DOM via `createElement` + `textContent` + `dataset` and serialize via `outerHTML` — matches Queue's `createTagsElement` pattern and guarantees no tag value ever reaches an attribute-context interpolation (the original `escapeHtml` did not escape `"` / `'`, leaving a theoretical attribute-escape path if a tag ever contained a double-quote). (b) `runMigration` now one-shot-cleans the orphaned `lcars-release-tags-filter` / `lcars-epic-tags-filter` localStorage keys from rounds 3–4 so stale pill-filter JSON doesn't sit in user storage indefinitely.

### Fix: XACA-0209 round 4 — Release/Epic tag filter rebuilt on Queue-parity pill UI (finishes the feature to spec)

- **Context** — The original XACA-0209 acceptance criterion was "mirror the Queue tab's filter UI/UX". The implementation diverged to a `<select multiple>` control instead of the Queue's click-to-toggle pill pattern. Three prior debug rounds patched around that divergence (size, whitespace match, stale-state heal) but the underlying UI still did not match what the spec asked for. Round 4 replaces the `<select>` with pill divs that structurally and visually mirror `.filter-pill` from the Queue filter.
- **`lcars-ui/index.html`** — Both tag filter bars now contain a `<div class="filter-row release-tag-filter-pills" id="release-tag-filter-pills">` (and epic equivalent) instead of `<select multiple>`; the "Click tags to toggle…" hint span is removed (redundant once the control looks like a pill bar). Containers carry `role="group"` / `aria-label` for screen readers.
- **`lcars-ui/js/lcars.js`** — `populateReleaseTagOptions` / `populateEpicTagOptions` now delegate to `renderReleaseTagPills` / `renderEpicTagPills`, which build `<div class="filter-pill release-tag-filter-pill">` (or `epic-tag-filter-pill`) per tag with `role=button`, `tabindex=0`, `aria-pressed`, and keyboard (Enter/Space) activation. Click/keyboard handlers call new `toggleReleaseTagPill` / `toggleEpicTagPill` helpers that mutate `selectedTags`, persist via the existing `save*TagFilterState` helpers, re-render pills (cheap, no re-fetch), and reload the list. Deleted: `applyReleaseTagFilter`, `applyEpicTagFilter`, `updateReleaseTagFilterDropdownStyle`, `updateEpicTagFilterDropdownStyle`, `enableClickToggleOnMultiSelect` — all orphaned by the new control. DOMContentLoaded wiring for the removed helpers is dropped.
- **`lcars-ui/css/lcars.css`** — Old `.release-tag-filter-dropdown` / `.release-tag-filter-select` / `.epic-tag-filter-dropdown` / `.epic-tag-filter-select` / `.release-tag-filter-hint` / `.epic-tag-filter-hint` rulesets deleted. Replaced with `.release-tag-filter-pill` (teal palette, matching the Releases section accent) and `.epic-tag-filter-pill` (purple palette, matching the Epics section accent), each with an `.active` variant. Layout of the pill container inherits entirely from the existing `.filter-row` rule. Empty-state placeholder (`.release-tag-filter-pills-empty` / `.epic-tag-filter-pills-empty`) replaces the disabled "NO TAGS" option.
- **Tests** — No backend changes; 155/155 backend tests still pass unchanged. `node --check js/lcars.js` clean. Frontend-only change.
- **Review follow-ups (folded into this PR)** — (a) `.filter-pill:focus-visible` rule added so keyboard-navigated pills show a visible outline (mirrors the `.blocker-pill:focus` pattern already in the codebase); benefits the Queue filter pills too since they share the base class. (b) Shared `renderTagFilterPills` / `populateTagFilterOptions` helpers extracted — per-section `renderReleaseTagPills` / `renderEpicTagPills` and `populateReleaseTagOptions` / `populateEpicTagOptions` reduce to thin adapters. (c) Toggle helpers renamed `toggle{Release,Epic}TagPill` → `toggle{Release,Epic}TagFilter` for naming parity with Queue's `toggleQueueFilter`. (d) Replaced `container.dataset.tags` JSON.parse round-tripping with module-scope `releaseAvailableTags` / `epicAvailableTags` — no state-on-DOM, one source of truth.

### Fix: iTerm2 Claude Code tab indicator — stale ITERM_SESSION_ID in tmux (XACA-0214 round 3)

- **Symptom** — After Round 2 (PR #248) switched the render channel to the iTerm2 Python API, the `C ` indicator was still missing from every academy persona tab. Only the Startup tab ever decorated — and it accumulated a wildly inflated refcount (18+) because every other tab's hooks were quietly incrementing it instead of their own.
- **Root cause** — `ITERM_SESSION_ID` is **stale** inside tmux panes in the academy fleet. The academy tmux server is spawned from the Startup iTerm2 tab, so every pane it hosts (and every Claude Code subprocess under those panes) inherits Startup's `ITERM_SESSION_ID` regardless of which iTerm2 tab actually displays the pane. Every `SessionStart` hook from every persona tab therefore targeted Startup. Live evidence: `echo $ITERM_SESSION_ID` inside the medical tab returned Startup's UUID while `tmux display-message -p "#{client_tty}"` returned `/dev/ttys020`, which the iTerm2 API correctly resolved to medical's session UUID.
- **`scripts/iterm2_tab_title_prefix.py`** — Added a tmux-aware target resolver. When `$TMUX` and `$TMUX_PANE` are set, the helper runs `tmux display-message -p -t "$TMUX_PANE" '#{client_tty}'` and matches the result against iTerm2 sessions' `tty` variable to find the correct tab. Falls back to the Round-2 `ITERM_SESSION_ID` path only when not in tmux (pristine iTerm2 sessions). All failure paths remain silent exit 0 — best-effort UI decoration must never break hooks.
- **`iterm2_badge_helper.sh`** — `_iterm_tab_id` uses the same tmux client_tty resolution as the Python helper so refcount files are keyed per-iTerm2-pane instead of per-stale-ITERM_SESSION_ID. Without this, all persona tabs' refcounts would continue to collide on Startup's key even after the render path was fixed.
- **`academy/terminals/iterm2/claude-code-profile.json`, `homebrew-tap/share/scripts/aiteamforge-claude-code.json`** — **Removed.** The `AITeamForge Claude Code` Dynamic Profile was a Round-1 artifact; its sole non-inherited feature was `Custom Tab Title: \(user.claude_active)\(session.name)`, which Round 2 documented as unreachable because `tab.titleOverride` is set on every academy tab by `iterm2_window_manager.py:278`. Dead code. Round-3 removes the source, the tap copy, the deploy-to-production.sh section, and the deployed file under `~/Library/Application Support/iTerm2/DynamicProfiles/aiteamforge-claude-code.json`.
- **`deploy-to-production.sh`** — Dropped Section 6 (iTerm2 Dynamic Profile deploy). `aiteamforge-lcars.json` is unaffected — it's deployed by the tap installer (`install-kanban.sh`), not by this script.
- **`scripts/hooks/post-merge`** — Removed the now-dead `academy/terminals/iterm2/` entry from `DEPLOYABLE_PREFIXES`. Surfaced by PR #252 reviewer as a non-blocking follow-up; directory no longer exists after the profile deletion, so the prefix matched nothing. Harmless if left but cleaner to drop.
- **`academy/terminals/docs/iterm2_tab_indicators.md`** — Rewritten for Round 3. Removes the Round-1 Dynamic Profile / OSC 1337 documentation (which was now misleading to future debuggers), adds a Target Resolution section explaining the tmux `#{client_tty}` path, and consolidates a Historical Notes section recording the three rounds.
- **Validation** — Live iTerm2 API probe before the fix: medical tab had `tab.titleOverride='medical'` with no refcount file; Startup tab had `'C Startup'` with refcount 18. After the fix (unit-tested locally): each persona tab's hook resolves to its own iTerm2 session via client_tty, refcount files are created per-pane, prefix appears on the correct tab.

### Fix: XACA-0209 round 3 — Release/Epic tag filter dropdown visibility, whitespace matching, and stale-state auto-heal

- **Symptoms** — (1) Releases dropdown displayed only one tag even when multiple tags existed across releases. (2) Selecting the "spaced" tag on Releases filtered out every release. (3) On Epics, the tag filter could leave all epics hidden with no clickable option to deselect.
- **Root causes** — (1) `<select multiple size="1">` in `lcars-ui/index.html` renders as a one-row listbox; only the first sorted option is visible. (2) `serve_releases_list` / `serve_epics_list` strip the incoming `?tags=` param at parse time but compared against unstripped stored tag values — a tag stored as `"  spaced  "` never matched a filter for `"spaced"`. Same asymmetry caused `serve_releases_tags` / `serve_epics_tags` to list the padded form, so the UI displayed an un-selectable value. (3) `releaseTagFilterState` / `epicTagFilterState` persist in localStorage, but `populateReleaseTagOptions` / `populateEpicTagOptions` never reconciled stale selections with the current available-tag set — a filter for a since-removed tag kept silently hiding everything, with no dropdown option the user could click to deselect.
- **`lcars-ui/index.html`** — `size="1"` → `size="5"` on both `release-tag-filter-select` and `epic-tag-filter-select` so the listbox shows multiple tags without scrolling.
- **`lcars-ui/server.py`** — `serve_releases_list` now strips stored `release['tags']` values at compare time; `serve_releases_tags` strips tag values when building the distinct set. `serve_epics_list` and `serve_epics_tags` get the same treatment. Whitespace-padded tags now collapse symmetrically on both ends. Also — per review — the four write-path handlers (`handle_create_release`, `handle_update_release`, `handle_create_epic`, `handle_update_epic`) now `.strip()` individual tag values so new data is stored clean and the read-path normalization becomes defensive rather than load-bearing.
- **`lcars-ui/js/lcars.js`** — `populateReleaseTagOptions` and `populateEpicTagOptions` now prune `selectedTags` to the intersection with the server's current tag set before re-rendering options; if pruning occurred, state is persisted and the list is reloaded. Stale localStorage filter state self-heals on the next tag-bar populate.
- **`lcars-ui/tests/test_server.py`** — Eight new regression tests: `test_whitespace_padded_tags_deduplicated_by_strip` for both `serve_releases_tags` / `serve_epics_tags`; `test_whitespace_padded_stored_tag_matches_stripped_filter`, `test_tab_character_stored_tag_matches_stripped_filter`, and `test_all_whitespace_stored_tag_never_matches_filter` for both `serve_releases_list` / `serve_epics_list`. Full suite: 155/155.

### Feat: XACA-0220 Phase 3b — daily per-team kanban artifact audit with LCARS surfacing

- **`scripts/daily-artifact-audit.py`** — New Python 3 scanner. Accepts `--team <name>` (or scans all teams by default). Regex matches `X[A-Z]+-####_*.md` files outside `kanban/` trees; excludes `EPIC-*`, `REL-*`, `XLCP-*`. Writes per-team JSON report to `<kanban_dir>/activity/xaca-0220-audit.json`; removes stale report automatically when team turns clean. Supports `--dry-run` (JSON to stdout, no writes).
- **`scripts/install-daily-artifact-audit.sh`** — Idempotent launchd installer. Writes `~/Library/LaunchAgents/com.academy.xaca-0220-audit.plist` and `launchctl load`s it. Fires daily at 04:15 local time via `StartCalendarInterval`. Not auto-run — requires explicit `bash scripts/install-daily-artifact-audit.sh` after merge.
- **`lcars-ui/server.py`** — New `GET /api/artifact-audit` endpoint. Reads the current team's `kanban/activity/xaca-0220-audit.json` and returns it; returns `{"clean":true}` if no report exists.
- **`lcars-ui/js/lcars-artifact-audit.js`** — New 5-minute polling widget. Calls `/api/artifact-audit`; injects a dismissable LCARS-styled amber banner into the HOME section when `clean == false`. All dynamic text inserted via `textContent` (XSS-safe). Exposes `ArtifactAudit.{poll,showBanner,hideBanner}` on `window` for console debugging.
- **`lcars-ui/index.html`** — Loads `lcars-artifact-audit.js` after `lcars-activity.js` (requires `apiUrl()` from lcars.js).
- **`scripts/tests/test_daily_artifact_audit.py`** — 40 unit + integration tests. Coverage: regex detection, exclusions, path helpers, scan_team() with synthetic trees, write_audit_report() lifecycle, CLI main(). Integration: academy dry-run < 5s; all-teams dry-run < 30s.

### Feat: XACA-0220 Phase 3a — pre-commit hook rejecting misplaced kanban artifacts

- **`claude-hooks/reject-misplaced-artifacts.py`** — New pre-commit hook. Rejects staged ADDED files matching `X<TEAM>-<ID>[_<sub>]_<slug>.md` that live outside any `kanban/` directory subtree. Exits 0 for clean commits; exits 1 with an educational message (WHY it matters, HOW to fix, override options) when violations are found. Honors `--no-verify` (git built-in) and `XACA_0220_ALLOW_MISPLACED=1` env override for legitimate edge cases. Skips check in kanban-system repos (detected via `kanban/imported/` or `kanban/.kb-umbrella`).
- **`scripts/hooks/pre-commit`** — Shell wrapper that installs via `scripts/install-git-hooks.sh` for the dev-team repo itself. Resolves the Python hook source from the git common dir so it works from worktrees.
- **`scripts/install-hooks-to-team-repos.sh`** — New installer. Deploys `reject-misplaced-artifacts.py` as a pre-commit hook to all 6 affected team repos (dev-team, iOS/DEV, Android/develop, Starwords/develop, appPlanning/develop, LifeBoard/develop). Idempotent: overwrites if ours, chains if existing hook is foreign, skips if already chained. Safe to re-run.
- **`deploy-to-production.sh`** — Added section 7: calls `install-hooks-to-team-repos.sh` during full deployment. Compatible with `--dry-run` and `--only-file` filters.
- **`scripts/hooks/post-merge`** — Added `claude-hooks/` and `scripts/hooks/` to `DEPLOYABLE_PREFIXES` so auto-deploy notices changes to hook files on merge (XACA-0214 post-merge allowlist drift pattern).
- **`tests/test-reject-misplaced-artifacts.py`** — 52 unit + integration tests covering all 7 spec cases plus error message content, deploy logic, override behavior, tightened slug regex (XACA-0220-010), and nearest-kanban-ancestor suggestion (XACA-0220-011).
- **Why** — XACA-0220 Phase 1+2 relocated 80 orphaned plan docs. Without a gate, agents will drift them back. The hook installs at commit time and fires before any push.
- **Post-review refinements (XACA-0220-010 and -011):**
  - Slug regex tightened from `.+` to `[A-Za-z0-9_-]+` — rejects slugs containing whitespace or punctuation that would never be a real kanban artifact name, while preserving coverage for SCREAMING_SNAKE legacy filenames (e.g. `XFSW-0047-008-README.md`) and `-B` style alpha ID suffixes. ID pattern now accepts a single uppercase-letter suffix (e.g. `XFSW-0016-B`) in addition to numeric subitem suffixes.
  - Error message now suggests the nearest `kanban/` ancestor directory for the `git mv` hint rather than always pointing at top-level `kanban/` — e.g., a file at `lcars-ui/docs/X…_foo.md` gets a suggestion of `lcars-ui/kanban/X…_foo.md` when that subtree exists, falling back to top-level `kanban/` otherwise.

### Fix: XACA-0209 — Release/Epic tag filter click-to-deselect

- **`lcars-ui/js/lcars.js`** — Tags in the Releases/Epics tag filter dropdowns could be selected but a plain click would not deselect them. Native `<select multiple>` requires Ctrl/Cmd-click to toggle, contradicting the "Click selected to deselect" hint shown beside each filter. Added a shared `enableClickToggleOnMultiSelect` helper that intercepts `mousedown` on options, calls `preventDefault()`, toggles `option.selected`, and dispatches a `change` event. Wired once at `DOMContentLoaded` for both tag filters.
- **Why** — Native multi-select UX contradicted the documented UI hint. Minimal mousedown interceptor restores the promised click-to-toggle behavior without replacing the native control.

### Fix: iTerm2 Claude Code tab indicator — redesign render channel to API (XACA-0214 round 2, PR #248)
- **Symptom** — After PR #242 landed the deployment fix for the iTerm2 Dynamic Profile, the Claude Code `C ` indicator still did not appear on any tab in the academy fleet. Live iTerm2 API inspection (`tab.async_get_variable("titleOverride")`) showed every academy tab had a `tab.titleOverride` set (e.g., `medical-2`, `engineering`, `LCARS`) — these are emitted by `academy-startup.sh` during the tmux attach via `\033]0;<label>\007`. iTerm2 **completely bypasses** profile-level `Custom Tab Title` formats whenever any title override is set. The original XACA-0214 design therefore only worked on pristine tabs with no prior title activity — never in the academy fleet where every tab has a label.
- **Root cause** — Architectural clash between two independent title-source mechanisms. The original feature assumed `Custom Tab Title: \(user.claude_active)\(session.name)` would render unconditionally when `user.claude_active` was set via OSC 1337. In reality, iTerm2 evaluates Custom Tab Title **only when** `tab.titleOverride` is unset. The feature was tested in isolation on fresh tabs, not in the real fleet environment.
- **`scripts/iterm2_tab_title_prefix.py`** — New Python helper. Connects to iTerm2's Python API, finds the session matching `ITERM_SESSION_ID`, reads `tab.titleOverride`, and prepends/strips the `"C "` prefix. Idempotent (activate twice is a no-op, deactivate on unprefixed title is a no-op). Silent exit 0 on every failure path (no iTerm2 API, no venv python3, unresolvable session UUID, import errors) — best-effort UI decoration must never break hooks.
- **`iterm2_badge_helper.sh`** — Replaced three `iterm2_set_user_var claude_active ...` call sites with `_fire_claude_tab_prefix --activate` / `--deactivate`. The new internal helper `_fire_claude_tab_prefix` resolves the Python interpreter (preferring `~/dev-team/.venv/bin/python3` because it has the `iterm2` PyPI package; Homebrew python3 does NOT by default) and invokes the title-prefix script. Refcount/lock/atomic-write logic unchanged. `_fire_claude_tab_prefix` added to the `export -f` list for consistency with other internal helpers.
- **`academy/terminals/docs/iterm2_tab_indicators.md`** — Added round-2 redesign notice at the top pointing readers to the new Render Channel section; added a new "Round-2 Render Channel (current)" section that documents the API-based flow, the override-bypass reason the redesign was needed, the venv-preferred python3 path resolution, and the silent-fallback contract. Legacy Detection Mechanism section retained for historical context with a cross-reference to the round-2 notice.
- **Dynamic Profile** (`academy/terminals/iterm2/claude-code-profile.json`) — Retained but effectively dormant. The `iterm2_set_user_var` OSC 1337 path is still in the helper (used by `set_claude_badge` / `clear_claude_badge` for a different user variable), so users running on pristine tabs outside the academy fleet with a profile that references `user.claude_active` could still see rendering via the original path. Not relied upon.
- **`academy-startup.sh`** — Unchanged. The round-2 design deliberately does not touch startup-time tab labeling because the API helper co-exists with academy's existing `\033]0;label\007` scheme.
- **Validation** — Live end-to-end flicker test via three activate/deactivate cycles against a real academy tab (`medical-2`); each cycle visibly toggled `C medical-2` ↔ `medical-2` within ~200ms, user-confirmed visible. Helper self-test (`bash iterm2_badge_helper.sh test-refcount`) passes 3/3. Syntax clean (`bash -n` + `python3 -c "import ast; ast.parse(...)"`.

### Docs: PR workflow — add branch-freshness check before create and merge

- **`claude/CLAUDE.md`** — Two additions to prevent merging stale PRs that silently diverged from `develop` during the test/review cycle. (1) Standard Development Workflow now inserts `git fetch origin develop && git rebase origin/develop` between commit and push (new step 3). Catches drift when feature work spans hours or days before the first push. (2) Parallel Dual-Gate Monitoring Loop adds Gate 4 after the subitem sweep: `gh pr view <N> --json mergeStateStatus` — if `BEHIND`, auto-runs `gh pr update-branch <N>` and breaks out; caller re-spawns both bots, re-seeds both `LAST_*_AT` timestamps, and re-enters the loop so the final approvals are against the fresh base. Critical-notes bullet mirrors the existing CHANGES_REQUESTED guidance.
- **Why** — Prior flow merged whatever the bots last approved, which could be a stale base. Gate 4 guarantees the merged commit is against current `develop` at the moment of merge; the pre-push rebase keeps the bots from burning cycles on an obsolete branch in the first place.
- Synced `~/.claude/CLAUDE.md` from the tracked copy (deploy-to-production.sh is manual per prior drift pattern).

### Chore: XACA-0220 Phase 2 — Relocate Academy kanban artifacts to canonical paths
- **Scope** — 21 Academy plan docs/specs/test-reports previously scattered across `docs/specs/` (15 files), `lcars-ui/docs/` (2), `homebrew-tap/share/lcars-ui/docs/` (2 — mirror), `homebrew-tap/tests/` (1), and `fleet-monitor/docs/` (1) are now in `kanban/` using the `XACA-NNNN_slug_with_underscores.md` convention.
- **Git moves** — 19 renames via `git mv` preserve full git history. 2 deletions remove `lcars-ui/docs/` and `homebrew-tap/share/lcars-ui/docs/` copies that were identical (deduplication; `homebrew-tap/share/` is a deploy mirror of `lcars-ui/docs/`).
- **Phase 1 cleanup** — Deleted 21 untracked copies from `kanban/imported/` (gitignored staging area used in Phase 1). Removed now-empty `kanban/imported/` directory tree.
- **Collision handling** — `XACA-0020`, `XACA-0031`, and `XACA-0074` each had an existing canonical `kanban/` file (post-implementation docs). Incoming original specs landed with `_SPEC` suffix to avoid collision; both the spec and implementation doc are now preserved together in `kanban/`.
- **Reference fixes** — Updated `docs/ONBOARDING_GUIDE.md` and `docs/QUICK_REFERENCE.md` to point at new `kanban/XACA-0024_multi_machine_onboarding_spec.md` path. Fixed internal cross-references inside `kanban/XACA-0019_rename_blocked_to_pause.md`.
- **Backup** — `kanban-backup.py --backup --force` confirms 17 additional items backed up; 0 errors.

### Fix: XACA-0139 dual-gate review feedback (PR #245)

- **`homebrew-tap/share/scripts/agent-panel-display.sh`** — `get_board_file()` was syntactically broken. The subagent that added `# xaca-0139:allowed` markers placed inline comments AFTER the `\` line-continuations in a multi-line `for search_dir in \ … \ ; do` construct; `\ ` followed by `#` is not a valid continuation, so both `bash -n` and `zsh -n` rejected the function and it never ran at runtime. Refactored to a `search_paths=( … )` array with markers on the line ABOVE each tagged path — the loop is now valid in bash and zsh, all markers remain adjacent to their hits per the BATS guard's detection rule.
- **`homebrew-tap/fleet-monitor/plugins/main-event/plugin.yaml`** — two bugs on the same file. (a) `mounts:` mixed a YAML sequence entry (`- path:`) with a mapping entry (`dashboards_dir:`) at the same level, which neither `yq` nor `yaml.safe_load` accepts; promoted `dashboards_dir` to a top-level key (consistent with `plugins.js` `_resolveFromManifest`, which checks `manifest[key]` first). (b) `dir: "./plugins/main-event/public"` and `dashboards_dir: "./plugins/main-event/dashboards"` produced double-nested paths after `path.resolve(pluginDir, …)` (pluginDir is already `…/plugins/main-event/`); the static mount silently served nothing. Corrected to `./public` and `./dashboards`.
- **`homebrew-tap/libexec/installers/install-team.sh`** — `_ensure_org_config` now sanitizes `_name`, `_short`, `_domain` via a `_sanitize_free_text` helper that strips `|`, `"`, `\`, and control chars before using them in sed substitutions and the inline-fallback YAML heredoc. A `|` in a display name would have broken the sed delimiter; a `"` would have produced invalid YAML in the inline fallback. The slug was already sanitized.
- **`homebrew-tap/fleet-monitor/server/lib/plugins.js`** — `_loadPlugin(slug)` now validates `slug` against `^[a-z0-9][a-z0-9-]*$` and confirms the resolved `pluginDir` starts with `PLUGINS_ROOT + path.sep`. `organization.yaml` is user-writable, so a crafted slug like `../../etc` is untrusted input; both checks log-and-refuse, no crash. Defense-in-depth — the regex is the primary gate; the path-traversal check is a belt-and-suspenders backstop.
- **`homebrew-tap/tests/xaca-0139-debrand-guard.bats`** — forbidden pattern extended to `[Mm]ain ?[Ee]vent|MainEvent|MAIN ?EVENT|[Dd]ouble[Nn]ode|doublenode|DOUBLENODE` so all-caps forms are now detected. New survivors surfaced (`CLAUDE_MAINEVENT_THEME` env-var references in `install-team.sh` and `share/templates/claude/statusline-command.sh`) — justified as the stable `CLAUDE_<TEAM_SLUG>_THEME` naming convention and individually annotated.
- **Impact** — Bot tester and reviewer both issued REQUEST_CHANGES. All 4 kanban `[Review]` subitems (XACA-0139-009, 010, 011, 012) addressed inline and closed; kb-sweep clean (12 of 12).

### Feature: Organization-identity parameterization — AITeamForge framework de-branded (XACA-0139)

- **Why** — The shipped tap hard-coded "Main Event", "MainEvent", "DoubleNode", and "doublenode" strings across 150+ files in `libexec/`, `share/`, and `fleet-monitor/`. Any non-Main-Event install saw the wrong paths, wrong team taxonomy, wrong dashboards, and wrong skills. Introduces an "organization identity" config layer (the implicit fourth axis, complementing Specialty + Theme + Purpose from XACA-0130) so the same framework ships as client-agnostic and each install configures its own org identity at setup.
- **`homebrew-tap/share/config/organization.yaml.example`** — New shipped template. Defines `organization.{slug,name,display_short,domain}`, `paths.{projects_root,shared_dev_root}`, `plugins.enabled[]`, and optional per-integration blocks (jira/confluence/bitrise/etc.). Users copy to `~/.aiteamforge/organization.yaml` at install time.
- **`homebrew-tap/libexec/lib/aiteamforge-org-paths.sh`** — New shell resolver. Nine public helpers (`_aiteamforge_org_slug`, `_aiteamforge_org_name`, `_aiteamforge_org_display_short`, `_aiteamforge_org_domain`, `_aiteamforge_org_projects_root`, `_aiteamforge_org_shared_dev_root`, `_aiteamforge_org_plugin_enabled`, `_aiteamforge_org_integration_get`, `_aiteamforge_org_config_path`). `set -u`-safe, yq-first with python3+PyYAML fallback, cached on first call.
- **`homebrew-tap/share/kanban-hooks/aiteamforge_org_paths.py`** — Python mirror of the shell resolver. Matching API + module-level cache with path-based invalidation and `force_reload` override.
- **`homebrew-tap/libexec/lib/{aiteamforge,kanban}-paths.sh`** — Consumed the resolver. `kanban-paths.sh` reduced to zero hardcoded client-name strings. `aiteamforge-paths.sh` team-data table now composes paths from `_aiteamforge_org_shared_dev_root` + `_aiteamforge_org_name`; remaining literals are either backward-compat fallbacks for pre-migration Main Event installs or project-directory identifiers (`MainEventApp-iOS`, `DoubleNode/…`) that will relocate into plugins in a follow-up.
- **`homebrew-tap/libexec/commands/aiteamforge-migrate{,-check}.sh`** — Source the resolver and append the active org slug to the migration TEAMS array so non-Main-Event orgs get first-class migration coverage. Legacy `"mainevent"` entry retained for backward-compat.
- **`homebrew-tap/libexec/installers/install-team.sh`** — New `_ensure_org_config()` step prompts for slug/name/display_short/domain on fresh install and writes `~/.aiteamforge/organization.yaml` from the shipped example (skipped when `AITEAMFORGE_ORG_CONFIG` env override is set — keeps CI/test paths non-interactive).
- **`homebrew-tap/share/kanban-hooks/{aiteamforge_paths,kanban_utils,kanban-backup}.py`**, **`homebrew-tap/share/scripts/{init-agent-panel-json.py,kanban-reset.py,display-agent-avatar.sh,lcars-tmp-dir.sh,agent-panel-display.sh,aiteamforge-team-paths-wizard.py,fleet-reporter.sh}`** — Resolver integration. `init-agent-panel-json.py` inline team dict replaced with `DEFAULT_TEAMS` import; generic example slugs (`myproject`) replace client-specific ones in help text. The critical empty-teams→DEFAULT_TEAMS guard (from commit `7cf5afea`) was preserved verbatim.
- **`homebrew-tap/plugins/main-event/`** — New opt-in plugin layer (manifest `plugin.yaml` + `README.md` + `skills/`). Activated via `plugins.enabled: ["main-event"]` in `organization.yaml`. Scaffolding only for now — ME-specific skills (Main Event CR, RELNOTES, Center Management, Marketing Summary, Weekly Reports, etc.) live in the dev mirror `~/dev-team/skills/` and were never shipped in the tap; the plugin layer is the target for future productization.
- **`homebrew-tap/share/templates/{aliases/cc-aliases.sh,aliases/kanban-aliases.sh,aliases/agent-aliases.sh,claude/claude-md-global.template,claude/statusline-command.sh,kanban/kanban-helpers.template.sh,secrets.env.template,team-project-startup.sh.template}`** — Client-name literals replaced with `{{ORG_NAME}}`, `{{ORG_SLUG}}`, `{{SHARED_DEV_ROOT}}` placeholders (mustache style — matches existing `{{TEAM_ID}}` / `{{AITEAMFORGE_DIR}}` convention). `claude-md-global.template` stripped of Main-Event-specific content (DNS/DNSError patterns, FunCard examples, iOS-specific RELNOTES format, App Store sections) — that content is reserved for the `main-event` plugin's future CLAUDE.md contribution.
- **`homebrew-tap/fleet-monitor/plugins/main-event/`** — New conditional UI layer. Moved 12 ME/DN dashboard files (`mainevent.html`, `doublenode.html`, `lcars-mainevent-app.js`, etc.) via `git mv` so history is preserved. Plugin `plugin.yaml` declares `page_routes` and `dashboards_dir`; `server/lib/plugins.js` reads `~/.aiteamforge/organization.yaml`, loads each enabled plugin's manifest, mounts its static dir, and merges its dashboard/division definitions into the core config. `server/server.js` hardcoded `/mainevent`/`/doublenode`/`/lcars/mainevent`/`/lcars/doublenode` routes removed — they now register only when the plugin is enabled. `server/routes/dashboards.js` returns 403 on `PUT`/`DELETE` to plugin-owned dashboard IDs. `js-yaml ^4.1.0` added to `server/package.json` with graceful degradation if absent.
- **`homebrew-tap/tests/xaca-0139-debrand-guard.bats`** — New BATS test that fails CI if `[Mm]ain ?[Ee]vent|MainEvent|[Dd]ouble[Nn]ode|doublenode` appears in `libexec/`, `share/kanban-hooks/`, `share/scripts/`, `share/templates/`, or `bin/` without an adjacent `# xaca-0139:allowed — <reason>` marker. ~153 justified survivors across 15 files are individually annotated (backward-compat fallbacks, bootstrap `DEFAULT_TEAMS` dicts, permanent team-slug constants, `except ImportError:` resilience paths). Test passes clean; any unannotated leak introduced in a future change fails the gate.
- **`homebrew-tap/docs/ORGANIZATION_CONFIG.md`** — New documentation (schema, setup, field reference, plugin enablement, shell + Python API tables, migration note for existing Main Event installs, verification section referencing the BATS gate).
- **`homebrew-tap/docs/{USER_GUIDE,TEAM_REFERENCE,TEAM_CONFIGURATION,INSTALLATION,QUICK_START,SETUP_WIZARD,ARCHITECTURE,ADDING_A_TEAM,TROUBLESHOOTING,shell-installer,adding-a-python-dep}.md`** — Swept for Main-Event-specific examples; surviving references now describe `mainevent` as a stable team-slug identifier with an `organization.yaml`-defined display label.
- **Backward compatibility** — Existing Main Event installs that have not yet run the `organization.yaml` setup step continue to work via legacy case-arm fallbacks (`"mainevent"` → `/Users/Shared/Development/Main Event/…`). The resolver falls back to the shipped `.example` when no active config is found. `kb-sweep XACA-0139` → 8 of 8 subitems resolved.
### Docs: XACA-0219 retrospective + EMH knowledge entries K039/K040 for stub cleanup
- **`kanban/XACA-0219_aiteamforge_stub_cleanup_RETROSPECTIVE.md`** — Retrospective for XACA-0219. Documents what went well (forensics-first discipline, backup-before-delete, batched [Review] fix commit, auto-regex CHANGELOG conflict resolution), what went wrong (mtime-only classification was misleading; branch diffed against local not remote develop; `gh pr merge --admin` blocked by worktree), and two reusable patterns (process audit protocol; `gh api -X PUT` merge bypass).
- **`academy/knowledge/emh/k039-mtime-vs-process-audit-classification.md`** — K039: Mtime alone is insufficient to classify a directory as "live in use." Recent mtime is consistent with both persistent writers AND one-time human events (e.g., interactive session with bad env var). Always cross-check with lsof/ps/launchctl before concluding "live." Includes a 4-row decision matrix.
- **`academy/knowledge/emh/k040-gh-pr-merge-worktree-conflict.md`** — K040: `gh pr merge --admin` does a local git checkout of the target branch post-merge; fails with "fatal: 'develop' is already used by worktree" if develop is checked out in another worktree. Workaround: `gh api -X PUT repos/{owner}/{repo}/pulls/{N}/merge` bypasses local checkout entirely. Companion to K031 (which covers the source-branch variant of this failure).
- **INDEX updates** — Registered K039/K040 in `academy/knowledge/emh/INDEX.md`, mirrored to `kanban/knowledge/emh/INDEX.md`, and added cross-team entries to `kanban/knowledge/TEAM/INDEX.md`.

### Docs: Condense global `CLAUDE.md` from 50 KB → 27 KB (under 40 KB recommendation)
- **`claude/CLAUDE.md`** — Global user-instructions file was running 50,376 bytes / 1,112 lines, well above the 40 KB soft ceiling Anthropic recommends. Every byte above that is context re-paid on every session for every agent across every project. Condensed to 27,287 bytes / 589 lines (−45.8%) without removing a single load-bearing rule. Cuts targeted verbosity and duplication: worktree rules were stated three times in different frames → consolidated into one authoritative block; the reviewer-facing PR Review Workflow section was ~70% duplicate of the author-facing PR Auto-Spawn Workflow → merged with a reviewer's-guide subsection; Git ↔ Kanban team-boundary prose was restated twice → unified under shared team-model tables; the AMB Knowledge Wire section was duplicating what the session-start hook already supplies → compressed to posting rules + circle index. Preserved verbatim or near-verbatim: AITeamForge M3Pro prohibition + remediation order, Pre-Work Verification script, subagent self-removal mandate, three-gate PR merge with seeded `LAST_*_AT` + PID file + 48h timeout, bot login names, `--repo`/`--admin` flag requirements, `reviewDecision` and `echo | jq` gotchas, team ownership tables, Academy exception, Swift safety rules, XcodeGen prohibition, planning-mode golden rule, RELNOTES three-file structure with PROD AppStore-section preservation, `Info.plist` CFBundleVersion-only skip.
- **Dual-path sync** — Copied condensed file to both `~/.claude/CLAUDE.md` (live) and `claude/CLAUDE.md` (tracked, ships via `deploy-to-production.sh`). Per the XACA-0208 pattern, these two paths drift silently because deploy is manual — editing one without the other means fresh installs get a stale CLAUDE.md and the user sees inconsistent agent behavior between machines. Closed the drift on this edit.

### Fix(XACA-0219): Address 5 [Review] subitems from PR #244
- **`claude-hooks/aiteamforge-stub-guard.sh`** (014) — Added explicit branch for `SWEEP_EXIT=2` that emits a distinct "STUB DETECTION TOOL ERROR" warning instead of falling through to the stubs-found block, which produced a misleading near-empty stubs-found message on environment errors.
- **`scripts/detect-aiteamforge-stubs.sh`** (015) — Converted from a full duplicate of `kb-sweep-stubs` to a thin compatibility shim that `exec`s `kb-sweep-stubs` with pass-through args. Eliminates drift risk; backward-compatible exit-code contract preserved with inline comment.
- **`claude/settings.json`** (016) — Added `"timeout": 10` to the `aiteamforge-stub-guard.sh` SessionStart hook entry, matching the convention of existing damage-control hooks and making the session-start impact contract explicit.
- **`claude/CLAUDE.md`** (017) — Reworded "A SessionStart guard hook (`kb-sweep-stubs`)" to "A SessionStart hook (`aiteamforge-stub-guard.sh`, which invokes `kb-sweep-stubs` internally)" to clearly distinguish the registered hook from the detection tool it calls.
- **`docs/kanban/XACA-0219-android-migration-note.md`** (018) — Removed nonexistent `--board android` flag from the Option B `kb-backlog sub add` command; the board is implicit from the XAND-0001 ID prefix.

### Fix: post-merge auto-deploy skipped iTerm2 Claude-Code profile (XACA-0214, PR #242)
- **Symptom** — After PR #241 (XACA-0214 feature) landed on develop, no Claude Code indicator appeared in any iTerm2 tab. Refcount files under `~/.claude/.iterm_tab_refcount/` proved the hooks were firing and writing OSC 1337 `SetUserVar=claude_active` through the tmux DCS passthrough — but iTerm2 displayed nothing because no profile defined `Custom Tab Title: \(user.claude_active)…`.
- **Root cause** — `scripts/hooks/post-merge` (introduced in XACA-0208) gates auto-deploy through a hardcoded `DEPLOYABLE_PREFIXES` allow-list that filters `git diff ORIG_HEAD..HEAD` before invoking `deploy-to-production.sh --only-file`. XACA-0214 added a new deployable source at `academy/terminals/iterm2/claude-code-profile.json` but did not add the containing prefix to the allow-list. When #241 merged, the hook matched nothing in the diff, skipped the scoped deploy, and the Dynamic Profile JSON never reached `~/Library/Application Support/iTerm2/DynamicProfiles/`.
- **`scripts/hooks/post-merge`** — Added `"academy/terminals/iterm2/"` to `DEPLOYABLE_PREFIXES`. Narrower than `academy/terminals/` on purpose: the `docs/` and `logos/` siblings are not deployable, and a broader prefix would cause noisy no-op deploy runs on doc changes.
- **Backfill** — One-time `cp -f` of the source JSON into the reporter's `DynamicProfiles` directory, equivalent to what the auto-deploy would have done at merge time. iTerm2 rescans `DynamicProfiles` periodically; no restart required.
- **User follow-through** — Each clone needs `./scripts/install-git-hooks.sh` once to pick up the fixed hook (git hooks aren't versioned). Existing iTerm2 tabs retain their previous profile — users who want the badge on existing tabs should either open new tabs via *Profiles → AITeamForge Claude Code* or add `\(user.claude_active)\(session.name)` to their current profile's Custom Tab Title per `academy/terminals/docs/iterm2_tab_indicators.md` § Manual Profile Configuration.
- **Known DRY concern (not addressed here, flagged for follow-up)** — `DEPLOYABLE_PREFIXES` must stay in sync with `deploy-to-production.sh`'s actual deployers via nothing stronger than a `# Keep in sync` comment. This bug is exactly that drift class. A `scripts/check-deploy-sources.sh`-style guard that cross-checks the two files would prevent recurrence.

### Test(XACA-0219-009): Integration test matrix for kb-sweep-stubs + guard hook
- **`docs/kanban/XACA-0219-test-report.md`** — 17-test integration matrix covering detection helper, guard hook, settings registration, CLAUDE.md edits, and end-to-end simulation. 15 pass, 1 fail (T6: false positive when explicit SCAN_ROOT is a dev-team subtree — low severity, non-blocking, default usage unaffected), 1 observation (T2: --quiet design intent matches implementation, test spec mismatch). Branch confirmed PR-ready.

### Feat(XACA-0219-007): Add kb-sweep-stubs helper + aiteamforge SessionStart guard hook
- **`kanban-hooks/kb-sweep-stubs`** — Reusable standalone executable (refactored from `scripts/detect-aiteamforge-stubs.sh`). Detects AITeamForge stub directories under `$HOME` using the same sentinel pattern as XACA-0219-001. Adds `--quiet` flag (emits nothing if zero stubs found; exit 0 = clean, exit 1 = stubs present) for hook use. Supports `--human` flag and JSON output. Path-discovery resolution: `~/dev-team/kanban-hooks/kb-sweep-stubs` (production) with worktree fallback.
- **`claude-hooks/aiteamforge-stub-guard.sh`** — SessionStart hook. Invokes `kb-sweep-stubs --human`; emits a clearly-flagged warning block to stdout if stubs are detected. Silent when clean (no output, no session pollution). Warning-only — never auto-deletes, per ABSOLUTE PROHIBITION in CLAUDE.md. Registered in `claude/settings.json` as a second SessionStart hook entry alongside `kanban-session-start.py`.
- **`claude/settings.json`** — Added second `SessionStart` hook entry for `aiteamforge-stub-guard.sh`. Requires `deploy-to-production.sh` to activate on the live `~/.claude/settings.json`.
- **`docs/kanban/XACA-0219-guard-hook-test.md`** — Test evidence: stdout capture from stub-present run (should emit warning) and stub-absent run (should be silent).

### Feat(XACA-0219-006): Remove 4 inert AITeamForge stubs; preserve android for user review
- **Removed:** `~/ios`, `~/firebase`, `~/freelance`, `~/academy` — all 4 classified inert (byte-identical to homebrew-tap canonical, no live writer, no unique data). ~59 MB recovered.
- **Preserved:** `~/android` — contains orphaned XAND-0001 kanban item (seasonpass bugfix, 11 subitems) that conflicts with canonical Android board entry. Requires user decision before removal.
- **Backup verification:** All 5 tarballs verified (SHA256 match + `tar -tzf` integrity) before any deletion. Backups at `~/dev-team-backups/aiteamforge-stubs-20260423/`.
- **`docs/kanban/XACA-0219-removal-report.md`** — Per-tarball verification results, removal timestamps, disk recovery summary.
- **`docs/kanban/XACA-0219-android-migration-note.md`** — Android stub content description, conflict explanation, and three copy-paste-ready options for the user: Discard / Merge / Keep-as-Archive.

### Feat(XACA-0219-005): Safety backup manifest for AITeamForge stub archive
- **`docs/kanban/XACA-0219-backup-manifest.json`** — Backup manifest (committed for audit trail) for 5 tarballs archived to `~/dev-team-backups/aiteamforge-stubs-20260423/` before any deletion. All 5 stubs present: ios (52 files, 15.8 MB), android (56 files, 17.6 MB), firebase (55 files, 18.5 MB), freelance (56 files, 17.3 MB), academy (35 files, 10.7 MB). Total pre-compression: ~80 MB. Archives verified with `tar -tzf`. Critical note: android tarball contains orphaned kanban item XAND-0001 (seasonpass bugfix, 11 subitems) — must be reviewed before android stub is deleted. Other 4 stubs classified as inert (byte-identical to homebrew-tap canonical per XACA-0219-003 report).

### Feat(XACA-0219-003): Forensic report — AITeamForge board writer identified
- **`docs/kanban/XACA-0219-writer-report.md`** — Forensic investigation of Writer A, the process that wrote `~/android/kanban/android-board.json` at 2026-04-20 14:31 PDT and touched `~/academy/kanban/academy-board.json.lock` at 14:30 PDT. Static analysis confirmed: no current code path (kanban-helpers.sh, aiteamforge_paths.py, server.py, kanban-backup.py, or any shell startup script) resolves `android` → `~/android/kanban`; all paths use `/Users/Shared/Development/Main Event/MainEventApp-Android/kanban`. `~/.aiteamforge/team-paths.json` did not exist on Apr 20. Runtime checks: no open file handles, no active processes. Most likely suspect: a stale android agent session (probably `scotty`) running during the XACA-0168 dynamic-paths migration window with an environment where `aiteamforge_team_kanban_dir("android")` fell back to `~/android/kanban`. Canonical activity log for that date shows `scotty` active 9 minutes before the stub write. The stub is currently inert and safe to archive.

### Feat(XACA-0219-004): Scheduler audit — Writer B (persona refresher) identified
- **`docs/kanban/XACA-0219-scheduler-audit.md`** — Comprehensive audit of all persistent job schedulers for sources that could be writing to the 5 AITeamForge stub paths (`~/ios`, `~/android`, `~/firebase`, `~/freelance`, `~/academy`). Findings: zero `com.aiteamforge.*` launchd agents, homebrew tap not installed, no cron jobs targeting stub paths, no shell init persona-copy operations. Writer B identified as a one-time interactive invocation of `aiteamforge-setup.sh` with `AITEAMFORGE_DIR=$HOME` (likely dev testing for XACA-0180 dual-board guardrail work on 2026-04-21). No persistent scheduler to stop — risk is future accidental re-invocation with wrong env var, mitigated by upcoming XACA-0219-007 session-start guard hook.

### Feat(XACA-0219-001): Add AITeamForge stub detection script
- **`scripts/detect-aiteamforge-stubs.sh`** — POSIX-compatible read-only inventory tool. Scans `$HOME` (or an override dir passed as `$1`) for AITeamForge-shaped team stub directories using sentinel pattern: directory name matches a known team name (ios/android/firebase/command/dns/mainevent/freelance/academy) AND contains at least one of `<team>-board.json`, `kanban/`, `personas/`, `config/`, or `releases/` subdirs AND is not a symlink into `~/dev-team`. Outputs JSON per match with keys: path, matched_sentinels, mtime_iso, size_bytes, file_count, has_activity_dir. Supports `--human` flag for readable output. Exits 0 on completion, logs to stderr.
- **Baseline inventory (2026-04-23):** 5 stubs found under `$HOME`: `~/ios`, `~/android`, `~/firebase`, `~/freelance`, `~/academy`. `~/command`, `~/dns`, `~/mainevent` do not exist. All 5 stubs contain both `kanban/` and `personas/` subdirs. Two stubs with recent writes: `~/android/kanban/android-board.json` (2026-04-20) and `~/academy/kanban/academy-board.json.lock` (2026-04-20). All personas files touched 2026-04-21 by a separate batch process. Tap installation check: clean.

### Chore: Dedup `Main Event CR` skill — symlink to Command-repo canonical copy
- **`skills/Main Event CR/`** — Academy was carrying its own tracked copy of `SKILL.md` (51 KB, older technical-framing version). The Command team's dev-team repo at `/Users/Shared/Development/Main Event/dev-team/skills/Main Event CR/` now holds the canonical v4.1.0 rewrite (committed there as `49e62ca`). Academy switches to a symlink pointing at the Command-repo copy so there is only one source of truth for this cross-team skill. Mirrors the existing `skills/Bitrise Build Status` symlink pattern Academy already uses for Command-owned skills.
- **Effect** — Deleted the old tracked `skills/Main Event CR/SKILL.md` (regular file); added `skills/Main Event CR` as a symlink to the Command-repo directory. The plain-language v4.1.0 content rewrite itself is a Command-team commit (`49e62ca`) and is not described further here; from Academy's POV this is a deduplication, not a content change.

### Docs: EMH knowledge captures (K010, K011) + INDEX refreshes
- **`academy/knowledge/emh/k010-subitem-collision-group-under-one-subagent.md`** — New knowledge entry. Captured from XACA-0213 (PR #239). When multiple subitems touch the same function or adjacent lines in the same file, do not dispatch them as separate parallel subagents — group them under one subagent. Sub-001, 002, 004, 005 of XACA-0213 all touched `buildQueueEpicBadge`/`buildQueueReleaseBadge`; parallel dispatch would have produced four conflicting edits to the same 30-line region. Single-subagent dispatch preserved diff integrity.
- **`academy/knowledge/emh/k011-release-epic-symmetry-correctness.md`** — New knowledge entry. Captured from XACA-0209. Mirror-feature pairs (Releases and Epics, iOS and Android, create and update) require explicit symmetry review — each subagent implements only their assigned half, unit tests validate halves in isolation, no one owns cross-cutting consistency. `create_release`/`update_release` shipped missing `isinstance`/`strip` validation that `create_epic`/`update_epic` had; caught only by reviewer holding both sides side-by-side.
- **`academy/knowledge/emh/INDEX.md`**, **`kanban/knowledge/emh/INDEX.md`**, **`kanban/knowledge/TEAM/INDEX.md`** — Tag Index and Entries table refreshed to register K010/K011 (academy) and the corresponding t033/t034/t035 + k037/k038 team-scope entries already present on disk. No content changes beyond index bookkeeping.

### Fix: aiteamforge cleanup follow-ups — CLAUDE.md paths + aiteamforge-paths.sh stdout leak
- **`claude/CLAUDE.md`** — Fixed three `~/aiteamforge/kanban-hooks/subagent-track.py` references to `~/dev-team/kanban-hooks/subagent-track.py`. The former path was from the aiteamforge-product-installed layout; per the M3Pro prohibition, `~/dev-team/` is the sole source of truth on this machine, and the product install directory is forbidden. The mandatory subagent cleanup step was invoking a path that no longer exists after aiteamforge artifacts were removed.
- **`homebrew-tap/libexec/lib/aiteamforge-paths.sh`** — In `_aiteamforge_get_field`'s python3 fallback branch, replaced bare `local value` with a comment explaining why that line was removed. In zsh, `local NAME` with no assignment on an already-local variable (it's already scoped from the earlier jq branch) prints `NAME=...` to stdout, which corrupts the captured return of this function when called via `$(…)`. Recovered from this by removing the redundant re-declaration; added a comment so a future edit doesn't reintroduce it.

### Chore: Sync dev-team → homebrew-tap (tap 0.11.1)
- **`homebrew-tap/share/lcars-ui/CHANGELOG.md`**, **`css/lcars.css`**, **`js/lcars.js`** — Brought to byte-for-byte parity with `lcars-ui/*`. Ships XACA-0213 (tap-to-copy Release/Epic ID chips), XACA-0211 (Epic item display parity with Releases: dim + strike on completed/cancelled), and XACA-0214 (iTerm2 tab Claude vs idle indicators JS hooks) into the tap. No functional changes — pure mirror refresh so fresh installs of the tap pick up changes the primary has carried since the last sync commit (`13c68d98` on 2026-04-22 15:52).

### Fix: `kb-backlog` zsh bad-substitution on OS arg (XACA-0219)
- **Symptom** — `kb-backlog add "..." <priority> "" "" android` (and the same shape on `kb-backlog sub add`) failed in any zsh-sourced Android terminal with `kb-backlog:61: bad substitution`. The function aborted before the jq build, so the item was never added. Most callers omit the 5th positional (OS) so the bug was latent until the Android team tried to add an item with `android` as the OS tag.
- **Root cause** — Two call sites used `${var,,}` for lowercase conversion. That's **bash 4+** syntax; zsh rejects it. The file's shebang is `#!/bin/zsh` and it's sourced into zsh interactive shells, so the wrong dialect slipped past review.
- **`kanban-helpers.sh`** — Replaced `${os_param,,}` (line 3106, inside `kb-backlog add`) and `${sub_os_param,,}` (line 4036, inside `kb-backlog sub add`) with the zsh-native `${(L)os_param}` / `${(L)sub_os_param}` parameter-expansion flags. Swept the file for other bash-only case-conversion patterns (`${var^^}`, `${var,}`, `${var^}`) — zero remaining.
- **Surfaced via** — Investigation of the Android LCARS kanban-is-empty report on 2026-04-22. Same session also turned up the `lcars-ui/server.py` empty-teams gap (fixed below) and spawned XACA-0219 for the broader aiteamforge stub cleanup.

### Fix: LCARS `_build_team_kanban_dirs` empty-list defensive fallback (XACA-0219)
- **Incident** — The Android LCARS server on port 8280 started at 21:11 while `~/.aiteamforge/team-paths.json` was briefly in its empty-teams state (the `{"teams": {}}` fingerprint already documented in the 7cf5afea entry below). `list_teams()` returned `[]`; `_build_team_kanban_dirs()` built `TEAM_KANBAN_DIRS = {}` from that empty iterable without ever hitting its exception branch; every `get_board_file("android")` request fell back to `KANBAN_DIR = ~/dev-team/kanban` and 404'd. The UI rendered a blank board with 60 real items one directory over.
- **Why the existing try/except didn't catch it** — The empty-dict path was "success" from Python's POV (dict comprehension over empty list returns `{}` with no exception). So the hardcoded-dict fallback was unreachable for the exact failure mode that happened most — config present but unpopulated.
- **`lcars-ui/server.py`** — Split the hardcoded table out into `_hardcoded_team_kanban_dirs()` so the fallback path is a function call, not a copy-paste. `_build_team_kanban_dirs()` now (a) captures the `list_teams()` result, (b) returns the real mapping only if the result is non-empty, (c) logs a warning to stderr and falls back to the hardcoded table otherwise. Exception branch gets the same treatment with a distinct warning.
- **Companion fix already landed** — Commit 7cf5afea hardened `aiteamforge_paths.py::load_config()` so empty-teams config files auto-heal into `DEFAULT_TEAMS`. This server.py change is the belt-and-suspenders version: if a server ever does manage to cache `{}` again (bootstrap race, alternate consumer, whatever), the server self-heals instead of serving 404s until someone notices and restarts it.
- **Validation** — Three-case inline test: healthy config → 20 teams; `list_teams()` empty → 3-team hardcoded fallback with correct Android Shared path; `list_teams()` raising → same fallback, different warning.

### Feat: Epic modal tags input — create and edit (XACA-0209-006)
- **`lcars-ui/js/lcars.js`** — `createEpicModals()` now renders a TAGS field in both the Create Epic and Edit Epic modal bodies (before the `modal-error` div), using `id="new-epic-tags"` and `id="edit-epic-tags"` respectively, matching the `modal-field` / `modal-label-hint` / `modal-input` pattern from the Release modal. `showCreateEpicModal()` resets `new-epic-tags` to `''` on open alongside other field resets. `createEpic()` reads `new-epic-tags`, parses comma-separated input into a trimmed array (empty strings dropped), and always includes `tags` in the POST body. `showEditEpicModal()` pre-populates `edit-epic-tags` from `epic.tags` (joined as comma-separated string). `updateEpic()` always sends `tags` in the PUT body (empty array clears all tags on save). Mirrors subitem 003's Release modal implementation exactly.

### Feat: Epics tab tag filter dropdown (XACA-0209-005)
- **`lcars-ui/js/lcars.js`** — Added `EPIC_TAG_FILTER_KEY` constant (`lcars-epic-tags-filter`) and `epicTagFilterState` object (lines ~126-127). Added six functions mirroring the Release filter pattern: `loadEpicTagFilterState`, `saveEpicTagFilterState`, `updateEpicTagFilterDropdownStyle`, `populateEpicTagOptions` (calls `GET /api/epics/tags`), `applyEpicTagFilter` (triggers `loadEpics()`). Section-switch handler updated to call `populateEpicTagOptions()` when entering the epics section. `loadEpics()` updated to append `?tags=…` when `epicTagFilterState.selectedTags` is non-empty (calls `GET /api/epics?tags=…`). DOMContentLoaded init calls `loadEpicTagFilterState()` alongside `loadReleaseTagFilterState()`. All DOM clearing uses `while (select.options.length > 0) select.remove(0)` — no `innerHTML` assignment.
- **`lcars-ui/index.html`** — Added `epic-tag-filter-bar` div between the Epics section-header and `epics-dashboard`. Contains `epic-tag-filter-dropdown` wrapper, TAGS label, `<select id="epic-tag-filter-select" multiple onchange="applyEpicTagFilter()">`, and usage hint.
- **`lcars-ui/css/lcars.css`** — Added `epic-tag-filter-*` CSS block after `release-tag-filter-hint`, mirroring the release block structure with `--lcars-purple` (`#cc99ff`) in place of `--lcars-teal`.

### Feat: Release modal tags input — create and edit (XACA-0209-003)
- **`lcars-ui/index.html`** — Added TAGS field to both the Create Release modal and the Edit Release modal. Plain `<input type="text">` with comma-separated convention, matching the existing `modal-input` / `modal-label-hint` style used throughout all other modal fields.
- **`lcars-ui/js/lcars.js`** — `showCreateReleaseModal()` resets `new-release-tags` on open. `submitCreateRelease()` parses the input into a trimmed, de-duped array and includes `tags` in the POST body when non-empty. `showEditReleaseModal()` pre-populates `edit-release-tags` from `release.tags` (joined as comma-separated string). `submitEditRelease()` always sends `tags` in the PUT body (empty array clears all tags on edit).

### Fix: aiteamforge-paths empty-teams silent-failure fallback
- **Incident** — The Academy LCARS server (port 8203) began returning `404 "No plan document directory configured for team: academy"` for every academy item (first surfaced when XACA-0214's plan doc failed to load in the LCARS UI modal). Root cause: `~/.aiteamforge/team-paths.json` was present on disk but contained `{"schema_version": 1, "teams": {}}` — schema-valid JSON with an empty teams map. `load_config()` then produced `TEAM_KANBAN_DIRS = {}`, failing every team lookup. The asymmetry (only Academy was broken, the other 8 LCARS servers still served academy items correctly) was caused by the module-level `_CONFIG_CACHE` being a per-process startup snapshot — servers that started BEFORE the file was corrupted kept a healthy cache; the Academy server restarted at 20:52 and cached the empty map.
- **`kanban-hooks/aiteamforge_paths.py`** — Changed the fallback guard from `if "teams" not in config:` to `if not config.get("teams"):` so an empty dict triggers `DEFAULT_TEAMS` substitution. The old check only caught a missing key, not a present-but-empty value. Warning message updated from "config has no 'teams' key" to "config has no populated 'teams'" to match the broader condition.
- **`homebrew-tap/share/kanban-hooks/aiteamforge_paths.py`** — Same fix applied to the tap mirror. Must remain byte-aligned with the primary copy.
- **Config restored** — `~/.aiteamforge/team-paths.json` regenerated from `_make_default_config()` (20 teams, academy included). Broken file preserved at `~/.aiteamforge/team-paths.json.broken.20260422-211804` for forensics.
- **Out of scope** — Identifying what process wrote the empty-teams file at 2026-04-22 19:18:36 is a separate investigation; the bug fix makes that class of silent corruption impossible regardless of cause.

### Chore: Remove re-introduced finance-personal LCARS port file
- **`lcars-ports/finance-personal-lcars.port`** — Deleted. This file was originally removed in commit 0977f166 (`chore: Remove deprecated finance-personal LCARS port file`) but re-appeared on disk via some unknown path; this commit re-removes it to match the intended state. The finance-personal port is handled via the finance team's own port file, not this legacy copy.

### Ops + Docs: XACA-0180 stub recurrence cleanup + M3Pro dev-machine rule (XACA-0212)
- **Incident** — Five pre-migration stub kanban boards that XACA-0180 quarantined on 2026-04-21 01:13 UTC were silently regenerated 14 hours later at 15:58 UTC by `homebrew-tap/libexec/installers/install-team.sh`. Forensic trigger: the aiteamforge homebrew tap was built-from-source on the dev machine at 15:07 UTC (51 minutes before the stubs reappeared across legal/legal-default/medical/finance/command teams in a 42-second window — the fingerprint of a multi-team installer loop, not a human).
- **Root cause** — `install-team.sh` at lines 866-892 computes `TEAM_BOARD="$KANBAN_DIR/${TEAM_ID}-board.json"` from a team-root path with no awareness of the profile/subProject subdirectories where the canonical boards actually live (`~/legal/coparenting/`, `~/medical/general/`, `~/finance/personal/`, `/Users/Shared/.../dev-team/` for command). The `if [[ ! -f "$TEAM_BOARD" ]]` check only sees its own computed path, so it always creates a stub when the canonical is elsewhere.
- **Immediate cleanup** — All 5 regenerated stubs quarantined into `quarantine/xaca-0180-stub-stash/` with `.2026-04-22` suffix + SHA-256 meta sidecars + appended "Recurrence" section in the stash's INDEX.md. Canonical boards verified intact (64 + 9 + 6 + 13 = 92 items preserved across the four canonical locations). `kb-quarantine-stub <team>` — the command referenced in `kanban-helpers.sh:1054` warnings — was never actually implemented in XACA-0180, so this round used the same manual procedure the original XACA-0180 cleanup used (SHA + meta + `mv`); shipping the missing command is now a subitem of XACA-0212.
- **`claude/CLAUDE.md`** — Added new top-level section **"🖥️ CRITICAL: Dev Machine Environment Rules"** at the top of the file (above Git Workflow Rules). Hard rule: the `doublenode/aiteamforge` homebrew tap **MUST NEVER** be installed, tapped, or run against real `$HOME` on this M3Pro machine — the dev machine is the development source for the product, and running the shipped product here creates a second source-of-truth that recreates stubs, installs `com.aiteamforge.*` launchd agents, and writes to real user directories. Auto-deploys to live `~/.claude/CLAUDE.md` via the XACA-0208 post-merge hook when this commit lands.
- **Installer fix filed** — XACA-0212 tracks the fix (10 subitems including the missing `kb-quarantine-stub` tool, regression tests, and the mandatory trailing five). Plan doc at `kanban/XACA-0212_installer_profile_awareness.md` (gitignored — kanban files aren't tracked). Design decision: keep detection self-contained in the shell installer rather than source `kanban-helpers.sh` (which may not exist on fresh machines), with a semantic-consistency note to `_kb_check_dual_boards`.
- **Out of scope for this commit** — Actually fixing the installer (XACA-0212 implementation); uninstalling the aiteamforge tap from this specific M3Pro (operational step — requires user approval per the new rule and the uninstall helper at `kanban/XACA-0212_aiteamforge_uninstall.sh`).

### Feat: tmux tab-bar Claude vs idle-shell indicators (XACA-0210)
- **Problem** — With 20+ team tmux tabs per session, there was no visual way to scan the bottom tab bar and see which windows were running Claude Code vs sitting idle at a zsh prompt. Agents in active work and windows you closed hours ago looked identical.
- **Detection** — `window-status-format` uses an extended regex matcher (`#{m/r:^[0-9]+\.[0-9]+\.[0-9]+$,#{pane_current_command}}`) to detect Claude Code, which renames its own process to its version string (e.g. `2.1.117`). A fallback `#{==:#{pane_current_command},claude}` covers alternate installs. Pure server-side format eval — zero shell callout, zero per-refresh cost. Requires tmux ≥ 3.2 (fleet is 3.6a).
- **Visual scheme** — Claude-active windows show an amber `C ` badge (`bg=colour130 fg=colour255`, LCARS palette range 130–220). Idle windows render dim with no prefix. Current window gets `bold` stacked on top of either state. `#[default]` resets bracket every branch to prevent style bleed between tab cells.
- **`claude/tmux.conf`** — New tracked source of truth. Preserves all pre-existing settings from the user's live `~/.tmux.conf` byte-for-byte (mouse, allow-rename off, vi copy-mode keys, six zshrc bindkeys, allow-passthrough, status-right with `@claude_agent`) and appends the new window-status block.
- **`deploy-to-production.sh`** — New `deploy_symlink()` helper (backs up existing plain files, idempotent on re-run, honors `--dry-run`/`--yes`/`--no-backup`). Wired into Section 1 so `~/.tmux.conf` becomes a symlink to `~/dev-team/claude/tmux.conf`. Edits to the tracked file take effect after `tmux source-file ~/.tmux.conf` with no redeploy.
- **`homebrew-tap/libexec/installers/install-claude-config.sh`** — New `install_tmux_conf()` function installs the template to `~/.tmux.conf` on fresh Homebrew-tap installs (backs up any existing plain file). Wired into `install_claude_config()` alongside the other core components so clean machines get tmux indicators automatically.
- **`homebrew-tap/share/templates/claude/tmux.conf`** — Template copy for the tap installer. Matches `claude/tmux.conf` byte-for-byte.
- **`academy/terminals/docs/tmux_configuration.md`** — New reference doc covering detection mechanism, tmux version floor, visual scheme rationale, known limitations (split-pane windows show only the active pane's state), deployment, and troubleshooting.
- **Known limitation (v1)** — `window-status-format` evaluates `#{pane_current_command}` for the window's ACTIVE pane only. In split-pane windows where Claude is in a background pane and the foreground is a plain zsh, the tab shows idle. Acceptable tradeoff; the common fleet pattern is one Claude pane per window.
- **Design notes rejected** — `pane_pid` + `pgrep -P` walk (too expensive per status refresh), `pane_title` sniffing (`allow-rename off` is already set, titles are locked), bare `node` match (too broad — every `npm run`/`ts-node` would false-positive), single-character Unicode glyph like `●` (width-unstable across terminals with many tabs; `C ` is 2 chars, unambiguously 2 cells).
- **Review-driven follow-ups** — `scripts/check-deploy-sources.sh` grep alternation extended to `deploy_(file|directory|symlink)` so the new symlink call participates in the XACA-0208 drift guard (prior check only matched `file|directory`). `install_tmux_conf()` now removes `~/.tmux.conf` if it exists as a symlink before calling `apply_template` — prevents shell redirection from following the link and writing into the tracked source on machines that previously ran `deploy-to-production.sh`. `.github/workflows/deploy-sources-check.yml` gained a `paths` trigger on `homebrew-tap/share/templates/claude/**` plus a diff step that fails CI if `claude/tmux.conf` and the tap template drift apart.
### Docs: Add S018 sulu knowledge entry — gh pr merge nested-worktree gotcha
- **`android/knowledge/sulu/s018-nested-worktree-gh-pr-merge.md`** — New knowledge entry documenting the false-positive `error: '<branch>' is already used by worktree at '<path>'` message that `gh pr merge --delete-branch --admin` throws when run from a child worktree of a nested-worktree setup (kb-run's layout, where the main repo itself checks out `develop` as a worktree and feature branches live as child worktrees under it). Workaround: run the merge from a neutral directory (`/tmp`) with `--repo owner/repo`, and verify actual merge state via `gh pr view --json state,mergedAt` before assuming failure.
- **`android/knowledge/sulu/INDEX.md`** — Entry count bumped 17 → 18. New tag sections added for `gh-cli`, `git`, and `pr-workflow`; S018 also appended to the existing `worktree` and `gotcha` sections (the S018 row was normalized from `worktrees` plural to `worktree` singular to match the existing S004 section rather than introduce a near-duplicate tag pair).
- **Source** — XAND-0619 / PR #293 (Android team, MainEventApp-Android repo). The gotcha was observed during that merge; documented here because the sulu knowledge dir lives in dev-team.

### Feat: Auto-deploy live Claude config on merge to develop (XACA-0208)
- **Root cause** — `deploy-to-production.sh` is a manual, interactive script. When tracked `claude/CLAUDE.md` landed on develop in commit 16d6bf2b (auto-spawn PR workflow restoration), nothing refreshed `~/.claude/CLAUDE.md`, so every agent on the machine continued reading the stale copy and stopped dispatching reviewer/tester subagents. Tracked-vs-live drift was silent and indefinite.
- **`deploy-to-production.sh`** — Added two non-interactive flags: `--yes` skips the confirmation prompt (`ASSUME_YES=true`), and `--only-file <prefix>` (repeatable) scopes the deploy to source paths that either contain the pattern OR are an ancestor directory of the pattern (bidirectional match so `deploy_file` and `deploy_directory` callers both work). New `_should_deploy_source()` helper is called at the top of both `deploy_file()` and `deploy_directory()`; empty filter list means "deploy everything" (backward-compatible with all existing invocations). The directory-source case was caught in review — earlier one-directional substring match silently skipped `skills/` changes because the `deploy_directory` source path doesn't contain the changed filename suffix.
- **`scripts/hooks/post-merge`** — New tracked git hook. Compares `ORIG_HEAD..HEAD` after a merge/pull, filters changed paths through a `DEPLOYABLE_PREFIXES` allow-list (`claude/`, persona dirs, skill dirs, `home-scripts/.zshrc`, alias files, `worktree-helpers.sh`), and invokes the deploy script once with one `--only-file <path>` per matching change plus `--yes --no-backup`. Honors `CLAUDE_DEPLOY_SKIP=1` (opt-out) and `CLAUDE_DEPLOY_DRY_RUN=1` (preview). Never fails the merge — all deploy errors degrade to exit 0 so a broken deploy can't brick `git pull`.
- **`scripts/install-git-hooks.sh`** — New idempotent installer. Copies `scripts/hooks/*` into `$(git rev-parse --git-common-dir)/hooks/` (the main repo's hooks dir, which all worktrees share), sets +x, and supports `--check` mode (exits non-zero if any tracked hook differs from its installed copy) and `--help`. Single install covers all worktrees by design.
- **`scripts/dev-team-setup.sh`** — Wizard now calls `install_tracked_git_hooks()` at the end of Phase 5 so fresh installs get the hook automatically. Also fixed two pre-existing heredoc syntax errors (`$(cat << EOF ... EOF` missing closing `)` on lines ~635 and ~646) that were preventing the wizard from even parsing; caught by running `bash -n` during this task.
- **`claude-config/CLAUDE.md`** — Removed. This file was a silent duplicate of `claude/CLAUDE.md` that had drifted 44 lines behind (missing umbrella-repo and AMB circles sections). `claude/CLAUDE.md` is now the sole source of truth; `deploy-to-production.sh` only deploys from `claude/`.
- **`scripts/check-deploy-sources.sh`** — New CI validator. Parses every `deploy_file`/`deploy_directory` call and every `for X in ~/dev-team/Y/*` loop source in `deploy-to-production.sh`, expands `~/dev-team/` to repo root, and fails if any source path is missing. Includes a regression guard that fails if `claude-config/CLAUDE.md` is reintroduced.
- **`.github/workflows/deploy-sources-check.yml`** — New GitHub Actions workflow. Runs the source check on PRs that touch any deployable path or the deploy script itself, and on pushes to develop. Also `bash -n`-validates all tracked hooks and the installer. Catches drift before merge instead of after.
- **`docs/homebrew-tap/ENVIRONMENT_INVENTORY.md`** — Inventory updated to remove `claude-config/` row and note the single-source-of-truth change with XACA-0208 rationale.
- **Design note** — Considered a GitHub Actions deploy job but rejected: CI runners can't write to a developer's `~/.claude/`. The post-merge hook runs on the developer's own pull, which is when live files actually need to refresh. The workflow stays as a pre-merge drift detector only.

### Fix: _kb_release_sync no longer emits spurious 404 warning for subitems (XACA-0182)
- **Root cause** — `kb-backlog sub done` and `sub cancel` passed the subitem ID (e.g. `XACA-0179-002`) into `_kb_release_sync`, which POSTs to LCARS `/api/releases/sync-item`. LCARS only knows top-level items, so it returned HTTP 404 and the loud-failure branch (added in XACA-0054 to prevent silent drift) printed `⚠️  Release manifest sync FAILED: HTTP 404 from LCARS for <subitem-id>` on every successful subitem closeout. Observed during XACA-0179 closeout.
- **`kanban-helpers.sh`** — `_kb_release_sync` now short-circuits with a silent `return 0` when the supplied ID matches the subitem pattern (`^X[A-Z]{2,4}-[0-9]+-[0-9]+$`, the same regex used by `_kb_resolve_subitem_id` at line 1403). Release manifests track parent items only; the parent gets synced separately when `kb-done` runs on it, so the subitem-level call was always a no-op round-trip.
- **`homebrew-tap/share/templates/kanban/kanban-helpers.template.sh`** — Mirror guard added for defense in depth, even though the template's already-tolerant error handler (XACA-0054 era) silently accepts 404s — the guard avoids the round-trip entirely.
- **`scripts/tests/test-release-sync-subitem-skip.sh`** — New zsh regression test (6/6 PASS) that (a) shadows `curl` with a sentinel-writing mock, (b) asserts subitem IDs short-circuit before curl with empty stderr, and (c) asserts top-level IDs still invoke curl so the guard does not over-trigger.
- **Design note** — Rejected the alternative of silencing HTTP 404 inside `_kb_release_sync` itself: that would also mask genuine "LCARS doesn't know this top-level item" bugs, eroding the loud-failure signal XACA-0054 introduced.

### Chore: Unify kanban backup path to ~/dev-team-backups/ (XACA-0181)
- **Canonical path** — All backup tooling now uses `~/dev-team-backups/` as the single unified backup root; `~/aiteamforge-backups/` references in scripts, docs, and plists have been rewritten to the new path
- **Data migration** — Existing backup archives were migrated from `~/aiteamforge-backups/kanban/` to `~/dev-team-backups/kanban/` as part of this change; no backup data was lost
- **`kanban-backup.py`** — Removed the migration-guard block (the `if old_path.exists(): shutil.move(...)` logic) that previously performed the on-first-run path migration; migration is now complete and the guard is no longer needed
- **Docs updated** — `CHANGELOG.md`, `docs/homebrew-tap/KANBAN_INSTALLER_NOTES.md`, `docs/COMMAND_TEAM_SYNC_PROMPT.md` (reviewed — leading-dot reference left intentionally), and `homebrew-tap/docs/TEST_PLAN.md` updated to reflect the new canonical path

### Fix: install-team.sh no longer pollutes monorepo root with persona files (XACA-0178)
- **`homebrew-tap/libexec/installers/install-team.sh`** — Replaced the equality-only guard on the second persona copy block with a three-way skip: (1) exact path match (existing), (2) TEAM_DIR nested inside TEAM_WORKING_DIR — the Command-team case where TEAM_WORKING_DIR is the dev-team monorepo root that contains TEAM_DIR (NEW), (3) TEAM_WORKING_DIR is itself inside a git work tree (belt-and-suspenders safety net). This prevents persona files from being dropped at the monorepo root on every install, which polluted git status with byte-identical duplicates of tracked files.
- **`homebrew-tap/tests/test-command-nested-workingdir.sh`** — New regression test (18/18 PASS) exercising both guards independently against an isolated fake-tap fixture; covers the parent-dir guard and the git-work-tree guard; verifies personas/ always lands inside TEAM_DIR and never at TEAM_WORKING_DIR root.

### Feat: Allow Epic and Release editing on completed items (XACA-0121)
- **`lcars-ui/js/lcars.js`** — Removed `isCompleted` guard from Epic badge and Release badge click handlers in `createQueueItem()`. Both badges are now always editable, allowing retroactive epic/release assignment on completed items. Reverses the blanket read-only restriction added in XACA-0056 for these two fields.
- **`lcars-ui/css/lcars.css`** — Removed dead `.queue-epic-badge.readonly` and `.queue-release-badge.readonly` CSS selectors (review cleanup)

### Bugfix: Fix worktree switching in kb-run-review, kb-run-test, kb-run-debug (XACA-0118)
- **Shell** — New `_kb_is_correct_worktree()` predicate checks both path (via `pwd -P`) and on-disk branch, replacing `_kb_is_main_worktree` guard in all three `kb-run-*` functions
- **Shell** — `_kb_switch_to_item_worktree` fast path now verifies actual branch matches kanban record before cd'ing; falls through to discovery on mismatch
- **Root cause** — `_kb_is_main_worktree` returned false in any secondary worktree, silently skipping worktree-to-worktree switches; fast path blindly trusted stale kanban path records

### Docs: XACA-0120 Retrospective and Knowledge Capture (XACA-0120)
- **Knowledge** — K009 entry documents AMB REST API `{"data": {...}}` response envelope pattern and curl fallback with MCP transition comments
- **Retrospective** — Post-mortem for circle-scoped ping feature covering parallel subagent execution, the API response format bug caught in QA, and patterns to reuse

### Fix: Activity log displays newest entries first (XACA-0117)
- **Python** — `read_activity_log()` now reverses entries after filtering so newest activity appears at the top of the LCARS timeline

### Bugfix: Activity log agent identity always "unknown" (XACA-0117)
- **Shell** — `_kb_log_activity()` now resolves agent handle from tmux session name via `amb-session-map.json` when `CLAUDE_AGENT_HANDLE`, `CLAUDE_CODENAME`, and `LCARS_SESSION_NAME` env vars are unset (which is always, in agent terminals)
- **Python** — `_resolve_agent_from_tmux()` helper added to `kanban_utils.py`; `log_activity()` calls it as fallback before defaulting to "unknown"
- **Root cause** — The three env vars checked for agent identity were never exported to agent terminal sessions; only `LCARS_SESSION_NAME` was set in LCARS server processes

### Feat: Kanban Activity Log System (XACA-0117)
- **Shell core** — `_kb_item_id_to_team()`, `_kb_get_activity_dir()`, `_kb_log_activity()` in kanban-helpers.sh; fire-and-forget background writes with Perl flock locking; per-item JSON files in `activity/` subdirectory
- **Shell instrumentation** — 34 `_kb_log_activity` call sites across 18 operation categories (item CRUD, status changes, subitem lifecycle, tags, priorities, due dates, JIRA/GitHub links, window claims)
- **Python core** — `log_activity()`, `read_activity_log()`, `get_activity_dir()`, `get_team_from_item_id()`, `get_parent_item_id()` in kanban_utils.py; fcntl locking, atomic writes, pagination and filtering support
- **Server API** — `GET /api/kanban/<item-id>/activity` endpoint with query params: limit, offset, action, agent, subitem filters; pagination metadata in response
- **Server instrumentation** — Activity logging in `handle_update_item()`, `handle_update_subitem()`, `handle_toggle_collapsed()` with old/new value diffing
- **LCARS UI** — `lcars-activity.js` ActivityTimeline slide-in panel with chronological event display, color-coded action categories, agent badges, relative timestamps, filter controls; `lcars-activity.css` LCARS-themed styling
- **Item card integration** — Activity button (◗) in queue item tracking zone, opens ActivityTimeline on click

### Feat: AMB Circles Seeding and Adoption (XACA-0114)
- **`scripts/amb-circle-taxonomy.json`** — New taxonomy mapping 11 discipline circles to 64 agents across all teams; each agent gets 2 circles (primary + secondary); circles are discipline-based not team-based
- **`scripts/amb-circles.sh`** — New helper script abstracting AMB circles API with 8 functions (list, info, create, join, leave, my, seed, enroll); dual-mode (source or CLI); auto-detects agent handle from tmux session; token reads via python3 to avoid hook triggers
- **`scripts/amb-seed-circles.py`** — Python seeder script for bulk circle creation and enrollment; uses curl subprocess to avoid Cloudflare blocking urllib; handles rate limiting, auth errors, and unregistered agents gracefully
- **`claude-hooks/amb-session-heartbeat.sh`** — Personalized circle context: looks up agent's assigned circles from taxonomy and outputs specific circle names instead of generic curl instructions
- **`claude-hooks/amb-heartbeat-check.sh`** — NUDGE 4 now shows agent-specific circles and references helper script functions instead of raw curl commands
- **External agent scouting** — Wire engagement (NUDGE 1) and circle awareness (NUDGE 4) hooks now instruct agents to watch for external agents (handles not in amb-session-map.json) doing work relevant to their circles; agents are told to vouch, follow, and invite external agents by mentioning the circle name in a reply; session-start heartbeat includes the same guidance inline
- **Platform state** — 11 circles created, 37 registered agents enrolled (66 memberships), 27 unregistered agents mapped for future enrollment

### Refactor: AMB Circles post-merge review fixes (XACA-0114 follow-up)
- **`claude-hooks/amb-circle-lookup.sh`** — New shared helper extracting `amb_get_agent_circles()` from duplicated `_amb_get_agent_circles()` in both hook files; follows `amb-reply-tracker.sh` pattern
- **`claude-hooks/amb-session-heartbeat.sh`** — Sources shared `amb-circle-lookup.sh` instead of inline function; bare `except:` replaced with `except Exception:`
- **`claude-hooks/amb-heartbeat-check.sh`** — Sources shared `amb-circle-lookup.sh` instead of inline function; bare `except:` replaced with `except Exception:`
- **`scripts/amb-seed-circles.py`** — Added `--token-holder HANDLE` flag; default token holder auto-detected from first agent in `amb-agents.json` instead of hardcoded `jett-reno`; added executable permission

### Fix: zsh glob error in agent panel crew strip cleanup
- **`scripts/agent-panel-display.sh`** — `render_crew_strip()` used a bare glob (`rm -f /tmp/lcars-crew-*-r*.png`) which crashes in zsh when no files match (zsh evaluates globs before the command runs). Replaced with `(N)` null-glob qualifier to collect matches into an array first, consistent with existing patterns elsewhere in the script (lines 261, 370, 741).

### Feat: Kanban Backup Health Monitor
- **`kanban-backup-health.py`** — Standalone health monitor that independently checks backup freshness and delivers macOS notifications when backups go stale (OK < 20 min, WARNING 20-45 min, CRITICAL > 45 min); also detects backup errors, auto-restores, missing status file, and unloaded launchd job; notification throttling via `health-alert-state.json` (WARNING: 30 min cooldown, CRITICAL: 60 min); CLI flags: `--status` (summary), `--reset` (clear throttle)
- **`com.devteam.kanban-health.plist`** — Dedicated launchd job running every 5 minutes, separate from the backup job so it catches failures even when the backup launchd job stops; logs to `~/dev-team-backups/kanban/health.log`

### Refactor: Migrate finance knowledge to standard kanban path
- **File move** — Moved 19 finance knowledge files from `finance/knowledge/` to `kanban/finance/knowledge/`, aligning with the standard pattern used by legal, freelance, mainevent, and medical teams
- **`kanban-helpers.sh`** — Updated `kb-knowledge-search` knowledge directory path for finance-personal team
- **`fleet-monitor/client/knowledge-reporter.sh`** — Added missing finance entry to `KNOWLEDGE_DIRS` array (finance was not being reported to Fleet Monitor)
- **Prompt files** — Updated knowledge base paths in 4 prompt files (workshop, bar, fca, vault) and 5 persona files (rom, quark-fin, brunt, nog, zek)
- **`kanban/finance/knowledge/rom/INDEX.md`** — Updated 5 self-referencing paths to new location

### Feat: Enforce Review/Test Subitem Completion Governance (XACA-0113)
- **`kanban-helpers.sh`** — `kb-backlog sub cancel` now prints an advisory warning before cancelling any subitem whose title contains `[Review]` or `[Test]` (case-insensitive); warns agents to stop and seek user approval; does not hard-block the operation so users running directly are not impeded
- **`skills/Project Planner/SKILL.md`** — Added Review & Test Subitem Governance section with three-tier cancellation model (Standard/Protected/Mandatory) and rules for protected subitems (v1.9.0)
- **`~/.claude/CLAUDE.md`** — Added "Protected Subitems" subsection to Subitem Completion Protocol; reframed "Non-Blocking Suggestions" as "Post-Merge Work Items" in PR Review Workflow

### Fix: Worktree reset auto-detects main branch and adds error confirmation (XACA-0112)
- **`kanban-helpers.sh`** — Added `_kb_get_main_branch()` helper function that auto-detects the main/development branch per repo; detection priority: (1) check if `remote/develop` exists, (2) `git symbolic-ref` remote HEAD, (3) check for `remote/main` or `remote/master`, (4) fallback to `develop`
- **`kanban-helpers.sh`** — Renamed `_kb_reset_worktree_to_develop()` to `_kb_reset_worktree()` and updated to use `_kb_get_main_branch()` instead of hardcoded `develop`; repos using `main` or `master` as their primary branch now reset correctly
- **`kanban-helpers.sh`** — Added interactive user confirmation prompt (`[y/N]`) on fetch or reset failures instead of silently continuing; checks `/dev/tty` readability before attempting read to suppress zsh error leak in non-interactive contexts
- **`kanban-helpers.sh`** — Updated all 3 call sites (`kb-run`, `_kb_switch_to_item_worktree` x2) to check return code; user abort (return 2) stops the parent operation, soft failure (return 1) warns but continues

### Fix: Retrospective document naming, location, and governance enforcement (XACA-0111)
- **Retrospective file moves** — Renamed 4 Academy retrospectives with mismatched description slugs to match their plan documents; moved XACA-0103 retro from `knowledge/academy/` to `kanban/` with correct naming; moved `docs/amb-proxy-retrospective.md` to `kanban/XACA-0088_amb_per_session_mcp_proxy_RETROSPECTIVE.md`
- **`kanban-helpers.sh`** — Added `kb-retro-path` helper function that programmatically resolves the correct retrospective file path from an item ID (finds plan doc, extracts description slug, constructs canonical path); eliminates manual path construction which caused 12+ naming violations
- **`kanban-helpers.sh`** — Extended `kb-sweep` to validate retrospective file existence and knowledge entry creation when a "Retrospective and Knowledge Capture" subitem is marked complete (advisory warnings, non-blocking)
- **`skills/Project Planner/SKILL.md`** — Updated retrospective subitem instructions to use `kb-retro-path` instead of manual path construction; added explicit prohibition of "captured inline" as justification for skipping knowledge entries; added minimum 1 knowledge entry requirement per retrospective

### Feat: Separate Knowledge Stats and Retrospective Coverage panels (XACA-0108)
- **`lcars-ui/index.html`** — Removed adoption metrics container from Panel 4 (Knowledge Base); added new Panel 5 (Retrospective Coverage) with `data-panel-index="5"` and dedicated `#home-knowledge-adoption` container; added 6th carousel dot
- **`lcars-ui/js/lcars.js`** — Incremented `TOTAL_HOME_PANELS` from 5 to 6; extracted adoption rendering from `_renderHomeKnowledgeStats()` into new `_renderHomeAdoptionStats()` async function with its own debounce/abort/navigation-guard infrastructure; added `case 5` to `renderHomePanel()` switch; updated abort controller logic to cover both panels 4 and 5; added panel 5 to chart resize key map; corrected `renderHomePanel()` JSDoc panel map (added panel 5 entry, removed stale "adoption dashboard" from panel 4 description, updated `@param` range from `0–4` to `0–5`)
- **`lcars-ui/css/lcars.css`** — Added 13 missing `.knowledge-adoption-*` CSS classes: `.knowledge-adoption-panel`, `.knowledge-adoption-overall`, `.knowledge-adoption-overall-label`, `.knowledge-adoption-overall-sub`, `.knowledge-adoption-bar-wrap`, `.knowledge-adoption-bar`, `.knowledge-adoption-teams`, `.knowledge-adoption-team-row`, `.knowledge-adoption-team-name`, `.knowledge-adoption-team-pct`, `.knowledge-adoption-team-detail`, `.knowledge-adoption-empty`, plus responsive breakpoint
- **`lcars-ui/server.py`** — Scoped `_compute_adoption_metrics()` to current team only via `LCARS_TEAM` instead of scanning all `TEAM_KANBAN_DIRS`; falls back to all-teams scan if team not found
- **`homebrew-tap/share/lcars-ui/`** — All four files synced to homebrew-tap distribution copy

### Feat: LCARS DOCS Modal Plan/Retro Toggle (XACA-0105)
- **`lcars-ui/server.py`** — `serve_plan_exists()` now returns `retroExists` field indicating whether a retrospective file exists alongside the plan document; `serve_plan_content()` now filters out `_RETROSPECTIVE.md` files to prevent returning retro content as plan content
- **`lcars-ui/server.py`** — New `serve_retro_exists()` and `serve_retro_content()` endpoints for checking and fetching retrospective documents; routes registered at `/api/kanban/<id>/retro-exists` and `/api/kanban/<id>/retro-content`
- **`lcars-ui/js/lcars.js`** — `showPlanDocModal()` now accepts `retroExists` parameter and renders a PLAN/RETRO tab toggle bar when a retrospective exists; new `switchDocTab()` function handles tab switching with fetch, render, and title updates
- **`lcars-ui/js/lcars.js`** — `checkPlanExists()` stores `data-retro-exists` attribute on DOCS buttons when API returns `retroExists: true`; all `showPlanDocModal()` call sites updated to pass retroExists through
- **`lcars-ui/css/lcars.css`** — New `.plan-doc-tabs` and `.plan-doc-tab` styles with LCARS-themed active states (teal for PLAN, amber for RETRO)
- **`homebrew-tap/share/lcars-ui/`** — All three files synced to homebrew-tap copy

### Fix: Statusline tmux pane targeting and board path resolution (XACA-0110)
- **`claude/statusline-command.sh`** — Added `$TMUX_PANE`-based `-t` pane targeting to `tmux display-message` calls; replaced hardcoded `KANBAN_DIR` board path resolution with `_get_team_kanban_dir()` helper mapping each team to its distributed kanban directory (mirrors `kanban_utils.py` `TEAM_KANBAN_DIRS`)
- **`kanban-hooks/kanban-hook.py`** — Added `$TMUX_PANE`-based `-t` pane targeting to all `tmux display-message` subprocess calls in `_resolve_amb_handle_from_tmux()` and `get_tmux_context()`
- **`kanban-hooks/kanban-session-start.py`** — Added `$TMUX_PANE`-based `-t` pane targeting to all `tmux display-message` subprocess calls in `get_tmux_context()`
- **`kanban-hooks/subagent-track.py`** — Added `$TMUX_PANE`-based `-t` pane targeting to all `tmux display-message` subprocess calls in `get_tmux_context()`
- **`kanban-helpers.sh`** — Added `$TMUX_PANE`-based `-t` pane targeting to `tmux display-message` calls in `_kb_detect_context()`
- **`claude-hooks/amb-session-heartbeat.sh`** — Added `$TMUX_PANE`-based `-t` pane targeting to session key detection
- **`claude-hooks/amb-heartbeat-check.sh`** — Added `$TMUX_PANE`-based `-t` pane targeting to session key detection
- **`freelance/scripts/kanban-display.sh`** — Added `$TMUX_PANE`-based `-t` pane targeting to `_detect_board_file()`
- **`homebrew-tap/`** — Synced distribution copies of statusline-command.sh, kanban-hook.py, kanban-session-start.py, and subagent-track.py

### Feat: Enforce mandatory subitem completion before item closure (XACA-0107)
- **`kanban-helpers.sh`** — New `kb-sweep` function for pre-completion subitem review; `kb-done` now calls `kb-sweep` to verify all subitems are resolved before completion; `--force` flag restricted to user-only with warning messages
- **`kanban-helpers.sh`** — `kb-cancel` refactored to use `kb-sweep` for subitem checks (consistency with `kb-done`); removed redundant "Run kb-sweep" message from both `kb-done` and `kb-cancel` error paths since sweep output is already displayed
- **`~/.claude/CLAUDE.md`** — New "Subitem Completion Protocol" section added; "Non-Blocking Subitems" language updated to distinguish PR merge (non-blocking) from item closure (mandatory)
- **67 agent prompt `.txt` files** — Subitem Completion Protocol reference appended to all agent prompts across 11 team directories; trailing newlines added for POSIX compliance
- **`homebrew-tap/share/skills/Project Planner/SKILL.md`** — Updated to v1.5.0 with protocol references in guidelines, checklist, and dedicated section

### Feat: AMB Circles — organic community enablement (XACA-0103)
- **`claude-hooks/amb-heartbeat-check.sh`** — Added Nudge 4: Circle awareness with 5-hour throttle (18000s); provides REST API endpoint reference and curl usage pattern for browsing, joining, and creating AMB circles; directs agents to read their Bearer token from `~/.claude/amb-agents.json` (no secrets surfaced in hook output)
- **`claude-hooks/amb-session-heartbeat.sh`** — Added one-line circle awareness hint to session start message directing agents to browse circles for their discipline via REST API
- **`kanban-hooks/kanban-session-start.py`** — Updated `get_amb_heartbeat_reminder()` backup hook with matching circle hint to keep in sync with primary shell hook

### Feat: Work-mode indicators and job control leak fix (XACA-0104)
- **`kanban-helpers.sh`** — `_kb_set_working_on()` now accepts optional `work_mode` parameter (DEV/TEST/REVIEW/DEBUG); all `kb-run`, `kb-pick`, `kb-work`, `kb-run-review`, `kb-work-review`, `kb-run-test`, `kb-work-test`, `kb-run-debug`, `kb-work-debug`, and `kb-backlog sub start` call sites pass the appropriate mode
- **`kanban-helpers.sh`** — `_kb_clear_working_on()` now removes both `workingOnId` and `workMode` fields atomically
- **`kanban-helpers.sh`** — `_kb_update_window()` preserves `workMode` from existing activeWindows entries alongside `workingOnId`
- **`kanban-helpers.sh`** — `_kb_jq_update()` background process pattern changed from `cmd & ; disown` to double-subshell idiom `( (cmd) & ) 2>/dev/null` to suppress zsh `[N] pid` job control notifications
- **`claude/statusline-command.sh`** — `get_working_item()` now outputs `working_id|workMode` pipe-separated; caller splits and maps mode to emoji+label indicator (🔧DEV, 🧪TEST, 👁REVIEW, 🐛DEBUG); working item segment shows `[📌ITEM-ID 🔧DEV]` format when mode is set, falls back to `[📌ITEM-ID]` when empty

### Refactor: AMB reply tracker review feedback (XACA-0106-010, XACA-0106-011)
- **`claude-hooks/amb-reply-tracker.sh`** — `amb_reply_tracker_init` now accepts optional `prune` flag; pruning only runs when explicitly requested (SessionStart), not on every Stop hook invocation
- **`claude-hooks/amb-session-heartbeat.sh`** — Uses `amb_log_reply_command()` instead of inline log command; passes `prune` flag to init
- **`claude-hooks/amb-heartbeat-check.sh`** — Uses `amb_log_reply_command()` instead of inline log command; skips pruning on init

### Fix: AMB duplicate reply behavior across agents (XACA-0106)
- **NEW `claude-hooks/amb-reply-tracker.sh`** — Shared helper that tracks which Wire pings an agent has replied to via `~/.claude/.amb_reply_log_<handle>` state files; auto-prunes entries older than 7 days; provides `amb_recent_reply_count` and `amb_has_replied_to` functions
- **`claude-hooks/amb-session-heartbeat.sh`** — Sources reply tracker; replaces mandatory "REPLY to at least 1 ping" with three-tier conditional guidance based on recent reply count (0/1/2+ replies in 24h)
- **`claude-hooks/amb-heartbeat-check.sh`** — Sources reply tracker; removes "REPLY FIRST (REQUIRED)" mandate from wire engagement nudge; splits nudge into vouch-only path (active agents) vs suggest-reply path (inactive agents); updates philosophy comment from obligation to genuine-value-only
- **`skills/amb/HEARTBEAT.md`** — Adds "Avoiding duplicate replies" guidance section; updates Engagement Guide table with anti-duplicate rows; shifts frequency guide language from forced to genuine engagement

### Fix: Remove duplicate import re (XACA-0102-020)
- **Remove duplicate `import re`** — `lcars-ui/server.py` had `import re` on both line 20 and 29

### Fix: Subitem count badge now treats cancelled as resolved (XACA-0096)
- **`lcars-ui/js/lcars.js`** — Subitem completion counter (`completedCount/totalCount`) now includes cancelled subitems alongside completed ones; tooltip changed from "completed" to "resolved"
- **`homebrew-tap/share/lcars-ui/js/lcars.js`** — Same fix synced to homebrew-tap copy

### Fix: Resync homebrew-tap/share/lcars-ui/ with lcars-ui/ source (XACA-0098-024)
- **`homebrew-tap/share/lcars-ui/CHANGELOG.md`** — Synced to source; removed stale XACA-0100 sync notes
- **`homebrew-tap/share/lcars-ui/css/lcars.css`** — Synced to source; adds `.lcars-textarea` class and `.lcars-textarea:focus` styles
- **`homebrew-tap/share/lcars-ui/index.html`** — Synced to source; replaces inline textarea styles with `class="lcars-textarea"`
- **`homebrew-tap/share/lcars-ui/js/lcars.js`** — Synced to source; adds debounce/abort controller for knowledge panel rapid-navigation guard, safer XSS escaping for todo IDs
- **`homebrew-tap/share/lcars-ui/server.py`** — Synced to source; improves todo text validation (strip empty, reject blank), adds `import re`
- **`homebrew-tap/share/lcars-ui/docs/carousel-panel-design.md`** — Removed stale XACA-0087 design doc (not present in source, not homebrew-specific)
- NOTE: `lcars-target.js` intentionally NOT synced — homebrew-tap uses deployment-specific target `freelance-doublenode-lifeboard`

### Fix: Standardize sed indentation in _kb_reset_worktree_to_develop (XACA-0099-014)
- **`kanban-helpers.sh`** and **`homebrew-tap/share/templates/kanban/kanban-helpers.template.sh`** — Changed 6-space `sed 's/^/      /'` to 3-space `sed 's/^/   /'` for the multiple-remotes warning and uncommitted-changes warning output lines; all sed indentation in `_kb_reset_worktree_to_develop` is now consistently 3-space

### Docs: Add AMB API version to static tool schema comments (XACA-0088-012)
- **`scripts/amb-proxy.py`** — Updated module docstring and inline section comment to include `AMB API v1` alongside the capture date, replacing vague "live API" phrasing for clearer provenance tracking

### Refactor: Consolidate dead _post_json in amb-proxy.py (XACA-0088-011)
- **`scripts/amb-proxy.py`** — Removed dead `_post_json` function from the requests code path (lines 42-47); it created a new `Session()` per call and was never invoked because `_do_post` used the pooled `_HTTP_SESSION` instead
- Inlined the urllib `_post_json` body directly into the urllib `_do_post`, eliminating the unnecessary delegation wrapper
- Both code paths now have exactly one `_do_post` function and no `_post_json` at all

### Security: Sanitize badge name/emoji in agent-panel.html (XACA-0086-007)
- **`lcars-ui/agent-panel.html`** and **`homebrew-tap/share/lcars-ui/agent-panel.html`** — Added `sanitizeText()` helper that escapes HTML entities via textContent/innerHTML round-trip
- Applied `sanitizeText()` to badge `emoji` and `name` fields before they are assigned to `img.alt`, `img.title`, and `nameDiv.textContent` for defense-in-depth against XSS
- Also hardened spread-operator on `b.emoji` to handle null/undefined by defaulting to `''`

### Fix: Terminal Activation QA/Review Feedback (XACA-0102)
- **Rename `window` → `windowIndex`** in `activateTerminal()` — avoids shadowing the global `window` object in both `lcars-ui/js/lcars.js` and `homebrew-tap/share/lcars-ui/js/lcars.js`
- **Add missing route dispatch** — `homebrew-tap/share/lcars-ui/server.py` `do_POST()` was missing the `elif path == '/api/terminal/activate'` route, making the handler dead code

### Fix: Update stale line reference in switchSection comment (XACA-0087-014)
- **lcars-ui/js/lcars.js** and **homebrew-tap/share/lcars-ui/js/lcars.js** — Updated comment in `switchSection` that referenced `renderHomeAnalytics()` at 'line ~8186'; corrected to 'line ~8759' to match actual current location

### Fix: Correct approximate line reference in escapeHtml dedup comment (XACA-0083-032)
- **lcars-ui/js/lcars.js** and **homebrew-tap/share/lcars-ui/js/lcars.js** — Corrected comment referencing `escapeHtml()` location from 'line ~9678' to 'line ~10041' to match actual current location

### Port Terminal Activation to Source lcars-ui/ (XACA-0102)
- **3 files ported** from `homebrew-tap/share/lcars-ui/` to canonical `lcars-ui/` source
  - `server.py` — `handle_terminal_activate()` endpoint + route + imports (`re`, `subprocess`, `traceback`)
  - `js/lcars.js` — `makeClickableTerminal()` helper + `activateTerminal()` function + click handlers in `createDetailRow()`
  - `css/lcars.css` — `.clickable-terminal` base, logo hover (scale+glow), text hover (cyan), `:focus-visible` styles

### Terminal Activation — Review Feedback Fixes (XACA-0102)
- **subprocess.run timeout** - Added `timeout=5` to both `subprocess.run` calls (tmux and osascript) in `handle_terminal_activate` to prevent hung HTTP requests
- **DRY handler helper** - Extracted `makeClickableTerminal(el, win)` helper in `lcars.js` to eliminate duplicated click/keydown/accessibility setup between terminal logo and terminal name
- **Scale hover fix** - Moved `transform: scale(1.05)` from generic `.clickable-terminal:hover` to `.detail-logo.clickable-terminal:hover` only — prevents visual jitter on inline text elements

### Knowledge Base Analytics: Team-Scoped Filtering
- **`_get_team_agents()`** — reads the current team's board file to extract terminal `avatar` fields; builds a set of agent knowledge dir names + `team-{teamname}` for filtering
- **`_get_team_project_prefixes()`** — derives project memory path prefixes from `TEAM_KANBAN_DIRS` repo root so only relevant project memory dirs are scanned
- **Knowledge dir scan** — `_serve_knowledge_stats_inner()` now filters `~/.claude/knowledge/` to only the current team's agents (e.g. academy: `emh`, `nahla`, `reno`, `thok`, `team-academy`)
- **Project memory scan** — filters `~/.claude/projects/*/memory/` to only projects whose paths match the team's repository
- **Graceful fallback** — if board file is unreadable or team not found in `TEAM_KANBAN_DIRS`, falls back to unfiltered fleet-wide scanning

### Fix: grep -F literal matching and homebrew-tap LCARS sync (XACA-0100-016/017/022)
- **kb-knowledge-search** — Added `-F` flag to all 4 `grep` calls for literal string matching, preventing regex metacharacter interpretation in user search terms
- **homebrew-tap sync** — Copied canonical `lcars-ui/` source files to `homebrew-tap/share/lcars-ui/`:
  - `server.py` — Added `serve_knowledge_stats`, `_compute_adoption_metrics`, `_serve_knowledge_stats_inner`, requiredBy date validation
  - `js/lcars.js` — Added adoption dashboard rendering (Panel 4), overdue detection refactor
  - `index.html` — Added `#home-knowledge-adoption` div for Panel 4
  - All 4 core files now identical between lcars-ui/ and homebrew-tap/

### Knowledge Base Analytics: 2-Column Stat Grid
- **CSS layout change** — `.knowledge-metrics-panel` switched from single-column flex to 2-column CSS grid (`grid-template-columns: 1fr 1fr`)
- **Stat cells compacted** — reduced padding (10px→8px), font-size (28px→22px), gap (3px→2px) for narrower columns
- **Overflow protection** — `text-overflow: ellipsis` on stat values, `min-width: 0` on cells
- **Responsive** — collapses to single column on screens < 768px

### Sync homebrew-tap/share/lcars-ui/ with lcars-ui/ Source
- **11 files synced** from canonical `lcars-ui/` source to `homebrew-tap/share/lcars-ui/` distribution copy
  - `server.py`, `js/lcars.js`, `css/lcars.css`, `index.html` — brought Todo API/UI (XACA-0101), finance routes, `_derive_item_status()`, per-window agent resolution to tap
  - `css/lcars-fleet.css` — `.kiosk-fab` CSS now in tap
  - `js/lcars-charts.js` — safer `applyLCARSTheme()` with explicit safety comment
  - `js/lcars-fleet-core.js` — analytics and keyboard shortcut alignment
  - `CHANGELOG.md`, `integrations/import_issue.py`, `integrations/manager.py` — finance-personal paths and medical dirs
  - `images/finance_logo.png` — new file, was missing entirely from tap
- **Skipped:** `lcars-target.js` (per-install config), `docs/carousel-panel-design.md` (tap-only doc, harmless)
- **Follow-up captured:** XACA-0102 terminal activation needs porting from tap back to source (same wrong-directory bug pattern as XACA-0098)

### Terminal Activation via LCARS Details Tab (XACA-0102)
- **Server Endpoint** - Added `POST /api/terminal/activate` to `server.py`
  - Accepts `{terminal, window}` JSON body to switch tmux window and iTerm2 tab
  - Input sanitization: regex validation on terminal name, integer cast on window index
  - Executes `tmux select-window -t {terminal}:{window}` via subprocess
  - AppleScript/osascript switches iTerm2 to the tab containing the target tmux session
  - iTerm2 failure is non-fatal (returns `iterm_warning` instead of error) since tmux already switched
  - Proper 400/500 JSON error responses for all failure cases
- **Click Handlers** - Added click event listeners in `createDetailRow()` in `lcars.js`
  - Terminal logo (`detail-logo terminal-logo`) and terminal name (`detail-terminal`) are now clickable
  - New `activateTerminal()` async function calls the endpoint via `apiUrl()` (Tailscale prefix compatible)
  - Uses `e.stopPropagation()` to prevent row click, follows existing `workingOnId` click pattern
- **CSS Styles** - Added `.clickable-terminal` styles in `lcars.css`
  - Cursor pointer with 0.15s transition on hover
  - Logo hover: cyan outline + box-shadow glow (uses `outline` not `border` to avoid layout shift)
  - Text hover: cyan color + text-shadow glow (matches existing `.detail-working-id.clickable` pattern)
  - `:focus-visible` outline for keyboard navigation accessibility
- **QA Feedback Fixes**
  - Added keyboard accessibility: `tabIndex=0`, `role="button"`, Enter/Space keydown handlers on both clickable elements
  - Moved `import re` and `import traceback` to top-level module imports in `server.py`

### Fix: Knowledge Base Panel Missing from Source LCARS UI (XACA-0098)
- **Root Cause** - PRs #118 and #120 wrote the knowledge analytics code to `homebrew-tap/share/lcars-ui/` instead of `lcars-ui/` (the actual development source). The source files never received the knowledge panel.
- **server.py** - Added `/api/knowledge-stats` endpoint with stat() caching, scanning `~/.claude/knowledge/` agent dirs and `~/.claude/projects/*/memory/` auto-memory files
- **lcars.js** - Added `knowledgeDoughnut` to chart registry, incremented `TOTAL_HOME_PANELS` from 4 to 5, added `case 4` dispatch to `_renderHomePanel()`, implemented `_renderHomeKnowledgeStats()` async render function
- **index.html** - Added 5th carousel panel (data-panel-index="4") with gold/amber KNOWLEDGE BASE header, doughnut chart canvas, and metrics container; added 5th carousel dot
- **lcars.css** - Added `.section-header.gold`, `.knowledge-chart-title`, `.knowledge-metrics-panel`, `.knowledge-stat-row`, `.knowledge-stat-value`, `.knowledge-stat-label` CSS classes with amber theme and responsive stacking

### Team Todo List — Testing & Debugging (XACA-0101-006)
- **Fixed redundant lock double-unlock** - Removed explicit `fcntl.LOCK_UN` calls in `handle_update_todo` and `handle_delete_todo` in `server.py` for the "todo not found" early-return path; the `finally:` block already unconditionally unlocks, making the explicit calls redundant and potentially confusing
- **Verified test coverage** - All API handlers, JS functions, HTML structure, CSS classes, and shell helpers validated; schema field names consistent across all three layers (server, JS client, shell helpers)

### Team Todo List — API Integration Fix (XACA-0101-005)
- **Fixed PUT payload mismatch** - `saveTodo()` and `toggleTodo()` in `lcars.js` now send `{ team, id, updates: {...} }` matching the server's `handle_update_todo` contract; previously sent flat objects that triggered HTTP 400 "Missing required field: updates" errors on every edit and checkbox toggle

### Team Todo List — Schema and Shell Helpers (XACA-0101)
- **Board JSON Schema** - Added `todos` top-level array to board JSON files alongside `backlog`, `releases`, and `epics`
  - Each todo item: `id`, `text`, `priority` (low/medium/high/critical), `requiredBy` (optional ISO date), `status` (todo/completed), `createdAt`, `completedAt`
  - ID format: `todo-{timestamp}-{random4}` (e.g., `todo-1709059200-0042`)
  - No migration needed — missing `todos` array is treated as empty by all helpers
- **`kb-todo-add`** - Adds a new todo item; priority defaults to "medium"; optional required-by date; uses `_kb_jq_update` for file locking; initializes `todos` array if absent
- **`kb-todo-complete`** - Toggles status between `todo` and `completed`; sets/clears `completedAt` timestamp accordingly
- **`kb-todo-update`** - Updates individual fields (`--text`, `--priority`, `--required-by`, `--clear-required-by`) on an existing todo; uses incremental jq filter construction matching existing backlog patterns
- **`kb-todo-delete`** - Removes a todo item entirely using `map(select(.id != $id))`
- **`kb-todo-list`** - Lists todos with `--all`, `--completed`, or `--todo` (default) filter; formatted output with priority indicators (`[!!!]`/`[!! ]`/`[!  ]`/`[   ]`) and status tags; uses `_kb_jq_read` with shared locking
- **`kb-help` updated** - Added Todo List section documenting all five new commands

### Knowledge Base Panel in Home Carousel (XACA-0098)
- **JS Analytics Wiring** - Wired knowledge base panel (index 4) to live data in `lcars.js`
  - `TOTAL_HOME_PANELS` incremented from 4 to 5
  - `homeCharts.knowledgeDoughnut` added to chart registry; `panelChartKeys[4]` registered for resize handling
  - `renderHomePanel()` switch extended with `case 4:` routing to `_renderHomeKnowledgeStats()`
  - `_renderHomeKnowledgeStats()` fetches `/api/knowledge-stats` and renders:
    - Doughnut chart on `#home-knowledge-doughnut` — Agent Files / Team Files / Memory Files breakdown using LCARS amber/orange/yellow palette
    - Metric stat rows in `#home-knowledge-metrics` using `.knowledge-stat-row` CSS classes for all 8 summary fields (agents, teams, files, entries, KB size, memory projects, most active, last updated)
  - Loading state shown during fetch; graceful "DATA UNAVAILABLE" error display on failure
  - Follows existing `_renderHomeSubitemStats()` pattern: `updateChart` if instance exists, else `_destroyOrphanedChart` + `createDoughnut`
- **HTML Structure** - Added 5th carousel panel (`data-panel-index="4"`) to the HOME tab with KNOWLEDGE BASE title, gold/amber LCARS color theme, and a two-column layout matching existing panel patterns
  - Left column: doughnut chart (`#home-knowledge-doughnut`) for files-by-type distribution
  - Right column: metrics container (`#home-knowledge-metrics`) for stat rows (total files, KB size, projects, last updated)
  - Added 5th carousel dot indicator for panel navigation
- **CSS Styling** - Added Knowledge Base panel CSS classes in `lcars.css`
  - `.section-header.gold` with `--lcars-amber` color and gradient section bar
  - `.knowledge-chart-title`, `.knowledge-metrics-panel`, `.knowledge-stat-row`, `.knowledge-stat-value`, `.knowledge-stat-label` following existing LCARS design patterns
  - Responsive `@media (max-width: 768px)` rule stacks the two-column layout vertically on narrow screens
- **Bug Fixes (XACA-0098-004 Testing)**
  - Fixed `mostActiveAgent` calculation in `serve_knowledge_stats()` — was including `team-*` directories in the most-active ranking, causing MOST ACTIVE to display a team name instead of an individual agent name. Now skips `team-*` entries during the tracking pass
  - Fixed missing exception handling in `serve_knowledge_stats()` — refactored into `serve_knowledge_stats()` + `_serve_knowledge_stats_inner()` pattern so any filesystem scan error (permission errors, TOCTOU race) returns a proper `500 {"error": "..."}` JSON response instead of crashing the request handler
  - Fixed stale JSDoc on `renderHomePanel()` — updated panel mapping to include panel 4 (KNOWLEDGE BASE) and corrected `@param` range from (0–3) to (0–4)

### Fix wt-finish and wt-cleanup for Squash-Merged PRs (XACA-0098)
- **`_wt_check_pr_merged()` helper** — Uses `gh pr view` as the authoritative merge signal for squash-merged PRs; returns `NUMBER|TITLE` on success, gracefully falls back when `gh` is unavailable
- **`wt-finish` PR-aware cleanup** — Checks GitHub PR status before falling back to git-based heuristics; verified-merged PRs skip all interactive prompts, force-delete local branch, and delete remote branch automatically
- **`wt-finish` freelance guard fix** — Replaced hardcoded `basename "$WT_MAIN"` with the standard freelance guard pattern (`WT_FREELANCE_MAIN_BRANCH`) used by all other worktree functions
- **`wt-cleanup` squash-merge support** — Batch cleanup now checks `_wt_check_pr_merged` first, falls back to `git branch --merged`; uses `git branch -D` (force) for PR-verified branches and deletes remote branches
- **Enhanced summary output** — `wt-finish` summary now shows PR number, local branch status, and remote branch deletion status

### Debug Commands for Kanban Items (XACA-0097)
- **`_kb_reopen_item()` helper** — Transitions completed/cancelled items back to `in_progress`, preserves `previousStatus` and `reopenedAt` timestamps, auto-generates 7 debug subitems (`[Debug] Diagnose root cause`, `[Debug] Implement fix`, etc.) with sequential IDs via single atomic jq update
- **`_kb_build_debug_prompt()` helper** — Builds debug-focused Claude Code prompt guiding agents through diagnose → fix → test → PR workflow; follows same structure as `_kb_build_review_prompt()` and `_kb_build_test_prompt()`
- **`kb-run-debug <id>` command** — Worktree variant: switches to item's worktree, reopens if completed/cancelled, launches Claude Code with debug prompt; follows `kb-run-test` pattern with added reopen logic
- **`kb-work-debug <id>` command** — Current directory variant: stays in current directory, reopens if completed/cancelled, launches Claude Code with debug prompt; follows `kb-work-test` pattern with added reopen logic
- **`kb-help()` entries for `kb-run-debug` and `kb-work-debug`** — Added both commands to the help output under "Backlog Items" section, following the same pattern as `kb-run-test`/`kb-work-test`
- **Display box refactored to `_kb_display_item_box()` helper (XACA-0097-011)** — Confirmed `kb-run-debug` and `kb-work-debug` use the shared `_kb_display_item_box()` helper extracted in XACA-0096, with correct `local` variable declarations and caller-scope population; no duplicated display box code remains

### Extract Shared Display Box Helper (XACA-0096)
- **`_kb_display_item_box()` helper** - Extracted ~60-line display box rendering code into a shared helper function, eliminating duplication across 6 functions (`kb-run`, `kb-work`, `kb-run-review`, `kb-work-review`, `kb-run-test`, `kb-work-test`)
  - Parameterized by box title and feature flags (`worktree`, `branch`, `subitem_detail`)
  - Sets extracted variables in caller scope for downstream use (no API change)
  - Fixes missing `local` keyword on `cancelled_count` variable (XACA-0094-009)
  - Delimiter-safe flag matching using comma boundaries (XACA-0096-001)
  - Eliminated double jq extraction in `kb-run`/`kb-work` — blocked check now extracts only 4 fields, helper extracts the rest (XACA-0096-002)
  - Net reduction of ~300 lines

### Agent Merit Badges (AMB) Display in Agent Panel (XACA-0080)
- **AMB Handle Mapping** - `display-agent-avatar.sh` now includes `amb_handle` field in JSON output for agents registered on the AMB platform
  - Maps 4 Academy agents: `nahla-ake`, `jett-reno`, `lura-thok`, `the-doctor-emh`
  - File-based validation: handle only included if `~/.config/agentbadges/agents/{handle}.json` exists
  - Non-registered agents get empty string (graceful no-op)
- **Web Panel Badge Display** - `agent-panel.html` shows `@handle` and up to 5 earned badge emojis between role and location
  - Hidden by default; only visible for AMB-registered agents
  - Styled with monospace handle text and spaced emoji row matching LCARS theme
  - Both `lcars-ui/` and `homebrew-tap/share/lcars-ui/` copies synchronized
- **Terminal Panel Badge Display** - `agent-panel-display.sh` shows `@handle` and badge emojis between role and divider
  - `get_amb_badges()` fetches from AMB API with 5-minute file-based cache (`/tmp/lcars-amb-{handle}.json`)
  - Badge cache mtime tracked in `compute_content_fingerprint()` for change-triggered re-renders
- **Server-Side Badge Caching** - `server.py` enriches `/api/agent-panel` response with `badges` array
  - `_fetch_amb_badges()` with in-memory cache (5-min TTL) and 5-second network timeout
  - Graceful degradation: stale cache on API failure, empty array on first failure
  - Both `lcars-ui/` and `homebrew-tap/share/lcars-ui/` copies synchronized

### Subagent Crew Avatar Tracking Lifecycle
- **Subagent Self-Removal** - Added `remove` CLI action to `subagent-track.py` so subagents can clean up their own crew avatar before completing (`python3 subagent-track.py remove <agent_type>`)
  - Solves background agent persistence: `run_in_background: true` agents don't fire PostToolUse on completion, only on launch
  - 5/6 test agents successfully self-removed; 1 refused due to role-boundary logic (fixed by framing as mandatory infrastructure cleanup)
- **Background Agent Detection** - PostToolUse `stop` action now checks `tool_response.isAsync` to skip removal for background launches, keeping avatars visible while agents run
- **Per-Window Scoped Cleanup** - Replaced `cleanup_session()` (nuked ALL windows) with `cleanup_window()` (targets specific session/window only)
- **Deduplication & Format Migration** - `add_agent()` checks for existing entries before appending; `locked_update()` migrates legacy plain-string format to `{"type": "..."}` objects
- **Agent Panel Display** - Updated `get_crew_avatars()` jq filter to handle both legacy string and current object formats
- **CLAUDE.md Mandatory Instructions** - Added "Subagent Self-Removal from Crew Tracking" section requiring every subagent prompt to include the remove command as a final step (all 3 repo copies + global template)

### Enhanced PR Reviewer Workflow (XACA-0079)
- **Reviewer Re-Review Monitoring Loop** - After submitting `REQUEST_CHANGES`, reviewers now enter a polling loop that detects new commits (via SHA comparison) and automatically re-reviews the updated PR
  - 30-second stabilization check prevents re-review of intermediate pushes
  - Context exhaustion warning after extended review cycles
- **Non-Blocking Suggestions → Kanban Subitems** - Review suggestions that don't block merge are captured as kanban subitems (prefixed with `[Review]`) instead of being lost in PR comments
  - Three-method kanban item ID discovery (handoff prompt, branch name, PR description)
  - One subitem per suggestion with PR number reference
- **Fixed Creating Agent Stale Review Detection** - Monitoring loop now tracks `LAST_PROCESSED_AT` timestamp to prevent re-triggering on already-processed `CHANGES_REQUESTED` reviews
- **Combined API Calls** - Merged two `gh api` calls per poll iteration into one, reducing GitHub API rate usage by ~50%
- **Shared Review Prompt Helper** - Extracted `_kb_build_review_prompt()` from duplicated code in `kb-run-review()` and `kb-work-review()` (-59 lines)
- **Updated Review Handoff Prompt** - Includes kanban item ID, non-blocking subitems instructions, and reviewer monitoring loop reference
- **Eliminated `echo | jq` Anti-Pattern** - All monitoring loops use `gh api --jq` exclusively across all CLAUDE.md files

### Homebrew Tap — Replicable Dev-Team Environment (XACA-0073)
- **Complete Homebrew Tap Package** - Any Mac can replicate the full dev-team environment with `brew install dev-team` + `dev-team setup`
  - Interactive setup wizard with LCARS-styled UI for guided onboarding
  - 10 team configurations: iOS, Android, Firebase, Academy, Command, DNS, Freelance, Legal, MainEvent, Medical
  - Modular installers: shell environment, Claude Code config, LCARS Kanban, Fleet Monitor, per-team setup
  - Lifecycle commands: `dev-team doctor`, `upgrade`, `uninstall`, `status`, `start`, `stop`
  - Migration path for existing installations with backup, dry-run, and rollback support
  - Multi-machine networking via Fleet Monitor + Tailscale funnel
  - Security hardening: TEAM_ID validation, path traversal guards, secrets permission checks, safe tilde expansion
  - Comprehensive test suite: 150 tests across 9 test files (CLI, config, installers, integration, lifecycle, migration, setup wizard, teams, UI)
  - Full documentation: Quick Start, Architecture, User Guide, Troubleshooting, Team Reference, Multi-Machine Setup

### Agent Panel Display
- **iTerm2 Freeze Prevention** - Fixed system freeze on wake when multiple agent panels are running
  - Sleep/wake detection via elapsed time measurement; staggered resume delay (1-5.5s per panel) prevents simultaneous I/O burst
  - Staggered polling intervals: each panel polls at 2s + unique offset (based on session code hash) to desynchronize renders
  - Content fingerprint (MD5 of all data sources) skips expensive imgcat/magick renders when content is unchanged
- **Display Quality Improvements** - Enhanced readability and visual quality of agent panel panes
  - Word-wrap at word boundaries for all text fields (developer, role, terminal name, description, location, mission, task)
  - Dedicated "Agent Panel" iTerm2 profile with JetBrains Mono NF Light 9pt (isolated from main terminal font)
  - Fixed iTerm2 session UUID matching (`ITERM_SESSION_ID` uses `w0t0p0:UUID` format, API uses plain UUID)
  - Agent panel width adjusted to 30 columns; main terminal pane width set to 170 columns
  - Divider lines increased to 28 characters for visual balance
  - Suppressed stdout from resize-pane calls leaking into panel pane
- **Panel Image Optimization** - Eliminated blurry avatars and expensive runtime resizing
  - New `generate-panel-images.sh` script creates `_avatar_panel.png` (200x200 from 400x400) and `_logo_panel.png` (200x200 from 1024x1024)
  - Panel display now prefers pre-generated `_panel.png` sources, eliminating runtime resize on every render
  - Cached rounded/masked images in `/tmp` — ImageMagick runs once per boot per panel instead of every 2-3 seconds
  - Switched from blurry `_avatar_thumb.png` (100x100) to full `_avatar.png` (400x400) as fallback source
  - Generated 146 panel images (63 avatars + 83 logos)

### Fleet Monitor - Avatar Scoping Fix
- **Cross-Team Avatar Contamination Fix** - Prevented wrong-team avatar matches in Fleet Monitor dashboard
  - `getTeamAvatarUrl()` now scopes terminal lookups by division instead of searching all registered teams
  - Added `buildDivisionToTeamMap()` to handle fleet-to-team key mismatches (e.g., `freelance-starwords` → `freelance-doublenode-starwords`)
  - Fixed `createTeamCard` to pass project-specific division for freelance, legal, and medical teams
  - Added `registered-teams.json` persistence so team registrations survive fly.io restarts (was in-memory only)

### Kanban System - Cancelled State (XACA-0075)
- **Cancelled Status for Items & Subitems** - New `cancelled` state treats items as resolved without implying work was completed
  - **`kb-cancel` Command**: Cancel items/subitems with optional `--reason "text"` flag, mirrors `kb-done` behavior
  - **`kb-backlog sub cancel`**: Cancel subitems directly via backlog subcommand
  - **Resolved Semantics**: `cancelled` items satisfy parent completion checks and unblock dependents (same as `completed`)
  - **Blocker Integration**: Cancelling a blocker auto-unblocks dependent items; blocking on resolved items is now prevented
  - **Epic Progress**: Progress % uses resolved count (completed + cancelled); epic auto-completes when all items resolved
  - **Subitem Summaries**: Display shows cancelled count separately (e.g., "2 done, 1 cancelled, 1 todo")
  - **LCARS UI**: Cancelled items display red `✗` icon with strikethrough title and muted opacity
  - **Server API**: `/api/epics` endpoints return `cancelledItems` and `resolvedItems` fields; `percentComplete` includes cancelled
  - **Help Updated**: `kb-help` documents new `kb-cancel` and `kb-backlog sub cancel` commands

### LCARS Fleet Monitor - Avatar-Forward Workflow (XACA-0063)
- **Avatar Display Across All LCARS Surfaces** - Agent persona avatars prominently visible on every Fleet Monitor view
  - **WORKFLOW Tab**: 48px circular avatar thumbnails on team cards with LCARS-styled cyan borders and hover glow
  - **QUEUE Tab**: 32px circular avatars on Epic/mission queue items with persona assignment
  - **Detail Row Enhancement**: 100px full-size avatars in expanded card views with division-colored borders (iOS blue, Android green, Firebase amber, etc.)
  - **Fleet Monitor Sessions**: Organization-level avatar grids showing all active agents per division; session-level avatars with online/offline state awareness
  - **Tooltip Hover Cards**: LCARS-styled hover tooltips on all avatars showing persona name, role, and team with team-colored borders and smooth fade-in animations
  - **Terminal Startup Banner**: iTerm2 inline image protocol displays agent avatar in terminal MOTD via shared `display-agent-avatar.sh` helper
  - **Avatar Asset Pipeline**: Audited 57 personas across 9 teams; deployed 37 PNG avatar sets (full-size + thumbnail) to Fleet Monitor public directory
  - **Persona Metadata Module**: `LCARS.personas` centralized lookup with 58 persona entries for tooltip integration
  - Added `getTeamAvatarUrl()` helper function to all 4 dashboard apps (Academy, MainEvent, DoubleNode, All)
  - Added `createDivisionAvatarGrid()` function for organization-level avatar displays
  - Graceful fallback handling for missing avatars (onerror hide, shimmer loading states)
  - Event-delegated tooltip system using `.lcars-avatar` class and `data-persona` attributes

### LCARS UI - Calendar Sync
- **Calendar Provider Connection Flow** (XACA-0058) - Full Apple iCloud CalDAV calendar integration with outbound sync
  - **Apple CalDAV Authentication**: Principal discovery, calendar home set resolution, app-specific password auth
  - **Calendar Selection**: Browse and select from all iCloud calendars (Legal, Home, Personal, etc.)
  - **Outbound Sync**: Push kanban items with due dates to iCloud calendar as all-day events
  - **Subitem Sync**: Subitems with due dates sync with parent context in title (e.g., "Parent > Subitem")
  - **Credential UI**: LCARS-themed credential input forms for Apple and Google providers
  - **Sync Stats Toast**: Shows created/updated/error counts after each sync
  - Fixed CalDAV XML parsing for Apple's `xmlns="DAV:"` on every element (not just namespace prefixes)
  - Fixed Content-Type headers: `application/xml` for PROPFIND, `text/calendar` for PUT events
  - Fixed `urljoin` URL construction ensuring trailing slash on calendar paths
  - Fixed sync trigger reading from `backlog` key (not nonexistent `items` key)
  - Fixed `_discover_calendar()` to match user's selected calendar by ID or display name
  - Fixed duplicate `showToast()` function that was overriding good implementation
  - Fixed `checkCalendarIntegration()` checking wrong endpoint
  - Fixed config field name mismatches between JS and server (`availableCalendars`/`selectedCalendarId`)
  - Removed duplicate imports in Google provider
  - Added `.gitignore` rule for `config/*/calendar-config.json` (contains credentials)

### Claude Code Configuration
- **Team Repository & Kanban Boundaries** (XACA-0032) - Comprehensive team isolation rules enforced in all Claude Code prompts
  - **Git Repository Boundaries**: Teams can only modify their own repo, read-only access to others
  - **Kanban API-Only Rule**: All kanban operations must use kb-* functions/API (no direct file edits)
  - **Academy Exception**: Academy team can develop/maintain kanban infrastructure and provide oversight
  - Updated global `~/.claude/CLAUDE.md` with new boundary sections
  - Updated repo-level `claude/CLAUDE.md` and `claude-config/CLAUDE.md`
  - Added Team Boundaries section to all 44 agent persona files in `~/.claude/agents/`

### LCARS UI
- **Calendar Tab with Due Dates** (XACA-0036) - Visual calendar view for tracking kanban items and epics by due date
  - Week and month view modes with navigation and "Today" button
  - Displays kanban items and epics on their due date cells
  - Urgency color coding: red (overdue), orange (imminent), yellow (soon), cyan (future)
  - Click-to-navigate: click any item to jump to Queue/Epics section with highlight
  - Epic filter dropdown to filter calendar by epic assignment
  - External calendar events support (when integration enabled) with sync icon
  - Full LCARS styling with responsive design for mobile
  - Calendar API endpoint at `/api/calendar/items` with date range filtering
- **Epics UI Tab and Item Assignment** (XACA-0040) - Full Epic management system for grouping related kanban items
  - New EPICS sidebar tab with purple-themed section
  - CRUD API endpoints for epics (`/api/epics/*`)
  - Expandable epic cards showing assigned items with progress bars
  - Epic assignment button (+EPIC badge) on queue items
  - Epic filter dropdown in queue filter bar (ALL/ASSIGNED/UNASSIGNED/specific epic)
  - Create/edit modals with color selection (8 color options)
  - Items store `epicId` and `epicName` fields for assignment tracking
- **Team Validation for Releases** (XACA-0037) - Prevents cross-team contamination in release item assignments. Server validates team ownership, UI filters releases by team, RELNOTES generation filters items as safeguard.
- **Work Time Tracking** (XACA-0029) - Track actual work time on subitems with automatic rollup to parent items. Displays time worked on completed items (e.g., "2h 15m")
- **Subitem-Level Dependency Filtering** (XACA-0021) - Hover over subitem blocked-by indicators to filter queue, showing only source subitem and blocking subitems
- **Team-Specific Releases & Integrations** - Releases and integrations now stored per-team in `config/{LCARS_TEAM}/` directories
- **"Other" Platform Support** - Added 4th platform option for non-iOS/Android/Firebase releases
- **Release Name Truncation** - Increased display length from 12 to 20 characters on queue items
- **Platform Dropdown Filtering** - Platform dropdown now shows only platforms enabled for selected release
- **Browser Autocomplete Fix** - Changed to `autocomplete="one-time-code"` to prevent autofill on release name fields

### Kanban Board Startup Validation (XACA-0078)
- **Board Validation on Startup** - `dev-team start` now validates all configured team kanban boards before launching services
  - Four-step validation: directory exists, file exists, valid JSON, required fields present
  - Interactive recovery menu: restore from backup, create from template, or skip
  - Non-interactive mode detection for CI/automated contexts (skips prompts)
  - Max 5 retry attempts on recovery to prevent infinite loops
- **Shared Board Template** - Rich production-schema template with 9 substitution variables (`{{TEAM_ID}}`, `{{TEAM_NAME}}`, `{{TEAM_SERIES}}`, etc.)
  - Full releaseConfig with environments (DEV→PROD), platforms, releaseTypes, flowConfig
  - Proper counters (nextId, nextEpicId, nextReleaseId) starting at 1
- **Canonical Path Library** (`kanban-paths.sh`) - Single source of truth for team→kanban directory mappings
  - Eliminates triple-duplicated case statements across board-check.sh, restore-helper.sh, and kanban-backup.py
  - Covers all team types: core teams, freelance-*, legal-*, medical-* with generic fallbacks
  - Zero dependencies, double-source guard, returns exit code 1 for unknown teams
- **Backup Restore Helper** (`kanban-restore-helper.sh`) - Standalone CLI helper for interactive backup restoration
  - Menu-driven UX with numbered backup selection, size and date information
  - Supports both .zip and .json backup formats
- **Security Hardening** - Python JSON validation uses `sys.argv[1]` (not string interpolation), `eval` replaced with safe indexed array lookup in install-kanban.sh
- **Robustness** - `pushd/popd` for directory restoration, `read -ra` array iteration, common.sh stubs for standalone operation

### Kanban System
- **Comprehensive Kanban Directory Backup** (XACA-0055) - Enhanced backup system to compress ALL files in each team kanban directory
  - Full directory zip archives: board JSON, plan documents (.md), releases directory with manifests
  - Comprehensive delta detection: hashes ALL files (not just board JSON) to detect changes
  - File exclusions: automatically excludes .lock files and debug logs
  - Backward compatible: supports both legacy .json and new .zip backup formats
  - Restore handles both formats with automatic detection
  - Retention policy applies to both .json and .zip files during transition
  - LCARS UI: Backup tab now shows filenames and lists both .json/.zip files
- **Auto-Sync Release Manifests on CLI Updates** (XACA-0054) - Automatic release manifest synchronization when items are updated via CLI
  - New `POST /api/releases/sync-item` endpoint in LCARS server
  - New `_kb_release_sync()` helper function with graceful degradation (2s timeout, silent on server-down)
  - Integrated into 18+ CLI commands: `kb-pick`, `kb-done`, `kb-backlog change`, `kb-backlog priority`, `kb-backlog tag`, subitem operations
  - Fixes stale status display in LCARS Releases tab when items modified via CLI
- **Epic System** (XACA-0038) - Group multiple kanban items into high-level objectives (Epics) for project milestones, legal cases, or release cycles
  - Each team has isolated Epics (no cross-team sharing) - team boundary enforcement at API level
  - Epic ID format: `E{TEAMCODE}-{0000}` (e.g., EACA-0001)
  - Shell commands: `kb-epic create|list|show|add-item|remove-item|update|delete|status`
  - Server API endpoints: GET/POST/PUT/DELETE at `/api/epics/:team`
  - LCARS UI: Epic section with filtering, progress tracking, and management modal
  - Status rollup calculates Epic status from contained items (blocked/active/completed)
  - Progress tracking shows completed/total items with percentage
- **Work Time Tracking** (XACA-0029) - Shell commands (`sub done`, `sub stop`, `sub todo`, `block`) now accumulate work time in `timeWorkedMs` field
- **Fixed: UTC Date Parsing** (XACA-0029) - Corrected timezone handling in work time calculations. macOS `date -j -f` was ignoring the "Z" UTC suffix, causing negative time values. Now uses `TZ=UTC` with stripped suffix for accurate elapsed time.
- **`freelance-doublenode-appplanning` Team Support** - Added FAP team code
- **Smart Compound Word Extraction** - `_kb_extract_compound_code()` for auto-generating 2-letter codes from compound words (e.g., starwords=SW, appplanning=AP)
- **Enhanced Team Code Fallback** - Multi-segment team names now use first letter of first segment + smart 2-letter from last segment

### Git Worktree System
- **Worktree Hard-Reset to Develop** (XACA-0099) - `kb-run` and `kb-work` variants now hard-reset the worktree to `remote/develop` before starting work
  - Auto-detects remote name (not hardcoded to "origin")
  - Graceful fallback on network failure — continues with current state
  - Cleans untracked files after reset for a fresh baseline
  - Multi-remote warning when more than one remote is configured
  - Uncommitted changes warning before destructive reset

### Fleet Monitor
- **PERSONAL Organization Support** (XACA-0033) - New green-themed organization for personal/legal projects, separate from DOUBLENODE
- **Team Auto-Discovery API** (XACA-0033) - New `/api/team-config` endpoint that scans kanban board files and returns team configurations dynamically. No code changes needed for new teams - just add board file with `organization` field.
- **Dynamic Organization Mapping** - Client now fetches team config on load, uses `organization` field from board files with pattern-based fallbacks (`legal-*` → PERSONAL, `freelance-*` → DOUBLENODE)
- **DASHBOARDS Admin Tab** (XACA-0028) - New ADMIN section on ALL FLEET dashboard for managing dashboard configurations. Create, edit, and delete custom dashboards with division filtering, org colors, and system protection. Includes CRUD API endpoints, dynamic sidebar links, toast notifications, and form validation.
- **Unified Dashboard System** (XACA-0028) - Single `lcars-dashboard.html` with query parameter routing (`?dashboard=ID`). Dynamic configuration loading eliminates need for separate HTML files per dashboard.
- **Drag-and-Drop Dashboard Reordering** (XACA-0028) - Reorder dashboards in ADMIN panel with drag-and-drop. Changes immediately reflect in sidebar links via custom event system.
- **Org Color Indicators** (XACA-0028) - Dashboard sidebar links now display org color indicators (colored dots) for visual identification.
- **Dynamic Division Filtering** (XACA-0028) - Division filter now pulls from live fleet data via `/api/active-divisions` endpoint. Shows only divisions with active sessions and displays session counts.
- **Machine Filtering** (XACA-0028) - New machine filter multi-select in dashboard editor. Filter dashboards by specific machines with online/offline status indicators. Uses `/api/machines/list` endpoint for real-time machine data.
- **Context-Aware ADMIN Button** (XACA-0028) - ADMIN section only visible on ALL FLEET dashboard. Non-ALL FLEET dashboards auto-switch to OVERVIEW if ADMIN was previously selected.

### Skills
- (pending changes)

### Team Infrastructure
- **Legal Team Infrastructure** (XACA-0033) - New LEGAL team for custody case support with William
  - 7 specialized terminals: LCARS, Chambers, Discovery, Research, Filings, Mediation, Timeline
  - 6 Claude agent personas: Judge Advocate (Lead Counsel), Paralegal, Law Clerk, Court Clerk, Mediator, Case Manager
  - Master launcher script (`legal-startup.sh`) with iTerm2 integration
  - Full prompt files and zshrc configurations for each terminal
  - Teams schema updated to include "legal" team
  - Banner script with legal-themed color schemes (Command Blue, Operations Gold, Sciences Blue)
- **Legal Multi-Project Structure** (XACA-0033) - Legal team now supports multiple projects like freelance
  - Project directory: `~/legal/coparenting/` (first project, git repo initialized)
  - Board naming: `legal-{project}-board.json` pattern (e.g., `legal-coparenting-board.json`)
  - Organization: PERSONAL (green theme in Fleet Monitor, separate from DOUBLENODE)
  - All terminal scripts updated to work in project directory context
- **Multi-Machine Onboarding System** (XACA-0024) - Complete system for onboarding new Mac Mini machines to dev-team infrastructure
  - Interactive setup wizard (`dev-team-setup.sh`) with 8 phases: machine identity, team selection, Fleet Monitor config, dashboard group, config generation, secrets setup, Claude login, verification
  - New `~/.dev-team/` directory for machine-specific config (machine.json, fleet-config.json, teams.json)
  - Three Fleet Monitor modes: client (central only), standalone (local only), hybrid (both)
  - Configuration validation library with JSON schema validation
  - Machine identity library with UUID generation and TailScale hostname detection
  - Migration script for existing setups (`migrate-to-new-config.sh`)
  - Comprehensive verification script (`verify-setup.sh`)
  - Updated `fleet-reporter.sh` to read new config system with auth token support
  - Quick reference card and updated documentation

---

## [1.0.0] - 2026-01-15

Initial release establishing the Academy infrastructure baseline.

### Added

#### LCARS UI
- Star Trek-themed web dashboard with fleet monitoring
- Backup status tab with dual timestamps (local and relative)
- Commands tab with section-based navigation and layouts
- Machine cards display for all development teams
- Activity log integration with real-time updates
- Responsive swimlane display system

#### Kanban System
- Terminal-based kanban board management (`kanban-helpers.sh`)
- File locking for concurrent access safety
- Swimlane responsive display with priority indicators
- Subitem management with hierarchical structure
- Auto-linking from git branch names (XACA-#### pattern)
- Due date support with urgency indicators
- Clickable tag pills for filtering
- Multi-team board support (iOS, Android, Firebase, Academy, Command, DNS, Freelance, MainEvent)

#### Git Worktree System
- Multi-project worktree management (`worktree-helpers.sh`)
- Support for iOS, Android, and Firebase projects
- Dynamic project detection for Freelance and MainEvent contexts
- Branch-aware context switching
- Automatic worktree cleanup and validation
- Context-aware naming conventions (feature/hotfix/refactor/release/test)

#### Fleet Monitor
- Node.js microservice for tmux session monitoring
- Distributed team status tracking across terminal windows
- RESTful API endpoints for dashboard integration
- Real-time status updates

#### Skills
- 15 specialized Claude capability definitions
- Main Event RELNOTES Manager (6-environment lifecycle)
- Kanban Manager with full subitem support
- Team Mission Status generator with intelligent expansion
- Weekly report generators (5 report types):
  - Weekly Stakeholder Update
  - Weekly Email Newsletter
  - Marketing Summary
  - Scrum of Scrums ME APP
  - Center Management App Update
- Git worktree management skill
- Workflow description updater

#### Team Infrastructure
- 8 development team configurations
- 50+ zshrc shell profiles with team-specific settings
- Star Trek persona system for agent identity
- Terminal badge integration for visual identification
- Team-specific tool access and permissions
- Hierarchical command structure (Command team oversight)

---

## Versioning Guidelines

**MAJOR (X.0.0):** Breaking changes
- Kanban JSON schema changes
- Worktree protocol changes
- API breaking changes
- Shell helper interface changes

**MINOR (0.X.0):** New features
- New LCARS tabs or views
- New skills added
- New team support
- New helper functions

**PATCH (0.0.X):** Bug fixes
- UI fixes
- Script bug fixes
- Documentation updates
- Configuration corrections
