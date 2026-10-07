//
//  xaca-1422-telemetry-key.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1422 (-002, -011, server half of -012): per-host CI credentials.
 *
 * REAL pool store, REAL ci-pool routes, REAL ci-runners routes, REAL auth middleware (fake env
 * tokens). The whole wiring is driven in-process through supertest; no server, no network.
 *
 * Auth matrix under test:
 *   fct_ (telemetry)  -> POST /api/ci-runners-push only, and only for its own body.machine
 *   fcp_ (agent)      -> the two agent routes only
 *   fleet / admin     -> neither of the above
 *   mint / revoke     -> admin tier only
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const { test, describe, after } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const express = require('express');

const FLEET = 'xaca1422-fake-fleet-token-aaaaaaaa';
const ADMIN = 'xaca1422-fake-admin-token-bbbbbbbb';
const SAVED = { a: process.env.FLEET_AUTH_TOKEN, b: process.env.FLEET_ADMIN_TOKEN, c: process.env.FLEET_CI_DISPATCHER };
process.env.FLEET_AUTH_TOKEN = FLEET;
process.env.FLEET_ADMIN_TOKEN = ADMIN;
delete process.env.FLEET_CI_DISPATCHER;

const { createPoolStore } = require('../lib/ci-pool-store');
const { createAssignments } = require('../lib/ci-dispatch-assignments');
const { createAudit } = require('../lib/ci-dispatch-audit');
const { registerCiPoolRoutes, requireCiTelemetryKey } = require('../lib/ci-pool-routes');
const { registerCiRunnersRoutes } = require('../lib/ci-runners-routes');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca1422-'));
after(() => {
    fs.rmSync(TMP, { recursive: true, force: true });
    for (const [k, v] of [['FLEET_AUTH_TOKEN', SAVED.a], ['FLEET_ADMIN_TOKEN', SAVED.b], ['FLEET_CI_DISPATCHER', SAVED.c]]) {
        if (v === undefined) delete process.env[k]; else process.env[k] = v;
    }
});

let seq = 0;
const FCP_RE = /^fcp_[A-Za-z0-9_-]{43}$/;
const FCT_RE = /^fct_[A-Za-z0-9_-]{43}$/;

function setup() {
    const dir = path.join(TMP, `s${++seq}`);
    fs.mkdirSync(dir, { recursive: true });
    const poolFile = path.join(dir, 'ci-pool.json');
    const auditFile = path.join(dir, 'audit.jsonl');
    const pool = createPoolStore({ file: poolFile, logger: { error() {} } });
    pool.load();
    const audit = createAudit({ path: auditFile, keep: 2 });
    const assignments = createAssignments({
        file: path.join(dir, 'state.json'), audit, logger: { error() {}, warn() {} },
        // Nothing here dispatches; a call from any request path would be a bug.
        github: {
            async generateJitConfig() { throw new Error('GitHub must not be called'); },
            async deleteRunner() { throw new Error('GitHub must not be called'); },
        },
    });
    const app = express();
    app.use(express.json({ limit: '10mb' }));
    registerCiPoolRoutes(app, { store: pool, assignments, audit, dispatcher: { isEnabled: () => false }, logger: { error() {} } });
    const runners = registerCiRunnersRoutes(app, { file: path.join(dir, 'ci-runners.json'), poolStore: pool });
    const auditRows = () => (fs.existsSync(auditFile) ? fs.readFileSync(auditFile, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l)) : []);
    return { app, pool, runners, poolFile, auditFile, auditRows };
}

const bearer = (r, token) => r.set('Authorization', `Bearer ${token}`);
const admin = (r) => bearer(r, ADMIN);
const payload = (machine) => ({
    schema_version: 1, machine, reportedAt: '2026-10-06T14:30:00Z', reporterVersion: '1.0.0',
    host: { uptimeSeconds: 10 }, vm: null,
    runners: [{ name: `${machine}-macos-1`, serviceState: 'up', labels: ['self-hosted'], currentJob: null }],
    jobs: [],
});

/** Create machine records through the existing operator route, as the runbook does. */
async function addMachine(ctx, id) {
    const r = await admin(request(ctx.app).put(`/api/ci-pool/machines/${id}`)).send({});
    assert.equal(r.status, 200, JSON.stringify(r.body));
}
async function mint(ctx, id, kind) {
    const suffix = kind === 'telemetry' ? 'telemetry-key' : 'key';
    const r = await admin(request(ctx.app).post(`/api/ci-pool/machines/${id}/${suffix}`));
    assert.equal(r.status, 200, JSON.stringify(r.body));
    return r.body.key;
}
const push = (ctx, token, body) => {
    const req = request(ctx.app).post('/api/ci-runners-push');
    return (token ? bearer(req, token) : req).send(body);
};
const poll = (ctx, token) => bearer(request(ctx.app).post('/api/ci-pool/agent/poll'), token).send({});

const UNAUTHORIZED = { error: 'Unauthorized', code: 'unauthorized' };

// ---------------------------------------------------------------------------
describe('mint routes (admin tier)', () => {
    test('mint returns {machine,key} once: fcp_ + 43 base64url, Cache-Control: no-store, hash-only at rest', async () => {
        const ctx = setup();
        await addMachine(ctx, 'm1mini');
        const r = await admin(request(ctx.app).post('/api/ci-pool/machines/m1mini/key'));
        assert.equal(r.status, 200);
        assert.deepEqual(Object.keys(r.body).sort(), ['key', 'machine']);
        assert.equal(r.body.machine, 'm1mini');
        assert.match(r.body.key, FCP_RE);
        assert.match(r.headers['cache-control'], /no-store/);
        assert.equal(ctx.pool.verifyHostSecret('m1mini', r.body.key), true);
        assert.equal(ctx.pool.verifyTelemetrySecret('m1mini', r.body.key), false, 'independent hashes');
    });

    test('telemetry mint returns fct_ + 43 base64url, no-store, and sets only telemetryKeyHash', async () => {
        const ctx = setup();
        await addMachine(ctx, 'm1mini');
        const r = await admin(request(ctx.app).post('/api/ci-pool/machines/m1mini/telemetry-key'));
        assert.equal(r.status, 200);
        assert.deepEqual(Object.keys(r.body).sort(), ['key', 'machine']);
        assert.match(r.body.key, FCT_RE);
        assert.match(r.headers['cache-control'], /no-store/);
        const m = ctx.pool.getMachine('m1mini');
        assert.match(m.telemetryKeyHash, /^[0-9a-f]{64}$/);
        assert.equal(m.keyHash, null, 'agent key untouched');
    });

    test('two mints never return the same key', async () => {
        const ctx = setup();
        await addMachine(ctx, 'm1mini');
        assert.notEqual(await mint(ctx, 'm1mini', 'telemetry'), await mint(ctx, 'm1mini', 'telemetry'));
        assert.notEqual(await mint(ctx, 'm1mini', 'agent'), await mint(ctx, 'm1mini', 'agent'));
    });

    test('re-mint replaces the hash: the old key dies at once (agent and telemetry)', async () => {
        const ctx = setup();
        await addMachine(ctx, 'm1mini');
        const oldAgent = await mint(ctx, 'm1mini', 'agent');
        const oldTel = await mint(ctx, 'm1mini', 'telemetry');
        assert.notEqual((await poll(ctx, oldAgent)).status, 401);
        assert.equal((await push(ctx, oldTel, payload('m1mini'))).status, 200);

        const newAgent = await mint(ctx, 'm1mini', 'agent');
        const newTel = await mint(ctx, 'm1mini', 'telemetry');
        assert.deepEqual((await poll(ctx, oldAgent)).body, UNAUTHORIZED);
        assert.deepEqual((await push(ctx, oldTel, payload('m1mini'))).body, UNAUTHORIZED);
        assert.notEqual((await poll(ctx, newAgent)).status, 401);
        assert.equal((await push(ctx, newTel, payload('m1mini'))).status, 200);
    });

    test('revoke: the key gets 401 at once; the other key kind is unaffected', async () => {
        const ctx = setup();
        await addMachine(ctx, 'm1mini');
        const agent = await mint(ctx, 'm1mini', 'agent');
        const tel = await mint(ctx, 'm1mini', 'telemetry');

        let r = await admin(request(ctx.app).delete('/api/ci-pool/machines/m1mini/telemetry-key'));
        assert.equal(r.status, 200);
        assert.deepEqual(r.body, { success: true, machine: 'm1mini' });
        assert.equal((await push(ctx, tel, payload('m1mini'))).status, 401);
        assert.notEqual((await poll(ctx, agent)).status, 401, 'agent key survives a telemetry revoke');
        assert.equal(ctx.pool.getMachine('m1mini').telemetryKeyHash, null);

        r = await admin(request(ctx.app).delete('/api/ci-pool/machines/m1mini/key'));
        assert.equal(r.status, 200);
        assert.equal((await poll(ctx, agent)).status, 401);
    });

    test('unknown machine -> 404 on all four routes; bad machine id -> 400; nothing is created', async () => {
        const ctx = setup();
        for (const [method, suffix] of [['post', 'key'], ['delete', 'key'], ['post', 'telemetry-key'], ['delete', 'telemetry-key']]) {
            const r = await admin(request(ctx.app)[method](`/api/ci-pool/machines/ghost/${suffix}`));
            assert.equal(r.status, 404, `${method} ${suffix}`);
            const b = await admin(request(ctx.app)[method](`/api/ci-pool/machines/-bad/${suffix}`));
            assert.equal(b.status, 400, `${method} ${suffix} bad id`);
        }
        assert.deepEqual(ctx.pool.listMachines(), {});
    });

    test('all four routes need ADMIN: fleet token, no credential, fct_ and fcp_ are all 401', async () => {
        const ctx = setup();
        await addMachine(ctx, 'm1mini');
        const agent = await mint(ctx, 'm1mini', 'agent');
        const tel = await mint(ctx, 'm1mini', 'telemetry');
        for (const [method, suffix] of [['post', 'key'], ['delete', 'key'], ['post', 'telemetry-key'], ['delete', 'telemetry-key']]) {
            const url = `/api/ci-pool/machines/m1mini/${suffix}`;
            for (const token of [FLEET, agent, tel, null]) {
                const req = request(ctx.app)[method](url);
                const r = await (token ? bearer(req, token) : req);
                assert.equal(r.status, 401, `${method} ${suffix} with ${token ? token.slice(0, 4) : 'no credential'}`);
            }
        }
        // The credentials survived every rejected call.
        assert.notEqual((await poll(ctx, agent)).status, 401);
        assert.equal((await push(ctx, tel, payload('m1mini'))).status, 200);
    });

    test('operator view reports hasKey/hasTelemetryKey but never a hash or a key', async () => {
        const ctx = setup();
        await addMachine(ctx, 'm1mini');
        const agent = await mint(ctx, 'm1mini', 'agent');
        const tel = await mint(ctx, 'm1mini', 'telemetry');
        const r = await request(ctx.app).get('/api/ci-pool');
        assert.equal(r.status, 200);
        assert.equal(r.body.machines.m1mini.hasKey, true);
        assert.equal(r.body.machines.m1mini.hasTelemetryKey, true);
        const raw = JSON.stringify(r.body);
        const m = ctx.pool.getMachine('m1mini');
        for (const secret of [agent, tel, m.keyHash, m.telemetryKeyHash]) assert.ok(!raw.includes(secret));
    });
});

// ---------------------------------------------------------------------------
describe('POST /api/ci-runners-push auth matrix (XACA-1422-002 / -011)', () => {
    async function twoHosts() {
        const ctx = setup();
        await addMachine(ctx, 'm1mini');
        await addMachine(ctx, 'm4mini');
        ctx.agent1 = await mint(ctx, 'm1mini', 'agent');
        ctx.tel1 = await mint(ctx, 'm1mini', 'telemetry');
        ctx.agent4 = await mint(ctx, 'm4mini', 'agent');
        ctx.tel4 = await mint(ctx, 'm4mini', 'telemetry');
        return ctx;
    }

    test('fct_ with its own machine -> 200 and the record is stored', async () => {
        const ctx = await twoHosts();
        const r = await push(ctx, ctx.tel1, payload('m1mini'));
        assert.equal(r.status, 200, JSON.stringify(r.body));
        assert.equal(r.body.machine, 'm1mini');
        assert.ok(ctx.runners.machines.has('m1mini'));
    });

    test('fct_ with ANOTHER machine in body.machine -> 403 and that record is untouched', async () => {
        const ctx = await twoHosts();
        assert.equal((await push(ctx, ctx.tel4, payload('m4mini'))).status, 200);
        const before = JSON.stringify(ctx.runners.machines.get('m4mini'));

        const forged = payload('m4mini');
        forged.reporterVersion = '6.6.6';
        const r = await push(ctx, ctx.tel1, forged); // m1mini's key, m4mini's record
        assert.equal(r.status, 403);
        assert.deepEqual(r.body, { error: 'Forbidden', code: 'forbidden' });
        assert.equal(JSON.stringify(ctx.runners.machines.get('m4mini')), before, 'victim record unchanged');
        assert.ok(!ctx.runners.machines.has('m1mini'), 'nothing was written for the key holder either');
    });

    test('fct_ with a missing, non-string or invalid body.machine -> 403, nothing stored', async () => {
        const ctx = await twoHosts();
        for (const machine of [undefined, null, 42, '', ['m1mini'], { id: 'm1mini' }, 'm1mini ', 'M1MINI', 'm1mini/../x']) {
            const body = payload('m1mini');
            if (machine === undefined) delete body.machine; else body.machine = machine;
            const r = await push(ctx, ctx.tel1, body);
            assert.equal(r.status, 403, JSON.stringify(machine));
        }
        assert.equal(ctx.runners.machines.size, 0);
        assert.equal((await push(ctx, ctx.tel1, [])).status, 403, 'array body');
    });

    test('fcp_ (agent key) on ci-runners-push -> byte-identical 401', async () => {
        const ctx = await twoHosts();
        const r = await push(ctx, ctx.agent1, payload('m1mini'));
        assert.equal(r.status, 401);
        assert.deepEqual(r.body, UNAUTHORIZED);
        assert.equal(r.headers['www-authenticate'], 'Bearer');
        assert.equal(ctx.runners.machines.size, 0);
    });

    test('fleet token, admin token, no credential and malformed credentials -> 401, nothing stored', async () => {
        const ctx = await twoHosts();
        const valid = ctx.tel1;
        const malformed = [
            FLEET, ADMIN, null, 'garbage',
            `fct_${'A'.repeat(42)}`, `fct_${'A'.repeat(44)}`, `fct_${'A'.repeat(42)}!`, `FCT_${valid.slice(4)}`,
            `fct_${'A'.repeat(43)}`, // well-formed, matches no machine
            valid.replace('fct_', 'fcp_'), // right body, wrong prefix
        ];
        for (const token of malformed) {
            const r = await push(ctx, token, payload('m1mini'));
            assert.equal(r.status, 401, String(token));
            assert.deepEqual(r.body, UNAUTHORIZED);
        }
        // X-API-Key and a fleet token via the other header are no way in either.
        for (const header of ['X-API-Key', 'X-Admin-Key']) {
            const r = await request(ctx.app).post('/api/ci-runners-push').set(header, FLEET).send(payload('m1mini'));
            assert.equal(r.status, 401, header);
        }
        assert.equal(ctx.runners.machines.size, 0);
    });

    test('the telemetry key is bound to the machine it was minted for, whichever machine is listed first', async () => {
        const ctx = await twoHosts();
        assert.equal((await push(ctx, ctx.tel4, payload('m4mini'))).status, 200);
        assert.equal((await push(ctx, ctx.tel1, payload('m1mini'))).status, 200);
        assert.equal((await push(ctx, ctx.tel4, payload('m1mini'))).status, 403);
    });

    test('auth is decided before the body is validated (no key + junk body -> 401, key + wrong machine + junk -> 403)', async () => {
        const ctx = await twoHosts();
        assert.equal((await push(ctx, null, { nonsense: true })).status, 401);
        assert.equal((await push(ctx, ctx.tel1, { machine: 'm4mini', nonsense: true })).status, 403);
        assert.equal((await push(ctx, ctx.tel1, { machine: 'm1mini', nonsense: true })).status, 400);
    });

    test('a machine record with no telemetry key accepts nothing (dormant default)', async () => {
        const ctx = setup();
        await addMachine(ctx, 'm1mini');
        const r = await push(ctx, `fct_${'Z'.repeat(43)}`, payload('m1mini'));
        assert.equal(r.status, 401);
        assert.equal(ctx.pool.getMachine('m1mini').telemetryKeyHash, null);
    });

    test('revoked telemetry key -> 401 on the next push', async () => {
        const ctx = await twoHosts();
        assert.equal((await push(ctx, ctx.tel1, payload('m1mini'))).status, 200);
        await admin(request(ctx.app).delete('/api/ci-pool/machines/m1mini/telemetry-key'));
        assert.equal((await push(ctx, ctx.tel1, payload('m1mini'))).status, 401);
    });

    test('fail closed: registerCiRunnersRoutes with no pool store rejects every push, even the fleet token', async () => {
        const dir = path.join(TMP, `nostore${++seq}`);
        const app = express();
        app.use(express.json());
        const store = registerCiRunnersRoutes(app, { file: path.join(dir, 'ci-runners.json') });
        for (const token of [FLEET, ADMIN, `fct_${'A'.repeat(43)}`, null]) {
            const req = request(app).post('/api/ci-runners-push');
            const r = await (token ? bearer(req, token) : req).send(payload('m1mini'));
            assert.equal(r.status, 401);
        }
        assert.equal(store.machines.size, 0);
        assert.equal((await request(app).get('/api/ci-runners')).status, 200, 'the open GET is unaffected');
    });

    test('requireCiTelemetryKey(undefined) is a fail-closed middleware, not an open one', () => {
        const mw = requireCiTelemetryKey(undefined);
        assert.equal(mw.name, 'ciTelemetryKey');
        let nexted = false;
        const res = { status(c) { this.code = c; return this; }, set() { return this; }, json(b) { this.body = b; return this; } };
        mw({ get: () => `Bearer fct_${'A'.repeat(43)}`, body: { machine: 'm1mini' } }, res, () => { nexted = true; });
        assert.equal(nexted, false);
        assert.equal(res.code, 401);
    });
});

// ---------------------------------------------------------------------------
describe('no crossover onto the agent routes', () => {
    test('fct_, fleet token and admin token are all 401 on both agent routes; fcp_ is not', async () => {
        const ctx = setup();
        await addMachine(ctx, 'm1mini');
        const agent = await mint(ctx, 'm1mini', 'agent');
        const tel = await mint(ctx, 'm1mini', 'telemetry');
        for (const token of [tel, FLEET, ADMIN]) {
            const p = await poll(ctx, token);
            assert.equal(p.status, 401);
            assert.deepEqual(p.body, UNAUTHORIZED);
            const s = await bearer(request(ctx.app).post('/api/ci-pool/assignments/a_x/state'), token).send({ state: 'started' });
            assert.equal(s.status, 401);
        }
        assert.notEqual((await poll(ctx, agent)).status, 401);
    });
});

// ---------------------------------------------------------------------------
describe('persistence and secrecy', () => {
    test('data/ci-pool.json holds hashes only: neither plaintext key, anywhere', async () => {
        const ctx = setup();
        await addMachine(ctx, 'm1mini');
        const agent = await mint(ctx, 'm1mini', 'agent');
        const tel = await mint(ctx, 'm1mini', 'telemetry');
        const raw = fs.readFileSync(ctx.poolFile, 'utf8');
        assert.ok(!raw.includes(agent), 'agent key in plaintext');
        assert.ok(!raw.includes(tel), 'telemetry key in plaintext');
        assert.ok(!raw.includes(agent.slice(4)) && !raw.includes(tel.slice(4)), 'key body in plaintext');
        const saved = JSON.parse(raw).machines.m1mini;
        assert.match(saved.keyHash, /^[0-9a-f]{64}$/);
        assert.match(saved.telemetryKeyHash, /^[0-9a-f]{64}$/);
        assert.notEqual(saved.keyHash, saved.telemetryKeyHash);
    });

    test('hashes survive a reload: keys keep working after a restart', async () => {
        const ctx = setup();
        await addMachine(ctx, 'm1mini');
        const tel = await mint(ctx, 'm1mini', 'telemetry');
        const reloaded = createPoolStore({ file: ctx.poolFile, logger: { error() {} } });
        assert.equal(reloaded.load().ok, true);
        assert.equal(reloaded.verifyTelemetrySecret('m1mini', tel), true);
    });

    test('audit records machine + action + kind, never the key', async () => {
        const ctx = setup();
        await addMachine(ctx, 'm1mini');
        const agent = await mint(ctx, 'm1mini', 'agent');
        const tel = await mint(ctx, 'm1mini', 'telemetry');
        await admin(request(ctx.app).delete('/api/ci-pool/machines/m1mini/telemetry-key'));
        const rows = ctx.auditRows().filter((r) => r.event === 'key-mint' || r.event === 'key-revoke');
        assert.deepEqual(rows.map((r) => [r.event, r.machine, r.keyKind]), [
            ['key-mint', 'm1mini', 'agent'], ['key-mint', 'm1mini', 'telemetry'], ['key-revoke', 'm1mini', 'telemetry'],
        ]);
        const raw = fs.readFileSync(ctx.auditFile, 'utf8');
        assert.ok(!raw.includes(agent) && !raw.includes(tel));
    });

    test('a ci-pool.json from before XACA-1422 (no telemetryKeyHash) loads, reads the field as null, and is not moved aside', () => {
        const dir = path.join(TMP, `legacy${++seq}`);
        fs.mkdirSync(dir, { recursive: true });
        const file = path.join(dir, 'ci-pool.json');
        const legacy = {
            schemaVersion: 1,
            config: {
                allowlist: ['DoubleNode/dev-team'], poolLabel: 'fleet-pool', jobClasses: { bats: 'long' },
                thresholds: {
                    memReclaimableBytes: 1610612736, swapUsedBytes: 3006477107, memFreePct: 35, loadPerCpu: 0.75, pollStaleMs: 30000,
                },
            },
            machines: {
                m1mini: {
                    enabled: true, paused: false, pausedBy: null, pausedAt: null, pauseReason: null,
                    prefers: null, thresholds: {}, keyHash: 'a'.repeat(64),
                },
            },
        };
        fs.writeFileSync(file, JSON.stringify(legacy));
        const store = createPoolStore({ file, logger: { error() {} } });
        const r = store.load();
        assert.equal(r.ok, true, JSON.stringify(r));
        assert.ok(fs.existsSync(file), 'not moved aside');
        assert.deepEqual(fs.readdirSync(dir), ['ci-pool.json']);
        const m = store.getMachine('m1mini');
        assert.equal(m.telemetryKeyHash, null);
        assert.equal(m.keyHash, 'a'.repeat(64), 'existing agent hash preserved');
        assert.equal(m.enabled, true, 'existing config preserved');
        assert.equal(store.setTelemetrySecret('m1mini', `fct_${'Q'.repeat(43)}`).ok, true, 'and it can be written back');
        assert.equal(store.verifyTelemetrySecret('m1mini', `fct_${'Q'.repeat(43)}`), true);
    });

    test('the one tolerated omission is only that: other missing/unknown/malformed fields still fail closed', () => {
        const base = () => ({
            schemaVersion: 1,
            config: {
                allowlist: [], poolLabel: 'fleet-pool', jobClasses: {},
                thresholds: { memReclaimableBytes: 1, swapUsedBytes: 1, memFreePct: 35, loadPerCpu: 0.75, pollStaleMs: 30000 },
            },
            machines: {
                m1mini: {
                    enabled: false, paused: false, pausedBy: null, pausedAt: null, pauseReason: null,
                    prefers: null, thresholds: {}, keyHash: null, telemetryKeyHash: null,
                },
            },
        });
        const cases = {
            'missing keyHash': (p) => { delete p.machines.m1mini.keyHash; },
            'unknown field': (p) => { p.machines.m1mini.extra = 1; },
            'telemetryKeyHash not a sha256': (p) => { p.machines.m1mini.telemetryKeyHash = 'plaintext-key'; },
            'telemetryKeyHash wrong type': (p) => { p.machines.m1mini.telemetryKeyHash = 5; },
            'telemetryKeyHash uppercase hex': (p) => { p.machines.m1mini.telemetryKeyHash = 'A'.repeat(64); },
        };
        for (const [name, mutate] of Object.entries(cases)) {
            const dir = path.join(TMP, `bad${++seq}`);
            fs.mkdirSync(dir, { recursive: true });
            const file = path.join(dir, 'ci-pool.json');
            const p = base(); mutate(p);
            fs.writeFileSync(file, JSON.stringify(p));
            const store = createPoolStore({ file, logger: { error() {} } });
            const r = store.load();
            assert.equal(r.ok, false, name);
            assert.deepEqual(store.listMachines(), {}, `${name}: starts dormant`);
        }
    });

    test('store: set/clear/verify on an unknown machine fail; empty and non-string secrets never verify', () => {
        const dir = path.join(TMP, `st${++seq}`);
        const store = createPoolStore({ file: path.join(dir, 'ci-pool.json'), logger: { error() {} } });
        store.load();
        assert.equal(store.setTelemetrySecret('ghost', `fct_${'A'.repeat(43)}`).ok, false);
        assert.equal(store.clearTelemetrySecret('ghost').ok, false);
        assert.equal(store.verifyTelemetrySecret('ghost', `fct_${'A'.repeat(43)}`), false);
        store.upsertMachine('m1mini', {});
        assert.equal(store.setTelemetrySecret('m1mini', '').ok, false);
        for (const v of ['', null, undefined, 5, {}]) assert.equal(store.verifyTelemetrySecret('m1mini', v), false);
        assert.equal(store.getMachine('m1mini').telemetryKeyHash, null);
    });
});
