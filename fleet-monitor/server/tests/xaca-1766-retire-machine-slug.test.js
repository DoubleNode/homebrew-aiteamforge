//
//  xaca-1766-retire-machine-slug.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1766-002: admin-tier endpoints that retire a stale machine slug from the registered-teams
 * `machines` map. Contract: kanban/plans/XACA-1766/retire-contract.md, test cases C7 1-10
 * (case 11 is the client's bats suite).
 *
 *   E1  DELETE /api/registered-teams/:team/machines/:slug
 *   E2  DELETE /api/registered-teams/machines/:slug
 *
 * Two layers, on purpose:
 *   - app-factory.js mirror + the REAL lib/registered-teams-retire.js and the REAL auth middleware
 *     (cases 1-8, 10), with temp dirs only.
 *   - server.js as a real child process with FLEET_TEAMS_FILE pointed at a temp dir (the only way to
 *     exercise the shipping saveRegisteredTeams() and handlers rather than the mirror).
 */

const fs = require('fs');
const os = require('os');
const net = require('net');
const path = require('path');
const { spawn } = require('child_process');

// Isolated vault BEFORE anything requires vault-store (team-register validates slugs against it).
const TEST_VAULT_FILE = path.join(os.tmpdir(), `xaca-1766-vault-${process.pid}-${Date.now()}.json`);
process.env.FLEET_VAULT_FILE = TEST_VAULT_FILE;

const { test, before, after, beforeEach, describe } = require('node:test');
const assert = require('node:assert/strict');
const request = require('./helpers/loopback-request');
const { createApp } = require('./helpers/app-factory.js');
const vaultStore = require('../lib/vault-store');
const { sanitizeAuditEntry, createRetireAudit, writeTeamsFileAtomic } = require('../lib/registered-teams-retire');

const FLEET_TOKEN = 'test-fleet-token-xaca-1766-not-real';
const ADMIN_TOKEN = 'test-admin-token-xaca-1766-not-real';
const SERVER_DIR = path.join(__dirname, '..');

const SLUG_A = 'darren-m3pro';
const SLUG_B = 'darren-m4-mini';

before(() => {
    process.env.FLEET_AUTH_TOKEN = FLEET_TOKEN;
    process.env.FLEET_ADMIN_TOKEN = ADMIN_TOKEN;
    assert.equal(vaultStore.VAULT_FILE, TEST_VAULT_FILE, 'must use the isolated vault');
});

after(() => {
    delete process.env.FLEET_AUTH_TOKEN;
    delete process.env.FLEET_ADMIN_TOKEN;
    try { fs.unlinkSync(TEST_VAULT_FILE); } catch (_) { /* noop */ }
});

beforeEach(() => {
    vaultStore.writeVault({
        version: 1,
        updated_at: new Date().toISOString(),
        machines: [SLUG_A, SLUG_B].map((id) => ({ id, label: id, public_key: 'not-real' })),
        secrets: []
    });
});

const admin = (r) => r.set('Authorization', `Bearer ${ADMIN_TOKEN}`);

function seedTeams() {
    return new Map([
        ['academy', {
            team: 'academy', teamName: 'Academy', organization: 'starfleet', kanbanDir: '/tmp/k', terminals: { reno: {} },
            registeredAt: '2026-01-01T00:00:00.000Z', lastSeen: '2026-11-01T00:00:00.000Z',
            machines: {
                [SLUG_A]: { machineId: 'bc68b987-1b86-4795-b131-615e992cdcaf', lastSeen: '2026-11-01T00:00:00.000Z' },
                [SLUG_B]: { machineId: null, lastSeen: '2026-11-02T00:00:00.000Z' }
            }
        }],
        ['ios', {
            team: 'ios', teamName: 'iOS', organization: 'acme', kanbanDir: '/tmp/k2', terminals: { a: {} },
            registeredAt: '2026-01-01T00:00:00.000Z', lastSeen: '2026-11-01T00:00:00.000Z',
            machines: { [SLUG_A]: { machineId: null, lastSeen: '2026-11-03T00:00:00.000Z' } }
        }],
        ['dns', {
            team: 'dns', teamName: 'DNS', organization: 'acme', kanbanDir: '/tmp/k3', terminals: { a: {} },
            registeredAt: '2026-01-01T00:00:00.000Z', lastSeen: '2026-11-01T00:00:00.000Z',
            machines: { [SLUG_B]: { machineId: null, lastSeen: '2026-11-04T00:00:00.000Z' } }
        }]
    ]);
}

function readAudit(file) {
    if (!fs.existsSync(file)) return [];
    return fs.readFileSync(file, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
}

function mk(opts = {}) {
    const registeredTeams = opts.registeredTeams || seedTeams();
    const made = createApp(Object.assign({ registeredTeams }, opts));
    return Object.assign({ registeredTeams }, made);
}

const E1 = (team, slug) => `/api/registered-teams/${team}/machines/${slug}`;
const E2 = (slug) => `/api/registered-teams/machines/${slug}`;

// ---------------------------------------------------------------------------
// C7.1 auth tier
// ---------------------------------------------------------------------------
test('C7.1 E1/E2: fleet-tier key and no key are refused; admin key is accepted', async () => {
    const { app, registeredTeams } = mk();
    for (const url of [E1('academy', SLUG_A), E2(SLUG_A)]) {
        const fleet = await request(app).delete(url).set('Authorization', `Bearer ${FLEET_TOKEN}`);
        assert.equal(fleet.status, 401, `${url}: fleet token must be refused`);
        const none = await request(app).delete(url);
        assert.equal(none.status, 401, `${url}: no credential must be refused`);
    }
    assert.ok(registeredTeams.get('academy').machines[SLUG_A], 'refused calls must not mutate');
    assert.equal((await admin(request(app).delete(E1('academy', SLUG_A)))).status, 200);
    assert.equal((await admin(request(app).delete(E2(SLUG_B)))).status, 200);
});

// ---------------------------------------------------------------------------
// C7.2 / C7.3 scope
// ---------------------------------------------------------------------------
test('C7.2 E1 removes only the named team\'s slug; other teams and other slugs untouched', async () => {
    const { app, registeredTeams } = mk();
    const res = await admin(request(app).delete(E1('academy', SLUG_A)));
    assert.equal(res.status, 200);
    assert.equal(res.body.success, true);
    assert.equal(res.body.scope, 'team');
    assert.equal(res.body.slug, SLUG_A);
    assert.deepEqual(res.body.removedFrom, ['academy']);
    assert.equal(res.body.removed.academy.machineId, 'bc68b987-1b86-4795-b131-615e992cdcaf');
    assert.deepEqual(Object.keys(res.body.machines), ['academy']);
    assert.deepEqual(Object.keys(res.body.machines.academy), [SLUG_B]);
    assert.deepEqual(Object.keys(registeredTeams.get('academy').machines), [SLUG_B]);
    assert.ok(registeredTeams.get('ios').machines[SLUG_A], 'ios keeps the slug');
    assert.ok(registeredTeams.get('dns').machines[SLUG_B], 'dns untouched');
});

test('C7.3 E2 removes the slug from every team that has it; removedFrom lists exactly those teams', async () => {
    const { app, registeredTeams } = mk();
    const res = await admin(request(app).delete(E2(SLUG_A)));
    assert.equal(res.status, 200);
    assert.equal(res.body.scope, 'machine');
    assert.deepEqual([...res.body.removedFrom].sort(), ['academy', 'ios']);
    assert.deepEqual(Object.keys(res.body.removed).sort(), ['academy', 'ios']);
    assert.ok(!(SLUG_A in registeredTeams.get('academy').machines));
    assert.ok(!(SLUG_A in registeredTeams.get('ios').machines));
    assert.deepEqual(registeredTeams.get('ios').machines, {}, 'machines may become {} and the team stays registered');
    assert.ok(registeredTeams.get('academy').machines[SLUG_B], 'other slug on the same team untouched');
    assert.ok(registeredTeams.get('dns').machines[SLUG_B], 'unrelated team untouched');
    assert.equal(registeredTeams.size, 3, 'no team record is ever deleted');
});

// ---------------------------------------------------------------------------
// C7.4 errors
// ---------------------------------------------------------------------------
test('C7.4 404 TEAM_NOT_REGISTERED, 404 SLUG_NOT_REGISTERED (E1 and E2), 400 INVALID_MACHINE_SLUG', async () => {
    const { app, registeredTeams } = mk();
    const before = JSON.stringify([...registeredTeams]);

    let r = await admin(request(app).delete(E1('nope', SLUG_A)));
    assert.equal(r.status, 404);
    assert.equal(r.body.code, 'TEAM_NOT_REGISTERED');

    r = await admin(request(app).delete(E1('dns', SLUG_A)));
    assert.equal(r.status, 404);
    assert.equal(r.body.code, 'SLUG_NOT_REGISTERED');

    r = await admin(request(app).delete(E2('no-such-machine')));
    assert.equal(r.status, 404);
    assert.equal(r.body.code, 'SLUG_NOT_REGISTERED');

    // A well-formed slug that is not in the vault registry is still retirable-shaped (decommissioned machines
    // may already be gone from it): it reaches the 404, not a 400.
    assert.ok(!vaultStore.findMachine('gone-from-vault'));

    for (const bad of ['..%2Fx', 'UPPER', '9starts-digit', 'has_underscore', 'a'.repeat(65), '__proto__']) {
        for (const url of [E1('academy', bad), E2(bad)]) {
            r = await admin(request(app).delete(url));
            assert.equal(r.status, 400, `${url} should be 400`);
            assert.equal(r.body.code, 'INVALID_MACHINE_SLUG');
        }
    }
    // The exact-length boundary is valid (reaches 404, not 400).
    r = await admin(request(app).delete(E2('a'.repeat(64))));
    assert.equal(r.status, 404);
    assert.equal(JSON.stringify([...registeredTeams]), before, 'error paths never mutate');
});

test('C7.4 a slug that is also an Object.prototype name cannot be "found" on an empty machines map', async () => {
    const teams = seedTeams();
    teams.get('dns').machines = {};
    const { app } = mk({ registeredTeams: teams });
    // "constructor" matches SLUG_RE; hasOwnProperty semantics must make it a 404, not a phantom hit.
    const r = await admin(request(app).delete(E1('dns', 'constructor')));
    assert.equal(r.status, 404);
    assert.equal(r.body.code, 'SLUG_NOT_REGISTERED');
});

// ---------------------------------------------------------------------------
// C7.5 persistence
// ---------------------------------------------------------------------------
test('C7.5 persistence: the slug is absent from TEAMS_FILE on disk and survives a restart (reload)', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca-1766-persist-'));
    const teamsFile = path.join(dir, 'registered-teams.json');
    try {
        const { app } = mk({ teamsFile });
        assert.equal((await admin(request(app).delete(E2(SLUG_A)))).status, 200);

        const onDisk = JSON.parse(fs.readFileSync(teamsFile, 'utf8'));
        assert.ok(!(SLUG_A in onDisk.academy.machines));
        assert.ok(!(SLUG_A in onDisk.ios.machines));
        assert.ok(SLUG_B in onDisk.academy.machines);

        // "Restart": a fresh app seeded only from the file, as loadRegisteredTeams() does.
        const reloaded = new Map(Object.entries(onDisk));
        const { app: app2 } = mk({ registeredTeams: reloaded });
        const list = await request(app2).get('/api/registered-teams');
        const academy = list.body.teams.find((t) => t.team === 'academy');
        assert.ok(!(SLUG_A in academy.machines));
    } finally {
        fs.rmSync(dir, { recursive: true, force: true });
    }
});

// ---------------------------------------------------------------------------
// C7.6 plain delete
// ---------------------------------------------------------------------------
test('C7.6 plain delete: team-register with the slug re-adds it', async () => {
    const { app, registeredTeams } = mk();
    assert.equal((await admin(request(app).delete(E1('academy', SLUG_A)))).status, 200);
    assert.ok(!(SLUG_A in registeredTeams.get('academy').machines));

    const reg = await request(app).post('/api/team-register')
        .set('Authorization', `Bearer ${FLEET_TOKEN}`)
        .send({ team: 'academy', organization: 'starfleet', kanbanDir: '/tmp/k', terminals: { reno: {} }, machineSlug: SLUG_A });
    assert.equal(reg.status, 200);
    assert.ok(registeredTeams.get('academy').machines[SLUG_A], 'the slug came back');
    assert.ok(registeredTeams.get('academy').machines[SLUG_B], 'and team-register did not clear siblings');
});

// ---------------------------------------------------------------------------
// C7.7 audit
// ---------------------------------------------------------------------------
test('C7.7 audit: exactly one allowlisted line per successful call, with prior; no credential ever lands', async () => {
    const { app, retireAuditFile } = mk();
    assert.equal((await admin(request(app).delete(E2(SLUG_A))).set('X-Forwarded-For', '203.0.113.9')).status, 200);
    let lines = readAudit(retireAuditFile);
    assert.equal(lines.length, 1);
    const [l] = lines;
    assert.deepEqual(Object.keys(l).sort(), ['at', 'prior', 'requestId', 'scope', 'slug', 'teams', 'tier']);
    assert.match(l.requestId, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/, 'XACA-1766-011: every real call carries a minted UUID');
    assert.equal(l.tier, 'admin');
    assert.equal(l.scope, 'machine');
    assert.equal(l.slug, SLUG_A);
    assert.deepEqual([...l.teams].sort(), ['academy', 'ios']);
    assert.deepEqual(l.prior.academy, { machineId: 'bc68b987-1b86-4795-b131-615e992cdcaf', lastSeen: '2026-11-01T00:00:00.000Z' });
    assert.ok(!Number.isNaN(Date.parse(l.at)));

    assert.equal((await admin(request(app).delete(E1('dns', SLUG_B)))).status, 200);
    lines = readAudit(retireAuditFile);
    assert.equal(lines.length, 2, 'one line per successful call');
    assert.notEqual(lines[0].requestId, lines[1].requestId, 'each call gets its own requestId');

    // Failed calls write nothing.
    assert.equal((await admin(request(app).delete(E2('nobody')))).status, 404);
    assert.equal(readAudit(retireAuditFile).length, 2);

    const raw = fs.readFileSync(retireAuditFile, 'utf8');
    assert.ok(!raw.includes(ADMIN_TOKEN), 'admin token must never be in the audit');
    assert.ok(!raw.includes('203.0.113.9'), 'no IPs/headers in the audit');
    assert.equal(fs.statSync(retireAuditFile).mode & 0o777, 0o600);
});

test('C7.7 audit allowlist is enforced in code: planted keys and secret-shaped requestId are dropped', () => {
    const planted = sanitizeAuditEntry({
        at: '2026-11-10T00:00:00.000Z', tier: 'admin', scope: 'team', slug: SLUG_A, teams: ['academy', 7, { x: 1 }],
        prior: { academy: { machineId: 'm', lastSeen: 't', authorization: `Bearer ${ADMIN_TOKEN}`, extra: 1 } },
        requestId: `Bearer ${ADMIN_TOKEN}`,
        authorization: `Bearer ${ADMIN_TOKEN}`, headers: { cookie: 'x' }, ip: '203.0.113.9', body: { a: 1 }
    });
    assert.deepEqual(Object.keys(planted).sort(), ['at', 'prior', 'scope', 'slug', 'teams', 'tier']);
    assert.deepEqual(planted.teams, ['academy']);
    assert.deepEqual(Object.keys(planted.prior.academy).sort(), ['lastSeen', 'machineId']);
    assert.ok(!JSON.stringify(planted).includes(ADMIN_TOKEN));
    assert.equal(sanitizeAuditEntry({ requestId: 'req-123.abc' }).requestId, 'req-123.abc');
});

// ---------------------------------------------------------------------------
// C7.8 fail-closed
// ---------------------------------------------------------------------------
test('C7.8 audit append failure -> 500 AUDIT_WRITE_FAILED and NO mutation, no save', async () => {
    let saves = 0;
    const { app, registeredTeams } = mk({
        appendRetireAudit: () => { throw new Error('disk full'); },
        saveRegisteredTeams: () => { saves++; return true; }
    });
    const before = JSON.stringify([...registeredTeams]);
    const res = await admin(request(app).delete(E2(SLUG_A)));
    assert.equal(res.status, 500);
    assert.equal(res.body.code, 'AUDIT_WRITE_FAILED');
    assert.equal(JSON.stringify([...registeredTeams]), before);
    assert.equal(saves, 0, 'must not persist when the audit could not be written');
});

test('C7.8 save failure -> 500 PERSIST_FAILED, in-memory pre-image restored, persist_failed audit line', async () => {
    const { app, registeredTeams, retireAuditFile } = mk({ saveRegisteredTeams: () => false });
    const before = JSON.stringify([...registeredTeams]);
    const res = await admin(request(app).delete(E2(SLUG_A)));
    assert.equal(res.status, 500);
    assert.equal(res.body.code, 'PERSIST_FAILED');
    assert.equal(JSON.stringify([...registeredTeams]), before, 'memory restored exactly (values and order)');
    const lines = readAudit(retireAuditFile);
    assert.equal(lines.length, 2, 'attempt line plus the failure line');
    assert.equal(lines[0].result, undefined);
    assert.equal(lines[1].result, 'persist_failed');
    assert.ok(lines[0].requestId, 'attempt line carries a requestId');
    assert.equal(lines[1].requestId, lines[0].requestId, 'XACA-1766-011: the failure line correlates to its attempt line');
    assert.equal(lines[1].slug, SLUG_A);
    assert.deepEqual([...lines[1].teams].sort(), ['academy', 'ios']);
});

test('C7.8 a real unwritable teams file makes the mirror save return false -> PERSIST_FAILED', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca-1766-ro-'));
    const blocker = path.join(dir, 'blocker');
    fs.writeFileSync(blocker, 'a file where a directory is needed');
    try {
        const { app, registeredTeams } = mk({ teamsFile: path.join(blocker, 'registered-teams.json') });
        const res = await admin(request(app).delete(E1('academy', SLUG_A)));
        assert.equal(res.status, 500);
        assert.equal(res.body.code, 'PERSIST_FAILED');
        assert.ok(registeredTeams.get('academy').machines[SLUG_A], 'restored');
    } finally {
        fs.rmSync(dir, { recursive: true, force: true });
    }
});

// ---------------------------------------------------------------------------
// C7.9 inventory / mirror wiring (the inventory + drift suites carry the full checks)
// ---------------------------------------------------------------------------
test('XACA-1766-012 a failed save leaves the previous teams file intact (temp + rename, never truncate)', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca-1766-atomic-'));
    const teamsFile = path.join(dir, 'registered-teams.json');
    try {
        const { app, registeredTeams } = mk({ teamsFile });
        fs.writeFileSync(teamsFile, JSON.stringify(Object.fromEntries(registeredTeams), null, 2));
        const before = fs.readFileSync(teamsFile, 'utf8');
        // Block the temp path with a directory: the write fails BEFORE the rename, as a full disk would.
        fs.mkdirSync(`${teamsFile}.tmp-${process.pid}`);
        const res = await admin(request(app).delete(E1('academy', SLUG_A)));
        assert.equal(res.status, 500);
        assert.equal(res.body.code, 'PERSIST_FAILED');
        assert.equal(fs.readFileSync(teamsFile, 'utf8'), before, 'previous file byte-identical, not truncated');
        assert.ok(registeredTeams.get('academy').machines[SLUG_A], 'memory restored too');
    } finally {
        fs.rmSync(dir, { recursive: true, force: true });
    }
});

test('XACA-1766-012 writeTeamsFileAtomic replaces the file and leaves no temp behind', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca-1766-atomic-ok-'));
    const f = path.join(dir, 'sub', 'registered-teams.json');
    try {
        writeTeamsFileAtomic(f, { a: 1 });
        writeTeamsFileAtomic(f, { a: 2 });
        assert.deepEqual(JSON.parse(fs.readFileSync(f, 'utf8')), { a: 2 });
        assert.deepEqual(fs.readdirSync(path.dirname(f)), ['registered-teams.json']);
    } finally {
        fs.rmSync(dir, { recursive: true, force: true });
    }
});

test('C7.9 server.js registers E1 and E2 on requireAdminKey, and the mirror registers both', () => {
    const server = fs.readFileSync(path.join(SERVER_DIR, 'server.js'), 'utf8');
    const mirror = fs.readFileSync(path.join(__dirname, 'helpers', 'app-factory.js'), 'utf8');
    for (const [src, name] of [[server, 'server.js'], [mirror, 'app-factory.js']]) {
        assert.match(src, /app\.delete\(\s*'\/api\/registered-teams\/:team\/machines\/:slug',\s*requireAdminKey/, `${name} E1`);
        assert.match(src, /app\.delete\(\s*'\/api\/registered-teams\/machines\/:slug',\s*requireAdminKey/, `${name} E2`);
    }
    const adminTier = fs.readFileSync(path.join(__dirname, 'xaca-0398-003-admin-tier.test.js'), 'utf8');
    assert.ok(adminTier.includes("'/api/registered-teams/:team/machines/:slug'"));
    assert.ok(adminTier.includes("'/api/registered-teams/machines/:slug'"));
});

// ---------------------------------------------------------------------------
// C7.10 GET count
// ---------------------------------------------------------------------------
test('C7.10 GET /api/registered-teams: machineCount decrements after retire', async () => {
    const { app } = mk();
    const count = async (team) => (await request(app).get('/api/registered-teams')).body.teams.find((t) => t.team === team).machineCount;
    assert.equal(await count('academy'), 2);
    assert.equal((await admin(request(app).delete(E1('academy', SLUG_A)))).status, 200);
    assert.equal(await count('academy'), 1);
    assert.equal(await count('ios'), 1, 'other team unchanged by E1');
    assert.equal((await admin(request(app).delete(E2(SLUG_A)))).status, 200);
    assert.equal(await count('ios'), 0);
});

// ---------------------------------------------------------------------------
// Real server.js child process: the shipping handlers + the shipping saveRegisteredTeams()
// ---------------------------------------------------------------------------
function getFreePort() {
    return new Promise((resolve, reject) => {
        const srv = net.createServer();
        srv.on('error', reject);
        srv.listen(0, '127.0.0.1', () => {
            const { port } = srv.address();
            srv.close(() => resolve(port));
        });
    });
}

describe('server.js (live child process) with FLEET_TEAMS_FILE in a temp dir', () => {
    let child;
    let baseUrl;
    let dir;
    let teamsFile;
    let auditFile;

    before(async () => {
        dir = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca-1766-live-'));
        teamsFile = path.join(dir, 'registered-teams.json');
        auditFile = path.join(dir, 'registered-teams-retire-audit.jsonl');
        fs.writeFileSync(teamsFile, JSON.stringify(Object.fromEntries(seedTeams())));
        const port = await getFreePort();
        baseUrl = `http://127.0.0.1:${port}`;
        const env = Object.assign({}, process.env, {
            PORT: String(port),
            FLEET_AUTH_TOKEN: FLEET_TOKEN,
            FLEET_ADMIN_TOKEN: ADMIN_TOKEN,
            FLEET_REQUIRE_AUTH: '1',
            FLEET_TEAMS_FILE: teamsFile
        });
        delete env.FLEET_VAULT_FILE;
        child = spawn(process.execPath, ['server.js'], { cwd: SERVER_DIR, env, stdio: ['ignore', 'ignore', 'ignore'] });
        const deadline = Date.now() + 20000;
        for (;;) {
            if (child.exitCode !== null) throw new Error(`server exited early: ${child.exitCode}`);
            try { if ((await fetch(`${baseUrl}/api/health`)).ok) break; } catch (_) { /* not up yet */ }
            if (Date.now() > deadline) throw new Error('server did not become ready');
            await new Promise((r) => setTimeout(r, 200));
        }
    });

    after(async () => {
        if (child && child.exitCode === null) {
            await new Promise((resolve) => { child.once('exit', resolve); child.kill('SIGTERM'); setTimeout(resolve, 3000); });
        }
        fs.rmSync(dir, { recursive: true, force: true });
    });

    const del = (url, token) => fetch(`${baseUrl}${url}`, {
        method: 'DELETE',
        headers: token ? { Authorization: `Bearer ${token}` } : {}
    });

    test('fleet token and no credential are 401; the file is untouched', async () => {
        assert.equal((await del(E2(SLUG_A), FLEET_TOKEN)).status, 401);
        assert.equal((await del(E2(SLUG_A), null)).status, 401);
        const onDisk = JSON.parse(fs.readFileSync(teamsFile, 'utf8'));
        assert.ok(onDisk.academy.machines[SLUG_A]);
        assert.ok(!fs.existsSync(auditFile));
    });

    test('E1 with the admin key: 200, persisted by the real saveRegisteredTeams(), one audit line, 0600', async () => {
        const res = await del(E1('academy', SLUG_A), ADMIN_TOKEN);
        assert.equal(res.status, 200);
        const body = await res.json();
        assert.deepEqual(body.removedFrom, ['academy']);
        const onDisk = JSON.parse(fs.readFileSync(teamsFile, 'utf8'));
        assert.ok(!(SLUG_A in onDisk.academy.machines));
        assert.ok(onDisk.ios.machines[SLUG_A], 'E1 leaves other teams');
        const lines = readAudit(auditFile);
        assert.equal(lines.length, 1);
        assert.equal(lines[0].scope, 'team');
        assert.ok(lines[0].requestId, 'live server.js path also mints a requestId (XACA-1766-011)');
        assert.equal(fs.statSync(auditFile).mode & 0o777, 0o600);
        assert.ok(!fs.readFileSync(auditFile, 'utf8').includes(ADMIN_TOKEN));
    });

    test('E2 then GET: machine-wide removal is visible in the live listing and the 404/400 codes hold', async () => {
        const res = await del(E2(SLUG_A), ADMIN_TOKEN);
        assert.equal(res.status, 200);
        assert.deepEqual((await res.json()).removedFrom, ['ios']);
        const list = await (await fetch(`${baseUrl}/api/registered-teams`)).json();
        for (const t of list.teams) assert.ok(!(SLUG_A in t.machines), `${t.team} still lists ${SLUG_A}`);
        assert.equal((await del(E2(SLUG_A), ADMIN_TOKEN)).status, 404);
        assert.equal((await (await del(E1('nope', SLUG_B), ADMIN_TOKEN)).json()).code, 'TEAM_NOT_REGISTERED');
        assert.equal((await del(E2('BAD'), ADMIN_TOKEN)).status, 400);
        assert.equal(readAudit(auditFile).length, 2);
    });
});

test('createRetireAudit throws on an unwritable target (the fail-closed signal the handler relies on)', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca-1766-aud-'));
    const blocker = path.join(dir, 'f');
    fs.writeFileSync(blocker, 'x');
    try {
        assert.throws(() => createRetireAudit(path.join(blocker, 'audit.jsonl'))({ slug: SLUG_A }));
    } finally {
        fs.rmSync(dir, { recursive: true, force: true });
    }
});
