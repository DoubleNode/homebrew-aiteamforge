//
//  lcars-estimates.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 DoubleNode.com. All rights reserved.
//

/**
 * lcars-estimates.js
 * LCARS HOME Carousel — Estimation Accuracy Panel (XACA-0630)
 *
 * Fetches GET /api/estimates and renders:
 *   - Global weighted handicap + median (headline metrics)
 *   - Excluded item tally
 *   - Four size-bucket rows: label, n, handicap, median, est hrs, actual hrs
 *
 * Interpretation: handicap > 1 = we tend to underestimate; < 1 = we overestimate.
 *
 * Empty-state (eligible == 0 or global.handicap == null):
 *   Renders a polished "Not enough tracked data yet" message.
 *   NEVER shows null, NaN, or 0.00 as a handicap value.
 *
 * No client-side computation — consumes pre-computed payload verbatim.
 * Values in the payload are already rounded to 2dp; display them as-is.
 *
 * Depends on: lcars.js (currentHomePanel, escapeHtml), no Chart.js required.
 * Must load after lcars.js.
 *
 * Physical carousel panel index: 6
 * data-home-mode: kanban
 */

/* global currentHomePanel, escapeHtml */

(function () {
    'use strict';

    // ── Module-level async fetch state ────────────────────────────────────────
    // Mirrors the knowledge-stats panel pattern: debounce + AbortController so
    // rapid carousel navigation cannot inject stale content into the DOM.

    /** @type {AbortController|null} */
    let _estimatesAbortController = null;

    /** @type {number|null} */
    let _estimatesDebounceTimer = null;

    const ESTIMATES_DEBOUNCE_MS = 150;

    // Physical panel index assigned to this panel in the carousel HTML.
    const PANEL_INDEX = 6;

    // ── Public API ─────────────────────────────────────────────────────────────

    /**
     * Render the Estimation Accuracy panel.
     * Called by renderHomePanel(6) in lcars.js.
     * Safe to call repeatedly — debounce + abort guard prevents stale injection.
     */
    async function renderEstimatesPanel() {
        // ── Debounce: cancel any pending (pre-fetch) timer ────────────────────
        if (_estimatesDebounceTimer !== null) {
            clearTimeout(_estimatesDebounceTimer);
            _estimatesDebounceTimer = null;
        }

        // ── Abort any in-flight fetch from a prior call ───────────────────────
        if (_estimatesAbortController !== null) {
            _estimatesAbortController.abort();
            _estimatesAbortController = null;
        }

        const container = document.getElementById('home-estimates-content');
        if (!container) return;

        // Show loading state
        container.innerHTML = _loadingHtml();

        // ── Debounce: wait before firing the real fetch ───────────────────────
        await new Promise(resolve => {
            _estimatesDebounceTimer = setTimeout(resolve, ESTIMATES_DEBOUNCE_MS);
        });
        _estimatesDebounceTimer = null;

        // Navigation guard: bail if user left this panel during debounce
        if (currentHomePanel !== PANEL_INDEX) {
            container.innerHTML = '';
            return;
        }

        // ── Create a fresh AbortController for this fetch ─────────────────────
        const controller = new AbortController();
        _estimatesAbortController = controller;

        let data;
        try {
            const response = await fetch('/api/estimates', { signal: controller.signal });
            if (!response.ok) throw new Error('HTTP ' + response.status);
            data = await response.json();
        } catch (err) {
            if (err.name === 'AbortError') return; // intentional navigation cancel
            console.warn('[LCARS] Failed to fetch /api/estimates:', err);
            if (currentHomePanel === PANEL_INDEX) {
                container.innerHTML = _errorHtml();
            }
            return;
        } finally {
            if (_estimatesAbortController === controller) {
                _estimatesAbortController = null;
            }
        }

        // Navigation guard: bail if user navigated away while fetch was in-flight
        if (currentHomePanel !== PANEL_INDEX) return;

        container.innerHTML = _renderPayload(data);
    }

    /**
     * Cancel any in-flight fetch or pending debounce.
     * Called by lcars.js when the user navigates away from panel 6.
     */
    function cancelEstimatesFetch() {
        if (_estimatesDebounceTimer !== null) {
            clearTimeout(_estimatesDebounceTimer);
            _estimatesDebounceTimer = null;
        }
        if (_estimatesAbortController !== null) {
            _estimatesAbortController.abort();
            _estimatesAbortController = null;
        }
    }

    // ── Rendering helpers ─────────────────────────────────────────────────────

    /** Returns the full panel HTML given a validated /api/estimates payload. */
    function _renderPayload(data) {
        const eligible = (data && typeof data.eligible === 'number') ? data.eligible : 0;
        const global   = (data && data.global) ? data.global : {};
        const excluded = (data && data.excluded) ? data.excluded : {};
        const buckets  = (data && Array.isArray(data.buckets)) ? data.buckets : [];

        // Empty-state guard: no eligible items or handicap is null
        if (eligible === 0 || global.handicap === null || global.handicap === undefined) {
            return _emptyStateHtml(excluded);
        }

        return _populatedHtml(eligible, global, excluded, buckets);
    }

    /**
     * Populated state: headline metrics + bucket table.
     * All values are pre-rounded in the payload; display them verbatim (no re-rounding).
     */
    function _populatedHtml(eligible, global, excluded, buckets) {
        const handicap = global.handicap;
        const median   = global.median;

        // Handicap color: orange when > 1 (underestimate), cyan when <= 1 (overestimate)
        const handicapColor = handicap > 1 ? '#FF9900' : '#99CCFF';
        const handicapLabel = handicap > 1
            ? 'UNDERESTIMATING'
            : (handicap < 1 ? 'OVERESTIMATING' : 'ON TARGET');

        const medianColor = (median !== null && median > 1) ? '#FF9900' : '#99CCFF';

        // Global summary bar
        const summaryHtml = `
            <div class="est-headline-grid">
                <div class="est-metric-card" style="border-left-color: ${handicapColor};">
                    <div class="est-metric-value" style="color: ${handicapColor};">${_fmt(handicap)}</div>
                    <div class="est-metric-label">WEIGHTED HANDICAP</div>
                    <div class="est-metric-sub" style="color: ${handicapColor};">${escapeHtml(handicapLabel)}</div>
                </div>
                <div class="est-metric-card" style="border-left-color: ${medianColor};">
                    <div class="est-metric-value" style="color: ${medianColor};">${_fmtNull(median)}</div>
                    <div class="est-metric-label">MEDIAN RATIO</div>
                    <div class="est-metric-sub" style="color: rgba(255,204,153,0.5);">OUTLIER-RESISTANT</div>
                </div>
                <div class="est-metric-card" style="border-left-color: #99CC99;">
                    <div class="est-metric-value" style="color: #99CC99;">${eligible}</div>
                    <div class="est-metric-label">ELIGIBLE ITEMS</div>
                    <div class="est-metric-sub" style="color: rgba(255,204,153,0.5);">${_excludedSub(excluded)}</div>
                </div>
            </div>`;

        // Bucket table
        const bucketRows = buckets.map(b => _bucketRowHtml(b)).join('');

        const tableHtml = `
            <div class="est-table-wrap">
                <table class="est-bucket-table">
                    <thead>
                        <tr>
                            <th>SIZE</th>
                            <th>N</th>
                            <th>HANDICAP</th>
                            <th>MEDIAN</th>
                            <th>EST HRS</th>
                            <th>ACT HRS</th>
                        </tr>
                    </thead>
                    <tbody>
                        ${bucketRows}
                    </tbody>
                </table>
            </div>`;

        return summaryHtml + tableHtml;
    }

    /** Renders a single bucket row. null handicap/median = em dash. */
    function _bucketRowHtml(b) {
        const label    = b.label || '—';
        const n        = typeof b.n === 'number' ? b.n : 0;
        const handicap = _fmtNull(b.handicap);
        const median   = _fmtNull(b.median);
        const estHrs   = typeof b.sumEstimatedHours === 'number' ? b.sumEstimatedHours.toFixed(2) : '0.00';
        const actHrs   = typeof b.sumActualHours    === 'number' ? b.sumActualHours.toFixed(2)    : '0.00';
        const dimmed   = n === 0 ? ' est-row-dim' : '';

        // Color handicap cell: orange > 1, cyan < 1, muted when null/n=0
        let hColor = 'rgba(255,204,153,0.35)';
        if (n > 0 && b.handicap !== null && b.handicap !== undefined) {
            hColor = b.handicap > 1 ? '#FF9900' : '#99CCFF';
        }

        return `<tr class="est-bucket-row${dimmed}">
            <td class="est-cell-label">${escapeHtml(label)}</td>
            <td class="est-cell-num">${n}</td>
            <td class="est-cell-num" style="color: ${hColor};">${handicap}</td>
            <td class="est-cell-num">${median}</td>
            <td class="est-cell-num">${estHrs}</td>
            <td class="est-cell-num">${actHrs}</td>
        </tr>`;
    }

    /** Empty state: explain what's needed, show excluded tally if informative. */
    function _emptyStateHtml(excluded) {
        const total = (excluded && typeof excluded.total === 'number') ? excluded.total : 0;
        const noEst = (excluded && typeof excluded.no_estimate === 'number') ? excluded.no_estimate : 0;
        const noTime = (excluded && typeof excluded.no_time === 'number') ? excluded.no_time : 0;
        const bothMissing = (excluded && typeof excluded.both_missing === 'number') ? excluded.both_missing : 0;

        let exclusionHint = '';
        if (total > 0) {
            const parts = [];
            if (noEst > 0)        parts.push(noEst + ' missing estimate');
            if (noTime > 0)       parts.push(noTime + ' missing tracked time');
            if (bothMissing > 0)  parts.push(bothMissing + ' missing both');
            if (parts.length > 0) {
                exclusionHint = `<div class="est-empty-hint">Completed items scanned: ${parts.join(', ')}</div>`;
            }
        }

        return `
            <div class="est-empty-state">
                <div class="est-empty-icon">&#9670;</div>
                <div class="est-empty-title">NOT ENOUGH TRACKED DATA YET</div>
                <div class="est-empty-body">
                    Estimation accuracy requires completed items with both an effort estimate (points)
                    and recorded time (tracked hours). Items are eligible once both are present.
                </div>
                ${exclusionHint}
                <div class="est-empty-tip">
                    Use <span class="est-code">kb-backlog points &lt;id&gt; &lt;hours&gt;</span> to add estimates,
                    and ensure time tracking is active during work sessions.
                </div>
            </div>`;
    }

    function _loadingHtml() {
        return `<div class="est-loading">LOADING ESTIMATES...</div>`;
    }

    function _errorHtml() {
        return `<div class="est-error">ESTIMATION DATA UNAVAILABLE</div>`;
    }

    // ── Format helpers ────────────────────────────────────────────────────────

    /** Format a number to 2dp string. Assumes value is already rounded. */
    function _fmt(v) {
        if (v === null || v === undefined || isNaN(v)) return '—';
        return Number(v).toFixed(2);
    }

    /** Format a nullable number: null/undefined/NaN → em dash. */
    function _fmtNull(v) {
        if (v === null || v === undefined || isNaN(v)) return '—';
        return Number(v).toFixed(2);
    }

    /** Build a compact excluded-items sub-label. */
    function _excludedSub(excluded) {
        if (!excluded || typeof excluded.total !== 'number' || excluded.total === 0) {
            return 'NO EXCLUSIONS';
        }
        return excluded.total + ' EXCLUDED';
    }

    // ── Expose on window for lcars.js to call ─────────────────────────────────
    window.LCARSEstimates = {
        renderPanel: renderEstimatesPanel,
        cancelFetch: cancelEstimatesFetch
    };

})();
