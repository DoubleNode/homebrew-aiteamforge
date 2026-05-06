/**
 * lcars-cr-age-helpers.js — Total-CR-age helpers for the CHANGE REQ tab
 *
 * XACA-0335: Pure-JS module (browser + Node-loadable) that computes the
 * total age of a CR record from cr_created_at (fallback addedAt) and
 * formats it as a compact relative-age label for the AGE column.
 *
 * Extracted from lcars-cr-tab.js (PR #357 [Review] subitem) so the
 * helpers are unit-testable in isolation without standing up the full
 * IIFE'd CR-tab module. Same pattern as lcars-cr-metrics.js.
 *
 * Public API (window.lcarsCrAgeHelpers, also module.exports):
 *   AGE_TERMINAL_STATES
 *     Frozen Set of crState values for which AGE is suppressed. Mirrors
 *     the canonical TERMINAL set in lcars-cr-tab.js
 *     SAVED_VIEWS['active-pipeline'] — keep these two in sync.
 *
 *   computeCRAgeMs(item, now?)
 *     Returns total CR age in milliseconds from cr_created_at (fallback
 *     addedAt), or null when the CR is in a terminal state, both
 *     timestamps are absent, or the timestamp string fails to parse.
 *     `now` defaults to Date.now() and is overridable for deterministic
 *     unit tests.
 *
 *   formatRelativeAge(ageMs)
 *     Format a millisecond duration as a compact relative-age string.
 *       < 1h          → "<N>m"
 *       < 24h         → "<N>h"
 *       < 7d          → "<N>d"
 *       < 30d         → "<N>w"
 *       ≥ 30d         → "<N>mo"
 *     Negative or zero clamps to "0m" (handles minor clock skew without
 *     producing nonsense like "-1m").
 *
 * No DOM access. No network. Dependency-free.
 */

'use strict';

(function () {

    // ─── Terminal states ──────────────────────────────────────────────────────

    /**
     * Terminal CR states for which AGE renders as "—".
     *
     * MUST mirror the TERMINAL set in lcars-cr-tab.js
     * SAVED_VIEWS['active-pipeline']. Once a CR reaches one of these
     * states the queue-management value of "how long has this been
     * waiting" goes to zero, so we suppress the value rather than let
     * it grow unbounded on rows that no longer need triage.
     */
    var AGE_TERMINAL_STATES = new Set([
        'deployed-prod',
        'emergency-deployed',
        'cr-rejected',
    ]);

    // ─── Compute ──────────────────────────────────────────────────────────────

    function computeCRAgeMs(item, now) {
        if (!item) return null;
        if (AGE_TERMINAL_STATES.has(item.crState)) return null;
        var rawTs = item.cr_created_at || item.addedAt;
        if (!rawTs) return null;
        var ms = new Date(rawTs).getTime();
        if (!ms || isNaN(ms)) return null;
        var nowMs = (typeof now === 'number') ? now : Date.now();
        return nowMs - ms;
    }

    // ─── Format ───────────────────────────────────────────────────────────────

    function formatRelativeAge(ageMs) {
        var m = Math.max(0, Math.floor(ageMs / 60000));
        if (m < 60)  return m + 'm';
        var h = Math.floor(m / 60);
        if (h < 24)  return h + 'h';
        var d = Math.floor(h / 24);
        if (d < 7)   return d + 'd';
        var w = Math.floor(d / 7);
        if (d < 30)  return w + 'w';
        var mo = Math.floor(d / 30);
        return mo + 'mo';
    }

    // ─── Module assembly ──────────────────────────────────────────────────────

    var lcarsCrAgeHelpers = {
        AGE_TERMINAL_STATES: AGE_TERMINAL_STATES,
        computeCRAgeMs:      computeCRAgeMs,
        formatRelativeAge:   formatRelativeAge,
    };

    // Browser export (loaded via <script> before lcars-cr-tab.js)
    if (typeof window !== 'undefined') {
        window.lcarsCrAgeHelpers = lcarsCrAgeHelpers;
    }

    // Node export so unit tests can require() this file directly
    if (typeof module !== 'undefined' && module.exports) {
        module.exports = lcarsCrAgeHelpers;
    }

}());
