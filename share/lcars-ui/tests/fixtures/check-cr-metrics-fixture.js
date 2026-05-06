/**
 * check-cr-metrics-fixture.js — Smoke test for lcars-cr-metrics.js
 *
 * XACA-0293-006: Validates that lcars-cr-metrics.js output matches the
 * hand-computed expected values in cr-metrics-fixture.json.
 *
 * Usage:
 *   node lcars-ui/tests/fixtures/check-cr-metrics-fixture.js
 *
 * Exit code 0 = all checks pass.
 * Exit code 1 = one or more mismatches found (diff printed to stdout).
 *
 * This is a diagnostic tool, NOT a test framework.
 * The proper test suite lives in XACA-0293-011.
 */

'use strict';

var path = require('path');
var fs   = require('fs');

// ─── Load modules ─────────────────────────────────────────────────────────────

var fixtureFile = path.join(__dirname, 'cr-metrics-fixture.json');
var moduleFile  = path.join(__dirname, '../../js/lcars-cr-metrics.js');

if (!fs.existsSync(fixtureFile)) {
    console.error('FATAL: fixture not found at', fixtureFile);
    process.exit(1);
}
if (!fs.existsSync(moduleFile)) {
    console.error('FATAL: module not found at', moduleFile);
    process.exit(1);
}

var fixture = JSON.parse(fs.readFileSync(fixtureFile, 'utf8'));
var metrics = require(moduleFile);

// ─── Comparison helpers ────────────────────────────────────────────────────────

var FLOAT_TOLERANCE = 1e-9;

/**
 * Compare two values for equality.
 * - null === null
 * - numbers compared within floating-point tolerance
 * - other types use strict equality
 */
function valuesMatch(actual, expected) {
    if (expected === null && actual === null) { return true; }
    if (expected === null || actual === null) { return false; }
    if (typeof expected === 'number' && typeof actual === 'number') {
        return Math.abs(actual - expected) <= FLOAT_TOLERANCE;
    }
    return actual === expected;
}

var failures = [];

function fail(location, field, actual, expected) {
    failures.push({
        location: location,
        field:    field,
        actual:   actual,
        expected: expected,
    });
}

// ─── Part 1: derivePerCR per-CR checks ────────────────────────────────────────

var DERIVED_FIELDS = [
    'cr_cycle_draft_to_submit_days',
    'cr_cycle_submit_to_approve_days',
    'cr_cycle_approve_to_dev_days',
    'cr_cycle_dev_to_test_days',
    'cr_cycle_test_to_deploydev_days',
    'cr_cycle_deploydev_to_deployprod_days',
    'cr_cycle_total_days',
    'deploy_estimate_delta_days',
];

console.log('=== Part 1: derivePerCR per-CR checks ===');

var crIndex = {};
for (var i = 0; i < fixture.crs.length; i++) {
    crIndex[fixture.crs[i].id] = fixture.crs[i];
}

var perCrExpected = fixture.expected_per_cr;
var crIds = Object.keys(perCrExpected);

for (var c = 0; c < crIds.length; c++) {
    var crId = crIds[c];
    var cr   = crIndex[crId];
    if (!cr) {
        fail('derivePerCR', crId, 'MISSING CR in crs[]', '(CR record present)');
        continue;
    }

    var actual   = metrics.derivePerCR(cr);
    var expected = perCrExpected[crId];

    for (var f = 0; f < DERIVED_FIELDS.length; f++) {
        var field = DERIVED_FIELDS[f];
        // skip _handcomputed metadata keys
        if (field.charAt(0) === '_') { continue; }
        if (!valuesMatch(actual[field], expected[field])) {
            fail('derivePerCR[' + crId + ']', field, actual[field], expected[field]);
        }
    }

    var status = 'PASS';
    // Check if any failure was added for this CR in the most recent iteration
    if (failures.length > 0 && failures[failures.length - 1].location.indexOf(crId) !== -1) {
        status = 'FAIL';
    }
    console.log('  ' + crId + ': ' + status);
}

// ─── Part 2: rollupAll aggregate checks ───────────────────────────────────────

console.log('\n=== Part 2: rollupAll aggregate checks ===');

var opts = {
    now:        fixture._meta.now_ms,
    windowDays: fixture._meta.window_days,
};

var rollupActual   = metrics.rollupAll(fixture.crs, opts);
var rollupExpected = fixture.expected_rollups;

var SEGMENT_KEYS = [
    'cr_cycle_draft_to_submit_days',
    'cr_cycle_submit_to_approve_days',
    'cr_cycle_approve_to_dev_days',
    'cr_cycle_dev_to_test_days',
    'cr_cycle_test_to_deploydev_days',
    'cr_cycle_deploydev_to_deployprod_days',
    'cr_cycle_total_days',
];

for (var s = 0; s < SEGMENT_KEYS.length; s++) {
    var segKey = SEGMENT_KEYS[s];
    var actSeg = rollupActual[segKey]   || {};
    var expSeg = rollupExpected[segKey] || {};
    var segFail = false;

    if (!valuesMatch(actSeg.avg, expSeg.avg)) {
        fail('rollupAll[' + segKey + ']', 'avg', actSeg.avg, expSeg.avg);
        segFail = true;
    }
    if (!valuesMatch(actSeg.median, expSeg.median)) {
        fail('rollupAll[' + segKey + ']', 'median', actSeg.median, expSeg.median);
        segFail = true;
    }
    if (!valuesMatch(actSeg.sampleCount, expSeg.sampleCount)) {
        fail('rollupAll[' + segKey + ']', 'sampleCount', actSeg.sampleCount, expSeg.sampleCount);
        segFail = true;
    }
    console.log('  ' + segKey + ': ' + (segFail ? 'FAIL' : 'PASS'));
}

// estimateDelta
var ESTIMATE_DELTA_FIELDS = ['avg', 'sampleCount', 'hits', 'earlies', 'lates', 'hitPct', 'earlyPct', 'latePct'];
var actEst = rollupActual.estimateDelta   || {};
var expEst = rollupExpected.estimateDelta || {};
var estFail = false;

for (var e = 0; e < ESTIMATE_DELTA_FIELDS.length; e++) {
    var ef = ESTIMATE_DELTA_FIELDS[e];
    if (!valuesMatch(actEst[ef], expEst[ef])) {
        fail('rollupAll[estimateDelta]', ef, actEst[ef], expEst[ef]);
        estFail = true;
    }
}
console.log('  estimateDelta: ' + (estFail ? 'FAIL' : 'PASS'));

// ─── Summary ──────────────────────────────────────────────────────────────────

console.log('\n=== Summary ===');

if (failures.length === 0) {
    console.log('ALL CHECKS PASSED. Fixture math aligns with lcars-cr-metrics.js output.');
    process.exit(0);
} else {
    console.log('FAILURES (' + failures.length + '):');
    for (var fail_i = 0; fail_i < failures.length; fail_i++) {
        var fl = failures[fail_i];
        console.log(
            '  [' + fl.location + '] ' + fl.field +
            '\n    actual:   ' + JSON.stringify(fl.actual) +
            '\n    expected: ' + JSON.stringify(fl.expected)
        );
    }
    process.exit(1);
}
