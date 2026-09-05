//
//  xaca-1091-005-006-telemetry-store-and-projection.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1091 subitems 005 (store) and 006 (projection) -- regression coverage
 * for the telemetry leaves added to the machine-level `system` block by
 * this ticket, per the frozen contract at
 * kanban/plans/XACA-1091/CONTRACT-system-block.md.
 *
 * ── Why this suite exists as a SEPARATE file from xaca-1031-007 ───────────
 * xaca-1031-007-system-block.test.js covers XACA-1031's `schema_version` /
 * `versions` slice of the same block and MUST NOT be touched here (its
 * behavior is preserved byte-for-byte -- see xaca-1031-007-mirror-drift-
 * guard.test.js, which still passes unmodified). This file covers only the
 * NEW telemetry leaves this ticket adds to the SAME normalizeSystemBlock()/
 * projectSystemBlock() functions (one normalize step, one allowlist, per
 * EPIC-0061 Design Decision 8 -- there is no second function to test).
 *
 * ── The nested-allowlist trap this suite exists to catch ──────────────────
 * projectSystemBlock() had its own early return: `if (!hasStoredVersions)
 * return out;`, which sat BEFORE any telemetry field would have been added.
 * A test that only exercises normalizeSystemBlock() (the store half) would
 * stay green forever even if that early return were never fixed -- the data
 * would sit in server memory looking present and never reach /api/fleet.
 * The "end-to-end" test below is the one assertion that actually catches
 * this: it round-trips through POST /api/status -> GET /api/fleet and reads
 * the raw HTTP response body, never server-side state directly (same
 * discipline as xaca-1031-007-system-block.test.js's own allowlist test).
 * The negative-control test after it proves that assertion is load-bearing
 * by running the SAME input through the pre-fix shape of projectSystemBlock
 * and showing every telemetry assertion would have failed.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const { createApp, helpers } = require('./helpers/app-factory.js');

const { normalizeSystemBlock, isVersionOutdated } = helpers;

const TEST_MACHINE_GUID = 'cccccccc-dddd-4eee-8fff-000000000001';

function baseMachine(overrides) {
    return Object.assign(
        {
            machine_id: TEST_MACHINE_GUID,
            hostname: 'runabout',
            ip: '10.0.0.5',
            os: 'Darwin'
        },
        overrides
    );
}

// The full contract example, kanban/plans/XACA-1091/CONTRACT-system-block.md
// §1 -- exactly what a reporter sends (note: NO `versions.latest`/
// `versions.outdated` -- contract §3a is explicit those never appear on the
// wire, only server-injected at /api/fleet read time).
const FULL_REPORTER_SYSTEM_PAYLOAD = {
    schema_version: 1,
    versions: { aiteamforge: '0.17.8' },
    os_version: '27.0',
    os_build: '26A5388g',
    os_name: 'macOS',
    model: 'Mac15,6',
    arch: 'arm64',
    cores: 11,
    total_ram: 19327352832,
    boot_time: 1787581393,
    memory: { used: 12884901888, total: 19327352832, pressure_percent: 67 },
    swap_used_bytes: 21949317120,
    disk: { used: 25044885504, free: 76291256320, percent: 25 },
    load_average: [26.62, 31.34, 33.51]
};

// Every XACA-1091-owned leaf, expressed as `[path, expectedValue]` so the
// e2e test (and the negative control mirroring it) can walk the same list
// instead of hand-writing 15 separate assert calls that could silently
// drift apart from each other.
const TELEMETRY_LEAVES = [
    ['os_version', '27.0'],
    ['os_build', '26A5388g'],
    ['os_name', 'macOS'],
    ['model', 'Mac15,6'],
    ['arch', 'arm64'],
    ['cores', 11],
    ['total_ram', 19327352832],
    ['boot_time', 1787581393],
    ['memory.used', 12884901888],
    ['memory.total', 19327352832],
    ['memory.pressure_percent', 67],
    ['swap_used_bytes', 21949317120],
    ['disk.used', 25044885504],
    ['disk.free', 76291256320],
    ['disk.percent', 25],
    ['load_average', [26.62, 31.34, 33.51]]
];

function getPath(obj, dottedPath) {
    return dottedPath.split('.').reduce((acc, key) => (acc == null ? acc : acc[key]), obj);
}

// ============================================================================
// normalizeSystemBlock() -- store side (XACA-1091-005), unit-level
// ============================================================================

test('normalizeSystemBlock: every XACA-1091 telemetry leaf passes through when collected', () => {
    const out = normalizeSystemBlock(FULL_REPORTER_SYSTEM_PAYLOAD);
    for (const [path, expected] of TELEMETRY_LEAVES) {
        assert.deepEqual(getPath(out, path), expected, `expected ${path} == ${JSON.stringify(expected)} in stored block`);
    }
});

test('normalizeSystemBlock: whole `system` block absent still normalizes to {} with the new leaves in play (old-reporter case, no crash)', () => {
    assert.deepEqual(normalizeSystemBlock(undefined), {});
    assert.deepEqual(normalizeSystemBlock(null), {});
});

test('normalizeSystemBlock: a collected zero survives -- swap_used_bytes:0 and memory.pressure_percent:0 are DATA, not absence', () => {
    const out = normalizeSystemBlock({
        schema_version: 1,
        versions: {},
        swap_used_bytes: 0,
        memory: { used: 1000, total: 2000, pressure_percent: 0 }
        // disk deliberately omitted -- contrast case: "collection failed"
        // must not render identically to "nothing to report".
    });
    assert.equal(Object.prototype.hasOwnProperty.call(out, 'swap_used_bytes'), true, 'swap_used_bytes:0 must be a present key');
    assert.equal(out.swap_used_bytes, 0);
    assert.equal(Object.prototype.hasOwnProperty.call(out.memory, 'pressure_percent'), true, 'pressure_percent:0 must be a present key');
    assert.equal(out.memory.pressure_percent, 0);
    assert.equal(Object.prototype.hasOwnProperty.call(out, 'disk'), false, 'disk must be OMITTED wholesale, not present-but-empty');
});

test('normalizeSystemBlock: malformed leaves are omitted, never passed through or coerced', () => {
    const out = normalizeSystemBlock({
        schema_version: 1,
        versions: {},
        cores: 'eleven', // string where a number belongs
        total_ram: 'lots', // string where a number belongs
        os_version: 42, // number where a string belongs
        load_average: [1.0, 2.0], // only 2 elements, not 3
        memory: 'not-an-object', // non-object where an object belongs
        disk: { used: '25GB', free: 76291256320, percent: 25 } // one bad leaf inside an otherwise-good object
    });
    assert.equal(Object.prototype.hasOwnProperty.call(out, 'cores'), false);
    assert.equal(Object.prototype.hasOwnProperty.call(out, 'total_ram'), false);
    assert.equal(Object.prototype.hasOwnProperty.call(out, 'os_version'), false);
    assert.equal(Object.prototype.hasOwnProperty.call(out, 'load_average'), false);
    assert.equal(Object.prototype.hasOwnProperty.call(out, 'memory'), false, 'a non-object memory must be omitted wholesale');
    // disk itself still ships (free/percent were valid) but the malformed
    // leaf inside it is dropped rather than passed through as a string.
    assert.equal(Object.prototype.hasOwnProperty.call(out.disk, 'used'), false);
    assert.equal(out.disk.free, 76291256320);
    assert.equal(out.disk.percent, 25);
});

test('normalizeSystemBlock: a non-object `system` (corrupted payload) normalizes to {}, never throws', () => {
    assert.deepEqual(normalizeSystemBlock('corrupted-string-payload'), {});
    assert.deepEqual(normalizeSystemBlock(42), {});
    assert.deepEqual(normalizeSystemBlock([1, 2, 3]), {});
});

// ============================================================================
// POST /api/status -> GET /api/fleet round trip (XACA-1091-006, the test
// that actually catches the nested-allowlist bug -- constraint: assert
// against the raw HTTP response body, never server-side state)
// ============================================================================

test('END-TO-END: a full reporter payload posted to /api/status has EVERY telemetry key survive to GET /api/fleet', async () => {
    const machines = new Map();
    const { app } = createApp({ machines, latestTapVersion: '0.17.9' });

    const postRes = await request(app)
        .post('/api/status')
        .send({ machine: baseMachine(), sessions: [], system: FULL_REPORTER_SYSTEM_PAYLOAD });
    assert.equal(postRes.status, 200);

    const fleetRes = await request(app).get('/api/fleet');
    assert.equal(fleetRes.status, 200);
    const machine = fleetRes.body.fleet.machines.find((m) => m.machine_id === TEST_MACHINE_GUID);
    assert.ok(machine, 'expected the machine in the raw /api/fleet response body');

    for (const [path, expected] of TELEMETRY_LEAVES) {
        assert.deepEqual(getPath(machine.system, path), expected,
            `${path} did not survive store -> projection -> /api/fleet (expected ${JSON.stringify(expected)})`);
    }

    // XACA-1031's own version fields must still be correct alongside the
    // new telemetry -- this ticket ADDS siblings, it does not touch them.
    assert.equal(machine.system.versions.aiteamforge, '0.17.8');
    assert.equal(machine.system.versions.latest, '0.17.9');
    assert.equal(machine.system.versions.outdated, true);
});

// ============================================================================
// NEGATIVE CONTROL: proves the end-to-end assertion above is load-bearing.
// Runs the identical stored record through the PRE-FIX shape of
// projectSystemBlock() (the one with the early `if (!hasStoredVersions)
// return out;` that this ticket's -006 subitem removed) and shows every
// telemetry assertion the e2e test makes would have FAILED against it.
// ============================================================================

// Deliberately preserved here ONLY as a fossil of the bug this ticket fixed
// -- never resync this with server.js/app-factory.js's real
// projectSystemBlock(). It exists specifically to keep failing.
function preFixProjectSystemBlock(storedSystem, getLatestTapVersionFn) {
    const out = {};
    if (storedSystem && Number.isInteger(storedSystem.schema_version)) {
        out.schema_version = storedSystem.schema_version;
    }

    const hasStoredVersions = !!(storedSystem && storedSystem.versions && typeof storedSystem.versions === 'object');
    if (!hasStoredVersions) return out; // the bug: nothing telemetry-related is ever reached below this line

    const storedAiteamforge = (typeof storedSystem.versions.aiteamforge === 'string' && storedSystem.versions.aiteamforge)
        ? storedSystem.versions.aiteamforge
        : null;

    const versions = {};
    if (storedAiteamforge) {
        versions.aiteamforge = storedAiteamforge;
        const latest = getLatestTapVersionFn();
        if (latest) {
            versions.latest = latest;
        }
    }
    out.versions = versions;

    // NOTE: no telemetry fields exist in this pre-fix shape at all -- this
    // function predates XACA-1091-006 entirely, matching what shipped when
    // XACA-1031 merged.
    return out;
}

test('NEGATIVE CONTROL: the pre-fix projectSystemBlock shape drops every telemetry key -- proves the e2e assertion is not vacuous', () => {
    const stored = normalizeSystemBlock(FULL_REPORTER_SYSTEM_PAYLOAD); // real store-side function -- unaffected by this control
    const projected = preFixProjectSystemBlock(stored, () => '0.17.9');

    // Sanity: the pre-fix function still does its OWN (XACA-1031) job
    // correctly, so this control isolates the telemetry regression alone
    // rather than a wholesale broken projection.
    assert.equal(projected.versions.aiteamforge, '0.17.8');

    // Every one of these is an assertion the e2e test above makes against
    // the REAL projectSystemBlock. Against the pre-fix shape, all of them
    // fail -- which is the point: it proves the e2e test would have caught
    // this exact regression had it shipped.
    assert.throws(() => {
        for (const [path] of TELEMETRY_LEAVES) {
            assert.ok(
                getPath(projected, path) !== undefined,
                `${path} is undefined in the pre-fix projection -- telemetry silently dropped`
            );
        }
    }, assert.AssertionError, 'expected the pre-fix projectSystemBlock to fail the telemetry-survival assertions');
});

// ============================================================================
// The early-return trap named explicitly in the ticket: `versions` absent
// from the STORED record (not merely empty) must not block telemetry.
// ============================================================================

test('projectSystemBlock: telemetry ships even when the stored record has no `versions` key at all (the early-return trap)', () => {
    const machines = new Map();
    const { projectSystemBlock } = createApp({ machines, latestTapVersion: '0.17.9' });

    const storedSystem = {
        schema_version: 1,
        // no `versions` key at all -- simulates a pre-XACA-1091 (but
        // post-XACA-1031) stored record, or any future path that produces a
        // `system` object without a `versions` sub-object.
        os_version: '27.0',
        cores: 11,
        memory: { used: 100, total: 200, pressure_percent: 50 }
    };

    const projected = projectSystemBlock(storedSystem);
    assert.equal(Object.prototype.hasOwnProperty.call(projected, 'versions'), false,
        'no versions key was stored, so none should be invented');
    assert.equal(projected.os_version, '27.0');
    assert.equal(projected.cores, 11);
    assert.equal(projected.memory.pressure_percent, 50);
});

// ============================================================================
// Old-reporter case through the full route -- stable {} shape, no crash,
// no telemetry leakage from `undefined`.
// ============================================================================

test('POST /api/status with no `system` key at all -- GET /api/fleet shows {} with no telemetry keys and no undefined leakage', async () => {
    const machines = new Map();
    const { app } = createApp({ machines });

    const postRes = await request(app)
        .post('/api/status')
        .send({ machine: baseMachine({ machine_id: 'dddddddd-eeee-4fff-8000-111111111112' }), sessions: [] });
    assert.equal(postRes.status, 200);

    const fleetRes = await request(app).get('/api/fleet');
    const machine = fleetRes.body.fleet.machines.find((m) => m.machine_id === 'dddddddd-eeee-4fff-8000-111111111112');
    assert.ok(machine);
    assert.deepEqual(machine.system, {});
    for (const [path] of TELEMETRY_LEAVES) {
        assert.equal(getPath(machine.system, path), undefined, `${path} must not appear on an old-reporter machine`);
    }
});

// ============================================================================
// Zero/false preservation through the FULL route (store -> project -> HTTP),
// not just the unit-level normalizeSystemBlock check above.
// ============================================================================

test('END-TO-END: swap_used_bytes:0 and memory.pressure_percent:0 survive to /api/fleet -- a healthy quiet machine must not render dashed rows', async () => {
    const machines = new Map();
    const { app } = createApp({ machines });

    const machineId = 'eeeeeeee-ffff-4000-8111-222222222223';
    await request(app)
        .post('/api/status')
        .send({
            machine: baseMachine({ machine_id: machineId }),
            sessions: [],
            system: {
                schema_version: 1,
                versions: {},
                swap_used_bytes: 0,
                memory: { used: 1073741824, total: 17179869184, pressure_percent: 0 }
                // disk omitted -- contrast fixture: collection failure must
                // read differently than "nothing to report".
            }
        });

    const fleetRes = await request(app).get('/api/fleet');
    const machine = fleetRes.body.fleet.machines.find((m) => m.machine_id === machineId);
    assert.equal(Object.prototype.hasOwnProperty.call(machine.system, 'swap_used_bytes'), true);
    assert.equal(machine.system.swap_used_bytes, 0);
    assert.equal(Object.prototype.hasOwnProperty.call(machine.system.memory, 'pressure_percent'), true);
    assert.equal(machine.system.memory.pressure_percent, 0);
    assert.equal(Object.prototype.hasOwnProperty.call(machine.system, 'disk'), false, 'an uncollected disk must stay OMITTED, not {}');
    assert.deepEqual(machine.system.versions, {}, 'versions:{} is a valid healthy payload, distinct from an omitted disk');
});

// ============================================================================
// Malformed input through the full route -- rejected (omitted), never
// passed through to a dashboard consumer, never a 500.
// ============================================================================

test('END-TO-END: malformed telemetry types are omitted rather than passed through, and the request still succeeds', async () => {
    const machines = new Map();
    const { app } = createApp({ machines });

    const machineId = 'ffffffff-0000-4111-8222-333333333334';
    const postRes = await request(app)
        .post('/api/status')
        .send({
            machine: baseMachine({ machine_id: machineId }),
            sessions: [],
            system: {
                schema_version: 1,
                versions: {},
                cores: '11 cores', // string where a number belongs
                load_average: [1.5, 2.5], // 2 elements, not 3
                memory: { used: 'a lot', total: 200, pressure_percent: 50 }, // one bad leaf
                disk: 'not-an-object' // wrong type entirely
            }
        });
    assert.equal(postRes.status, 200, 'a malformed system block must never 500 the request');

    const fleetRes = await request(app).get('/api/fleet');
    assert.equal(fleetRes.status, 200);
    const machine = fleetRes.body.fleet.machines.find((m) => m.machine_id === machineId);

    assert.equal(Object.prototype.hasOwnProperty.call(machine.system, 'cores'), false);
    assert.equal(Object.prototype.hasOwnProperty.call(machine.system, 'load_average'), false);
    assert.equal(Object.prototype.hasOwnProperty.call(machine.system, 'disk'), false, 'a non-object disk must be omitted entirely, not passed through as a string');
    // memory still ships (total/pressure_percent were valid) but the bad
    // leaf inside it must not survive as the literal string 'a lot'.
    assert.equal(Object.prototype.hasOwnProperty.call(machine.system.memory, 'used'), false);
    assert.equal(machine.system.memory.total, 200);
    assert.equal(machine.system.memory.pressure_percent, 50);
});

// ============================================================================
// isVersionOutdated sanity re-check alongside telemetry, per the contract
// example figures, purely to confirm nothing about this ticket's changes
// perturbed XACA-1031's numeric comparison.
// ============================================================================

test('sanity: isVersionOutdated is untouched by this ticket -- contract example figures (0.17.8 vs 0.17.9) are outdated', () => {
    assert.equal(isVersionOutdated('0.17.8', '0.17.9'), true);
});

// ============================================================================
// ADVERSARIAL CASES (XACA-1091-018/019 review): `typeof [] === 'object'` in
// JavaScript, so a bare object-type check alone cannot reject an array.
// normalizeSystemBlock()/projectSystemBlock() reject `system`/`storedSystem`
// itself being an array via an explicit `Array.isArray()` check at the top
// of each function -- that guard is tested here for the first time.
// `memory`/`disk` supplied as arrays have NO dedicated Array.isArray
// rejection; they are neutralized instead by the per-leaf Number.isFinite
// checks (an array has no `.used`/`.total`/`.pressure_percent` own
// properties, so nothing validates and the empty group is omitted
// wholesale) -- that fallthrough behavior is tested here too, since it is
// one refactor away from silently disappearing if a future change ever
// short-circuits the per-leaf validation.
//
// Each guard gets a NEGATIVE CONTROL: a minimal reimplementation of ONLY
// the relevant fragment with the guard clause removed, proving the
// corresponding real-function assertion is not vacuous -- the same
// technique this file's own NEGATIVE CONTROL section (above) already uses
// for the nested-allowlist bug.
// ============================================================================

// A `system`/`storedSystem` shaped as a real Array (Array.isArray === true)
// but carrying every contract-shaped field as a NAMED own property -- this
// is exactly the case server.js's own top-guard comment calls out ("an
// array is not a valid system block, even though typeof [] === 'object'").
// Deliberately NOT constructible over real HTTP/JSON -- JSON.stringify on
// an array drops non-index own properties -- so this targets the
// direct-function-call adversary: a future in-process caller, or a refactor
// that swaps the object literal for an array by mistake, both of which are
// indistinguishable from a healthy record by `typeof` alone.
function arrayWithNamedContractFields() {
    return Object.assign([], FULL_REPORTER_SYSTEM_PAYLOAD);
}

test('normalizeSystemBlock: `system` supplied as a real Array carrying named contract fields still normalizes to {} -- typeof-object alone would have accepted it', () => {
    const arraySystem = arrayWithNamedContractFields();
    assert.equal(Array.isArray(arraySystem), true, 'sanity: this fixture really is an array');
    assert.deepEqual(normalizeSystemBlock(arraySystem), {});
});

test('projectSystemBlock: `storedSystem` supplied as a real Array carrying named contract fields still projects to {} -- same guard, projection side', () => {
    const { projectSystemBlock } = createApp({ machines: new Map() });
    const arrayStored = arrayWithNamedContractFields();
    assert.equal(Array.isArray(arrayStored), true, 'sanity: this fixture really is an array');
    assert.deepEqual(projectSystemBlock(arrayStored), {});
});

// Mirrors normalizeSystemBlock's real top-of-function guard MINUS the
// `|| Array.isArray(system)` clause, then a couple of representative leaf
// copies -- just enough to demonstrate whether the array fixture above gets
// accepted or rejected. Deliberately NOT resynced with the real function;
// it exists only to prove the removed clause is load-bearing.
function normalizeTopGuardWithoutArrayCheck(system) {
    if (!system || typeof system !== 'object') return {};
    const out = {};
    if (typeof system.os_version === 'string' && system.os_version) out.os_version = system.os_version;
    if (Number.isInteger(system.cores) && system.cores > 0) out.cores = system.cores;
    return out;
}

test('NEGATIVE CONTROL: dropping Array.isArray from the top guard lets the array fixture leak fields through -- proves the guard is load-bearing', () => {
    const arraySystem = arrayWithNamedContractFields();
    const buggy = normalizeTopGuardWithoutArrayCheck(arraySystem);
    assert.notDeepEqual(buggy, {}, 'sanity: the buggy guard must actually accept the array, or this control proves nothing');
    assert.equal(buggy.os_version, '27.0');
    assert.equal(buggy.cores, 11);
    // The real function does not share this failure:
    assert.deepEqual(normalizeSystemBlock(arraySystem), {});
});

test('normalizeSystemBlock: `memory` supplied as a bare array is omitted wholesale, no crash, nothing nonsensical projected', () => {
    const out = normalizeSystemBlock({ schema_version: 1, versions: {}, memory: [12884901888, 19327352832, 67] });
    assert.equal(Object.prototype.hasOwnProperty.call(out, 'memory'), false, 'a bare array has no .used/.total/.pressure_percent own properties, so nothing validates and the whole group must be omitted');
});

test('normalizeSystemBlock: `disk` supplied as a bare array is omitted wholesale, no crash, nothing nonsensical projected', () => {
    const out = normalizeSystemBlock({ schema_version: 1, versions: {}, disk: [25044885504, 76291256320, 25] });
    assert.equal(Object.prototype.hasOwnProperty.call(out, 'disk'), false);
});

test('projectSystemBlock: `memory`/`disk` supplied as bare arrays in a stored record are omitted wholesale, no crash', () => {
    const { projectSystemBlock } = createApp({ machines: new Map() });
    const out = projectSystemBlock({
        schema_version: 1,
        versions: {},
        memory: [12884901888, 19327352832, 67],
        disk: [25044885504, 76291256320, 25]
    });
    assert.equal(Object.prototype.hasOwnProperty.call(out, 'memory'), false);
    assert.equal(Object.prototype.hasOwnProperty.call(out, 'disk'), false);
});

// Mirrors the real `memory` block's outer typeof-object gate, but SKIPS the
// per-leaf Number.isFinite validation and the Object.keys-empty omission --
// the naive "just copy it over" implementation a careless refactor could
// reintroduce.
function naiveMemoryPassthrough(system) {
    const out = {};
    if (system.memory && typeof system.memory === 'object') {
        out.memory = system.memory;
    }
    return out;
}

test('NEGATIVE CONTROL: a naive memory passthrough (no per-leaf Number.isFinite discipline) lets the bare array leak straight through as `memory`', () => {
    const input = { memory: [12884901888, 19327352832, 67] };
    const buggy = naiveMemoryPassthrough(input);
    assert.equal(Object.prototype.hasOwnProperty.call(buggy, 'memory'), true, 'sanity: the naive passthrough must actually accept the array, or this control proves nothing');
    assert.equal(Array.isArray(buggy.memory), true, 'the buggy version ships the raw array, not the {used,total,pressure_percent} contract shape');
    // The real function does not share this failure:
    const real = normalizeSystemBlock({ schema_version: 1, versions: {}, memory: input.memory });
    assert.equal(Object.prototype.hasOwnProperty.call(real, 'memory'), false);
});

test('normalizeSystemBlock: `load_average` as a 3-element array of NON-NUMBERS is omitted', () => {
    const out = normalizeSystemBlock({ schema_version: 1, versions: {}, load_average: ['a', 'b', 'c'] });
    assert.equal(Object.prototype.hasOwnProperty.call(out, 'load_average'), false);
});

test('normalizeSystemBlock: `load_average` with wrong arity (2 elements) is omitted', () => {
    const out = normalizeSystemBlock({ schema_version: 1, versions: {}, load_average: [1.0, 2.0] });
    assert.equal(Object.prototype.hasOwnProperty.call(out, 'load_average'), false);
});

test('normalizeSystemBlock: `load_average` with wrong arity (4 elements) is omitted', () => {
    const out = normalizeSystemBlock({ schema_version: 1, versions: {}, load_average: [1.0, 2.0, 3.0, 4.0] });
    assert.equal(Object.prototype.hasOwnProperty.call(out, 'load_average'), false);
});

test('projectSystemBlock: `load_average` non-numeric / wrong-arity is omitted on the projection side too', () => {
    const { projectSystemBlock } = createApp({ machines: new Map() });
    assert.equal(Object.prototype.hasOwnProperty.call(projectSystemBlock({ load_average: ['a', 'b', 'c'] }), 'load_average'), false);
    assert.equal(Object.prototype.hasOwnProperty.call(projectSystemBlock({ load_average: [1, 2] }), 'load_average'), false);
    assert.equal(Object.prototype.hasOwnProperty.call(projectSystemBlock({ load_average: [1, 2, 3, 4] }), 'load_average'), false);
});

// Mirrors the real load_average check but DROPS the `.every(Number.isFinite)`
// per-element type validation, keeping only the arity check.
function naiveLoadAverageArityOnly(system) {
    const out = {};
    if (Array.isArray(system.load_average) && system.load_average.length === 3) {
        out.load_average = system.load_average.slice();
    }
    return out;
}

test('NEGATIVE CONTROL: dropping the per-element numeric-type check lets a 3-element array of NON-NUMBERS through', () => {
    const input = { load_average: ['a', 'b', 'c'] };
    const buggy = naiveLoadAverageArityOnly(input);
    assert.deepEqual(buggy.load_average, ['a', 'b', 'c'], 'sanity: the buggy version must actually accept it, or this control proves nothing');
    const real = normalizeSystemBlock({ schema_version: 1, versions: {}, load_average: input.load_average });
    assert.equal(Object.prototype.hasOwnProperty.call(real, 'load_average'), false);
});

// Mirrors the real load_average check but DROPS the `.length === 3` arity
// check, keeping only the per-element numeric-type validation.
function naiveLoadAverageTypeOnly(system) {
    const out = {};
    if (Array.isArray(system.load_average) && system.load_average.every((n) => Number.isFinite(n))) {
        out.load_average = system.load_average.slice();
    }
    return out;
}

test('NEGATIVE CONTROL: dropping the arity (length === 3) check lets a 2-element and a 4-element array through', () => {
    const buggy2 = naiveLoadAverageTypeOnly({ load_average: [1.0, 2.0] });
    const buggy4 = naiveLoadAverageTypeOnly({ load_average: [1.0, 2.0, 3.0, 4.0] });
    assert.deepEqual(buggy2.load_average, [1.0, 2.0], 'sanity: the buggy version must actually accept the 2-element array, or this control proves nothing');
    assert.deepEqual(buggy4.load_average, [1.0, 2.0, 3.0, 4.0], 'sanity: the buggy version must actually accept the 4-element array, or this control proves nothing');
    const real2 = normalizeSystemBlock({ schema_version: 1, versions: {}, load_average: [1.0, 2.0] });
    const real4 = normalizeSystemBlock({ schema_version: 1, versions: {}, load_average: [1.0, 2.0, 3.0, 4.0] });
    assert.equal(Object.prototype.hasOwnProperty.call(real2, 'load_average'), false);
    assert.equal(Object.prototype.hasOwnProperty.call(real4, 'load_average'), false);
});

test('END-TO-END: a POST carrying array-shaped memory/disk and a malformed load_average never 500s and omits every bad leaf', async () => {
    const machines = new Map();
    const { app } = createApp({ machines });

    const machineId = '11111111-2222-4333-8444-555555555556';
    const postRes = await request(app)
        .post('/api/status')
        .send({
            machine: baseMachine({ machine_id: machineId }),
            sessions: [],
            system: {
                schema_version: 1,
                versions: {},
                memory: [12884901888, 19327352832, 67],
                disk: [25044885504, 76291256320, 25],
                load_average: ['a', 'b', 'c']
            }
        });
    assert.equal(postRes.status, 200, 'array-shaped memory/disk and non-numeric load_average must never 500 the request');

    const fleetRes = await request(app).get('/api/fleet');
    const machine = fleetRes.body.fleet.machines.find((m) => m.machine_id === machineId);
    assert.equal(Object.prototype.hasOwnProperty.call(machine.system, 'memory'), false);
    assert.equal(Object.prototype.hasOwnProperty.call(machine.system, 'disk'), false);
    assert.equal(Object.prototype.hasOwnProperty.call(machine.system, 'load_average'), false);
});

// ============================================================================
// RANGE VALIDATION (XACA-1091-019/020 review): `Number.isFinite` admits
// negatives and absurd magnitudes -- this data arrives over HTTP from
// machines we do not control, so a hostile or buggy reporter could
// otherwise put `-5` bytes or `percent: 9999` straight onto the dashboard.
// Out-of-range values must be OMITTED, never clamped (a wrong number is
// worse than no number). A COLLECTED ZERO is valid data and must survive --
// every "healthy" assertion below uses an explicit `hasOwnProperty` +
// `equal(..., 0)` pair, never truthiness, per the contract's `0 IS FALSY`
// rule.
// ============================================================================

test('normalizeSystemBlock: negative byte counts are omitted (total_ram, memory.used/total, swap_used_bytes, disk.used/free)', () => {
    const out = normalizeSystemBlock({
        schema_version: 1,
        versions: {},
        total_ram: -19327352832,
        memory: { used: -1, total: -2, pressure_percent: 50 },
        swap_used_bytes: -5,
        disk: { used: -1, free: -1, percent: 25 }
    });
    assert.equal(Object.prototype.hasOwnProperty.call(out, 'total_ram'), false);
    assert.equal(Object.prototype.hasOwnProperty.call(out.memory, 'used'), false);
    assert.equal(Object.prototype.hasOwnProperty.call(out.memory, 'total'), false);
    assert.equal(out.memory.pressure_percent, 50, 'the one valid leaf in an otherwise-bad memory object still ships');
    assert.equal(Object.prototype.hasOwnProperty.call(out, 'swap_used_bytes'), false);
    assert.equal(Object.prototype.hasOwnProperty.call(out.disk, 'used'), false);
    assert.equal(Object.prototype.hasOwnProperty.call(out.disk, 'free'), false);
    assert.equal(out.disk.percent, 25);
});

test('normalizeSystemBlock: out-of-range percentages are omitted (memory.pressure_percent, disk.percent) -- negative AND above 100', () => {
    const negOut = normalizeSystemBlock({ schema_version: 1, versions: {}, memory: { pressure_percent: -1 }, disk: { percent: -1 } });
    assert.equal(Object.prototype.hasOwnProperty.call(negOut, 'memory'), false, 'pressure_percent was the only leaf and it was invalid, so the whole group is omitted');
    assert.equal(Object.prototype.hasOwnProperty.call(negOut, 'disk'), false);

    const hugeOut = normalizeSystemBlock({ schema_version: 1, versions: {}, memory: { pressure_percent: 9999 }, disk: { percent: 101 } });
    assert.equal(Object.prototype.hasOwnProperty.call(hugeOut, 'memory'), false);
    assert.equal(Object.prototype.hasOwnProperty.call(hugeOut, 'disk'), false);
});

test('normalizeSystemBlock: 100 is a valid percent (boundary, not "above range")', () => {
    const out = normalizeSystemBlock({ schema_version: 1, versions: {}, memory: { pressure_percent: 100 }, disk: { percent: 100 } });
    assert.equal(out.memory.pressure_percent, 100);
    assert.equal(out.disk.percent, 100);
});

test('normalizeSystemBlock: negative load_average components are omitted', () => {
    const out = normalizeSystemBlock({ schema_version: 1, versions: {}, load_average: [-1.0, 2.0, 3.0] });
    assert.equal(Object.prototype.hasOwnProperty.call(out, 'load_average'), false);
});

test('normalizeSystemBlock: `cores` must be a positive integer -- zero, negative, and non-integer are all omitted', () => {
    assert.equal(Object.prototype.hasOwnProperty.call(normalizeSystemBlock({ schema_version: 1, versions: {}, cores: 0 }), 'cores'), false);
    assert.equal(Object.prototype.hasOwnProperty.call(normalizeSystemBlock({ schema_version: 1, versions: {}, cores: -4 }), 'cores'), false);
    assert.equal(Object.prototype.hasOwnProperty.call(normalizeSystemBlock({ schema_version: 1, versions: {}, cores: 4.5 }), 'cores'), false);
});

test('normalizeSystemBlock: `boot_time` must be a positive integer -- zero, negative, and non-integer are all omitted', () => {
    assert.equal(Object.prototype.hasOwnProperty.call(normalizeSystemBlock({ schema_version: 1, versions: {}, boot_time: 0 }), 'boot_time'), false);
    assert.equal(Object.prototype.hasOwnProperty.call(normalizeSystemBlock({ schema_version: 1, versions: {}, boot_time: -1787581393 }), 'boot_time'), false);
    assert.equal(Object.prototype.hasOwnProperty.call(normalizeSystemBlock({ schema_version: 1, versions: {}, boot_time: 1787581393.5 }), 'boot_time'), false);
});

test('projectSystemBlock: the same range discipline applies on the projection side -- negative bytes, out-of-range percent, negative load, non-positive cores/boot_time', () => {
    const { projectSystemBlock } = createApp({ machines: new Map() });
    const out = projectSystemBlock({
        schema_version: 1,
        versions: {},
        cores: -1,
        boot_time: -1,
        total_ram: -1,
        swap_used_bytes: -1,
        memory: { used: -1, total: -1, pressure_percent: 200 },
        disk: { used: -1, free: -1, percent: -1 },
        load_average: [-1, -1, -1]
    });
    assert.equal(Object.prototype.hasOwnProperty.call(out, 'cores'), false);
    assert.equal(Object.prototype.hasOwnProperty.call(out, 'boot_time'), false);
    assert.equal(Object.prototype.hasOwnProperty.call(out, 'total_ram'), false);
    assert.equal(Object.prototype.hasOwnProperty.call(out, 'swap_used_bytes'), false);
    assert.equal(Object.prototype.hasOwnProperty.call(out, 'memory'), false);
    assert.equal(Object.prototype.hasOwnProperty.call(out, 'disk'), false);
    assert.equal(Object.prototype.hasOwnProperty.call(out, 'load_average'), false);
});

// A collected ZERO is the healthiest possible reading and MUST survive every
// new bound added above -- proven at both the unit level (normalize) and
// through the full HTTP round trip (store -> project -> /api/fleet), same
// discipline as this file's pre-existing zero-preservation tests.
test('normalizeSystemBlock: zeros survive every new range bound -- swap_used_bytes:0, pressure_percent:0, disk.percent:0, load_average:[0,0,0], total_ram:0', () => {
    const out = normalizeSystemBlock({
        schema_version: 1,
        versions: {},
        total_ram: 0,
        swap_used_bytes: 0,
        memory: { used: 0, total: 0, pressure_percent: 0 },
        disk: { used: 0, free: 0, percent: 0 },
        load_average: [0, 0, 0]
    });
    assert.equal(Object.prototype.hasOwnProperty.call(out, 'total_ram'), true);
    assert.equal(out.total_ram, 0);
    assert.equal(Object.prototype.hasOwnProperty.call(out, 'swap_used_bytes'), true);
    assert.equal(out.swap_used_bytes, 0);
    assert.equal(Object.prototype.hasOwnProperty.call(out.memory, 'used'), true);
    assert.equal(out.memory.used, 0);
    assert.equal(Object.prototype.hasOwnProperty.call(out.memory, 'pressure_percent'), true);
    assert.equal(out.memory.pressure_percent, 0);
    assert.equal(Object.prototype.hasOwnProperty.call(out.disk, 'percent'), true);
    assert.equal(out.disk.percent, 0);
    assert.deepEqual(out.load_average, [0, 0, 0]);
});

test('END-TO-END: a fully-zeroed healthy machine survives every new range bound through the full HTTP round trip', async () => {
    const machines = new Map();
    const { app } = createApp({ machines });

    const machineId = '22222222-3333-4444-8555-666666666667';
    await request(app)
        .post('/api/status')
        .send({
            machine: baseMachine({ machine_id: machineId }),
            sessions: [],
            system: {
                schema_version: 1,
                versions: {},
                total_ram: 0,
                swap_used_bytes: 0,
                memory: { used: 0, total: 0, pressure_percent: 0 },
                disk: { used: 0, free: 0, percent: 0 },
                load_average: [0, 0, 0]
            }
        });

    const fleetRes = await request(app).get('/api/fleet');
    const machine = fleetRes.body.fleet.machines.find((m) => m.machine_id === machineId);
    assert.equal(machine.system.total_ram, 0);
    assert.equal(machine.system.swap_used_bytes, 0);
    assert.equal(machine.system.memory.pressure_percent, 0);
    assert.equal(machine.system.disk.percent, 0);
    assert.deepEqual(machine.system.load_average, [0, 0, 0]);
});

// NEGATIVE CONTROLS for the range bounds: minimal reimplementations of each
// bound's guard with the range check dropped back to bare Number.isFinite --
// the exact regression this review comment warns about.
function naiveByteCount(n) {
    return Number.isFinite(n);
}
function naivePercent(n) {
    return Number.isFinite(n);
}

test('NEGATIVE CONTROL: bare Number.isFinite (no range check) accepts a negative byte count and an out-of-range percent -- proves the range checks above are load-bearing', () => {
    assert.equal(naiveByteCount(-5), true, 'sanity: the naive (pre-fix) check must actually accept -5, or this control proves nothing');
    assert.equal(naivePercent(9999), true, 'sanity: the naive (pre-fix) check must actually accept 9999, or this control proves nothing');

    // The real functions do not share this failure:
    const out = normalizeSystemBlock({ schema_version: 1, versions: {}, swap_used_bytes: -5, memory: { pressure_percent: 9999 } });
    assert.equal(Object.prototype.hasOwnProperty.call(out, 'swap_used_bytes'), false);
    assert.equal(Object.prototype.hasOwnProperty.call(out, 'memory'), false);
});
