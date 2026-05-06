/**
 * test_cr_metrics.js — Node-native unit tests for lcars-cr-metrics.js
 *
 * XACA-0293-011: Gate 2 — ≥10 named test cases using node:test + node:assert.
 * Validates the gold-standard fixture AND edge cases.
 *
 * Usage:
 *   node --test lcars-ui/tests/test_cr_metrics.js
 *
 * No external dependencies. Node ≥18 required (node:test is built-in).
 */

'use strict';

var test   = require('node:test');
var assert = require('node:assert/strict');
var path   = require('path');

// ─── Load modules ──────────────────────────────────────────────────────────────

var METRICS_PATH = path.join(__dirname, '../js/lcars-cr-metrics.js');
var FIXTURE_PATH = path.join(__dirname, 'fixtures/cr-metrics-fixture.json');

var metrics = require(METRICS_PATH);
var fixture = require(FIXTURE_PATH);

// ─── Helpers ───────────────────────────────────────────────────────────────────

var FLOAT_TOL = 1e-9;

/** Deep-equal comparison with float tolerance and _handcomputed stripping. */
function assertDeepApprox(actual, expected, label) {
    // Strip annotation fields from expected before comparing
    var exp = stripAnnotations(expected);
    var keys = Object.keys(exp);
    for (var i = 0; i < keys.length; i++) {
        var k = keys[i];
        var ev = exp[k];
        var av = actual[k];
        if (ev === null && av === null) { continue; }
        if (typeof ev === 'number' && typeof av === 'number') {
            assert.ok(
                Math.abs(av - ev) <= FLOAT_TOL,
                (label || '') + ' field=' + k + ' actual=' + av + ' expected=' + ev
            );
        } else {
            assert.deepStrictEqual(av, ev, (label || '') + ' field=' + k);
        }
    }
}

/** Remove keys starting with '_' (annotation fields in fixture). */
function stripAnnotations(obj) {
    if (!obj || typeof obj !== 'object') { return obj; }
    var out = {};
    var keys = Object.keys(obj);
    for (var i = 0; i < keys.length; i++) {
        if (keys[i].charAt(0) !== '_') {
            out[keys[i]] = obj[keys[i]];
        }
    }
    return out;
}

/** Build an index of fixture CRs by id for fast lookup. */
function buildCrIndex(crs) {
    var idx = {};
    for (var i = 0; i < crs.length; i++) {
        idx[crs[i].id] = crs[i];
    }
    return idx;
}

var crIndex = buildCrIndex(fixture.crs);

// Rollup opts from fixture metadata
var FIXTURE_OPTS = {
    now:        fixture._meta.now_ms,
    windowDays: fixture._meta.window_days,
};

// ─── Test 1: CR-FIXTURE-001 Happy path — all 8 derived fields ─────────────────

test('derivePerCR: CR-FIXTURE-001 happy path — all segments 2.0 days, delta=0.0', function () {
    var cr = crIndex['CR-FIXTURE-001'];
    var actual = metrics.derivePerCR(cr);
    assertDeepApprox(actual, fixture.expected_per_cr['CR-FIXTURE-001'], 'CR-FIXTURE-001');
});

// ─── Test 2: CR-FIXTURE-002 Missing timestamps — nulls where expected ─────────

test('derivePerCR: CR-FIXTURE-002 missing dev/test timestamps produce null segments', function () {
    var cr = crIndex['CR-FIXTURE-002'];
    var actual = metrics.derivePerCR(cr);
    assertDeepApprox(actual, fixture.expected_per_cr['CR-FIXTURE-002'], 'CR-FIXTURE-002');
    // Explicit null assertions for the null segments
    assert.strictEqual(actual.cr_cycle_approve_to_dev_days, null);
    assert.strictEqual(actual.cr_cycle_dev_to_test_days, null);
    assert.strictEqual(actual.cr_cycle_test_to_deploydev_days, null);
    // deploy_estimate_delta positive (LATE)
    assert.ok(actual.deploy_estimate_delta_days > 1, 'delta should be LATE (> +1)');
});

// ─── Test 3: CR-FIXTURE-003 Emergency path — anchor = cr_emergency_deployed_at

test('derivePerCR: CR-FIXTURE-003 emergency path — most fields null, delta null', function () {
    var cr = crIndex['CR-FIXTURE-003'];
    var actual = metrics.derivePerCR(cr);
    assertDeepApprox(actual, fixture.expected_per_cr['CR-FIXTURE-003'], 'CR-FIXTURE-003');
    // Emergency CR: no planned window, no prod deploy → delta must be null
    assert.strictEqual(actual.deploy_estimate_delta_days, null);
    assert.strictEqual(actual.cr_cycle_total_days, null);
});

// ─── Test 4: CR-FIXTURE-004 Out-of-window — derivePerCR still computes values ─

test('derivePerCR: CR-FIXTURE-004 out-of-window CR still derives values correctly', function () {
    var cr = crIndex['CR-FIXTURE-004'];
    var actual = metrics.derivePerCR(cr);
    assertDeepApprox(actual, fixture.expected_per_cr['CR-FIXTURE-004'], 'CR-FIXTURE-004');
    // All segments present for this CR
    assert.ok(actual.cr_cycle_total_days !== null, 'cr_cycle_total_days should not be null');
    assert.ok(actual.deploy_estimate_delta_days !== null, 'delta should not be null');
});

// ─── Test 5: CR-FIXTURE-005 Early delivery — delta = -3.0 (EARLY) ─────────────

test('derivePerCR: CR-FIXTURE-005 early delivery delta=-3.0 classified EARLY', function () {
    var cr = crIndex['CR-FIXTURE-005'];
    var actual = metrics.derivePerCR(cr);
    assertDeepApprox(actual, fixture.expected_per_cr['CR-FIXTURE-005'], 'CR-FIXTURE-005');
    assert.ok(actual.deploy_estimate_delta_days < -1, 'delta must be < -1 to be EARLY');
});

// ─── Test 6: CR-FIXTURE-006 Boundary hit — delta = +0.5, deploydev_to_prod=0.5 days ─

test('derivePerCR: CR-FIXTURE-006 boundary hit delta=+0.5, deploydev_to_prod=0.5', function () {
    var cr = crIndex['CR-FIXTURE-006'];
    var actual = metrics.derivePerCR(cr);
    assertDeepApprox(actual, fixture.expected_per_cr['CR-FIXTURE-006'], 'CR-FIXTURE-006');
    // deploydev_to_deployprod = 12 hours = 0.5 days (sub-day precision)
    assert.ok(
        Math.abs(actual.cr_cycle_deploydev_to_deployprod_days - 0.5) <= FLOAT_TOL,
        'deploydev_to_deployprod should be exactly 0.5'
    );
    // delta = 0.5 => abs <= 1 => HIT
    assert.ok(Math.abs(actual.deploy_estimate_delta_days) <= 1, 'delta 0.5 must classify as HIT');
});

// ─── Test 7: rollupAll — full fixture rollup matches expected_rollups ─────────

test('rollupAll: fixture rollup — all 7 segments + estimateDelta match expected', function () {
    var actual = metrics.rollupAll(fixture.crs, FIXTURE_OPTS);
    var SEGMENT_KEYS = [
        'cr_cycle_draft_to_submit_days',
        'cr_cycle_submit_to_approve_days',
        'cr_cycle_approve_to_dev_days',
        'cr_cycle_dev_to_test_days',
        'cr_cycle_test_to_deploydev_days',
        'cr_cycle_deploydev_to_deployprod_days',
        'cr_cycle_total_days',
    ];
    var expRollups = fixture.expected_rollups;

    for (var i = 0; i < SEGMENT_KEYS.length; i++) {
        var sk = SEGMENT_KEYS[i];
        var actSeg = actual[sk];
        var expSeg = stripAnnotations(expRollups[sk]);
        assert.ok(
            Math.abs(actSeg.avg - expSeg.avg) <= FLOAT_TOL,
            sk + '.avg: actual=' + actSeg.avg + ' expected=' + expSeg.avg
        );
        assert.ok(
            Math.abs(actSeg.median - expSeg.median) <= FLOAT_TOL,
            sk + '.median: actual=' + actSeg.median + ' expected=' + expSeg.median
        );
        assert.strictEqual(actSeg.sampleCount, expSeg.sampleCount, sk + '.sampleCount');
    }

    // estimateDelta
    var actEst = actual.estimateDelta;
    var expEst = stripAnnotations(expRollups.estimateDelta);
    assert.ok(Math.abs(actEst.avg - expEst.avg) <= FLOAT_TOL, 'estimateDelta.avg');
    assert.strictEqual(actEst.sampleCount, expEst.sampleCount, 'estimateDelta.sampleCount');
    assert.strictEqual(actEst.hits, expEst.hits, 'estimateDelta.hits');
    assert.strictEqual(actEst.earlies, expEst.earlies, 'estimateDelta.earlies');
    assert.strictEqual(actEst.lates, expEst.lates, 'estimateDelta.lates');
    assert.ok(Math.abs(actEst.hitPct - expEst.hitPct) <= FLOAT_TOL, 'estimateDelta.hitPct');
    assert.ok(Math.abs(actEst.earlyPct - expEst.earlyPct) <= FLOAT_TOL, 'estimateDelta.earlyPct');
    assert.ok(Math.abs(actEst.latePct - expEst.latePct) <= FLOAT_TOL, 'estimateDelta.latePct');
});

// ─── Test 8: Edge case — empty array input ─────────────────────────────────────

test('edge: empty array → all rollup fields return null / sampleCount 0', function () {
    var result = metrics.rollupAll([], FIXTURE_OPTS);
    // All 7 segment rollups should have null avg/median and 0 sampleCount
    var SEGMENT_KEYS = [
        'cr_cycle_draft_to_submit_days',
        'cr_cycle_submit_to_approve_days',
        'cr_cycle_approve_to_dev_days',
        'cr_cycle_dev_to_test_days',
        'cr_cycle_test_to_deploydev_days',
        'cr_cycle_deploydev_to_deployprod_days',
        'cr_cycle_total_days',
    ];
    for (var i = 0; i < SEGMENT_KEYS.length; i++) {
        var r = result[SEGMENT_KEYS[i]];
        assert.strictEqual(r.avg, null, SEGMENT_KEYS[i] + '.avg should be null for empty input');
        assert.strictEqual(r.median, null, SEGMENT_KEYS[i] + '.median should be null for empty input');
        assert.strictEqual(r.sampleCount, 0, SEGMENT_KEYS[i] + '.sampleCount should be 0 for empty input');
    }
    assert.strictEqual(result.estimateDelta.avg, null, 'estimateDelta.avg should be null for empty');
    assert.strictEqual(result.estimateDelta.sampleCount, 0, 'estimateDelta.sampleCount should be 0 for empty');
});

// ─── Test 9: Edge case — all-null timestamps ──────────────────────────────────

test('edge: all-null timestamps → derivePerCR returns all-null derived fields', function () {
    var cr = {
        id: 'CR-ALLNULL',
        timestamps: {
            cr_created_at:            null,
            cr_submitted_at:          null,
            cr_approved_at:           null,
            cr_dev_started_at:        null,
            cr_testing_started_at:    null,
            cr_deployed_dev_at:       null,
            cr_deployed_prod_at:      null,
            cr_completed_at:          null,
            cr_emergency_deployed_at: null,
        },
        deploy_window_planned: null,
    };
    var actual = metrics.derivePerCR(cr);
    var DERIVED_KEYS = [
        'cr_cycle_draft_to_submit_days',
        'cr_cycle_submit_to_approve_days',
        'cr_cycle_approve_to_dev_days',
        'cr_cycle_dev_to_test_days',
        'cr_cycle_test_to_deploydev_days',
        'cr_cycle_deploydev_to_deployprod_days',
        'cr_cycle_total_days',
        'deploy_estimate_delta_days',
    ];
    for (var i = 0; i < DERIVED_KEYS.length; i++) {
        assert.strictEqual(actual[DERIVED_KEYS[i]], null,
            DERIVED_KEYS[i] + ' must be null when all timestamps are null');
    }
});

// ─── Test 10: Edge case — single CR rollup ─────────────────────────────────────

test('edge: single CR in window → rollup sampleCount=1, avg=median=that value', function () {
    // Use CR-FIXTURE-001 alone (all timestamps present, clean 2.0 day segments)
    var cr001 = crIndex['CR-FIXTURE-001'];
    // now_ms points to just after cr_completed_at so it's in a 14-day window
    var now = fixture._meta.now_ms;  // 2026-05-06T12:00:00Z; CR-FIXTURE-001 completed 2026-05-04T12:00Z (2 days before now)
    var opts = { now: now, windowDays: 14 };

    var result = metrics.rollupSegment([cr001], 'cr_cycle_draft_to_submit_days', opts);
    assert.strictEqual(result.sampleCount, 1, 'sampleCount should be 1');
    // For a single value, avg === median === value
    assert.ok(Math.abs(result.avg - 2.0) <= FLOAT_TOL, 'avg should be 2.0');
    assert.ok(Math.abs(result.median - 2.0) <= FLOAT_TOL, 'median should be 2.0');
});

// ─── Test 11: Edge case — custom windowDays excludes CR ──────────────────────

test('edge: custom window=1 day excludes all fixture CRs completed more than 1 day ago', function () {
    // now = 2026-05-06T12:00:00Z; only a CR completed within 1 day of now would be included
    // CR-FIXTURE-006 completed 2026-05-05T12:00:00Z → 1.0 day before now → exactly at boundary
    // The boundary check is anchorMs >= cutoff (>=), so 1.0 day ago at cutoff=1d is INCLUDED
    var opts = { now: fixture._meta.now_ms, windowDays: 1 };
    var result = metrics.rollupSegment(fixture.crs, 'cr_cycle_total_days', opts);
    // CR-FIXTURE-006 completed at 2026-05-05T12:00:00Z (cr_completed_at) — that is exactly 1 day
    // before now_ms, so it falls exactly on the cutoff boundary and should be included.
    // All other in-window CRs have completed > 1 day before now.
    assert.strictEqual(result.sampleCount, 1, 'only 1 CR within 1-day window');
    assert.ok(Math.abs(result.avg - 11.0) <= FLOAT_TOL, 'CR-006 total_days=11.0');
});

// ─── Test 12: Edge case — now parameter override ───────────────────────────────

test('edge: now parameter override — shifting now excludes all CRs from window', function () {
    // Set now to 2020-01-01 — all fixture CRs are in the future from that vantage point
    // so none will have an anchor within the rolling window
    var ancientNow = Date.parse('2020-01-01T00:00:00Z');
    var opts = { now: ancientNow, windowDays: 14 };
    var result = metrics.rollupAll(fixture.crs, opts);
    assert.strictEqual(result.cr_cycle_total_days.sampleCount, 0,
        'no CRs in window when now is before all fixture timestamps');
    assert.strictEqual(result.estimateDelta.sampleCount, 0,
        'estimateDelta sampleCount should be 0 with ancient now');
});

// ─── Test 13: Edge case — invalid/null CR input to derivePerCR ────────────────

test('edge: null/invalid CR input → derivePerCR returns all-null object without throwing', function () {
    // Null input
    var nullResult = metrics.derivePerCR(null);
    assert.strictEqual(nullResult.cr_cycle_total_days, null, 'null input → total_days null');
    assert.strictEqual(nullResult.deploy_estimate_delta_days, null, 'null input → delta null');

    // Non-object input
    var strResult = metrics.derivePerCR('not-an-object');
    assert.strictEqual(strResult.cr_cycle_total_days, null, 'string input → total_days null');

    // Empty object (no timestamps field)
    var emptyResult = metrics.derivePerCR({});
    assert.strictEqual(emptyResult.cr_cycle_total_days, null, 'empty object → total_days null');
    assert.strictEqual(emptyResult.deploy_estimate_delta_days, null, 'empty object → delta null');
});

// ─── Test 14: rollupEstimateDelta — hit/early/late classification ─────────────

test('rollupEstimateDelta: hit/early/late counts and percentages from fixture', function () {
    var result = metrics.rollupEstimateDelta(fixture.crs, FIXTURE_OPTS);
    // From fixture: 4 samples (001=HIT, 002=LATE, 005=EARLY, 006=HIT); 003 excluded (null delta)
    assert.strictEqual(result.sampleCount, 4, 'sampleCount=4');
    assert.strictEqual(result.hits, 2, 'hits=2 (001 and 006)');
    assert.strictEqual(result.earlies, 1, 'earlies=1 (005)');
    assert.strictEqual(result.lates, 1, 'lates=1 (002)');
    assert.ok(Math.abs(result.hitPct - 50.0) <= FLOAT_TOL, 'hitPct=50.0');
    assert.ok(Math.abs(result.earlyPct - 25.0) <= FLOAT_TOL, 'earlyPct=25.0');
    assert.ok(Math.abs(result.latePct - 25.0) <= FLOAT_TOL, 'latePct=25.0');
    // avg delta = (-3.0 + 0.0 + 0.5 + 3.0) / 4 = 0.5 / 4 = 0.125
    assert.ok(Math.abs(result.avg - 0.125) <= FLOAT_TOL, 'avg=0.125');
});

// ─── Test 15: CR-FIXTURE-004 excluded from rollup but derivePerCR works ───────

test('rollup: CR-FIXTURE-004 out-of-window is excluded from sampleCount', function () {
    // If we use only CR-FIXTURE-004 (completed T-30d), it should produce sampleCount=0
    // in the 14-day window rollup
    var cr004 = crIndex['CR-FIXTURE-004'];
    var opts = { now: fixture._meta.now_ms, windowDays: 14 };
    var result = metrics.rollupSegment([cr004], 'cr_cycle_total_days', opts);
    assert.strictEqual(result.sampleCount, 0,
        'CR-004 completed 30 days ago → excluded from 14-day window → sampleCount=0');
    assert.strictEqual(result.avg, null, 'avg null when sampleCount=0');
    assert.strictEqual(result.median, null, 'median null when sampleCount=0');
});
