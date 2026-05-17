//
//  fleet-routes.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * Fleet Routes Tests
 * Tests: POST /api/status, GET /api/fleet, PUT /api/machine/:id/nickname,
 *        GET /api/machine/:id/history, GET /api/health, GET /api/backup-status,
 *        GET /api/machines/list, GET /api/active-divisions
 */
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const { createApp } = require('./helpers/app-factory.js');

// Shared test machine GUID (must be 36 chars)
const TEST_MACHINE_GUID = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';

// ============================================================================
// /api/health
// ============================================================================

test('GET /api/health returns operational status', async () => {
    const { app } = createApp();
    const res = await request(app).get('/api/health');
    assert.equal(res.status, 200);
    assert.equal(res.body.status, 'operational');
    assert.ok(typeof res.body.uptime === 'number');
    assert.ok(typeof res.body.timestamp === 'string');
    assert.ok(typeof res.body.machines_tracked === 'number');
    assert.ok(typeof res.body.registered_teams === 'number');
});

test('GET /api/health reflects injected machine count', async () => {
    const machines = new Map();
    machines.set('m1', { machine_id: 'm1' });
    const { app } = createApp({ machines });
    const res = await request(app).get('/api/health');
    assert.equal(res.status, 200);
    assert.equal(res.body.machines_tracked, 1);
});

// ============================================================================
// POST /api/status — success cases
// ============================================================================

test('POST /api/status stores a new machine', async () => {
    const machines = new Map();
    const { app } = createApp({ machines });
    const res = await request(app)
        .post('/api/status')
        .send({
            machine: {
                machine_id: TEST_MACHINE_GUID,
                hostname: 'enterprise',
                ip: '192.168.1.1',
                os: 'macOS'
            },
            sessions: [{ session_name: 'academy', division: 'academy', project: null, team: 'reno', name: 'academy', windows: 2 }]
        });
    assert.equal(res.status, 200);
    assert.equal(res.body.success, true);
    assert.equal(res.body.sessions_count, 1);
    assert.equal(machines.size, 1);
    const stored = machines.get(TEST_MACHINE_GUID);
    assert.equal(stored.hostname, 'enterprise');
    assert.equal(stored.status, 'online');
    assert.equal(stored.ip, '192.168.1.1');
});

test('POST /api/status updates existing machine without clobbering nickname', async () => {
    const machines = new Map();
    machines.set(TEST_MACHINE_GUID, {
        machine_id: TEST_MACHINE_GUID,
        hostname: 'enterprise',
        nickname: 'Big E',
        ip: '192.168.1.1',
        status: 'online',
        sessions: [],
        session_count: 0,
        first_seen: new Date().toISOString(),
        last_seen: new Date().toISOString(),
        uptime_history: []
    });
    const { app } = createApp({ machines });

    const res = await request(app)
        .post('/api/status')
        .send({
            machine: { machine_id: TEST_MACHINE_GUID, hostname: 'enterprise', ip: '10.0.0.1' },
            sessions: []
        });
    assert.equal(res.status, 200);
    const updated = machines.get(TEST_MACHINE_GUID);
    // Nickname preserved
    assert.equal(updated.nickname, 'Big E');
    // IP updated
    assert.equal(updated.ip, '10.0.0.1');
});

test('POST /api/status preserves first_seen from existing machine', async () => {
    const originalFirstSeen = '2024-01-01T00:00:00.000Z';
    const machines = new Map();
    machines.set(TEST_MACHINE_GUID, {
        machine_id: TEST_MACHINE_GUID,
        hostname: 'enterprise',
        first_seen: originalFirstSeen,
        status: 'online',
        sessions: [],
        session_count: 0,
        last_seen: originalFirstSeen,
        uptime_history: []
    });
    const { app } = createApp({ machines });

    await request(app)
        .post('/api/status')
        .send({ machine: { machine_id: TEST_MACHINE_GUID, hostname: 'enterprise' }, sessions: [] });

    const stored = machines.get(TEST_MACHINE_GUID);
    assert.equal(stored.first_seen, originalFirstSeen);
});

test('POST /api/status falls back to hostname as key when no machine_id', async () => {
    const machines = new Map();
    const { app } = createApp({ machines });
    await request(app)
        .post('/api/status')
        .send({ machine: { hostname: 'defiant' }, sessions: [] });
    assert.ok(machines.has('defiant'), 'Should use hostname as key');
});

test('POST /api/status caps uptime_history at 48 entries', async () => {
    const machines = new Map();
    const history = Array.from({ length: 48 }, (_, i) => ({
        timestamp: new Date(Date.now() - i * 1000).toISOString(),
        status: 'online',
        session_count: 0
    }));
    machines.set(TEST_MACHINE_GUID, {
        machine_id: TEST_MACHINE_GUID,
        hostname: 'enterprise',
        status: 'online',
        sessions: [],
        session_count: 0,
        first_seen: new Date().toISOString(),
        last_seen: new Date().toISOString(),
        uptime_history: history
    });
    const { app } = createApp({ machines });

    await request(app)
        .post('/api/status')
        .send({ machine: { machine_id: TEST_MACHINE_GUID, hostname: 'enterprise' }, sessions: [] });

    const stored = machines.get(TEST_MACHINE_GUID);
    assert.equal(stored.uptime_history.length, 48);
});

// ============================================================================
// POST /api/status — error cases
// ============================================================================

test('POST /api/status returns 400 if machine is missing', async () => {
    const { app } = createApp();
    const res = await request(app).post('/api/status').send({ sessions: [] });
    assert.equal(res.status, 400);
    assert.ok(res.body.error);
});

test('POST /api/status returns 400 if machine.hostname is missing', async () => {
    const { app } = createApp();
    const res = await request(app).post('/api/status').send({ machine: { ip: '1.2.3.4' }, sessions: [] });
    assert.equal(res.status, 400);
    assert.match(res.body.error, /machine\.hostname/);
});

test('POST /api/status returns 400 for empty body', async () => {
    const { app } = createApp();
    const res = await request(app).post('/api/status').send({});
    assert.equal(res.status, 400);
});

// ============================================================================
// GET /api/fleet
// ============================================================================

test('GET /api/fleet returns fleet structure with no machines', async () => {
    const { app } = createApp();
    const res = await request(app).get('/api/fleet');
    assert.equal(res.status, 200);
    assert.ok(res.body.fleet);
    assert.equal(res.body.fleet.total_machines, 0);
    assert.equal(res.body.fleet.online_machines, 0);
    assert.equal(res.body.fleet.total_sessions, 0);
    assert.ok(Array.isArray(res.body.fleet.machines));
    assert.ok(typeof res.body.last_update === 'string');
});

test('GET /api/fleet counts online machine correctly', async () => {
    const machines = new Map();
    machines.set(TEST_MACHINE_GUID, {
        machine_id: TEST_MACHINE_GUID,
        hostname: 'enterprise',
        status: 'online',
        last_seen: new Date().toISOString(),
        sessions: [],
        session_count: 2,
        ip: '192.168.1.1',
        os: 'macOS',
        first_seen: new Date().toISOString(),
        uptime_history: []
    });
    const { app } = createApp({ machines });
    const res = await request(app).get('/api/fleet');
    assert.equal(res.status, 200);
    assert.equal(res.body.fleet.total_machines, 1);
    assert.equal(res.body.fleet.online_machines, 1);
});

test('GET /api/fleet marks machine as offline when last_seen is stale', async () => {
    const machines = new Map();
    // last_seen 10 minutes ago (exceeds 3 min OFFLINE_THRESHOLD)
    const staleTime = new Date(Date.now() - 10 * 60 * 1000).toISOString();
    machines.set(TEST_MACHINE_GUID, {
        machine_id: TEST_MACHINE_GUID,
        hostname: 'enterprise',
        status: 'online',  // starts online
        last_seen: staleTime,
        sessions: [],
        session_count: 0,
        ip: '192.168.1.1',
        os: 'macOS',
        first_seen: staleTime,
        uptime_history: []
    });
    const { app, state } = createApp({ machines });
    const res = await request(app).get('/api/fleet');
    assert.equal(res.status, 200);
    // Machine should now be offline
    assert.equal(state.machines.get(TEST_MACHINE_GUID).status, 'offline');
});

test('GET /api/fleet marks machine as warning when 2 minutes stale', async () => {
    const machines = new Map();
    const warnTime = new Date(Date.now() - 150 * 1000).toISOString(); // 2.5 min ago
    machines.set(TEST_MACHINE_GUID, {
        machine_id: TEST_MACHINE_GUID,
        hostname: 'enterprise',
        status: 'online',
        last_seen: warnTime,
        sessions: [],
        session_count: 0,
        ip: '10.0.0.1',
        os: 'Linux',
        first_seen: warnTime,
        uptime_history: []
    });
    const { app, state } = createApp({ machines });
    await request(app).get('/api/fleet');
    const status = state.machines.get(TEST_MACHINE_GUID).status;
    assert.equal(status, 'warning');
});

test('GET /api/fleet skips machines without valid GUID', async () => {
    const machines = new Map();
    // Legacy machine with short key
    machines.set('short-key', { machine_id: 'short-key', hostname: 'oldbox', status: 'online', last_seen: new Date().toISOString(), sessions: [], session_count: 0, uptime_history: [] });
    const { app } = createApp({ machines });
    const res = await request(app).get('/api/fleet');
    // Machine list should be empty — legacy machine excluded
    assert.equal(res.body.fleet.machines.length, 0);
});

test('GET /api/fleet builds divisions from online machine sessions', async () => {
    const machines = new Map();
    machines.set(TEST_MACHINE_GUID, {
        machine_id: TEST_MACHINE_GUID,
        hostname: 'enterprise',
        status: 'online',
        last_seen: new Date().toISOString(),
        sessions: [
            { session_name: 'academy', division: 'academy', project: null, team: 'reno', name: 'academy', windows: 2, attached: true, created: new Date().toISOString(), uptime_seconds: 3600 }
        ],
        session_count: 1,
        ip: '192.168.1.1',
        os: 'macOS',
        first_seen: new Date().toISOString(),
        uptime_history: []
    });
    const { app } = createApp({ machines });
    const res = await request(app).get('/api/fleet');
    assert.ok(res.body.fleet.divisions['academy']);
    assert.equal(res.body.fleet.divisions['academy'].total_sessions, 1);
});

// ============================================================================
// PUT /api/machine/:machineId/nickname
// ============================================================================

test('PUT /api/machine/:id/nickname sets a nickname', async () => {
    const machines = new Map();
    machines.set(TEST_MACHINE_GUID, {
        machine_id: TEST_MACHINE_GUID,
        hostname: 'enterprise',
        nickname: null
    });
    const { app } = createApp({ machines });

    const res = await request(app)
        .put(`/api/machine/${TEST_MACHINE_GUID}/nickname`)
        .send({ nickname: 'Big E' });

    assert.equal(res.status, 200);
    assert.equal(res.body.success, true);
    assert.equal(res.body.nickname, 'Big E');
    assert.equal(machines.get(TEST_MACHINE_GUID).nickname, 'Big E');
});

test('PUT /api/machine/:id/nickname clears nickname on empty string', async () => {
    const machines = new Map();
    machines.set(TEST_MACHINE_GUID, { machine_id: TEST_MACHINE_GUID, hostname: 'enterprise', nickname: 'Big E' });
    const { app } = createApp({ machines });

    const res = await request(app)
        .put(`/api/machine/${TEST_MACHINE_GUID}/nickname`)
        .send({ nickname: '' });

    assert.equal(res.status, 200);
    assert.equal(res.body.nickname, null);
});

test('PUT /api/machine/:id/nickname clears nickname on null', async () => {
    const machines = new Map();
    machines.set(TEST_MACHINE_GUID, { machine_id: TEST_MACHINE_GUID, hostname: 'enterprise', nickname: 'Big E' });
    const { app } = createApp({ machines });

    const res = await request(app)
        .put(`/api/machine/${TEST_MACHINE_GUID}/nickname`)
        .send({ nickname: null });

    assert.equal(res.status, 200);
    assert.equal(res.body.nickname, null);
});

test('PUT /api/machine/:id/nickname returns 404 for unknown machine', async () => {
    const { app } = createApp();
    const res = await request(app)
        .put('/api/machine/nonexistent-id/nickname')
        .send({ nickname: 'Ghost' });
    assert.equal(res.status, 404);
    assert.ok(res.body.error);
});

test('PUT /api/machine/:id/nickname trims whitespace', async () => {
    const machines = new Map();
    machines.set(TEST_MACHINE_GUID, { machine_id: TEST_MACHINE_GUID, hostname: 'enterprise', nickname: null });
    const { app } = createApp({ machines });

    const res = await request(app)
        .put(`/api/machine/${TEST_MACHINE_GUID}/nickname`)
        .send({ nickname: '  Trimmed  ' });

    assert.equal(res.body.nickname, 'Trimmed');
});

// ============================================================================
// GET /api/machine/:id/history
// ============================================================================

test('GET /api/machine/:id/history returns paginated empty history', async () => {
    const { app } = createApp();
    const res = await request(app).get(`/api/machine/${TEST_MACHINE_GUID}/history`);
    assert.equal(res.status, 200);
    assert.equal(res.body.machine_id, TEST_MACHINE_GUID);
    assert.ok(typeof res.body.total === 'number');
    assert.ok(Array.isArray(res.body.entries));
});

test('GET /api/machine/:id/history respects limit query param', async () => {
    const { app } = createApp();
    const res = await request(app).get(`/api/machine/${TEST_MACHINE_GUID}/history?limit=10`);
    assert.equal(res.status, 200);
    assert.equal(res.body.limit, 10);
});

test('GET /api/machine/:id/history respects offset query param', async () => {
    const { app } = createApp();
    const res = await request(app).get(`/api/machine/${TEST_MACHINE_GUID}/history?offset=5`);
    assert.equal(res.status, 200);
    assert.equal(res.body.offset, 5);
});

// ============================================================================
// GET /api/backup-status
// ============================================================================

test('GET /api/backup-status returns not_configured when no machines have backup data', async () => {
    const { app } = createApp();
    const res = await request(app).get('/api/backup-status');
    assert.equal(res.status, 200);
    assert.equal(res.body.status, 'not_configured');
});

test('GET /api/backup-status returns configured when machine has backup_status', async () => {
    const machines = new Map();
    machines.set(TEST_MACHINE_GUID, {
        machine_id: TEST_MACHINE_GUID,
        hostname: 'enterprise',
        backup_status: {
            boards: { academy: { lastCheck: new Date().toISOString() } }
        }
    });
    const { app } = createApp({ machines });
    const res = await request(app).get('/api/backup-status');
    assert.equal(res.status, 200);
    assert.equal(res.body.status, 'configured');
});

// ============================================================================
// GET /api/machines/list
// ============================================================================

test('GET /api/machines/list returns empty list with no machines', async () => {
    const { app } = createApp();
    const res = await request(app).get('/api/machines/list');
    assert.equal(res.status, 200);
    assert.deepEqual(res.body.machines, []);
    assert.equal(res.body.total, 0);
    assert.equal(res.body.online, 0);
    assert.equal(res.body.offline, 0);
});

test('GET /api/machines/list shows online machines first', async () => {
    const machines = new Map();
    const staleTime = new Date(Date.now() - 10 * 60 * 1000).toISOString();
    const freshTime = new Date().toISOString();
    // Alpha is offline, Zephyr is online — Zephyr should come first
    machines.set('aaaaaaaa-1111-4111-8111-111111111111', {
        machine_id: 'aaaaaaaa-1111-4111-8111-111111111111',
        hostname: 'alpha',
        status: 'online',
        last_seen: staleTime, // will go offline after fleet parse
        sessions: [], session_count: 0, ip: '1.1.1.1', os: 'macOS', first_seen: staleTime, uptime_history: []
    });
    machines.set('zzzzzzzz-2222-4222-8222-222222222222', {
        machine_id: 'zzzzzzzz-2222-4222-8222-222222222222',
        hostname: 'zephyr',
        status: 'online',
        last_seen: freshTime,
        sessions: [], session_count: 0, ip: '2.2.2.2', os: 'macOS', first_seen: freshTime, uptime_history: []
    });
    const { app } = createApp({ machines });
    const res = await request(app).get('/api/machines/list');
    assert.equal(res.status, 200);
    // zephyr (online) should appear before alpha (offline)
    assert.equal(res.body.machines[0].hostname, 'zephyr');
});

// ============================================================================
// GET /api/active-divisions
// ============================================================================

test('GET /api/active-divisions returns empty when no online machines', async () => {
    const { app } = createApp();
    const res = await request(app).get('/api/active-divisions');
    assert.equal(res.status, 200);
    assert.deepEqual(res.body.divisions, []);
    assert.equal(res.body.source, 'live_fleet_data');
});
