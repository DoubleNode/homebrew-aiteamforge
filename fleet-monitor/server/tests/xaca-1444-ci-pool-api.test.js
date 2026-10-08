//
//  xaca-1444-ci-pool-api.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1444-001 -- GET /api/ci-pool additive read model + PUT /api/ci-pool/machines/:machine
 * strand protection and enabled-flip audit. Real store, real dispatcher, real routes, real auth
 * (fake env tokens). NO network, no real data dir.
 *
 * The three fixtures under tests/fixtures/xaca-1444-ci-pool-*.json are the REAL GET body for a
 * deterministic scenario; the UI (wave 2) builds against them. A drift test regenerates each
 * scenario and compares; set XACA_1444_WRITE_FIXTURES=1 to rewrite them after an intended change.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const { test, describe, after } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const express = require('express');
const http = require('http');

const FLEET = 'xaca1444-fake-fleet-token-aaaaaaaa';
const ADMIN = 'xaca1444-fake-admin-token-bbbbbbbb';
const SAVED = { a: process.env.FLEET_AUTH_TOKEN, b: process.env.FLEET_ADMIN_TOKEN };
process.env.FLEET_AUTH_TOKEN = FLEET;
process.env.FLEET_ADMIN_TOKEN = ADMIN;

const { createPoolStore } = require('../lib/ci-pool-store');
const { createAssignments } = require('../lib/ci-dispatch-assignments');
const { createAudit } = require('../lib/ci-dispatch-audit');
const { createAlerts } = require('../lib/ci-dispatch-alerts');
const { createDispatcher } = require('../lib/ci-dispatcher');
const { registerCiPoolRoutes } = require('../lib/ci-pool-routes');


// Loopback-pinned supertest (XACA-1444-005). supertest, handed a bare express app, calls app.listen(0) itself;
// and if handed an http.Server that is NOT yet listening (listen(port, host) resolves the host asynchronously,
// so address() is still null on the first call) it ALSO falls back to a wildcard listen(0). A wildcard port can
// collide with a listener another process holds on 127.0.0.1 only; the request then lands on that foreign
// server and comes back "401 auth required" (text/plain, empty parsed body) -- observed ~1 in 25 runs, reported
// as "fixture drifted" or a TypeError on body.queue. Fix: await 'listening' on a 127.0.0.1-bound server first.
const SERVERS = new Map();
async function req(app) {
    let srv = SERVERS.get(app);
    if (!srv) {
        srv = http.createServer(app);
        SERVERS.set(app, srv);
        srv.ready = new Promise((resolve, reject) => { srv.once('listening', resolve); srv.once('error', reject); });
        srv.listen(0, '127.0.0.1');
        srv.unref();
    }
    await srv.ready;
    return request(srv);
}
after(() => { for (const srv of SERVERS.values()) srv.close(); SERVERS.clear(); });

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca1444-api-'));
after(() => {
    fs.rmSync(TMP, { recursive: true, force: true });
    for (const [k, v] of [['FLEET_AUTH_TOKEN', SAVED.a], ['FLEET_ADMIN_TOKEN', SAVED.b]]) {
        if (v === undefined) delete process.env[k]; else process.env[k] = v;
    }
});

const T0 = Date.UTC(2026, 9, 7, 18, 0, 0);
const REPO = 'DoubleNode/dev-team';
const CREDS = { FLEET_CI_DISPATCHER: '1', GITHUB_APP_CLIENT_ID: 'Iv-test-client', GITHUB_APP_PRIVATE_KEY: 'not-a-real-key-fixture' };
// Shadow decides and records but never mints, so assignment ids/runner names (random) stay out of fixtures.
const SHADOW = Object.assign({}, CREDS, { FLEET_CI_DISPATCHER: 'shadow' });
const FIXTURES = path.join(__dirname, 'fixtures');
const POOL_LINUX = ['self-hosted', 'Linux', 'ARM64', 'fleet-pool'];
const POOL_M1MINI = ['self-hosted', 'macOS', 'ARM64', 'fleet-pool', 'm1mini'];
const CAP = { memTotalBytes: 17179869184, memReclaimableBytes: 4080000000, memFreePct: 45, swapUsedBytes: 100, swapTotalBytes: 3221225472, load1: 1.2, load5: 1, load15: 1, ncpu: 10, teamSessions: 6, vmState: 'running' };
let seq = 0;

const slot = (osName, index, state, assignmentId = null) => ({ os: osName, index, state, assignmentId });
const bearer = (r, tok) => r.set('Authorization', `Bearer ${tok}`);

function job(jobId, minutesOld, labels) {
    return {
        key: `${REPO}#${jobId}#1`, owner: 'DoubleNode', repo: 'dev-team', runId: 5, runAttempt: 1, jobId,
        name: 'unit', labels: labels.slice(), status: 'queued', conclusion: null, runnerName: null,
        createdAt: new Date(T0 - minutesOld * 60000).toISOString(), firstSeenAt: new Date(T0).toISOString(),
        inProgressAt: null, completedAt: null, run: { event: 'push', repoFullName: REPO, headRepoFullName: REPO },
        branch: 'feature/xaca-1444', workflow: 'CI', url: `https://github.com/${REPO}/actions/runs/5/job/${jobId}`,
    };
}

/** Real routes + real dispatcher over a temp dir. `machines` seeds store + reports. */
function build({ machines = {}, noDispatcher = false, env = CREDS } = {}) {
    const dir = path.join(TMP, `s${++seq}`);
    fs.mkdirSync(dir, { recursive: true });
    const clock = { t: T0 };
    const store = createPoolStore({ file: path.join(dir, 'ci-pool.json'), logger: { error() {} } });
    store.load();
    assert.equal(store.updateConfig({ allowlist: [REPO] }).ok, true);
    const reports = new Map();
    for (const [id, spec] of Object.entries(machines)) {
        assert.equal(store.upsertMachine(id, { enabled: spec.enabled !== false }).ok, true);
        if (spec.paused) assert.equal(store.upsertMachine(id, { paused: true, pauseReason: spec.reason || null }, { by: 'operator', now: T0 - 600000 }).ok, true);
        if (spec.key) assert.equal(store.setHostSecret(id, `fcp_${'A'.repeat(43)}`).ok, true);
        if (spec.slots) {
            const r = { receivedAt: T0 - 4000, capacity: CAP, slots: spec.slots, agentVersion: '1.0.0' };
            if (spec.marker) r.pauseMarker = spec.marker;
            if (spec.capability) r.capability = spec.capability;
            reports.set(id, r);
        }
    }
    const auditFile = path.join(dir, 'audit.jsonl');
    const audit = createAudit({ path: auditFile, keep: 2, now: () => new Date(clock.t) });
    const assignments = createAssignments({ file: path.join(dir, 'state.json'), github: { async generateJitConfig() { return { runnerId: 1, encodedJitConfig: 'JITSENTINEL' }; }, async deleteRunner() { return { deleted: true }; } }, audit, now: () => clock.t, logger: { error() {}, warn() {} } });
    const logger = { log() {}, warn() {}, error() {} };
    const alerts = createAlerts({ now: () => clock.t, logger, getEmitter: () => null });
    const dispatcher = noDispatcher ? undefined : createDispatcher({
        env, store, assignments, alerts, audit, reports, logger, now: () => clock.t,
        watcher: { async runCycle() { return 15000; }, stop() {} }, setTimer: () => ({}), clearTimer() {},
    });
    const app = express();
    app.use(express.json());
    registerCiPoolRoutes(app, { store, assignments, dispatcher, audit, reports, now: () => clock.t, logger });
    const auditRows = () => (fs.existsSync(auditFile) ? fs.readFileSync(auditFile, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l)) : []);
    const get = async () => {
        const r = await (await req(app)).get('/api/ci-pool');
        // A transport/harness failure must never surface as "fixture drifted" or a confusing TypeError.
        assert.equal(r.status, 200, `GET /api/ci-pool harness failure: status ${r.status} ${r.type} ${JSON.stringify(String(r.text).slice(0, 120))} (not the ci-pool route?)`);
        assert.ok(r.text && r.body && Object.keys(r.body).length > 0, 'GET /api/ci-pool harness failure: empty body');
        return r.body;
    };
    const put = async (id, body) => bearer((await req(app)).put(`/api/ci-pool/machines/${id}`), ADMIN).send(body);
    return { app, store, assignments, reports, dispatcher, clock, auditRows, get, put, dir };
}

async function scenario(name) {
    if (name === 'mixed') {
        const s = build({ machines: {
            m4mini: { key: true, capability: 'enabled', slots: [slot('Linux', 1, 'idle'), slot('macOS', 1, 'busy', 'a_1')] },
            m1mini: { key: true, paused: true, reason: 'disk cleanup', slots: [slot('macOS', 1, 'busy', 'a_2'), slot('macOS', 2, 'idle')], marker: 'draining' },
            m1pro: { key: true, paused: true, reason: 'OS update', slots: [slot('Linux', 1, 'idle')], marker: 'paused', capability: 'dormant' },
            m3pro: { slots: [slot('Linux', 1, 'idle')], marker: 'resuming' },
            m2mini: { enabled: false },
            m5mini: {},
        }, env: SHADOW });
        for (let i = 1; i <= 3; i++) s.dispatcher.onJob(job(i, 4, POOL_LINUX), 'queued');
        await s.dispatcher.tick();
        return s;
    }
    if (name === 'draining') {
        const s = build({ machines: {
            m4mini: { key: true, paused: true, reason: 'restart agent', slots: [slot('Linux', 1, 'busy', 'a_1'), slot('Linux', 2, 'idle')], marker: 'draining' },
            m1mini: { key: true, slots: [slot('macOS', 1, 'idle'), slot('macOS', 2, 'idle')] },
        }, env: SHADOW });
        for (let i = 1; i <= 2; i++) s.dispatcher.onJob(job(i, 2, POOL_LINUX), 'queued');
        await s.dispatcher.tick();
        return s;
    }
    if (name === 'no-capacity') {
        const s = build({ machines: {
            m4mini: { key: true, paused: true, reason: 'maintenance', slots: [slot('Linux', 1, 'idle')], marker: 'paused' },
            m1mini: { key: true, paused: true, reason: 'maintenance', slots: [slot('macOS', 1, 'busy', 'a_1'), slot('macOS', 2, 'idle')], marker: 'draining' },
            m2mini: { enabled: false },
        } });
        for (let i = 1; i <= 44; i++) s.dispatcher.onJob(job(i, 32 - i * 0.01, POOL_M1MINI), 'queued');
        await s.dispatcher.tick();
        s.clock.t += 130000;   // past the 120 s no-capacity grace
        for (const r of s.reports.values()) r.receivedAt = s.clock.t - 4000;
        await s.dispatcher.tick();
        return s;
    }
    throw new Error(`unknown scenario ${name}`);
}

const fixturePath = (n) => path.join(FIXTURES, `xaca-1444-ci-pool-${n}.json`);

describe('fixtures are the real GET /api/ci-pool body (drift guard)', () => {
    for (const name of ['mixed', 'draining', 'no-capacity']) {
        test(`${name}`, async () => {
            const body = await (await scenario(name)).get();
            if (process.env.XACA_1444_WRITE_FIXTURES === '1') {
                fs.mkdirSync(FIXTURES, { recursive: true });
                fs.writeFileSync(fixturePath(name), JSON.stringify(body, null, 2) + '\n');
            }
            assert.deepEqual(JSON.parse(fs.readFileSync(fixturePath(name), 'utf8')), JSON.parse(JSON.stringify(body)),
                'fixture drifted from the live response; rerun with XACA_1444_WRITE_FIXTURES=1 if the change is intended');
        });
    }
});

describe('GET /api/ci-pool additive fields', () => {
    test('mixed scenario derives all six states and the per-machine capability', async () => {
        const body = await (await scenario('mixed')).get();
        const st = Object.fromEntries(Object.entries(body.machines).map(([k, m]) => [k, m.state]));
        assert.deepEqual(st, { m4mini: 'enabled', m1mini: 'draining', m1pro: 'paused', m3pro: 'resuming', m2mini: 'disabled', m5mini: 'unknown' });
        assert.deepEqual(new Set(Object.values(st)), new Set(['enabled', 'draining', 'paused', 'resuming', 'disabled', 'unknown']));
        assert.deepEqual(Object.fromEntries(Object.entries(body.machines).map(([k, m]) => [k, m.capability])),
            { m4mini: 'enabled', m1mini: 'unknown', m1pro: 'dormant', m3pro: 'unknown', m2mini: 'unknown', m5mini: 'unknown' });
        assert.equal(typeof body.machines.m1mini.stateReason, 'string');
        assert.deepEqual(body.noCapacity, { active: false, since: null, queuedCount: 0, oldestQueuedAt: null });
        assert.equal(body.queueAge.length, 1);
        assert.equal(body.queueAge[0].depth, 3);
        assert.equal(body.queueAge[0].overThreshold, false);
        assert.equal(body.queueAgeThresholdSec, 900);
    });

    test('no-capacity scenario reports noCapacity + an over-threshold queueAge group', async () => {
        const body = await (await scenario('no-capacity')).get();
        assert.equal(body.noCapacity.active, true);
        assert.equal(body.noCapacity.queuedCount, 44);
        assert.equal(body.queueAge[0].depth, 44);
        assert.equal(body.queueAge[0].host, 'm1mini');
        assert.equal(body.queueAge[0].overThreshold, true);
        assert.equal(body.alerts.some((a) => a.type === 'ci-queue-age'), true);
        assert.equal(body.alerts.some((a) => a.type === 'ci-no-capacity'), true);
    });

    test('purely additive: every pre-existing top-level and per-machine field is still present with its type', async () => {
        const body = await (await scenario('mixed')).get();
        for (const k of ['schemaVersion', 'serverTime', 'dispatcherEnabled', 'config', 'machines', 'assignments', 'alerts', 'queue']) assert.ok(k in body, k);
        assert.equal(Array.isArray(body.queue), true);
        const m = body.machines.m4mini;
        for (const k of ['enabled', 'paused', 'pausedBy', 'pausedAt', 'pauseReason', 'prefers', 'thresholds', 'mode', 'hasKey', 'hasTelemetryKey', 'lastPollAt', 'agentVersion', 'pauseMarker', 'pauseDrift', 'capacity', 'slots']) assert.ok(k in m, k);
        assert.equal('pool' in body, false);   // not added to /api/ci-runners and not invented here
    });

    test('secrets stay out: no key hash and no JIT config anywhere in the body', async () => {
        const s = await scenario('mixed');
        const text = JSON.stringify(await s.get());
        assert.equal(/keyHash|telemetryKeyHash|JITSENTINEL|encodedJitConfig/.test(text), false);
    });

    test('queue items carry branch, workflow, url, labels, status, runnerName; machine null with no assignment', async () => {
        const s = await scenario('draining');
        const q = (await s.get()).queue;
        assert.equal(q.length, 2);
        assert.equal(q[0].branch, 'feature/xaca-1444'); assert.equal(q[0].workflow, 'CI');
        assert.equal(q[0].url, `https://github.com/${REPO}/actions/runs/5/job/${q[0].jobId}`);
        assert.deepEqual(q[0].labels, POOL_LINUX); assert.equal(q[0].status, 'queued');
        assert.equal(q[0].runnerName, null); assert.equal(q[0].machine, null);
    });

    test('queue item: fields are null when the record lacks them, and machine resolves from a live assignment', async () => {
        const s = build({ machines: { m4mini: { key: true, slots: [slot('Linux', 1, 'idle')] } }, env: CREDS });
        const bare = job(1, 1, POOL_LINUX); delete bare.branch; delete bare.workflow; delete bare.url;
        s.dispatcher.onJob(bare, 'queued');
        s.dispatcher.onJob(job(2, 1, POOL_LINUX), 'queued');
        let q = s.dispatcher.queue();
        assert.equal(q.find((i) => i.jobId === 1).branch, null);
        assert.equal(q.find((i) => i.jobId === 1).workflow, null);
        assert.equal(q.find((i) => i.jobId === 1).url, null);
        await s.assignments.mint({ job: { owner: 'DoubleNode', repo: 'dev-team', jobId: 2, name: 'unit', runId: 5 }, machine: 'm4mini', labels: POOL_LINUX, os: 'Linux' });
        q = s.dispatcher.queue();
        assert.equal(q.find((i) => i.jobId === 2).machine, 'm4mini');
        assert.equal(q.find((i) => i.jobId === 1).machine, null);
    });

    test('a running assignment carries branch, workflow, url on boundJob (capped, null when absent)', async () => {
        const s = build({ machines: { m4mini: { key: true, slots: [slot('Linux', 1, 'idle')] } }, env: CREDS });
        const url = `https://github.com/${REPO}/actions/runs/5/job/3`;
        const minted = await s.assignments.mint({ job: { owner: 'DoubleNode', repo: 'dev-team', jobId: 3, name: 'unit', runId: 5, branch: 'feature/x', workflow: 'CI', url }, machine: 'm4mini', labels: POOL_LINUX, os: 'Linux' });
        assert.equal(minted.ok, true);
        const bare = await s.assignments.mint({ job: { owner: 'DoubleNode', repo: 'dev-team', jobId: 4, name: 'unit', runId: 5 }, machine: 'm4mini', labels: POOL_LINUX, os: 'Linux' });
        s.assignments.takeForMachine('m4mini');
        for (const m of [minted, bare]) s.assignments.report(m.assignment.id, 'm4mini', { state: 'started' });
        const watcherRec = (jobId, extra) => Object.assign({ owner: 'DoubleNode', repo: 'dev-team', jobId, name: 'unit', runId: 5 }, extra);
        s.assignments.bindJob(watcherRec(3, { runnerName: minted.assignment.runnerName, branch: 'feature/x', workflow: 'CI', url }), 'in_progress');
        s.assignments.bindJob(watcherRec(4, { runnerName: bare.assignment.runnerName, branch: 42, workflow: 'x'.repeat(500), url: 'u'.repeat(900) }), 'in_progress');
        const body = await s.get();
        const bound = (id) => body.assignments.find((a) => a.boundJob && a.boundJob.id === id).boundJob;
        assert.deepEqual(bound(3), { id: 3, name: 'unit', runId: 5, branch: 'feature/x', workflow: 'CI', url });
        assert.equal(bound(4).branch, null, 'non-string source is null');
        assert.equal(bound(4).workflow.length, 200);
        assert.equal(bound(4).url.length, 500);
        assert.equal(body.assignments.find((a) => a.boundJob && a.boundJob.id === 3).state, 'running');
        assert.equal(body.assignments.find((a) => a.boundJob && a.boundJob.id === 3).machine, 'm4mini');
    });

    test('no dispatcher wired: inactive noCapacity, empty queueAge, default threshold (not an error)', async () => {
        const s = build({ noDispatcher: true, machines: { m4mini: { slots: [slot('Linux', 1, 'idle')] } } });
        const body = await s.get();
        assert.deepEqual(body.noCapacity, { active: false, since: null, queuedCount: 0, oldestQueuedAt: null });
        assert.deepEqual(body.queueAge, []);
        assert.equal(body.queueAgeThresholdSec, 900);
        assert.equal(body.machines.m4mini.state, 'enabled');
    });

    test('a poll may self-report capability; junk is a 400', async () => {
        const s = build({ machines: { m4mini: { key: true } } });
        const poll = async (extra) => bearer((await req(s.app)).post('/api/ci-pool/agent/poll'), `fcp_${'A'.repeat(43)}`).send(Object.assign({
            schemaVersion: 1, agentVersion: '1.0.0', capacity: CAP, slots: [slot('Linux', 1, 'idle')],
        }, extra));
        assert.equal((await poll({ capability: 'dormant' })).status, 200);
        assert.equal((await s.get()).machines.m4mini.capability, 'dormant');
        assert.equal((await poll({ capability: 'turbo' })).status, 400);
        assert.equal((await poll({})).status, 200);
        assert.equal((await s.get()).machines.m4mini.capability, 'unknown');   // not carried over: absent is not dormant
    });
});

describe('PUT /api/ci-pool/machines/:machine strand protection', () => {
    const one = () => build({ machines: { m4mini: { slots: [slot('Linux', 1, 'idle')] }, m1mini: { enabled: false } } });
    const two = () => build({ machines: { m4mini: { slots: [slot('Linux', 1, 'idle')] }, m1mini: { slots: [slot('macOS', 1, 'idle')] } } });

    test('pausing the LAST enabled-and-unpaused machine -> 409 wouldStrand, nothing changes, refusal audited', async () => {
        const s = one();
        const r = await s.put('m4mini', { paused: true, reason: 'x' });
        assert.equal(r.status, 409);
        assert.equal(r.body.wouldStrand, true);
        assert.equal(r.body.machine, 'm4mini');
        assert.equal(r.body.action, 'pause');
        assert.equal(typeof r.body.error, 'string');
        assert.equal(s.store.getMachine('m4mini').paused, false);
        assert.deepEqual(s.auditRows().filter((a) => a.event === 'pause').map((a) => [a.outcome, a.machine]), [['refused-would-strand', 'm4mini']]);
    });

    test('disabling the last one -> 409 (action disable); with confirm:true -> 200 and applied', async () => {
        const s = one();
        const r = await s.put('m4mini', { enabled: false });
        assert.equal(r.status, 409);
        assert.equal(r.body.action, 'disable');
        assert.equal(s.store.getMachine('m4mini').enabled, true);
        const ok = await s.put('m4mini', { enabled: false, confirm: true });
        assert.equal(ok.status, 200);
        assert.equal(s.store.getMachine('m4mini').enabled, false);
        assert.equal('confirm' in ok.body.record, false);
    });

    test('confirm is never persisted (not in the store, not on disk)', async () => {
        const s = one();
        assert.equal((await s.put('m4mini', { paused: true, confirm: true })).status, 200);
        assert.equal('confirm' in s.store.getMachine('m4mini'), false);
        assert.equal(/confirm/.test(fs.readFileSync(path.join(s.dir, 'ci-pool.json'), 'utf8')), false);
    });

    test('confirm must be boolean; unknown fields are still rejected', async () => {
        const s = one();
        assert.equal((await s.put('m4mini', { paused: true, confirm: 'yes' })).status, 400);
        assert.equal((await s.put('m4mini', { paused: true, nope: 1 })).status, 400);
        assert.equal(s.store.getMachine('m4mini').paused, false);
    });

    test('not the last: another accepting machine exists -> 200 without confirm', async () => {
        const s = two();
        assert.equal((await s.put('m4mini', { paused: true })).status, 200);
        // now m1mini is the last one
        const r = await s.put('m1mini', { enabled: false });
        assert.equal(r.status, 409);
    });

    test('a paused or disabled other machine does not count as capacity', async () => {
        const s = two();
        assert.equal((await s.put('m1mini', { paused: true })).status, 200);
        assert.equal((await s.put('m4mini', { paused: true })).status, 409);
    });

    test('machines that are not accepting never trip the guard; resume/enable are never refused', async () => {
        const s = one();
        assert.equal((await s.put('m1mini', { paused: true })).status, 200);      // m1mini is disabled
        assert.equal((await s.put('m1mini', { enabled: true })).status, 200);
        assert.equal((await s.put('m4mini', { paused: false })).status, 200);     // already accepting: no-op
        assert.equal((await s.put('m4mini', { prefers: 'long' })).status, 200);   // unrelated field
    });

    test('idempotent: repeating the same value is 200 and writes no new audit row', async () => {
        const s = two();
        assert.equal((await s.put('m4mini', { paused: true })).status, 200);
        const n = s.auditRows().length;
        assert.equal((await s.put('m4mini', { paused: true })).status, 200);
        assert.equal((await s.put('m4mini', { enabled: true })).status, 200);
        assert.equal(s.auditRows().length, n);
    });

    test('requires the admin tier', async () => {
        const s = one();
        assert.equal((await (await req(s.app)).put('/api/ci-pool/machines/m4mini').send({ paused: true })).status, 401);
        assert.equal((await bearer((await req(s.app)).put('/api/ci-pool/machines/m4mini'), FLEET).send({ paused: true })).status, 401);
    });
});

describe('enabled flips are audited', () => {
    test('disable and enable each write one row with machine, action, outcome and actor', async () => {
        const s = build({ machines: { m4mini: {}, m1mini: {} } });
        assert.equal((await s.put('m4mini', { enabled: false })).status, 200);
        assert.equal((await s.put('m4mini', { enabled: true })).status, 200);
        const rows = s.auditRows().filter((a) => a.event === 'enable');
        assert.deepEqual(rows.map((r) => [r.machine, r.action, r.enabled, r.outcome, r.by]), [
            ['m4mini', 'disable', false, 'applied', 'operator'],
            ['m4mini', 'enable', true, 'applied', 'operator'],
        ]);
        assert.ok(rows[0].ts);
    });

    test('pause/resume rows now carry action + outcome; confirmed override is recorded', async () => {
        const s = build({ machines: { m4mini: {} } });
        assert.equal((await s.put('m4mini', { paused: true, confirm: true, reason: 'maint' })).status, 200);
        assert.equal((await s.put('m4mini', { paused: false })).status, 200);
        const rows = s.auditRows().filter((a) => a.event === 'pause');
        assert.deepEqual(rows.map((r) => [r.action, r.paused, r.outcome, r.confirmed]), [['pause', true, 'applied', true], ['resume', false, 'applied', false]]);
    });

    test('a PUT that changes only unrelated fields writes no audit row', async () => {
        const s = build({ machines: { m4mini: {} } });
        assert.equal((await s.put('m4mini', { prefers: 'short' })).status, 200);
        assert.equal(s.auditRows().filter((a) => a.event === 'enable' || a.event === 'pause').length, 0);
    });
});
