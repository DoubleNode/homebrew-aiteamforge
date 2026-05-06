/**
 * lcars-cr-tab.js — CHANGE REQ section list view
 *
 * XACA-0292-007: Renders the CR/CAB list inside #change-req-list with a
 * 9-column tabular layout, filter-bar integration, and per-row DOCS button
 * that opens the existing plan-doc modal pre-switched to the CR tab.
 *
 * XACA-0292-008: Adds 3 saved-view chips in #change-req-saved-views:
 *   "THIS WEEK'S CRs"    — cr_created_at (or addedAt) within current ISO week
 *   "AWAITING APPROVAL"  — crState === 'cr-submitted' (filter-bar preset only)
 *   "EMERGENCY (30D)"    — cr_type === 'emergency' within last 30 days
 *
 * XACA-0293-002: View 1 Active CR Pipeline
 *   "ACTIVE PIPELINE"    — all non-terminal crState values; sorted by STAGE AGE desc
 *   STAGE AGE column     — time-in-current-state with color-coded badge (green/yellow/red)
 *
 * XACA-0310 Phase 2.5:
 *   001: CR rows carry linkedItemIds[]; item-count badge in TITLE cell.
 *   002: Chevron expands a cr-children-row showing linked kanban items.
 *   005: DOCS modal reads cr_doc_link directly (CR-keyed, not item-keyed).
 *   007: SAVED_VIEWS predicates evaluate against CR record timestamps —
 *        see comment block at SAVED_VIEWS declaration below.
 *
 * Public API (globals):
 *   initChangeReqTab()       — idempotent; called from lcars.js on page load.
 *   renderChangeReqList()    — called when user navigates into CHANGE REQ section.
 *
 * Dependencies (all defined in lcars.js, which loads before this file):
 *   boardData, apiUrl, escapeHtml, showPlanDocModal, switchDocTab, createFilterBar,
 *   copyToClipboard, pauseAutoRefresh, resumeAutoRefresh, renderMarkdown
 */

/* global boardData, apiUrl, escapeHtml, showPlanDocModal, switchDocTab, createFilterBar, copyToClipboard, pauseAutoRefresh, resumeAutoRefresh, renderMarkdown */

'use strict';

(function () {

    // ─── Module state ─────────────────────────────────────────────────────────

    let _initialized   = false;
    let _filterBar     = null;

    // Map of cr_id → full normalized CR view-object, refreshed each render.
    // Lets the DOCS click handler resolve the CR record without re-walking
    // boardData or reading large attributes off the button.
    const _crByIdCache = {};

    // Backlog index built during the most recent _getCRItems() call, reused
    // by renderChangeReqList() and the DOM-surgery chevron handler so we don't
    // recompute the index on every render or expand/collapse (XACA-0310-013).
    let _lastBacklogIdx = {};

    // Set of cr_ids whose child-rows are currently expanded.
    // Keyed by cr_id; survives re-renders (renderChangeReqList restores state).
    const _expandedCRs = new Set();

    // ─── Saved-view state ─────────────────────────────────────────────────────

    const SAVED_VIEW_KEY = 'lcars-change-req-saved-view';

    /**
     * Stable view IDs — do NOT rename; persisted to localStorage.
     * Labels may change freely; these IDs must not.
     *
     * NOTE (XACA-0310-007): predicates evaluate against NORMALIZED CR VIEW-OBJECTS
     * (post-_normalizeCR), NOT raw backlog items. Field mapping:
     *   cr_created_at          ← timestamps.cr_created_at || cr.createdAt
     *   cr_emergency_deployed_at ← timestamps.cr_emergency_deployed_at
     *   cr_completed_at        ← timestamps.cr_completed_at
     *   addedAt                ← cr.createdAt (same source, fallback alias)
     * These are verified correct in _normalizeCR below.
     */
    const SAVED_VIEWS = {
        'this-week':        {
            label: "THIS WEEK'S CRs",
            preset: { stateFilter: 'all', typeFilter: 'all', platformFilter: 'all', searchText: '' },
            predicate: item => {
                const ts = item.cr_created_at || item.addedAt;
                return ts ? isWithinIsoWeek(new Date(ts).getTime()) : false;
            },
        },
        'awaiting-approval': {
            label: 'AWAITING APPROVAL',
            preset: { stateFilter: 'cr-submitted', typeFilter: 'all', platformFilter: 'all', searchText: '' },
            predicate: null,   // filter-bar state alone is sufficient
        },
        'emergency-30d': {
            label: 'EMERGENCY (30D)',
            preset: { stateFilter: 'all', typeFilter: 'emergency', platformFilter: 'all', searchText: '' },
            predicate: item => {
                // cr_emergency_deployed_at covers emergency-deployed state;
                // cr_completed_at covers deployed-prod; addedAt is last fallback.
                const ts = item.cr_emergency_deployed_at || item.cr_completed_at || item.addedAt;
                return ts ? isWithinLastNDays(new Date(ts).getTime(), 30) : false;
            },
        },

        // XACA-0293-002: Active CR Pipeline.
        // Stable view ID — do NOT rename; persisted to localStorage.
        //
        // Terminal-state rationale:
        //   'deployed-prod'      — end of standard pipeline; no further transitions expected.
        //   'emergency-deployed' — end of emergency pipeline; no further transitions expected.
        //   'cr-rejected'        — dead-end in current submission cycle. If the CR is
        //                          re-submitted it transitions back to 'cr-submitted',
        //                          which automatically puts it back into the active set.
        //   'cr-held'            — NOT terminal; the CR is paused but still in flight.
        //
        // sortKey: when this view is applied, _applySavedView honors it by writing
        //   _filterState.sortBy = 'STAGE-AGE', surfacing stuck CRs first.
        'active-pipeline': {
            label: 'ACTIVE PIPELINE',
            preset: { stateFilter: 'all', typeFilter: 'all', platformFilter: 'all', searchText: '' },
            sortKey: 'STAGE-AGE',
            predicate: item => {
                // Active = any non-terminal cr-* state. Terminal states excluded (see above).
                const TERMINAL = new Set(['deployed-prod', 'emergency-deployed', 'cr-rejected']);
                return !TERMINAL.has(item.crState) && item.crState && item.crState.length > 0;
            },
        },
    };

    let _activeSavedView = _loadSavedView();

    function _loadSavedView() {
        try {
            const v = localStorage.getItem(SAVED_VIEW_KEY);
            return (v && SAVED_VIEWS[v]) ? v : null;
        } catch (e) {
            return null;
        }
    }

    function _saveSavedView(viewId) {
        _activeSavedView = viewId || null;
        try {
            if (_activeSavedView) {
                localStorage.setItem(SAVED_VIEW_KEY, _activeSavedView);
            } else {
                localStorage.removeItem(SAVED_VIEW_KEY);
            }
        } catch (e) { /* silently ignore */ }
    }

    // crState priority for default sort — active CRs float to top
    const CR_STATE_ORDER = {
        'cr-submitted':       0,
        'cr-approved':        1,
        'implementing':       2,
        'deployed-dev':       3,
        'deployed-prod':      4,
        'emergency-deployed': 5,
        'cr-drafted':         6,
        'cr-rejected':        7,
        'cr-held':            8,
    };

    const PRIORITY_ORDER = { critical: 0, high: 1, medium: 2, med: 2, low: 3 };

    // ─── Time-window helpers ──────────────────────────────────────────────────

    /**
     * Returns true if the given timestamp (ms epoch) falls within the
     * current Mon–Sun ISO week in local time.
     * Returns false for NaN / 0 / missing timestamps — be honest about empty data.
     */
    function isWithinIsoWeek(tsMs) {
        if (!tsMs || isNaN(tsMs)) return false;
        const now   = new Date();
        const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
        // ISO: Monday = 1 … Sunday = 7; JS: Sunday = 0 … Saturday = 6
        const jsDay    = today.getDay();                       // 0=Sun…6=Sat
        const isoDay   = jsDay === 0 ? 7 : jsDay;             // 1=Mon…7=Sun
        const weekStart = new Date(today);
        weekStart.setDate(today.getDate() - (isoDay - 1));    // last Monday
        const weekEnd   = new Date(weekStart);
        weekEnd.setDate(weekStart.getDate() + 7);             // next Monday (exclusive)
        const d = new Date(tsMs);
        return d >= weekStart && d < weekEnd;
    }

    /**
     * Returns true if (now - tsMs) <= n * 24 * 60 * 60 * 1000.
     * Returns false for NaN / 0 / missing timestamps.
     */
    function isWithinLastNDays(tsMs, n) {
        if (!tsMs || isNaN(tsMs)) return false;
        return (Date.now() - tsMs) <= n * 24 * 60 * 60 * 1000;
    }

    // ─── Filter-bar initialisation ────────────────────────────────────────────

    function _initFilterBar() {
        const container = document.getElementById('change-req-filter-bar');
        if (!container || _filterBar) return;   // already wired or container missing

        // Inject filter-bar HTML into the mount point
        container.innerHTML = `
            <div class="cr-filter-row">
                <div class="cr-filter-pills" id="cr-state-pills">
                    <button class="filter-pill active" data-cr-state="all">ALL</button>
                    <button class="filter-pill" data-cr-state="cr-drafted">DRAFTED</button>
                    <button class="filter-pill" data-cr-state="cr-submitted">SUBMITTED</button>
                    <button class="filter-pill" data-cr-state="cr-approved">APPROVED</button>
                    <button class="filter-pill" data-cr-state="implementing">IMPLEMENTING</button>
                    <button class="filter-pill" data-cr-state="deployed-dev">DEPLOYED-DEV</button>
                    <button class="filter-pill" data-cr-state="deployed-prod">DEPLOYED-PROD</button>
                    <button class="filter-pill" data-cr-state="emergency-deployed">EMERGENCY</button>
                    <button class="filter-pill" data-cr-state="cr-rejected">REJECTED</button>
                    <button class="filter-pill" data-cr-state="cr-held">HELD</button>
                </div>
                <div class="cr-filter-pills cr-type-pills" id="cr-type-pills">
                    <button class="filter-pill active" data-cr-type="all">ALL</button>
                    <button class="filter-pill" data-cr-type="standard">STANDARD</button>
                    <button class="filter-pill" data-cr-type="major">MAJOR</button>
                    <button class="filter-pill" data-cr-type="emergency">EMERGENCY</button>
                </div>
                <div class="cr-filter-controls">
                    <div class="cr-platform-wrap">
                        <label class="cr-dropdown-label">PLATFORM</label>
                        <select id="cr-platform-select" class="cr-platform-select">
                            <option value="all">ALL</option>
                            <option value="ios">iOS</option>
                            <option value="android">ANDROID</option>
                            <option value="firebase">FIREBASE</option>
                            <option value="crossplatform">CROSSPLATFORM</option>
                        </select>
                    </div>
                    <div class="cr-sort-wrap">
                        <button class="cr-sort-btn" id="cr-sort-btn" title="Cycle sort order">
                            SORT: <span id="cr-sort-value">STATE</span>
                        </button>
                    </div>
                    <div class="filter-search-container cr-search-wrap">
                        <input type="text" id="cr-filter-text" class="filter-search-input"
                               placeholder="SEARCH CR ID, TITLE, SUMMARY..." autocomplete="off" spellcheck="false">
                        <button id="cr-filter-clear" class="filter-search-clear" title="Clear search">&times;</button>
                    </div>
                </div>
            </div>`;

        _wireCRFilterBar();
    }

    // ─── Filter bar state ─────────────────────────────────────────────────────

    const FILTER_KEY = 'lcars-change-req-filter';
    const SORT_VALUES = ['STATE', 'TYPE', 'PLATFORM', 'APPROVER', 'STAGE-AGE'];

    let _filterState = _loadFilterState();

    function _loadFilterState() {
        const defaults = {
            stateFilter: 'all',
            typeFilter:  'all',
            platformFilter: 'all',
            searchText: '',
            sortBy: 'STATE',
        };
        try {
            const saved = localStorage.getItem(FILTER_KEY);
            if (!saved) return defaults;
            return Object.assign({}, defaults, JSON.parse(saved));
        } catch (e) {
            return defaults;
        }
    }

    function _saveFilterState() {
        try {
            localStorage.setItem(FILTER_KEY, JSON.stringify(_filterState));
        } catch (e) { /* silently ignore */ }
    }

    // ─── Filter bar wiring ────────────────────────────────────────────────────

    function _wireCRFilterBar() {
        // State pills
        const statePillsContainer = document.getElementById('cr-state-pills');
        if (statePillsContainer) {
            statePillsContainer.querySelectorAll('.filter-pill[data-cr-state]').forEach(pill => {
                pill.addEventListener('click', () => {
                    _filterState.stateFilter = pill.dataset.crState;
                    _syncStatePills();
                    _saveFilterState();
                    _onFilterDiverge();
                    renderChangeReqList();
                });
            });
        }

        // Type pills
        const typePillsContainer = document.getElementById('cr-type-pills');
        if (typePillsContainer) {
            typePillsContainer.querySelectorAll('.filter-pill[data-cr-type]').forEach(pill => {
                pill.addEventListener('click', () => {
                    _filterState.typeFilter = pill.dataset.crType;
                    _syncTypePills();
                    _saveFilterState();
                    _onFilterDiverge();
                    renderChangeReqList();
                });
            });
        }

        // Platform dropdown
        const platformSelect = document.getElementById('cr-platform-select');
        if (platformSelect) {
            platformSelect.value = _filterState.platformFilter || 'all';
            platformSelect.addEventListener('change', () => {
                _filterState.platformFilter = platformSelect.value;
                _saveFilterState();
                _onFilterDiverge();
                renderChangeReqList();
            });
        }

        // Sort cycle button
        const sortBtn = document.getElementById('cr-sort-btn');
        const sortValue = document.getElementById('cr-sort-value');
        if (sortBtn && sortValue) {
            sortValue.textContent = _filterState.sortBy || 'STATE';
            sortBtn.addEventListener('click', () => {
                const current = _filterState.sortBy || 'STATE';
                const idx = SORT_VALUES.indexOf(current);
                _filterState.sortBy = SORT_VALUES[(idx + 1) % SORT_VALUES.length];
                sortValue.textContent = _filterState.sortBy;
                _saveFilterState();
                // Sort changes don't diverge from a saved-view preset — don't clear chip
                renderChangeReqList();
            });
        }

        // Search input
        const searchInput = document.getElementById('cr-filter-text');
        const clearBtn    = document.getElementById('cr-filter-clear');
        if (searchInput) {
            searchInput.value = _filterState.searchText || '';
            let debounce;
            searchInput.addEventListener('input', () => {
                clearTimeout(debounce);
                debounce = setTimeout(() => {
                    _filterState.searchText = searchInput.value;
                    _saveFilterState();
                    _onFilterDiverge();
                    renderChangeReqList();
                }, 150);
            });
            searchInput.addEventListener('keydown', e => {
                if (e.key === 'Escape') {
                    searchInput.value = '';
                    _filterState.searchText = '';
                    _saveFilterState();
                    _onFilterDiverge();
                    renderChangeReqList();
                    searchInput.blur();
                }
            });
        }
        if (clearBtn) {
            clearBtn.addEventListener('click', () => {
                const input = document.getElementById('cr-filter-text');
                if (input) { input.value = ''; input.focus(); }
                _filterState.searchText = '';
                _saveFilterState();
                _onFilterDiverge();
                renderChangeReqList();
            });
        }

        // Sync pill UI from loaded state
        _syncStatePills();
        _syncTypePills();
    }

    function _syncStatePills() {
        const container = document.getElementById('cr-state-pills');
        if (!container) return;
        container.querySelectorAll('.filter-pill[data-cr-state]').forEach(pill => {
            pill.classList.toggle('active', pill.dataset.crState === (_filterState.stateFilter || 'all'));
        });
    }

    function _syncTypePills() {
        const container = document.getElementById('cr-type-pills');
        if (!container) return;
        container.querySelectorAll('.filter-pill[data-cr-type]').forEach(pill => {
            pill.classList.toggle('active', pill.dataset.crType === (_filterState.typeFilter || 'all'));
        });
    }

    // ─── Saved-view chip rendering + wiring ───────────────────────────────────

    /**
     * Called when user manually changes any filter pill/search.
     * Clears the active saved-view chip because the user has diverged from the preset.
     */
    function _onFilterDiverge() {
        if (!_activeSavedView) return;
        _saveSavedView(null);
        _syncSavedViewChips();
    }

    // ─── Sub-tab toggle (XACA-0293-003) ─────────────────────────────────────

    const _SUBTAB_KEY    = 'lcars-cr-subtab';
    const _VALID_SUBTABS = ['pipeline', 'cycle-time'];

    function _initSubtabs() {
        const bar = document.getElementById('change-req-subtabs');
        if (!bar) return;

        const buttons = bar.querySelectorAll('.cr-subtab');
        if (!buttons.length) return;

        function _activateSubtab(target) {
            buttons.forEach(btn => {
                const isTarget = btn.dataset.subtab === target;
                btn.classList.toggle('active', isTarget);
                btn.setAttribute('aria-selected', String(isTarget));
            });

            document.querySelectorAll('.change-req-pane').forEach(pane => {
                if (pane.dataset.subtabPane === target) {
                    pane.removeAttribute('hidden');
                } else {
                    pane.setAttribute('hidden', '');
                }
            });

            try {
                localStorage.setItem(_SUBTAB_KEY, target);
            } catch (_) {}

            document.dispatchEvent(new CustomEvent('cr-subtab-changed', { detail: { subtab: target } }));
        }

        buttons.forEach(btn => {
            btn.addEventListener('click', () => _activateSubtab(btn.dataset.subtab));
        });

        // Restore persisted selection; fall back to 'pipeline' if invalid
        let stored = 'pipeline';
        try {
            const raw = localStorage.getItem(_SUBTAB_KEY);
            if (raw && _VALID_SUBTABS.includes(raw)) stored = raw;
        } catch (_) {}

        _activateSubtab(stored);
    }

    function _initSavedViews() {
        const container = document.getElementById('change-req-saved-views');
        if (!container) return;

        const chips = Object.entries(SAVED_VIEWS).map(([id, view]) =>
            `<button class="cr-saved-view-chip" data-view="${id}">${view.label}</button>`
        ).join('');

        container.innerHTML =
            `<div class="cr-saved-views">${chips}` +
            `<button class="cr-saved-view-chip cr-saved-view-clear" data-view="">CLEAR</button></div>`;

        container.querySelectorAll('.cr-saved-view-chip').forEach(btn => {
            btn.addEventListener('click', () => {
                const viewId = btn.dataset.view;
                if (!viewId) {
                    // CLEAR button
                    _applySavedView(null);
                } else {
                    _applySavedView(viewId);
                }
            });
        });

        _syncSavedViewChips();
    }

    /**
     * Apply a saved view: update filter state to the view's preset,
     * save active view ID, sync chips, re-render.
     * Pass null to clear (reset to default state).
     */
    function _applySavedView(viewId) {
        if (viewId && SAVED_VIEWS[viewId]) {
            const view = SAVED_VIEWS[viewId];
            Object.assign(_filterState, view.preset);
            // Honor per-view sort hint (e.g. ACTIVE PIPELINE sorts by STAGE-AGE desc).
            if (view.sortKey) {
                _filterState.sortBy = view.sortKey;
            }
        } else {
            // Reset to defaults
            _filterState.stateFilter   = 'all';
            _filterState.typeFilter    = 'all';
            _filterState.platformFilter = 'all';
            _filterState.searchText    = '';
        }

        _saveSavedView(viewId || null);
        _saveFilterState();

        // Sync UI controls to new filter state
        _syncStatePills();
        _syncTypePills();

        const platformSelect = document.getElementById('cr-platform-select');
        if (platformSelect) platformSelect.value = _filterState.platformFilter || 'all';

        const searchInput = document.getElementById('cr-filter-text');
        if (searchInput) searchInput.value = _filterState.searchText || '';

        // Reflect sortBy in the sort button display (e.g. "STAGE-AGE" when active-pipeline applied).
        const sortValueEl = document.getElementById('cr-sort-value');
        if (sortValueEl) sortValueEl.textContent = _filterState.sortBy || 'STATE';

        _syncSavedViewChips();
        renderChangeReqList();
    }

    function _syncSavedViewChips() {
        const container = document.getElementById('change-req-saved-views');
        if (!container) return;
        container.querySelectorAll('.cr-saved-view-chip[data-view]').forEach(btn => {
            const isActive = btn.dataset.view && btn.dataset.view === _activeSavedView;
            btn.classList.toggle('active', !!isActive);
        });
    }

    // ─── Data helpers ─────────────────────────────────────────────────────────

    /**
     * Build a quick lookup of backlog items keyed by id, used to resolve
     * per-item fields (priority for secondary sort, fallback title) when
     * normalizing CR objects and when expanding child rows.
     */
    function _backlogIndex() {
        const idx = {};
        const list = (window.boardData && window.boardData.backlog) || [];
        for (const item of list) {
            if (item && item.id) idx[item.id] = item;
        }
        return idx;
    }

    /**
     * Normalize a CR record from the new top-level `changeRequests[]` array
     * into the view-object shape the rest of this file expects (cr_id, cr_type,
     * crState, title, platform, deploy_window_planned, cr_pushback_count,
     * cr_doc_link, cr_summary, cr_created_at, cr_emergency_deployed_at,
     * cr_completed_at, addedAt, priority, id, linkedItemIds). The `id` field
     * is set to the first linked backlog item id so the DOCS button can fall
     * back to the item-keyed cr-content endpoint when needed.
     *
     * linkedItemIds: full array of linked item ids (XACA-0310-001).
     *
     * Timestamp mapping (XACA-0310-007 — verified against kb-cr schema):
     *   cr_created_at          ← timestamps.cr_created_at || cr.createdAt
     *   cr_emergency_deployed_at ← timestamps.cr_emergency_deployed_at (may be absent)
     *   cr_completed_at        ← timestamps.cr_completed_at (may be absent)
     *   addedAt                ← cr.createdAt (fallback alias used by saved-view predicates)
     */
    function _normalizeCR(cr, backlogIdx) {
        const ts = cr.timestamps || {};
        const linkedItemIds = Array.isArray(cr.itemIds) ? cr.itemIds.filter(Boolean) : [];
        const firstItemId = linkedItemIds.length > 0 ? linkedItemIds[0] : '';
        const linkedItem = firstItemId ? backlogIdx[firstItemId] : null;
        return {
            id:                         firstItemId,
            cr_id:                      cr.id || '',
            cr_type:                    cr.type || '',
            crState:                    cr.crState || '',
            title:                      cr.title || (linkedItem ? linkedItem.title : '') || '',
            platform:                   cr.platform || (linkedItem ? linkedItem.platform : '') || '',
            cr_approver_name:           cr.cr_approver_name || '',
            cr_approved_by:             cr.cr_approved_by || '',
            deploy_window_planned:      cr.deploy_window_planned || '',
            cr_pushback_count:          cr.pushback_count || 0,
            cr_doc_link:                cr.cr_doc_link || '',
            cr_proper_url:              cr.cr_proper_url || '',
            cr_summary:                 cr.summary || '',
            cr_created_at:              ts.cr_created_at || cr.createdAt || '',
            cr_submitted_at:            ts.cr_submitted_at || '',
            cr_approved_at:             ts.cr_approved_at || '',
            cr_dev_started_at:          ts.cr_dev_started_at || '',
            cr_deployed_dev_at:         ts.cr_deployed_dev_at || '',
            cr_deployed_prod_at:        ts.cr_deployed_prod_at || '',
            cr_emergency_deployed_at:   ts.cr_emergency_deployed_at || '',
            cr_completed_at:            ts.cr_completed_at || '',
            addedAt:                    cr.createdAt || '',
            priority:                   linkedItem ? linkedItem.priority : '',
            linkedItemIds:              linkedItemIds,
        };
    }

    /**
     * Extract CR view-objects from the global boardData.
     * Reads the top-level `crs[]` array (current schema, written by kb-cr).
     * Returns [] when boardData is not yet loaded or has no CRs.
     */
    function _getCRItems() {
        // Drop stale cache entries — we rebuild from live boardData below
        for (const k of Object.keys(_crByIdCache)) delete _crByIdCache[k];

        if (!window.boardData) { _lastBacklogIdx = {}; return []; }
        const crs = window.boardData.crs;
        if (!Array.isArray(crs) || crs.length === 0) { _lastBacklogIdx = {}; return []; }
        const backlogIdx = _backlogIndex();
        _lastBacklogIdx = backlogIdx;
        const items = crs
            .filter(cr => cr && cr.id && String(cr.id).trim().length > 0)
            .map(cr => _normalizeCR(cr, backlogIdx));
        for (const it of items) {
            if (it.cr_id) _crByIdCache[it.cr_id] = it;
        }
        return items;
    }

    /**
     * Match function: return true when item passes all active filters.
     */
    function _itemMatchesFilters(item) {
        const s = _filterState;

        // State filter
        if (s.stateFilter && s.stateFilter !== 'all') {
            if (item.crState !== s.stateFilter) return false;
        }

        // Type filter
        if (s.typeFilter && s.typeFilter !== 'all') {
            const itemType = (item.cr_type || '').toLowerCase();
            if (itemType !== s.typeFilter.toLowerCase()) return false;
        }

        // Platform filter — case-insensitive match (board may store 'ios'/'IOS'/'iOS')
        if (s.platformFilter && s.platformFilter !== 'all') {
            const itemPlatform = (item.platform || '').toLowerCase();
            const wantPlatform = s.platformFilter.toLowerCase();
            if (itemPlatform !== wantPlatform) return false;
        }

        // Search filter — matches cr_id, cr_summary, item title
        if (s.searchText && s.searchText.trim()) {
            const needle = s.searchText.toLowerCase();
            const haystack = [
                item.cr_id || '',
                item.cr_summary || '',
                item.title || '',
            ].join(' ').toLowerCase();
            if (!haystack.includes(needle)) return false;
        }

        return true;
    }

    /**
     * Sort CR items.
     * Default: by crState priority asc, then item priority asc.
     * Alternate sorts: TYPE, PLATFORM, APPROVER (all alpha).
     */
    function _sortItems(items) {
        const sortBy = (_filterState.sortBy || 'STATE').toUpperCase();
        return [...items].sort((a, b) => {
            if (sortBy === 'TYPE') {
                return (a.cr_type || '').localeCompare(b.cr_type || '');
            }
            if (sortBy === 'PLATFORM') {
                return (a.platform || '').localeCompare(b.platform || '');
            }
            if (sortBy === 'APPROVER') {
                const aName = a.cr_approver_name || a.cr_approved_by || '';
                const bName = b.cr_approver_name || b.cr_approved_by || '';
                return aName.localeCompare(bName);
            }
            // STAGE-AGE: descending (oldest first, so stuck CRs surface at top).
            // null ages (missing anchor) sort to the bottom.
            if (sortBy === 'STAGE-AGE') {
                const aAge = _computeStageAge(a);
                const bAge = _computeStageAge(b);
                if (aAge === null && bAge === null) return 0;
                if (aAge === null) return 1;   // a sinks
                if (bAge === null) return -1;  // b sinks
                return bAge - aAge;            // larger age = higher in list
            }
            // Default: STATE priority
            const aOrd = CR_STATE_ORDER[a.crState] !== undefined ? CR_STATE_ORDER[a.crState] : 99;
            const bOrd = CR_STATE_ORDER[b.crState] !== undefined ? CR_STATE_ORDER[b.crState] : 99;
            if (aOrd !== bOrd) return aOrd - bOrd;
            // Secondary: item priority
            const aPri = PRIORITY_ORDER[a.priority] !== undefined ? PRIORITY_ORDER[a.priority] : 99;
            const bPri = PRIORITY_ORDER[b.priority] !== undefined ? PRIORITY_ORDER[b.priority] : 99;
            return aPri - bPri;
        });
    }

    // ─── Badge renderers ──────────────────────────────────────────────────────

    const CR_TYPE_CLASS = {
        standard:  'cr-badge-standard',
        major:     'cr-badge-major',
        emergency: 'cr-badge-emergency',
    };

    const CR_STATE_CLASS = {
        'cr-drafted':         'cr-state-drafted',
        'cr-submitted':       'cr-state-submitted',
        'cr-approved':        'cr-state-approved',
        'cr-rejected':        'cr-state-rejected',
        'cr-held':            'cr-state-held',
        'implementing':       'cr-state-implementing',
        'deployed-dev':       'cr-state-deployed-dev',
        'deployed-prod':      'cr-state-deployed-prod',
        'emergency-deployed': 'cr-state-emergency',
    };

    function _typeBadge(crType) {
        const raw = (crType || '').toLowerCase();
        const cls = CR_TYPE_CLASS[raw] || 'cr-badge-standard';
        return `<span class="cr-badge ${cls}">${escapeHtml((crType || 'STANDARD').toUpperCase())}</span>`;
    }

    function _stateBadge(crState) {
        const raw = crState || 'cr-drafted';
        const cls = CR_STATE_CLASS[raw] || 'cr-state-drafted';
        return `<span class="cr-state-badge ${cls}">${escapeHtml(raw.toUpperCase().replace(/-/g, ' '))}</span>`;
    }

    function _formatDeployWindow(value) {
        if (!value || !String(value).trim()) return '<span class="cr-dim">—</span>';
        // Try to parse as ISO date; fall back to raw string
        const d = new Date(value);
        if (!isNaN(d.getTime())) {
            return escapeHtml(d.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' }));
        }
        return escapeHtml(String(value));
    }

    function _pushbackDisplay(count) {
        const n = parseInt(count, 10);
        if (isNaN(n) || n === 0) return '<span class="cr-dim">0</span>';
        return `<span class="cr-pushback-count">${n}</span>`;
    }

    // ─── Stage age helpers (XACA-0293-002) ───────────────────────────────────

    /**
     * Anchor-timestamp mapping for STAGE AGE computation.
     * Returns the timestamp (string/ISO) that marks when the CR entered its
     * current state.  Fallback chain: anchor field → cr_created_at → addedAt.
     *
     * Thresholds are first-cut values; tunable in Phase 7 (XACA-0297).
     */
    const _STAGE_ANCHOR = {
        'cr-drafted':         item => item.cr_created_at,
        'cr-submitted':       item => item.cr_submitted_at,
        'cr-approved':        item => item.cr_approved_at,
        // cr-held: paused since submission; use cr_submitted_at as anchor.
        'cr-held':            item => item.cr_submitted_at,
        // cr-rejected: dead-end since submission; would re-enter at cr-submitted if re-submitted.
        'cr-rejected':        item => item.cr_submitted_at,
        'implementing':       item => item.cr_dev_started_at,
        'deployed-dev':       item => item.cr_deployed_dev_at,
        'deployed-prod':      item => item.cr_deployed_prod_at,
        'emergency-deployed': item => item.cr_emergency_deployed_at,
    };

    /**
     * Returns fractional days (float) that the CR has been in its current state,
     * or null when no usable anchor timestamp is available.
     */
    function _computeStageAge(item) {
        const anchorFn = _STAGE_ANCHOR[item.crState];
        const rawTs = anchorFn
            ? (anchorFn(item) || item.cr_created_at || item.addedAt)
            : (item.cr_created_at || item.addedAt);

        if (!rawTs) return null;
        const anchorMs = new Date(rawTs).getTime();
        if (!anchorMs || isNaN(anchorMs)) return null;

        return (Date.now() - anchorMs) / (24 * 60 * 60 * 1000);
    }

    /**
     * Render a stage-age badge <td> cell.
     * Format: <Xh | Xd | X.Xmo>  with CSS class for color coding.
     * Thresholds (first cut — tunable in Phase 7, XACA-0297):
     *   0–2 days   → .stage-age-fresh  (green)
     *   2–5 days   → .stage-age-aging  (yellow)
     *   >5 days    → .stage-age-stale  (red)
     *   no anchor  → .stage-age-unknown (gray), displays "—"
     */
    function _stageAgeBadge(item) {
        const ageDays = _computeStageAge(item);

        if (ageDays === null) {
            return '<span class="stage-age-badge stage-age-unknown">—</span>';
        }

        let label;
        if (ageDays < 1) {
            label = Math.floor(ageDays * 24) + 'h';
        } else if (ageDays < 30) {
            label = Math.floor(ageDays) + 'd';
        } else {
            label = (ageDays / 30).toFixed(1) + 'mo';
        }

        let cls;
        if (ageDays <= 2) {
            cls = 'stage-age-fresh';
        } else if (ageDays <= 5) {
            cls = 'stage-age-aging';
        } else {
            cls = 'stage-age-stale';
        }

        return `<span class="stage-age-badge ${cls}">${label}</span>`;
    }

    // ─── Item-count badge (XACA-0310-001) ────────────────────────────────────

    /**
     * Build the title cell content: title text + item-count badge when > 1 linked item.
     * Single item: title only (the cr_id or linked item title is already in title).
     * Multiple items: title + small "N items" badge overlaid in the title cell.
     */
    function _titleWithBadge(item) {
        const title = escapeHtml(item.title || '');
        const count = item.linkedItemIds ? item.linkedItemIds.length : 0;
        if (count <= 1) {
            return `<span class="cr-title-text" title="${title}">${title}</span>`;
        }
        const badge = `<span class="cr-item-count" title="${count} linked kanban items">${count} items</span>`;
        return `<span class="cr-title-text" title="${title}">${title}</span>${badge}`;
    }

    // ─── Row renderer ─────────────────────────────────────────────────────────

    // Total column count including chevron col-0 and STAGE AGE col (XACA-0293-002).
    const CR_COL_COUNT = 11;

    function _renderRow(item) {
        const crId       = escapeHtml(item.cr_id || '');
        const crType     = _typeBadge(item.cr_type);
        const crState    = _stateBadge(item.crState);
        const titleCell  = _titleWithBadge(item);
        const platform   = escapeHtml(item.platform || '');
        const approver   = escapeHtml(item.cr_approver_name || item.cr_approved_by || '');
        const deployWin  = _formatDeployWindow(item.deploy_window_planned);
        const pushbacks  = _pushbackDisplay(item.cr_pushback_count);
        const stageAge   = _stageAgeBadge(item);
        const hasCRDoc   = !!(item.cr_doc_link && String(item.cr_doc_link).trim().length > 0);
        const hasChildren = item.linkedItemIds && item.linkedItemIds.length > 0;
        const isExpanded  = _expandedCRs.has(item.cr_id);

        // DOCS button on the CR list opens a CR-only modal — distinct from the
        // item DOCS button which shows Plan/Retro/CR tabs. We stash the CR id on
        // the button so the click handler can look the full CR view-object back
        // up from the cached list (avoids re-fetching boardData).
        const docsBtn = hasCRDoc
            ? `<button class="cr-docs-btn" data-cr-id="${escapeHtml(item.cr_id)}" title="View CR document">DOCS</button>`
            : `<span class="cr-docs-placeholder"></span>`;

        // Chevron column (col-0): shown only when there are linked items.
        const chevronCls = isExpanded ? 'cr-chevron expanded' : 'cr-chevron';
        const chevronBtn = hasChildren
            ? `<button class="${chevronCls}" data-cr-id="${escapeHtml(item.cr_id)}" title="${isExpanded ? 'Collapse' : 'Expand'} linked items" aria-expanded="${isExpanded}" aria-label="${isExpanded ? 'Collapse' : 'Expand'} linked items">&#9654;</button>`
            : `<span class="cr-chevron-placeholder"></span>`;

        return `<tr class="cr-row${isExpanded ? ' cr-row-expanded' : ''}" data-cr-id="${escapeHtml(item.cr_id)}" data-item-id="${escapeHtml(item.id)}">
            <td class="cr-col-chevron">${chevronBtn}</td>
            <td class="cr-col-id"><button class="cr-id-copy" data-cr-id="${crId}" title="Copy CR ID to clipboard"><span class="cr-id-mono">${crId}</span></button></td>
            <td class="cr-col-type">${crType}</td>
            <td class="cr-col-state">${crState}</td>
            <td class="cr-col-title">${titleCell}</td>
            <td class="cr-col-platform">${platform}</td>
            <td class="cr-col-approver">${approver}</td>
            <td class="cr-col-deploy">${deployWin}</td>
            <td class="cr-col-pushbacks">${pushbacks}</td>
            <td class="cr-col-stage-age">${stageAge}</td>
            <td class="cr-col-docs">${docsBtn}</td>
        </tr>`;
    }

    // ─── Child-row renderer (XACA-0310-002) ──────────────────────────────────

    /**
     * Render the expanded children row for a CR.
     * Inserts a single <tr class="cr-children-row"> with colspan=CR_COL_COUNT
     * containing an inline list of linked kanban items.
     * Uses _backlogIndex() to look up title/status for each linked item id.
     */
    function _renderChildrenRow(item, backlogIdx) {
        const ids = item.linkedItemIds || [];
        if (ids.length === 0) return '';

        const childRows = ids.map(id => {
            const backlogItem = backlogIdx[id] || null;
            const rawTitle    = backlogItem ? (backlogItem.title || '') : '';
            const rawStatus   = backlogItem ? (backlogItem.status || backlogItem.crState || '') : '';
            const titleText   = escapeHtml(rawTitle) || '<span class="cr-dim">—</span>';
            const statusText  = rawStatus
                ? `<span class="cr-child-status cr-child-status-${escapeHtml(rawStatus.toLowerCase().replace(/\s+/g, '-'))}">${escapeHtml(rawStatus)}</span>`
                : '<span class="cr-dim">—</span>';

            return `<div class="cr-child-item">
                <button class="cr-child-id-copy" data-copy-id="${escapeHtml(id)}" title="Copy item ID to clipboard">
                    <span class="cr-id-mono">${escapeHtml(id)}</span>
                </button>
                <span class="cr-child-title">${titleText}</span>
                ${statusText}
            </div>`;
        }).join('');

        return `<tr class="cr-children-row" data-parent-cr-id="${escapeHtml(item.cr_id)}">
            <td colspan="${CR_COL_COUNT}">
                <div class="cr-children-container">
                    <div class="cr-children-label">LINKED ITEMS</div>
                    ${childRows}
                </div>
            </td>
        </tr>`;
    }

    // ─── Expansion DOM surgery (XACA-0310-014) ───────────────────────────────

    /**
     * Wire a single child-id copy button. Extracted so newly-inserted rows
     * (from chevron expansion) can be wired without re-running the parent
     * loop in renderChangeReqList().
     */
    function _wireChildCopyButton(btn) {
        btn.addEventListener('click', e => {
            e.stopPropagation();
            const copyId = btn.dataset.copyId || '';
            if (!copyId) return;
            if (typeof copyToClipboard === 'function') copyToClipboard(copyId);
            btn.classList.add('cr-id-copied');
            setTimeout(() => btn.classList.remove('cr-id-copied'), 900);
        });
    }

    /**
     * Toggle CR row expansion via DOM surgery — insert or remove the children
     * row directly under the parent row, instead of triggering a full
     * renderChangeReqList() (which would wipe and re-wire all event listeners).
     */
    function _toggleCRExpansion(chevronBtn) {
        const crId = chevronBtn.dataset.crId;
        if (!crId) return;
        const parentRow = chevronBtn.closest('tr.cr-row');
        if (!parentRow) return;

        const isExpanded = _expandedCRs.has(crId);
        if (isExpanded) {
            _expandedCRs.delete(crId);
            chevronBtn.classList.remove('expanded');
            chevronBtn.setAttribute('aria-expanded', 'false');
            const next = parentRow.nextElementSibling;
            if (next && next.classList.contains('cr-children-row') &&
                next.dataset.parentCrId === crId) {
                next.remove();
            }
            return;
        }

        const view = _crByIdCache[crId];
        if (!view) return;
        const childrenHtml = _renderChildrenRow(view, _lastBacklogIdx);
        if (!childrenHtml) return;

        _expandedCRs.add(crId);
        chevronBtn.classList.add('expanded');
        chevronBtn.setAttribute('aria-expanded', 'true');
        parentRow.insertAdjacentHTML('afterend', childrenHtml);
        const inserted = parentRow.nextElementSibling;
        if (inserted) {
            inserted.querySelectorAll('.cr-child-id-copy').forEach(_wireChildCopyButton);
        }
    }

    // ─── Public: renderChangeReqList ──────────────────────────────────────────

    /**
     * Re-render the CHANGE REQ list.
     * Safe to call any time; reads from global boardData.
     */
    function renderChangeReqList() {
        const listEl  = document.getElementById('change-req-list');
        const countEl = document.getElementById('change-req-count');
        if (!listEl) return;

        const allCRItems = _getCRItems();

        if (allCRItems.length === 0) {
            // boardData may still be loading, or genuinely no CRs
            if (!window.boardData) {
                listEl.innerHTML = '<div class="change-req-empty">Loading change requests...</div>';
                if (countEl) countEl.textContent = '0 ITEMS';
                return;
            }
            listEl.innerHTML = '<div class="change-req-empty">No change requests for this team.</div>';
            if (countEl) countEl.textContent = '0 ITEMS';
            return;
        }

        // AND saved-view predicate on top of filter-bar state
        const savedViewPredicate = _activeSavedView && SAVED_VIEWS[_activeSavedView]
            ? SAVED_VIEWS[_activeSavedView].predicate
            : null;

        const filtered = allCRItems.filter(item => {
            if (!_itemMatchesFilters(item)) return false;
            if (savedViewPredicate && !savedViewPredicate(item)) return false;
            return true;
        });
        const sorted   = _sortItems(filtered);

        if (countEl) {
            const label = filtered.length !== allCRItems.length
                ? `${filtered.length}/${allCRItems.length} SHOWN`
                : `${allCRItems.length} ITEMS`;
            countEl.textContent = label;
        }

        if (sorted.length === 0) {
            listEl.innerHTML = '<div class="change-req-empty">No change requests match these filters.</div>';
            return;
        }

        // Backlog index already built during _getCRItems() above; reuse it
        // (XACA-0310-013) instead of walking boardData.backlog a second time.
        const backlogIdx = _lastBacklogIdx;

        // Build rows: each CR row optionally followed by its children row
        const rows = sorted.map(item => {
            const parentRow = _renderRow(item);
            const childrenRow = _expandedCRs.has(item.cr_id)
                ? _renderChildrenRow(item, backlogIdx)
                : '';
            return parentRow + childrenRow;
        }).join('');

        listEl.innerHTML = `
            <table class="cr-table">
                <thead>
                    <tr class="cr-header-row">
                        <th class="cr-col-chevron"></th>
                        <th class="cr-col-id">CR ID</th>
                        <th class="cr-col-type">TYPE</th>
                        <th class="cr-col-state">STATE</th>
                        <th class="cr-col-title">TITLE</th>
                        <th class="cr-col-platform">PLATFORM</th>
                        <th class="cr-col-approver">APPROVER</th>
                        <th class="cr-col-deploy">DEPLOY WINDOW</th>
                        <th class="cr-col-pushbacks">PUSHBACKS</th>
                        <th class="cr-col-stage-age">STAGE AGE</th>
                        <th class="cr-col-docs">DOCS</th>
                    </tr>
                </thead>
                <tbody>${rows}</tbody>
            </table>`;

        // Wire DOCS buttons → open CR-only modal (NOT the item plan-doc modal).
        listEl.querySelectorAll('.cr-docs-btn').forEach(btn => {
            btn.addEventListener('click', e => {
                e.stopPropagation();
                const crId = btn.dataset.crId;
                if (!crId) return;
                const view = _crByIdCache[crId];
                if (!view) return;
                _showCRDocModal(view);
            });
        });

        // Wire CR-ID copy buttons → delegate to the global copyToClipboard()
        // (defined in lcars.js) so the upper-right toast is identical to the
        // one shown when item IDs are copied. Local green-flash class layers
        // on top of the toast for direct visual feedback at the click site.
        listEl.querySelectorAll('.cr-id-copy').forEach(btn => {
            btn.addEventListener('click', e => {
                e.stopPropagation();
                const crId = btn.dataset.crId || '';
                if (!crId) return;
                if (typeof copyToClipboard === 'function') copyToClipboard(crId);
                btn.classList.add('cr-id-copied');
                setTimeout(() => btn.classList.remove('cr-id-copied'), 900);
            });
        });

        // Wire chevron buttons → toggle expansion via DOM surgery
        // (XACA-0310-002 / 014). Avoids full innerHTML re-render + re-wire,
        // which would otherwise wipe every event listener on every toggle.
        listEl.querySelectorAll('.cr-chevron[data-cr-id]').forEach(btn => {
            btn.addEventListener('click', e => {
                e.stopPropagation();
                _toggleCRExpansion(btn);
            });
            btn.addEventListener('keydown', e => {
                if (e.key === 'Enter' || e.key === ' ') {
                    e.preventDefault();
                    btn.click();
                }
            });
        });

        // Wire child item ID copy buttons for any rows expanded at first paint
        // (e.g. restored from a prior render). Newly-expanded rows wire their
        // own copy buttons inside _toggleCRExpansion().
        listEl.querySelectorAll('.cr-child-id-copy').forEach(_wireChildCopyButton);
    }

    // ─── CR-only modal ────────────────────────────────────────────────────────

    /**
     * Show a CR-only modal for a CR record (XACA-0310-005).
     *
     * Logic for fetching/displaying the CR document:
     *
     * 1. If cr_doc_link is an external URL (https?://): render metadata block
     *    with a launch button. No fetch needed.
     *
     * 2. If cr_doc_link is a relative path (e.g. change-requests/CR-2026-001.md):
     *    fetch via the item-keyed endpoint /api/kanban/<firstItemId>/cr-content
     *    using view.id (first linked item id). The server resolves the CR doc
     *    via crAssignment in the same call. No CR-keyed server route exists yet
     *    (out of scope for this chunk) so item-keyed fallback is intentional.
     *    TODO(server-route): switch to /api/kanban/cr/<cr_id>/content when the
     *    CR-keyed server route lands. File a follow-up XACA ticket against the
     *    XACA-0310 parent (Phase 2.5) before changing this call.
     *
     * 3. If no cr_doc_link at all: show "no local CR document" guidance.
     */
    function _showCRDocModal(view) {
        // pause auto-refresh if the host page exposes it (lcars.js global)
        if (typeof pauseAutoRefresh === 'function') pauseAutoRefresh();

        const overlay = document.createElement('div');
        overlay.className = 'lcars-modal-overlay';
        overlay.id = 'cr-doc-modal-overlay';

        const modal = document.createElement('div');
        modal.className = 'lcars-modal cr-doc-modal';
        modal.setAttribute('data-cr-id', view.cr_id || '');

        const header = document.createElement('div');
        header.className = 'lcars-modal-header';
        header.innerHTML =
            `<span class="lcars-modal-title">CR DOCUMENT: ${escapeHtml(view.cr_id || '')}</span>` +
            `<div class="cr-doc-header-actions">` +
                `<button class="cr-edit-state-btn" id="cr-edit-state-btn" title="Change CR state">EDIT STATE</button>` +
                `<button class="lcars-modal-close" id="cr-doc-modal-close">&times;</button>` +
            `</div>`;

        const body = document.createElement('div');
        body.className = 'lcars-modal-body cr-doc-content';

        // Stable sub-divs so fetches can update them independently
        const metaDiv = document.createElement('div');
        metaDiv.className = 'cr-doc-meta-container';
        metaDiv.innerHTML = _renderCRMetadata(view);

        const contentDiv = document.createElement('div');
        contentDiv.className = 'cr-doc-content-area';

        const activityDiv = document.createElement('div');
        activityDiv.className = 'cr-activity-section';
        activityDiv.innerHTML = '<div class="cr-activity-loading">Loading activity log...</div>';

        body.appendChild(metaDiv);
        body.appendChild(contentDiv);
        body.appendChild(activityDiv);

        modal.appendChild(header);
        modal.appendChild(body);
        overlay.appendChild(modal);

        overlay.addEventListener('click', e => {
            if (e.target === overlay) _hideCRDocModal();
        });
        document.body.appendChild(overlay);
        setTimeout(() => overlay.classList.add('active'), 10);

        const closeBtn = header.querySelector('#cr-doc-modal-close');
        if (closeBtn) closeBtn.addEventListener('click', _hideCRDocModal);

        const editStateBtn = header.querySelector('#cr-edit-state-btn');
        if (editStateBtn) {
            editStateBtn.addEventListener('click', () => _showCRStateChangeDialog(view));
        }

        const docLink = view.cr_doc_link || '';
        const isExternalUrl = /^https?:\/\//i.test(docLink);

        // Local *.md is the source of truth (XACA-0309). Fetch from the server
        // via the item-keyed endpoint when a relative path / empty link is in
        // play. Skip the cr-content fetch for external-only URLs (the metadata
        // launch button is sufficient); the activity log fetch below still runs.
        if (!isExternalUrl && view.id) {
            fetch(apiUrl('/api/kanban/' + encodeURIComponent(view.id) + '/cr-content'))
                .then(r => { if (!r.ok) throw new Error('CR document not found'); return r.json(); })
                .then(data => {
                    if (data && data.content != null) {
                        const md = (typeof renderMarkdown === 'function')
                            ? renderMarkdown(data.content || '')
                            : `<pre class="cr-doc-pre">${escapeHtml(data.content || '')}</pre>`;
                        contentDiv.innerHTML = '<div class="cr-doc-md">' + md + '</div>';
                    }
                    // else: external-only response — metadata launch button is sufficient.
                })
                .catch(() => {
                    contentDiv.innerHTML =
                        `<div class="cr-doc-missing">` +
                        `<strong>No local CR document found.</strong><br>` +
                        `Expected at <code>change-requests/${escapeHtml(view.cr_id || '')}*.md</code>. ` +
                        `Use the launch button above to view the Confluence page, or create the local source file.` +
                        `</div>`;
                });
        }

        // Fetch activity log (XACA-0328-002)
        const crIdForActivity = view.cr_id || '';
        if (crIdForActivity) {
            fetch(apiUrl('/api/kanban/cr/' + encodeURIComponent(crIdForActivity) + '/activity'))
                .then(r => r.json())
                .then(data => {
                    activityDiv.innerHTML = _renderCRActivityLog(data);
                    _wireCRActivityCollapse(activityDiv);
                })
                .catch(() => {
                    activityDiv.innerHTML = _renderCRActivityLog(null);
                });
        } else {
            activityDiv.innerHTML = '';
        }
    }

    // ─── Activity log rendering (XACA-0328-002) ───────────────────────────────

    const _CR_ACTIVITY_TYPE_COLORS = {
        'cr_state_changed':    'var(--lcars-orange, #ff9900)',
        'cr_created':          'var(--lcars-amber, #ffcc00)',
        'cr_published':        'var(--lcars-amber, #ffcc00)',
        'cr_proper_detected':  'var(--lcars-cyan,  #99ccff)',
        'cr_field_update':     'var(--lcars-blue,  #9999ff)',
    };

    function _crActivityTypePill(type) {
        const color = _CR_ACTIVITY_TYPE_COLORS[type] || 'var(--lcars-mauve, #cc99cc)';
        return `<span class="cr-activity-pill" style="background:${color};color:#000">${escapeHtml(type)}</span>`;
    }

    function _crActivityDetails(evt) {
        if (evt.type === 'cr_state_changed' && evt.from_state && evt.to_state) {
            return `<span class="cr-activity-states">${escapeHtml(evt.from_state)} &rarr; ${escapeHtml(evt.to_state)}</span>`;
        }
        if ((evt.type === 'cr_proper_detected' || evt.type === 'cr_field_update') && evt.field) {
            const oldV = evt.old_value != null ? escapeHtml(String(evt.old_value)) : '&mdash;';
            const newV = evt.new_value != null ? escapeHtml(String(evt.new_value)) : '&mdash;';
            return `<span class="cr-activity-field">${escapeHtml(evt.field)}: ${oldV} &rarr; ${newV}</span>`;
        }
        if (evt.note) {
            return `<span class="cr-activity-note">${escapeHtml(evt.note)}</span>`;
        }
        return '';
    }

    function _renderCRActivityLog(data) {
        const events = (data && Array.isArray(data.events)) ? data.events : [];
        // Reverse for newest-first display
        const sorted = events.slice().reverse();

        const rows = sorted.length > 0
            ? sorted.map(evt => {
                const ts = escapeHtml(evt.ts || '');
                const actor = escapeHtml(evt.actor || '');
                const pill = _crActivityTypePill(evt.type || '');
                const details = _crActivityDetails(evt);
                return `<div class="cr-activity-row">` +
                    `<span class="cr-activity-ts">${ts}</span>` +
                    `${pill}` +
                    `<span class="cr-activity-actor">${actor}</span>` +
                    (details ? `<span class="cr-activity-details">${details}</span>` : '') +
                    `</div>`;
            }).join('')
            : '<div class="cr-activity-empty">No activity recorded for this CR.</div>';

        return `<div class="cr-activity-header" data-collapsed="false">` +
            `<span class="cr-activity-title">ACTIVITY LOG</span>` +
            `<span class="cr-activity-toggle">&#9660;</span>` +
            `</div>` +
            `<div class="cr-activity-body">${rows}</div>`;
    }

    function _wireCRActivityCollapse(container) {
        const hdr = container.querySelector('.cr-activity-header');
        const body = container.querySelector('.cr-activity-body');
        if (!hdr || !body) return;
        hdr.addEventListener('click', () => {
            const collapsed = hdr.dataset.collapsed === 'true';
            hdr.dataset.collapsed = collapsed ? 'false' : 'true';
            body.style.display = collapsed ? '' : 'none';
            const toggle = hdr.querySelector('.cr-activity-toggle');
            if (toggle) toggle.innerHTML = collapsed ? '&#9660;' : '&#9654;';
        });
    }

    function _hideCRDocModal() {
        if (typeof resumeAutoRefresh === 'function') resumeAutoRefresh();
        const overlay = document.getElementById('cr-doc-modal-overlay');
        if (overlay) {
            overlay.classList.remove('active');
            setTimeout(() => overlay.remove(), 300);
        }
    }

    // ─── EDIT STATE dialog (XACA-0328-004) ────────────────────────────────────

    /**
     * The 9 valid CR states and their per-state conditional field definitions.
     * `fields` is an ordered array of field descriptors; empty = no extra inputs.
     * required: all listed fields must be non-empty before SUBMIT enables.
     */
    const _CR_STATES = [
        'cr-drafted',
        'cr-submitted',
        'cr-approved',
        'cr-rejected',
        'cr-held',
        'implementing',
        'deployed-dev',
        'deployed-prod',
        'emergency-deployed',
    ];

    const _CR_STATE_FIELDS = {
        'cr-drafted':         [],
        'cr-submitted':       [
            { key: 'cr_proper_url', label: 'CR-PROPER URL', type: 'url', required: true,
              hint: 'Must start with https://' },
        ],
        'cr-approved':        [
            { key: 'approver_login', label: 'APPROVER LOGIN', type: 'text', required: true },
            { key: 'approver_name',  label: 'APPROVER NAME',  type: 'text', required: true },
        ],
        'cr-rejected':        [
            { key: 'pushback_notes', label: 'REJECTION REASON', type: 'textarea', required: true },
        ],
        'cr-held':            [
            { key: 'hold_reason', label: 'HOLD REASON', type: 'textarea', required: true },
        ],
        'implementing':       [],
        'deployed-dev':       [
            { key: 'deploy_estimate', label: 'DEPLOY TIMESTAMP', type: 'datetime-local',
              required: true, defaultNow: true },
        ],
        'deployed-prod':      [
            { key: 'deploy_estimate', label: 'DEPLOY TIMESTAMP', type: 'datetime-local',
              required: true, defaultNow: true },
        ],
        'emergency-deployed': [
            { key: 'emergency_justification', label: 'EMERGENCY JUSTIFICATION',
              type: 'textarea', required: true },
            { key: 'deploy_estimate', label: 'DEPLOY TIMESTAMP', type: 'datetime-local',
              required: true, defaultNow: true },
        ],
    };

    /**
     * Locate the raw CR record from boardData.crs by cr_id.
     * Returns null if not found.
     */
    function _findRawCRById(crId) {
        if (!window.boardData || !Array.isArray(window.boardData.crs)) return null;
        return window.boardData.crs.find(cr => cr && cr.id === crId) || null;
    }

    /**
     * Return a datetime-local string for "now" (local time, no seconds).
     */
    function _nowDatetimeLocal() {
        const d = new Date();
        const pad = n => String(n).padStart(2, '0');
        return `${d.getFullYear()}-${pad(d.getMonth()+1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
    }

    /**
     * Render the conditional fields HTML for a given target state.
     * Returns an HTML string for injection into #cr-state-cond-fields.
     */
    function _renderStateCondFields(targetState) {
        const fieldDefs = _CR_STATE_FIELDS[targetState] || [];
        if (fieldDefs.length === 0) {
            return '<div class="cr-sc-no-fields">No additional fields required for this state.</div>';
        }
        return fieldDefs.map(f => {
            const id = 'cr-sc-field-' + f.key;
            let input;
            if (f.type === 'textarea') {
                input = `<textarea id="${id}" class="cr-sc-textarea" placeholder="" rows="3"></textarea>`;
            } else if (f.type === 'datetime-local') {
                const dflt = f.defaultNow ? ` value="${_nowDatetimeLocal()}"` : '';
                input = `<input type="datetime-local" id="${id}" class="cr-sc-input"${dflt}>`;
            } else {
                // text or url
                input = `<input type="text" id="${id}" class="cr-sc-input" autocomplete="off" spellcheck="false">`;
            }
            const hintHtml = f.hint
                ? `<span class="cr-sc-hint">${escapeHtml(f.hint)}</span>`
                : '';
            return `<div class="cr-sc-field-group">` +
                   `<label class="cr-sc-label" for="${id}">${escapeHtml(f.label)}</label>` +
                   input +
                   hintHtml +
                   `</div>`;
        }).join('');
    }

    /**
     * Validate the current state of all conditional fields for targetState.
     * Returns true when SUBMIT should be enabled.
     * Validation rules:
     *   - All required fields non-empty after trim
     *   - cr_proper_url: must start with https://
     *   - datetime-local: must be parseable
     */
    function _validateStateCondFields(targetState) {
        const fieldDefs = _CR_STATE_FIELDS[targetState] || [];
        for (const f of fieldDefs) {
            if (!f.required) continue;
            const el = document.getElementById('cr-sc-field-' + f.key);
            if (!el) return false;
            const val = (el.value || '').trim();
            if (!val) return false;
            if (f.key === 'cr_proper_url') {
                if (!/^https:\/\//i.test(val)) return false;
            }
            if (f.type === 'datetime-local') {
                if (isNaN(new Date(val).getTime())) return false;
            }
        }
        return true;
    }

    /**
     * Collect the `fields` payload from conditional inputs for a given target state.
     */
    function _collectStateCondFields(targetState) {
        const fieldDefs = _CR_STATE_FIELDS[targetState] || [];
        const fields = {};
        for (const f of fieldDefs) {
            const el = document.getElementById('cr-sc-field-' + f.key);
            if (!el) continue;
            const val = (el.value || '').trim();
            if (f.key === 'approver_login') {
                if (!fields.approver) fields.approver = {};
                fields.approver.login = val;
            } else if (f.key === 'approver_name') {
                if (!fields.approver) fields.approver = {};
                fields.approver.name = val;
            } else {
                fields[f.key] = val;
            }
        }
        return fields;
    }

    /**
     * Open a state-change dialog overlaid on the existing CR-DOCS modal.
     * @param {object} view  — the normalized CR view object (from _crByIdCache)
     */
    function _showCRStateChangeDialog(view) {
        // Remove any existing state-change dialog
        const existing = document.getElementById('cr-state-dialog-overlay');
        if (existing) existing.remove();

        // Resolve optimistic concurrency token from raw CR record
        const rawCR = _findRawCRById(view.cr_id);
        const expectedUpdatedAt = (rawCR && (rawCR.updatedAt || rawCR.lastUpdatedAt)) || '';

        const overlay = document.createElement('div');
        overlay.className = 'lcars-modal-overlay cr-state-dialog-overlay';
        overlay.id = 'cr-state-dialog-overlay';

        const dialog = document.createElement('div');
        dialog.className = 'lcars-modal cr-state-dialog';

        // Build dropdown options — exclude the current state (can't transition to self)
        const options = _CR_STATES.map(s => {
            const label = s.toUpperCase().replace(/-/g, ' ');
            const isCurrent = s === view.crState;
            return `<option value="${escapeHtml(s)}"${isCurrent ? ' data-is-current="true"' : ''}>${escapeHtml(label)}</option>`;
        }).join('');

        dialog.innerHTML =
            `<div class="lcars-modal-header cr-state-dialog-header">` +
                `<span class="lcars-modal-title">EDIT CR STATE — ${escapeHtml(view.cr_id || '')}</span>` +
                `<button class="lcars-modal-close" id="cr-state-dialog-close">&times;</button>` +
            `</div>` +
            `<div class="lcars-modal-body cr-state-dialog-body">` +
                `<div class="cr-sc-meta-row">` +
                    `<div class="cr-sc-meta-cell">` +
                        `<span class="cr-sc-meta-label">CURRENT STATE</span>` +
                        `<span>${_stateBadge(view.crState)}</span>` +
                    `</div>` +
                `</div>` +
                `<div class="cr-sc-field-group cr-sc-target-group">` +
                    `<label class="cr-sc-label" for="cr-sc-target-select">TARGET STATE</label>` +
                    `<select id="cr-sc-target-select" class="cr-sc-select">` +
                        `<option value="">— SELECT —</option>` +
                        options +
                    `</select>` +
                `</div>` +
                `<div class="cr-sc-divider"></div>` +
                `<div id="cr-state-cond-fields" class="cr-sc-cond-fields">` +
                    `<div class="cr-sc-no-fields">Select a target state above.</div>` +
                `</div>` +
                `<div id="cr-sc-error" class="cr-sc-error" style="display:none"></div>` +
                `<div class="cr-sc-actions">` +
                    `<button class="cr-sc-btn cr-sc-cancel" id="cr-sc-cancel">CANCEL</button>` +
                    `<button class="cr-sc-btn cr-sc-submit" id="cr-sc-submit" disabled>SUBMIT</button>` +
                `</div>` +
            `</div>`;

        overlay.appendChild(dialog);

        // Clicking outside the dialog (on the overlay darkened area) = cancel
        overlay.addEventListener('click', e => {
            if (e.target === overlay) _hideCRStateChangeDialog();
        });

        document.body.appendChild(overlay);
        setTimeout(() => overlay.classList.add('active'), 10);

        // Wire close / cancel buttons
        dialog.querySelector('#cr-state-dialog-close').addEventListener('click', _hideCRStateChangeDialog);
        dialog.querySelector('#cr-sc-cancel').addEventListener('click', _hideCRStateChangeDialog);

        // Wire target-state dropdown
        const targetSelect = dialog.querySelector('#cr-sc-target-select');
        const condFieldsDiv = dialog.querySelector('#cr-state-cond-fields');
        const submitBtn = dialog.querySelector('#cr-sc-submit');
        const errorDiv = dialog.querySelector('#cr-sc-error');

        function _refreshCondFields() {
            const targetState = targetSelect.value;
            if (!targetState) {
                condFieldsDiv.innerHTML = '<div class="cr-sc-no-fields">Select a target state above.</div>';
                submitBtn.disabled = true;
                return;
            }
            condFieldsDiv.innerHTML = _renderStateCondFields(targetState);
            _revalidate();
            // Wire input events on newly-rendered fields
            condFieldsDiv.querySelectorAll('input, textarea, select').forEach(el => {
                el.addEventListener('input', _revalidate);
                el.addEventListener('change', _revalidate);
            });
        }

        function _revalidate() {
            const targetState = targetSelect.value;
            if (!targetState) { submitBtn.disabled = true; return; }
            submitBtn.disabled = !_validateStateCondFields(targetState);
        }

        targetSelect.addEventListener('change', () => {
            _hideError();
            _refreshCondFields();
        });

        // Wire SUBMIT button
        submitBtn.addEventListener('click', () => {
            const targetState = targetSelect.value;
            if (!targetState) return;
            if (!_validateStateCondFields(targetState)) return;

            const fields = _collectStateCondFields(targetState);
            const payload = {
                targetState,
                expectedUpdatedAt,
                fields,
                actor: 'lcars-ui',
            };

            _doSubmitTransition(view.cr_id, payload, submitBtn, errorDiv, view);
        });

        function _hideError() {
            errorDiv.style.display = 'none';
            errorDiv.innerHTML = '';
        }
    }

    /**
     * POST the transition request and handle the response.
     * On success: close dialog, re-open docs modal with fresh data.
     * On 409: show inline conflict error with RELOAD button.
     * On 400/other: show inline server error.
     * On network failure: show inline error with RETRY button.
     */
    function _doSubmitTransition(crId, payload, submitBtn, errorDiv, view) {
        submitBtn.disabled = true;
        submitBtn.textContent = 'SUBMITTING...';

        const url = apiUrl('/api/kanban/cr/' + encodeURIComponent(crId) + '/transition');

        function _showError(msg, withReload, withRetry) {
            errorDiv.innerHTML = escapeHtml(msg) +
                (withReload
                    ? ` <button class="cr-sc-btn cr-sc-btn-inline cr-sc-reload" id="cr-sc-reload-btn">RELOAD</button>`
                    : '') +
                (withRetry
                    ? ` <button class="cr-sc-btn cr-sc-btn-inline cr-sc-retry" id="cr-sc-retry-btn">RETRY</button>`
                    : '');
            errorDiv.style.display = 'block';
            submitBtn.textContent = 'SUBMIT';
            submitBtn.disabled = false;

            const reloadBtn = errorDiv.querySelector('#cr-sc-reload-btn');
            if (reloadBtn) {
                reloadBtn.addEventListener('click', () => {
                    // Close dialog, close docs modal, re-open docs modal with fresh data
                    _hideCRStateChangeDialog();
                    _hideCRDocModal();
                    // Re-fetch board data then re-open the docs modal
                    if (typeof window.refreshBoardData === 'function') {
                        window.refreshBoardData(() => {
                            const freshRaw = _findRawCRById(crId);
                            if (freshRaw) {
                                const backlogIdx = _backlogIndex();
                                const freshView = _normalizeCR(freshRaw, backlogIdx);
                                _showCRDocModal(freshView);
                            }
                        });
                    } else {
                        // Fallback: just close both modals — user can navigate back
                    }
                });
            }

            const retryBtn = errorDiv.querySelector('#cr-sc-retry-btn');
            if (retryBtn) {
                retryBtn.addEventListener('click', () => {
                    errorDiv.style.display = 'none';
                    _doSubmitTransition(crId, payload, submitBtn, errorDiv, view);
                });
            }
        }

        fetch(url, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload),
        })
        .then(r => {
            if (r.status === 409) {
                return r.json().then(data => {
                    _showError(
                        'This CR was modified by another session. Reload to see the latest state.',
                        true,   // withReload
                        false,  // withRetry
                    );
                }).catch(() => {
                    _showError(
                        'This CR was modified by another session. Reload to see the latest state.',
                        true,
                        false,
                    );
                });
            }
            if (!r.ok) {
                return r.json().then(data => {
                    const msg = (data && data.error) ? data.error : ('Server error ' + r.status);
                    _showError(msg, false, false);
                }).catch(() => {
                    _showError('Server error ' + r.status + '. Check server logs.', false, false);
                });
            }
            return r.json().then(data => {
                if (!data || !data.ok) {
                    const msg = (data && data.error) ? data.error : 'Transition failed (server returned ok=false).';
                    _showError(msg, false, false);
                    return;
                }
                // Success — close dialog, refresh docs modal
                _hideCRStateChangeDialog();
                _hideCRDocModal();
                // Re-fetch boardData if possible, then re-open updated docs modal
                if (typeof window.refreshBoardData === 'function') {
                    window.refreshBoardData(() => {
                        const freshRaw = _findRawCRById(crId);
                        if (freshRaw) {
                            const backlogIdx = _backlogIndex();
                            const freshView = _normalizeCR(freshRaw, backlogIdx);
                            _crByIdCache[crId] = freshView;
                            _showCRDocModal(freshView);
                        }
                    });
                } else {
                    // If we can't refresh board data, just update the cache from the
                    // returned CR object (if the server echoed it back in data.cr)
                    if (data.cr) {
                        const backlogIdx = _backlogIndex();
                        const freshView = _normalizeCR(data.cr, backlogIdx);
                        _crByIdCache[crId] = freshView;
                        _showCRDocModal(freshView);
                    }
                }
            });
        })
        .catch(() => {
            _showError('Network error — could not reach the server.', false, true);
        });
    }

    function _hideCRStateChangeDialog() {
        const overlay = document.getElementById('cr-state-dialog-overlay');
        if (overlay) {
            overlay.classList.remove('active');
            setTimeout(() => overlay.remove(), 250);
        }
    }

    /**
     * Render the static metadata block at the top of the CR-only modal:
     * id, type, state, summary, deploy window, approver, linked items
     * (lists ALL items per XACA-0310-005 when linkedItemIds.length > 1),
     * cr_doc_link launch button, and cr_proper_url (XACA-0328) when present.
     */
    function _renderCRMetadata(view) {
        const link = view.cr_doc_link || '';
        const isUrl = /^https?:\/\//i.test(link);
        const launch = isUrl
            ? `<a class="cr-doc-launch" href="${escapeHtml(link)}" target="_blank" rel="noopener noreferrer">OPEN CR DOC →</a>`
            : '';

        // Defense-in-depth: only render cr_proper_url as a clickable link
        // when its scheme is http(s). escapeHtml encodes <>&" but does NOT
        // strip a leading 'javascript:' scheme, so a stale/legacy value on
        // disk could fire when clicked. Reject anything else, render as text.
        const properUrl = view.cr_proper_url || '';
        const properUrlIsHttp = /^https?:\/\//i.test(properUrl);
        const properUrlCell = !properUrl
            ? '<span class="cr-dim">—</span>'
            : properUrlIsHttp
                ? `<a class="cr-proper-url-link" href="${escapeHtml(properUrl)}" target="_blank" rel="noopener noreferrer">${escapeHtml(properUrl)}</a>`
                : `<span class="cr-dim" title="Non-http(s) scheme refused">${escapeHtml(properUrl)}</span>`;

        // Show all linked items, not just the first (XACA-0310-005).
        const allIds = view.linkedItemIds && view.linkedItemIds.length > 0
            ? view.linkedItemIds
            : (view.id ? [view.id] : []);
        const items = allIds.length > 0
            ? allIds.map(id => `<span class="cr-id-mono">${escapeHtml(id)}</span>`).join(' ')
            : '<span class="cr-dim">—</span>';

        const summary = view.cr_summary
            ? `<div class="cr-doc-summary">${escapeHtml(view.cr_summary)}</div>`
            : '';

        return `
            <div class="cr-doc-meta">
                <div class="cr-doc-meta-row">
                    <div class="cr-doc-meta-cell"><span class="cr-doc-meta-label">TYPE</span>${_typeBadge(view.cr_type)}</div>
                    <div class="cr-doc-meta-cell"><span class="cr-doc-meta-label">STATE</span>${_stateBadge(view.crState)}</div>
                    <div class="cr-doc-meta-cell"><span class="cr-doc-meta-label">PLATFORM</span><span>${escapeHtml(view.platform || '—')}</span></div>
                    <div class="cr-doc-meta-cell"><span class="cr-doc-meta-label">DEPLOY</span><span>${_formatDeployWindow(view.deploy_window_planned)}</span></div>
                </div>
                <div class="cr-doc-meta-row">
                    <div class="cr-doc-meta-cell"><span class="cr-doc-meta-label">APPROVER</span><span>${escapeHtml(view.cr_approver_name || view.cr_approved_by || '—')}</span></div>
                    <div class="cr-doc-meta-cell"><span class="cr-doc-meta-label">PUSHBACKS</span>${_pushbackDisplay(view.cr_pushback_count)}</div>
                    <div class="cr-doc-meta-cell cr-doc-linked-items"><span class="cr-doc-meta-label">LINKED ITEMS</span><span class="cr-linked-ids">${items}</span></div>
                </div>
                <div class="cr-doc-meta-row cr-doc-url-row">
                    <div class="cr-doc-meta-cell cr-doc-meta-cell--wide"><span class="cr-doc-meta-label">CR-PROPER URL</span>${properUrlCell}</div>
                </div>
                ${summary}
                ${launch ? `<div class="cr-doc-launch-row">${launch}</div>` : ''}
            </div>`;
    }

    // ─── Public: initChangeReqTab ─────────────────────────────────────────────

    /**
     * Idempotent initialisation.
     * Mounts the filter bar and wires the crsupport-changed listener.
     * Safe to call before boardData is populated.
     */
    function initChangeReqTab() {
        if (_initialized) return;
        _initialized = true;

        // Wire sub-tab toggle (PIPELINE | CYCLE TIME)
        _initSubtabs();

        // Mount filter bar (will no-op gracefully if container not in DOM yet)
        _initFilterBar();

        // Mount saved-view chips
        _initSavedViews();

        // If a saved view was active when page last closed, restore its filter preset.
        // The filter state was already persisted separately, so this just re-syncs the chip.
        if (_activeSavedView && SAVED_VIEWS[_activeSavedView]) {
            _syncSavedViewChips();
        }

        // Listen for crSupport flag changes — clear list when feature turns off
        document.addEventListener('crsupport-changed', e => {
            if (!e.detail || !e.detail.enabled) {
                const listEl = document.getElementById('change-req-list');
                if (listEl) {
                    listEl.innerHTML = '<div class="change-req-empty">No change requests</div>';
                }
                const countEl = document.getElementById('change-req-count');
                if (countEl) countEl.textContent = '0 ITEMS';
            }
        });
    }

    // ─── Expose on window ────────────────────────────────────────────────────

    window.initChangeReqTab    = initChangeReqTab;
    window.renderChangeReqList = renderChangeReqList;

}());
