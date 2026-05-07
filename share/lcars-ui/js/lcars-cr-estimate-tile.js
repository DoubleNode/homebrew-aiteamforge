//
//  lcars-cr-estimate-tile.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * lcars-cr-estimate-tile.js — CR Estimate-vs-Actual Tile
 *
 * XACA-0293-005: Renders the 8th tile in the CYCLE TIME pane (View 2) of the
 * CHANGE REQ section.  Shows avg deploy_estimate_delta_days over the rolling
 * 14-day window, plus a HIT / EARLY / LATE breakdown with counts and percentages.
 * The primary value is color-coded by aggregate health.
 *
 * Health thresholds (tunable in Phase 7, XACA-0297 — these are a first cut):
 *   good = |avg| <= 1 day
 *   warn = |avg| > 1 and <= 3 days
 *   bad  = |avg| > 3 days
 *
 * Public API (window.lcarsCrEstimateTile):
 *   init()            — idempotent; subscribes to DOM events and registers with
 *                       the shared lcarsCrPollBus for board-change callbacks.
 *   render(crs)       — renders the tile given an array of CR container records.
 *   renderFromBoard() — convenience; reads window.boardData.crs and delegates.
 *
 * Event subscriptions:
 *   cr-subtab-changed  — re-renders when subtab === 'cycle-time'
 *   lcarsCrPollBus     — fires the 'estimate-tile' subscriber on crs hash-change
 *                        and on crsupport-changed (bus handles both)
 *
 * Dependencies:
 *   window.lcarsCrMetrics  (lcars-cr-metrics.js — must load first)
 *   window.lcarsCrPollBus  (lcars-cr-poll-bus.js — must load before this file)
 *   window.boardData       (lcars.js)
 *
 * No DOM access outside #cr-cycle-tile-estimate-delta.
 * No network calls.  No side-effects on window.boardData.
 */

'use strict';

(function (root, factory) {
    if (typeof module !== 'undefined' && module.exports) {
        // Node.js — testable without a browser
        module.exports = factory();
    } else {
        root.lcarsCrEstimateTile = factory();
    }
}(typeof window !== 'undefined' ? window : global, function () {

    // ─── Constants ────────────────────────────────────────────────────────────

    /** Rolling window in days (matches the metrics module default). */
    var WINDOW_DAYS = 14;

    /**
     * Health thresholds in absolute days.
     * Tunable in Phase 7 (XACA-0297) — these are a first cut.
     */
    var HEALTH_WARN_THRESHOLD = 1;  // |avg| > this → warn
    var HEALTH_BAD_THRESHOLD  = 3;  // |avg| > this → bad

    /** DOM id of this tile's mount element. */
    var MOUNT_ID = 'cr-cycle-tile-estimate-delta';

    // ─── Module state ─────────────────────────────────────────────────────────

    var _initialized = false;

    /**
     * Determine the CSS health class for the primary avg delta value.
     *
     * @param {number|null} avg - Average delta in days
     * @returns {string} CSS class name
     */
    function _healthClass(avg) {
        if (avg === null || avg === undefined || isNaN(avg)) {
            return 'cr-estimate-health-good';
        }
        var abs = Math.abs(avg);
        if (abs > HEALTH_BAD_THRESHOLD) {
            return 'cr-estimate-health-bad';
        }
        if (abs > HEALTH_WARN_THRESHOLD) {
            return 'cr-estimate-health-warn';
        }
        return 'cr-estimate-health-good';
    }

    /**
     * Format the avg delta value with a leading sign.
     * Always one decimal place.  Returns '0.0' for null/NaN.
     *
     * @param {number|null} avg
     * @returns {string}
     */
    function _fmtDelta(avg) {
        if (avg === null || avg === undefined || isNaN(avg)) {
            return '0.0';
        }
        var fixed = Math.abs(avg).toFixed(1);
        return (avg >= 0 ? '+' : '-') + fixed;
    }

    /**
     * Build the inner HTML for the tile in normal (data) state.
     *
     * @param {object} rollup - Result from lcarsCrMetrics.rollupEstimateDelta()
     * @returns {string}
     */
    function _buildTileHtml(rollup) {
        var avg        = rollup.avg;
        var health     = _healthClass(avg);
        var deltaStr   = _fmtDelta(avg);
        var hitPct     = Math.round(rollup.hitPct   || 0);
        var earlyPct   = Math.round(rollup.earlyPct || 0);
        var latePct    = Math.round(rollup.latePct  || 0);
        var hits       = rollup.hits    || 0;
        var earlies    = rollup.earlies || 0;
        var lates      = rollup.lates   || 0;
        var count      = rollup.sampleCount || 0;

        return (
            '<div class="cr-tile-header">' +
                '<span class="cr-tile-label">ESTIMATE vs ACTUAL</span>' +
                '<span class="cr-tile-window">' + WINDOW_DAYS + 'D ROLLING</span>' +
            '</div>' +
            '<div class="cr-tile-body">' +
                '<div class="cr-tile-primary cr-estimate-primary">' +
                    '<span class="cr-tile-value cr-estimate-delta-value ' + health + '">' +
                        deltaStr +
                    '</span>' +
                    '<span class="cr-tile-unit">DAYS AVG DELTA</span>' +
                '</div>' +
                '<div class="cr-estimate-breakdown">' +
                    '<span class="cr-estimate-bucket cr-estimate-bucket-hit">' +
                        '<span class="cr-estimate-bucket-pct">' + hitPct + '%</span>' +
                        '<span class="cr-estimate-bucket-label">HIT</span>' +
                        '<span class="cr-estimate-bucket-count">' + hits + '</span>' +
                    '</span>' +
                    '<span class="cr-estimate-bucket cr-estimate-bucket-early">' +
                        '<span class="cr-estimate-bucket-pct">' + earlyPct + '%</span>' +
                        '<span class="cr-estimate-bucket-label">EARLY</span>' +
                        '<span class="cr-estimate-bucket-count">' + earlies + '</span>' +
                    '</span>' +
                    '<span class="cr-estimate-bucket cr-estimate-bucket-late">' +
                        '<span class="cr-estimate-bucket-pct">' + latePct + '%</span>' +
                        '<span class="cr-estimate-bucket-label">LATE</span>' +
                        '<span class="cr-estimate-bucket-count">' + lates + '</span>' +
                    '</span>' +
                '</div>' +
                '<div class="cr-estimate-sample-count">SAMPLES <strong>' + count + '</strong></div>' +
            '</div>'
        );
    }

    /**
     * Build the inner HTML for the tile in empty (no-sample) state.
     *
     * @returns {string}
     */
    function _buildEmptyTileHtml() {
        return (
            '<div class="cr-tile-header">' +
                '<span class="cr-tile-label">ESTIMATE vs ACTUAL</span>' +
                '<span class="cr-tile-window">' + WINDOW_DAYS + 'D ROLLING</span>' +
            '</div>' +
            '<div class="cr-tile-body cr-tile-empty">' +
                '<span class="cr-tile-empty-msg">NO SAMPLES</span>' +
            '</div>'
        );
    }

    // ─── Flag-off guard ───────────────────────────────────────────────────────

    /**
     * Returns true when CR support is disabled — renders should no-op.
     *
     * @returns {boolean}
     */
    function _crDisabled() {
        try {
            return window.boardData &&
                   window.boardData.teamConfig &&
                   window.boardData.teamConfig.crSupport &&
                   window.boardData.teamConfig.crSupport.enabled === false;
        } catch (_) {
            return false;
        }
    }

    // ─── Public API ───────────────────────────────────────────────────────────

    /**
     * Render the estimate-vs-actual tile given an array of CR container records.
     * No-ops when CR support is flagged off.
     *
     * @param {Array} crs - Array of CR container objects from boardData.crs
     */
    function render(crs) {
        if (_crDisabled()) { return; }
        // No point computing a rollup nobody will see — bail when pane is hidden.
        // lcars-cr-tab.js removes [hidden] BEFORE dispatching cr-subtab-changed,
        // so the event path always sees the pane as visible when it should render.
        try {
            var pane = document.getElementById('change-req-pane-cycle-time');
            if (pane && pane.hasAttribute('hidden')) { return; }
        } catch (_) {}

        var mount = (typeof document !== 'undefined')
            ? document.getElementById(MOUNT_ID)
            : null;
        if (!mount) { return; }

        var safeCrs = Array.isArray(crs) ? crs : [];

        if (typeof window === 'undefined' || !window.lcarsCrMetrics) {
            mount.innerHTML = _buildEmptyTileHtml();
            return;
        }

        var rollup = window.lcarsCrMetrics.rollupEstimateDelta(
            safeCrs,
            { windowDays: WINDOW_DAYS }
        );

        if (!rollup || rollup.sampleCount === 0) {
            mount.innerHTML = _buildEmptyTileHtml();
            return;
        }

        mount.innerHTML = _buildTileHtml(rollup);
    }

    /**
     * Convenience render that reads window.boardData.crs automatically.
     * No-ops gracefully when boardData is not yet available.
     */
    function renderFromBoard() {
        if (_crDisabled()) { return; }
        try {
            var crs = (window.boardData && Array.isArray(window.boardData.crs))
                ? window.boardData.crs
                : [];
            render(crs);
        } catch (err) {
            console.warn('[lcarsCrEstimateTile] renderFromBoard error:', err);
        }
    }

    /**
     * Subscribe to DOM events and perform an initial render if the CYCLE TIME
     * subtab is already active.  Idempotent — safe to call multiple times.
     *
     * Event subscriptions:
     *   cr-subtab-changed  — re-renders when subtab === 'cycle-time'
     *   lcarsCrPollBus     — board-data changes and crsupport-changed handled by bus
     */
    function init() {
        if (_initialized) { return; }
        _initialized = true;

        // Event: subtab activation (kept separate from the poll bus — this fires
        // on user tab-switch, not on board-data change).
        document.addEventListener('cr-subtab-changed', function (e) {
            if (e && e.detail && e.detail.subtab === 'cycle-time') {
                renderFromBoard();
            }
        });

        // Board-update detection delegated to the shared poll bus.
        // The bus also handles crsupport-changed; no duplicate listener needed here.
        if (window.lcarsCrPollBus) {
            window.lcarsCrPollBus.subscribe('estimate-tile', function (crs) {
                render(crs);
            });
        }

        // Initial render: lcars-cr-tab.js will dispatch cr-subtab-changed on
        // DOMContentLoaded when it restores the persisted subtab.  If it runs
        // before us (load-order is metrics → cr-tab → segment-tiles → this file),
        // the event fires before we subscribe.  Guard against that by checking
        // the active subtab button directly.
        try {
            var activeBtn = document.querySelector('.cr-subtab.active');
            if (activeBtn && activeBtn.dataset && activeBtn.dataset.subtab === 'cycle-time') {
                renderFromBoard();
            }
        } catch (_) {}
    }

    return {
        init:            init,
        render:          render,
        renderFromBoard: renderFromBoard,
    };

}));

// ─── Auto-init ────────────────────────────────────────────────────────────────

if (typeof window !== 'undefined') {
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', function () {
            window.lcarsCrEstimateTile.init();
        });
    } else {
        window.lcarsCrEstimateTile.init();
    }
}
