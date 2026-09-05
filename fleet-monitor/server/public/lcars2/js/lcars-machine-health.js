//
//  lcars-machine-health.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * XACA-1092-003 -- Machine health-state derivation.
 *
 * A STANDALONE PURE FUNCTION: no DOM, no fetch, no globals read, no side
 * effects. Same inputs always produce the same output. This file is loaded
 * as a plain browser <script> like its neighbours in this directory (no
 * build step, no dependency), but nothing in it touches `document` or
 * `window` beyond exposing its own namespace, so it is equally loadable
 * headless (see tests/xaca-1092-003-machine-health.test.js).
 *
 * ── WIRE DECOUPLING (deliberate) ─────────────────────────────────────────
 * This module takes already-normalized PRIMITIVE arguments -- never the raw
 * `machine.system{}` wire object from XACA-1091's frozen contract
 * (kanban/plans/XACA-1091/CONTRACT-system-block.md). Mapping wire field
 * names (system.disk.percent, system.swap_used_bytes,
 * system.load_average[0], system.cores, ...) onto these primitives is an
 * ADAPTER's job, owned by a different subitem -- NOT this file. That
 * decoupling has already paid off twice this session: the upstream
 * contract changed shape twice while this subitem was in flight (first the
 * container/versions nesting, then the disk-percent-is-pre-computed and
 * zero-is-data corrections below), and this function needed zero edits for
 * either change. Preserve that property -- do not restructure this file
 * toward the wire format.
 *
 * ── DISK vs SWAP -- INVERSE RULES, NOT PARALLEL ONES ─────────────────────
 * - `diskPercentUsed` ships PRE-COMPUTED by the reporter and MUST be
 *   consumed as-is -- NEVER recomputed here from used/total. On APFS, `df`'s
 *   total column is NOT used+free (the boot volume is a sealed snapshot on
 *   a shared container): measured live on darren-m3pro, `df -k /` reported
 *   total=1948424520K used=24457896K avail=74429544K, where used/total is
 *   1.26% but df's own capacity column -- used/(used+avail) -- is 25%, the
 *   figure that actually matches reality. A percent-of-total denominator is
 *   a ~20x under-report that gets WORSE as the disk fills, and it fails in
 *   the reassuring direction. See CONTRACT-system-block.md §5(a). This
 *   function trusts `diskPercentUsed` to already be that safe, correct
 *   number and does no arithmetic on it beyond threshold comparison.
 * - Swap must NEVER be a percentage and must be thresholded in ABSOLUTE
 *   BYTES -- see scripts/iterm2-memory-watchdog.py's module docstring,
 *   section "WHY NOT SWAP-USED-AS-A-PERCENTAGE" (lines ~40-82), and its
 *   SWAP_USED_WARNING_MB / SWAP_USED_CRITICAL_MB constants (lines
 *   ~189-194), confirmed by reading that file directly:
 *     SWAP_USED_WARNING_MB  = 15 * 1024   (comment: "15 GB")
 *     SWAP_USED_CRITICAL_MB = 30 * 1024   (comment: "30 GB")
 *   Reused verbatim below as byte counts. NOTE the watchdog's own "* 1024"
 *   multiplier is BINARY (i.e. these are 15 GiB / 30 GiB), despite being
 *   commented "GB" -- this file uses the identical byte count and spells
 *   the binary unit out explicitly (BYTES_PER_GIB) so that ambiguity is not
 *   re-introduced here.
 *
 *   KNOWN FOLLOW-UP (not fixed here, by design): 15 GiB / 30 GiB were
 *   calibrated on an 18 GB M3Pro. The fleet also runs M1Pro/M4Mini machines
 *   with different total RAM, so the same absolute thresholds will trip at
 *   different *relative* memory pressure on each machine class. The user
 *   has explicitly decided to reuse the calibrated figures verbatim rather
 *   than scale them per machine -- do not "improve" this without a new
 *   ticket.
 *
 * ── LOAD AVERAGE must be normalized by CORE COUNT ────────────────────────
 * `coreCount` is `hw.logicalcpu` (LOGICAL cores), the correct denominator
 * because `vm.loadavg` is a run-queue depth compared against logical CPUs,
 * not physical ones -- CONTRACT-system-block.md §5(b). A load of 8 is idle
 * on a 10-core box and catastrophic on a 2-core box. If `coreCount` is
 * missing, non-numeric, or non-positive, load is treated as UNKNOWN --
 * never given a guessed default, because a wrong default could produce a
 * false AT RISK badge in either direction.
 *
 * ── RULING: LOAD IS RENDERED BUT DOES NOT VOTE ON THE OVERALL VERDICT ────
 * `metrics.load` is still fully computed below -- normalized, thresholded,
 * displayed -- but it is EXCLUDED from the `state` (AT RISK) roll-up.
 * Disk and swap are the only two metrics whose overall verdict is a
 * calibrated claim: swap's 15/30 GiB bounds are reused verbatim from
 * scripts/iterm2-memory-watchdog.py, calibrated against a real 2026-07-09
 * crisis and a measured ambient baseline (see that file's docstring);
 * disk's bounds are conventional ops bands, but its denominator is fixed
 * and safe to threshold at all (see the DISK vs SWAP note above). Load's
 * LOAD_WARNING_RATIO / LOAD_CRITICAL_RATIO below have NEITHER kind of
 * grounding -- they were invented at the keyboard while writing this
 * function, and a repo-wide grep turned up no load-average threshold
 * precedent anywhere, including in the watchdog script, which deliberately
 * thresholds footprint, swap bytes, and swapout RATE -- and pointedly NOT
 * load average. Measured evidence against the invented numbers: this dev
 * host read 6.4x logical cores (load 70.29 across 11 logical cores) while
 * working perfectly normally, and 1.49x earlier in the same session. A
 * badge that fires at 1.0x fires on essentially every busy dev machine,
 * and the alert fatigue that produces would destroy the value of the swap
 * and disk signals that ARE trustworthy. This follows the precedent set by
 * XACA-0767 elsewhere in this file's history: REMOVE (or in this case,
 * don't wire in) a signal you cannot calibrate correctly, rather than ship
 * a threshold that looks authoritative but isn't. See
 * `evaluateOverallState()`/`deriveMachineHealth()` below for exactly how
 * the exclusion is implemented, including the "load is the only evaluable
 * metric" case. DO NOT wire load back into the roll-up to "fix" the
 * apparent inconsistency of a computed-but-non-voting metric -- that
 * inconsistency is deliberate and is the entire point of this note. What
 * WOULD justify calibrating and re-enabling it: ambient load-average
 * readings gathered across the fleet (multiple machine classes, multiple
 * times of day) PLUS at least one real degradation event attributable to
 * load, the same two-part evidence bar swap already cleared.
 *
 * ── ABSENT / ZERO INPUT -- THE SHIPPING PATH, NOT AN EDGE CASE ───────────
 * server.js's machineList projection (the `machineList` allowlist inside
 * parseFleetData() -- grep server.js for `system: projectSystemBlock(m.system)`
 * to locate it directly rather than trusting a line number, which has
 * already drifted once) is an explicit allowlist with no `system` entry as
 * of this writing, so on day one EVERY machine in the fleet hits the
 * all-inputs-absent path. Every argument may
 * be missing, undefined, null, a non-numeric string, or NaN -- all of those
 * are treated as "not evaluable", contributing NEITHER healthy NOR at-risk
 * evidence. If every metric is unevaluable, the overall verdict is the
 * explicit `'unknown'` state, distinct from `'healthy'`.
 *
 * CRITICAL: a COLLECTED ZERO IS DATA, NOT ABSENCE, and is frequently the
 * HEALTHIEST possible reading (`swapUsedBytes: 0` = not swapping at all;
 * `loadAvg1: 0` = idle; `diskPercentUsed: 0` = empty disk). Evaluability is
 * therefore an EXISTENCE + TYPE check
 * (`typeof x === 'number' && Number.isFinite(x)`), NEVER a truthiness check
 * (`if (!x)`) -- a falsy-based guard would misreport the fleet's best
 * machines as unknown and its worst as confident. See
 * CONTRACT-system-block.md §3, "A COLLECTED zero or false is DATA, not
 * absence". There is no null convention in the frozen contract either
 * (an uncollectable field is OMITTED, never `null`) -- this function still
 * treats `null` defensively as "not evaluable" rather than throwing, since
 * nothing upstream of it is trusted to honor that convention perfectly.
 *
 * ── SCOPE NOTE: memory is NOT evaluated here ──────────────────────────────
 * The ticket's three numbered "THRESHOLD CORRECTNESS" metrics are disk,
 * swap, and load -- memory used/total is a RENDER-only field elsewhere in
 * this ticket's scope, and no threshold figure (calibrated or otherwise)
 * has been specified for memory pressure anywhere referenced by this
 * subitem. Inventing one here would violate "count it, don't assert it".
 * If a future subitem adds a memory-pressure threshold, extend `metrics{}`
 * additively -- do not change the shape of disk/swap/load.
 *
 * ── OUTPUT SHAPE (stable -- the renderer depends on it) ──────────────────
 *   {
 *     state: 'healthy' | 'at_risk' | 'unknown',
 *     metrics: {
 *       disk: { state, value, threshold, unit, evaluable },
 *       swap: { state, value, threshold, unit, evaluable },
 *       load: { state, value, threshold, unit, evaluable }
 *     }
 *   }
 *   Each per-metric `state` is one of 'ok' | 'warning' | 'critical' |
 *   'unknown'. `value` is the raw number that was evaluated (the normalized
 *   ratio for load, not the raw loadAvg1). `threshold` is whichever bound
 *   produced the verdict (the WARNING bound when state is 'ok' or
 *   'warning', the CRITICAL bound when state is 'critical'; `null` when
 *   unevaluable). `value`/`threshold` are both `null` when `evaluable` is
 *   `false` -- never `NaN`, never `undefined`. This is what lets the
 *   renderer explain WHY a host is at risk instead of just showing a badge.
 *
 *   Overall `state` is voted on by disk and swap ONLY -- see the "RULING:
 *   LOAD IS RENDERED BUT DOES NOT VOTE" note above for why load is
 *   computed and displayed but excluded here:
 *     - `'at_risk'` if disk or swap (evaluable) is `'warning'` or
 *       `'critical'`. Load's own state is irrelevant to this branch even
 *       when load is `'critical'`.
 *     - `'unknown'` if NEITHER disk nor swap was evaluable -- INCLUDING
 *       the case where load *was* evaluable (even flagged) but disk and
 *       swap were not. A non-voting metric being the only evaluable one
 *       must not silently read as `'healthy'` (there is no voting
 *       evidence for that) or as `'at_risk'` (load isn't allowed to cast
 *       that vote) -- `'unknown'` is the only answer that doesn't
 *       overclaim in either direction.
 *     - `'healthy'` otherwise, i.e. disk or swap was evaluable and neither
 *       was flagged (load may be showing warning/critical for display and
 *       this is still `'healthy'` -- that is the whole point of the
 *       ruling).
 */

// Global namespace, matching this directory's convention (see
// lcars-fleet-core.js's `window.LCARS_CORE = window.LCARS_CORE || {};`).
window.LCARS_MACHINE_HEALTH = window.LCARS_MACHINE_HEALTH || {};

(function (NS) {
    'use strict';

    // ── Thresholds ───────────────────────────────────────────────────────

    // Swap: ABSOLUTE BYTES, reused verbatim from
    // scripts/iterm2-memory-watchdog.py's SWAP_USED_WARNING_MB (15 * 1024)
    // and SWAP_USED_CRITICAL_MB (30 * 1024) -- see module header for the
    // exact command/output that confirmed these before they were hardcoded
    // here, and for the GiB-not-GB unit note.
    var BYTES_PER_GIB = 1024 * 1024 * 1024;
    var SWAP_WARNING_BYTES = 15 * BYTES_PER_GIB;
    var SWAP_CRITICAL_BYTES = 30 * BYTES_PER_GIB;

    // Disk: percent-of-capacity thresholds. Safe to threshold at all
    // (fixed denominator, per CONTRACT-system-block.md §5(a)) -- but unlike
    // swap, there is no calibrated-incident figure to reuse for disk in
    // this fleet's history, so these are conventional ops warn/critical
    // bands rather than a measured calibration. Revisit if real incident
    // data ever narrows this.
    var DISK_WARNING_PERCENT = 85;
    var DISK_CRITICAL_PERCENT = 95;

    // Load average, normalized by logical core count (ratio = loadAvg1 /
    // coreCount). > 1.0 means the run queue is sustained longer than there
    // are logical CPUs to service it; > 2.0 is a conventional "clearly
    // overloaded" band. UNLIKE disk, these are not even a conventional ops
    // band reused from prior art -- they were invented at the keyboard for
    // this ticket, with no precedent anywhere in this repo (grepped for
    // one; found none) and no incident behind them. Measured evidence says
    // they are wrong for that job: this dev host ran at 6.4x cores (load
    // 70.29 / 11 logical cores) while behaving perfectly normally. THAT IS
    // WHY these two constants drive `metrics.load`'s own display state
    // (kept for the renderer) but are deliberately EXCLUDED from voting on
    // the overall `state` -- see the module-header "RULING" note and
    // `deriveMachineHealth()` below. Kept as display-only constants rather
    // than deleted so a future subitem can calibrate and re-enable them
    // without re-deriving the shape from scratch. What would justify that:
    // ambient load readings across the fleet (multiple machine classes,
    // multiple times of day) plus at least one real degradation event
    // attributable to load -- the same two-part bar swap's thresholds
    // cleared before they were trusted to vote.
    var LOAD_WARNING_RATIO = 1.0;
    var LOAD_CRITICAL_RATIO = 2.0;

    // ── Helpers ──────────────────────────────────────────────────────────

    /**
     * True only for a genuine, finite number -- excludes null, undefined,
     * NaN, Infinity, booleans, and numeric strings. This is an
     * EXISTENCE + TYPE check, deliberately NEVER a truthiness check: `0`
     * must pass (see module header, "a collected zero is data").
     * @param {*} x
     * @returns {boolean}
     */
    function isFiniteNumber(x) {
        return typeof x === 'number' && Number.isFinite(x);
    }

    /**
     * The shared "nothing to evaluate" result for one metric.
     * @returns {{state: string, value: null, threshold: null, unit: null, evaluable: boolean}}
     */
    function unknownMetric() {
        return { state: 'unknown', value: null, threshold: null, unit: null, evaluable: false };
    }

    /**
     * Classify an already-evaluable numeric value against a warning/
     * critical pair. Boundary values (`value === threshold`) fall into the
     * threshold they meet, i.e. `>=` on both bounds.
     * @param {number} value
     * @param {number} warningThreshold
     * @param {number} criticalThreshold
     * @param {string} unit - purely descriptive, for the renderer.
     * @returns {{state: string, value: number, threshold: number, unit: string, evaluable: true}}
     */
    function evaluateAgainstThresholds(value, warningThreshold, criticalThreshold, unit) {
        var state = 'ok';
        var threshold = warningThreshold;
        if (value >= criticalThreshold) {
            state = 'critical';
            threshold = criticalThreshold;
        } else if (value >= warningThreshold) {
            state = 'warning';
            threshold = warningThreshold;
        }
        return { state: state, value: value, threshold: threshold, unit: unit, evaluable: true };
    }

    function evaluateDisk(diskPercentUsed) {
        if (!isFiniteNumber(diskPercentUsed)) {
            return unknownMetric();
        }
        return evaluateAgainstThresholds(diskPercentUsed, DISK_WARNING_PERCENT, DISK_CRITICAL_PERCENT, 'percent');
    }

    function evaluateSwap(swapUsedBytes) {
        if (!isFiniteNumber(swapUsedBytes)) {
            return unknownMetric();
        }
        return evaluateAgainstThresholds(swapUsedBytes, SWAP_WARNING_BYTES, SWAP_CRITICAL_BYTES, 'bytes');
    }

    function evaluateLoad(loadAvg1, coreCount) {
        // Both operands must be genuine finite numbers AND coreCount must be
        // positive -- a missing/zero/negative core count has no safe
        // default (see module header) so load becomes unknown rather than
        // guessed.
        if (!isFiniteNumber(loadAvg1) || !isFiniteNumber(coreCount) || coreCount <= 0) {
            return unknownMetric();
        }
        var normalized = loadAvg1 / coreCount;
        return evaluateAgainstThresholds(normalized, LOAD_WARNING_RATIO, LOAD_CRITICAL_RATIO, 'ratio');
    }

    // ── Public API ───────────────────────────────────────────────────────

    /**
     * Derive a machine's overall health state from normalized primitives.
     * PURE: no DOM, no fetch, no globals, no side effects -- same input
     * always produces the same output.
     *
     * @param {object} [input]
     * @param {number} [input.diskPercentUsed] - 0-100, pre-computed by the
     *   reporter. NEVER recompute this from used/total (see module header).
     * @param {number} [input.swapUsedBytes] - absolute bytes.
     * @param {number} [input.loadAvg1] - 1-minute load average, RAW (not
     *   yet normalized by core count -- this function does that).
     * @param {number} [input.coreCount] - logical CPU count
     *   (`sysctl hw.logicalcpu`), the correct denominator for load average.
     * @returns {{state: string, metrics: {disk: object, swap: object, load: object}}}
     */
    // Metrics allowed to vote on the overall verdict. `load` is
    // deliberately absent -- see the module-header "RULING: LOAD IS
    // RENDERED BUT DOES NOT VOTE" note and the LOAD_WARNING_RATIO /
    // LOAD_CRITICAL_RATIO comment above for the full reasoning (no
    // calibration precedent anywhere in this repo, and measured evidence
    // -- 6.4x cores while healthy -- that the invented ratio thresholds
    // would fire on ordinary busy machines). `metrics.load` itself is
    // still fully computed and returned for display; this list only
    // controls what feeds `state`. DO NOT add 'load' here without a new
    // ticket that calibrates it (ambient fleet readings + a real
    // degradation event, the same bar swap cleared).
    var VOTING_METRIC_NAMES = ['disk', 'swap'];

    /**
     * Roll up ONLY the voting metrics (disk, swap) into the overall
     * verdict. `metrics.load` is intentionally excluded from both the
     * "flagged" and "evaluable" checks below -- see VOTING_METRIC_NAMES.
     *
     * The subtle case: if load is the ONLY evaluable metric (disk and
     * swap both unknown), `anyVotingEvaluable` is false regardless of
     * load's own state, so the result is `'unknown'` -- never `'healthy'`
     * (there is no voting evidence to call it healthy) and never
     * `'at_risk'` (load doesn't get to cast that vote). A non-voting
     * signal must not be able to manufacture a verdict in EITHER
     * direction just because it happens to be the only thing reporting.
     *
     * @param {{disk: object, swap: object, load: object}} metrics
     * @returns {string} 'at_risk' | 'unknown' | 'healthy'
     */
    function evaluateOverallState(metrics) {
        var anyVotingEvaluable = false;
        var anyFlagged = false;
        for (var i = 0; i < VOTING_METRIC_NAMES.length; i++) {
            var metric = metrics[VOTING_METRIC_NAMES[i]];
            if (metric.evaluable) {
                anyVotingEvaluable = true;
            }
            if (metric.state === 'warning' || metric.state === 'critical') {
                anyFlagged = true;
            }
        }

        if (anyFlagged) {
            return 'at_risk';
        }
        if (!anyVotingEvaluable) {
            return 'unknown';
        }
        return 'healthy';
    }

    function deriveMachineHealth(input) {
        input = input || {};

        var metrics = {
            disk: evaluateDisk(input.diskPercentUsed),
            swap: evaluateSwap(input.swapUsedBytes),
            load: evaluateLoad(input.loadAvg1, input.coreCount)
        };

        return { state: evaluateOverallState(metrics), metrics: metrics };
    }

    NS.deriveMachineHealth = deriveMachineHealth;

    // Exposed so callers/tests can reference the real thresholds instead of
    // duplicating the magic numbers.
    NS.THRESHOLDS = {
        SWAP_WARNING_BYTES: SWAP_WARNING_BYTES,
        SWAP_CRITICAL_BYTES: SWAP_CRITICAL_BYTES,
        DISK_WARNING_PERCENT: DISK_WARNING_PERCENT,
        DISK_CRITICAL_PERCENT: DISK_CRITICAL_PERCENT,
        LOAD_WARNING_RATIO: LOAD_WARNING_RATIO,
        LOAD_CRITICAL_RATIO: LOAD_CRITICAL_RATIO
    };

})(window.LCARS_MACHINE_HEALTH);
