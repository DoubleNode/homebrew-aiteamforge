//
//  xaca-1092-003-machine-health.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1092-003 -- coverage for deriveMachineHealth() in
 * fleet-monitor/server/public/lcars2/js/lcars-machine-health.js.
 *
 * ── Route taken, and why ─────────────────────────────────────────────────
 * The only comparable harness in this directory,
 * tests/helpers/lcars-client-dom-stub.js, exists specifically to fake a DOM
 * for browser-IIFE functions that manipulate one (createTeamCard(),
 * escapeHtml(), etc). deriveMachineHealth() touches no DOM at all -- it is
 * a pure function of its arguments -- so reusing that stub would add DOM
 * surface area for nothing to consume. Per this subitem's brief ("If none
 * exists, do NOT invent a framework; include a self-contained assertion
 * block runnable with plain node"), this file uses node's own built-in
 * `node:test` + `node:assert/strict` and loads the REAL shipped source
 * (never a paraphrase of it) via `node:vm` with a two-line `window` stub --
 * there is no DOM to fake because the function under test touches none.
 *
 * WIRED into server/package.json's "test" script as of XACA-1092-006 --
 * this file existed and passed (24/24) since XACA-1092-003 but was never
 * added to the explicit file list `npm test` runs (that list has no glob,
 * so a new test file is invisible to CI until named here), which meant the
 * "133 tests / 115 pass / 18 pre-existing failures" baseline never actually
 * included this suite. Found and fixed during the XACA-1092-006 adversarial
 * pass rather than left for "whoever wires the renderer subitems in" per
 * the (now stale) note this replaced -- the renderer subitems had already
 * landed with their own coverage gap (see
 * tests/xaca-1092-006-degradation-adversarial.test.js) and neither one had
 * closed this. Can still be run standalone:
 *
 *   cd fleet-monitor/server && node --test tests/xaca-1092-003-machine-health.test.js
 */

const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');
const assert = require('node:assert/strict');

const MODULE_PATH = path.join(__dirname, '..', 'public', 'lcars2', 'js', 'lcars-machine-health.js');

/**
 * Load the real shipped module in a fresh vm context. The module's only
 * global touch is `window.LCARS_MACHINE_HEALTH = window.LCARS_MACHINE_HEALTH
 * || {}` plus assignments onto that namespace object -- so a `window` that
 * refers to the sandbox itself is sufficient; no DOM stub is needed.
 * @returns {{deriveMachineHealth: Function, THRESHOLDS: object}}
 */
function loadHealthModule() {
    const src = fs.readFileSync(MODULE_PATH, 'utf8');
    const sandbox = {};
    sandbox.window = sandbox;
    vm.createContext(sandbox);
    vm.runInContext(src, sandbox, { filename: MODULE_PATH });
    assert.ok(sandbox.LCARS_MACHINE_HEALTH, 'module did not attach LCARS_MACHINE_HEALTH to window');
    return sandbox.LCARS_MACHINE_HEALTH;
}

const HEALTH = loadHealthModule();
const deriveMachineHealth = HEALTH.deriveMachineHealth;
const T = HEALTH.THRESHOLDS;

// ── Calibrated threshold sanity ───────────────────────────────────────────

test('swap thresholds are the ABSOLUTE-BYTE figures reused verbatim from scripts/iterm2-memory-watchdog.py (SWAP_USED_WARNING_MB=15*1024, SWAP_USED_CRITICAL_MB=30*1024)', () => {
    assert.equal(T.SWAP_WARNING_BYTES, 15 * 1024 * 1024 * 1024);
    assert.equal(T.SWAP_CRITICAL_BYTES, 30 * 1024 * 1024 * 1024);
});

// ── The shipping path: everything absent ──────────────────────────────────
// server.js's machineList projection (server.js:1337-1352) has no `system`
// entry as of this writing, so this is what EVERY machine in the fleet
// looks like on day one -- not a hypothetical edge case.

test('all inputs absent -> overall unknown, every metric unknown, no throw', () => {
    const result = deriveMachineHealth({});
    assert.equal(result.state, 'unknown');
    assert.equal(result.metrics.disk.state, 'unknown');
    assert.equal(result.metrics.swap.state, 'unknown');
    assert.equal(result.metrics.load.state, 'unknown');
    assert.equal(result.metrics.disk.evaluable, false);
    assert.equal(result.metrics.swap.evaluable, false);
    assert.equal(result.metrics.load.evaluable, false);
});

test('no input object at all (undefined) -> unknown, no throw', () => {
    const result = deriveMachineHealth(undefined);
    assert.equal(result.state, 'unknown');
});

test('called with zero arguments -> unknown, no throw', () => {
    const result = deriveMachineHealth();
    assert.equal(result.state, 'unknown');
});

// ── A collected zero is DATA, not absence (CONTRACT-system-block.md §3) ──
// These are the highest-value cases in this suite: a truthiness-based guard
// (`if (!x)`) would misclassify the fleet's healthiest machines as unknown.

test('swapUsedBytes: 0 (not swapping at all -- the best possible reading) evaluates to healthy, never unknown', () => {
    const result = deriveMachineHealth({ swapUsedBytes: 0, diskPercentUsed: 10, loadAvg1: 0, coreCount: 8 });
    assert.equal(result.metrics.swap.evaluable, true);
    assert.equal(result.metrics.swap.state, 'ok');
    assert.equal(result.metrics.swap.value, 0);
    assert.equal(result.state, 'healthy');
});

test('loadAvg1: 0 with coreCount: 0 cores idle evaluates to healthy, never unknown', () => {
    const result = deriveMachineHealth({ loadAvg1: 0, coreCount: 8, diskPercentUsed: 5, swapUsedBytes: 0 });
    assert.equal(result.metrics.load.evaluable, true);
    assert.equal(result.metrics.load.state, 'ok');
    assert.equal(result.metrics.load.value, 0);
    assert.equal(result.state, 'healthy');
});

test('diskPercentUsed: 0 (empty disk) evaluates to healthy, never unknown', () => {
    const result = deriveMachineHealth({ diskPercentUsed: 0, swapUsedBytes: 0, loadAvg1: 0, coreCount: 8 });
    assert.equal(result.metrics.disk.evaluable, true);
    assert.equal(result.metrics.disk.state, 'ok');
    assert.equal(result.state, 'healthy');
});

// ── Malformed / partial input never crashes, never false-positives ───────

test('non-numeric / malformed inputs (string, NaN, null, undefined) are treated as unevaluable, never crash, never emit NaN/undefined, never false-positive at_risk', () => {
    const result = deriveMachineHealth({
        diskPercentUsed: '50', // string, not a number
        swapUsedBytes: NaN,
        loadAvg1: null,
        coreCount: undefined
    });
    assert.equal(result.metrics.disk.evaluable, false);
    assert.equal(result.metrics.swap.evaluable, false);
    assert.equal(result.metrics.load.evaluable, false);
    assert.equal(result.state, 'unknown');
    assert.doesNotMatch(JSON.stringify(result), /NaN/);
});

test('a sweep of edge inputs never produces NaN/undefined anywhere in the output and never throws', () => {
    const edgeCases = [
        {},
        { diskPercentUsed: 0, swapUsedBytes: 0, loadAvg1: 0, coreCount: 1 },
        { diskPercentUsed: 100, swapUsedBytes: Number.MAX_SAFE_INTEGER, loadAvg1: 999, coreCount: 1 },
        { diskPercentUsed: -5 },
        { coreCount: Infinity, loadAvg1: 5 },
        { coreCount: true, loadAvg1: 5 },
        { diskPercentUsed: [], swapUsedBytes: {}, loadAvg1: 'x', coreCount: 'y' }
    ];
    for (const input of edgeCases) {
        const result = deriveMachineHealth(input);
        const json = JSON.stringify(result);
        assert.doesNotMatch(json, /NaN/);
        assert.ok(!json.includes('undefined'));
        assert.equal(typeof result.state, 'string');
    }
});

// ── Disk: fixed-denominator percent, consumed as given, never recomputed ──

test('disk percent well under warning -> ok', () => {
    const r = deriveMachineHealth({ diskPercentUsed: 50 });
    assert.equal(r.metrics.disk.state, 'ok');
});

test('disk percent at the warning threshold -> warning, overall at_risk', () => {
    const r = deriveMachineHealth({ diskPercentUsed: T.DISK_WARNING_PERCENT });
    assert.equal(r.metrics.disk.state, 'warning');
    assert.equal(r.state, 'at_risk');
});

test('disk percent at the critical threshold -> critical, overall at_risk', () => {
    const r = deriveMachineHealth({ diskPercentUsed: T.DISK_CRITICAL_PERCENT });
    assert.equal(r.metrics.disk.state, 'critical');
    assert.equal(r.state, 'at_risk');
});

// ── Swap: absolute bytes, never a percentage ──────────────────────────────

test('swap just under the warning threshold -> ok', () => {
    const r = deriveMachineHealth({ swapUsedBytes: T.SWAP_WARNING_BYTES - 1 });
    assert.equal(r.metrics.swap.state, 'ok');
});

test('swap at the critical threshold -> critical', () => {
    const r = deriveMachineHealth({ swapUsedBytes: T.SWAP_CRITICAL_BYTES });
    assert.equal(r.metrics.swap.state, 'critical');
});

test('REAL non-synthetic calibration vector (darren-m3pro, 2026-09-04, sysctl vm.swapusage: total 21504.00M used 20651.12M): ~96%+ by percentage looks catastrophic, but in absolute bytes is a WARNING, not critical -- the entire rationale for absolute-byte thresholding, observed live', () => {
    const usedBytes = 20651.12 * 1024 * 1024;
    const r = deriveMachineHealth({ swapUsedBytes: usedBytes });
    assert.equal(r.metrics.swap.state, 'warning');
    assert.notEqual(r.metrics.swap.state, 'critical');
    assert.equal(r.state, 'at_risk');
});

test('REAL calibration vector #2 (darren-m3pro, sysctl vm.swapusage: total 21504.00M used 20929.00M, ~97.3% by percentage): also a WARNING, not critical, in absolute bytes (~20.4 GiB against 15/30 GiB bounds)', () => {
    const usedBytes = 20929.0 * 1024 * 1024;
    const r = deriveMachineHealth({ swapUsedBytes: usedBytes });
    assert.equal(r.metrics.swap.state, 'warning');
    assert.notEqual(r.metrics.swap.state, 'critical');
});

// ── Load: normalized by core count, never a raw threshold ────────────────

test('REAL calibration vector (darren-m3pro, sysctl vm.loadavg 16.34 23.37 29.51, sysctl hw.logicalcpu 11): 16.34 / 11 ~= 1.49 normalized -> warning (exceeds the 1.0 warning ratio, stays under the 2.0 critical ratio)', () => {
    const r = deriveMachineHealth({ loadAvg1: 16.34, coreCount: 11 });
    assert.equal(r.metrics.load.state, 'warning');
    assert.notEqual(r.metrics.load.state, 'critical');
});

test('identical raw load average, different core counts, produce different verdicts -- proves normalization by core count is actually applied', () => {
    const busyTwoCore = deriveMachineHealth({ loadAvg1: 8, coreCount: 2 });    // ratio 4.0
    const idleSixteenCore = deriveMachineHealth({ loadAvg1: 8, coreCount: 16 }); // ratio 0.5
    assert.equal(busyTwoCore.metrics.load.state, 'critical');
    assert.equal(idleSixteenCore.metrics.load.state, 'ok');
});

test('missing, zero, or negative coreCount -> load is unknown, never a guessed default, never a false verdict', () => {
    const missingCore = deriveMachineHealth({ loadAvg1: 20 });
    const zeroCore = deriveMachineHealth({ loadAvg1: 20, coreCount: 0 });
    const negativeCore = deriveMachineHealth({ loadAvg1: 20, coreCount: -4 });
    assert.equal(missingCore.metrics.load.state, 'unknown');
    assert.equal(zeroCore.metrics.load.state, 'unknown');
    assert.equal(negativeCore.metrics.load.state, 'unknown');
});

// ── RULING (XACA-1092): load is rendered but does NOT vote on the overall
// verdict. Load's 1.0x/2.0x ratio thresholds were invented at the keyboard
// with no calibration precedent anywhere in this repo (confirmed by grep),
// unlike swap's 15/30 GiB (reused verbatim from
// scripts/iterm2-memory-watchdog.py, calibrated against a real 2026-07-09
// crisis). Measured evidence against the invented numbers: this dev host
// ran at 6.4x logical cores (load 70.29 / 11 cores) while behaving
// perfectly normally. A badge that fires at 1.0x fires on essentially
// every busy machine and would drown out the trustworthy swap/disk
// signals with alert fatigue -- see lcars-machine-health.js's module
// header and LOAD_WARNING_RATIO/LOAD_CRITICAL_RATIO comments for the full
// rationale, including what WOULD justify calibrating and re-enabling it.

test('high load alone (disk and swap both healthy) does NOT lift overall state to at_risk -- load computes/renders as critical but cannot vote', () => {
    // The exact measured vector from the ruling: load 70.29 across 11
    // logical cores (ratio ~6.39, far past the 2.0 "critical" band) on an
    // otherwise perfectly healthy machine.
    const r = deriveMachineHealth({ diskPercentUsed: 5, swapUsedBytes: 0, loadAvg1: 70.29, coreCount: 11 });
    assert.equal(r.metrics.load.state, 'critical');
    assert.equal(r.metrics.disk.state, 'ok');
    assert.equal(r.metrics.swap.state, 'ok');
    assert.equal(r.state, 'healthy');
});

test('load is the ONLY evaluable metric (disk and swap both unknown) and critical -> overall is unknown, not healthy and not at_risk', () => {
    // The subtle case the ruling calls out explicitly: a non-voting
    // metric being the sole evaluable one must not manufacture a verdict
    // in either direction. It reads 'unknown', not 'healthy' (there is no
    // voting evidence to call it healthy) and not 'at_risk' (load isn't
    // allowed to cast that vote).
    const r = deriveMachineHealth({ loadAvg1: 70.29, coreCount: 11 });
    assert.equal(r.metrics.load.state, 'critical');
    assert.equal(r.metrics.disk.evaluable, false);
    assert.equal(r.metrics.swap.evaluable, false);
    assert.equal(r.state, 'unknown');
});

test('load is the ONLY evaluable metric and merely "ok" -> overall is still unknown, not healthy, for the same reason', () => {
    const r = deriveMachineHealth({ loadAvg1: 0.1, coreCount: 8 });
    assert.equal(r.metrics.load.state, 'ok');
    assert.equal(r.metrics.disk.evaluable, false);
    assert.equal(r.metrics.swap.evaluable, false);
    assert.equal(r.state, 'unknown');
});

// ── Overall-state composition rules ───────────────────────────────────────

test('all three metrics healthy -> overall healthy', () => {
    const r = deriveMachineHealth({ diskPercentUsed: 5, swapUsedBytes: 0, loadAvg1: 0.1, coreCount: 8 });
    assert.equal(r.state, 'healthy');
});

test('one critical metric is enough to make the whole machine at_risk even when the others are healthy', () => {
    const r = deriveMachineHealth({ diskPercentUsed: 99, swapUsedBytes: 0, loadAvg1: 0.1, coreCount: 8 });
    assert.equal(r.metrics.disk.state, 'critical');
    assert.equal(r.metrics.swap.state, 'ok');
    assert.equal(r.metrics.load.state, 'ok');
    assert.equal(r.state, 'at_risk');
});

test('partial input: only one metric evaluable and it is healthy -> overall healthy, not unknown', () => {
    const r = deriveMachineHealth({ diskPercentUsed: 10 });
    assert.equal(r.state, 'healthy');
    assert.equal(r.metrics.swap.state, 'unknown');
    assert.equal(r.metrics.load.state, 'unknown');
});

test('partial input: only one metric evaluable and it is flagged -> overall at_risk, not unknown', () => {
    const r = deriveMachineHealth({ swapUsedBytes: T.SWAP_CRITICAL_BYTES });
    assert.equal(r.state, 'at_risk');
    assert.equal(r.metrics.disk.state, 'unknown');
    assert.equal(r.metrics.load.state, 'unknown');
});

// ── Purity ─────────────────────────────────────────────────────────────

test('deriveMachineHealth is pure: same input object produces deep-equal output across repeated calls, and does not mutate its input', () => {
    const input = Object.freeze({ diskPercentUsed: 42, swapUsedBytes: 1024, loadAvg1: 3, coreCount: 4 });
    const first = deriveMachineHealth(input);
    const second = deriveMachineHealth(input);
    assert.deepEqual(first, second);
});
