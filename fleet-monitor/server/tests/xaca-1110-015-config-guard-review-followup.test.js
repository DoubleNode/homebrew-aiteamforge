//
//  xaca-1110-015-config-guard-review-followup.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1110-015 (PR #829 review finding): coverage for the loud
 * window.LCARS_DASHBOARD_CONFIG guard added to
 * fleet-monitor/server/public/lcars2/js/lcars-fleet-dashboard-app.js.
 *
 * ── The defect this guard closes ──────────────────────────────────────────
 * Before this fix, if the per-org config script (lcars-<org>-config.js)
 * 404'd or its <script> tag loaded AFTER this one instead of before it
 * (D5/D6), `Object.assign({...defaults}, window.LCARS_DASHBOARD_CONFIG)`
 * silently no-ops (Object.assign ignores an undefined source), leaving
 * `CONFIG.divisions` undefined. `isUnbounded` -- `CONFIG.divisions === null`
 * -- then resolves to `false` (undefined !== null), so filterData() gets
 * ASSIGNED (D1) and, on first call, throws a TypeError on
 * `CONFIG.divisions.includes(...)`. That throw happens inside
 * fetchFleetData()'s try block, whose catch swallows it into
 * `updateConnectionStatus(false)` -- a generic "connection lost" that
 * misdiagnoses a deployment fault (config script order/404) as a network
 * one, with nothing in the console pointing at the real cause.
 *
 * ── What the guard does ────────────────────────────────────────────────────
 * Mirrors the window.LCARS_ORG guard idiom already in this file
 * (getOrganizationGroup()/getGroupColor()): when window.LCARS_DASHBOARD_CONFIG
 * is absent, log a loud, specific console.error naming the real cause, and
 * default CONFIG.divisions to `[]` (not `null`/unbounded -- D5 forbids this
 * module guessing at a per-org division list) so filterData() runs without
 * throwing instead of silently rendering unfiltered data under an undefined
 * dashboard name.
 *
 * ── Route taken ────────────────────────────────────────────────────────────
 * Loads the REAL shipped module via
 * tests/helpers/lcars-fleet-dashboard-jsdom-loader.js's loadDashboardModule()
 * -- same harness XACA-1110-004's differential suite uses -- with NO
 * `configGlobal` supplied, which leaves window.LCARS_DASHBOARD_CONFIG unset
 * in the jsdom window exactly as a 404'd/misordered config script would.
 * console.error is spied at the Node global (not the jsdom window's own
 * console), the same pattern
 * tests/xaca-1100-022-guard-hoisted-single-error.test.js already uses for
 * the sibling window.LCARS_CORE guard in this file's neighborhood.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const {
    loadDashboardModule,
    loadConfigGlobal
} = require('./helpers/lcars-fleet-dashboard-jsdom-loader.js');

const UNIFIED_MODULE_REL_PATH = 'lcars2/js/lcars-fleet-dashboard-app.js';

// Mirrors tests/xaca-1100-022-guard-hoisted-single-error.test.js's
// withCapturedConsoleError() -- captured calls are the EXPECTED diagnostic
// this test exists to assert on, not test-run noise worth printing, so
// nothing is forwarded to the real console.
async function withCapturedConsoleError(fn) {
    const calls = [];
    const orig = console.error;
    console.error = function (...args) { calls.push(args); };
    try {
        const result = await fn();
        return { result, calls };
    } finally {
        console.error = orig;
    }
}

// Values crossing back from the jsdom vm context are a DIFFERENT REALM --
// their Array/Object come from that context's own globals, so
// assert.deepEqual/deepStrictEqual fail on prototype identity even when the
// structure is identical (a documented Node cross-realm gotcha, not a bug in
// the module under test). Re-serializing through THIS realm's JSON
// normalizes both sides onto this realm's Array/Object before comparing.
function toThisRealm(value) {
    return JSON.parse(JSON.stringify(value));
}

function sampleFleetData() {
    return {
        fleet: {
            divisions: {
                academy: { total_sessions: 2 },
                dns: { total_sessions: 1 }
            },
            machines: [
                {
                    machine_id: '00000000-0000-4000-8000-000000000015',
                    hostname: 'guard-test.example.test',
                    status: 'online',
                    sessions: [
                        { division: 'academy' },
                        { division: 'dns' }
                    ]
                }
            ]
        },
        last_update: '2026-09-06T00:00:00.000Z'
    };
}

test('XACA-1110-015: missing window.LCARS_DASHBOARD_CONFIG logs a loud, specific console.error naming the real cause', async () => {
    const { calls } = await withCapturedConsoleError(async () => {
        return loadDashboardModule({ relPath: UNIFIED_MODULE_REL_PATH });
    });

    const configGuardCalls = calls.filter(
        (args) => typeof args[0] === 'string' && args[0].indexOf('[LCARS][config]') === 0
    );
    assert.equal(
        configGuardCalls.length,
        1,
        'expected exactly one [LCARS][config] console.error when window.LCARS_DASHBOARD_CONFIG is absent, got: ' +
            JSON.stringify(calls)
    );
    const message = configGuardCalls[0].join(' ');
    assert.match(
        message,
        /LCARS_DASHBOARD_CONFIG is not set/,
        'the guard must name the actual missing global, not a generic failure'
    );
    assert.match(
        message,
        /lcars-<org>-config\.js.*BEFORE this script/,
        'the guard must point at the real fix (config script load order), not just report a symptom'
    );
});

test('XACA-1110-015: missing config defaults CONFIG.divisions to [] rather than leaving it undefined', async () => {
    const { result } = await withCapturedConsoleError(async () => {
        return loadDashboardModule({ relPath: UNIFIED_MODULE_REL_PATH });
    });
    assert.deepEqual(
        toThisRealm(result.mod.CONFIG.divisions),
        [],
        'CONFIG.divisions must default to [] (fail-safe, not fail-open to unbounded/null) when the config global is absent'
    );
});

test('XACA-1110-015: the exact pre-fix crash path (filterData -> CONFIG.divisions.includes) no longer throws, and no longer silently drops all data without explanation', async () => {
    const { result } = await withCapturedConsoleError(async () => {
        return loadDashboardModule({ relPath: UNIFIED_MODULE_REL_PATH });
    });
    const { mod } = result;

    // Pre-fix, this call threw a TypeError (CONFIG.divisions was
    // undefined), which fetchFleetData()'s catch swallowed into a
    // misleading "connection lost". Proving it no longer throws is the
    // regression test for the defect itself, not just for the log line.
    assert.doesNotThrow(() => {
        mod.filterData(sampleFleetData());
    }, 'filterData() must not throw when CONFIG.divisions was defaulted to [] by the guard');

    const filtered = mod.filterData(sampleFleetData());
    assert.deepEqual(
        toThisRealm(filtered.fleet.divisions),
        {},
        'an empty divisions allowlist must filter out every division (visibly empty), not crash'
    );
    assert.equal(
        filtered.fleet.machines.length,
        0,
        'a machine with no sessions surviving the (empty) allowlist must be filtered out entirely'
    );
});

test('XACA-1110-015 negative control: a real per-org config does NOT trip the guard', async () => {
    const configGlobal = loadConfigGlobal('lcars2/js/lcars-academy-config.js');
    const { result, calls } = await withCapturedConsoleError(async () => {
        return loadDashboardModule({ relPath: UNIFIED_MODULE_REL_PATH, configGlobal: configGlobal });
    });

    const configGuardCalls = calls.filter(
        (args) => typeof args[0] === 'string' && args[0].indexOf('[LCARS][config]') === 0
    );
    assert.equal(
        configGuardCalls.length,
        0,
        'a real, present config must never trip the missing-config guard -- proves the guard is not vacuously always-on'
    );
    assert.deepEqual(
        toThisRealm(result.mod.CONFIG.divisions),
        ['academy'],
        "the real academy config's divisions must pass through untouched, not be overwritten by the guard's [] fallback"
    );
});
