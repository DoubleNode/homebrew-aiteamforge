//
//  lcars-cr-metrics.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * lcars-cr-metrics.js — CR Cycle-Time Compute Module
 *
 * XACA-0293-001: Pure-JS module (browser + Node-loadable) that computes
 * cycle-time data per the crDerived section of cr-schema.json.
 *
 * SCHEMA INVARIANT (enforced by cr-schema.json critical_invariants):
 *   Derived fields MUST NOT be persisted. This module returns computed values
 *   only — it never writes to any board JSON, item record, or disk artifact.
 *
 * Public API (window.lcarsCrMetrics):
 *   derivePerCR(cr)
 *     Compute all 8 derived fields for a single CR container record.
 *     Returns { cr_cycle_*: number|null, deploy_estimate_delta_days: number|null }.
 *
 *   rollupSegment(crs, segmentKey, opts)
 *     Rolling-window aggregate for a single segment field.
 *     Returns { avg: number|null, median: number|null, sampleCount: number }.
 *
 *   rollupEstimateDelta(crs, opts)
 *     Rolling-window aggregate for deploy_estimate_delta_days with
 *     hit/early/late breakdown.
 *     Returns { avg, sampleCount, hits, earlies, lates, hitPct, earlyPct, latePct }.
 *
 *   rollupAll(crs, opts)
 *     Convenience wrapper — returns all 8 rollups in one object.
 *
 * opts shape: { windowDays: number (default 14), now: number (default Date.now()) }
 *
 * No DOM access. No network. No globals beyond window.lcarsCrMetrics export.
 * Dependency-free.
 *
 * Dependencies: none.
 */

'use strict';

(function () {

    // ─── Constants ────────────────────────────────────────────────────────────

    var MS_PER_DAY = 86400000;

    /**
     * The 7 segment keys derived from the crTimestamps pairs, in lifecycle order.
     * Key = the derived field name; value = [startTimestampKey, endTimestampKey].
     * Endpoints are read from cr.timestamps (the crContainer.timestamps object).
     */
    var SEGMENT_PAIRS = {
        cr_cycle_draft_to_submit_days:         ['cr_created_at',       'cr_submitted_at'],
        cr_cycle_submit_to_approve_days:       ['cr_submitted_at',     'cr_approved_at'],
        cr_cycle_approve_to_dev_days:          ['cr_approved_at',      'cr_dev_started_at'],
        cr_cycle_dev_to_test_days:             ['cr_dev_started_at',   'cr_testing_started_at'],
        cr_cycle_test_to_deploydev_days:       ['cr_testing_started_at', 'cr_deployed_dev_at'],
        cr_cycle_deploydev_to_deployprod_days: ['cr_deployed_dev_at',  'cr_deployed_prod_at'],
        cr_cycle_total_days:                   ['cr_created_at',       'cr_completed_at'],
    };

    /**
     * All 7 segment keys in order — used by rollupAll to iterate.
     */
    var SEGMENT_KEYS = Object.keys(SEGMENT_PAIRS);

    // ─── Internal helpers ─────────────────────────────────────────────────────

    /**
     * Parse a timestamp string (or number) to epoch ms.
     * Returns NaN if the value is missing, empty, or not parseable.
     * Never throws.
     */
    function _parseTs(val) {
        if (val === null || val === undefined || val === '') { return NaN; }
        var ms = typeof val === 'number' ? val : Date.parse(String(val));
        return isFinite(ms) ? ms : NaN;
    }

    /**
     * Compute fractional days between two timestamp values.
     * Returns null if either endpoint is missing or non-parseable.
     * Negative results are valid (e.g. early deployment).
     */
    function _daysBetween(startVal, endVal) {
        var startMs = _parseTs(startVal);
        var endMs   = _parseTs(endVal);
        if (isNaN(startMs) || isNaN(endMs)) { return null; }
        return (endMs - startMs) / MS_PER_DAY;
    }

    /**
     * Compute the median of a non-empty array of finite numbers.
     * Returns null on empty or non-finite input.
     */
    function _median(values) {
        if (!values || values.length === 0) { return null; }
        var sorted = values.slice().sort(function (a, b) { return a - b; });
        var mid = Math.floor(sorted.length / 2);
        if (sorted.length % 2 === 1) {
            return sorted[mid];
        }
        return (sorted[mid - 1] + sorted[mid]) / 2;
    }

    /**
     * Compute the arithmetic mean of a non-empty array of finite numbers.
     * Returns null on empty input.
     */
    function _avg(values) {
        if (!values || values.length === 0) { return null; }
        var sum = 0;
        for (var i = 0; i < values.length; i++) { sum += values[i]; }
        return sum / values.length;
    }

    /**
     * Resolve the anchor timestamp (epoch ms) used to determine whether a CR
     * falls within a rolling window.
     *
     * Anchor selection rule (documented here — see brief requirement B):
     *   1. cr_completed_at         (preferred — CR is fully done)
     *   2. cr_deployed_prod_at     (fallback — prod deploy happened, may not be formally complete)
     *   3. cr_emergency_deployed_at (fallback — emergency path that skips prod)
     *
     * CRs without ANY of these three timestamps are excluded from rolling-window
     * rollups because their lifecycle hasn't reached a completion-class state.
     * Draft, submitted, approved, and in-progress CRs are intentionally excluded.
     *
     * Returns epoch ms, or NaN if no completion-class timestamp is present.
     */
    function _completionAnchorMs(ts) {
        var ms;
        ms = _parseTs(ts.cr_completed_at);
        if (!isNaN(ms)) { return ms; }
        ms = _parseTs(ts.cr_deployed_prod_at);
        if (!isNaN(ms)) { return ms; }
        ms = _parseTs(ts.cr_emergency_deployed_at);
        if (!isNaN(ms)) { return ms; }
        return NaN;
    }

    /**
     * Filter CRs to those whose completion anchor falls within the rolling
     * window [now - windowDays*MS_PER_DAY, now].
     */
    function _filterToWindow(crs, windowDays, nowMs) {
        var cutoff = nowMs - (windowDays * MS_PER_DAY);
        var result = [];
        for (var i = 0; i < crs.length; i++) {
            var cr = crs[i];
            if (!cr) { continue; }
            var ts = cr.timestamps || {};
            var anchorMs = _completionAnchorMs(ts);
            if (isNaN(anchorMs)) { continue; }
            if (anchorMs >= cutoff && anchorMs <= nowMs) {
                result.push(cr);
            }
        }
        return result;
    }

    /**
     * Resolve opts defaults. Returns { windowDays, nowMs }.
     */
    function _resolveOpts(opts) {
        var o = opts || {};
        return {
            windowDays: (typeof o.windowDays === 'number' && isFinite(o.windowDays) && o.windowDays > 0)
                ? o.windowDays
                : 14,
            nowMs: (typeof o.now === 'number' && isFinite(o.now))
                ? o.now
                : Date.now(),
        };
    }

    // ─── Public API ───────────────────────────────────────────────────────────

    /**
     * Derive all 8 cycle-time fields for a single CR container record.
     *
     * Reads timestamps from cr.timestamps (the crContainer.timestamps object,
     * matching the runtime shape produced by _normalizeCR in lcars-cr-tab.js).
     * Also reads cr.deploy_window_planned directly from the CR record for the
     * estimate-delta calculation (it is a top-level field, not in timestamps).
     *
     * All values are in fractional days (ms / 86400000).
     * Returns null for any segment whose start or end timestamp is missing
     * or non-parseable.
     * Never throws on bad input.
     *
     * @param {object} cr - CR container record (crs[] entry from boardData)
     * @returns {{ cr_cycle_draft_to_submit_days: number|null,
     *             cr_cycle_submit_to_approve_days: number|null,
     *             cr_cycle_approve_to_dev_days: number|null,
     *             cr_cycle_dev_to_test_days: number|null,
     *             cr_cycle_test_to_deploydev_days: number|null,
     *             cr_cycle_deploydev_to_deployprod_days: number|null,
     *             cr_cycle_total_days: number|null,
     *             deploy_estimate_delta_days: number|null }}
     */
    function derivePerCR(cr) {
        if (!cr || typeof cr !== 'object') {
            return _emptyDerived();
        }

        var ts = (cr.timestamps && typeof cr.timestamps === 'object') ? cr.timestamps : {};
        var result = {};

        // Compute each of the 7 segment fields from their timestamp pairs
        for (var key in SEGMENT_PAIRS) {
            if (!Object.prototype.hasOwnProperty.call(SEGMENT_PAIRS, key)) { continue; }
            var pair = SEGMENT_PAIRS[key];
            result[key] = _daysBetween(ts[pair[0]], ts[pair[1]]);
        }

        // deploy_estimate_delta_days:
        //   (cr_deployed_prod_at - deploy_window_planned) in fractional days
        //   negative = early, positive = late
        //   Only computable when BOTH fields are present (cr.deploy_window_planned
        //   is a top-level CR field, not inside timestamps).
        result.deploy_estimate_delta_days = _daysBetween(
            cr.deploy_window_planned,
            ts.cr_deployed_prod_at
        );

        return result;
    }

    /**
     * Return an object with all 8 derived keys set to null.
     * Used as the safe fallback for invalid input in derivePerCR.
     */
    function _emptyDerived() {
        var obj = {};
        for (var i = 0; i < SEGMENT_KEYS.length; i++) {
            obj[SEGMENT_KEYS[i]] = null;
        }
        obj.deploy_estimate_delta_days = null;
        return obj;
    }

    /**
     * Compute rolling-window aggregate statistics for a single segment field.
     *
     * Collects the derived value for `segmentKey` across all CRs whose
     * completion anchor falls within the rolling window, then returns
     * avg, median, and sampleCount over the non-null values.
     *
     * @param {Array}  crs        - Array of CR container records
     * @param {string} segmentKey - One of the SEGMENT_KEYS (e.g. 'cr_cycle_total_days')
     * @param {object} [opts]     - { windowDays: 14, now: Date.now() }
     * @returns {{ avg: number|null, median: number|null, sampleCount: number }}
     */
    function rollupSegment(crs, segmentKey, opts) {
        var empty = { avg: null, median: null, sampleCount: 0 };
        if (!Array.isArray(crs) || crs.length === 0) { return empty; }
        if (typeof segmentKey !== 'string') { return empty; }

        var resolved = _resolveOpts(opts);
        var windowed = _filterToWindow(crs, resolved.windowDays, resolved.nowMs);
        var values = [];

        for (var i = 0; i < windowed.length; i++) {
            var derived = derivePerCR(windowed[i]);
            var val = derived[segmentKey];
            if (val !== null && isFinite(val)) {
                values.push(val);
            }
        }

        return {
            avg:         _avg(values),
            median:      _median(values),
            sampleCount: values.length,
        };
    }

    /**
     * Compute rolling-window aggregate statistics for deploy_estimate_delta_days,
     * including hit/early/late breakdown.
     *
     * Hit/early/late thresholds (per spec):
     *   hit   = abs(delta) <= 1 day
     *   early = delta < -1 day
     *   late  = delta > +1 day
     *
     * Only CRs with BOTH deploy_window_planned AND cr_deployed_prod_at are
     * included (producing a non-null delta). CRs missing either field are
     * excluded from sampleCount and percentages.
     *
     * @param {Array}  crs    - Array of CR container records
     * @param {object} [opts] - { windowDays: 14, now: Date.now() }
     * @returns {{ avg: number|null,
     *             sampleCount: number,
     *             hits: number,
     *             earlies: number,
     *             lates: number,
     *             hitPct: number|null,
     *             earlyPct: number|null,
     *             latePct: number|null }}
     */
    function rollupEstimateDelta(crs, opts) {
        var empty = {
            avg: null, sampleCount: 0,
            hits: 0, earlies: 0, lates: 0,
            hitPct: null, earlyPct: null, latePct: null,
        };
        if (!Array.isArray(crs) || crs.length === 0) { return empty; }

        var resolved = _resolveOpts(opts);
        var windowed = _filterToWindow(crs, resolved.windowDays, resolved.nowMs);
        var values   = [];
        var hits     = 0;
        var earlies  = 0;
        var lates    = 0;

        for (var i = 0; i < windowed.length; i++) {
            var derived = derivePerCR(windowed[i]);
            var delta = derived.deploy_estimate_delta_days;
            // Only include CRs where we could compute a delta (both endpoints present)
            if (delta === null || !isFinite(delta)) { continue; }
            values.push(delta);
            var absDelta = Math.abs(delta);
            if (absDelta <= 1) {
                hits++;
            } else if (delta < -1) {
                earlies++;
            } else {
                // delta > 1
                lates++;
            }
        }

        var count = values.length;
        if (count === 0) { return empty; }

        // Largest-remainder (Hamilton) rounding: guarantees hitPct + earlyPct +
        // latePct === 100 exactly when sampleCount > 0.
        // Independent Math.round() on each bucket can produce totals of 99 or 101.
        // Step 1: exact float percentages.
        var hitRaw   = (hits    / count) * 100;
        var earlyRaw = (earlies / count) * 100;
        var lateRaw  = (lates   / count) * 100;
        // Step 2: floor each bucket.
        var hitFloor   = Math.floor(hitRaw);
        var earlyFloor = Math.floor(earlyRaw);
        var lateFloor  = Math.floor(lateRaw);
        // Step 3: distribute leftover points to buckets with the largest residuals.
        // Tie-break is alphabetical by bucket name (early < hit < late) so results
        // are deterministic regardless of bucket counts.
        var leftover = 100 - (hitFloor + earlyFloor + lateFloor);
        var buckets = [
            { key: 'early', floor: earlyFloor, residual: earlyRaw - earlyFloor },
            { key: 'hit',   floor: hitFloor,   residual: hitRaw   - hitFloor   },
            { key: 'late',  floor: lateFloor,  residual: lateRaw  - lateFloor  },
        ];
        buckets.sort(function (a, b) {
            // Sort descending by residual; ties broken by key ascending (alphabetical).
            if (b.residual !== a.residual) { return b.residual - a.residual; }
            return a.key < b.key ? -1 : 1;
        });
        for (var j = 0; j < leftover; j++) {
            buckets[j].floor += 1;
        }
        var pctMap = {};
        for (var k = 0; k < buckets.length; k++) {
            pctMap[buckets[k].key] = buckets[k].floor;
        }

        return {
            avg:         _avg(values),
            sampleCount: count,
            hits:        hits,
            earlies:     earlies,
            lates:       lates,
            hitPct:      pctMap['hit'],
            earlyPct:    pctMap['early'],
            latePct:     pctMap['late'],
        };
    }

    /**
     * Convenience wrapper — compute all 8 rollups in a single call.
     *
     * Returns an object keyed by each derived field name, plus a top-level
     * `estimateDelta` key for the full rollupEstimateDelta result.
     *
     * Shape:
     * {
     *   cr_cycle_draft_to_submit_days:         { avg, median, sampleCount },
     *   cr_cycle_submit_to_approve_days:       { avg, median, sampleCount },
     *   cr_cycle_approve_to_dev_days:          { avg, median, sampleCount },
     *   cr_cycle_dev_to_test_days:             { avg, median, sampleCount },
     *   cr_cycle_test_to_deploydev_days:       { avg, median, sampleCount },
     *   cr_cycle_deploydev_to_deployprod_days: { avg, median, sampleCount },
     *   cr_cycle_total_days:                   { avg, median, sampleCount },
     *   estimateDelta: { avg, sampleCount, hits, earlies, lates, hitPct, earlyPct, latePct },
     * }
     *
     * @param {Array}  crs    - Array of CR container records
     * @param {object} [opts] - { windowDays: 14, now: Date.now() }
     * @returns {object}
     */
    function rollupAll(crs, opts) {
        var result = {};
        for (var i = 0; i < SEGMENT_KEYS.length; i++) {
            result[SEGMENT_KEYS[i]] = rollupSegment(crs, SEGMENT_KEYS[i], opts);
        }
        result.estimateDelta = rollupEstimateDelta(crs, opts);
        return result;
    }

    // ─── Module assembly ──────────────────────────────────────────────────────

    var lcarsCrMetrics = {
        derivePerCR:          derivePerCR,
        rollupSegment:        rollupSegment,
        rollupEstimateDelta:  rollupEstimateDelta,
        rollupAll:            rollupAll,
    };

    // Browser export (IIFE + window-attach pattern matching lcars-cr-tab.js)
    if (typeof window !== 'undefined') {
        window.lcarsCrMetrics = lcarsCrMetrics;
    }

    // Node export so unit tests can require() this file directly
    if (typeof module !== 'undefined' && module.exports) {
        module.exports = lcarsCrMetrics;
    }

}());
