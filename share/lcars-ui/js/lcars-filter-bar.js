/**
 * lcars-filter-bar.js — Reusable LCARS filter-bar component
 *
 * XACA-0292-005: Extracted from lcars.js so the BACKLOG section and future
 * consumers (CHANGE REQ tab, etc.) can share the same filter-bar UX without
 * duplicating state management, event wiring, or localStorage persistence.
 *
 * Usage:
 *   const fb = createFilterBar({
 *     containerId:   'backlog-filter-bar',
 *     storageKey:    'lcars-queue-filter',
 *     initialState:  { activeFilters: ['all'], searchText: '', sortBy: 'priority',
 *                      osFilter: 'all', releaseFilter: 'all', epicFilter: 'all',
 *                      categoryFilter: 'all' },
 *     osPlatforms:   ['iOS', 'Android', 'Firebase', 'Web'],   // optional
 *     osConfig:      { iOS: { color, logo, label }, ... },    // optional
 *     releaseOptionsEndpoint: '/api/releases',                // optional
 *     epicOptionsEndpoint:    '/api/epics',                   // optional
 *     extraButtons:  [{ id: 'backlog-import-btn', label: '↓ IMPORT', onClick: fn }],
 *     viewToggle:    { btnId: 'view-toggle-btn', valueId: 'view-toggle-value',
 *                      sectionSelector: '.backlog-section',
 *                      storageKey: 'lcars-view-toggle',
 *                      values: ['TAGS', 'TRACKING'] },
 *     onChange: (state) => { renderList(); },
 *   });
 *
 * Public API:
 *   fb.getState()                — returns live state object (same reference always)
 *   fb.setState(partial)         — merge partial state, persist, call onChange
 *   fb.refresh()                 — re-sync all UI controls from current state
 *   fb.filterItems(items, matchFn) — convenience: items.filter(i => matchFn(i, fb.getState()))
 *   fb.populateReleaseOptions()  — async; re-fetch + rebuild release <select>
 *   fb.populateEpicOptions()     — async; re-fetch + rebuild epic <select>
 *   fb.updateReleaseStyle()      — sync active/inactive CSS class on release dropdown
 *   fb.save()                    — persist state to localStorage
 */

/* global apiUrl */   // defined in lcars.js; available because this file loads before it

'use strict';

/**
 * @param {object} options
 * @returns {{ getState, setState, refresh, filterItems, populateReleaseOptions, populateEpicOptions, updateReleaseStyle, save }}
 */
function createFilterBar(options) {
    const {
        containerId,
        storageKey,
        initialState = {},
        osPlatforms = [],
        osConfig = {},
        releaseOptionsEndpoint = null,
        epicOptionsEndpoint = null,
        extraButtons = [],
        viewToggle = null,
        onChange = null,
    } = options;

    // ─── State ───────────────────────────────────────────────────────────────────

    const DEFAULT_STATE = {
        activeFilters:  ['all'],
        searchText:     '',
        sortBy:         'priority',
        osFilter:       'all',
        releaseFilter:  'all',
        epicFilter:     'all',
        categoryFilter: 'all',
    };

    // Merge caller defaults into a new state object (live reference returned to caller)
    const state = Object.assign({}, DEFAULT_STATE, initialState);

    // Load persisted values on top of defaults+initialState
    _loadState();

    // ─── State helpers ────────────────────────────────────────────────────────────

    function _loadState() {
        try {
            const saved = localStorage.getItem(storageKey);
            if (!saved) return;
            const parsed = JSON.parse(saved);
            if (Array.isArray(parsed.activeFilters) && parsed.activeFilters.length > 0) {
                state.activeFilters = parsed.activeFilters;
            }
            if (typeof parsed.searchText === 'string') {
                state.searchText = parsed.searchText;
            }
            if (parsed.sortBy === 'priority' || parsed.sortBy === 'due_date') {
                state.sortBy = parsed.sortBy;
            }
            if (parsed.osFilter)       state.osFilter       = parsed.osFilter;
            if (parsed.releaseFilter)  state.releaseFilter  = parsed.releaseFilter;
            if (parsed.epicFilter)     state.epicFilter     = parsed.epicFilter;
            if (parsed.categoryFilter) state.categoryFilter = parsed.categoryFilter;
        } catch (e) {
            console.warn('[FilterBar] Could not load filter state:', e);
        }
    }

    function _saveState() {
        try {
            localStorage.setItem(storageKey, JSON.stringify(state));
        } catch (e) {
            console.warn('[FilterBar] Could not save filter state:', e);
        }
    }

    function _applyStateChange(partial) {
        Object.assign(state, partial);
        _saveState();
        if (typeof onChange === 'function') onChange(state);
    }

    // ─── Status pills ─────────────────────────────────────────────────────────────

    function _syncPillsUI() {
        const filterBar = document.getElementById(containerId);
        if (!filterBar) return;
        filterBar.querySelectorAll('.filter-pill').forEach(pill => {
            const filter = pill.dataset.filter;
            if (state.activeFilters.includes(filter)) {
                pill.classList.add('active');
            } else {
                pill.classList.remove('active');
            }
        });
    }

    function _togglePill(filterName) {
        const filters = state.activeFilters;
        if (filterName === 'all') {
            state.activeFilters = ['all'];
        } else {
            const allIndex = filters.indexOf('all');
            if (allIndex > -1) filters.splice(allIndex, 1);

            const filterIndex = filters.indexOf(filterName);
            if (filterIndex > -1) {
                filters.splice(filterIndex, 1);
            } else {
                filters.push(filterName);
            }

            if (filters.length === 0) state.activeFilters = ['all'];
        }
        _saveState();
        _syncPillsUI();
        _syncSortToggleVisibility();
        if (typeof onChange === 'function') onChange(state);
    }

    function _wirePills() {
        const filterBar = document.getElementById(containerId);
        if (!filterBar) return;
        filterBar.querySelectorAll('.filter-pill').forEach(pill => {
            pill.addEventListener('click', () => _togglePill(pill.dataset.filter));
        });
    }

    // ─── Sort toggle ──────────────────────────────────────────────────────────────

    function _syncSortToggleVisibility() {
        const sortToggle = document.getElementById('sort-toggle');
        if (sortToggle) {
            const showingCompleted = state.activeFilters.includes('completed');
            sortToggle.style.display = showingCompleted ? 'none' : '';
        }
    }

    function _syncSortToggleValue() {
        const sortValue = document.getElementById('sort-value');
        if (sortValue) {
            sortValue.textContent = state.sortBy === 'due_date' ? 'DUE DATE' : 'PRIORITY';
        }
    }

    function _wireSortToggle() {
        const sortToggle = document.getElementById('sort-toggle');
        const sortValue  = document.getElementById('sort-value');
        if (!sortToggle || !sortValue) return;

        sortValue.textContent = state.sortBy === 'due_date' ? 'DUE DATE' : 'PRIORITY';

        sortToggle.addEventListener('click', () => {
            state.sortBy = state.sortBy === 'priority' ? 'due_date' : 'priority';
            sortValue.textContent = state.sortBy === 'due_date' ? 'DUE DATE' : 'PRIORITY';
            _saveState();
            if (typeof onChange === 'function') onChange(state);
        });
    }

    // ─── OS dropdown ─────────────────────────────────────────────────────────────
    // Only wired when osPlatforms / osConfig are provided.

    function _syncOSDropdownStyle() {
        if (!osPlatforms.length) return;
        const dropdown = document.getElementById('os-filter-dropdown');
        const iconEl   = document.getElementById('os-filter-icon');
        const valueEl  = document.getElementById('os-filter-value');
        const current  = state.osFilter || 'all';

        if (dropdown) {
            if (current !== 'all') {
                dropdown.classList.add('active');
            } else {
                dropdown.classList.remove('active');
            }
        }

        if (iconEl && valueEl) {
            if (current === 'all') {
                iconEl.innerHTML  = '<span class="os-filter-all-icon">⊕</span>';
                valueEl.textContent = 'ALL';
            } else if (current === 'none') {
                iconEl.innerHTML = `<svg viewBox="0 0 24 24" fill="currentColor" width="16" height="16">
                    <circle cx="12" cy="12" r="10" fill="none" stroke="currentColor" stroke-width="2"/>
                    <text x="12" y="17" text-anchor="middle" font-size="14" font-weight="bold">?</text>
                </svg>`;
                valueEl.textContent = 'None';
            } else {
                const cfg = osConfig[current];
                if (cfg && cfg.logo) {
                    // Use DOM construction to avoid innerHTML interpolation of config-derived strings (XACA-0292-014)
                    const img = document.createElement('img');
                    img.src       = cfg.logo;
                    img.alt       = cfg.label || '';
                    img.className = 'os-filter-logo';
                    iconEl.textContent = '';
                    iconEl.appendChild(img);
                }
                valueEl.textContent = cfg ? cfg.label : current;
            }
        }
    }

    function _showOSDropdown() {
        if (!osPlatforms.length) return;
        // Toggle off if already open
        const existing = document.querySelector('.os-filter-popup');
        if (existing) { existing.remove(); return; }

        const trigger = document.getElementById('os-filter-trigger');
        if (!trigger) return;

        const dropdown = document.createElement('div');
        dropdown.className = 'os-filter-popup';

        const current = state.osFilter || 'all';

        // _makeOption accepts a pre-built DOM node (iconNode) rather than raw HTML to avoid
        // innerHTML interpolation of config-derived strings (XACA-0292-014).
        const _makeOption = (value, iconNode, label) => {
            const opt = document.createElement('div');
            opt.className = 'os-filter-option' + (current === value ? ' selected' : '');
            opt.appendChild(iconNode);
            const labelSpan = document.createElement('span');
            labelSpan.textContent = label;
            opt.appendChild(labelSpan);
            opt.addEventListener('click', (e) => {
                e.stopPropagation();
                state.osFilter = value;
                _syncOSDropdownStyle();
                _saveState();
                dropdown.remove();
                if (typeof onChange === 'function') onChange(state);
            });
            return opt;
        };

        // 'all' option — static developer-controlled content; build as DOM node
        const allIconSpan = document.createElement('span');
        allIconSpan.className = 'os-filter-option-icon';
        allIconSpan.textContent = '⊕';
        dropdown.appendChild(_makeOption('all', allIconSpan, 'ALL'));

        osPlatforms.forEach(os => {
            const cfg = osConfig[os] || {};
            let iconNode;
            if (cfg.logo) {
                // cfg.logo is a URL string; use <img> DOM node to avoid innerHTML interpolation
                iconNode = document.createElement('img');
                iconNode.src       = cfg.logo;
                iconNode.alt       = cfg.label || '';
                iconNode.className = 'os-filter-option-logo';
            } else {
                iconNode = document.createElement('span');
                iconNode.className   = 'os-filter-option-icon';
                iconNode.textContent = '?';
            }
            const opt = _makeOption(os, iconNode, cfg.label || os);
            if (cfg.color) opt.style.setProperty('--option-color', cfg.color);
            dropdown.appendChild(opt);
        });

        // 'none' option — static SVG is developer-controlled; safe to set innerHTML once on a fresh element
        const noneIconContainer = document.createElement('span');
        noneIconContainer.innerHTML = `<svg viewBox="0 0 24 24" fill="currentColor" width="16" height="16" class="os-filter-option-icon">
            <circle cx="12" cy="12" r="10" fill="none" stroke="currentColor" stroke-width="2"/>
            <text x="12" y="17" text-anchor="middle" font-size="14" font-weight="bold">?</text>
        </svg>`;
        dropdown.appendChild(_makeOption('none', noneIconContainer, 'None'));

        const rect = trigger.getBoundingClientRect();
        dropdown.style.position = 'fixed';
        dropdown.style.top      = `${rect.bottom + 4}px`;
        dropdown.style.left     = `${rect.left}px`;
        dropdown.style.zIndex   = '1000';
        document.body.appendChild(dropdown);

        const _close = (e) => {
            if (!dropdown.contains(e.target) && !trigger.contains(e.target)) {
                dropdown.remove();
                document.removeEventListener('click', _close);
            }
        };
        setTimeout(() => document.addEventListener('click', _close), 0);
    }

    function _wireOSDropdown() {
        if (!osPlatforms.length) return;
        const trigger = document.getElementById('os-filter-trigger');
        if (!trigger) return;
        _syncOSDropdownStyle();
        trigger.addEventListener('click', (e) => {
            e.stopPropagation();
            _showOSDropdown();
        });
    }

    // ─── Release dropdown ─────────────────────────────────────────────────────────

    function _syncReleaseStyle() {
        const dropdown = document.getElementById('release-filter-dropdown');
        const select   = document.getElementById('release-filter-select');
        if (dropdown && select) {
            if (select.value !== 'all') {
                dropdown.classList.add('active');
            } else {
                dropdown.classList.remove('active');
            }
        }
    }

    async function _populateReleaseOptions() {
        const select = document.getElementById('release-filter-select');
        if (!select || !releaseOptionsEndpoint) return;
        try {
            const [activeRes, archivedRes] = await Promise.all([
                fetch(apiUrl(`${releaseOptionsEndpoint}?status=active`)),
                fetch(apiUrl(`${releaseOptionsEndpoint}?status=archived`)),
            ]);
            if (!activeRes.ok) return;

            const activeData = await activeRes.json();
            const releases   = (activeData.releases || []).sort((a, b) => {
                const aDate = a.targetDate ? new Date(a.targetDate) : null;
                const bDate = b.targetDate ? new Date(b.targetDate) : null;
                if (aDate && bDate) return aDate - bDate;
                return ((a.shortTitle || a.name || '')).localeCompare((b.shortTitle || b.name || ''));
            });

            let archived = [];
            if (archivedRes.ok) {
                const archData = await archivedRes.json();
                archived = (archData.releases || [])
                    .sort((a, b) => {
                        const aD = a.archivedAt ? new Date(a.archivedAt) : new Date(0);
                        const bD = b.archivedAt ? new Date(b.archivedAt) : new Date(0);
                        return bD - aD;
                    })
                    .slice(0, 5);
            }

            const targetValue = state.releaseFilter || select.value || 'all';

            // Trim to fixed options (ALL / ASSIGNED / UNASSIGNED)
            while (select.options.length > 3) select.remove(3);

            const _addSeparator = (label) => {
                const sep = document.createElement('option');
                sep.value    = '---';
                sep.textContent = label;
                sep.disabled = true;
                select.appendChild(sep);
            };
            const _addRelease = (release, suffix) => {
                const opt = document.createElement('option');
                opt.value = release.id;
                let name  = (release.shortTitle && release.name)
                    ? `${release.shortTitle} - ${release.name}`
                    : (release.name || release.id);
                opt.textContent = name.length > 35 ? name.substring(0, 35) + '…' : name;
                opt.title       = `${release.name} (${release.id})${suffix || ''}`;
                select.appendChild(opt);
            };

            if (releases.length)  { _addSeparator('── Active ──');   releases.forEach(r => _addRelease(r, '')); }
            if (archived.length)  { _addSeparator('── Archived ──'); archived.forEach(r => _addRelease(r, ' [Archived]')); }

            select.value = targetValue;
            if (select.value !== targetValue) {
                select.value = 'all';
                state.releaseFilter = 'all';
            }
        } catch (e) {
            console.log('[FilterBar] Could not load releases:', e);
        }
    }

    function _wireReleaseDropdown() {
        const select = document.getElementById('release-filter-select');
        if (!select) return;
        select.value = state.releaseFilter || 'all';
        _syncReleaseStyle();
        select.addEventListener('change', (e) => {
            state.releaseFilter = e.target.value;
            _syncReleaseStyle();
            _saveState();
            if (typeof onChange === 'function') onChange(state);
        });
        if (releaseOptionsEndpoint) _populateReleaseOptions();
    }

    // ─── Epic dropdown ────────────────────────────────────────────────────────────

    function _syncEpicStyle() {
        const dropdown = document.getElementById('epic-filter-dropdown');
        const select   = document.getElementById('epic-filter-select');
        if (dropdown && select) {
            if (select.value !== 'all') {
                dropdown.classList.add('active');
            } else {
                dropdown.classList.remove('active');
            }
        }
    }

    async function _populateEpicOptions() {
        const select = document.getElementById('epic-filter-select');
        if (!select || !epicOptionsEndpoint) return;
        try {
            const response = await fetch(apiUrl(epicOptionsEndpoint));
            if (!response.ok) return;
            const data  = await response.json();
            const epics = data.epics || [];

            const targetValue = state.epicFilter || select.value || 'all';

            while (select.options.length > 3) select.remove(3);

            if (epics.length > 0) {
                const sep = document.createElement('option');
                sep.value    = '---';
                sep.textContent = '───────────';
                sep.disabled = true;
                select.appendChild(sep);

                epics.forEach(epic => {
                    const opt = document.createElement('option');
                    opt.value = epic.id;
                    let name  = (epic.shortTitle && (epic.title || epic.name))
                        ? `${epic.shortTitle} - ${epic.title || epic.name}`
                        : (epic.title || epic.name || epic.id);
                    opt.textContent = name.length > 35 ? name.substring(0, 35) + '…' : name;
                    opt.title       = `${epic.title || epic.name} (${epic.id})`;
                    select.appendChild(opt);
                });
            }

            select.value = targetValue;
            if (select.value !== targetValue) {
                select.value = 'all';
                state.epicFilter = 'all';
            }
        } catch (e) {
            console.log('[FilterBar] Could not load epics:', e);
        }
    }

    function _wireEpicDropdown() {
        const select = document.getElementById('epic-filter-select');
        if (!select) return;
        select.value = state.epicFilter || 'all';
        _syncEpicStyle();
        select.addEventListener('change', (e) => {
            state.epicFilter = e.target.value;
            _syncEpicStyle();
            _saveState();
            if (typeof onChange === 'function') onChange(state);
        });
        if (epicOptionsEndpoint) _populateEpicOptions();
    }

    // ─── Category dropdown ────────────────────────────────────────────────────────

    function _syncCategoryStyle() {
        const dropdown = document.getElementById('category-filter-dropdown');
        const select   = document.getElementById('category-filter-select');
        if (dropdown && select) {
            if (select.value !== 'all') {
                dropdown.classList.add('active');
            } else {
                dropdown.classList.remove('active');
            }
        }
    }

    function _wireCategoryDropdown() {
        const select = document.getElementById('category-filter-select');
        if (!select) return;
        select.value = state.categoryFilter || 'all';
        _syncCategoryStyle();
        select.addEventListener('change', (e) => {
            state.categoryFilter = e.target.value;
            _syncCategoryStyle();
            _saveState();
            if (typeof onChange === 'function') onChange(state);
        });
    }

    // ─── Search input ─────────────────────────────────────────────────────────────

    function _wireSearch() {
        const input     = document.getElementById('backlog-filter-text');
        const clearBtn  = document.getElementById('backlog-filter-clear');
        if (!input) return;

        input.value = state.searchText || '';

        let debounceTimer;
        input.addEventListener('input', (e) => {
            clearTimeout(debounceTimer);
            debounceTimer = setTimeout(() => {
                state.searchText = e.target.value;
                _saveState();
                if (typeof onChange === 'function') onChange(state);
            }, 150);
        });

        input.addEventListener('keydown', (e) => {
            if (e.key === 'Escape') {
                input.value = '';
                state.searchText = '';
                _saveState();
                if (typeof onChange === 'function') onChange(state);
                input.blur();
            }
        });

        if (clearBtn) {
            clearBtn.addEventListener('click', () => {
                input.value = '';
                state.searchText = '';
                _saveState();
                if (typeof onChange === 'function') onChange(state);
                input.focus();
            });
        }
    }

    function _syncSearchUI() {
        const input = document.getElementById('backlog-filter-text');
        if (input && input !== document.activeElement) {
            input.value = state.searchText || '';
        }
    }

    // ─── Extra buttons ────────────────────────────────────────────────────────────

    function _wireExtraButtons() {
        extraButtons.forEach(btn => {
            const el = document.getElementById(btn.id);
            if (el && typeof btn.onClick === 'function') {
                el.addEventListener('click', btn.onClick);
            }
        });
    }

    // ─── View toggle ──────────────────────────────────────────────────────────────

    function _wireViewToggle() {
        if (!viewToggle) return;
        const { btnId, valueId, sectionSelector, storageKey: vtKey, values } = viewToggle;
        const toggleBtn   = document.getElementById(btnId);
        const toggleValue = document.getElementById(valueId);
        const section     = sectionSelector ? document.querySelector(sectionSelector) : null;

        if (!toggleBtn || !toggleValue) return;

        let vtState = values[0]; // default to first value (e.g. 'tags')

        const saved = vtKey ? localStorage.getItem(vtKey) : null;
        if (saved && values.includes(saved.toUpperCase())) {
            vtState = saved.toUpperCase();
        } else if (saved && values.map(v => v.toLowerCase()).includes(saved.toLowerCase())) {
            // case-insensitive match
            vtState = values.find(v => v.toLowerCase() === saved.toLowerCase()) || vtState;
        }

        const _applyVT = (val) => {
            vtState = val;
            const isFirst = (val === values[0]);
            toggleValue.textContent = val;
            if (isFirst) {
                toggleBtn.classList.remove('active');
                if (section) section.classList.remove('show-tracking');
            } else {
                toggleBtn.classList.add('active');
                if (section) section.classList.add('show-tracking');
            }
            if (vtKey) localStorage.setItem(vtKey, val.toLowerCase());
        };

        _applyVT(vtState);

        toggleBtn.addEventListener('click', () => {
            const nextIndex = (values.indexOf(vtState) + 1) % values.length;
            _applyVT(values[nextIndex]);
        });

        toggleBtn.addEventListener('keydown', (e) => {
            if (e.key === 'Enter' || e.key === ' ') {
                e.preventDefault();
                toggleBtn.click();
            }
        });
    }

    // ─── Full UI sync (called on init and from refresh()) ────────────────────────

    function _syncAllUI() {
        _syncPillsUI();
        _syncSearchUI();
        _syncSortToggleVisibility();
        _syncSortToggleValue();
        _syncOSDropdownStyle();
        _syncReleaseStyle();
        _syncEpicStyle();
        _syncCategoryStyle();
    }

    // ─── Init (wire all controls) ─────────────────────────────────────────────────

    function _init() {
        const filterBar = document.getElementById(containerId);
        if (!filterBar) return;

        _wirePills();
        _wireSortToggle();
        _wireOSDropdown();
        _wireReleaseDropdown();
        _wireEpicDropdown();
        _wireCategoryDropdown();
        _wireSearch();
        _wireExtraButtons();
        _wireViewToggle();
        _syncAllUI();
    }

    _init();

    // ─── Public API ───────────────────────────────────────────────────────────────

    return {
        /**
         * Returns the live state object (same reference; mutating it bypasses persistence).
         * Prefer setState() for tracked changes.
         */
        getState() {
            return state;
        },

        /**
         * Merge partial into state, persist, call onChange, re-sync UI.
         * @param {object} partial
         */
        setState(partial) {
            _applyStateChange(partial);
            _syncAllUI();
        },

        /**
         * Re-sync all filter-bar UI controls from current state.
         * Call after external state mutations (e.g. viewReleaseItems setting releaseFilter directly).
         */
        refresh() {
            _syncAllUI();
        },

        /**
         * Convenience: filter an items array using a caller-supplied match function.
         * The match function receives (item, state) and should return boolean.
         *
         * If no matchFn supplied, returns items unfiltered (caller must supply their own logic).
         *
         * @param {Array}    items
         * @param {Function} matchFn  (item, state) => boolean
         * @returns {Array}
         */
        filterItems(items, matchFn) {
            if (typeof matchFn !== 'function') return items.slice();
            return items.filter(item => matchFn(item, state));
        },

        /**
         * Async — re-fetch release options and repopulate the release <select>.
         * No-op when releaseOptionsEndpoint was not supplied.
         */
        populateReleaseOptions() {
            return _populateReleaseOptions();
        },

        /**
         * Async — re-fetch epic options and repopulate the epic <select>.
         * No-op when epicOptionsEndpoint was not supplied.
         */
        populateEpicOptions() {
            return _populateEpicOptions();
        },

        /**
         * Sync the release dropdown active/inactive CSS class from current DOM value.
         */
        updateReleaseStyle() {
            _syncReleaseStyle();
        },

        /**
         * Persist current state to localStorage.
         */
        save() {
            _saveState();
        },
    };
}
