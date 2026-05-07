//
//  lcars-cr-poll-bus.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * lcars-cr-poll-bus.js — Shared CR Board-Data Poll Bus
 *
 * XACA-0293-013: Single 5-second polling interval shared by all CYCLE TIME tile
 * modules.  Before this module existed, each tile module ran its own setInterval
 * with its own JSON.stringify hash — Phase 4-7 would have multiplied intervals.
 * This bus runs ONE interval; subscribers receive the latest crs array whenever
 * the board data changes.
 *
 * Public API (window.lcarsCrPollBus):
 *   subscribe(name, callback)  — register a named callback; callback(crs[])
 *   unsubscribe(name)          — remove a registered callback by name
 *   start(intervalMs)          — start the interval; idempotent, safe to call
 *                                multiple times (only the first call takes effect)
 *   stop()                     — clear the interval; primarily for tests
 *   _forceTick()               — trigger a tick immediately; for tests/debug
 *
 * The bus does NOT filter on crSupport.enabled — that is each subscriber's
 * responsibility, consistent with the existing pattern in the tile modules.
 *
 * Dependencies:
 *   window.boardData  (lcars.js)
 *
 * No DOM access.  No network calls.  No side-effects on window.boardData.
 */

'use strict';

(function (root, factory) {
    if (typeof module !== 'undefined' && module.exports) {
        module.exports = factory();
    } else {
        root.lcarsCrPollBus = factory();
    }
}(typeof window !== 'undefined' ? window : global, function () {

    // ─── Module state ─────────────────────────────────────────────────────────

    var _subscribers  = {};   // name → callback
    var _timer        = null;
    var _lastCrsHash  = null;

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
     * Read the current crs array from boardData, or return an empty array if
     * boardData is not yet available.
     *
     * @returns {Array}
     */
    function _currentCrs() {
        try {
            return (typeof window !== 'undefined' &&
                    window.boardData &&
                    Array.isArray(window.boardData.crs))
                ? window.boardData.crs
                : [];
        } catch (_) {
            return [];
        }
    }

    /**
     * Invoke all registered subscribers with the current crs array.
     * Errors in individual subscribers are caught so a bad callback cannot
     * break the bus or other subscribers.
     *
     * @param {Array} crs
     */
    function _notifyAll(crs) {
        var names = Object.keys(_subscribers);
        for (var i = 0; i < names.length; i++) {
            try {
                _subscribers[names[i]](crs);
            } catch (err) {
                // Subscriber errors must not kill the bus.
                if (typeof console !== 'undefined') {
                    console.warn('[lcarsCrPollBus] subscriber error (' + names[i] + '):', err);
                }
            }
        }
    }

    /**
     * Check whether boardData.crs has changed since the last tick.
     * If it has, update the stored hash and notify all subscribers.
     * Called by the interval and by _forceTick().
     */
    function _tick() {
        var crs  = _currentCrs();
        var hash = _hashCrs(crs);
        if (hash !== _lastCrsHash) {
            _lastCrsHash = hash;
            _notifyAll(crs);
        }
    }

    // ─── Public API ───────────────────────────────────────────────────────────

    /**
     * Register a named subscriber callback.
     * If a subscriber with the same name already exists it is replaced.
     *
     * @param {string}   name     - Stable identifier for this subscriber (e.g. 'segment-tiles')
     * @param {Function} callback - Called with (crs: Array) whenever boardData.crs changes
     */
    function subscribe(name, callback) {
        if (typeof name !== 'string' || !name) {
            throw new Error('[lcarsCrPollBus] subscribe: name must be a non-empty string');
        }
        if (typeof callback !== 'function') {
            throw new Error('[lcarsCrPollBus] subscribe: callback must be a function');
        }
        _subscribers[name] = callback;
    }

    /**
     * Remove a previously registered subscriber by name.
     * No-ops if the name is not registered.
     *
     * @param {string} name
     */
    function unsubscribe(name) {
        delete _subscribers[name];
    }

    /**
     * Start the shared poll interval.
     * Idempotent — calling start() multiple times has no effect after the first.
     * Also subscribes to crsupport-changed so subscribers refresh immediately
     * when the feature flag is toggled on (no need to wait for the next tick).
     *
     * @param {number} [intervalMs=5000]
     */
    function start(intervalMs) {
        if (_timer !== null) { return; }
        var ms = (typeof intervalMs === 'number' && isFinite(intervalMs) && intervalMs > 0)
            ? intervalMs
            : 5000;
        _timer = setInterval(_tick, ms);

        // Refresh immediately when crSupport is enabled — don't wait for next tick.
        if (typeof document !== 'undefined') {
            document.addEventListener('crsupport-changed', function (e) {
                if (e && e.detail && e.detail.enabled === true) {
                    _lastCrsHash = null;   // force a re-notify even if crs didn't change
                    _tick();
                }
            });
        }
    }

    /**
     * Stop the shared poll interval.
     * Primarily for tests; in production the bus runs for the session lifetime.
     */
    function stop() {
        if (_timer !== null) {
            clearInterval(_timer);
            _timer = null;
        }
        _lastCrsHash = null;
    }

    /**
     * Trigger a tick immediately without waiting for the next interval.
     * Useful for tests and manual debugging from the browser console.
     */
    function _forceTick() {
        _tick();
    }

    return {
        subscribe:   subscribe,
        unsubscribe: unsubscribe,
        start:       start,
        stop:        stop,
        _forceTick:  _forceTick,
    };

}));

// ─── Auto-start ──────────────────────────────────────────────────────────────

if (typeof window !== 'undefined') {
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', function () {
            window.lcarsCrPollBus.start();
        });
    } else {
        window.lcarsCrPollBus.start();
    }
}
