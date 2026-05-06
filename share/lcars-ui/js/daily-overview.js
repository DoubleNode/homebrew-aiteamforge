//
//  daily-overview.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//  (Year order is intentional: current year first per COPYRIGHT_POLICY.md § 4.8 range convention.)
//

/**
 * daily-overview.js — Daily Overview section renderer + interactions
 *
 * XACA-0334-005: Fetches /api/daily-overview?team=<team> and renders the
 * no-scroll 7-category grid into #daily-overview-grid.
 *
 * XACA-0334-006: Wires interactions — dismiss, complete, deep-link, and the
 * manual refresh button in the section header.
 *
 * Design spec: kanban/plans/XACA-0334/SPEC.md § 2, § 4, § 5
 * Target viewport: 1280×720 minimum, no vertical scrollbar.
 *
 * Public API (globals called by lcars.js):
 *   loadDailyOverview()           — fetch + full render; called on section entrance.
 *   initDailyOverviewInteractions() — wire delegation + refresh button; called once at boot.
 *
 * Dependencies (defined in lcars.js, which loads before this file):
 *   apiUrl(), escapeHtml(), CONFIG, showToast(), switchSection()
 *
 * NOTE: No polling. Manual refresh only. See spec § 2.3 and user decision
 *       recorded in SPEC.md decision override #1.
 */

/* global apiUrl, escapeHtml, CONFIG, showToast, switchSection */

'use strict';

// ─── Module state ──────────────────────────────────────────────────────────────

/** Most-recently rendered response; used for optimistic row removal. */
let _lastOverviewData = null;

/** True while a fetch is in flight — prevent double-loads on rapid nav. */
let _loading = false;

/** Whether the single delegation listener has been attached to the grid. */
let _delegationWired = false;

// ─── Category canonical order (matches spec § 2.4) ─────────────────────────────

const CATEGORY_ORDER = [
    'kanban_todos',
    'kanban_items_due',
    'change_requests',
    'backup_failures',
    'calendar_items',
    'releases',
    'alert',
];

// ─── Severity → CSS class mapping ─────────────────────────────────────────────

const SEV_CLASS = {
    critical: 'do-sev-critical',
    high:     'do-sev-high',
    warn:     'do-sev-warn',
    medium:   'do-sev-medium',
    info:     'do-sev-info',
    low:      'do-sev-low',
};

// ─── Public entry point ────────────────────────────────────────────────────────

/**
 * Fetch the daily overview and render it. Safe to call multiple times;
 * concurrent calls are debounced (second call is a no-op while loading).
 */
function loadDailyOverview() {
    _fetchAndRender(null);
}

// ─── Interaction bootstrap ─────────────────────────────────────────────────────

/**
 * Wire the single delegated event listener on #daily-overview-grid and the
 * refresh button in the section header.
 *
 * Call ONCE at boot (or once after the DOM is ready).  Safe to call multiple
 * times — the guard flag prevents duplicate listeners.
 *
 * XACA-0334-006
 */
function initDailyOverviewInteractions() {
    _wireDelegation();
    _wireRefreshButton();
}

/**
 * Attach a single delegated click listener to #daily-overview-grid.
 * Switches on data-action to route dismiss / complete / deep-link.
 * Using event delegation avoids listener leaks when the grid is re-rendered.
 */
function _wireDelegation() {
    if (_delegationWired) return;

    const grid = document.getElementById('daily-overview-grid');
    if (!grid) {
        // Grid not in DOM yet (section not mounted).  Try again at next boot;
        // initDailyOverviewInteractions() should be called after DOM ready.
        console.warn('[daily-overview] #daily-overview-grid not found — delegation not wired');
        return;
    }

    grid.addEventListener('click', function (e) {
        // Walk up from the target to find a button with data-action.
        const btn = e.target.closest('button[data-action]');
        if (!btn) return;

        // Find the parent card for item metadata.
        const card = btn.closest('.do-card');
        if (!card) return;

        const action     = btn.dataset.action;
        const itemId     = card.dataset.id;
        const sourceView = card.dataset.sourceView;
        const deepLinkId = card.dataset.deepLinkId;

        switch (action) {
            case 'dismiss':
                _handleDismiss(btn, card, itemId);
                break;
            case 'complete':
                _handleComplete(btn, card, itemId);
                break;
            case 'deep-link':
                _handleDeepLink(sourceView, deepLinkId);
                break;
            default:
                console.warn('[daily-overview] unknown data-action:', action);
        }
    });

    // Keyboard: Enter/Space on focusable buttons is handled natively by <button>,
    // so no extra keydown handler is needed — the click event fires on activation.

    _delegationWired = true;
}

/**
 * Wire the [REFRESH] button inside .daily-overview-section .section-header.
 * Shows a REFRESHING… label while in flight; restores original label on complete.
 */
function _wireRefreshButton() {
    const btn = document.getElementById('do-refresh-btn');
    if (!btn) {
        console.warn('[daily-overview] #do-refresh-btn not found — refresh button not wired');
        return;
    }

    btn.addEventListener('click', function () {
        if (_loading) return;   // Already fetching; ignore rapid double-clicks.

        // Visual feedback: disable button + show spinner text.
        btn.disabled = true;
        const originalText = btn.textContent;
        btn.textContent = 'REFRESHING…';

        // _fetchAndRender sets _loading = true and calls _renderLoading on
        // the grid, which gives additional in-grid feedback.  We piggyback on
        // the callback param to restore the button after the fetch completes.
        _fetchAndRender(function () {
            btn.disabled = false;
            btn.textContent = originalText;
        });
    });
}

// ─── Action handlers ───────────────────────────────────────────────────────────

/**
 * Dismiss an alert item.
 *
 * Only fires when the button does NOT carry the `not-dismissable` class
 * (i.e., item.dismissable === true from the server).
 *
 * Flow:
 *   1. POST /api/alerts/<id>/dismiss   body: { team }
 *   2. On 200: optimistically remove the card row from the DOM.
 *   3. Re-fetch full overview to pick up auto-promoted overflow items.
 *   4. On error: keep the row; show a non-blocking error toast.
 */
function _handleDismiss(btn, card, itemId) {
    if (btn.classList.contains('not-dismissable')) return;
    if (btn.disabled) return;

    const team = (CONFIG && CONFIG.team) || '';
    if (!team) {
        showToast('Cannot dismiss — team not configured', 'error', 4000);
        return;
    }

    // Disable the button to prevent double-firing.
    btn.disabled = true;

    const url = apiUrl('/api/alerts/' + encodeURIComponent(itemId) + '/dismiss');

    fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ team: team }),
    })
        .then(function (res) {
            if (!res.ok) {
                return res.json().catch(function () {
                    return { error: 'HTTP ' + res.status };
                }).then(function (body) {
                    throw new Error(body.error || 'HTTP ' + res.status);
                });
            }
            return res.json();
        })
        .then(function () {
            // Optimistic: remove the card from the DOM immediately.
            _removeCardFromGrid(card);
            // Re-fetch to promote overflow items into the vacated slot.
            loadDailyOverview();
        })
        .catch(function (err) {
            console.error('[daily-overview] dismiss failed:', err);
            btn.disabled = false;
            showToast('Dismiss failed: ' + (err.message || 'unknown error'), 'error', 5000);
        });
}

/**
 * Complete a TODO item.
 *
 * Only fires when the button does NOT carry the `not-completable` class
 * (i.e., item.completable === true from the server).
 *
 * Flow:
 *   1. PUT /api/todos  body: { team, id, updates: { status: 'completed' } }
 *   2. On 200: optimistically remove the card row from the DOM.
 *   3. Re-fetch full overview to pick up auto-promoted overflow items.
 *   4. On error: keep the row; show a non-blocking error toast.
 */
function _handleComplete(btn, card, itemId) {
    if (btn.classList.contains('not-completable')) return;
    if (btn.disabled) return;

    const team = (CONFIG && CONFIG.team) || '';
    if (!team) {
        showToast('Cannot complete — team not configured', 'error', 4000);
        return;
    }

    // Disable the button to prevent double-firing.
    btn.disabled = true;

    const url = apiUrl('/api/todos');

    fetch(url, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ team: team, id: itemId, updates: { status: 'completed' } }),
    })
        .then(function (res) {
            if (!res.ok) {
                return res.json().catch(function () {
                    return { error: 'HTTP ' + res.status };
                }).then(function (body) {
                    throw new Error(body.error || 'HTTP ' + res.status);
                });
            }
            return res.json();
        })
        .then(function () {
            // Optimistic: remove the card from the DOM immediately.
            _removeCardFromGrid(card);
            // Re-fetch to promote overflow items into the vacated slot.
            loadDailyOverview();
        })
        .catch(function (err) {
            console.error('[daily-overview] complete failed:', err);
            btn.disabled = false;
            showToast('Complete failed: ' + (err.message || 'unknown error'), 'error', 5000);
        });
}

/**
 * Navigate to the source section for a deep-link.
 *
 * Uses the existing switchSection() from lcars.js — no extra setTimeout per
 * the spec § 5.4 / switchSection race note.  We do NOT invent scroll-to
 * behaviour; if switchSection supports a deep-link target it can be wired later.
 */
function _handleDeepLink(sourceView, deepLinkId) {
    if (!sourceView) {
        console.warn('[daily-overview] deep-link clicked but source_view is empty');
        return;
    }

    // Delegate entirely to lcars.js routing.
    // deepLinkId is passed as a data attribute; if the target section later gains
    // a scroll-to API, wire it here.  For now, switchSection is sufficient.
    switchSection(sourceView);

    // Log for debuggability — the subitem 007 manual test plan can verify this.
    if (deepLinkId) {
        console.debug('[daily-overview] deep-link to', sourceView, 'item:', deepLinkId);
    }
}

// ─── DOM helpers ───────────────────────────────────────────────────────────────

/**
 * Optimistically remove a card from the grid DOM.
 * Leaves the cell visible (empty-state placeholder appears naturally on
 * re-fetch via _renderCell when items array becomes empty).
 */
function _removeCardFromGrid(card) {
    if (card && card.parentNode) {
        card.parentNode.removeChild(card);
    }
}

/**
 * Shared fetch-and-render core.  Both loadDailyOverview() and the refresh
 * button route through here.
 *
 * @param {Function|null} cb  Optional callback fired on completion (success or
 *   failure), regardless of outcome.  Used by the refresh button to restore
 *   its label.  Pass null when no post-fetch action is needed.
 *
 * Implementation note: _loading guard still applies.  If _loading is already
 * true when called (e.g. refresh button clicked while a fetch is in flight —
 * shouldn't happen because the button is disabled, but be defensive), cb fires
 * immediately and we return without starting a second fetch.
 */
function _fetchAndRender(cb) {
    if (_loading) {
        if (cb) cb();
        return;
    }
    _loading = true;

    const grid = document.getElementById('daily-overview-grid');
    if (!grid) {
        _loading = false;
        if (cb) cb();
        return;
    }

    _renderLoading(grid);

    const url = apiUrl('/api/daily-overview');

    fetch(url)
        .then(function (res) {
            if (!res.ok) {
                return res.json().catch(function () {
                    return { error: 'HTTP ' + res.status };
                }).then(function (body) {
                    throw new Error(body.error || 'HTTP ' + res.status);
                });
            }
            return res.json();
        })
        .then(function (data) {
            _lastOverviewData = data;
            _renderOverview(grid, data);
        })
        .catch(function (err) {
            console.error('[daily-overview] fetch failed:', err);
            _renderError(grid, err.message || 'Failed to load daily overview');
        })
        .finally(function () {
            _loading = false;
            if (cb) cb();
        });
}

// ─── Rendering helpers ─────────────────────────────────────────────────────────

/**
 * Render a loading skeleton while the fetch is in-flight.
 */
function _renderLoading(grid) {
    grid.innerHTML =
        '<div class="do-grid-loading">LOADING DAILY OVERVIEW…</div>';
}

/**
 * Render an error state.
 */
function _renderError(grid, message) {
    grid.innerHTML =
        '<div class="do-grid-error">' +
            'UNABLE TO LOAD DAILY OVERVIEW<br>' +
            '<span style="font-size:11px;opacity:0.7;">' +
                escapeHtml(String(message)) +
            '</span>' +
        '</div>';
}

/**
 * Render the full 7-category grid from the aggregator response.
 *
 * @param {HTMLElement} grid   #daily-overview-grid container
 * @param {Object}      data   Response from GET /api/daily-overview
 */
function _renderOverview(grid, data) {
    const categories = Array.isArray(data.categories) ? data.categories : [];

    // Build a lookup from key → category object for guaranteed ordering.
    const byKey = {};
    categories.forEach(function (cat) {
        byKey[cat.key] = cat;
    });

    // Render cells in canonical order regardless of server order.
    const cellsHtml = CATEGORY_ORDER.map(function (key) {
        const cat = byKey[key];
        if (cat) {
            return _renderCell(cat);
        }
        // Category missing from response — render empty placeholder so layout
        // is stable (spec § 4.3: cells never collapse).
        return _renderEmptyCell(key);
    }).join('');

    grid.innerHTML = cellsHtml;
}

/**
 * Render a populated category cell.
 */
function _renderCell(cat) {
    const label       = escapeHtml(cat.label   || cat.key.toUpperCase());
    const total       = typeof cat.total    === 'number' ? cat.total    : 0;
    const overflow    = typeof cat.overflow === 'number' ? cat.overflow : 0;
    const items       = Array.isArray(cat.items) ? cat.items : [];
    const hasOverflow = overflow > 0;

    const overflowChip = hasOverflow
        ? '<span class="do-overflow-chip">+' + overflow + ' MORE</span>'
        : '<span class="do-overflow-chip hidden" aria-hidden="true"></span>';

    const bodyHtml = items.length === 0
        ? '<div class="do-cell-empty">NO ITEMS</div>'
        : items.map(function (item) { return _renderCard(item); }).join('');

    return (
        '<div class="do-cell" data-category="' + escapeHtml(cat.key) + '">' +
            '<div class="do-cell-header">' +
                '<span class="do-cell-label">' + label + '</span>' +
                '<span class="do-cell-count">' + total + '</span>' +
                overflowChip +
            '</div>' +
            '<div class="do-cell-body">' + bodyHtml + '</div>' +
        '</div>'
    );
}

/**
 * Render an empty placeholder cell when the aggregator omitted a category.
 * Keeps layout stable across refreshes — spec § 4.3.
 */
function _renderEmptyCell(key) {
    const label = escapeHtml(key.replace(/_/g, ' ').toUpperCase());
    return (
        '<div class="do-cell" data-category="' + escapeHtml(key) + '">' +
            '<div class="do-cell-header">' +
                '<span class="do-cell-label">' + label + '</span>' +
                '<span class="do-cell-count">0</span>' +
                '<span class="do-overflow-chip hidden" aria-hidden="true"></span>' +
            '</div>' +
            '<div class="do-cell-body">' +
                '<div class="do-cell-empty">NO ITEMS</div>' +
            '</div>' +
        '</div>'
    );
}

/**
 * Render one card row inside a category cell.
 *
 * Spec § 4.4:
 *   [severity bar] [severity dot] [title…] [due] [action icons]
 *   32px fixed height, single line, text-overflow ellipsis.
 *   Action icons are PLACEHOLDERS — interactions wired in subitem 006.
 */
function _renderCard(item) {
    const sev   = (item.severity_or_priority || 'low').toLowerCase();
    const sevClass = SEV_CLASS[sev] || 'do-sev-low';

    const title   = escapeHtml(String(item.title || ''));
    const dueText = escapeHtml(_formatDue(item.due_at));

    // Action icons — present but cursor:default until subitem 006 wires them.
    // data-id and data-source-view are load-bearing attributes for subitem 006.
    const dismissable   = item.dismissable   === true;
    const completable   = item.completable   === true;
    const itemId        = escapeHtml(String(item.id || ''));
    const sourceView    = escapeHtml(String(item.source_view  || ''));
    const deepLinkId    = escapeHtml(String(item.deep_link_id || item.id || ''));

    const dismissClass  = dismissable  ? 'do-action-btn dismiss-btn'  : 'do-action-btn dismiss-btn not-dismissable';
    const completeClass = completable  ? 'do-action-btn complete-btn' : 'do-action-btn complete-btn not-completable';

    return (
        '<div class="do-card ' + sevClass + '"' +
                ' data-id="' + itemId + '"' +
                ' data-source-view="' + sourceView + '"' +
                ' data-deep-link-id="' + deepLinkId + '">' +
            '<div class="do-card-severity-bar"></div>' +
            '<div class="do-card-severity-dot"></div>' +
            '<span class="do-card-title" title="' + title + '">' + title + '</span>' +
            (dueText ? '<span class="do-card-due">' + dueText + '</span>' : '') +
            '<div class="do-card-actions">' +
                '<button class="' + dismissClass + '" data-action="dismiss"' +
                        ' aria-label="Dismiss" title="Dismiss">✕</button>' +
                '<button class="' + completeClass + '" data-action="complete"' +
                        ' aria-label="Complete" title="Complete">✓</button>' +
                '<button class="do-action-btn deep-link-btn" data-action="deep-link"' +
                        ' aria-label="Open" title="Open">→</button>' +
            '</div>' +
        '</div>'
    );
}

// ─── Date formatting ───────────────────────────────────────────────────────────

/**
 * Format a due_at ISO timestamp as a compact relative string.
 *
 * Examples:
 *   past:    "5h ago", "2d ago", "just now"
 *   future:  "in 2h", "tomorrow", "in 3d"
 *   null/missing: ""
 *
 * Note: formatRelativeTime() in lcars.js only covers past times.
 * This function handles both past and future so due dates display correctly.
 */
function _formatDue(isoString) {
    if (!isoString) return '';

    const now  = Date.now();
    const then = new Date(isoString).getTime();
    if (isNaN(then)) return '';

    const diff    = now - then;       // positive = past, negative = future
    const absDiff = Math.abs(diff);

    const seconds = Math.floor(absDiff / 1000);
    const minutes = Math.floor(seconds / 60);
    const hours   = Math.floor(minutes / 60);
    const days    = Math.floor(hours   / 24);

    if (absDiff < 60000) return 'just now';

    if (diff > 0) {
        // Past
        if (minutes < 60)  return minutes + 'm ago';
        if (hours   < 24)  return hours   + 'h ago';
        return days + 'd ago';
    } else {
        // Future
        if (minutes < 60)  return 'in ' + minutes + 'm';
        if (hours   < 24)  {
            if (hours <= 23 && days === 0) return 'in ' + hours + 'h';
        }
        if (days === 1)    return 'tomorrow';
        return 'in ' + days + 'd';
    }
}
