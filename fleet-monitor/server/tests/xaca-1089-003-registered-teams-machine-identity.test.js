//
//  xaca-1089-003-registered-teams-machine-identity.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1089 subitem 003 (server half): GET /api/registered-teams surfaces
 * the per-team `machines` map that POST /api/team-register (subitem 002)
 * writes, per the signed-off design in kanban knowledge doc
 * XACA-1089-001-identity-contract.md. Full rationale lives in server.js's
 * header comments on enrichTeamMachineEntry() and the GET route itself;
 * this suite exercises the behavioral contract:
 *
 *   - `machines` is ALWAYS present, `{}` when nothing has asserted --
 *     including for a team record persisted BEFORE 002 shipped, which has
 *     no `machines` key at all (Q5 back-compat, same posture as the write
 *     side)
 *   - a team with two asserted machines surfaces both (Q4 -- a set, never
 *     a scalar)
 *   - Join A (contract §9.2): enriches a slug entry with live status from
 *     the server's UNRELATED global `machines` Map when the stored
 *     `machineId` GUID resolves there
 *   - Join A degrades gracefully -- omits the enrichment, never throws,
 *     never drops the slug entry -- for BOTH asymmetric cases MEASURED
 *     LIVE in the contract (global machines Map has 4 entries, vault
 *     registry has 3; `jasons-mac-mini` has a GUID and no vault/slug
 *     identity at all):
 *       (a) the stored `machineId` is null
 *       (b) the stored `machineId` GUID has no entry in the global Map
 *           (the `jasons-mac-mini`-shaped case, inverted: here it's the
 *           TEAM side missing the GUID, not the machine side missing the
 *           slug -- same asymmetry, opposite direction)
 *   - the pre-existing 13 fields are all still present and unchanged
 *     (back-compat for five dashboards reading this endpoint)
 *
 * SECURITY (XACA-0416/XACA-0989): this suite also asserts that Join A's
 * `machineInfo` enrichment NEVER surfaces the global machine's `hostname`
 * or `nickname` -- both are unconstrained free text (arbitrary
 * client-supplied FQDN / user-set string) and this endpoint's JSON is
 * rendered via innerHTML in five dashboard apps. Only type-constrained
 * fields (boolean, enum, ISO timestamp, number) are exposed.
 *
 * TEST ISOLATION (mirrors xaca-1089-002-team-register-machine-identity):
 *   Sets FLEET_VAULT_FILE to a unique per-process temp path BEFORE
 *   requiring vault-store (transitively, via app-factory.js) so this suite
 *   never touches the real data/vault.json and is parallel-safe.
 */

const fs   = require('fs');
const path = require('path');
const os   = require('os');

const TEST_VAULT_FILE = path.join(os.tmpdir(), `xaca-1089-003-vault-${process.pid}-${Date.now()}.json`);
process.env.FLEET_VAULT_FILE = TEST_VAULT_FILE;

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const { createApp } = require('./helpers/app-factory.js');
const vaultStore = require('../lib/vault-store');

const VALID_SLUG_1 = 'darren-m3pro';
const VALID_SLUG_2 = 'darren-m1pro';
const GUID_1 = 'bc68b987-1b86-4795-b131-615e992cdcaf';
const GUID_2 = 'f8bd91c5-9b06-4cd5-807e-5e4b601fe185';
// A GUID that has a slug/vault identity but no entry in the global machines
// Map -- e.g. never reported via POST /api/status, or removed by
// cleanupLegacyMachines() on startup. This is the inverse of the
// `jasons-mac-mini` shape (GUID with no slug); here it's a slug with a
// machineId that resolves to nothing on the global-Map side.
const GUID_WITH_NO_GLOBAL_ENTRY = '11111111-2222-3333-4444-555555555555';

function seedVault(slugs) {
    vaultStore.writeVault({
        version: 1,
        updated_at: new Date().toISOString(),
        machines: slugs.map((id) => ({ id, label: id, public_key: 'not-real-but-findMachine-does-not-check-this' })),
        secrets: []
    });
}

before(() => {
    assert.equal(vaultStore.VAULT_FILE, TEST_VAULT_FILE, 'VAULT_FILE must resolve to the isolated temp path');
});

beforeEach(() => {
    seedVault([VALID_SLUG_1, VALID_SLUG_2]);
});

after(() => {
    try { fs.unlinkSync(TEST_VAULT_FILE); } catch (_) {}
    const dir = path.dirname(TEST_VAULT_FILE);
    const base = path.basename(TEST_VAULT_FILE);
    try { fs.unlinkSync(path.join(dir, `${base}.tmp.${process.pid}`)); } catch (_) {}
});

function validTeamPayload(overrides = {}) {
    return {
        team: 'academy',
        teamName: 'Academy Engineering',
        organization: 'starfleet',
        orgColor: 'operations-gold',
        kanbanDir: '/tmp/kanban',
        terminals: { reno: { persona: 'Jett Reno', role: 'Chief Engineer' } },
        ...overrides
    };
}

// A minimal, valid entry for the GLOBAL `machines` Map (the one declared
// near the top of server.js / passed as opts.machines to createApp, keyed
// by machine.machine_id || machine.hostname) -- shaped like what
// POST /api/status actually stores.
function globalMachineEntry(overrides = {}) {
    return {
        machine_id: GUID_1,
        hostname: 'darren-m3pro-mbp.tail4637d5.ts.net',
        nickname: 'M3 Pro <script>alert(1)</script>', // deliberately hostile -- must never leak into the response
        ip: '100.64.0.1',
        os: 'darwin',
        first_seen: '2026-09-01T00:00:00.000Z',
        last_seen: '2026-09-04T15:01:00.000Z',
        status: 'online',
        sessions: [],
        session_count: 3,
        uptime_history: [],
        backup_status: null,
        lcars_services: [],
        ...overrides
    };
}

// ============================================================================
// Q5: backward compatibility -- machines always present, {} default
// ============================================================================

test('pre-002 team record (no machines key at all) projects as {} on GET, not undefined', async () => {
    const preChangeRecord = {
        team: 'academy',
        teamName: 'ACADEMY',
        subtitle: '',
        ship: '',
        series: '',
        organization: 'starfleet',
        orgColor: 'lavender',
        kanbanDir: '/tmp/kanban',
        fleetMonitorUrl: 'http://localhost:3000',
        terminals: { reno: { persona: 'Jett Reno' } },
        registeredAt: '2026-01-01T00:00:00.000Z',
        lastSeen: '2026-01-01T00:00:00.000Z'
        // NOTE: deliberately no `machines` key -- pre-XACA-1089-002 shape.
    };
    const seededTeams = new Map([['academy', preChangeRecord]]);
    const { app } = createApp({ registeredTeams: seededTeams });

    const res = await request(app).get('/api/registered-teams');
    assert.equal(res.status, 200);
    const team = res.body.teams.find((t) => t.team === 'academy');
    assert.ok(team, 'team must still be present');
    assert.ok(Object.prototype.hasOwnProperty.call(team, 'machines'), 'machines key must be present, not absent');
    assert.notEqual(team.machines, undefined);
    assert.notEqual(team.machines, null);
    assert.deepEqual(team.machines, {}, 'pre-002 record must project as {}, never undefined/null');
    assert.equal(team.machineCount, 0);
});

test('team registered with no machineSlug reads back machines: {} and machineCount: 0', async () => {
    const { app } = createApp();
    await request(app).post('/api/team-register').send(validTeamPayload());

    const res = await request(app).get('/api/registered-teams');
    const team = res.body.teams.find((t) => t.team === 'academy');
    assert.deepEqual(team.machines, {});
    assert.equal(team.machineCount, 0);
});

// ============================================================================
// Q4: a team with two asserted machines surfaces both
// ============================================================================

test('a team with two asserted machines surfaces both on GET, with machineCount 2', async () => {
    const { app } = createApp();
    await request(app).post('/api/team-register').send(validTeamPayload({ machineSlug: VALID_SLUG_1, machineId: GUID_1 }));
    await request(app).post('/api/team-register').send(validTeamPayload({ machineSlug: VALID_SLUG_2, machineId: GUID_2 }));

    const res = await request(app).get('/api/registered-teams');
    const team = res.body.teams.find((t) => t.team === 'academy');
    assert.deepEqual(Object.keys(team.machines).sort(), [VALID_SLUG_1, VALID_SLUG_2].sort());
    assert.equal(team.machineCount, 2);
    assert.equal(team.machines[VALID_SLUG_1].machineId, GUID_1);
    assert.equal(team.machines[VALID_SLUG_2].machineId, GUID_2);
});

// ============================================================================
// Join A: enrichment when the GUID resolves in the global machines Map
// ============================================================================

test('Join A: enriches a slug entry when its machineId GUID resolves in the global machines Map', async () => {
    const seededMachines = new Map([[GUID_1, globalMachineEntry({ machine_id: GUID_1, status: 'online', session_count: 3, last_seen: '2026-09-04T15:01:00.000Z' })]]);
    const { app } = createApp({ machines: seededMachines });
    await request(app).post('/api/team-register').send(validTeamPayload({ machineSlug: VALID_SLUG_1, machineId: GUID_1 }));

    const res = await request(app).get('/api/registered-teams');
    const team = res.body.teams.find((t) => t.team === 'academy');
    const entry = team.machines[VALID_SLUG_1];

    assert.ok(entry.machineInfo, 'machineInfo enrichment must be present when the GUID resolves');
    assert.equal(entry.machineInfo.online, true);
    assert.equal(entry.machineInfo.status, 'online');
    assert.equal(entry.machineInfo.lastHeartbeat, '2026-09-04T15:01:00.000Z');
    assert.equal(entry.machineInfo.sessionCount, 3);
});

test('Join A: online is false when the global machine status is offline', async () => {
    const seededMachines = new Map([[GUID_1, globalMachineEntry({ machine_id: GUID_1, status: 'offline' })]]);
    const { app } = createApp({ machines: seededMachines });
    await request(app).post('/api/team-register').send(validTeamPayload({ machineSlug: VALID_SLUG_1, machineId: GUID_1 }));

    const res = await request(app).get('/api/registered-teams');
    const team = res.body.teams.find((t) => t.team === 'academy');
    assert.equal(team.machines[VALID_SLUG_1].machineInfo.online, false);
    assert.equal(team.machines[VALID_SLUG_1].machineInfo.status, 'offline');
});

test('SECURITY: Join A enrichment never surfaces hostname or nickname from the global machines Map', async () => {
    const seededMachines = new Map([[GUID_1, globalMachineEntry({ machine_id: GUID_1 })]]);
    const { app } = createApp({ machines: seededMachines });
    await request(app).post('/api/team-register').send(validTeamPayload({ machineSlug: VALID_SLUG_1, machineId: GUID_1 }));

    const res = await request(app).get('/api/registered-teams');
    const raw = JSON.stringify(res.body);
    assert.ok(!raw.includes('tail4637d5.ts.net'), 'hostname must never appear in the response');
    assert.ok(!raw.includes('<script>'), 'nickname (hostile free text) must never appear in the response');

    const team = res.body.teams.find((t) => t.team === 'academy');
    const info = team.machines[VALID_SLUG_1].machineInfo;
    assert.deepEqual(
        Object.keys(info).sort(),
        ['lastHeartbeat', 'online', 'sessionCount', 'status'].sort(),
        'machineInfo must only ever contain these type-constrained fields'
    );
});

// ============================================================================
// Join A: graceful degradation
// ============================================================================

test('Join A degrades cleanly when the stored machineId is null: no machineInfo, slug entry retained', async () => {
    const { app } = createApp();
    await request(app).post('/api/team-register').send(validTeamPayload({ machineSlug: VALID_SLUG_1 })); // no machineId

    const res = await request(app).get('/api/registered-teams');
    const team = res.body.teams.find((t) => t.team === 'academy');
    const entry = team.machines[VALID_SLUG_1];

    assert.ok(entry, 'slug entry must still be present');
    assert.equal(entry.machineId, null);
    assert.ok(!Object.prototype.hasOwnProperty.call(entry, 'machineInfo'), 'machineInfo must be omitted, not null/undefined-valued');
});

test('Join A degrades cleanly when the machineId GUID has no entry in the global machines Map (jasons-mac-mini-shaped, inverted): no machineInfo, slug entry retained, no throw', async () => {
    // Global machines Map deliberately does NOT contain GUID_WITH_NO_GLOBAL_ENTRY --
    // mirrors the live fleet asymmetry (contract §3.2): a GUID this team asserted
    // that never (or no longer) has a corresponding entry in the global Map.
    const { app } = createApp();
    const res1 = await request(app).post('/api/team-register').send(validTeamPayload({ machineSlug: VALID_SLUG_1, machineId: GUID_WITH_NO_GLOBAL_ENTRY }));
    assert.equal(res1.status, 201);

    const res = await request(app).get('/api/registered-teams');
    assert.equal(res.status, 200, 'GET must not throw/500 when a stored machineId is absent from the global Map');
    const team = res.body.teams.find((t) => t.team === 'academy');
    const entry = team.machines[VALID_SLUG_1];

    assert.ok(entry, 'slug entry must still be present');
    assert.equal(entry.machineId, GUID_WITH_NO_GLOBAL_ENTRY);
    assert.ok(!Object.prototype.hasOwnProperty.call(entry, 'machineInfo'), 'machineInfo must be omitted when the GUID does not resolve');
});

test('the live-fleet asymmetry in the OTHER direction: a global machine with a GUID and no team/slug identity at all does not appear anywhere and causes no error (jasons-mac-mini, as measured)', async () => {
    // jasons-mac-mini: a GUID in the global machines Map with no vault/slug
    // identity and no team ever asserting it. Nothing in this endpoint's
    // output should reference it.
    const JASONS_GUID = '7e1db15a-5fe7-43ea-b4c4-2e439922d152';
    const seededMachines = new Map([[JASONS_GUID, globalMachineEntry({ machine_id: JASONS_GUID, hostname: 'jasons-mac-mini.tail4637d5.ts.net', nickname: null })]]);
    const { app } = createApp({ machines: seededMachines });
    await request(app).post('/api/team-register').send(validTeamPayload({ machineSlug: VALID_SLUG_1, machineId: GUID_1 }));

    const res = await request(app).get('/api/registered-teams');
    assert.equal(res.status, 200);
    const raw = JSON.stringify(res.body);
    assert.ok(!raw.includes('jasons-mac-mini'), 'a machine nobody asserted must never surface in registered-teams output');
    assert.ok(!raw.includes(JASONS_GUID));
});

// ============================================================================
// Back-compat: the pre-existing 13 fields are all still present, unchanged
// ============================================================================

test('back-compat: all 13 pre-existing fields remain present and unchanged alongside the new machines/machineCount fields', async () => {
    const { app } = createApp();
    await request(app).post('/api/team-register').send(validTeamPayload({
        teamName: 'Academy Engineering',
        subtitle: 'Sub',
        ship: 'USS Cerritos',
        series: 'LD',
        orgColor: 'operations-gold',
        fleetMonitorUrl: 'http://localhost:9999'
    }));

    const res = await request(app).get('/api/registered-teams');
    const team = res.body.teams.find((t) => t.team === 'academy');

    const expectedPreExistingFields = [
        'team', 'teamName', 'subtitle', 'ship', 'series', 'organization',
        'orgColor', 'kanbanDir', 'fleetMonitorUrl', 'terminalCount',
        'terminals', 'registeredAt', 'lastSeen'
    ];
    for (const field of expectedPreExistingFields) {
        assert.ok(Object.prototype.hasOwnProperty.call(team, field), `pre-existing field '${field}' must still be present`);
    }

    assert.equal(team.team, 'academy');
    assert.equal(team.teamName, 'Academy Engineering');
    assert.equal(team.subtitle, 'Sub');
    assert.equal(team.ship, 'USS Cerritos');
    assert.equal(team.series, 'LD');
    assert.equal(team.organization, 'starfleet');
    assert.equal(team.orgColor, 'operations-gold');
    assert.equal(team.kanbanDir, '/tmp/kanban');
    assert.equal(team.fleetMonitorUrl, 'http://localhost:9999');
    assert.equal(team.terminalCount, 1);
    assert.deepEqual(team.terminals, { reno: { persona: 'Jett Reno', role: 'Chief Engineer' } });
    assert.ok(typeof team.registeredAt === 'string');
    assert.ok(typeof team.lastSeen === 'string');

    // And the two new fields are additive, not replacing anything.
    assert.ok(Object.prototype.hasOwnProperty.call(team, 'machines'));
    assert.ok(Object.prototype.hasOwnProperty.call(team, 'machineCount'));
});

test('top-level response shape (teams/total/timestamp) is unchanged', async () => {
    const { app } = createApp();
    await request(app).post('/api/team-register').send(validTeamPayload());
    const res = await request(app).get('/api/registered-teams');
    assert.ok(Array.isArray(res.body.teams));
    assert.equal(res.body.total, res.body.teams.length);
    assert.ok(typeof res.body.timestamp === 'string');
});
