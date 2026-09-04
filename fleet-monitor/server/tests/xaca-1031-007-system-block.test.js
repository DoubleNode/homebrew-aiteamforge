//
//  xaca-1031-007-system-block.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1031 subitem 007 (Testing & Debugging) -- SERVER-side regression
 * coverage for the machine-level `system` block (EPIC-0061 Design Decision
 * 8, frozen contract kanban/plans/XACA-1091/CONTRACT-system-block.md):
 * isVersionOutdated() (numeric semver comparison), normalizeSystemBlock()
 * (POST /api/status ingestion), and projectSystemBlock() (the GET /api/fleet
 * machineList allowlist projection) in server.js.
 *
 * ── Why this tests tests/helpers/app-factory.js's mirror, not server.js
 *    directly ──────────────────────────────────────────────────────────
 * server.js has no module.exports and calls app.listen() unconditionally at
 * import time (see every other suite in this directory's header comment on
 * why they all use app-factory.js's createApp() instead of require()-ing
 * server.js). isVersionOutdated/normalizeSystemBlock/projectSystemBlock have
 * been added to that mirror in the SAME diff as this test file, copied
 * VERBATIM from server.js's real implementation -- see app-factory.js's own
 * "XACA-1031-007: mirrored VERBATIM from server.js's ..." comments at each
 * definition. THIS GAP EXISTED BEFORE THIS COMMIT: the feature shipped in
 * e77798e1 (server.js's normalizeSystemBlock/projectSystemBlock/
 * isVersionOutdated, the POST /api/status `system` field, and the
 * machineList `system: projectSystemBlock(m.system)` allowlist entry) without
 * a matching update to this mirror -- every prior suite in this directory
 * documents that the mirror "MUST stay in sync", and the lcars_services
 * precedent (XACA-0983 fix (b)) explicitly says it "was updated in the SAME
 * diff as server.js's real ... changes". XACA-1031's shipped commit did not
 * do that for this block, so no route-level test through createApp() could
 * have exercised the real POST/GET behavior until this file's app-factory.js
 * update closed that gap.
 *
 * ── The projection allowlist is the highest-risk step (constraint #12) ───
 * server.js's machineList .map() in parseFleetData() is an EXPLICIT
 * ALLOWLIST -- a field stored via machines.set() but omitted from that one
 * .map() call silently never reaches GET /api/fleet's response body, while
 * still looking present in server memory. Every assertion below that cares
 * about the projected shape reads `res.body` (the raw HTTP response), NEVER
 * `state.machines.get(...)` -- reading server-side state would pass even if
 * the real allowlist entry were deleted, which is exactly the failure mode
 * this ticket's contract calls out as most likely to be "verified" green
 * while broken.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const { createApp, helpers } = require('./helpers/app-factory.js');

const { isVersionOutdated, normalizeSystemBlock } = helpers;

const TEST_MACHINE_GUID = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
const TEST_MACHINE_GUID_2 = 'bbbbbbbb-cccc-4ddd-8eee-ffffffffffff';

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

// ============================================================================
// isVersionOutdated() -- numeric semver comparison (constraint #6)
// ============================================================================

test('isVersionOutdated: the live trap -- "0.20.3" is NEWER than "0.9.0" even though it sorts first lexicographically', () => {
    // A string comparison ("0.20.3" < "0.9.0" because '2' < '9') would say
    // the current tap version is outdated relative to an ancient 0.9.0 --
    // backwards, and live at the tap's actual current version.
    assert.equal(isVersionOutdated('0.20.3', '0.9.0'), false, 'current 0.20.3 vs latest 0.9.0 -- NOT outdated');
    assert.equal(isVersionOutdated('0.9.0', '0.20.3'), true, 'current 0.9.0 vs latest 0.20.3 -- genuinely outdated');
});

test('isVersionOutdated: equal versions are not outdated', () => {
    assert.equal(isVersionOutdated('0.20.3', '0.20.3'), false);
});

test('isVersionOutdated: older current is outdated', () => {
    assert.equal(isVersionOutdated('0.18.0', '0.20.3'), true);
});

test('isVersionOutdated: garbage on either side returns null (undeterminable, not a guess)', () => {
    assert.equal(isVersionOutdated('not-a-version', '0.20.3'), null);
    assert.equal(isVersionOutdated('0.20.3', 'not-a-version'), null);
    assert.equal(isVersionOutdated('', '0.20.3'), null);
    assert.equal(isVersionOutdated('0.20.3', ''), null);
    assert.equal(isVersionOutdated(null, '0.20.3'), null);
    assert.equal(isVersionOutdated('0.20.3', undefined), null);
});

test('isVersionOutdated: a leading "v" is stripped before comparison', () => {
    assert.equal(isVersionOutdated('v0.9.0', 'v0.20.3'), true);
    assert.equal(isVersionOutdated('0.9.0', 'v0.20.3'), true);
});

test('isVersionOutdated: unequal component counts zero-pad the shorter side', () => {
    assert.equal(isVersionOutdated('2.0', '2.0.0'), false, '2.0 == 2.0.0 -- not outdated');
    assert.equal(isVersionOutdated('2.0', '2.0.1'), true, '2.0 == 2.0.0 < 2.0.1 -- outdated');
    assert.equal(isVersionOutdated('2.1', '2.0.9'), false, '2.1 > 2.0.9 -- not outdated');
});

// ============================================================================
// normalizeSystemBlock() -- POST /api/status ingestion (pure function)
// ============================================================================

test('normalizeSystemBlock: whole block absent (old reporter) normalizes to {}', () => {
    assert.deepEqual(normalizeSystemBlock(undefined), {});
    assert.deepEqual(normalizeSystemBlock(null), {});
});

test('normalizeSystemBlock: an uncollectable aiteamforge leaf is OMITTED, never null or empty string', () => {
    const out = normalizeSystemBlock({ schema_version: 1, versions: {} });
    assert.deepEqual(out, { schema_version: 1, versions: {} });
    assert.equal(Object.prototype.hasOwnProperty.call(out.versions, 'aiteamforge'), false);
});

test('normalizeSystemBlock: a resolved aiteamforge version passes through', () => {
    const out = normalizeSystemBlock({ schema_version: 1, versions: { aiteamforge: '0.20.3' } });
    assert.deepEqual(out, { schema_version: 1, versions: { aiteamforge: '0.20.3' } });
});

// ============================================================================
// POST /api/status -> GET /api/fleet round trip (constraint #12: assert
// against the raw HTTP response body, never server-side state)
// ============================================================================

test('POST /api/status with no `system` key at all (old reporter) -- GET /api/fleet shows a stable {} shape, never undefined (constraint #10)', async () => {
    const machines = new Map();
    const { app } = createApp({ machines });

    const postRes = await request(app)
        .post('/api/status')
        .send({ machine: baseMachine(), sessions: [] });
    assert.equal(postRes.status, 200);

    const fleetRes = await request(app).get('/api/fleet');
    assert.equal(fleetRes.status, 200);
    const machine = fleetRes.body.fleet.machines.find((m) => m.machine_id === TEST_MACHINE_GUID);
    assert.ok(machine, 'expected the machine to be present in /api/fleet response');
    assert.notEqual(machine.system, undefined, 'machine.system must never be undefined in the response body');
    assert.deepEqual(machine.system, {});
});

test('POST /api/status with schema_version -- GET /api/fleet round-trips it unchanged (constraint #9)', async () => {
    const machines = new Map();
    const { app } = createApp({ machines });

    await request(app)
        .post('/api/status')
        .send({
            machine: baseMachine(),
            sessions: [],
            system: { schema_version: 1, versions: {} }
        });

    const fleetRes = await request(app).get('/api/fleet');
    const machine = fleetRes.body.fleet.machines.find((m) => m.machine_id === TEST_MACHINE_GUID);
    assert.equal(machine.system.schema_version, 1);
});

test('POST /api/status with versions: {} (unresolvable on the reporter) -- GET /api/fleet keeps versions: {} and is still valid (constraint #4 server half)', async () => {
    const machines = new Map();
    const { app } = createApp({ machines });

    const postRes = await request(app)
        .post('/api/status')
        .send({
            machine: baseMachine(),
            sessions: [],
            system: { schema_version: 1, versions: {} }
        });
    assert.equal(postRes.status, 200);

    const fleetRes = await request(app).get('/api/fleet');
    assert.equal(fleetRes.status, 200);
    const machine = fleetRes.body.fleet.machines.find((m) => m.machine_id === TEST_MACHINE_GUID);
    assert.deepEqual(machine.system.versions, {});
});

test('outdated:false is PRESENT (not omitted) in the /api/fleet response when confirmed current (constraint #8)', async () => {
    const machines = new Map();
    const { app, state } = createApp({ machines, latestTapVersion: '0.20.3' });

    await request(app)
        .post('/api/status')
        .send({
            machine: baseMachine(),
            sessions: [],
            system: { schema_version: 1, versions: { aiteamforge: '0.20.3' } }
        });

    const fleetRes = await request(app).get('/api/fleet');
    const machine = fleetRes.body.fleet.machines.find((m) => m.machine_id === TEST_MACHINE_GUID);
    assert.equal(Object.prototype.hasOwnProperty.call(machine.system.versions, 'outdated'), true,
        'outdated key must be PRESENT when the comparison is determinable, even though the value is false');
    assert.equal(machine.system.versions.outdated, false);
    assert.equal(machine.system.versions.latest, '0.20.3');
    // Sanity: state.latestTapVersionState is the deterministic test seam this
    // suite relies on -- confirm it actually drove the response rather than
    // some other path resolving the same value by coincidence.
    assert.equal(state.latestTapVersionState.value, '0.20.3');
});

test('outdated:true is present and correctly signed for a genuinely outdated machine', async () => {
    const machines = new Map();
    const { app } = createApp({ machines, latestTapVersion: '0.20.3' });

    await request(app)
        .post('/api/status')
        .send({
            machine: baseMachine(),
            sessions: [],
            system: { schema_version: 1, versions: { aiteamforge: '0.9.0' } }
        });

    const fleetRes = await request(app).get('/api/fleet');
    const machine = fleetRes.body.fleet.machines.find((m) => m.machine_id === TEST_MACHINE_GUID);
    assert.equal(machine.system.versions.outdated, true);
});

test('outdated key is OMITTED (never null) when the aiteamforge version is known but the latest-tap-version cache never resolved (constraint #7 + #11 fail-safe)', async () => {
    const machines = new Map();
    // latestTapVersion deliberately NOT seeded -- defaults to null, the same
    // state server.js's real cache is in before its first successful fetch,
    // or permanently after every fetch attempt has failed. No network call
    // happens anywhere in this test -- the mirror's getLatestTapVersion() is
    // a plain synchronous read of this seeded value, so the failure mode is
    // driven deterministically instead of depending on a real DNS/HTTP
    // failure.
    const { app } = createApp({ machines });

    const postRes = await request(app)
        .post('/api/status')
        .send({
            machine: baseMachine(),
            sessions: [],
            system: { schema_version: 1, versions: { aiteamforge: '0.15.0' } }
        });
    assert.equal(postRes.status, 200, 'POST must still succeed when the tap-version cache is unresolved');

    const fleetRes = await request(app).get('/api/fleet');
    assert.equal(fleetRes.status, 200, 'GET /api/fleet must still return 200 when the tap-version cache is unresolved');
    const machine = fleetRes.body.fleet.machines.find((m) => m.machine_id === TEST_MACHINE_GUID);
    assert.deepEqual(machine.system.versions, { aiteamforge: '0.15.0' });
    assert.equal(Object.prototype.hasOwnProperty.call(machine.system.versions, 'latest'), false, 'latest must be OMITTED, not null');
    assert.equal(Object.prototype.hasOwnProperty.call(machine.system.versions, 'outdated'), false, 'outdated must be OMITTED, not null');
});

test('the projection is an ALLOWLIST: a machine record carrying `system` in server memory but a machineList map lacking the projection line would silently drop it -- this test fails if that line is ever removed (constraint #12)', async () => {
    const machines = new Map();
    machines.set(TEST_MACHINE_GUID, {
        machine_id: TEST_MACHINE_GUID,
        hostname: 'runabout',
        ip: '10.0.0.5',
        os: 'Darwin',
        status: 'online',
        sessions: [],
        session_count: 0,
        first_seen: new Date().toISOString(),
        last_seen: new Date().toISOString(),
        uptime_history: [],
        // Stored directly (bypassing POST /api/status) to isolate the
        // projection step alone -- this is exactly the shape
        // normalizeSystemBlock() would have produced.
        system: { schema_version: 1, versions: { aiteamforge: '0.20.3' } }
    });
    const { app } = createApp({ machines, latestTapVersion: '0.20.3' });

    const fleetRes = await request(app).get('/api/fleet');
    assert.equal(fleetRes.status, 200);
    // Deliberately reading res.body (the raw HTTP response), never
    // state.machines.get(...).system -- the stored value being correct is
    // not evidence the allowlist projected it into the response.
    const machine = fleetRes.body.fleet.machines.find((m) => m.machine_id === TEST_MACHINE_GUID);
    assert.ok(machine, 'expected the machine in the raw /api/fleet response body');
    assert.equal(machine.system.versions.aiteamforge, '0.20.3');
    assert.equal(machine.system.versions.outdated, false);
});

test('a pre-XACA-1031 stored record with no `system` key at all survives parseFleetData without throwing (defends projectSystemBlock against undefined storedSystem)', async () => {
    const machines = new Map();
    machines.set(TEST_MACHINE_GUID_2, {
        machine_id: TEST_MACHINE_GUID_2,
        hostname: 'defiant',
        ip: '10.0.0.6',
        os: 'Darwin',
        status: 'online',
        sessions: [],
        session_count: 0,
        first_seen: new Date().toISOString(),
        last_seen: new Date().toISOString(),
        uptime_history: []
        // no `system` key at all -- simulates a record persisted to disk by
        // a pre-XACA-1031 server build and reloaded on restart.
    });
    const { app } = createApp({ machines });

    const fleetRes = await request(app).get('/api/fleet');
    assert.equal(fleetRes.status, 200);
    const machine = fleetRes.body.fleet.machines.find((m) => m.machine_id === TEST_MACHINE_GUID_2);
    assert.deepEqual(machine.system, {});
});
