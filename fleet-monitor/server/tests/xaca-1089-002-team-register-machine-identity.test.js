//
//  xaca-1089-002-team-register-machine-identity.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1089 subitem 002 (server half): POST /api/team-register accepts and
 * persists an optional machine identity (`machineSlug` + `machineId`) per
 * the signed-off design in kanban knowledge doc
 * XACA-1089-001-identity-contract.md. Full Q1-Q7 rationale lives in
 * server.js's header comment on this route; this suite exercises the
 * behavioral contract:
 *
 *   - old clients (no machineSlug/machineId) register unchanged, and read
 *     back `machines: {}` (Q5 back-compat)
 *   - a valid, vault-registered slug is stored under a MAP key, never a
 *     scalar (Q4) -- the regression test for the whole subitem is TWO
 *     different machines registering the SAME team and BOTH persisting
 *   - an invalid slug (bad chars, wrong case, too long, injection attempt)
 *     is rejected with 400 and nothing is stored (Q3 mandatory validation --
 *     XACA-0416/XACA-0989 innerHTML sinks)
 *   - a slug that is syntactically valid but not in the vault registry is
 *     also rejected with 400 (Q3 membership check)
 *   - a pre-change persisted record (no `machines` key at all) degrades to
 *     `machines: {}` rather than crashing on the next POST (Q5)
 *   - the POST response always echoes `machines`, {} included (Q7)
 *
 * TEST ISOLATION (mirrors vault-store.test.js / vault-routes.test.js):
 *   Sets FLEET_VAULT_FILE to a unique per-process temp path BEFORE requiring
 *   vault-store (transitively, via app-factory.js) so this suite never
 *   touches the real data/vault.json and is parallel-safe.
 */

const fs   = require('fs');
const path = require('path');
const os   = require('os');

// Point the store at an isolated temp file BEFORE anything requires
// vault-store. vault-store (and app-factory.js, which requires it) resolves
// VAULT_FILE at module-load time, so this env var must be set first -- same
// discipline as every other suite in this directory that touches the vault.
const TEST_VAULT_FILE = path.join(os.tmpdir(), `xaca-1089-002-vault-${process.pid}-${Date.now()}.json`);
process.env.FLEET_VAULT_FILE = TEST_VAULT_FILE;

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const { createApp } = require('./helpers/app-factory.js');
const vaultStore = require('../lib/vault-store');

// ---------------------------------------------------------------------------
// Vault fixture: two "real" vault-registered machines + helper to seed them.
// writeVault() performs no field validation (that's validateMachineFields'
// job, for the /api/vault/machines route layer only) so a minimal
// {id, label, public_key} shape is sufficient to make findMachine() resolve.
// ---------------------------------------------------------------------------

const VALID_SLUG_1 = 'darren-m3pro';
const VALID_SLUG_2 = 'darren-m4-mini';
const VALID_GUID_1 = 'bc68b987-1b86-4795-b131-615e992cdcaf';

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
    assert.ok(!vaultStore.VAULT_FILE.includes(path.join('data', 'vault.json')), 'must not point at real data/vault.json');
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

// Minimal valid team registration payload (mirrors team-routes.test.js's
// helper, plus this subitem's new optional fields).
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

// ============================================================================
// Q5: backward compatibility -- old clients unaffected
// ============================================================================

test('no machineSlug: registers unchanged and reads back machines: {}', async () => {
    const { app } = createApp();
    const res = await request(app).post('/api/team-register').send(validTeamPayload());
    assert.equal(res.status, 201);
    assert.deepEqual(res.body.machines, {}, 'response must echo machines: {} even when none was sent');
});

test('no machineSlug: stored team record also carries machines: {}, not absent/null', async () => {
    const { app, state } = createApp();
    await request(app).post('/api/team-register').send(validTeamPayload());
    const stored = state.registeredTeams.get('academy');
    assert.ok(stored.machines !== undefined, 'machines must be present on the stored record');
    assert.ok(stored.machines !== null, 'machines must not be null');
    assert.deepEqual(stored.machines, {});
});

// ============================================================================
// Q3/Q4: valid slug accepted and stored
// ============================================================================

test('valid, vault-registered machineSlug: registers and is stored under the slug key', async () => {
    const { app, state } = createApp();
    const res = await request(app).post('/api/team-register').send(validTeamPayload({ machineSlug: VALID_SLUG_1, machineId: VALID_GUID_1 }));
    assert.equal(res.status, 201);
    assert.deepEqual(Object.keys(res.body.machines), [VALID_SLUG_1]);
    assert.equal(res.body.machines[VALID_SLUG_1].machineId, VALID_GUID_1);
    assert.ok(typeof res.body.machines[VALID_SLUG_1].lastSeen === 'string' && res.body.machines[VALID_SLUG_1].lastSeen.length > 0);

    const stored = state.registeredTeams.get('academy');
    assert.deepEqual(Object.keys(stored.machines), [VALID_SLUG_1]);
});

test('valid machineSlug with no machineId: stored machineId is null, not absent', async () => {
    const { app } = createApp();
    const res = await request(app).post('/api/team-register').send(validTeamPayload({ machineSlug: VALID_SLUG_1 }));
    assert.equal(res.status, 201);
    assert.equal(res.body.machines[VALID_SLUG_1].machineId, null);
});

// ============================================================================
// Q4: THE regression test -- two different machines registering the SAME
// team must BOTH persist. A scalar field would let the second overwrite the
// first; this is the exact last-writer-wins flap the map shape exists to
// prevent (contract §5, `_kb_register_team` fires on every terminal start).
// ============================================================================

test('REGRESSION (Q4): two machines registering the same team both persist -- neither overwrites the other', async () => {
    const { app, state } = createApp();

    const res1 = await request(app).post('/api/team-register').send(validTeamPayload({ machineSlug: VALID_SLUG_1 }));
    assert.equal(res1.status, 201);
    assert.deepEqual(Object.keys(res1.body.machines).sort(), [VALID_SLUG_1]);

    // Second registration of the SAME team from a DIFFERENT machine.
    const res2 = await request(app).post('/api/team-register').send(validTeamPayload({ machineSlug: VALID_SLUG_2 }));
    assert.equal(res2.status, 200, 'second registration of an existing team is an update (200), not a create (201)');
    assert.deepEqual(
        Object.keys(res2.body.machines).sort(),
        [VALID_SLUG_1, VALID_SLUG_2].sort(),
        'both machines must be present in the response echo -- neither was dropped'
    );

    const stored = state.registeredTeams.get('academy');
    assert.deepEqual(
        Object.keys(stored.machines).sort(),
        [VALID_SLUG_1, VALID_SLUG_2].sort(),
        'the stored record must retain BOTH machines -- a scalar field would have let slug 2 clobber slug 1'
    );
});

test('re-registering the SAME slug updates its lastSeen without duplicating or dropping the other machine', async () => {
    const { app, state } = createApp();
    await request(app).post('/api/team-register').send(validTeamPayload({ machineSlug: VALID_SLUG_1 }));
    await request(app).post('/api/team-register').send(validTeamPayload({ machineSlug: VALID_SLUG_2 }));

    const firstLastSeen = state.registeredTeams.get('academy').machines[VALID_SLUG_1].lastSeen;

    // Re-assert slug 1 again.
    await new Promise((resolve) => setTimeout(resolve, 5));
    const res3 = await request(app).post('/api/team-register').send(validTeamPayload({ machineSlug: VALID_SLUG_1 }));
    assert.deepEqual(Object.keys(res3.body.machines).sort(), [VALID_SLUG_1, VALID_SLUG_2].sort());

    const stored = state.registeredTeams.get('academy');
    assert.equal(Object.keys(stored.machines).length, 2, 'must still be exactly 2 machines, not 3');
    assert.notEqual(stored.machines[VALID_SLUG_1].lastSeen, firstLastSeen, 'lastSeen for the re-asserted slug must advance');
});

// ============================================================================
// Q3: mandatory SLUG_RE validation BEFORE storage -- XACA-0416/XACA-0989
// innerHTML sinks. Nothing must be stored on rejection.
// ============================================================================

const INVALID_SLUGS = [
    ['uppercase (Darren-M3Pro)', 'Darren-M3Pro'],
    ['leading digit (9foo)', '9foo'],
    ['too long (65 chars)', 'a'.repeat(65)],
    ['script injection', '<script>alert(1)</script>']
];

for (const [label, badSlug] of INVALID_SLUGS) {
    test(`invalid machineSlug rejected with 400 and nothing stored: ${label}`, async () => {
        const { app, state } = createApp();
        const res = await request(app).post('/api/team-register').send(validTeamPayload({ machineSlug: badSlug }));
        assert.equal(res.status, 400);
        assert.equal(res.body.code, 'INVALID_MACHINE_SLUG');
        assert.equal(state.registeredTeams.has('academy'), false, 'a rejected registration must not create a team record at all');
    });
}

test('65-char slug is exactly one over the limit (boundary check)', async () => {
    const exactly64 = 'a' + 'b'.repeat(63);
    assert.equal(exactly64.length, 64);
    seedVault([exactly64]);
    const { app } = createApp();
    const res = await request(app).post('/api/team-register').send(validTeamPayload({ machineSlug: exactly64 }));
    assert.equal(res.status, 201, 'a 64-char slug that matches SLUG_RE and is in the vault registry must be accepted');
});

// ============================================================================
// Q3: vault-registry membership check -- syntactically valid but unknown
// slugs are rejected too (this is the "client-asserted, not authenticated"
// mitigation from contract §4).
// ============================================================================

test('syntactically valid machineSlug NOT in the vault registry is rejected with 400 and nothing stored', async () => {
    const { app, state } = createApp();
    const res = await request(app).post('/api/team-register').send(validTeamPayload({ machineSlug: 'nobody-registered-this-slug' }));
    assert.equal(res.status, 400);
    assert.equal(res.body.code, 'MACHINE_NOT_IN_VAULT_REGISTRY');
    assert.equal(state.registeredTeams.has('academy'), false);
});

// ============================================================================
// machineId validation
// ============================================================================

test('invalid machineId (not a UUID) rejected with 400 and nothing stored', async () => {
    const { app, state } = createApp();
    const res = await request(app).post('/api/team-register').send(validTeamPayload({ machineSlug: VALID_SLUG_1, machineId: 'not-a-uuid' }));
    assert.equal(res.status, 400);
    assert.equal(res.body.code, 'INVALID_MACHINE_ID');
    assert.equal(state.registeredTeams.has('academy'), false);
});

test('machineId sent without machineSlug: accepted, but recorded on no machine (honest partial outcome per contract §2)', async () => {
    const { app } = createApp();
    const res = await request(app).post('/api/team-register').send(validTeamPayload({ machineId: VALID_GUID_1 }));
    assert.equal(res.status, 201);
    assert.deepEqual(res.body.machines, {}, 'without a slug there is nothing to key the machineId under -- no kb-msg benefit, and that is the documented honest outcome');
});

// ============================================================================
// Q5: a record persisted BEFORE this change (no `machines` key at all) must
// degrade to {} on the next write, never crash.
// ============================================================================

test('pre-change persisted record (no machines key) degrades to {} rather than crashing on next POST', async () => {
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
        // NOTE: deliberately no `machines` key -- this is the pre-XACA-1089-002 shape.
    };
    const seededTeams = new Map([['academy', preChangeRecord]]);
    const { app, state } = createApp({ registeredTeams: seededTeams });

    assert.doesNotThrow(() => {
        // Registering again (no new machineSlug) must not throw despite the
        // existing record having no `machines` field to spread.
    });

    const res = await request(app).post('/api/team-register').send(validTeamPayload());
    assert.equal(res.status, 200, 'registering an existing team is an update');
    assert.deepEqual(res.body.machines, {}, 'must degrade to {} rather than crash or leak undefined');

    const stored = state.registeredTeams.get('academy');
    assert.deepEqual(stored.machines, {});
});

test('pre-change persisted record + a fresh machineSlug: upgrades cleanly to a one-entry map', async () => {
    const preChangeRecord = {
        team: 'academy',
        organization: 'starfleet',
        kanbanDir: '/tmp/kanban',
        terminals: { reno: {} },
        registeredAt: '2026-01-01T00:00:00.000Z',
        lastSeen: '2026-01-01T00:00:00.000Z'
    };
    const seededTeams = new Map([['academy', preChangeRecord]]);
    const { app, state } = createApp({ registeredTeams: seededTeams });

    const res = await request(app).post('/api/team-register').send(validTeamPayload({ machineSlug: VALID_SLUG_1 }));
    assert.equal(res.status, 200);
    assert.deepEqual(Object.keys(res.body.machines), [VALID_SLUG_1]);

    const stored = state.registeredTeams.get('academy');
    assert.deepEqual(Object.keys(stored.machines), [VALID_SLUG_1]);
});

// ============================================================================
// Q7: the POST response must ALWAYS echo `machines` -- this is the "server
// deployed and accepted/rejected" vs "server not deployed at all" detector.
// ============================================================================

test('response always includes a machines key, on every success path', async () => {
    const { app } = createApp();
    const resNoSlug = await request(app).post('/api/team-register').send(validTeamPayload());
    assert.ok(Object.prototype.hasOwnProperty.call(resNoSlug.body, 'machines'));

    const resWithSlug = await request(app).post('/api/team-register').send(validTeamPayload({ team: 'ios', machineSlug: VALID_SLUG_1 }));
    assert.ok(Object.prototype.hasOwnProperty.call(resWithSlug.body, 'machines'));
});
