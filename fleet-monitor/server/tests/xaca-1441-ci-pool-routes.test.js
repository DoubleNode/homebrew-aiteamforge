//
//  xaca-1441-ci-pool-routes.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1441-005 -- lib/ci-pool-routes.js (Contract C1-C4, C8).
 * Real pool store, real assignments, real auth middleware (fake env tokens);
 * fake GitHub client that THROWS on any call from a request path. NO network.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const { test, describe, after } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const express = require('express');

const FLEET = 'xaca1441-fake-fleet-token-aaaaaaaa';
const ADMIN = 'xaca1441-fake-admin-token-bbbbbbbb';
const TELEMETRY = 'xaca1441-fake-telemetry-tok-cccccc';
const SAVED = { a: process.env.FLEET_AUTH_TOKEN, b: process.env.FLEET_ADMIN_TOKEN, c: process.env.FLEET_CI_DISPATCHER };
process.env.FLEET_AUTH_TOKEN = FLEET;
process.env.FLEET_ADMIN_TOKEN = ADMIN;
delete process.env.FLEET_CI_DISPATCHER;

const { requireApiKey } = require('../lib/auth-middleware');
const { createPoolStore } = require('../lib/ci-pool-store');
const { createAssignments } = require('../lib/ci-dispatch-assignments');
const { createAudit } = require('../lib/ci-dispatch-audit');
const { registerCiPoolRoutes, validatePoll, pauseDrift, PAUSE_MARKERS, MAX_POLL_BYTES } = require('../lib/ci-pool-routes');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca1441-005-routes-'));
after(() => {
    fs.rmSync(TMP, { recursive: true, force: true });
    for (const [k, v] of [['FLEET_AUTH_TOKEN', SAVED.a], ['FLEET_ADMIN_TOKEN', SAVED.b], ['FLEET_CI_DISPATCHER', SAVED.c]]) {
        if (v === undefined) delete process.env[k]; else process.env[k] = v;
    }
});

const T0 = Date.UTC(2026, 9, 6, 12, 0, 0);
const KEY_A = `fcp_${'A'.repeat(43)}`;
const KEY_B = `fcp_${'B'.repeat(43)}`;
const JIT = 'ROUTE-JITCFG-SENTINEL-55d1e0';
const FULL = ['self-hosted', 'Linux', 'ARM64', 'fleet-pool', 'm4mini'];
let seq = 0;

function validPoll(over = {}) {
    return Object.assign({
        schemaVersion: 1, agentVersion: '1.0.0',
        capacity: {
            memTotalBytes: 17179869184, memReclaimableBytes: 4080000000, memFreePct: 45,
            swapUsedBytes: 100, swapTotalBytes: 3221225472, load1: 1.2, load5: 1, load15: 1, ncpu: 10,
            teamSessions: 6, vmState: 'running',
        },
        slots: [{ os: 'Linux', index: 1, state: 'idle', assignmentId: null }, { os: 'macOS', index: 1, state: 'busy', assignmentId: 'a_9f' }],
    }, over);
}

function setup(opts = {}) {
    const dir = path.join(TMP, `s${++seq}`);
    fs.mkdirSync(dir, { recursive: true });
    const clock = { t: T0 };
    const store = createPoolStore({ file: path.join(dir, 'ci-pool.json'), logger: { error() {} } });
    store.load();
    for (const [id, key] of [['m4mini', KEY_A], ['m1mini', KEY_B]]) {
        store.upsertMachine(id, { enabled: true });
        assert.equal(store.setHostSecret(id, key).ok, true);
    }
    const ghCalls = [];
    const gh = {
        async generateJitConfig(a) { ghCalls.push(['mint', a]); return { runnerId: 9000 + ghCalls.length, encodedJitConfig: `${JIT}-${ghCalls.length}` }; },
        async deleteRunner(a) { ghCalls.push(['delete', a]); return { deleted: true }; },
    };
    const auditFile = path.join(dir, 'audit.jsonl');
    const audit = createAudit({ path: auditFile, keep: 2, now: () => new Date(clock.t) });
    const assignments = createAssignments({ file: path.join(dir, 'state.json'), github: gh, audit, now: () => clock.t, logger: { error() {}, warn() {} } });
    let on = opts.on !== undefined ? opts.on : true;
    const dispatcher = opts.noDispatcher ? undefined : { isEnabled: () => on, alerts: () => [], queue: () => [] };
    const app = express();
    app.use(express.json({ limit: '10mb' }));
    const reg = registerCiPoolRoutes(app, Object.assign({
        store, assignments, dispatcher, audit, now: () => clock.t, logger: { error() {} },
    }, opts.deps || {}));
    const auditRows = () => (fs.existsSync(auditFile) ? fs.readFileSync(auditFile, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l)) : []);
    return { app, store, assignments, clock, ghCalls, reg, auditRows, setOn: (v) => { on = v; }, dir };
}

const bearer = (r, tok) => r.set('Authorization', `Bearer ${tok}`);
const poll = (s, key, body = validPoll()) => bearer(request(s.app).post('/api/ci-pool/agent/poll'), key).send(body);
const postState = (s, key, id, body) => bearer(request(s.app).post(`/api/ci-pool/assignments/${id}/state`), key).send(body);

async function mintFor(s, machine = 'm4mini', jobId = 100) {
    const r = await s.assignments.mint({
        job: { owner: 'acme', repo: 'widgets', jobId, runId: 5, name: 'shell-suite', labels: FULL.slice(0, 4) },
        machine, labels: FULL, os: 'Linux',
    });
    assert.equal(r.ok, true);
    return r.assignment;
}

/**
 * The auth matrix as a function so the SAME assertions run against a mutant app.
 * Returns a list of failures (empty = the gate behaves per C1).
 */
async function authMatrix(makeSetup) {
    const failures = [];
    const expect = (label, got, want) => { if (got !== want) failures.push(`${label}: got ${got}, want ${want}`); };
    const s = makeSetup();
    const a = await mintFor(s, 'm4mini');
    // poll (no body-picked machine, so wrong-machine is not applicable)
    expect('poll per-host key', (await poll(s, KEY_A)).status, 200);
    expect('poll other host key', (await poll(s, KEY_B)).status, 200);
    expect('poll fleet token', (await poll(s, FLEET)).status, 401);
    expect('poll admin token', (await poll(s, ADMIN)).status, 401);
    expect('poll telemetry token', (await poll(s, TELEMETRY)).status, 401);
    expect('poll unknown fcp key', (await poll(s, `fcp_${'C'.repeat(43)}`)).status, 401);
    expect('poll no key', (await request(s.app).post('/api/ci-pool/agent/poll').send(validPoll())).status, 401);
    expect('poll key in X-API-Key only', (await request(s.app).post('/api/ci-pool/agent/poll').set('X-API-Key', KEY_A).send(validPoll())).status, 401);
    // state
    const url = `/api/ci-pool/assignments/${a.id}/state`;
    expect('state fleet token', (await bearer(request(s.app).post(url), FLEET).send({ state: 'started' })).status, 401);
    expect('state admin token', (await bearer(request(s.app).post(url), ADMIN).send({ state: 'started' })).status, 401);
    expect('state telemetry token', (await bearer(request(s.app).post(url), TELEMETRY).send({ state: 'started' })).status, 401);
    expect('state no key', (await request(s.app).post(url).send({ state: 'started' })).status, 401);
    expect('state other machine key', (await bearer(request(s.app).post(url), KEY_B).send({ state: 'started' })).status, 404);
    return failures;
}

describe('auth matrix (C1)', () => {
    test('per-host key only: fleet/admin/telemetry/unknown/absent keys are 401; another host\'s key is 404 on foreign ids', async () => {
        assert.deepEqual(await authMatrix(() => setup()), []);
    });

    test('mutation proof: wiring requireApiKey in place of the per-host gate fails the matrix', async () => {
        const failures = await authMatrix(() => setup({ deps: { hostAuth: requireApiKey } }));
        assert.equal(failures.length > 0, true, 'the matrix must notice a fleet-tier gate on the agent routes');
        assert.equal(failures.some((f) => /fleet token/.test(f)), true);
    });

    test('every 401 body is byte-identical regardless of why', async () => {
        const s = setup();
        const bodies = new Set();
        for (const r of [await poll(s, FLEET), await poll(s, `fcp_${'C'.repeat(43)}`), await request(s.app).post('/api/ci-pool/agent/poll').send({}),
            await bearer(request(s.app).post('/api/ci-pool/agent/poll'), 'short').send({})]) {
            assert.equal(r.status, 401);
            bodies.add(r.text);
        }
        assert.equal(bodies.size, 1);
    });

    test('a cleared host key stops working immediately', async () => {
        const s = setup();
        assert.equal((await poll(s, KEY_A)).status, 200);
        s.store.clearHostSecret('m4mini');
        assert.equal((await poll(s, KEY_A)).status, 401);
    });

    test('the key picks the machine: a body or URL naming another machine changes nothing', async () => {
        const s = setup();
        await mintFor(s, 'm1mini');
        const r = await poll(s, KEY_A);
        assert.deepEqual(r.body.assignments, []);
        assert.equal((await poll(s, KEY_A, validPoll({ machine: 'm1mini' }))).status, 400, 'machine is not a poll field');
    });
});

describe('poll behaviour (C4)', () => {
    test('enabled machine receives its assignment once; the second poll has none and no config', async () => {
        const s = setup();
        const a = await mintFor(s);
        const r1 = await poll(s, KEY_A);
        assert.equal(r1.status, 200);
        assert.equal(r1.body.schemaVersion, 1);
        assert.equal(r1.body.enabled, true);
        assert.equal(r1.body.paused, false);
        assert.equal(r1.body.pollAfterSeconds, 10);
        assert.equal(r1.body.serverTime, new Date(T0).toISOString());
        assert.equal(r1.body.assignments.length, 1);
        assert.equal(r1.body.assignments[0].id, a.id);
        assert.equal(r1.body.assignments[0].jitConfig, `${JIT}-1`);
        const r2 = await poll(s, KEY_A);
        assert.deepEqual(r2.body.assignments, []);
        assert.equal(r2.text.includes(JIT), false);
        assert.deepEqual(r2.body.cancel, []);
    });

    test('the other host\'s poll never carries it', async () => {
        const s = setup();
        await mintFor(s, 'm4mini');
        const r = await poll(s, KEY_B);
        assert.deepEqual(r.body.assignments, []);
        assert.equal(r.text.includes(JIT), false);
    });

    test('paused machine: paused:true + reason, assignments empty, pending config not served', async () => {
        const s = setup();
        const a = await mintFor(s);
        s.store.upsertMachine('m4mini', { paused: true, pauseReason: 'ci-host pause' }, { by: 'op', now: T0 });
        const r = await poll(s, KEY_A);
        assert.equal(r.body.paused, true);
        assert.equal(r.body.pauseReason, 'ci-host pause');
        assert.deepEqual(r.body.assignments, []);
        assert.equal(s.assignments.get(a.id).state, 'pending');
        assert.equal(r.text.includes(JIT), false);
    });

    test('machine not enabled: enabled:false, assignments empty', async () => {
        const s = setup();
        await mintFor(s);
        s.store.upsertMachine('m4mini', { enabled: false });
        const r = await poll(s, KEY_A);
        assert.equal(r.body.enabled, false);
        assert.deepEqual(r.body.assignments, []);
    });

    test('cancel[] names un-acked kills and is still sent while paused', async () => {
        const s = setup();
        const a = await mintFor(s);
        await poll(s, KEY_A);                              // delivered
        s.clock.t += 120000;
        await s.assignments.sweep();
        s.store.upsertMachine('m4mini', { paused: true }, { by: 'op', now: s.clock.t });
        const r = await poll(s, KEY_A);
        assert.deepEqual(r.body.cancel, [a.id]);
        assert.deepEqual(r.body.assignments, []);
        await postState(s, KEY_A, a.id, { state: 'cancelled' });
        assert.deepEqual((await poll(s, KEY_A)).body.cancel, []);
    });

    test('the poll records a server-stamped report for the dispatcher', async () => {
        const s = setup();
        await poll(s, KEY_A);
        const rep = s.reg.reports.get('m4mini');
        assert.equal(rep.receivedAt, T0);
        assert.equal(rep.capacity.vmState, 'running');
        assert.equal(rep.slots.length, 2);
        assert.equal((await poll(s, KEY_A, validPoll({ receivedAt: 1 }))).status, 400, 'a client cannot stamp its own time');
    });
});

describe('dormant mode (Requirement 3)', () => {
    test('dispatcher off: enabled:false, empty assignments, slow cadence, ZERO GitHub calls', async () => {
        const s = setup({ on: false });
        await mintFor(s);                                  // a leftover from an earlier enabled run
        const callsBeforePoll = s.ghCalls.length;
        const r = await poll(s, KEY_A);
        assert.equal(r.status, 200);
        assert.equal(r.body.enabled, false);
        assert.deepEqual(r.body.assignments, []);
        assert.equal(r.body.pollAfterSeconds, 60);
        assert.equal(r.text.includes(JIT), false);
        assert.equal(s.ghCalls.length, callsBeforePoll, 'a poll never touches GitHub');
    });

    test('no dispatcher dependency: FLEET_CI_DISPATCHER unset is dormant, =1 is live', async () => {
        const s = setup({ noDispatcher: true });
        assert.equal((await poll(s, KEY_A)).body.enabled, false);
        process.env.FLEET_CI_DISPATCHER = '1';
        try { assert.equal((await poll(s, KEY_A)).body.enabled, true); } finally { delete process.env.FLEET_CI_DISPATCHER; }
    });

    test('no request path calls GitHub, enabled or not', async () => {
        const s = setup();
        const base = s.ghCalls.length;
        await poll(s, KEY_A);
        await request(s.app).get('/api/ci-pool');
        await bearer(request(s.app).put('/api/ci-pool/machines/m4mini'), ADMIN).send({ paused: true });
        await bearer(request(s.app).put('/api/ci-pool/config'), ADMIN).send({ poolLabel: 'fleet-pool' });
        assert.equal(s.ghCalls.length, base);
    });
});

describe('poll validation (C3/C8)', () => {
    test('a valid minimal report (optional fields omitted) is accepted', () => {
        const v = validPoll();
        for (const k of ['swapTotalBytes', 'load5', 'load15', 'teamSessions']) delete v.capacity[k];
        assert.equal(validatePoll(v).capacity.vmState, 'running');
    });

    const bad = [
        ['not an object', []],
        ['unknown top-level field', { ...validPoll(), extra: 1 }],
        ['unknown capacity field', (() => { const v = validPoll(); v.capacity.hacked = 1; return v; })()],
        ['missing agentVersion', (() => { const v = validPoll(); delete v.agentVersion; return v; })()],
        ['bad agentVersion', validPoll({ agentVersion: 'v 1;rm' })],
        ['missing required capacity', (() => { const v = validPoll(); delete v.capacity.memFreePct; return v; })()],
        ['string number', (() => { const v = validPoll(); v.capacity.load1 = '1.2'; return v; })()],
        ['NaN-ish (null)', (() => { const v = validPoll(); v.capacity.load1 = null; return v; })()],
        ['negative bytes', (() => { const v = validPoll(); v.capacity.swapUsedBytes = -1; return v; })()],
        ['memFreePct over 100', (() => { const v = validPoll(); v.capacity.memFreePct = 101; return v; })()],
        ['non-integer ncpu', (() => { const v = validPoll(); v.capacity.ncpu = 2.5; return v; })()],
        ['zero ncpu', (() => { const v = validPoll(); v.capacity.ncpu = 0; return v; })()],
        ['bad vmState', (() => { const v = validPoll(); v.capacity.vmState = 'paused'; return v; })()],
        ['slots not array', validPoll({ slots: {} })],
        ['too many slots', validPoll({ slots: Array.from({ length: 33 }, (_, i) => ({ os: 'Linux', index: (i % 64) + 1, state: 'idle', assignmentId: null })) })],
        ['bad slot os', validPoll({ slots: [{ os: 'Windows', index: 1, state: 'idle', assignmentId: null }] })],
        ['bad slot state', validPoll({ slots: [{ os: 'Linux', index: 1, state: 'sleeping', assignmentId: null }] })],
        ['bad slot index', validPoll({ slots: [{ os: 'Linux', index: 0, state: 'idle', assignmentId: null }] })],
        ['slot unknown field', validPoll({ slots: [{ os: 'Linux', index: 1, state: 'idle', assignmentId: null, pid: 1 }] })],
        ['slot assignmentId junk', validPoll({ slots: [{ os: 'Linux', index: 1, state: 'busy', assignmentId: '../x' }] })],
        ['duplicate slot', validPoll({ slots: [{ os: 'Linux', index: 1, state: 'idle', assignmentId: null }, { os: 'Linux', index: 1, state: 'busy', assignmentId: null }] })],
    ];
    for (const [label, body] of bad) {
        test(`400: ${label}`, async () => {
            const s = setup();
            const r = await poll(s, KEY_A, body);
            assert.equal(r.status, 400, r.text);
            assert.equal(s.reg.reports.has('m4mini'), false, 'a rejected poll records nothing (the machine reads stale)');
        });
    }

    test('schemaVersion mismatch is 400 with {error, expected} (C8)', async () => {
        const s = setup();
        for (const v of [2, 0, '1', undefined]) {
            const r = await poll(s, KEY_A, validPoll({ schemaVersion: v }));
            assert.equal(r.status, 400);
            assert.equal(r.body.expected, 1);
            assert.equal(typeof r.body.error, 'string');
        }
    });

    test('a bad poll after a good one leaves the older report to go stale rather than refreshing it', async () => {
        const s = setup();
        await poll(s, KEY_A);
        s.clock.t += 40000;
        assert.equal((await poll(s, KEY_A, validPoll({ schemaVersion: 9 }))).status, 400);
        assert.equal(s.reg.reports.get('m4mini').receivedAt, T0);
    });

    test('body over 16 KiB is 413', async () => {
        const s = setup();
        const r = await poll(s, KEY_A, validPoll({ agentVersion: '1.0.0', pad: 'x'.repeat(MAX_POLL_BYTES) }));
        assert.equal(r.status, 413);
        assert.equal(s.reg.reports.has('m4mini'), false);
    });
});

// XACA-1441-025: the optional `pauseMarker` field and the drift verdict it feeds.
describe('pauseMarker (025)', () => {
    for (const marker of PAUSE_MARKERS) {
        test(`"${marker}" is accepted, stored on the report and exposed by GET /api/ci-pool`, async () => {
            const s = setup();
            const r = await poll(s, KEY_A, validPoll({ pauseMarker: marker }));
            assert.equal(r.status, 200, r.text);
            assert.equal(s.reg.reports.get('m4mini').pauseMarker, marker);
            const g = await request(s.app).get('/api/ci-pool');
            assert.equal(g.body.machines.m4mini.pauseMarker, marker);
        });
    }

    test('no marker sent: pauseMarker and pauseDrift are null, and a later poll without one clears a stale marker', async () => {
        const s = setup();
        await poll(s, KEY_A, validPoll({ pauseMarker: 'paused' }));
        await poll(s, KEY_A);
        const g = await request(s.app).get('/api/ci-pool');
        assert.deepEqual([g.body.machines.m4mini.pauseMarker, g.body.machines.m4mini.pauseDrift], [null, null]);
        assert.deepEqual([g.body.machines.m1mini.pauseMarker, g.body.machines.m1mini.pauseDrift], [null, null], 'never polled');
    });

    for (const [label, value] of [['unlisted string', 'frozen'], ['wrong case', 'Paused'], ['empty string', ''], ['null', null], ['number', 1], ['boolean', true], ['object', {}], ['array', ['paused']]]) {
        test(`400: pauseMarker ${label}; nothing recorded`, async () => {
            const s = setup();
            const r = await poll(s, KEY_A, validPoll({ pauseMarker: value }));
            assert.equal(r.status, 400, r.text);
            assert.match(r.body.error, /pauseMarker/);
            assert.equal(s.reg.reports.has('m4mini'), false);
        });
    }

    test('unknown fields stay 400 next to a valid pauseMarker', async () => {
        const s = setup();
        assert.equal((await poll(s, KEY_A, validPoll({ pauseMarker: 'paused', pauseState: 'x' }))).status, 400);
    });

    // marker x server `paused` (true / false / absent: no machine record or a non-boolean)
    const DRIFT_TABLE = [
        // [marker, paused=true, paused=false, paused=absent]
        ['paused',   false, true,  false],
        ['draining', false, true,  false],
        ['absent',   true,  false, false],
        ['resuming', true,  false, false],
        ['corrupt',  false, false, false],
    ];
    for (const [marker, whenTrue, whenFalse, whenAbsent] of DRIFT_TABLE) {
        test(`pauseDrift truth table: marker "${marker}"`, () => {
            assert.equal(pauseDrift(marker, true), whenTrue, 'paused=true');
            assert.equal(pauseDrift(marker, false), whenFalse, 'paused=false');
            assert.equal(pauseDrift(marker, undefined), whenAbsent, 'paused absent');
        });
    }
    test('pauseDrift is null whenever the agent sent no marker', () => {
        for (const paused of [true, false, undefined, null]) {
            assert.equal(pauseDrift(undefined, paused), null);
            assert.equal(pauseDrift(null, paused), null);
        }
    });

    test('GET shows the drift verdict end to end for every marker x paused state', async () => {
        for (const [marker, whenTrue, whenFalse] of DRIFT_TABLE) {
            const s = setup();
            await bearer(request(s.app).put('/api/ci-pool/machines/m4mini'), ADMIN).send({ paused: true, reason: 'r' });
            await poll(s, KEY_A, validPoll({ pauseMarker: marker }));
            let g = await request(s.app).get('/api/ci-pool');
            assert.equal(g.body.machines.m4mini.pauseDrift, whenTrue, `${marker} vs paused=true`);
            await bearer(request(s.app).put('/api/ci-pool/machines/m4mini'), ADMIN).send({ paused: false });
            g = await request(s.app).get('/api/ci-pool');
            assert.equal(g.body.machines.m4mini.pauseDrift, whenFalse, `${marker} vs paused=false`);
        }
    });

    test('a warning is logged once per transition into drift, not on every poll', async () => {
        const lines = [];
        const s = setup({ deps: { logger: { error() {}, warn: (m) => lines.push(m) } } });
        const drifted = () => lines.filter((l) => /pause drift on m4mini/.test(l)).length;
        await poll(s, KEY_A, validPoll({ pauseMarker: 'paused' }));   // server says un-paused: drift begins
        await poll(s, KEY_A, validPoll({ pauseMarker: 'paused' }));
        await poll(s, KEY_A, validPoll({ pauseMarker: 'draining' }));
        assert.equal(drifted(), 1);
        await poll(s, KEY_A, validPoll({ pauseMarker: 'absent' }));   // agrees with paused=false: drift ends
        await poll(s, KEY_A, validPoll({ pauseMarker: 'paused' }));   // second transition
        assert.equal(drifted(), 2);
        await poll(s, KEY_A);                                         // no marker resets the state, logs nothing
        await poll(s, KEY_A, validPoll({ pauseMarker: 'paused' }));
        assert.equal(drifted(), 3);
        assert.equal(lines.some((l) => /fcp_|keyHash/.test(l)), false);
    });

    test('the marker never changes what the poll response says: the server record stays the single truth (C7)', async () => {
        const s = setup();
        const r = await poll(s, KEY_A, validPoll({ pauseMarker: 'paused' }));
        assert.equal(r.body.paused, false);
        assert.equal(s.store.getMachine('m4mini').paused, false);
    });
});

describe('config writes notify the dispatcher (029)', () => {
    const put = (s, url, body) => bearer(request(s.app).put(url), ADMIN).send(body);

    test('PUT /config and PUT /machines/:machine each call dispatcher.onConfigChanged once after a successful write', async () => {
        let calls = 0;
        const dispatcher = { isEnabled: () => true, alerts: () => [], queue: () => [], onConfigChanged: () => { calls++; } };
        const s = setup({ deps: { dispatcher } });
        assert.equal((await put(s, '/api/ci-pool/config', { allowlist: ['acme/widgets'] })).status, 200);
        assert.equal(calls, 1);
        assert.equal((await put(s, '/api/ci-pool/machines/m4mini', { prefers: 'long' })).status, 200);
        assert.equal(calls, 2);
    });

    test('a rejected write (400) does not notify', async () => {
        let calls = 0;
        const dispatcher = { isEnabled: () => true, onConfigChanged: () => { calls++; } };
        const s = setup({ deps: { dispatcher } });
        assert.equal((await put(s, '/api/ci-pool/config', { nope: 1 })).status, 400);
        assert.equal((await put(s, '/api/ci-pool/machines/m4mini', { prefers: 'medium' })).status, 400);
        assert.equal(calls, 0);
    });

    test('null-safe: no dispatcher, a dispatcher without the hook, or a throwing hook never fails the write', async () => {
        for (const dispatcher of [undefined, { isEnabled: () => false }, { isEnabled: () => true, onConfigChanged: () => { throw new Error('boom'); } }]) {
            const s = setup({ noDispatcher: dispatcher === undefined, deps: dispatcher ? { dispatcher } : {} });
            assert.equal((await put(s, '/api/ci-pool/config', { allowlist: ['acme/widgets'] })).status, 200);
            assert.equal((await put(s, '/api/ci-pool/machines/m4mini', { enabled: true })).status, 200);
        }
    });
});

describe('assignment state route (C5)', () => {
    test('idempotent repeat is 200; illegal is 409; the response never carries the config', async () => {
        const s = setup();
        const a = await mintFor(s);
        await poll(s, KEY_A);
        let r = await postState(s, KEY_A, a.id, { state: 'started' });
        assert.deepEqual([r.status, r.body], [200, { id: a.id, state: 'started' }]);
        r = await postState(s, KEY_A, a.id, { state: 'started' });
        assert.deepEqual([r.status, r.body.state], [200, 'started']);
        r = await postState(s, KEY_A, a.id, { state: 'cancelled', reason: 'stop' });
        assert.equal(r.body.state, 'cancelled');
        r = await postState(s, KEY_A, a.id, { state: 'started' });
        assert.equal(r.status, 409);
        assert.equal(r.body.state, 'cancelled');
        assert.equal(r.text.includes(JIT), false);
    });

    test('404 for unknown, malformed and another machine\'s id, with identical bodies', async () => {
        const s = setup();
        const a = await mintFor(s, 'm4mini');
        const texts = new Set();
        for (const id of ['a_00000000-0000-4000-8000-0000000000ff', 'nope', 'a_1', a.id]) {
            const key = id === a.id ? KEY_B : KEY_A;
            const r = await postState(s, key, id, { state: 'started' });
            assert.equal(r.status, 404, id);
            texts.add(r.text);
        }
        assert.equal(texts.size, 1, 'existence is not revealed');
        // ownership is decided before the body is judged
        assert.equal((await postState(s, KEY_B, a.id, { bogus: true })).status, 404);
    });

    test('invalid report bodies are 400', async () => {
        const s = setup();
        const a = await mintFor(s);
        await poll(s, KEY_A);
        for (const body of [{}, { state: 'running' }, { state: 'started', machine: 'x' }, { state: 'failed', exitCode: 1.5 },
            { state: 'failed', exitCode: 999 }, { state: 'failed', reason: 'x'.repeat(201) }, { state: 'failed', reason: 5 }, []]) {
            const r = await postState(s, KEY_A, a.id, body);
            assert.equal(r.status, 400, JSON.stringify(body));
        }
        assert.equal(s.assignments.get(a.id).state, 'delivered');
        assert.equal((await postState(s, KEY_A, a.id, { state: 'failed', exitCode: 3, reason: 'x'.repeat(200) })).status, 200);
    });
});

describe('GET /api/ci-pool redaction', () => {
    test('exposes machines, capacity and assignments but never a key, key hash or JIT config', async () => {
        const s = setup();
        await mintFor(s);
        await poll(s, KEY_A);                              // delivers; also records the report
        await mintFor(s, 'm4mini', 101);                   // a second, still pending (config in memory)
        const r = await request(s.app).get('/api/ci-pool');
        assert.equal(r.status, 200);
        const text = r.text;
        for (const secret of [KEY_A, KEY_B, JIT, 'keyHash', 'jitConfig', 'encodedJit']) assert.equal(text.includes(secret), false, secret);
        assert.equal(/[0-9a-f]{64}/.test(text), false, 'no sha256 hex anywhere');
        assert.equal(r.body.machines.m4mini.hasKey, true);
        assert.equal(r.body.machines.m4mini.hasTelemetryKey, false);
        assert.equal(r.body.machines.m4mini.lastPollAt, new Date(T0).toISOString());
        assert.equal(r.body.machines.m4mini.capacity.vmState, 'running');
        assert.equal(r.body.machines.m1mini.lastPollAt, null);
        assert.equal(r.body.dispatcherEnabled, true);
        assert.equal(r.body.assignments.length, 2);
        assert.deepEqual(Object.keys(r.body.machines.m4mini).sort(), ['agentVersion', 'capacity', 'enabled', 'hasKey', 'hasTelemetryKey', 'lastPollAt', 'pauseDrift', 'pauseMarker', 'pauseReason', 'pausedAt', 'pausedBy', 'paused', 'prefers', 'slots', 'thresholds'].sort());
    });
});

describe('operator writes (admin tier)', () => {
    const put = (s, url, tok, body) => bearer(request(s.app).put(url), tok).send(body);

    test('machine and config writes need the admin key: no key, fleet key and per-host keys are 401', async () => {
        const s = setup();
        for (const url of ['/api/ci-pool/machines/m4mini', '/api/ci-pool/config']) {
            assert.equal((await request(s.app).put(url).send({})).status, 401, url);
            assert.equal((await put(s, url, FLEET, {})).status, 401, url);
            assert.equal((await put(s, url, KEY_A, {})).status, 401, url);
        }
        assert.equal(s.store.getMachine('m4mini').paused, false);
    });

    test('pause: sets the single source of truth, server-stamps who/when, audits, and the next poll sees it', async () => {
        const s = setup();
        s.clock.t = T0 + 5000;
        const r = await put(s, '/api/ci-pool/machines/m4mini', ADMIN, { paused: true, reason: 'XACA-1440 pause' });
        assert.equal(r.status, 200);
        assert.equal(r.body.record.paused, true);
        assert.equal(r.body.record.pausedBy, 'operator');
        assert.equal(r.body.record.pausedAt, new Date(T0 + 5000).toISOString());
        assert.equal(r.body.record.hasKey, true);
        assert.equal(r.text.includes('keyHash'), false);
        assert.equal(s.store.getMachine('m4mini').paused, true);
        const p = await poll(s, KEY_A);
        assert.equal(p.body.paused, true);
        assert.equal(p.body.pauseReason, 'XACA-1440 pause');
        const row = s.auditRows().find((x) => x.event === 'pause');
        assert.deepEqual([row.machine, row.paused, row.by, row.reason], ['m4mini', true, 'operator', 'XACA-1440 pause']);
        // no audit row when nothing flipped, and unpausing clears the reason
        await put(s, '/api/ci-pool/machines/m4mini', ADMIN, { paused: true });
        assert.equal(s.auditRows().filter((x) => x.event === 'pause').length, 1);
        const u = await put(s, '/api/ci-pool/machines/m4mini', ADMIN, { paused: false });
        assert.equal(u.body.record.pauseReason, null);
        assert.equal(s.auditRows().filter((x) => x.event === 'pause').length, 2);
    });

    test('enabled / prefers / thresholds, and a brand-new machine starts dormant', async () => {
        const s = setup();
        let r = await put(s, '/api/ci-pool/machines/m3new', ADMIN, { prefers: 'long' });
        assert.equal(r.status, 200);
        assert.equal(r.body.record.enabled, false);
        assert.equal(r.body.record.hasKey, false);
        r = await put(s, '/api/ci-pool/machines/m3new', ADMIN, { enabled: true, thresholds: { memFreePct: 50 } });
        assert.deepEqual([r.body.record.enabled, r.body.record.thresholds], [true, { memFreePct: 50 }]);
    });

    test('validation: unknown fields, bad types and bad ids are 400 and change nothing', async () => {
        const s = setup();
        for (const [url, body] of [
            ['/api/ci-pool/machines/m4mini', { keyHash: 'a'.repeat(64) }],
            ['/api/ci-pool/machines/m4mini', { pausedBy: 'someone' }],
            ['/api/ci-pool/machines/m4mini', { paused: 'yes' }],
            ['/api/ci-pool/machines/m4mini', { prefers: 'medium' }],
            ['/api/ci-pool/machines/m4mini', { thresholds: { bogus: 1 } }],
            ['/api/ci-pool/machines/m4mini', []],
            ['/api/ci-pool/machines/bad%20id', { enabled: true }],
            ['/api/ci-pool/config', { nope: 1 }],
            ['/api/ci-pool/config', { allowlist: ['not a repo'] }],
            ['/api/ci-pool/config', { poolLabel: '' }],
            ['/api/ci-pool/config', []],
        ]) {
            const r = await put(s, url, ADMIN, body);
            assert.equal(r.status, 400, `${url} ${JSON.stringify(body)}`);
        }
        const m = s.store.getMachine('m4mini');
        assert.deepEqual([m.paused, m.prefers, typeof m.keyHash], [false, null, 'string']);
    });

    test('config: allowlist and pool label update and persist', async () => {
        const s = setup();
        const r = await put(s, '/api/ci-pool/config', ADMIN, { allowlist: ['acme/widgets'], poolLabel: 'fleet-pool' });
        assert.equal(r.status, 200);
        assert.deepEqual(r.body.config.allowlist, ['acme/widgets']);
        const disk = JSON.parse(fs.readFileSync(path.join(s.dir, 'ci-pool.json'), 'utf8'));
        assert.deepEqual(disk.config.allowlist, ['acme/widgets']);
        const g = await request(s.app).get('/api/ci-pool');
        assert.deepEqual(g.body.config.allowlist, ['acme/widgets']);
    });
});
