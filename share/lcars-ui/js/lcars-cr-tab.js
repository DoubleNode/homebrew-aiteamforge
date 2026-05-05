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
 * Public API (globals):
 *   initChangeReqTab()       — idempotent; called from lcars.js on page load.
 *   renderChangeReqList()    — called when user navigates into CHANGE REQ section.
 *
 * Dependencies (all defined in lcars.js, which loads before this file):
 *   boardData, apiUrl, escapeHtml, showPlanDocModal, switchDocTab
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

    // ─── Saved-view state ─────────────────────────────────────────────────────

    const SAVED_VIEW_KEY = 'lcars-change-req-saved-view';

    /**
     * Stable view IDs — do NOT rename; persisted to localStorage.
     * Labels may change freely; these IDs must not.
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
                const ts = item.cr_emergency_deployed_at || item.cr_completed_at || item.addedAt;
                return ts ? isWithinLastNDays(new Date(ts).getTime(), 30) : false;
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
    const SORT_VALUES = ['STATE', 'TYPE', 'PLATFORM', 'APPROVER'];

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
            const preset = SAVED_VIEWS[viewId].preset;
            Object.assign(_filterState, preset);
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
     * normalizing CR objects.
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
     * cr_completed_at, addedAt, priority, id). The `id` field is set to the
     * first linked backlog item id so the DOCS button can drive the existing
     * plan-doc modal (which looks items up by backlog id).
     */
    function _normalizeCR(cr, backlogIdx) {
        const ts = cr.timestamps || {};
        const firstItemId = Array.isArray(cr.itemIds) && cr.itemIds.length > 0 ? cr.itemIds[0] : '';
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
            cr_emergency_deployed_at:   ts.cr_emergency_deployed_at || '',
            cr_completed_at:            ts.cr_completed_at || '',
            addedAt:                    cr.createdAt || '',
            priority:                   linkedItem ? linkedItem.priority : '',
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

        if (!window.boardData) return [];
        const crs = window.boardData.crs;
        if (!Array.isArray(crs) || crs.length === 0) return [];
        const backlogIdx = _backlogIndex();
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

    // ─── Row renderer ─────────────────────────────────────────────────────────

    function _renderRow(item) {
        const crId       = escapeHtml(item.cr_id || '');
        const crType     = _typeBadge(item.cr_type);
        const crState    = _stateBadge(item.crState);
        const title      = escapeHtml(item.title || '');
        const platform   = escapeHtml(item.platform || '');
        const approver   = escapeHtml(item.cr_approver_name || item.cr_approved_by || '');
        const deployWin  = _formatDeployWindow(item.deploy_window_planned);
        const pushbacks  = _pushbackDisplay(item.cr_pushback_count);
        const hasCRDoc   = !!(item.cr_doc_link && String(item.cr_doc_link).trim().length > 0);

        // DOCS button on the CR list opens a CR-only modal — distinct from the
        // item DOCS button which shows Plan/Retro/CR tabs. We stash the CR id on
        // the button so the click handler can look the full CR view-object back
        // up from the cached list (avoids re-fetching boardData).
        const docsBtn = hasCRDoc
            ? `<button class="cr-docs-btn" data-cr-id="${escapeHtml(item.cr_id)}" title="View CR document">DOCS</button>`
            : `<span class="cr-docs-placeholder"></span>`;

        return `<tr class="cr-row" data-item-id="${escapeHtml(item.id)}">
            <td class="cr-col-id"><button class="cr-id-copy" data-cr-id="${crId}" title="Copy CR ID to clipboard"><span class="cr-id-mono">${crId}</span></button></td>
            <td class="cr-col-type">${crType}</td>
            <td class="cr-col-state">${crState}</td>
            <td class="cr-col-title" title="${title}"><span class="cr-title-text">${title}</span></td>
            <td class="cr-col-platform">${platform}</td>
            <td class="cr-col-approver">${approver}</td>
            <td class="cr-col-deploy">${deployWin}</td>
            <td class="cr-col-pushbacks">${pushbacks}</td>
            <td class="cr-col-docs">${docsBtn}</td>
        </tr>`;
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

        const rows = sorted.map(_renderRow).join('');

        listEl.innerHTML = `
            <table class="cr-table">
                <thead>
                    <tr class="cr-header-row">
                        <th class="cr-col-id">CR ID</th>
                        <th class="cr-col-type">TYPE</th>
                        <th class="cr-col-state">STATE</th>
                        <th class="cr-col-title">TITLE</th>
                        <th class="cr-col-platform">PLATFORM</th>
                        <th class="cr-col-approver">APPROVER</th>
                        <th class="cr-col-deploy">DEPLOY WINDOW</th>
                        <th class="cr-col-pushbacks">PUSHBACKS</th>
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
    }

    // ─── CR-only modal ────────────────────────────────────────────────────────

    /**
     * Show a CR-only modal for a CR record. Distinct from showPlanDocModal:
     * no Plan/Retro tabs, title is the CR id (not the linked item id), and
     * the body shows CR metadata + a launch button for the external CR doc.
     *
     * If cr_doc_link is an http(s) URL, render a launch button (the CR doc is
     * typically a Confluence page). If it's a relative path inside the kanban
     * dir, fetch via /api/kanban/<itemId>/cr-content and render markdown.
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

        // Always fetch the CR doc from the server. The local markdown file
        // (change-requests/<CR-ID>*.md) is the source of truth. The server
        // returns { content, filename, confluenceUrl } when the file exists,
        // or { isExternal:true, url } as a fallback when only the Confluence
        // link is available. The metadata block already includes a launch
        // button for external URLs, so when content is present we render
        // the markdown body and let the metadata button handle the link.
        if (view.id) {
            fetch(apiUrl('/api/kanban/' + encodeURIComponent(view.id) + '/cr-content'))
                .then(r => { if (!r.ok) throw new Error('CR document not found'); return r.json(); })
                .then(data => {
                    if (data && data.content != null) {
                        const md = (typeof renderMarkdown === 'function')
                            ? renderMarkdown(data.content || '')
                            : `<pre class="cr-doc-pre">${escapeHtml(data.content || '')}</pre>`;
                        contentDiv.innerHTML = '<div class="cr-doc-md">' + md + '</div>';
                    }
                    // else: external-only — metadata launch button is sufficient.
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
     * id, type, state, summary, deploy window, approver, linked items,
     * cr_doc_link launch button, and cr_proper_url when present.
     */
    function _renderCRMetadata(view) {
        const link = view.cr_doc_link || '';
        const isUrl = /^https?:\/\//i.test(link);
        const launch = isUrl
            ? `<a class="cr-doc-launch" href="${escapeHtml(link)}" target="_blank" rel="noopener noreferrer">OPEN CR DOC →</a>`
            : '';

        const properUrl = view.cr_proper_url || '';
        const properUrlCell = properUrl
            ? `<a class="cr-proper-url-link" href="${escapeHtml(properUrl)}" target="_blank" rel="noopener noreferrer">${escapeHtml(properUrl)}</a>`
            : '<span class="cr-dim">—</span>';

        const items = (view.id && view.id.trim().length > 0)
            ? `<span class="cr-id-mono">${escapeHtml(view.id)}</span>`
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
                    <div class="cr-doc-meta-cell"><span class="cr-doc-meta-label">LINKED ITEM</span>${items}</div>
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
