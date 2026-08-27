//
//  xaca-0983-004-lcars-services.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-0983 fix (b): the Fleet Monitor's LCARS-tab gate
 * (isLcarsTerminal in the 5 client dashboard apps) previously inferred
 * service absence from tmux SESSION-NAME absence -- so a healthy LCARS
 * backend with no matching session (e.g. a health-check self-heal killed
 * the session and nothing recreated it -- XACA-0983 fix (a)) rendered as
 * "no LCARS tab", indistinguishable from a team that never had one.
 *
 * This suite covers the SERVER side of that fix: POST /api/status storing
 * a machine-level `lcars_services[]` array (independent of `sessions[]`),
 * and GET /api/fleet's parseFleetData() materializing a team entry from a
 * service record even when that team has ZERO tmux sessions -- something
 * parseFleetData structurally could not do before this change (it only
 * ever iterated machineData.sessions to discover a team at all).
 *
 * Tests run against tests/helpers/app-factory.js's createApp(), which
 * mirrors server.js's route handlers with injectable state (no real
 * server.js require() -- that file calls app.listen() unconditionally at
 * import time, which is why every other suite in this directory uses the
 * same mirror). The mirror was updated in the SAME diff as server.js's
 * real parseFleetData/POST-handler changes -- see both files' "XACA-0983
 * fix (b)" comments -- so this suite exercises the same logic server.js
 * runs, not a stale duplicate of it.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const { createApp } = require('./helpers/app-factory.js');

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
// Ingestion (POST /api/status) -- storing lcars_services
// ============================================================================

test('POST /api/status stores lcars_services on the machine record', async () => {
    const machines = new Map();
    const { app } = createApp({ machines });

    const res = await request(app)
        .post('/api/status')
        .send({
            machine: baseMachine(),
            sessions: [],
            lcars_services: [
                { session_name: 'academy-lcars', division: 'academy', project: null, team: 'lcars', port: 8203, reachable: true, source: 'portfile' }
            ]
        });

    assert.equal(res.status, 200);
    const stored = machines.get(TEST_MACHINE_GUID);
    assert.ok(Array.isArray(stored.lcars_services));
    assert.equal(stored.lcars_services.length, 1);
    assert.equal(stored.lcars_services[0].port, 8203);
});

// Backward compat: OLD reporter, NEW server. A pre-XACA-0983 reporter never
// sends the lcars_services key at all -- req.body simply lacks it. Must not
// crash, must degrade to a normal empty-array machine record.
test('POST /api/status without lcars_services (old reporter) defaults to empty array and does not crash', async () => {
    const machines = new Map();
    const { app } = createApp({ machines });

    const res = await request(app)
        .post('/api/status')
        .send({
            machine: baseMachine(),
            sessions: [{ name: 'academy-engineering', division: 'academy', project: null, team: 'engineering', windows: 2 }]
        });

    assert.equal(res.status, 200);
    const stored = machines.get(TEST_MACHINE_GUID);
    assert.ok(Array.isArray(stored.lcars_services));
    assert.equal(stored.lcars_services.length, 0);
});

test('POST /api/status with malformed lcars_services (not an array) is normalized to [] and does not crash', async () => {
    const machines = new Map();
    const { app } = createApp({ machines });

    const res = await request(app)
        .post('/api/status')
        .send({
            machine: baseMachine(),
            sessions: [],
            lcars_services: 'not-an-array'
        });

    assert.equal(res.status, 200);
    const stored = machines.get(TEST_MACHINE_GUID);
    assert.deepEqual(stored.lcars_services, []);
});

// ============================================================================
// GET /api/fleet -- parseFleetData materializing a session-less team
// ============================================================================

test('GET /api/fleet materializes a team with ZERO sessions from lcars_services alone', async () => {
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
        lcars_services: [
            { session_name: 'academy-lcars', division: 'academy', project: null, team: 'lcars', port: 8203, reachable: true, source: 'portfile' }
        ]
    });
    const { app } = createApp({ machines });

    const res = await request(app).get('/api/fleet');
    assert.equal(res.status, 200);

    const academyTeam = res.body.fleet.divisions.academy.projects._default.teams.lcars;
    assert.ok(academyTeam, 'expected a materialized "lcars" team under academy/_default');
    assert.deepEqual(academyTeam.sessions, []);
    assert.equal(academyTeam.lcars_service.port, 8203);
    assert.equal(academyTeam.lcars_service.reachable, true);
    assert.equal(academyTeam.lcars_service.hostname, 'runabout');

    // total_sessions must NOT be incremented by a service-only record --
    // there is no session, and this counter means "live tmux sessions".
    assert.equal(res.body.fleet.divisions.academy.total_sessions, 0);
});

test('GET /api/fleet: a team with BOTH a live session and a service record gets both, sessions not double-counted', async () => {
    const machines = new Map();
    machines.set(TEST_MACHINE_GUID, {
        machine_id: TEST_MACHINE_GUID,
        hostname: 'runabout',
        ip: '10.0.0.5',
        os: 'Darwin',
        status: 'online',
        sessions: [
            { name: 'academy-lcars', division: 'academy', project: null, team: 'lcars', windows: 1, attached: false, created: new Date().toISOString(), uptime_seconds: 60, lcars_port: 8203 }
        ],
        session_count: 1,
        first_seen: new Date().toISOString(),
        last_seen: new Date().toISOString(),
        uptime_history: [],
        lcars_services: [
            { session_name: 'academy-lcars', division: 'academy', project: null, team: 'lcars', port: 8203, reachable: true, source: 'portfile' }
        ]
    });
    const { app } = createApp({ machines });

    const res = await request(app).get('/api/fleet');
    assert.equal(res.status, 200);

    const academyTeam = res.body.fleet.divisions.academy.projects._default.teams.lcars;
    assert.equal(academyTeam.sessions.length, 1);
    assert.equal(academyTeam.lcars_service.port, 8203);
    assert.equal(res.body.fleet.divisions.academy.total_sessions, 1);
});

test('GET /api/fleet: reachable=true is not clobbered by a later reachable=false record for the same team', async () => {
    const machines = new Map();
    machines.set(TEST_MACHINE_GUID, {
        machine_id: TEST_MACHINE_GUID, hostname: 'runabout', ip: '10.0.0.5', os: 'Darwin',
        status: 'online', sessions: [], session_count: 0,
        first_seen: new Date().toISOString(), last_seen: new Date().toISOString(), uptime_history: [],
        lcars_services: [
            { session_name: 'academy-lcars', division: 'academy', project: null, team: 'lcars', port: 8203, reachable: false, source: 'portfile' }
        ]
    });
    machines.set(TEST_MACHINE_GUID_2, {
        machine_id: TEST_MACHINE_GUID_2, hostname: 'defiant', ip: '10.0.0.6', os: 'Darwin',
        status: 'online', sessions: [], session_count: 0,
        first_seen: new Date().toISOString(), last_seen: new Date().toISOString(), uptime_history: [],
        lcars_services: [
            { session_name: 'academy-lcars', division: 'academy', project: null, team: 'lcars', port: 8203, reachable: true, source: 'portfile' }
        ]
    });
    const { app } = createApp({ machines });

    const res = await request(app).get('/api/fleet');
    const academyTeam = res.body.fleet.divisions.academy.projects._default.teams.lcars;
    // Regardless of Map iteration order, a reachable:true record must win.
    assert.equal(academyTeam.lcars_service.reachable, true);
});

test('GET /api/fleet: malformed lcars_services entries (missing team/division/port) are skipped individually, not fatal', async () => {
    const machines = new Map();
    machines.set(TEST_MACHINE_GUID, {
        machine_id: TEST_MACHINE_GUID, hostname: 'runabout', ip: '10.0.0.5', os: 'Darwin',
        status: 'online', sessions: [], session_count: 0,
        first_seen: new Date().toISOString(), last_seen: new Date().toISOString(), uptime_history: [],
        lcars_services: [
            { session_name: 'broken-lcars', division: null, team: 'lcars', port: 8203 }, // missing division
            { session_name: 'broken2-lcars', division: 'ios', team: null, port: 8443 },  // missing team
            { session_name: 'broken3-lcars', division: 'firebase', team: 'lcars', port: 'not-a-number' }, // bad port
            { session_name: 'ios-lcars', division: 'ios', project: null, team: 'lcars', port: 8443, reachable: true, source: 'portfile' } // valid
        ]
    });
    const { app } = createApp({ machines });

    const res = await request(app).get('/api/fleet');
    assert.equal(res.status, 200);
    assert.ok(!res.body.fleet.divisions.firebase, 'malformed firebase entry must not materialize a division');
    const iosTeam = res.body.fleet.divisions.ios.projects._default.teams.lcars;
    assert.equal(iosTeam.lcars_service.port, 8443);
});

test('GET /api/fleet: freelance divisionKey splitting applies identically to lcars_services as it does to sessions', async () => {
    const machines = new Map();
    machines.set(TEST_MACHINE_GUID, {
        machine_id: TEST_MACHINE_GUID, hostname: 'runabout', ip: '10.0.0.5', os: 'Darwin',
        status: 'online', sessions: [], session_count: 0,
        first_seen: new Date().toISOString(), last_seen: new Date().toISOString(), uptime_history: [],
        lcars_services: [
            { session_name: 'freelance-doublenode-workstats-lcars', division: 'freelance', project: 'doublenode-workstats', team: 'lcars', port: 8901, reachable: true, source: 'portfile' }
        ]
    });
    const { app } = createApp({ machines });

    const res = await request(app).get('/api/fleet');
    const div = res.body.fleet.divisions['freelance-workstats'];
    assert.ok(div, 'expected divisionKey "freelance-workstats" (matching the sessions-path splitting rule)');
    const team = div.projects['doublenode-workstats'].teams.lcars;
    assert.equal(team.lcars_service.port, 8901);
});

test('GET /api/fleet: a team with neither a session nor a service record is absent (genuinely-absent state unaffected)', async () => {
    const machines = new Map();
    machines.set(TEST_MACHINE_GUID, {
        machine_id: TEST_MACHINE_GUID, hostname: 'runabout', ip: '10.0.0.5', os: 'Darwin',
        status: 'online',
        sessions: [{ name: 'academy-engineering', division: 'academy', project: null, team: 'engineering', windows: 2, attached: true, created: new Date().toISOString(), uptime_seconds: 10 }],
        session_count: 1,
        first_seen: new Date().toISOString(), last_seen: new Date().toISOString(), uptime_history: [],
        lcars_services: []
    });
    const { app } = createApp({ machines });

    const res = await request(app).get('/api/fleet');
    const teams = res.body.fleet.divisions.academy.projects._default.teams;
    assert.ok(teams.engineering);
    assert.ok(!teams.lcars, 'no lcars session and no lcars_service -- must not materialize a phantom team');
});
