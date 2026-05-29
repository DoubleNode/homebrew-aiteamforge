<!--
  CHANGELOG.md
  DoubleNode Dev-Team Infrastructure (AITeamForge)

  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
-->

# LCARS UI Changelog

All notable changes to the LCARS Kanban Workflow Monitor will be documented in this file.

## [Unreleased]

<!-- XACA-0582: acknowledgePreflightDeltas operator override for migration import-apply -->

### Added
- **XACA-0582: `acknowledgePreflightDeltas` operator override in `handle_import_apply`.** New body-JSON flag (bool, default false) that lets a migration import proceed when the preflight verifier reports `baseMatch=false`. The gate is circular for migration payloads: files such as `user_state`, `export_kanban`, `export_database`, and `git` are "missing on destination" only because the import that creates them has not run yet. Type-aware coercion mirrors `acknowledgeMissingSecrets` exactly (only `true` bool / int `1` / case-insensitive `"true"/"yes"/"1"` are accepted; `"false"` string → false). Emits a prominent `[LCARS Import] OPERATOR OVERRIDE` audit log line when the override is active. The HTTP 400 error response now includes `override_flag: 'acknowledgePreflightDeltas'` so the UI knows the override name. Body-JSON parse block hoisted above the baseMatch gate so both override flags are available before any gate decision.

<!-- XACA-0569: static-asset cache-bust — mtime-versioned URLs + no-cache parity -->

### Added
- **XACA-0569: mtime-based version query strings on `<script src>` / `<link href>` in served HTML.** `serve_no_cache_static` now rewrites local `.js`/`.css` refs to append `?v=<mtime>` when the served file is HTML (helper: `_version_html_refs`). Absolute URLs (http/https/protocol-relative/data:) and refs that already carry a query string are preserved as-is, so CDN refs and hand-versioned tags (e.g. `lcars.css?v=31.1`, `lcars.js?v=3.18`) keep their existing version. Eliminates the recurring "shipped fix looks missing" trap (most recently XACA-0568 v2 import pre-flight) without requiring operator hard-reloads.

### Changed
- **XACA-0569: `.css` now flows through `serve_no_cache_static`.** Dispatcher updated to route `.js` / `.html` / `.css` (and `/`) to the no-cache helper; everything else (images, fonts) still falls through to `super().do_GET()` with default caching. CSS responses now carry `Content-Type: text/css` + `Cache-Control: no-cache, no-store, must-revalidate` + `Pragma: no-cache` + `Expires: 0` instead of the SimpleHTTPRequestHandler default (no Cache-Control header).
- **XACA-0569: HEAD parity with GET for static `.js` / `.html` / `.css`.** `do_HEAD` now mirrors the GET static dispatch and calls `serve_no_cache_static(path, head_only=True)`. Curl `-I` and other tooling probes see the same no-cache headers as a GET — closes a parity gap where HEAD fell through to `super().do_HEAD()` and returned the default cache headers.

<!-- XACA-0281 Phase A.3: LCARS Settings → Team Config tab (account control surface) -->

### Added
- **XACA-0281 (Phase A.3): LCARS Team Config tab — AI engine account control surface.** Replaces the placeholder Team Config tab with a real per-team account control surface backed by a fleet-wide AI engines registry (Fleet Monitor). Architecture: machine-local team-paths.json stays the source of truth for A.1's resolver (no breaking changes); Fleet Monitor owns the fleet-wide registry of engines + accounts; LCARS Settings loads the registry on tab open with a local cache fallback so team startup is offline-clean.
- **XACA-0281-001/002:** New `team-account-routing` block in `lcars-ui/index.html` (Team Config section): per-team accordion with nickname + truncated account_id + status dot (green = validated, amber = unvalidated, red = no credentials), `<template>` row clone, plus a `#team-account-edit-modal` manual-override modal (free-form account_id/nickname/env_var_name + TEST CONNECTION/SAVE/CANCEL).
- **XACA-0281-003:** `GET /api/team-config/account/current?team=<id>` — returns `{account_id, account_nickname, env_var_name, has_credentials, last_validated_at}`. Never returns the key value. `has_credentials` derived from `os.environ.get(env_var_name)`. `last_validated_at` sourced from `~/.aiteamforge/account-validation.json`.
- **XACA-0281-004:** `POST /api/team-config/account/save` — manual-override save path; mirrors free-form fields into team-paths.json (`anthropic_account_id`, `anthropic_account_nickname`, `anthropic_api_key_env_var`). Atomic write. `env_var_name` validated against `^[A-Z][A-Z0-9_]*$`. NEVER stores the actual key.
- **XACA-0281-005:** `POST /api/team-config/account/test-connection` — probes Anthropic API with `claude-haiku-4-5` / `max_tokens=1`. Returns `{ok, account_fingerprint, model_access, error}` with the fingerprint masked (`sk-an****…XY4Z`). Writes the success timestamp to the validation cache. urllib only — no new deps.
- **XACA-0281-006:** `GET /api/team-config/account/running-sessions?team=<id>` — scans `~/.claude/.session-account-map.jsonl` for live-PID entries matching `<team>`. Returns `{sessions: [{pid, terminal, started_at, cwd, account_id}]}`. Liveness via `os.kill(pid, 0)`.
- **XACA-0281-007:** Running-sessions warning modal (`#team-account-running-sessions-modal`) shown before committing an AI engine account swap when active Claude sessions exist on the old account. Modal displays session count, summary text, and a per-session list (PID, terminal, truncated cwd, relative start time). Three action buttons: CANCEL (aborts swap), SAVE AND NOTIFY (proceeds; notification mechanism is a TODO placeholder for a future ticket), SAVE ANYWAY (proceeds). Pre-assign guard wired into both `onAccountPickerChange` (picker path) and `saveTeamAccountConfig` (manual-override path) — modal is skipped when the account is not actually changing.
- **XACA-0281-008:** Resume-ID handling modal (`#team-account-resume-ids-modal`) shown after a successful account swap when orphaned resume points exist on the old account. Queries `GET /api/team-config/account/resume-ids/count` post-swap; skips silently if count is zero. Radio options: Preserve (default/recommended; A.1's segregation keeps them isolated), Archive to backup (timestamped archive file), Clear (destructive). Apply fires `POST /api/team-config/account/resume-ids`. Backend (`server.py` ~line 9540+): atomic archive-then-rewrite for `archive` action; archive path returned in response.
- **XACA-0281-011:** Verified SETTINGS legend pill → `switchMode('settings')` → `pickDefaultSectionForMode('team-config')` → `loadTeamConfig()` → monkey-patched wrapper fires `loadTeamAccountList()` chain. Routing confirmed correct; no bugs found; no changes required.
- **XACA-0281-020:** `GET /api/engines/list[?refresh=true]` — proxies the Fleet Monitor `/api/engines` registry; on failure (timeout, refused, parse error), falls back to a local cache at `~/.aiteamforge/engines-cache.json` with `_source: "local_cache"` + `_cache_age_seconds`. Final fallback returns `_source: "empty"` with HTTP 200 so the UI always renders. `FLEET_MONITOR_URL` constant configurable via env (default `http://localhost:8080`).
- **XACA-0281-021:** `POST /api/team-config/account/assign` — copy-on-select mirror: given `{team, engine_slug, account_slug}`, looks up the registry (fresh fetch, cache fallback) and mirrors `account_id`/`nickname`/`env_var_name` into the team's record in team-paths.json. Also writes a new informational `anthropic_account_ref` field for drift detection. Atomic write. Returns `{success, team, engine_slug, account_slug, mirrored, has_credentials}` — never the key.
- **XACA-0281-022:** Per-team account picker dropdown (default flow). `js/lcars-team-account.js` clones each team row's template, injects a `<select class="team-account-picker">` populated from `/api/engines/list` (optgrouped per engine), with an "+ ADD NEW" sentinel option that links to Fleet Monitor. Picker selection POSTs to `/api/team-config/account/assign`. Existing free-form edit modal demoted to a small "MANUAL" affordance. Status dot logic: ok / amber / missing based on `has_credentials` + `last_validated_at` recency (7d threshold).

### Changed
- **XACA-0281 naming generalization:** "Anthropic Account Routing" section header renamed to **"AI Engine Account Routing"** in `index.html` (LCARS Team Config panel). Hint text updated to reference "AI engine account" rather than "Anthropic account". Picker `aria-label` updated to "Select AI engine account for …". Technical field names (`anthropic_account_id`, etc.) unchanged — those are A.1's resolver contract.

<!-- XACA-0335: CHANGE REQ — AGE column (XACA-0305 review verdict) -->

### Added
- **XACA-0335:** New **AGE** column on the CHANGE REQ tab, slotted between STAGE AGE and DOCS (post-rebase: 12-cell `CR_COL_COUNT` after picking up XACA-0349's EDIT column on develop). Renders the total CR age from `cr_created_at` (fallback `addedAt`) in compact relative form (`15m`, `3h`, `2d`, `3w`, `2mo`). Each cell carries a `title=""` tooltip with the absolute ISO timestamp — folds the REQUESTED-AT use case into a hover affordance, matching the XACA-0305 CAB-stakeholder review verdict. Suppressed to `—` on terminal states (`deployed-prod`, `emergency-deployed`, `cr-rejected`) — the codebase-canonical TERMINAL set used by SAVED_VIEWS — since the queue-management signal goes to zero once a CR is done. AGE added to filter-bar `SORT_VALUES` with an oldest-first comparator (mirrors the existing STAGE-AGE pattern; null/terminal-state ages sink to the bottom). New `.cr-col-age` CSS rule (75px width, center-aligned, nowrap) plus a `<600px` viewport hide rule that matches DEPLOY WINDOW responsive behavior. Header comment "9-column tabular layout" updated to "10-column" — the count had drifted across XACA-0293/0308-004/0353; this brings it back into agreement with the rendered layout.
- **XACA-0335 [Review] follow-up:** Compute/format helpers extracted from the `lcars-cr-tab.js` IIFE into a new `lcars-ui/js/lcars-cr-age-helpers.js` module (dual browser-global + CommonJS exports, same SSOT pattern as `lcars-cr-metrics.js`). New test suite `lcars-ui/tests/test_cr_age_helpers.js` — 34 cases covering every `formatRelativeAge` boundary bucket (m/h/d/w/mo + clock-skew clamp), `computeCRAgeMs` happy path with injectable `now`, terminal-state suppression for each of the 3 terminal states, fallback chain (`cr_created_at` → `addedAt`, both empty, both missing), invalid-input guards (null/undefined item, garbage date), and an SSOT invariant test that greps `lcars-cr-tab.js` for the canonical `TERMINAL` set and asserts equivalence with `AGE_TERMINAL_STATES` — fails CI if either set drifts. Total CR-tab JS test coverage: 49 (15 existing `cr-metrics` + 34 new `cr-age-helpers`). Renderer (`_ageCell`) and the AGE sort branch stay inside the IIFE — they touch the DOM contract (`escapeHtml`, `.cr-age` / `.cr-age-empty` classes) and are exercised through integration, not unit tests.

<!-- XACA-0351: Daily Overview — completed-item filter + per-card detail popup -->

### Fixed
- **XACA-0351-001:** Daily Overview was surfacing kanban backlog items even after they were marked `completed`/`done`/`cancelled`. `_collect_kanban_items_due` in `server.py` now skips terminal-state items before the dueDate check (mirroring the filter `_collect_kanban_todos` already had). 4 regression tests added in `test_daily_overview_endpoint.py::TestKanbanItemsDue` covering each terminal state plus an active-with-completed-sibling case.

### Added
- **XACA-0351 detail popup:** Tap any card on the Daily Overview to open a per-item detail popup. Modal shell (backdrop, ESC, click-outside, focus restore) lives in new `lcars-ui/js/daily-overview-popup.js` with category-specific renderers for all 7 sources (`kanban_todos`, `kanban_items_due`, `change_requests`, `backup_failures`, `calendar_items`, `releases`, `alert`). Kanban-style IDs inside body text (`XACA-NNNN`, `EPIC-NNNN`, `REL-NNNN`, etc.) render as deep-link anchors that close the popup and route via `switchSection`. Cards are now `role="button" tabindex="0"` so Enter/Space open the popup; existing dismiss/complete/deep-link icon buttons keep their behaviour (`stopPropagation` on the action button path so card click does not double-fire).
- **XACA-0351 backend enrichment:** Each item in `GET /api/daily-overview` now carries a `details` sub-object whose `kind` matches the category and whose required keys are present for the popup renderer (todo body, kanban description + subitem ratio + linked-item IDs, CR state/customer/summary, backup `last_error`, calendar source/start/end, release environments map, alert body/source/metadata/dedupe_key). 9 new unit tests in `TestPopupDetails` plus an explicit regression for the "Dedupe test v2" shape (alert with `body=null`, `source='qa-test'` produces a usable details dict). Total: 163 daily-overview + alert tests passing.
- **XACA-0351 popup styles:** New section in `daily-overview.css` covering the popup shell, key/value table, status/priority pills, environment chips, and deep-link anchor styling. Card hover/focus states added so the new tap-to-open affordance is discoverable.

### Fixed (PR #351 reviewer follow-ups, subitems 010–012)
- **XACA-0351-010:** `_priorityPill` now applies the same `[^a-z0-9_-]` whitelist sanitization on the class suffix that `_statusPill` already used. Defence-in-depth — `escapeHtml` already covers attribute escaping, but consistency between the two pill helpers prevents future drift.
- **XACA-0351-011:** Added a JSDoc comment to the `_keydownWired` singleton flag clarifying that the listener is intentionally module-lifetime (install-once on first popup open) — not a leak.
- **XACA-0351-012:** Tightened the `_bodyHtml` linkifier regex from a broad `[A-Z][A-Z0-9]+-\d{1,6}` to an anchored alternation against a fixed prefix list (`XACA`, `MEAPP`, `IOSAPP`, `ANDAPP`, `FBAPP`, `DNS`, `EPIC`, `REL`, `CR`). Generic uppercase-token-dash-number patterns in alert bodies (e.g. `HTTP-200`, `ISO-8601`, `RFC-7231`) no longer render as false deep-links.

<!-- XACA-0334: Daily Overview — sidebar restructure + section registration -->

### Added
- **XACA-0334 PR #346 follow-ups (subitems 012–017):** Six reviewer/tester subitems implemented: (014) `_fetchAndRender()` private helper extracted from `daily-overview.js` — `loadDailyOverview()` and the refresh-button path both call it with an optional callback, eliminating ~40 LOC of duplication; (015) `_sort_key_for_items` in `server.py` converted from `@staticmethod` to `@classmethod` and now references `cls._SEV_RANK` instead of re-declaring a local dict; (016) `_append_to_archive` in `server.py` wraps `json.load()` in `try/except (json.JSONDecodeError, OSError)` — corrupt/unreadable archive is re-initialised rather than 500-ing the dismiss/evict caller; (017) inline comment added after the `2026 - 2025` copyright range in both `daily-overview.css` and `daily-overview.js` clarifying the order is intentional per `COPYRIGHT_POLICY.md § 4.8`; (012) calendar adapter extended to read `<team-kanban-dir>/calendar/events.json` (schema: `{version, events:[{id, title, start, end?, all_day?, link?}]}`), merging events whose `start` date ≤ today into the calendar category — missing or malformed file falls back gracefully; (013) backup_failures adapter gains per-team awareness via `<team-kanban-dir>/backups/status.json` (schema: `{version, last_run, status:ok|stale|failed, last_error?}`) — per-team file preferred when present, global file used as fallback; when both are non-ok both entries surface. 25 new unit tests added across `test_alert_endpoints.py` (4 corrupt-archive-recovery tests) and `test_daily_overview_endpoint.py` (13 calendar events.json tests + 8 per-team backup status tests). Total: 150 tests, all passing.

- **XACA-0334 copyright headers:** Applied DoubleNode copyright headers (per `COPYRIGHT_POLICY.md`) to the 4 new files this branch creates: `lcars-ui/js/daily-overview.js`, `lcars-ui/css/daily-overview.css`, `lcars-ui/tests/test_alert_endpoints.py`, `lcars-ui/tests/test_daily_overview_endpoint.py`. CSS hand-crafted in `/* */` style (not in policy template table); JS uses `//` Swift-style; Python headers placed after shebang per § 2.3.5. Modified-but-not-new files (`server.py`, `lcars.js`, `lcars.css`, `index.html`) remain untouched — broader `lcars-ui/` and `fleet-monitor/` backfill is tracked under XACA-0336 (EPIC-0015 child). All 125 tests still pass after header insertion.
- **XACA-0334-007:** 9 additional unit tests across `test_alert_endpoints.py` and `test_daily_overview_endpoint.py` covering: archive append-only correctness (second dismiss appends to same monthly file; eviction preserves pre-existing archive entries), concurrent dedupe-key writes via threads, malformed global/team config JSON falls back to defaults, corrupt board JSON returns graceful empty response, `board.todos` as non-array handled gracefully, corrupt `active.json` returns empty alert bucket, corrupt `backup-status.json` returns empty. Total: 125 tests, all passing.


- **XACA-0334-006:** Daily Overview interactions wired in `lcars-ui/js/daily-overview.js`. Manual **REFRESH** button added to `.daily-overview-section .section-header` (`#do-refresh-btn`; disabled + "REFRESHING…" label while fetch is in-flight). Single delegated `click` listener on `#daily-overview-grid` routes by `data-action`: **dismiss** fires `POST /api/alerts/<id>/dismiss {team}` (only when `dismissable: true`) → optimistic card removal + re-fetch; **complete** fires `PUT /api/todos {team, id, updates:{status:"completed"}}` (only when `completable: true`) → optimistic card removal + re-fetch; **deep-link** calls `switchSection(source_view)` to navigate to the source section. Error paths show non-blocking `showToast(..., 'error')`. No polling — manual refresh only (spec § 2.3). `initDailyOverviewInteractions()` exported and called once from `DOMContentLoaded` in `lcars.js`. CSS: action buttons upgraded to `cursor:pointer` with hover + `focus-visible` outlines; `.do-refresh-btn` pill added to `daily-overview.css`.
- **XACA-0334-005:** Daily Overview grid renderer. New `lcars-ui/js/daily-overview.js` fetches `GET /api/daily-overview?team=<team>` on section entrance and renders 7 category cells into `#daily-overview-grid`. No-scroll CSS grid layout (`daily-overview.css`) targets 1280×720 minimum viewport with fixed 32px card rows, severity color bars/dots (spec § 4.4 hex palette), overflow `+N MORE` chips, and empty-state placeholders that hold grid position when `total === 0`. Action icon buttons (dismiss/complete/deep-link) are DOM-present as accessible `<button>` elements with `data-action`/`data-id`/`data-source-view` attributes; event handlers deferred to subitem 006. `/api/daily-overview` added to `TEAM_SCOPED_PREFIXES` for auto team-param injection. Section show/hide, animation entrance/exit, and sidebar button colors added to `lcars.css`.
- **XACA-0334-003:** Daily Overview aggregator endpoint `GET /api/daily-overview?team=<id>`. Returns 7 ordered categories (`kanban_todos`, `kanban_items_due`, `change_requests`, `backup_failures`, `calendar_items`, `releases`, `alert`) each with `top_n`/`total`/`overflow`/`items`. Items share a uniform schema with `dismissable`/`completable` flags; sorted by severity desc + due_at asc. Alerts with matching `category` merge into structural buckets per spec §2.7. Config-driven `top_n` and `label` loaded from `lcars-ui/config/daily-overview.json` (global defaults) merged with per-team `<kanban-dir>/config/daily-overview.json` overrides (live-editable). Unknown team → 400. Sources with unreachable data return `total: 0` with TODO comments for subitem 007. 61 unit tests added in `tests/test_daily_overview_endpoint.py`.
- **XACA-0334-003:** `lcars-ui/config/daily-overview.json` created with defaults: kanban_todos/kanban_items_due/calendar_items/alert top_n=5; change_requests/backup_failures/releases top_n=3.
- **XACA-0334-002:** Alert ingestion API (`POST /api/alerts`, `GET /api/alerts`, `GET /api/alerts/<id>`, `DELETE /api/alerts/<id>`, `POST /api/alerts/<id>/dismiss`). Alerts scoped per-team via `TEAM_KANBAN_DIRS`; active store at `<team-kanban-dir>/alerts/active.json`; dismissed alerts archived to `<team-kanban-dir>/alerts/archive/YYYY-MM.json`. Supports dedupe upsert via `dedupe_key`, ISO-8601 `expires_at` filtering, hard-delete (no audit trail), soft-dismiss (preserves history), and 1000-alert-per-team eviction ceiling. Full field validation (severity enum, category enum, metadata-must-be-object, title/body length). Uses existing `_atomic_write_json` + `fcntl.flock` for concurrent-safe writes.
- **XACA-0334-004:** New `daily-overview` section registered in LCARS. Sidebar kanban-mode gets a new HOME button (routes to `daily-overview`) above a renamed ANALYTICS button (former HOME, still routes to `data-section="home"`). Mobile tab bar mirrors the change. The `daily-overview-section` DOM stub added to `index.html` (grid populated in subitem 005). `pickDefaultSectionForMode('kanban')` now returns `'daily-overview'` so kanban mode lands on the Daily Overview by default.

<!-- XACA-0333: Team Config UI hardening — XACA-0332 advisory follow-ups -->

### Fixed
- **XACA-0333-001:** Advisory `*.json.lock` files left by `_write_copyright_config` and `handle_update_team_config` are now `unlink()`-ed after `LOCK_UN` (best-effort, swallows `OSError`). A startup `_sweep_stale_locks()` removes stranded zero-byte locks older than 60s — targets `~/.aiteamforge/*.lock` and every canonical `<team>-board.json.lock`.
- **XACA-0333-002:** `_read_copyright_config` uses an mtime-based class-level cache (`_TEAM_PATHS_CACHE` keyed by `st_mtime_ns`) so repeat GETs to `/api/team-config` no longer re-read `team-paths.json` from disk. Cache invalidates on `_write_copyright_config` success. Thread-safe via `_TEAM_PATHS_CACHE_LOCK`.
- **XACA-0333-003:** Server is now the single source of truth for the TBD-sentinel string set (`_COPYRIGHT_PLACEHOLDER_VALUES`). GET/POST responses include a per-field `copyright.is_placeholder = { copyright_owner: bool, ... }` map. The JS hardcoded `_COPYRIGHT_TBD_VALUES` list is removed; `_populateCopyrightFields` reads `is_placeholder[key]` instead.
- **XACA-0333-004:** `handle_update_team_config` wraps the board.json lock+read+merge+write in `if clean_team_config:`. Copyright-only POSTs no longer acquire the board lock or do a no-op fsync.
- **XACA-0333-005:** POST response always includes the saved `teamConfig.copyright` block (with `is_placeholder`), read fresh from `team-paths.json` after writes. When 004's guard skips the board write, response re-reads the board for `crSupport`. JS local-form fallback in `saveTeamConfigCopyright` removed (dead code).
- **XACA-0333-006:** PR #347 review advisory. `dict.get('teamConfig', {})` falls back to default only when the key is absent, not when it's `None`. Switched to `dict.get('teamConfig') or {}` in the GET handler and POST response builder so a hand-edited `"teamConfig": null` board JSON cannot crash `setdefault`.

<!-- XACA-0304: Converge BACKLOG and CHANGE REQ filter bars onto lcars-filter-bar.js -->

### Changed
- **XACA-0304-001:** `js/lcars-filter-bar.js` extended with four optional config blocks — `searchIds`, `pillGroups[]` (multi/single pill modes), `sortControl` (N-value cycle button), and `customDropdowns[]` (generic `<select>` wiring). Defaults preserve original BACKLOG behavior; BACKLOG `createFilterBar()` init is unchanged.
- **XACA-0304-002:** `index.html` — CR filter-bar HTML is now static markup. Previously injected at runtime via a `container.innerHTML` template literal in `_wireCRFilterBar`.
- **XACA-0304-003:** `js/lcars-cr-tab.js` deleted `_filterState`, `_loadFilterState`, `_saveFilterState`, `_wireCRFilterBar`, `_syncStatePills`, `_syncTypePills`, plus `FILTER_KEY` / `SORT_VALUES` constants (~180 LOC of duplicate filter-bar plumbing). Replaced with a single `createFilterBar({...})` call. Net: −81 lines in this file. localStorage keys unchanged (`lcars-queue-filter` for BACKLOG, `lcars-change-req-filter` for CR) — no migration needed.
- **XACA-0304-004:** Saved-view chips (THIS WEEK / AWAITING APPROVAL / EMERGENCY 30D) now drive `fb.setState(preset)`. Added an `_applyingSavedView` re-entrancy guard plus a non-sort-fields snapshot so the active chip is not cleared on sort cycles or self-applied presets. Resolves the Wave 3G TODO noted in XACA-0292-007 ("future refactor could unify them").
- **XACA-0304-006:** CR platform dropdown `.active` parity — added `id="cr-platform-wrap"` to the wrapping `<div>` and pointed `customDropdowns.dropdownId` at the wrapper, matching the OS / release / epic / category convention.
- **XACA-0304-007:** `fb.snapshot(keys)` hoisted into `createFilterBar` as a public method (deterministic over arrays + null/undefined). CR tab now calls `_filterBar.snapshot(SAVED_VIEW_DIVERGE_KEYS)` instead of carrying its own `_filterSnap` helper, so future consumers can request their own non-sort snapshots without duplicating field lists.

<!-- XACA-0293: CAB Workflow Phase 3 — Cycle-Time Metrics -->

### Added
- **XACA-0293-011:** Add Node-native test_cr_metrics.js (15 cases against gold-standard fixture); ESLint clean across all 4 CR JS modules (3 new modules zero errors; 8 pre-existing errors in lcars-cr-tab.js from XACA-0328 code documented); manual UI exercise performed via code inspection with justification (server not running).
- **XACA-0293-005:** View 2 estimate-vs-actual tile — avg deploy_estimate_delta_days with HIT/EARLY/LATE breakdown over rolling 14-day window; color-coded health badge (green/yellow/red, tunable in Phase 7).
- **XACA-0293-004:** View 2 segment rollup tiles — 7 cycle-time tiles (avg / median / sample count) across the rolling 14-day window; refresh on board update; empty-state handling for low-sample windows.
- **XACA-0293-006:** Add cr-metrics fixture (5+ CRs covering happy/gap/emergency/out-of-window/early paths) + reconciliation doc + Node smoke check.
- **XACA-0293-003:** View 2 scaffold — PIPELINE | CYCLE TIME sub-tab toggle inside #section-change-req; 8 empty chart-card tiles for cycle-time rollups (rendered by 004/005).
- **XACA-0293-002:** View 1 Active CR Pipeline — ACTIVE PIPELINE saved-view chip (filters non-terminal cr-* states); STAGE AGE column with color-coded aging badge (green/yellow/red thresholds tunable in Phase 7).
- **XACA-0293-001:** Add lcars-cr-metrics.js — pure-JS cycle-time derivation + rolling-window aggregation helpers.

<!-- XACA-0310: CAB Workflow Phase 2.5 — CR-row expansion + BACKLOG CR filter -->

### Fixed
- **XACA-0310-013:** `renderChangeReqList` no longer rebuilds the backlog index — it reuses `_lastBacklogIdx` populated by `_getCRItems()`. Eliminates the duplicate O(n) walk over `boardData.backlog` on every render.
- **XACA-0310-014:** Chevron expand/collapse now uses DOM surgery (insert/remove the children row in place) instead of triggering a full `renderChangeReqList()` re-render. Avoids wiping every event listener on every toggle. New `_toggleCRExpansion()` and `_wireChildCopyButton()` helpers extracted.
- **XACA-0310-016:** Added CSS rules for `.cr-filter-dropdown` / `.cr-filter-label` / `.cr-filter-select` (mirrors category-filter pattern with cyan accent) so the BACKLOG CR filter renders properly when `crSupport.enabled = true`.

### Changed
- **XACA-0310-015:** `_showCRDocModal` TODO comment for the future CR-keyed server endpoint now references the parent XACA-0310 ticket to track the follow-up.

### Added
- **XACA-0310-001:** `_normalizeCR` now preserves `linkedItemIds[]` (full array of linked item ids). `_renderRow` shows a `cr-item-count` badge in the TITLE cell when a CR has more than one linked item (e.g. "3 items").
- **XACA-0310-002:** Expandable CR rows — chevron button in col-0 toggles a `cr-children-row` showing all linked kanban items (id, title, status). Child item ids are copyable via `copyToClipboard()`. Expansion state is preserved across re-renders in `_expandedCRs` Set keyed by `cr_id`.
- **XACA-0310-005:** `_showCRDocModal` now reads `cr_doc_link` directly from the CR record. External URLs (`https?://`) render metadata + launch button only (no fetch). Relative paths fall back to item-keyed `/api/kanban/<id>/cr-content` endpoint using the first linked item id. `_renderCRMetadata` now lists ALL linked items (not just one) in the LINKED ITEMS metadata cell.
- **XACA-0310-007:** `SAVED_VIEWS` predicates verified against CR record timestamps. Added comment block documenting that predicates evaluate against normalized CR view-objects (not backlog items) post-XACA-0310. `emergency-30d` predicate comment updated to document `cr_emergency_deployed_at` / `cr_completed_at` / `addedAt` fallback chain.

<!-- XACA-0292: CAB Workflow Phase 2 — UI layer (EPIC-0017) -->

### Fixed
- **XACA-0292-013:** `renderMarkdown` XSS hardening — raw content is now HTML-escaped before any regex substitution, so embedded `<script>` tags or raw HTML in CR docs become inert entities. Code blocks are extracted into placeholders prior to escaping (preserving verbatim display) and restored afterward. A new `validateUrlScheme` helper enforces an allow-list of safe link schemes (`http:`, `https:`, `mailto:`, relative paths); `javascript:`, `data:`, `vbscript:`, and any other unlisted schemes are rejected — the anchor is dropped and only the link text is rendered.
- **XACA-0292-011:** `serve_team_config` (GET) and `handle_update_team_config` (POST `/api/team-config`) now validate the `team` parameter against the `TEAM_KANBAN_DIRS` allow-list before touching the filesystem. Unknown or path-traversal values (e.g. `../foo`) → HTTP 400 `{"error": "Unknown team: <team>"}`.
- **XACA-0292-012:** `handle_update_team_config` now schema-validates the `teamConfig` payload. Only `crSupport` is accepted as a top-level key; only `enabled` (bool) and `description` (str, optional) are accepted under it. Unknown keys at either level → HTTP 400. A clean payload is constructed from validated values; no attacker-controlled keys are ever written to the board JSON.
- **XACA-0292-014:** OS dropdown in `lcars-filter-bar.js` replaced `innerHTML` interpolation of `cfg.logo`/`cfg.label` config strings with DOM node construction (`createElement` + `textContent` / `img.src`). `cfg.logo` is a URL, so `<img>` is built via DOM; static developer-controlled SVG retains a single `innerHTML` assignment on a fresh element with a comment explaining the decision.
- **XACA-0292-010:** `serve_plan_exists` 500-path now includes `crExists: False` so the error response schema matches the success path.
- **XACA-0292-015:** Removed dead `_abortCtrl` variable from `lcars-cr-tab.js` — declared but never assigned; AbortController not needed in synchronous data path.
- **XACA-0292-017:** Wrapped `itemId` in `escapeHtml()` in `showPlanDocModal` modal header innerHTML to prevent XSS injection via crafted item IDs.
- **XACA-0292 (PR #330 review):** `serve_cr_content` (`/api/kanban/<id>/cr-content`) now rejects absolute paths and validates that resolved relative paths stay inside the team's kanban directory. Closes a path-traversal vector reachable from every tailnet peer (server binds to all interfaces).

### Added
- **XACA-0292-008: Saved-view chips for CHANGE REQ section** -
  Three chip-style buttons rendered in `#change-req-saved-views` between the
  filter bar and the list: "THIS WEEK'S CRs" (items whose `cr_created_at` or
  `addedAt` falls in the current Mon–Sun ISO week), "AWAITING APPROVAL"
  (filter-bar preset `crState=cr-submitted`), and "EMERGENCY (30D)" (type=emergency
  AND (`cr_emergency_deployed_at` || `cr_completed_at` || `addedAt`) within 30 days).
  Active chip highlighted with orange/amber LCARS accent.  Saved-view predicate is
  AND-ed on top of the existing filter-bar result in `renderChangeReqList()`.
  Active view ID persisted at `localStorage['lcars-change-req-saved-view']`.
  Manual filter changes clear the active chip (divergence detection hooked into every
  filter-bar control except the sort cycle button).  CLEAR chip resets both filter
  state and active view.  Reload restores the persisted chip.
  Helpers `isWithinIsoWeek(tsMs)` and `isWithinLastNDays(tsMs, n)` added to
  `lcars-cr-tab.js`; absent timestamps return `false` (honest about missing data).
  CSS added to `lcars-cr-tab.css`.

- **XACA-0292-007: CHANGE REQ list view with filter bar and DOCS button** -
  New files `js/lcars-cr-tab.js` (exposes `initChangeReqTab()` / `renderChangeReqList()`)
  and `css/lcars-cr-tab.css`.  Renders a 9-column tabular list (CR ID, TYPE, STATE,
  TITLE, PLATFORM, APPROVER, DEPLOY WINDOW, PUSHBACKS, DOCS) populated from
  `boardData.backlog` items that carry a non-empty `cr_id`.  Filter bar mounted in
  `#change-req-filter-bar` with state pills (10 values), type pills (4 values),
  platform dropdown, sort-cycle button (STATE/TYPE/PLATFORM/APPROVER), and debounced
  search.  Filter state is persisted to localStorage under `lcars-change-req-filter`.
  Per-row DOCS button visible only when `cr_doc_link` is set; opens existing
  `showPlanDocModal` then calls `switchDocTab(itemId, 'cr')` after 20ms to land
  directly on the CR tab.  Section nav hook added in `switchSection` for `change-req`.
  Both new files linked in `index.html`.
  Note: the CR tab's filter bar logic is inline rather than consuming the shared
  `createFilterBar` component (Wave 3G decision) — both filter bars are visually
  similar but not code-shared. A future refactor could unify them.

- **XACA-0292-006: CHANGE REQ tab shell** -
  Added sidebar button (`#sidebar-btn-change-req`, `data-section="change-req"`),
  mobile tabbar button (`#tabbar-btn-change-req`), and section shell
  (`#section-change-req`, `.change-req-section[data-mode="kanban"]`) with header,
  empty-state list container (`#change-req-list`), and placeholder slots for filter
  bar (`#change-req-filter-bar`) and saved views (`#change-req-saved-views`).
  Added `'change-req'` to the SECTIONS array in `lcars.js` so routing works.
  Added `initChangeReqSection()` which fetches `/api/team-config` on page load and
  calls `applyChangeReqVisibility(enabled)` to show/hide all three elements without a
  page reload. Listens for the existing `crsupport-changed` DOM event for runtime
  toggles; navigates user back to BACKLOG if they are currently on CHANGE REQ when
  the flag is turned off. All three elements render with `style="display:none"`
  initially so the DOM is visually identical to the pre-change state when the flag
  is false. Minimal CSS rules added to `lcars.css` mirroring the BACKLOG section's
  color palette, fade-in transitions, and spacing.

- **XACA-0292-005: Extract reusable filter-bar component** -
  New file `js/lcars-filter-bar.js` exports `createFilterBar(options)` — a
  constructor-style component that encapsulates filter-bar state management,
  localStorage persistence, pill/sort/OS/release/epic/category/search event
  wiring, and an optional view toggle.  Public API: `getState()`, `setState(partial)`,
  `refresh()`, `filterItems(items, matchFn)`, `populateReleaseOptions()`,
  `populateEpicOptions()`, `updateReleaseStyle()`, `save()`.
  BACKLOG behavior is unchanged; `backlogFilterState` now references the
  component's live state object.  External callers of `saveQueueFilterState`,
  `populateReleaseFilterOptions`, `populateEpicFilterOptions`, and
  `updateReleaseDropdownStyle` are forwarded via thin stubs in `lcars.js`.
  Script tag added to `index.html` before `lcars.js`.

- **XACA-0292-004: CR tab in item DOCS popup** -
  `showPlanDocModal(itemId, retroExists, crExists)` gains a third parameter.
  A CR tab appears when `crSupport.enabled` is true for the board AND the item's
  `cr_id` is non-empty; otherwise the tab bar is identical to before.
  `checkPlanExists` now stores `data-cr-exists` on the DOCS button alongside
  `data-retro-exists` (single request, no extra round-trip) using the extended
  `plan-exists` response. Clicking the CR tab calls
  `GET /api/kanban/<id>/cr-content` and renders via `renderMarkdown()`.
  New `GET /api/kanban/<id>/cr-exists` endpoint mirrors `retro-exists`.
  All 6 callers of `showPlanDocModal` updated to pass the third argument.
  CSS adds distinct orange active/hover colours for the CR tab while
  preserving existing 1-tab and 2-tab layouts unchanged.

- **XACA-0292-003: Add `/api/kanban/<id>/cr-content` endpoint** -
  New GET endpoint mirroring `plan-content` and `retro-content`. Looks up the
  kanban item by ID, reads the `cr_doc_link` field, resolves absolute or relative
  paths against the team's kanban directory, and returns
  `{ "content": "...", "itemId": "...", "filename": "..." }`. Returns 404 if the
  item is not found, `cr_doc_link` is empty/missing, or the file does not exist
  on disk. No gating on `crSupport.enabled` — endpoint is visibility-agnostic.

- **XACA-0292-002: SETTINGS → TEAM CONFIG → "Enable CR (CAB) support" checkbox** -
  Replaced the `team-config-placeholder` in `index.html` with a real config form.
  Added `GET /api/team-config?team=<team>` (returns `{ teamConfig: { crSupport: { enabled: bool } } }`)
  and `POST /api/team-config` (deep-merges payload into `teamConfig` in the board JSON
  using file lock + atomic write). On checkbox toggle the UI shows a "Saving..." /
  "Saved" inline indicator, then dispatches a `crsupport-changed` DOM CustomEvent with
  `{ enabled: bool }` detail so downstream agents can react without a page reload.
  Default value is `false` (no-op when `teamConfig` key is absent from board JSON).

### Changed
- **XACA-0292-001: Rename QUEUE → BACKLOG throughout LCARS UI** -
  Unconditional rename of all kanban "queue" identifiers and labels to "backlog".
  Covers `index.html` (sidebar button `data-section`, `<span>` labels, section class,
  section title "MISSION BACKLOG", all element IDs), `css/lcars.css` (all `.queue-*`
  class selectors → `.backlog-*`, sidebar active-state rule, transition/animation
  blocks, comment headers), and `js/lcars.js` (SECTIONS array entry, DOM ID lookups,
  CSS class string literals, `BACKLOG_FILTER_KEY` constant, `backlogFilterState`
  variable, `renderMissionBacklog`/`createBacklogItem`/`toggleBacklogItemExpansion`/
  `navigateToBacklogItem` function names, all querySelector/className references).
  The localStorage key `'lcars-queue-filter'` is intentionally preserved for
  backward compatibility. Non-kanban "queue" uses (fetch debounce comment, JS async
  queue comment, `sync-release-manifests.py` board-data field backward-compat check)
  are intentionally unchanged.

- **Main header title no longer ends with "STATUS"** -
  Trimmed the trailing `STATUS` from the LCARS header title in all three responsive
  variants (`.title-full`, `.title-medium`, `.title-short`) and the matching
  `document.title`. The header now renders e.g. `STARFLEET ACADEMY` instead of
  `STARFLEET ACADEMY STATUS`. The static `STATUS` placeholder in `index.html`
  for `.title-short` was replaced with `--` to align with the other two `--`
  placeholders. Inline section titles (`MISSION STATUS`, `BACKUP SYSTEM STATUS`,
  sidebar `WORKFLOW STATUS`) are unchanged — only the main page header.

### Fixed
- **XACA-0249: Team param now injected by UI for all team-scoped API calls** -
  Extended the existing `apiUrl()` helper to automatically append `?team=<CONFIG.team>`
  for known team-scoped endpoints (`/api/epics`, `/api/releases`, `/api/todos`,
  `/api/items`, `/api/release-config`, `/api/calendar/items`). The injection is
  guarded: only fires when `CONFIG.team` is truthy and the URL doesn't already
  carry a `team=` param, so no double-encoding or breakage on already-correct call
  sites. Fixes the bug where an academy server restarted without `LCARS_TEAM` env
  would silently serve freelance epics/releases to the academy UI.
- **XACA-0249: `/api/team` dedicated endpoint added** -
  New `GET /api/team` returns `{"team": "...", "team_was_explicit": bool,
  "default_used": bool}`. The UI's `loadServerConfig()` now falls back to this
  endpoint if `/api/status` fails or returns no team — guaranteeing `CONFIG.team`
  is always populated before the first team-scoped fetch fires. Includes a browser
  console warning when `default_used` is true so misconfiguration is visible to
  developers without digging into server logs.
- **XACA-0249: Server WARN log when team defaults silently to "freelance"** -
  `_get_board_file()` now detects the bad condition (no `?team=` from UI AND
  `LCARS_TEAM` env was unset at server start) and emits a throttled `[LCARS] WARN`
  log line — at most once per minute per endpoint path — so misconfiguration is
  unmissable in logs without flooding them under normal operation.

### Changed
- **ccusage collector cadence tuned for slow scans** (XACA-0243 follow-up) -
  Bumped `POLL_INTERVAL_S` from 30s to 180s and extracted/raised the
  ccusage subprocess timeout from a hardcoded 120s to a `CCUSAGE_TIMEOUT_S`
  constant of 240s in `ccusage_collector.py`. Direct measurement on a
  populated transcript dataset showed `ccusage blocks --json --since`
  taking ~65s typical and occasionally cresting 120s under disk/CPU
  contention, which polluted the cache with "ccusage timed out after 120s"
  failure entries (UI sees those as `ok:false`). The poll loop is
  sequential — `do_collection()` blocks for the scan, then sleeps
  `POLL_INTERVAL_S` — so polls never stack regardless of scan duration;
  the prior 30s interval just meant the loop spent more wall-clock waking
  up than waiting. Net effect: a fresh data point every ~3.5–4.5 min on a
  healthy system instead of bursts of timeouts. Dashboard "refresh"
  button (`?refresh=1`) stays as-is — it's an on-demand path, not bound
  by the daemon's polling cadence.

### Added
- **Claude Usage Monitor — full integration** (XACA-0243) -
  Surfaces real-time API token consumption from `ccusage` on the LCARS
  dashboard and every agent panel. Includes cached collector daemon
  (`ccusage_collector.py`), heuristics layer with GREEN/AMBER/RED band
  thresholds, new `/api/usage/current` endpoint, compact agent-panel
  indicator (top-of-panel, polls every 30s), full dashboard widget
  (current window progress, 7-day history, daily/weekly totals, calibration
  confidence), stale-data detection (hatched bars, untrustworthy overlays),
  and theme-aware styling (terminal accent color tints on agent panels).
  Projection math uses ccusage's own burn-rate smoothing; refreshes every
  ~30s cached, or on-demand via `?refresh=1` query param (slow, ~2 min).
  Band thresholds (60%/85%) calibrated against 30-day rolling max-window
  baseline; UNKNOWN until samples >= 5. See LCARS-README § Claude Usage
  Monitor for operations and troubleshooting.

- **Claude usage cache collector daemon** (XACA-0243-001) - New
  `ccusage_collector.py` daemon polls `ccusage blocks --json` every 30s
  and writes a normalised JSON cache to `/tmp/lcars-ccusage-cache.json`
  atomically. Cache includes active window (burn rate, projection,
  elapsed/remaining minutes), last 50 non-gap history windows, 30-day
  calibration stats (max + p90 token counts for UI progress-bar scaling),
  and today/7d cost totals. Error handling preserves last known good
  values on ccusage failure so UI can show stale-data warnings.
  `launch-ccusage-collector.sh` wrapper provided for launchd/supervisord
  integration.

### Fixed
- **ccusage collector daemon now self-heals** (XACA-0243 follow-up) - When
  `ccusage_collector.py` died (e.g. crash, fnm-multishells PATH drift,
  manual kill) nothing restarted it, so `/api/usage/current` would return
  `ok:false, stale:true` indefinitely until the LCARS server itself was
  restarted. Added `_ensure_collector_running()` watchdog in `server.py`
  invoked on every `/api/usage/current` request: cheap `kill(pid, 0)` fast
  path when healthy, throttled detached `Popen` (30s cooldown to prevent
  fork-bombing on crash-loop) when the PID is missing or dead. The
  dashboard "refresh" button (`?refresh=1`) also benefits — pressing it
  now resurrects a dead daemon in addition to running the synchronous
  `--once` scan, so a single click recovers from any collector outage.
  Adds 6 unit tests covering PID-alive detection (missing file, malformed
  contents, dead PID, live PID, cross-user `PermissionError`) and respawn
  throttling. Also extracts a `dim_color()` helper in
  `agent-panel-display.sh::render_usage_indicator` so the stale/offline
  branches no longer compound SGR escapes by raw string concatenation.

- **USAGE section displayed under other content + button moved to utility
  cluster** (XACA-0243 follow-up) - The USAGE section was missing from the
  `.lcars-content > *` hide-by-default and active-show CSS rule sets in
  `lcars.css`, so it was never given `position:absolute; display:none`
  treatment and rendered in normal document flow underneath whatever
  section was active. Also added `'usage'` to the `SECTIONS` array in
  `lcars.js` (without it, `switchSection('usage')` returned at the
  `indexOf === -1` guard before doing anything). Per UX feedback, the
  USAGE button has been moved out of the kanban-mode sidebar into the
  mode-bar utility cluster (next to VIEWSCREEN/SOUND) so it is globally
  available across all modes; widened the section's `data-mode` to
  `team kanban data settings`. Mobile tabbar entry retained.
- **Overlay modals: header/footer rendered as content-width pills above
  full-width body** (XACA-0246) - The base `.lcars-modal` rule at
  `lcars-ui/css/lcars.css:5988` declares `display: flex; align-items:
  center; justify-content: center` (intent: center the modal as a
  full-screen backdrop). The overlay-scoped rule
  `.lcars-modal-overlay .lcars-modal` overrides `display`/
  `flex-direction` to `flex` + `column` for vertical stacking but does
  not override `align-items`. Result: in column-flex mode,
  `align-items: center` makes header and footer shrink to their content
  width and render centered, producing a small pill-shaped header
  floating above full-width body content (visible on epic-assign,
  status-change, and any overlay modal whose body has explicit width).
  Fix: declare `align-items: stretch` explicitly on
  `.lcars-modal-overlay .lcars-modal` so cross-axis children fill the
  modal width.

### Changed
- **Plan/Retro doc popup widened to 1200px max-width** (XACA-0246) -
  Plan and retrospective markdown content (tables, code blocks, the
  Subitems table) was cramped at the previous effective max-width of
  500px. The `.plan-doc-modal { max-width: 800px }` declaration was
  losing on specificity (0,1,0) to
  `.lcars-modal-overlay .lcars-modal { max-width: 500px }` (0,2,0).
  New rule `#plan-doc-modal-overlay .lcars-modal { max-width: 1200px }`
  uses the unique overlay ID for specificity (1,1,0) so it wins cleanly
  without touching the broad rule's defaults for other modals — about
  50% wider than the prior effective rendering, on viewports that
  support it (still scales down via `width: 90%` on smaller windows).

### Reverted
- **Reverted PR #273 (XACA-0240 plan-doc popup fix)** -
  The scope-narrowing fix for plan-doc popup layout regressed worse than the
  original symptom. Root cause of the regression: the base `.lcars-modal`
  rule at `lcars-ui/css/lcars.css:5988` declares `display: flex` *without*
  `flex-direction: column` (defaulting to `row`). Before XACA-0240, the
  overlay-scoped rule `.lcars-modal-overlay .lcars-modal` overrode that
  with `display: flex; flex-direction: column` (added by `bd96cd07`).
  XACA-0240 removed that override under the assumption it was bd96cd07-new
  and therefore safe to scope-narrow — but the underlying base rule made
  `flex-direction: column` load-bearing for *every* overlay modal, not just
  the release-flow modal. Without the override, header and body laid out
  horizontally and content collapsed to a thin vertical strip on the right
  edge. Reverting restores the working state. The original plan-doc bug
  needs re-diagnosis before a new fix attempt.

### Added
- **PLANNED state as initial release platform state** (XACA-0238) -
  New release platforms now start in `PLANNED` state instead of `DEV`, signifying
  "created but not yet started." The full pipeline is now
  `PLANNED → DEV → QA → ALPHA → BETA → GAMMA → PROD`. First promotion advances
  a platform from PLANNED to DEV. The LCARS releases dashboard gains a third tab
  (**Planned / Active / Archived**); Planned tab shows releases where all platforms
  are still at PLANNED, Active tab shows releases with any platform at DEV+.
  PLANNED renders as neutral gray in platform badges and env-badge elements.

### Fixed
- **Collapsed release cards rendered invisible text after tab backgrounding** -
  `.release-card` gained `transform: translateZ(0)` to force an independent
  paint layer. On the Firebase releases view (and any board with ≥2 collapsed
  releases), cards after the first rendered as empty black regions with the
  team watermark bleeding through after the browser tab was hidden and
  restored; selecting text forced a repaint and content reappeared until the
  next tab backgrounding. Root cause is a Chromium/WebKit paint-invalidation
  bug triggered by `.release-card-items`'s idle `transition: max-height`
  inside the card's `overflow: hidden` container — the compositor
  deprioritized the layer while the tab was hidden and failed to re-rasterize
  text on return. Expanded cards were unaffected because `overflow-y: auto`
  on the items panel forced its own paint layer. Promoting every card to its
  own layer up front sidesteps the bug without changing the expand/collapse
  animation.

### Changed
- **Epic + Release card headers: tag pill relocated into header, right cluster stacked below, tighter section spacing** (XACA-0226) -
  The free-standing `queue-tags-row` that rendered below each Epic/Release card header was removed and
  the tag pill is now injected inside the header's right column, directly above whatever already sat
  on the right side of the header (Epics: DOCS/✎/✕/▶ action cluster; Releases: date/count/progress/expand
  meta row). New `.epic-card-header-right` / `.release-card-header-right` flex columns (`flex-direction:
  column`, `align-items: flex-end`, `align-self: stretch`) span the full header height; the bottom
  cluster uses `margin-top: auto` so it still bottoms out on tag-less cards (a `justify-content:
  space-between` approach would pin the lone child to the top). `.epic-search-bar` / `.release-search-bar`
  top padding reduced 6px → 2px and `.epics-section` / `.releases-section` top padding reduced to 8px
  so the search field hugs the section header. Archived-release `::before` 📦 badge at `right: 8px`
  would have overlapped the new tag pill's top-right corner, so `.release-card.archived
  .release-card-header-right` gained `padding-right: 16px` to clear the badge zone. The bottom
  `.release-card-actions` bar (DOCS/PROMOTE/RELNOTES/EDIT/ARCHIVE/DELETE) was explicitly out of scope
  and is unchanged. Tag click-to-populate-search and header click-to-expand both still work — click
  delegation is on `dashboardEl` (unchanged by DOM restructuring) and `e.stopPropagation()` on tag
  clicks keeps the header's `onclick` from firing.
- **Release/Epic tag filter replaced with Queue-parity search + clickable item tag pills** (XACA-0209 round 5) -
  The pill filter bar from rounds 3–4 was removed entirely. Each section now has a single search input
  that filters across id/title/shortTitle/description/tags. Every Release and Epic card shows a
  Queue-style purple tag-pill row between the card header and body; clicking a pill populates the
  section's search input, exactly like clicking a tag on a Queue item. `/api/releases/tags` and
  `/api/epics/tags` endpoints removed; `?tags=` query filter removed from the list endpoints; all
  client-side pill-filter machinery + 43 endpoint tests deleted. New localStorage keys
  (`lcars-release-search` / `lcars-epic-search`) persist the search string; old `*-tags-filter`
  keys orphaned (harmless) rather than migrated. `.queue-tag` gained `max-width: 180px` +
  `text-overflow: ellipsis` so legacy 200-char test tags don't bloat any pill row. Net: 5 files
  changed, +209 / −904 (−695 lines). Backend suite: 155 → 112 pass.
- **Release/Epic tag filter rebuilt on Queue-parity pill UI** (XACA-0209 round 4) -
  The original spec was "mirror the Queue tab's filter UI/UX". The feature had
  shipped as a `<select multiple>` control, which three debug rounds patched
  around but never brought into spec. This round replaces the select with
  click-to-toggle pill divs (`.filter-pill` variants) that structurally match
  the Queue filter pills — teal for Releases, purple for Epics. Keyboard
  accessible (Enter/Space), `role=button` / `aria-pressed`, empty-state
  "NO TAGS" placeholder when a section has zero tags. State persistence and
  stale-tag auto-heal from round 3 are retained. Dead code removed:
  `applyReleaseTagFilter`, `applyEpicTagFilter`,
  `updateReleaseTagFilterDropdownStyle`, `updateEpicTagFilterDropdownStyle`,
  `enableClickToggleOnMultiSelect`, and their CSS/HTML counterparts.
  Review follow-ups folded in: shared `renderTagFilterPills` /
  `populateTagFilterOptions` helpers; toggles renamed
  `toggle{Release,Epic}TagFilter` for Queue parity; module-scope
  `{release,epic}AvailableTags` replaces `dataset.tags` caching;
  `.filter-pill:focus-visible` adds a keyboard focus outline on the
  shared pill base (benefits Queue filters too).

### Fixed
- **Epic `completedCount` now matches release convention** (XACA-0218) -
  `GET /api/epics` under-reported `completedCount` because it checked only
  `status == 'completed'`, missing items marked `status == 'done'`. Aligned with
  the dual-check already used in `serve_release_progress` (server.py:2685) and
  frontend `loadEpicItems`/`loadReleaseItems`: `status in ('done', 'completed')`.
  One-line fix at `server.py:4087`.
- **Release/Epic tag filter — three compounding bugs** (XACA-0209 debug round 3) -
  (1) Dropdowns only displayed the first sorted tag because `<select multiple size="1">`
  renders as a one-row listbox; bumped `size="5"` on both filters so multiple
  tags are visible without scrolling. (2) Selecting a tag stored with padding
  (e.g. `"  spaced  "`) hid every release/epic because the backend stripped the
  incoming filter but compared it against unstripped stored tag values;
  `serve_releases_list`, `serve_releases_tags`, `serve_epics_list`, and
  `serve_epics_tags` now normalize stored tag values via `.strip()` on compare
  and list-build. The four write-path handlers (`handle_create_release`,
  `handle_update_release`, `handle_create_epic`, `handle_update_epic`) also
  `.strip()` individual tag values so new data is stored clean and the
  read-path normalization becomes defensive rather than load-bearing.
  (3) A `selectedTags` value left in localStorage from a tag the
  user later removed (or one that exists on another team) had no dropdown option
  to click, so the user could not deselect it and every release/epic stayed
  hidden; `populateReleaseTagOptions` / `populateEpicTagOptions` now prune
  `selectedTags` to the intersection with the server's current tag set, persist
  the pruned state, and re-run the list loader when pruning occurs.
- **Release/Epic tag filter click-to-deselect** (XACA-0209 debug) - Tags in the
  Releases and Epics tag filter dropdowns could be selected but a plain click on
  a selected tag would not deselect it. Native `<select multiple>` requires
  Ctrl/Cmd-click to toggle, contradicting the "Click selected to deselect" hint.
  Added a shared `mousedown` interceptor that toggles `option.selected` manually,
  giving true checkbox-style click-to-toggle behavior on both filters.
- **Release/Epic tag API parity cleanups** (XACA-0209 review follow-up) - Addressed 4 review subitems before merge.
  - `serve_epics_tags` now sends `Cache-Control: no-cache` (mirrors `serve_releases_tags`).
  - Added `test_route_dispatch_to_serve_epics_tags` symmetric to the releases equivalent.
  - Documented no-comma-in-tag-value constraint in filter docstrings (both releases and epics).
  - `handle_create_release` / `handle_update_release` now apply `isinstance` + `strip` validation to the `tags` field, matching the epic handlers (filters out non-string and blank entries server-side).
  - 10 new tests (`TestHandleCreateReleaseTagsValidation`, `TestHandleUpdateReleaseTagsValidation`), 147 total passing.

### Added
- **Tap-to-copy for Release and Epic IDs** (XACA-0213) - Release and Epic badges on
  queue items now include a clickable monospace ID chip (e.g. `[XIOS-0042]`) next to
  the shortTitle. Clicking the chip copies the ID to clipboard with toast feedback —
  mirroring the existing Item ID click-to-copy pattern. The badge body continues to
  open the assignment modal; `stopPropagation` on the chip prevents modal hijacking.
  - New spans: `.queue-epic-badge-name`, `.queue-epic-badge-id`,
    `.queue-release-badge-name`, `.queue-release-badge-id`
  - ARIA: `role=button`, `tabindex=0`, descriptive `aria-label` for screen readers
  - Keyboard: Enter/Space triggers the copy
  - Chip only rendered when a release/epic is assigned (unassigned `+REL`/`+EPIC`
    states are unchanged)
  - Visual: 87% font-size, Courier New monospace, opacity 0.72 idle → 1.0 on hover,
    subtle scale + tinted background matching each badge's accent color
  - Mobile: font scales to 80% inside `@media (max-width: 1024px)` to stay within
    the tracking-zone row
- **Release tag filtering API** (XACA-0209) - New backend endpoints for tag-based filtering on Releases.
  - `GET /api/releases/tags` — returns distinct sorted list of tags across all active releases for the team; respects `?team=<slug>` param; response shape `{"tags": [...]}`.
  - `GET /api/releases?tags=tag1,tag2` — filters returned releases to those whose `tags` array contains ANY of the requested tags (OR semantics, matching epics behaviour). Omitting `?tags` leaves existing behaviour unchanged.
- **Release tab tag filter dropdown** (XACA-0209-002) - Tag filter UI above the Releases dashboard.
  - Separate `releaseTagFilterState` object and `RELEASE_TAG_FILTER_KEY = 'lcars-release-tags-filter'` localStorage key — no coupling to `queueFilterState`.
  - Multi-select dropdown populated from `GET /api/releases/tags` when entering the Releases tab.
  - Filter persists across sessions via `loadReleaseTagFilterState()` / `saveReleaseTagFilterState()`.
  - `applyReleaseTagFilter()` passes `?tags=…` to `loadReleases()` on change; control highlights when filter is active.
  - New CSS classes with `release-tag-filter-*` prefix appended to `lcars.css`.

### Changed
- **LCARS Tab Order Reorder** (XACA-0115) - Reordered all tab navigation for improved workflow
  - New order: HOME → TODOS → CALENDAR → WORKFLOW → DETAILS → QUEUE → EPICS → RELEASES → SETTINGS
  - TODOS and CALENDAR moved to positions 2-3 for faster access to daily-use tabs
  - Updated SECTIONS array, sidebar buttons, mobile tabbar, and Alt+1-8 keyboard shortcuts

### Fixed
- **Epics Item Display Parity with Releases** (XACA-0211) - Epics screen now dims and
  strikes through completed and cancelled items, matching the existing Releases
  behavior. `loadEpicItems` computes `isCompleted`/`isCancelled`/`stateClass` and
  applies the resulting class to `.epic-item`; CSS adds `.epic-item.completed` and
  `.epic-item.cancelled` rules mirroring `.release-item.completed`/`.cancelled`
  (opacity 0.7/0.6, `line-through` title, `var(--lcars-muted)` title color,
  `var(--lcars-red)` id color on cancelled). Pure display change — no behavioral
  differences, no changes to data flow or click handling.
- **Terminal Activation tmux Socket Fix** (XACA-0102) - Terminal click-to-activate was
  non-functional because the tmux command used the default socket (which doesn't exist) and
  bare terminal names (which don't match). Fix adds `-L {team}` for per-team sockets and
  constructs `{team}-{terminal}` session names using the `LCARS_TEAM` environment variable.
- **Knowledge Panel Orphaned Chart Guard** (XACA-0098-016) - Debounce and AbortController
  pattern added to `_renderHomeKnowledgeStats` to prevent orphaned chart injection on rapid
  carousel navigation.
  - Added module-level `_knowledgeAbortController` and `_knowledgeDebounceTimer` state variables
  - `_renderHomeKnowledgeStats` now coalesces rapid calls with a 150ms debounce before firing
    the `/api/knowledge-stats` fetch
  - In-flight fetch is aborted immediately via `AbortController.signal` when a new call arrives
  - Two `currentHomePanel !== 4` guards after each `await` prevent stale continuations from
    injecting DOM content or charts when a different panel is active
  - `navigateToPanel` cancels debounce timer and aborts fetch when leaving panel 4
  - `stopCarousel` cancels debounce timer and aborts fetch when leaving the HOME tab entirely
  - `AbortError` exceptions are silently suppressed (they are intentional, not failures)

### Added
- **Team Todo List UI** (XACA-0101) - Lightweight per-team todo feature for quick one-shot items
  - New TODOS sidebar button and section in LCARS Kanban UI (`lcars-ui/index.html`)
  - Toggle tabs to switch between ACTIVE and COMPLETED views
  - Checkbox-based completion toggle with immediate API update
  - Priority badges (low/medium/high/critical) with LCARS color coding; critical items pulse
  - Optional required-by date with overdue highlighting (red border + date label)
  - Add/Edit modal with text, priority, and date fields; delete with confirmation
  - Empty state and loading state indicators
  - Reusable `lcars-modal` pattern for todo add/edit form
  - `todos-section` integrated into section switching, hide/show, and entrance animation system
  - All JavaScript functions: `loadTodos`, `renderTodos`, `filterTodos`, `openTodoModal`,
    `closeTodoModal`, `saveTodo`, `deleteTodo`, `toggleTodo`, `renderTodoItem`
  - API endpoints: `GET /api/todos`, `POST /api/todos`, `PUT /api/todos`, `DELETE /api/todos`
    (server implementation in `server.py` via XACA-0101-002)
  - Server handlers: `serve_todos_list`, `handle_create_todo`, `handle_update_todo`, `handle_delete_todo`
  - File locking + atomic writes; auto-sets completedAt on status transitions; sorts active by priority/date
- **AMB Badge Display** (XACA-0080) - Optional Agent Merit Badges display in agent panels
  - `@handle` text and up to 5 earned badge emojis shown between role and location/divider
  - Only visible for agents registered on the AMB platform (file-based detection)
  - `agent-panel.html`: `.amb-section` with handle + badge row, hidden by default
  - `agent-panel-display.sh`: `get_amb_badges()` with 5-min file cache, centered emoji display
  - `server.py`: `_fetch_amb_badges()` with in-memory cache (5-min TTL), badge enrichment in API response
  - `display-agent-avatar.sh`: `amb_handle` field in JSON output with config file validation
  - Graceful degradation at every layer (API down, no handle, no badges = invisible)

## [2026-02-12] - Agent Panel Split Panes & VESSEL/UPDATED Alignment

### Added
- **Terminal-Based Agent Panels** - Split pane in each terminal tab showing agent avatar and info
  - Uses `imgcat` for inline avatar display + ANSI formatting for agent details
  - Polls `/tmp/lcars-agent-{session}.json` for data changes (3s interval)
  - Auto-refreshes when agent data updates (file mtime detection)
  - Narrow 30-column pane on right side of each terminal tab
- **`agent-panel-display.sh`** - New script for terminal-based agent panel rendering
- **`agent-panel.html`** / **`agent-panel-router.html`** - Browser-based panel pages (available as fallback)
- **Per-session agent JSON** - `display-agent-avatar.sh` writes per-session JSON files for panel consumption

### Changed
- **VESSEL/UPDATED positioning** - Moved up 4px and tightened gap between lines by 8px across all LCARS UIs
  - `lcars-ui/css/lcars.css`
  - `fleet-monitor/lcars/css/lcars-fleet.css`
  - `fleet-monitor/lcars2/css/lcars-fleet.css`
- **`iterm2_window_manager.py`** - `split-agent-panel` action now uses Default profile + command (not Browser WebView)
  - Resizes pane to 30 cols after split for narrow sidebar layout
- **`server.py`** - Fixed `tempfile.gettempdir()` mismatch; hardcoded `/tmp` for agent JSON reads
- **All 10 startup scripts** - Updated to use `--command` with `agent-panel-display.sh` instead of `--url`
- **All banner scripts** - Updated to write per-session JSON via `display-agent-avatar.sh`

---

## [2026-01-28] - XACA-0050: Add shortTitle to Epics and Releases

### Added
- **Epic shortTitle Field** - Optional short display name for Epics
  - CLI: `kb-epic create --short-title "text"` or `-s "text"`
  - CLI: `kb-epic update <id> shortTitle "value"`
  - UI: shortTitle input in Epic create/edit modals
- **Release shortTitle Field** - Optional short display name for Releases
  - API: Create/update releases with optional shortTitle
  - UI: shortTitle input in Release create/edit modals
- **QUEUE Badge Display** - Epic and Release badges show shortTitle when available
  - Falls back to full title if shortTitle not set
  - Full title shown in tooltip for accessibility

### Changed
- **Badge Rendering** - Epic/Release badges now use `shortTitle || title` pattern
- **Modal Forms** - Added shortTitle input fields with helpful hints

---

## [2026-01-27] - XACA-0046: Queue Item UI Redesign

### Added
- **Zone-Based Layout** - Reorganized queue item header into 4 distinct zones:
  - **Identity Zone** - Expander, Priority, Category, Due Date, Item ID (always visible)
  - **Title Zone** - Item title with flex-grow (always visible)
  - **Tracking Zone** - Epic, Release, JIRA, GitHub, DOCS (toggle-controlled)
  - **Workflow Zone** - Window badge, Worktree badge, Tags (toggle-controlled)
- **View Toggle Button** - New "VIEW: TAGS/TRACKING" toggle in filter bar
  - Switches between showing Tags or Tracking metadata
  - Touch-friendly (replaces hover-to-reveal for iPad/iPhone support)
  - Persists preference to localStorage
- **Visual Hierarchy** - CSS-based hierarchy for scanability:
  - PRIMARY (14px, opacity 1.0): Title, Priority, Item ID
  - SECONDARY (12px, opacity 0.85): Category, Window/Worktree badges
  - TERTIARY (11px, opacity 0.7): Tracking zone elements
- **Progressive Disclosure** - Smooth CSS transitions for subitem expand/collapse
- **Accessibility Improvements** - ARIA attributes, keyboard navigation, focus indicators
- **Wireframe Documentation** - Design spec at `docs/kanban/XACA-0046_queue_redesign_wireframes.md`

### Changed
- **Due Date Position** - Moved from tracking zone to identity zone (always visible)
- **createQueueItem()** - Refactored to build elements into zone wrapper divs
- **Subitem Visibility** - Now uses CSS transitions instead of inline style.display

### Removed
- **Hover-to-Reveal** - Replaced with toggle button for better touch device support

---

## [2026-01-26] - XACA-0045: Plan Document Popup Reader

### Added
- **DOCS Button** - Conditional button on kanban items that appears when a plan document exists
  - Async existence check via new API endpoint
  - Blue LCARS styling with hover state
  - Positioned in queue item header
- **Plan Document Modal** - Popup reader for viewing markdown plan documents
  - Full markdown rendering (headers, lists, code blocks, links, bold/italic)
  - LCARS-themed styling with teal/cyan/purple color scheme
  - Loading and error state handling
  - Close via X button or clicking outside modal
  - Custom scrollbar for long documents
- **Server API Endpoints** - Two new endpoints for plan document access
  - `GET /api/kanban/<item-id>/plan-exists` - Check if plan document exists
  - `GET /api/kanban/<item-id>/plan-content` - Retrieve markdown content
  - Team-aware path resolution (iOS, Android, Firebase, Academy, Freelance, etc.)
  - Glob pattern matching for `<ITEM-ID>_*.md` files
- **Plan Document Cache** - Client-side caching infrastructure
  - 60-second TTL for existence checks
  - Cache clearing on board refresh

### Changed
- **createQueueItem()** - Added DOCS button rendering with async existence check

---

## [2026-01-25] - XACA-0042: LCARS Style Guide Alignment & Animation Library Sync

### Added
- **Animation Library** - Ported Fleet Monitor animations to Kanban LCARS
  - `lcars-glow` (with slow/fast variants) - Pulsing glow effect
  - `lcars-breathe` (with slow variant) - Opacity pulsing
  - `lcars-scan` (with slow variant) - Horizontal scanning beam
  - `lcars-warp` (in/out variants) - Warp speed stretch effect
  - `lcars-transport` (in/out) - Star Trek transporter dissolve
- **Slide Animations** - `slideInLeft` / `slideInRight` keyframes and utility classes
- **Candy-Pill Animations** - `candy-pulse` and `candy-invert` for interaction feedback
- **Accessibility** - `prefers-reduced-motion` media query covering all 19+ animation types
- **Missing Color Variables** - Added `--lcars-error`, `--lcars-violet`, `--lcars-yellow-glow`, `--lcars-alert-glow`
- **Organization Colors** - Added `--org-personal`, `--org-legal`
- **Division Colors** - Added `--div-legal`, `--div-legal-coparenting`
- **Firefox Scrollbar Support** - Added `scrollbar-width` and `scrollbar-color` to all scrollbar definitions

### Fixed
- **Critical Color Bug** - Line 29 incorrectly defined `--lcars-orange: #aa77dd` (violet value)
  - Now correctly defines `--lcars-violet: #aa77dd`
  - StarWords freelance division now displays correct violet color
- **Green-Dark Value** - Synced `--lcars-green-dark` to Fleet Monitor value (`#66cc66`)

### Changed
- **Easing Functions** - Standardized `--lcars-ease-smooth` and `--lcars-ease-elastic` across both interfaces
- **Fleet Monitor CSS** - Added Firefox scrollbar support to `lcars-fleet.css` and `lcars-fleet-theme.css`

---

## [2026-01-24] - XACA-0041: Animated Settings Sub-Menu

### Added
- **SETTINGS Button with Sub-Menu** - Consolidated INTEGRATIONS, BACKUPS, and COMMANDS into a single SETTINGS button with animated sub-menu
- **CSS Animation** - Smooth horizontal slide-out animation using `transform: scaleX()` (250ms ease-out)
  - Sub-menu positioned to the right of sidebar
  - High z-index (1000) for proper layering
  - Hover states with color inversion (tan ↔ black)
  - Active state tracking for selected sub-menu items
- **JavaScript Toggle Logic** - Complete sub-menu interaction handling
  - Toggle on SETTINGS button click
  - Close on outside click (document-level listener)
  - Close after item selection with navigation
  - Integrates with existing `switchSection()` function
  - Active state sync for sub-menu items

### Changed
- **Sidebar Structure** - Replaced three separate buttons (INTEGRATIONS, BACKUPS, COMMANDS) with nested SETTINGS sub-menu

---

## [2026-01-21] - XACA-0037: Team Validation for Release Item Assignment

### Added
- **Team Field in Release Schema** - Added `team` field to releases.json config and individual releases for ownership tracking
- **Server-Side Validation** - `handle_assign_item_to_release()` now validates item team matches release team, returns 403 on mismatch
- **Team Filter API** - `/api/releases?team=<team>` query parameter to filter releases by team
- **UI Team Filtering** - `showReleaseAssignModal()` now only shows releases for current team
- **RELNOTES Safeguard** - `generateRelnotesContent()` filters out cross-team items as defensive measure
- **Item ID Prefix Utilities** - `extractTeamFromItemId()` functions in both Python and JavaScript
  - Supports: XIOS→ios, XAND→android, XFIR→firebase, XACA→academy, XCMD→command, XDNS→dns, XFRE→freelance, XMEV→mainevent

### Fixed
- **Cross-Team Contamination Bug** - Items from one team can no longer be assigned to another team's releases

### Changed
- **Existing releases.json Files** - Updated with team ownership field for backward compatibility

---

## [2026-01-20] - XACA-0018: Monday.com Integration Support

### Added
- **MondayProvider Class** - Full Monday.com GraphQL API integration
  - Bearer token authentication via `MONDAY_API_TOKEN` environment variable
  - Connection testing using Monday.com `me` query
  - Item search across accessible boards
  - Item verification and URL generation
- **Status Column Detection** - Intelligent status column handling
  - `get_board_columns()` - Fetch all columns for a board
  - `detect_status_columns()` - Find status columns with their labels
  - `get_status_column_for_item()` - Get item's current status info
- **Status Synchronization** - `sync_status()` method with mapping support
  - Maps kanban statuses to Monday.com status labels
  - Case-insensitive label matching
  - Skip-on-unchanged optimization
- **Board Fetching API** - `POST /api/integrations/boards` endpoint for Monday.com
- **Frontend Integration**
  - Monday.com preset in INTEGRATION_PRESETS (auto-fill configuration)
  - Monday.com option in integration type dropdown
  - Monday icon (📅) in integration cards
  - Ticket pill styling with coral red (#ff6b6b) theme
- **Manual Integration Test** - `test_monday_integration.py` for real board testing
- **Unit Tests** - Extended test suite with `TestMondayProviderStatusMethods` class

### Documentation
- Updated `integrations/README.md` with Monday.com configuration examples
- Added API token setup instructions
- Documented status column detection and synchronization features
- Added Monday.com specific features section

---

## [2026-01-19] - XACA-0027: LCARS Configure Flow Feature

### Added
- **Configure Flow Button** - New "⚙ FLOW" button in releases tab header
- **Current Flow Display** - Shows enabled stages in header (e.g., `DEV → QA → PROD`), updates after config changes
- **Flow Config Modal** - Visual configuration modal with:
  - Dynamic flow diagram preview showing active stages
  - Toggle switches for QA, ALPHA, BETA, GAMMA stages
  - DEV and PROD locked as required stages
- **`flowConfig` Schema** - Added to all team `releases.json` files with stage enable/disable state
- **API Endpoint** - `POST /api/releases/flow-config` for saving flow configuration
- **`getEnabledEnvironments()`** - Helper function to get list of enabled stages
- **`updateCurrentFlowDisplay()`** - Updates header flow display when config changes

### Changed
- **Promote Logic** - Now skips disabled stages when auto-promoting to next environment
- **Promotion Modal** - Only displays enabled target environments
- **Release Cards** - Progress bars calculate percentage based on enabled stages only
- **`loadReleases()`** - Now fetches flow config in parallel for accurate progress display
- **`renderReleaseCard()`** - Accepts flowConfig parameter for stage-aware rendering
- **`/api/release-config`** - Now includes `flowConfig` in response

### Features
- **Team-Scoped** - Each team has independent flow configuration
- **Backward Compatible** - Defaults to all stages enabled if no flowConfig exists
- **Real-time Preview** - Flow diagram updates instantly as toggles change

---

## [2026-01-19] - XACA-0029: Work Time Tracking for Kanban Items

### Added
- **`formatWorkTime(ms)`** - Formats milliseconds as human-readable duration (e.g., "2h 15m", "3d 4h")
- **`calculateParentWorkTime(item)`** - Sums `timeWorkedMs` from all completed subitems for rollup display
- **Subitem Time Display** - Completed subitems show work time after timestamp (e.g., "✓ 2026-01-19 12:00 (2h 15m)")
- **Parent Rollup Display** - Parent items show total accumulated time from completed subitems
- **Partial Progress Display** - In-progress parent items show "(Xh Ym worked)" from completed subitems
- **CSS Classes**:
  - `.item-time-worked` - Styling for time display on parent items
  - `.subitem-time-worked` - Styling for time display on subitems
  - `.item-time-worked.partial` - Styling for in-progress rollup display

### Features
- Time accumulates across multiple work sessions (start/stop cycles)
- Only shows time on completed items (not in-progress)
- Blue color for time worked, mauve for partial progress

---

## [2026-01-19] - Window Badge Text Contrast Fix

### Fixed
- **Window badge readability** - Changed text color from black to white for all window badge states
  - Default (orange background): now uses white text
  - Coding (blue background): now uses white text
  - Planning (gold background): now uses white text
  - Paused (red background): already used white text (unchanged)
- Resolves "black on black" visibility issue where window badges were hard to read against the dark LCARS interface

---

## [2026-01-19] - Smart Team Code Generation for Kanban IDs

### Added
- **FAP Team Code** - New mapping for `freelance-doublenode-appplanning` → `XFAP-####`
- **Smart Compound Word Extraction** - `_kb_extract_compound_code()` function that intelligently parses compound words to generate 2-letter codes:
  - Detects camelCase (e.g., `CodeReview` → `CR`)
  - Finds consonant clusters at word boundaries (e.g., `starwords` → `SW`, `workstats` → `WS`, `appplanning` → `AP`)
  - Falls back to first two letters when no pattern detected
- **Intelligent Fallback** - Multi-segment team names now auto-generate codes using first letter of first segment + smart 2-letter code from last segment

### Changed
- `_kb_get_team_code()` fallback logic upgraded from simple "first 3 chars" to intelligent compound word parsing
- Existing AppPlanning items migrated from `XFRE-*` to `XFAP-*` prefix

### Fixed
- AppPlanning kanban items no longer incorrectly use `XFRE` prefix (which belongs to main `freelance` team)

---

## [2026-01-19] - XACA-0021: Hover-to-Filter Blocked Items (Enhanced)

### Added
- **Dependency Filter Mode** - Hover over "Blocked by" row to filter queue
- **`activateDependencyFilter()`** - Shows only blocked item and its blockers
- **`deactivateDependencyFilter()`** - Restores normal queue view
- **`checkAndClearStuckDependencyFilter()`** - Safety fallback on document click
- **Subitem-Level Filtering** - Hover over subitem blockers to filter:
  - Source subitem highlighted with `.dependency-source` class
  - Only blocking subitems remain visible
  - Non-blocking subitems fade to 15% opacity
  - Auto-expands parent items to reveal blocking subitems
- **CSS Classes**:
  - `.dependency-filter-active` - Queue container in filter mode
  - `.dependency-visible` - Items/subitems visible during filtering
  - `.dependency-source` - The blocked item/subitem (stronger highlight)
  - `.filter-hover` - Visual feedback on blocked row or subitem blocker container
  - `.subitem-blocker-container.filter-hover` - Hover styling for subitem blockers

### Features
- Fades non-related items to 15% opacity
- Fades non-blocking subitems within visible parent items
- Orange glow on visible items and subitems during filter
- Auto-expands parent items when subitem is a blocker
- Smooth 0.2s transitions for all effects
- Supports single and multiple blockers
- Works for both parent item and subitem blocked-by indicators

### Fixed
- Filter no longer gets stuck when queue re-renders during hover
- Pointer-events preserved on hover elements to ensure mouseleave fires

---

## [2026-01-19] - XACA-0025: Extend Blocked-By System to Subitems

### Added
- **Subitem Blocker Pills** - Blocked subitems now display inline blocker pills in their header
- **Subitem Navigation** - Clicking blocker pills navigates to the blocking item/subitem:
  - Parent items scroll and highlight
  - Subitems auto-expand parent first, then scroll and highlight
- **`navigateToBlocker()` Helper** - Unified navigation for both parent and subitem blockers
- **`data-subitem-id` Attribute** - Enables DOM targeting for subitem navigation
- **`is-blocked` Class for Subitems** - Visual styling for blocked subitems
- **CLI Subitem Blocking Commands**:
  - `kb-backlog block XACA-0016-001 XACA-0016-002` - Block subitem by subitem
  - `kb-backlog block XACA-0016-003 XACA-0017` - Block subitem by parent item
  - `kb-backlog unblock XACA-0016-001` - Remove all blockers from subitem
  - `kb-backlog unblock XACA-0016-001 XACA-0016-002` - Remove specific blocker
- **Auto-Unblock Cascade** - Completing a subitem auto-unblocks dependent items/subitems
- **Backend Helper Functions**:
  - `_kb_is_subitem_id()` - Detect subitem ID format
  - `_kb_add_subitem_blocker()` - Add blocker to subitem
  - `_kb_remove_subitem_blocker()` - Remove blocker from subitem

### Changed
- `_kb_check_unblock_dependents()` now processes both items and subitems
- Parent item blocker pill click handler refactored to use shared `navigateToBlocker()`

---

## [2026-01-19] - Delete Release Feature

### Added
- **Delete Release Button** - Red "DELETE" button on release cards
- **`deleteRelease()` Function** - Archives release with confirmation prompt
- **Danger Button Styling** - Red theme for destructive actions

---

## [2026-01-19] - XACA-0016: Multi-Platform Integration System

### Added
- **INTEGRATIONS Tab** - New orange-colored tab for managing external integrations
- **Integration Provider Architecture** - Flexible system supporting multiple platforms:
  - Abstract `IntegrationProvider` base class
  - JIRA Cloud implementation with REST API v3
  - Extensible for GitHub, Linear, and custom providers
- **Integration Modal** - Full add/edit/delete functionality:
  - Type selector (JIRA/GitHub/Linear/Custom)
  - Auto-fill presets based on type selection
  - URL configuration (base URL, browse URL pattern)
  - Project filtering and ticket ID regex patterns
  - Environment variable credential configuration
  - Test Connection button with user info display
- **ticketLinks Data Model** - Replaces legacy single `jiraId` field:
  - Supports multiple ticket links per kanban item
  - Caches ticket summary and status
  - Tracks link creation metadata
- **Integration API Endpoints**:
  - `/api/integrations` - List all configured integrations
  - `/api/integrations/test` - Test connection and show user info
  - `/api/integrations/verify` - Verify ticket exists
  - `/api/integrations/search` - Search for tickets by JQL
  - `/api/integrations/save` - Create or update integration
  - `/api/integrations/delete` - Remove integration
- **Migration Script** - Migrates legacy `jiraId` to `ticketLinks` format
- **22 Unit Tests** - Full test coverage for integration system

### Changed
- Tab order: RELEASES now appears before INTEGRATIONS
- INTEGRATIONS button uses unique orange color (`--lcars-orange`)
- JIRA API updated to use `/search/jql` endpoint (v3 compatibility)
- Default JIRA projects updated to: MEM, MEW, MEAPP, MEKIOSK, MEWEB

### Fixed
- JIRA 410 Gone error by updating deprecated search endpoint
- Test button now displays authenticated user info prominently

---

## [2026-01-19] - XACA-0023: Release Tracking System

### Added
- **Release Management Dashboard** - New RELEASES tab with green color theme
- **Create Release Modal** - Form to create new releases with:
  - Release name (required)
  - Type selector (feature/bugfix/hotfix/maintenance)
  - Platform checkboxes (iOS/Android/Firebase)
  - Target date (optional)
  - Description (optional)
- **Release Assignment Modal** - Assign kanban items to releases:
  - Pre-populates current assignment when editing
  - UNASSIGN button (red) for removing assignments
  - Auto-detects platform from item ID prefix (XIOS/XAND/XFIR)
  - Handles reassignment (unassigns from old release first)
- **Release Filter Dropdown** - Filter queue by release assignment:
  - ALL - Show all items
  - ASSIGNED - Show only items assigned to a release
  - UNASSIGNED - Show items not yet assigned
- **Release Badge on Queue Items** - Shows assigned release ID or "+REL" to assign
- **Release Manager Skill** - CLI commands for release management:
  - `/release list` - List all active releases
  - `/release show <id>` - Show detailed release info
  - `/release create "name"` - Create a new release
  - `/release assign <item-id> <release-id>` - Assign item to release
  - `/release unassign <item-id> <release-id>` - Remove item from release
  - `/release promote <release-id> <platform>` - Promote platform to next environment
  - `/release status <release-id>` - Show release progress by platform
  - `/release archive <release-id>` - Archive a completed release

### Changed
- RELEASES sidebar/tabbar button now uses green color
- Modal system extended with input fields, textareas, and checkboxes
- Queue items now display release assignment badge

### Fixed
- Release dashboard auto-refreshes after creating new release
- Browser autofill disabled on release name input
- Assign modal handles already-assigned items gracefully

---

## [2026-01-17] - Foundation

### Added
- Initial RELEASES tab structure
- releases.json configuration file
- API endpoints for release management
- Basic release card display in dashboard
