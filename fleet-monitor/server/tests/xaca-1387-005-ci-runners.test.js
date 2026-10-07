//
//  xaca-1387-005-ci-runners.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1387-005 -- full contract suite for lib/ci-runners-routes.js.
 * Push contract: fleet-monitor/docs/DATA_SCHEMA.md § "CI Runner Telemetry".
 * GET contract:  fleet-monitor/docs/CI-RUNNERS-API-CONTRACT.md (shape is
 * asserted table-driven in xaca-1387-016-contract-shape.test.js).
 *
 * Auth uses the REAL per-host telemetry gate (XACA-1422) over a real pool store, with a
 * credential minted on demand per machine. The fleet token is only used to prove it is REJECTED.
 * Every store points at a mkdtemp file -- never the real data/ path.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const { test, describe, before, after } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const express = require('express');

const TOKEN = 'xaca1387-fake-fleet-token-0001';
const SAVED_ENV = { a: process.env.FLEET_AUTH_TOKEN, b: process.env.FLEET_ADMIN_TOKEN };
process.env.FLEET_AUTH_TOKEN = TOKEN;
delete process.env.FLEET_ADMIN_TOKEN;

const { createPoolStore } = require('../lib/ci-pool-store');
const {
    registerCiRunnersRoutes, createCiRunnerStore, validatePush, validateJob,
    ValidationError, CapacityError, parseJobsLimit, MAX_BODY_BYTES, MAX_MACHINES, STALE_THRESHOLD_MS, OFFLINE_THRESHOLD_MS,
} = require('../lib/ci-runners-routes');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca1387-005-'));
let seq = 0;
const newFile = () => path.join(TMP, `ci-${++seq}`, 'ci-runners.json');

after(() => {
    fs.rmSync(TMP, { recursive: true, force: true });
    if (SAVED_ENV.a === undefined) delete process.env.FLEET_AUTH_TOKEN; else process.env.FLEET_AUTH_TOKEN = SAVED_ENV.a;
    if (SAVED_ENV.b === undefined) delete process.env.FLEET_ADMIN_TOKEN; else process.env.FLEET_ADMIN_TOKEN = SAVED_ENV.b;
});

function mount(file = newFile()) {
    const app = express();
    app.use(express.json({ limit: '10mb' })); // same global limit as server.js; the 64 KiB cap is in-route
    const pool = createPoolStore({ file: path.join(path.dirname(file), 'ci-pool.json') });
    const store = registerCiRunnersRoutes(app, { file, poolStore: pool });
    app.locals.pool = pool;
    return { app, store, file, pool };
}
const auth = (r) => r.set('Authorization', `Bearer ${TOKEN}`);
let credSeq = 0;
// Telemetry credential for `machine` (XACA-1422): creates the pool record, mints once per app.
function credFor(app, machine) {
    const pool = app.locals.pool;
    app.locals.creds = app.locals.creds || {};
    if (!app.locals.creds[machine]) {
        const cred = `fct_${String(++credSeq).padStart(43, 'k')}`;
        if (!pool.getMachine(machine)) pool.upsertMachine(machine, {});
        if (!pool.setTelemetrySecret(machine, cred).ok) return null; // unmintable id (a validation test)
        app.locals.creds[machine] = cred;
    }
    return app.locals.creds[machine];
}
// Authenticate as `machine` regardless of what the body claims.
const pushAs = (app, machine, body) => {
    const cred = credFor(app, machine);
    const req = request(app).post('/api/ci-runners-push');
    return (cred ? req.set('Authorization', `Bearer ${cred}`) : req).send(body);
};
const push = (app, body) => pushAs(app, body && body.machine, body);

const RUN_URL = 'https://github.com/DoubleNode/dev-team/actions/runs/123/job/456';
const job = (id, over = {}) => ({
    id, runner: 'm1mini-macos-1', workflow: 'CI', jobName: 'build', repo: 'DoubleNode/dev-team',
    runUrl: RUN_URL, startedAt: '2026-10-02T14:10:00Z', endedAt: '2026-10-02T14:17:30Z',
    result: 'success', minutes: 7.5, ...over,
});
const runner = (over = {}) => ({ name: 'm1mini-macos-1', serviceState: 'up', labels: ['self-hosted', 'macOS'], currentJob: null, ...over });
const payload = (over = {}) => ({
    schema_version: 1, machine: 'm1mini', reportedAt: '2026-10-02T14:30:00Z', reporterVersion: '1.0.0',
    host: { uptimeSeconds: 100, disk: { path: '/', totalBytes: 1000, freeBytes: 500 } }, vm: null,
    runners: [runner()], jobs: [job('j1')], ...over,
});

// ---------------------------------------------------------------------------
describe('1. auth (real requireApiKey)', () => {
    test('no credential -> 401 with WWW-Authenticate, nothing stored', async () => {
        const { app, store } = mount();
        const r = await request(app).post('/api/ci-runners-push').send(payload());
        assert.equal(r.status, 401);
        assert.equal(r.headers['www-authenticate'], 'Bearer');
        assert.equal(store.machines.size, 0);
    });
    test('wrong bearer -> 401', async () => {
        const { app, store } = mount();
        const r = await request(app).post('/api/ci-runners-push')
            .set('Authorization', 'Bearer wrong-wrong-wrong-wrong').send(payload());
        assert.equal(r.status, 401);
        assert.equal(store.machines.size, 0);
    });
    test('valid per-host telemetry key -> 200', async () => {
        const { app } = mount();
        const r = await push(app, payload());
        assert.equal(r.status, 200);
        assert.equal(r.body.success, true);
        assert.equal(r.body.machine, 'm1mini');
    });
    test('the fleet token (bearer or X-API-Key) is rejected: no fallback (XACA-1422)', async () => {
        const { app, store } = mount();
        assert.equal((await auth(request(app).post('/api/ci-runners-push')).send(payload())).status, 401);
        assert.equal((await request(app).post('/api/ci-runners-push').set('X-API-Key', TOKEN).send(payload())).status, 401);
        assert.equal(store.machines.size, 0);
    });
    test('a store-less registration fails closed, even for the fleet token', async () => {
        const app = express();
        app.use(express.json());
        const store = registerCiRunnersRoutes(app, { file: newFile() });
        assert.equal((await auth(request(app).post('/api/ci-runners-push')).send(payload())).status, 401);
        assert.equal(store.machines.size, 0);
    });
    test('auth is checked before body validation (bad body without key -> 401, not 400)', async () => {
        const { app } = mount();
        const r = await request(app).post('/api/ci-runners-push').send({ nonsense: true });
        assert.equal(r.status, 401);
    });
    test('GET /api/ci-runners is open (no key)', async () => {
        const { app } = mount();
        assert.equal((await request(app).get('/api/ci-runners')).status, 200);
    });
});

// ---------------------------------------------------------------------------
describe('2. schema validation', () => {
    // Authenticated as m1mini (the default payload's machine) so the request reaches validation.
    const bad = async (body, field) => {
        const { app, store } = mount();
        const r = await pushAs(app, 'm1mini', body);
        assert.equal(r.status, 400, JSON.stringify(r.body));
        if (field) assert.equal(r.body.field, field);
        assert.equal(store.machines.size, 0, 'nothing stored on 400');
        return r;
    };
    // XACA-1422: a body whose `machine` is not the key's machine never reaches validation (403).
    const refusedAtGate = async (body) => {
        const { app, store } = mount();
        const r = await pushAs(app, 'm1mini', body);
        assert.equal(r.status, 403, JSON.stringify(r.body));
        assert.equal(store.machines.size, 0, 'nothing stored on 403');
    };

    for (const f of ['schema_version', 'reportedAt', 'reporterVersion', 'host', 'vm', 'runners', 'jobs']) {
        test(`missing required field: ${f}`, async () => {
            const p = payload(); delete p[f];
            await bad(p, f);
        });
    }
    test('missing required field: machine -> 403 at the key gate (XACA-1422)', async () => {
        const p = payload(); delete p.machine;
        await refusedAtGate(p);
    });
    test('non-object body (array) -> 403 at the key gate (no machine to bind)', async () => { await refusedAtGate([]); });
    test('wrong schema_version (2, "1", null)', async () => {
        for (const v of [2, '1', null, 0]) await bad(payload({ schema_version: v }), 'schema_version');
    });
    test('bad machine ids (no key can be minted for them; 403 at the gate, never stored)', async () => {
        for (const m of ['', '-lead', '.dot', 'has space', 'a/b', 'x'.repeat(129), 42, null, 'bad\nid', '../etc']) {
            await refusedAtGate(payload({ machine: m }));
        }
    });
    test('validatePush still rejects a bad machine id itself (defence in depth)', () => {
        for (const m of ['', '-lead', 'a/b', 42, null]) {
            assert.throws(() => validatePush(payload({ machine: m })), (e) => e instanceof ValidationError && e.field === 'machine');
        }
    });
    test('good machine ids accepted (boundary 128, dots, dashes)', async () => {
        const { app } = mount();
        for (const m of ['a', 'M1-Mini.local_x'.replace('_', '-'), 'a'.repeat(128)]) {
            assert.equal((await push(app, payload({ machine: m }))).status, 200, m);
        }
    });
    test('bad reportedAt (non-UTC, no Z, offset, garbage, impossible date)', async () => {
        for (const t of ['2026-10-02T14:30:00', '2026-10-02T14:30:00+00:00', 'yesterday', 12345, null, '2026-13-45T99:99:99Z']) {
            await bad(payload({ reportedAt: t }), 'reportedAt');
        }
    });
    test('reportedAt with fractional seconds is accepted', async () => {
        const { app } = mount();
        assert.equal((await push(app, payload({ reportedAt: '2026-10-02T14:30:00.123Z' }))).status, 200);
    });
    test('reporterVersion over-length / empty / control char', async () => {
        await bad(payload({ reporterVersion: 'v'.repeat(33) }), 'reporterVersion');
        await bad(payload({ reporterVersion: '' }), 'reporterVersion');
        await bad(payload({ reporterVersion: '1.0\u0007' }), 'reporterVersion');
        const { app } = mount();
        assert.equal((await push(app, payload({ reporterVersion: 'v'.repeat(32) }))).status, 200);
    });
    test('host shape: non-object, bad uptime, bad disk', async () => {
        await bad(payload({ host: 'x' }), 'host');
        await bad(payload({ host: { uptimeSeconds: -1 } }), 'host.uptimeSeconds');
        await bad(payload({ host: { uptimeSeconds: 1.5 } }), 'host.uptimeSeconds');
        await bad(payload({ host: { uptimeSeconds: 1, disk: { path: '/', totalBytes: -1, freeBytes: 0 } } }), 'host.disk');
        await bad(payload({ host: { uptimeSeconds: 1, disk: 'x' } }), 'host.disk');
    });
    test('vm: null ok, valid object ok, bad state/shape rejected', async () => {
        const { app } = mount();
        assert.equal((await push(app, payload({ vm: { name: 'lima-x', state: 'running' } }))).status, 200);
        await bad(payload({ vm: { name: 'lima-x', state: 'exploded' } }), 'vm');
        await bad(payload({ vm: 'running' }), 'vm');
        await bad(payload({ vm: { name: '', state: 'running' } }), 'vm');
    });
    test('runners: not array, 17 runners, 16 ok, duplicate names', async () => {
        const mk = (n) => Array.from({ length: n }, (_, i) => runner({ name: `r${i}` }));
        await bad(payload({ runners: 'x' }), 'runners');
        await bad(payload({ runners: mk(17) }), 'runners');
        await bad(payload({ runners: [runner(), runner()] }), 'runners');
        const { app } = mount();
        assert.equal((await push(app, payload({ runners: mk(16) }))).status, 200);
    });
    test('runner fields: bad name, serviceState, labels, currentJob', async () => {
        await bad(payload({ runners: [runner({ name: 'has space' })] }), 'runners[0].name');
        await bad(payload({ runners: [runner({ name: 'x'.repeat(65) })] }), 'runners[0].name');
        await bad(payload({ runners: [runner({ serviceState: 'running' })] }), 'runners[0].serviceState');
        await bad(payload({ runners: [runner({ labels: 'x' })] }), 'runners[0].labels');
        await bad(payload({ runners: [runner({ labels: Array(33).fill('l') })] }), 'runners[0].labels');
        await bad(payload({ runners: [runner({ labels: ['ok', 'x'.repeat(65)] })] }), 'runners[0].labels');
        await bad(payload({ runners: [runner({ labels: ['a\u0000b'] })] }), 'runners[0].labels');
        await bad(payload({ runners: [runner({ currentJob: 'x' })] }), 'runners[0].currentJob');
        await bad(payload({ runners: [runner({ currentJob: { id: '1' } })] }));
    });
    test('runner currentJob (valid, runUrl null) is stored', async () => {
        const { app } = mount();
        const cj = { id: 'cj1', workflow: 'CI', jobName: 'b', repo: 'DoubleNode/dev-team', runUrl: null, startedAt: '2026-10-02T14:20:00Z' };
        assert.equal((await push(app, payload({ runners: [runner({ currentJob: cj })] }))).status, 200);
        const g = await request(app).get('/api/ci-runners');
        // Served in the v1 contract shape: jobName -> job, absent optionals -> null.
        assert.deepEqual(g.body.machines[0].runners[0].currentJob, {
            id: 'cj1', workflow: 'CI', job: 'b', repo: 'DoubleNode/dev-team', branch: null,
            startedAt: '2026-10-02T14:20:00Z', runUrl: null, jobUrl: null,
        });
    });
    test('missing currentJob is still a 400 (required; null = idle)', async () => {
        const r = runner(); delete r.currentJob;
        await bad(payload({ runners: [r] }), 'runners[0].currentJob');
    });
    test('jobs: not an array, 51 jobs -> 400; 50 ok', async () => {
        await bad(payload({ jobs: {} }), 'jobs');
        await bad(payload({ jobs: Array.from({ length: 51 }, (_, i) => job(`j${i}`)) }), 'jobs');
        const { app } = mount();
        const r = await push(app, payload({ jobs: Array.from({ length: 50 }, (_, i) => job(`j${i}`)) }));
        assert.equal(r.status, 200);
        assert.equal(r.body.jobsAccepted, 50);
    });
    test('control characters in strings are rejected (host.disk.path, runner label, machine)', async () => {
        await bad(payload({ host: { uptimeSeconds: 1, disk: { path: '/\u001b[31m', totalBytes: 1, freeBytes: 1 } } }), 'host.disk');
        await refusedAtGate(payload({ machine: 'm1\u0000' }));
        await refusedAtGate(payload({ machine: 'm1\u007f' }));
    });
    test('over-length job strings are per-job rejections', () => {
        for (const [k, len] of [['workflow', 129], ['jobName', 129], ['id', 129], ['runner', 65]]) {
            assert.throws(() => validateJob(job('x', { [k]: 'a'.repeat(len) })), ValidationError, k);
        }
        assert.doesNotThrow(() => validateJob(job('x', { workflow: 'a'.repeat(128), jobName: 'b'.repeat(128) })));
    });
    test('control characters in job strings are rejected', () => {
        for (const k of ['workflow', 'jobName', 'id']) {
            assert.throws(() => validateJob(job('x', { [k]: 'a\nb' })), ValidationError, k);
        }
        assert.throws(() => validateJob(job('x', { workflow: 'a\u0000' })), ValidationError);
    });
    test('bad repo values', () => {
        for (const r of ['noslash', 'a/b/c', '/x', 'x/', 'a b/c', 'o/' + 'r'.repeat(101), 'o'.repeat(40) + '/r', '', null, 5, 'a/b c']) {
            assert.throws(() => validateJob(job('x', { repo: r })), ValidationError, String(r));
        }
        assert.doesNotThrow(() => validateJob(job('x', { repo: 'Some-Org/my.repo_1-x' })));
    });
    test('runUrl: accepted variants', () => {
        for (const u of [
            'https://github.com/DoubleNode/dev-team/actions/runs/1',
            'https://github.com/DoubleNode/dev-team/actions/runs/1/attempts/2',
            'https://github.com/DoubleNode/dev-team/actions/runs/1/job/2',
            'https://github.com/DoubleNode/dev-team/actions/runs/1/attempts/2/job/3',
            null,
        ]) assert.doesNotThrow(() => validateJob(job('x', { runUrl: u })), String(u));
    });
    test('runUrl: rejected variants', () => {
        for (const u of [
            'http://github.com/DoubleNode/dev-team/actions/runs/1',
            'https://gitlab.com/DoubleNode/dev-team/actions/runs/1',
            'https://github.com.evil.com/DoubleNode/dev-team/actions/runs/1',
            'https://evil.com/https://github.com/DoubleNode/dev-team/actions/runs/1',
            'https://github.com/DoubleNode/dev-team/actions/runs/1/',
            'https://github.com/DoubleNode/dev-team/actions/runs/1?x=1',
            'https://github.com/DoubleNode/dev-team/actions/runs/1#frag',
            'https://github.com/DoubleNode/dev-team/actions/runs/1/job/2/extra',
            'https://github.com/DoubleNode/dev-team/actions/runs/abc',
            'https://github.com/DoubleNode/dev-team/pull/1',
            'https://github.com/DoubleNode/dev-team/actions/runs/1 ',
            'https://github.com/DoubleNode/dev-team/actions/runs/1\n',
            'javascript:alert(1)',
            'data:text/html,<script>1</script>',
            '', 5, undefined,
            'https://github.com/DoubleNode/dev-team/actions/runs/' + '1'.repeat(300),
        ]) assert.throws(() => validateJob(job('x', { runUrl: u })), ValidationError, String(u).slice(0, 60));
    });
    test('job: bad result / minutes / timestamps / endedAt before startedAt', () => {
        assert.throws(() => validateJob(job('x', { result: 'passed' })), ValidationError);
        for (const m of [-1, 7201, NaN, Infinity, '5', null]) assert.throws(() => validateJob(job('x', { minutes: m })), ValidationError, String(m));
        assert.doesNotThrow(() => validateJob(job('x', { minutes: 0 })));
        assert.doesNotThrow(() => validateJob(job('x', { minutes: 7200 })));
        assert.throws(() => validateJob(job('x', { startedAt: 'nope' })), ValidationError);
        assert.throws(() => validateJob(job('x', { endedAt: '2026-10-02T14:00:00Z' })), ValidationError);
        assert.throws(() => validateJob(null), ValidationError);
    });
    test('validatePush throws ValidationError carrying .field', () => {
        try { validatePush(payload({ machine: '' })); assert.fail('expected throw'); }
        catch (e) { assert.ok(e instanceof ValidationError); assert.equal(e.field, 'machine'); }
    });

    test('>64 KiB body -> 413', async () => {
        const { app, store } = mount();
        const big = payload({ runners: [runner({ pad: 'y'.repeat(MAX_BODY_BYTES + 10) })] });
        const r = await push(app, big);
        assert.equal(r.status, 413);
        assert.equal(store.machines.size, 0);
    });
    test('413 is decided BEFORE validation (oversized AND schema-invalid -> 413, not 400)', async () => {
        const { app } = mount();
        const r = await push(app, { machine: 'm1mini', schema_version: 99, pad: 'z'.repeat(MAX_BODY_BYTES + 10) });
        assert.equal(r.status, 413);
    });
    test('body just under the cap passes the size gate', async () => {
        const { app } = mount();
        const base = payload();
        const overhead = Buffer.byteLength(JSON.stringify({ ...base, pad: '' }), 'utf8');
        const r = await push(app, { ...base, pad: 'y'.repeat(MAX_BODY_BYTES - overhead) });
        assert.equal(r.status, 200); // size ok; unknown field dropped
    });
});

// ---------------------------------------------------------------------------
describe('3. per-job rejection', () => {
    test('one bad job among good -> 200, good stored, bad reported, nothing partial', async () => {
        const { app, store } = mount();
        const r = await push(app, payload({
            jobs: [job('g1'), job('bad1', { runUrl: 'http://x' }), job('g2'), job('bad2', { result: 'meh' }), { nonsense: 1 }, job('g3')],
        }));
        assert.equal(r.status, 200);
        assert.equal(r.body.jobsAccepted, 3);
        assert.deepEqual(r.body.jobsRejected.map((j) => j.id), ['bad1', 'bad2', null]);
        for (const j of r.body.jobsRejected) assert.equal(typeof j.reason, 'string');
        const stored = store.machines.get('m1mini').jobs.map((j) => j.id).sort();
        assert.deepEqual(stored, ['g1', 'g2', 'g3']);
    });
    test('all jobs bad -> still 200, host/runner state still updated', async () => {
        const { app, store } = mount();
        const r = await push(app, payload({ jobs: [job('b', { repo: 'nope' })] }));
        assert.equal(r.status, 200);
        assert.equal(r.body.jobsAccepted, 0);
        assert.equal(r.body.jobsRejected.length, 1);
        assert.equal(store.machines.get('m1mini').runners.length, 1);
    });
    test('rejected job with a control-char id reports id:null, not the raw id', async () => {
        const { app } = mount();
        const r = await push(app, payload({ jobs: [job('a\u0000b')] }));
        assert.equal(r.body.jobsRejected[0].id, null);
    });
});

// ---------------------------------------------------------------------------
describe('4. allow-list', () => {
    test('unknown top-level, host, disk, vm, runner, currentJob and job fields are neither persisted nor served', async () => {
        const { app, store, file } = mount();
        const cj = { id: 'cj', workflow: 'w', jobName: 'j', repo: 'o/r', runUrl: null, startedAt: '2026-10-02T14:20:00Z', logs: 'SECRET' };
        const p = payload({
            evilTop: 'EVIL', host: { uptimeSeconds: 5, hostEvil: 'EVIL', disk: { path: '/', totalBytes: 1, freeBytes: 1, diskEvil: 'EVIL' } },
            vm: { name: 'v', state: 'running', vmEvil: 'EVIL' },
            runners: [runner({ runnerEvil: 'EVIL', currentJob: cj })],
            jobs: [job('j1', { jobEvil: 'EVIL', log: 'raw log text' })],
        });
        assert.equal((await push(app, p)).status, 200);
        store.save();
        assert.ok(!fs.readFileSync(file, 'utf8').includes('EVIL'), 'not persisted');
        assert.ok(!fs.readFileSync(file, 'utf8').includes('SECRET'), 'not persisted');
        const g = await request(app).get('/api/ci-runners');
        assert.ok(!JSON.stringify(g.body).includes('EVIL'), 'not served');
        assert.ok(!JSON.stringify(g.body).includes('SECRET'), 'not served');
        assert.ok(!JSON.stringify(g.body).includes('raw log text'), 'not served');
        const m = g.body.machines[0];
        assert.deepEqual(Object.keys(m.runners[0]).sort(),
            ['busy', 'currentJob', 'cycle', 'labels', 'name', 'os', 'service', 'today', 'uptimeSeconds']);
        assert.deepEqual(Object.keys(m.recentJobs[0]).sort(),
            ['branch', 'durationSeconds', 'event', 'finishedAt', 'id', 'job', 'jobUrl', 'minutes', 'os', 'repo', 'result', 'runUrl', 'runner', 'startedAt', 'workflow']);
        // ...and the STORED records are allow-listed too.
        const rec = store.machines.get('m1mini');
        assert.deepEqual(Object.keys(rec.runners[0]).sort(), ['busy', 'currentJob', 'labels', 'name', 'os', 'serviceState']);
        assert.deepEqual(Object.keys(rec.jobs[0]).sort(),
            ['branch', 'durationSeconds', 'endedAt', 'event', 'firstSeenAt', 'id', 'jobName', 'jobUrl', 'minutes', 'os', 'repo', 'result', 'runUrl', 'runner', 'startedAt', 'workflow']);
    });
});

// ---------------------------------------------------------------------------
describe('5. persistence', () => {
    test('dedupe is first-write-wins; firstSeenAt preserved', async () => {
        const store = createCiRunnerStore(newFile());
        const t1 = new Date('2026-10-02T15:00:00Z'); const t2 = new Date('2026-10-02T15:05:00Z');
        const a = store.applyPush(validatePush(payload({ jobs: [job('d1', { result: 'success' })] })), t1);
        assert.equal(a.jobsAccepted, 1);
        const b = store.applyPush(validatePush(payload({ jobs: [job('d1', { result: 'failure', minutes: 99 })] })), t2);
        assert.equal(b.jobsAccepted, 0);
        assert.equal(b.jobsDuplicate, 1);
        const stored = store.machines.get('m1mini').jobs;
        assert.equal(stored.length, 1);
        assert.equal(stored[0].result, 'success');
        assert.equal(stored[0].minutes, 7.5);
        assert.equal(stored[0].firstSeenAt, t1.toISOString());
    });
    test('dedupe via HTTP reports jobsDuplicate', async () => {
        const { app } = mount();
        await push(app, payload());
        const r = await push(app, payload());
        assert.equal(r.body.jobsAccepted, 0);
        assert.equal(r.body.jobsDuplicate, 1);
    });
    test('same job id on a DIFFERENT machine is not a duplicate', async () => {
        const { app } = mount();
        await push(app, payload({ machine: 'a' }));
        const r = await push(app, payload({ machine: 'b' }));
        assert.equal(r.body.jobsAccepted, 1);
    });
    test('duplicate ids inside one push count once', () => {
        const store = createCiRunnerStore(newFile());
        const r = store.applyPush(validatePush(payload({ jobs: [job('same'), job('same')] })));
        assert.equal(r.jobsAccepted, 1);
        assert.equal(r.jobsDuplicate, 1);
    });
    test('500-per-machine cap keeps the NEWEST by endedAt', () => {
        const store = createCiRunnerStore(newFile());
        const mk = (i) => {
            const end = new Date(Date.UTC(2026, 9, 1, 0, 0, 0) + i * 60000);
            const start = new Date(end.getTime() - 30000);
            return job(`n${i}`, { startedAt: start.toISOString().replace('.000Z', 'Z'), endedAt: end.toISOString().replace('.000Z', 'Z') });
        };
        // 12 pushes of 50 = 600 jobs, newest ids last; also push in shuffled order.
        for (let p = 11; p >= 0; p--) {
            store.applyPush(validatePush(payload({ jobs: Array.from({ length: 50 }, (_, k) => mk(p * 50 + k)) })));
        }
        const jobs = store.machines.get('m1mini').jobs;
        assert.equal(jobs.length, 500);
        const ids = new Set(jobs.map((j) => j.id));
        assert.ok(ids.has('n599'), 'newest kept');
        assert.ok(ids.has('n100'), 'boundary kept');
        assert.ok(!ids.has('n99'), 'oldest evicted');
        assert.ok(!ids.has('n0'), 'oldest evicted');
        assert.equal(jobs[0].id, 'n599', 'sorted newest-first');
    });
    test('host / vm / runners / reportedAt are REPLACED each push; jobs accumulate', () => {
        const store = createCiRunnerStore(newFile());
        store.applyPush(validatePush(payload({ vm: { name: 'v', state: 'running' }, runners: [runner({ name: 'a' }), runner({ name: 'b' })], jobs: [job('x1')] })));
        store.applyPush(validatePush(payload({
            reportedAt: '2026-10-02T15:00:00Z', host: { uptimeSeconds: 9 }, vm: null, runners: [runner({ name: 'c' })], jobs: [job('x2')],
        })));
        const rec = store.machines.get('m1mini');
        assert.deepEqual(rec.runners.map((r) => r.name), ['c']);
        assert.equal(rec.vm, null);
        assert.deepEqual(rec.host, { uptimeSeconds: 9 });
        assert.equal(rec.reportedAt, '2026-10-02T15:00:00Z');
        assert.deepEqual(rec.jobs.map((j) => j.id).sort(), ['x1', 'x2']);
    });
    test('save -> new store -> load round-trips', () => {
        const file = newFile();
        const s1 = createCiRunnerStore(file);
        s1.applyPush(validatePush(payload({ jobs: [job('p1'), job('p2', { endedAt: '2026-10-02T14:20:00Z' })] })), new Date('2026-10-02T15:00:00Z'));
        s1.save();
        const s2 = createCiRunnerStore(file);
        s2.load();
        assert.deepEqual(s2.machines.get('m1mini'), s1.machines.get('m1mini'));
        assert.equal(s2.machines.get('m1mini').jobs[0].id, 'p2');
    });
    test('corrupt / wrong-shape / empty files start empty without throwing', () => {
        const origErr = console.error; const origLog = console.log;
        console.error = () => {}; console.log = () => {};
        try {
            const cases = {
                corrupt: '{not json', empty: '', array: '[]', nullJson: 'null',
                wrongVersion: JSON.stringify({ schema_version: 2, machines: {} }),
                machinesNotObject: JSON.stringify({ schema_version: 1, machines: [] }),
                noMachines: JSON.stringify({ schema_version: 1 }),
            };
            for (const [name, content] of Object.entries(cases)) {
                const file = newFile(); fs.mkdirSync(path.dirname(file), { recursive: true });
                fs.writeFileSync(file, content);
                const s = createCiRunnerStore(file);
                assert.doesNotThrow(() => s.load(), name);
                assert.equal(s.machines.size, 0, name);
            }
        } finally { console.error = origErr; console.log = origLog; }
    });
    test('load skips malformed machine entries but keeps good ones', () => {
        const origErr = console.error; const origLog = console.log;
        console.error = () => {}; console.log = () => {};
        try {
            const file = newFile(); fs.mkdirSync(path.dirname(file), { recursive: true });
            const good = { machine: 'ok', receivedAt: '2026-10-02T15:00:00Z', reportedAt: '2026-10-02T15:00:00Z',
                reporterVersion: '1.0.0', host: { uptimeSeconds: 1 }, vm: null, jobs: [], runners: [] };
            fs.writeFileSync(file, JSON.stringify({
                schema_version: 1,
                machines: { ok: good, bad1: { jobs: 'x' }, 'bad id': good, bad2: null, bad3: { ...good, receivedAt: 5 } },
            }));
            const s = createCiRunnerStore(file); s.load();
            assert.deepEqual([...s.machines.keys()], ['ok']);
        } finally { console.error = origErr; console.log = origLog; }
    });
    test('missing file starts empty', () => {
        const origLog = console.log; console.log = () => {};
        try { const s = createCiRunnerStore(newFile()); s.load(); assert.equal(s.machines.size, 0); }
        finally { console.log = origLog; }
    });
    test('atomic write leaves no .tmp files, and file parses', () => {
        const file = newFile();
        const s = createCiRunnerStore(file);
        s.applyPush(validatePush(payload()));
        s.save(); s.save();
        const leftovers = fs.readdirSync(path.dirname(file)).sort();
        // XACA-1387-020: save() also writes the rollups file, atomically too
        assert.deepEqual(leftovers, ['ci-runner-rollups.json', 'ci-runners.json']);
        assert.equal(JSON.parse(fs.readFileSync(file, 'utf8')).schema_version, 1);
    });
    test('save creates the parent directory', () => {
        const file = path.join(TMP, 'deep', 'er', 'x.json');
        const s = createCiRunnerStore(file);
        s.applyPush(validatePush(payload())); s.save();
        assert.ok(fs.existsSync(file));
    });
    test('registerCiRunnersRoutes honours opts.file (state written only there)', async () => {
        const { app, store, file } = mount();
        await push(app, payload());
        store.save();
        assert.ok(fs.existsSync(file));
    });
});

// ---------------------------------------------------------------------------
describe('6. staleness signals (injected now) -- the UI derives status, the server stamps', () => {
    const base = new Date('2026-10-02T15:00:00Z');
    const at = (sec) => new Date(base.getTime() + sec * 1000);
    const seed = () => {
        const s = createCiRunnerStore(newFile());
        s.applyPush(validatePush(payload({ runners: [runner({ serviceState: 'up' })] })), base);
        return s;
    };
    test('thresholds: stale 180 s (constant reused), offline 600 s, both served', () => {
        assert.equal(STALE_THRESHOLD_MS, 180000);
        assert.equal(OFFLINE_THRESHOLD_MS, 600000);
        const snap = seed().snapshot({ now: at(1) });
        assert.equal(snap.staleAfterSeconds, 180);
        assert.equal(snap.offlineAfterSeconds, 600);
    });
    test('lastReportAt is the server receivedAt; generatedAt is the injected now', () => {
        const snap = seed().snapshot({ now: at(42) });
        assert.equal(snap.machines[0].lastReportAt, base.toISOString());
        assert.equal(snap.generatedAt, at(42).toISOString());
    });
    test('a stale/offline machine is still served, with every reported value as-is', () => {
        const s = seed();
        const m = s.snapshot({ now: at(5000) }).machines[0];
        assert.equal(m.machine, 'm1mini');
        assert.equal(m.runners[0].service, 'online', 'service is NOT rewritten for a stale machine');
        assert.equal(s.machines.get('m1mini').runners[0].serviceState, 'up');
    });
    test('staleness keys on server receivedAt, not the reporter-supplied reportedAt', () => {
        const s = createCiRunnerStore(newFile());
        s.applyPush(validatePush(payload({ reportedAt: '2020-01-01T00:00:00Z' })), base);
        assert.equal(s.snapshot({ now: at(5) }).machines[0].lastReportAt, base.toISOString());
    });
    test('service up/down/unknown -> online/offline/unknown; busy from currentJob unless pushed', () => {
        const s = createCiRunnerStore(newFile());
        const cj = { id: 'c', workflow: 'w', jobName: 'j', repo: 'o/r', runUrl: null, startedAt: '2026-10-02T15:00:00Z' };
        s.applyPush(validatePush(payload({ runners: [
            runner({ name: 'f1', serviceState: 'down' }), runner({ name: 'f2', serviceState: 'unknown' }),
            runner({ name: 'f3', serviceState: 'up', currentJob: cj }), runner({ name: 'f4', serviceState: 'up', busy: true }),
            runner({ name: 'f5', serviceState: 'up', currentJob: cj, busy: false }),
        ] })), base);
        const rs = s.snapshot({ now: at(1) }).machines[0].runners;
        assert.deepEqual(rs.map((r) => r.service), ['offline', 'unknown', 'online', 'online', 'online']);
        assert.deepEqual(rs.map((r) => r.busy), [false, false, true, true, false], 'pushed busy wins over currentJob');
    });
    test('machines are sorted by id', () => {
        const s = createCiRunnerStore(newFile());
        for (const m of ['zeta', 'alpha', 'mid']) s.applyPush(validatePush(payload({ machine: m })), base);
        assert.deepEqual(s.snapshot({ now: base }).machines.map((m) => m.machine), ['alpha', 'mid', 'zeta']);
    });
});

// ---------------------------------------------------------------------------
describe('6b. new optional push fields (XACA-1387-016)', () => {
    const JOB_URL = 'https://github.com/DoubleNode/dev-team/actions/runs/123/job/456';
    test('older reporter payload (none of the new fields) is still accepted', async () => {
        const { app } = mount();
        assert.equal((await push(app, payload())).status, 200);
    });
    test('valid new fields are stored and served', async () => {
        const { app } = mount();
        const cj = { id: 'cj', workflow: 'w', jobName: 'j', repo: 'o/r', runUrl: null, startedAt: '2026-10-02T14:20:00Z',
            branch: 'feature/x', event: 'push', jobUrl: JOB_URL };
        const r = await push(app, payload({
            host: { uptimeSeconds: 5, hostname: 'M1Mini.local' },
            runners: [runner({ os: 'macOS', busy: true, currentJob: cj })],
            jobs: [job('n1', { branch: 'develop', event: 'pull_request', durationSeconds: 450, jobUrl: JOB_URL })],
        }));
        assert.equal(r.status, 200, JSON.stringify(r.body));
        assert.equal(r.body.jobsAccepted, 1);
        const m = (await request(app).get('/api/ci-runners')).body.machines[0];
        assert.equal(m.hostname, 'M1Mini.local');
        assert.equal(m.runners[0].os, 'macOS');
        assert.equal(m.runners[0].busy, true);
        assert.equal(m.runners[0].currentJob.branch, 'feature/x');
        assert.equal(m.runners[0].currentJob.jobUrl, JOB_URL);
        const j = m.recentJobs[0];
        assert.deepEqual([j.branch, j.event, j.durationSeconds, j.minutes, j.jobUrl], ['develop', 'pull_request', 450, 8, JOB_URL]);
    });
    test('explicit nulls for the new fields are accepted', async () => {
        const { app } = mount();
        const r = await push(app, payload({
            host: { uptimeSeconds: 5, hostname: null }, runners: [runner({ os: null, busy: null })],
            jobs: [job('n1', { branch: null, event: null, durationSeconds: null, jobUrl: null })],
        }));
        assert.equal(r.status, 200);
        assert.equal(r.body.jobsAccepted, 1);
    });
    test('bad host.hostname / runners[].os / runners[].busy -> 400 with field', async () => {
        const cases = [
            [{ host: { uptimeSeconds: 1, hostname: 'has space' } }, 'host.hostname'],
            [{ host: { uptimeSeconds: 1, hostname: 'x'.repeat(256) } }, 'host.hostname'],
            [{ host: { uptimeSeconds: 1, hostname: 'a\nb' } }, 'host.hostname'],
            [{ host: { uptimeSeconds: 1, hostname: 5 } }, 'host.hostname'],
            [{ runners: [runner({ os: 'Windows' })] }, 'runners[0].os'],
            [{ runners: [runner({ os: 'linux' })] }, 'runners[0].os'],
            [{ runners: [runner({ busy: 'yes' })] }, 'runners[0].busy'],
        ];
        for (const [over, field] of cases) {
            const { app, store } = mount();
            const r = await push(app, payload(over));
            assert.equal(r.status, 400, field);
            assert.equal(r.body.field, field);
            assert.equal(store.machines.size, 0);
        }
        const { app } = mount();
        assert.equal((await push(app, payload({ host: { uptimeSeconds: 1, hostname: 'h'.repeat(255) } }))).status, 200, '255 ok');
    });
    test('bad job branch / event / durationSeconds / jobUrl are per-job rejections', () => {
        const badVals = {
            branch: ['', 'b'.repeat(256), 'a\u0000b', 'x\ny', 5],
            event: ['', 'e'.repeat(65), 'a\tb', {}],
            durationSeconds: [-1, 1.5, 432001, '60', NaN],
            jobUrl: [
                'https://github.com/DoubleNode/dev-team/actions/runs/1', // no /job/<digits>
                'http://github.com/DoubleNode/dev-team/actions/runs/1/job/2',
                'https://github.com/DoubleNode/dev-team/actions/runs/1/job/2/',
                'https://github.com/DoubleNode/dev-team/actions/runs/1/job/x',
                'javascript:alert(1)', '', 5,
            ],
        };
        for (const [k, vals] of Object.entries(badVals)) {
            for (const v of vals) assert.throws(() => validateJob(job('x', { [k]: v })), ValidationError, `${k}=${String(v)}`);
        }
        assert.doesNotThrow(() => validateJob(job('x', { branch: 'b'.repeat(255), event: 'e'.repeat(64), durationSeconds: 432000,
            jobUrl: 'https://github.com/DoubleNode/dev-team/actions/runs/1/attempts/2/job/3' })));
    });
    test('bad currentJob branch / jobUrl rejects the push (currentJob rules = top-level)', async () => {
        const cj = { id: 'cj', workflow: 'w', jobName: 'j', repo: 'o/r', runUrl: null, startedAt: '2026-10-02T14:20:00Z' };
        for (const [k, v] of [['branch', 'a\u0007'], ['jobUrl', 'https://evil.example/job/1']]) {
            const { app } = mount();
            const r = await push(app, payload({ runners: [runner({ currentJob: { ...cj, [k]: v } })] }));
            assert.equal(r.status, 400);
            assert.equal(r.body.field, `runners[0].currentJob.${k}`);
        }
    });
});

// ---------------------------------------------------------------------------
describe('6c. load() deep-validates stored records (XACA-1387-015)', () => {
    const quiet = (fn) => {
        const e = console.error; const l = console.log; console.error = () => {}; console.log = () => {};
        try { return fn(); } finally { console.error = e; console.log = l; }
    };
    const goodRec = () => {
        const s = createCiRunnerStore(newFile());
        s.applyPush(validatePush(payload({ jobs: [job('ok1'), job('ok2', { endedAt: '2026-10-02T14:20:00Z' })] })), new Date('2026-10-02T15:00:00Z'));
        return JSON.parse(JSON.stringify(s.machines.get('m1mini')));
    };
    const writeStore = (machines) => {
        const file = newFile(); fs.mkdirSync(path.dirname(file), { recursive: true });
        fs.writeFileSync(file, JSON.stringify({ schema_version: 1, machines }));
        return file;
    };
    const getAfterLoad = async (machines) => {
        const file = writeStore(machines);
        const { app, store } = quiet(() => mount(file));
        const g = await request(app).get('/api/ci-runners');
        return { g, store };
    };
    test('runners:[null] and jobs:[null] -> GET still 200, malformed entries dropped', async () => {
        const rec = goodRec();
        rec.runners.push(null);
        rec.jobs.push(null);
        const { g, store } = await getAfterLoad({ m1mini: rec });
        assert.equal(g.status, 200);
        assert.equal(store.machines.get('m1mini').runners.length, 1);
        assert.deepEqual(store.machines.get('m1mini').jobs.map((j) => j.id), ['ok2', 'ok1']);
    });
    test('wrong-typed runner / job fields are dropped; the machine survives', async () => {
        const rec = goodRec();
        rec.runners.push({ name: 5, serviceState: 'up', labels: [], currentJob: null });
        rec.runners.push({ name: 'r2', serviceState: 'up', labels: 'nope', currentJob: null });
        rec.runners.push({ name: 'r3', serviceState: 'up', labels: [], currentJob: { id: 1 } });
        rec.jobs.push({ ...rec.jobs[0], id: 'j-bad-min', minutes: 'seven' });
        rec.jobs.push({ ...rec.jobs[0], id: 'j-bad-seen', firstSeenAt: 12 });
        rec.jobs.push({ ...rec.jobs[0] }); // duplicate id
        const { g, store } = await getAfterLoad({ m1mini: rec });
        assert.equal(g.status, 200);
        assert.equal(store.machines.get('m1mini').runners.length, 1);
        assert.deepEqual(store.machines.get('m1mini').jobs.map((j) => j.id).sort(), ['ok1', 'ok2']);
    });
    test('machine-level corruption drops only that machine', async () => {
        const good = goodRec();
        const variants = {
            hostStr: { ...good, machine: 'hostStr', host: 'x' },
            vmBad: { ...good, machine: 'vmBad', vm: { name: 'v', state: 'exploded' } },
            noReported: { ...good, machine: 'noReported', reportedAt: undefined },
            runnersObj: { ...good, machine: 'runnersObj', runners: {} },
            recvGarbage: { ...good, machine: 'recvGarbage', receivedAt: 'yesterday' },
        };
        const { g, store } = await getAfterLoad({ m1mini: good, ...variants });
        assert.equal(g.status, 200);
        assert.deepEqual([...store.machines.keys()], ['m1mini']);
        assert.deepEqual(g.body.machines.map((m) => m.machine), ['m1mini']);
    });
    test('unknown fields in a stored record are not carried forward', async () => {
        const rec = goodRec();
        rec.evil = 'EVIL'; rec.runners[0].evil = 'EVIL'; rec.jobs[0].evil = 'EVIL'; rec.host.evil = 'EVIL';
        const { g, store } = await getAfterLoad({ m1mini: rec });
        assert.ok(!JSON.stringify(g.body).includes('EVIL'));
        assert.ok(!JSON.stringify([...store.machines.values()]).includes('EVIL'));
    });
    test('a valid round-tripped record is loaded unchanged', async () => {
        const rec = goodRec();
        const { store } = await getAfterLoad({ m1mini: rec });
        assert.deepEqual(store.machines.get('m1mini'), rec);
    });
});

// ---------------------------------------------------------------------------
describe('6d. machine cap (XACA-1387-014)', () => {
    const t0 = new Date('2026-10-02T15:00:00Z');
    const at = (sec) => new Date(t0.getTime() + sec * 1000);
    const fill = (s, when) => {
        for (let i = 0; i < MAX_MACHINES; i++) s.applyPush(validatePush(payload({ machine: `m${String(i).padStart(3, '0')}`, jobs: [] })), when(i));
    };
    test('cap is 64', () => { assert.equal(MAX_MACHINES, 64); });
    test('all live at cap -> a NEW machine is refused (CapacityError), nothing evicted', () => {
        const s = createCiRunnerStore(newFile());
        fill(s, () => t0);
        assert.throws(() => s.applyPush(validatePush(payload({ machine: 'newcomer' })), at(60)), CapacityError);
        assert.equal(s.machines.size, MAX_MACHINES);
        assert.ok(!s.machines.has('newcomer'));
    });
    test('an EXISTING machine can always re-push at cap', () => {
        const s = createCiRunnerStore(newFile());
        fill(s, () => t0);
        assert.doesNotThrow(() => s.applyPush(validatePush(payload({ machine: 'm000' })), at(60)));
        assert.equal(s.machines.size, MAX_MACHINES);
    });
    test('the oldest machine is evicted only once it is OFFLINE (> 600 s)', () => {
        const s = createCiRunnerStore(newFile());
        fill(s, (i) => (i === 7 ? t0 : at(500))); // m007 heard from first
        // at 600 s m007 is exactly at the threshold (not > 600) -> still refused
        assert.throws(() => s.applyPush(validatePush(payload({ machine: 'newcomer' })), at(600)), CapacityError);
        s.applyPush(validatePush(payload({ machine: 'newcomer' })), at(601));
        assert.ok(s.machines.has('newcomer'));
        assert.ok(!s.machines.has('m007'), 'oldest offline machine evicted');
        assert.equal(s.machines.size, MAX_MACHINES);
    });
    test('HTTP: refusal is 507 with a clear error and field, existing data untouched', async () => {
        const { app, store } = mount();
        fill(store, () => new Date());
        const r = await push(app, payload({ machine: 'newcomer' }));
        assert.equal(r.status, 507);
        assert.equal(r.body.field, 'machine');
        assert.match(r.body.error, /machine cap reached/);
        assert.equal(store.machines.size, MAX_MACHINES);
    });
    test('load() of an over-cap file keeps the 64 most recently heard-from', () => {
        const big = createCiRunnerStore(newFile());
        // bypass the live cap to fabricate an over-cap file
        for (let i = 0; i < MAX_MACHINES + 6; i++) {
            const rec = { machine: `x${i}`, receivedAt: at(i).toISOString(), reportedAt: '2026-10-02T15:00:00Z', reporterVersion: '1',
                host: { uptimeSeconds: 1 }, vm: null, runners: [], jobs: [] };
            big.machines.set(rec.machine, rec);
        }
        const file = newFile(); fs.mkdirSync(path.dirname(file), { recursive: true });
        fs.writeFileSync(file, JSON.stringify({ schema_version: 1, machines: Object.fromEntries(big.machines) }));
        const e = console.error; const l = console.log; console.error = () => {}; console.log = () => {};
        try {
            const s = createCiRunnerStore(file); s.load();
            assert.equal(s.machines.size, MAX_MACHINES);
            assert.ok(s.machines.has(`x${MAX_MACHINES + 5}`) && !s.machines.has('x0') && !s.machines.has('x5'));
        } finally { console.error = e; console.log = l; }
    });
});

// ---------------------------------------------------------------------------
describe('6e. save() temp-file orphans (XACA-1387-017)', () => {
    test('load() removes orphaned ci-runners.json.tmp-* and nothing else', () => {
        const file = newFile(); const dir = path.dirname(file);
        const s1 = createCiRunnerStore(file);
        s1.applyPush(validatePush(payload()));
        s1.save();
        fs.writeFileSync(`${file}.tmp-12345`, '{partial');
        fs.writeFileSync(`${file}.tmp-99`, '');
        fs.writeFileSync(path.join(dir, 'other.json.tmp-1'), 'keep');
        const l = console.log; console.log = () => {};
        try {
            const s2 = createCiRunnerStore(file); s2.load();
            assert.equal(s2.machines.size, 1, 'real file still loaded');
        } finally { console.log = l; }
        // ci-runner-rollups.json: the second file save() writes (XACA-1387-020)
        assert.deepEqual(fs.readdirSync(dir).sort(), ['ci-runner-rollups.json', 'ci-runners.json', 'other.json.tmp-1']);
    });
    test('load() with no data dir yet does not throw', () => {
        const l = console.log; console.log = () => {};
        try { assert.doesNotThrow(() => createCiRunnerStore(path.join(TMP, 'nope', 'ci-runners.json')).load()); }
        finally { console.log = l; }
    });
});

// ---------------------------------------------------------------------------
describe('7. GET ?jobs=N', () => {
    const seed600 = () => {
        const { app, store } = mount();
        for (let p = 0; p < 12; p++) {
            const jobs = Array.from({ length: 50 }, (_, k) => {
                const i = p * 50 + k;
                const end = new Date(Date.UTC(2026, 9, 1) + i * 60000);
                return job(`g${i}`, { startedAt: new Date(end - 1000).toISOString().replace('.000Z', 'Z'), endedAt: end.toISOString().replace('.000Z', 'Z') });
            });
            store.applyPush(validatePush(payload({ jobs })));
        }
        return app;
    };
    const n = async (app, q) => (await request(app).get(`/api/ci-runners${q}`)).body.machines[0].recentJobs.length;
    test('default 50, explicit values, cap 500', async () => {
        const app = seed600();
        assert.equal(await n(app, ''), 50);
        assert.equal(await n(app, '?jobs=7'), 7);
        assert.equal(await n(app, '?jobs=0'), 0);
        assert.equal(await n(app, '?jobs=500'), 500);
        assert.equal(await n(app, '?jobs=501'), 500);
        assert.equal(await n(app, '?jobs=999999999999999999999'), 500);
    });
    test('junk values fall back to the default (50)', async () => {
        const app = seed600();
        for (const q of ['?jobs=abc', '?jobs=-5', '?jobs=1.5', '?jobs=', '?jobs=1e3', '?jobs=%20', '?jobs=0x10', '?jobs[]=3', '?jobs=3&jobs=4']) {
            assert.equal(await n(app, q), 50, q);
        }
    });
    test('parseJobsLimit unit', () => {
        assert.equal(parseJobsLimit(undefined), 50);
        assert.equal(parseJobsLimit('12'), 12);
        assert.equal(parseJobsLimit('9999'), 500);
        assert.equal(parseJobsLimit('x'), 50);
    });
    test('newest jobs are served first', async () => {
        const app = seed600();
        const g = await request(app).get('/api/ci-runners?jobs=2');
        assert.deepEqual(g.body.machines[0].recentJobs.map((j) => j.id), ['g599', 'g598']);
    });
    test('empty store -> empty machines, summary null (absent != zero; empty fixture)', async () => {
        const { app } = mount();
        const g = await request(app).get('/api/ci-runners');
        assert.deepEqual(g.body.machines, []);
        assert.equal(g.body.summary, null);
    });
});
