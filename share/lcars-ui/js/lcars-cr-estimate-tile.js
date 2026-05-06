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
 *   init()            — idempotent; subscribes to DOM events and starts the
 *                       board-update poll guard.
 *   render(crs)       — renders the tile given an array of CR container records.
 *   renderFromBoard() — convenience; reads window.boardData.crs and delegates.
 *
 * Event subscriptions (mirrors lcars-cr-segment-tiles.js exactly):
 *   cr-subtab-changed  — re-renders when subtab === 'cycle-time'
 *   crsupport-changed  — re-renders when enabled === true
 *   5 s poll guard     — JSON hash of boardData.crs detects mutations
 *                        (lcars.js does not dispatch a board-updated event)
 *
 * Dependencies:
 *   window.lcarsCrMetrics  (lcars-cr-metrics.js — must load first)
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

    /** Poll interval for board-update detection when no event is available. */
    var POLL_INTERVAL_MS = 5000;

    /** DOM id of this tile's mount element. */
    var MOUNT_ID = 'cr-cycle-tile-estimate-delta';

    // ─── Module state ─────────────────────────────────────────────────────────

    var _initialized = false;
    var _pollTimer   = null;
    var _lastCrsHash = null;

    // ─── Internal helpers ─────────────────────────────────────────────────────

    /**
     * Cheap hash of the CRs array to detect board changes without deep-equal.
     * JSON.stringify is acceptable for dashboard polling (small array, 5 s cadence).
     *
     * @param {Array} crs
     * @returns {string}
     */
    function _hashCrs(crs) {
        try {
            return JSON.stringify(crs);
        } catch (_) {
            return String(Date.now());
        }
    }

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
     * Start polling for board changes (5 s interval).
     * Uses a JSON hash of boardData.crs to detect mutations without a
     * dedicated board-updated event (lcars.js does not dispatch one).
     * Pattern mirrors lcars-cr-segment-tiles.js exactly.
     */
    function _startPoll() {
        if (_pollTimer !== null) { return; }
        _pollTimer = setInterval(function () {
            if (_crDisabled()) { return; }
            try {
                var crs = (window.boardData && Array.isArray(window.boardData.crs))
                    ? window.boardData.crs
                    : [];
                var hash = _hashCrs(crs);
                if (hash !== _lastCrsHash) {
                    _lastCrsHash = hash;
                    render(crs);
                }
            } catch (_) {}
        }, POLL_INTERVAL_MS);
    }

    /**
     * Subscribe to DOM events and perform an initial render if the CYCLE TIME
     * subtab is already active.  Idempotent — safe to call multiple times.
     *
     * Event subscriptions (identical contract to lcars-cr-segment-tiles.js):
     *   cr-subtab-changed  — re-renders when subtab === 'cycle-time'
     *   crsupport-changed  — re-renders when enabled === true
     *   5 s poll guard     — JSON hash detects board mutations
     */
    function init() {
        if (_initialized) { return; }
        _initialized = true;

        // Event 1: subtab activation
        document.addEventListener('cr-subtab-changed', function (e) {
            if (e && e.detail && e.detail.subtab === 'cycle-time') {
                renderFromBoard();
            }
        });

        // Event 2: crsupport-changed (flag toggled on → re-render)
        document.addEventListener('crsupport-changed', function (e) {
            if (e && e.detail && e.detail.enabled === true) {
                renderFromBoard();
            }
        });

        // Fallback board-update detection: poll every 5 s
        _startPoll();

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
