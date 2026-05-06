/**
 * lcars-cr-segment-tiles.js — CR Cycle-Time Segment Rollup Tiles
 *
 * XACA-0293-004: Renders 7 rolling-14-day cycle-time tiles in the CYCLE TIME
 * pane (View 2) of the CHANGE REQ section.  Each tile shows avg, median, and
 * sample count for one lifecycle segment computed by lcars-cr-metrics.js.
 *
 * Public API (window.lcarsCrSegmentTiles):
 *   init()           — idempotent; subscribes to DOM events and starts the
 *                      board-update poll guard.
 *   render(crs)      — renders all 7 segment tiles given a CR array.
 *   renderFromBoard() — convenience; reads window.boardData.crs and delegates.
 *
 * Dependencies:
 *   window.lcarsCrMetrics  (lcars-cr-metrics.js)
 *   window.boardData       (lcars.js)
 *
 * No DOM access outside the 7 tile mount divs.
 * No network calls.  No side-effects on window.boardData.
 */

'use strict';

(function (root, factory) {
    if (typeof module !== 'undefined' && module.exports) {
        // Node.js — testable without a browser
        module.exports = factory();
    } else {
        root.lcarsCrSegmentTiles = factory();
    }
}(typeof window !== 'undefined' ? window : global, function () {

    // ─── Constants ────────────────────────────────────────────────────────────

    /** Display labels for each of the 7 segment keys, in lifecycle order. */
    var SEGMENT_LABELS = {
        draft_to_submit:         'DRAFT → SUBMIT',
        submit_to_approve:       'SUBMIT → APPROVE',
        approve_to_dev:          'APPROVE → DEV',
        dev_to_test:             'DEV → TEST',
        test_to_deploydev:       'TEST → DEPLOY-DEV',
        deploydev_to_deployprod: 'DEPLOY-DEV → DEPLOY-PROD',
        total:                   'TOTAL CYCLE',
    };

    /**
     * Ordered list of segment keys — drives tile rendering order.
     * Must stay in sync with the mount IDs in index.html.
     */
    var SEGMENT_KEYS = Object.keys(SEGMENT_LABELS);

    /** Rolling window in days (matches the metrics module default). */
    var WINDOW_DAYS = 14;

    /** Poll interval for board-update detection when no event is available. */
    var POLL_INTERVAL_MS = 5000;

    // ─── Module state ─────────────────────────────────────────────────────────

    var _initialized    = false;
    var _pollTimer      = null;
    var _lastCrsHash    = null;

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
     * Return the DOM mount element for a segment key, or null if absent.
     *
     * @param {string} segmentKey
     * @returns {Element|null}
     */
    function _mountFor(segmentKey) {
        // Convert snake_case segment key to the stable tile ID.
        // Mapping mirrors the data-segment attributes in index.html.
        var idMap = {
            draft_to_submit:         'cr-cycle-tile-draft-to-submit',
            submit_to_approve:       'cr-cycle-tile-submit-to-approve',
            approve_to_dev:          'cr-cycle-tile-approve-to-dev',
            dev_to_test:             'cr-cycle-tile-dev-to-test',
            test_to_deploydev:       'cr-cycle-tile-test-to-deploydev',
            deploydev_to_deployprod: 'cr-cycle-tile-deploydev-to-deployprod',
            total:                   'cr-cycle-tile-total',
        };
        var id = idMap[segmentKey];
        return id ? document.getElementById(id) : null;
    }

    /**
     * Format a day value for display.
     * Always one decimal place (e.g. "2.0", "2.5").
     * Returns "—" (em-dash) for null / NaN.
     *
     * @param {number|null} val
     * @returns {string}
     */
    function _fmtDays(val) {
        if (val === null || val === undefined || isNaN(val)) {
            return '—';
        }
        return Number(val).toFixed(1);
    }

    /**
     * Build the inner HTML for a tile in normal (data) state.
     *
     * @param {string} label    — display label
     * @param {number} avg      — rolling avg in days (may be null)
     * @param {number} median   — rolling median in days (may be null)
     * @param {number} sampleCount
     * @returns {string}
     */
    function _buildTileHtml(label, avg, median, sampleCount) {
        return (
            '<div class="cr-tile-header">' +
                '<span class="cr-tile-label">' + label + '</span>' +
                '<span class="cr-tile-window">' + WINDOW_DAYS + 'D ROLLING</span>' +
            '</div>' +
            '<div class="cr-tile-body">' +
                '<div class="cr-tile-primary">' +
                    '<span class="cr-tile-value">' + _fmtDays(avg) + '</span>' +
                    '<span class="cr-tile-unit">DAYS AVG</span>' +
                '</div>' +
                '<div class="cr-tile-secondary">' +
                    '<span class="cr-tile-stat">MEDIAN <strong>' + _fmtDays(median) + 'd</strong></span>' +
                    '<span class="cr-tile-stat">SAMPLES <strong>' + sampleCount + '</strong></span>' +
                '</div>' +
            '</div>'
        );
    }

    /**
     * Build the inner HTML for a tile in empty (no-sample) state.
     *
     * @param {string} label
     * @returns {string}
     */
    function _buildEmptyTileHtml(label) {
        return (
            '<div class="cr-tile-header">' +
                '<span class="cr-tile-label">' + label + '</span>' +
                '<span class="cr-tile-window">' + WINDOW_DAYS + 'D ROLLING</span>' +
            '</div>' +
            '<div class="cr-tile-body cr-tile-empty">' +
                '<span class="cr-tile-empty-msg">NO SAMPLES</span>' +
            '</div>'
        );
    }

    /**
     * Render a single segment tile into its mount element.
     *
     * @param {string} segmentKey
     * @param {Array}  crs
     */
    function _renderTile(segmentKey, crs) {
        var mount = _mountFor(segmentKey);
        if (!mount) { return; }

        var label = SEGMENT_LABELS[segmentKey] || segmentKey;

        if (typeof window === 'undefined' || !window.lcarsCrMetrics) {
            mount.innerHTML = _buildEmptyTileHtml(label);
            return;
        }

        var rollup = window.lcarsCrMetrics.rollupSegment(
            crs,
            segmentKey,
            { windowDays: WINDOW_DAYS }
        );

        if (!rollup || rollup.sampleCount === 0) {
            mount.innerHTML = _buildEmptyTileHtml(label);
            return;
        }

        mount.innerHTML = _buildTileHtml(label, rollup.avg, rollup.median, rollup.sampleCount);
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
     * Render all 7 segment tiles given an array of CR container records.
     * No-ops when CR support is flagged off.
     *
     * @param {Array} crs — array of CR container objects from boardData.crs
     */
    function render(crs) {
        if (_crDisabled()) { return; }
        var safeCrs = Array.isArray(crs) ? crs : [];
        SEGMENT_KEYS.forEach(function (key) {
            _renderTile(key, safeCrs);
        });
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
            console.warn('[lcarsCrSegmentTiles] renderFromBoard error:', err);
        }
    }

    /**
     * Start polling for board changes (5 s interval).
     * Uses a JSON hash of boardData.crs to detect mutations without a
     * dedicated board-updated event (lcars.js does not dispatch one).
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
        // before us (load-order is metrics → cr-tab → this file), the event
        // fires before we subscribe.  Guard against that by checking the active
        // subtab button directly.
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
            window.lcarsCrSegmentTiles.init();
        });
    } else {
        window.lcarsCrSegmentTiles.init();
    }
}
