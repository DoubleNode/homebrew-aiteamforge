//
//  xaca-1479-adversarial.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1479-009 -- adversarial gap tests added by the QA pass (Thok). The implementer suite
 * (xaca-1479-ci-priority-dispatch.test.js) covers the planned behaviour; these pin the edges it
 * left open: zero capacity, cross-label-set contention for one slot, late/unknown priority events,
 * and the bound on mints. No network, fake clock, temp dir.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const { test, describe, after } = require('node:test');
const assert = require('node:assert/strict');

const { createPoolStore } = require('../lib/ci-pool-store');
const { createAssignments } = require('../lib/ci-dispatch-assignments');
const { createAlerts } = require('../lib/ci-dispatch-alerts');
const { createDispatcher } = require('../lib/ci-dispatcher');
const { createPriorityResolver } = require('../lib/ci-dispatch-github');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca1479-adv-'));
after(() => fs.rmSync(TMP, { recursive: true, force: true }));

const T0 = Date.UTC(2026, 9, 9, 12, 0, 0);
const OWNER = 'DoubleNode';
const REPO_NAME = 'dev-team';
const REPO = `${OWNER}/${REPO_NAME}`;
const POOL = ['self-hosted', 'Linux', 'ARM64', 'fleet-pool'];
const POOL_B = POOL.concat(['m1mini']);   // a second VALID label set: pool labels + the host label (an unknown extra label makes the job ineligible)
const ENV_ON = { FLEET_CI_DISPATCHER: '1', GITHUB_APP_CLIENT_ID: 'Iv-test-client', GITHUB_APP_PRIVATE_KEY: 'not-a-real-key-fixture' };
let seq = 0;

const capacity = () => ({
    memTotalBytes: 17179869184, memReclaimableBytes: 4080000000, memFreePct: 45,
    swapUsedBytes: 100, swapTotalBytes: 3221225472, load1: 1.2, load5: 1, load15: 1, ncpu: 10,
    teamSessions: 6, vmState: 'running',
});
const slots = (n) => Array.from({ length: n }, (_, i) => ({ os: 'Linux', index: i + 1, state: 'idle', assignmentId: null }));

function rec(jobId, over = {}) {
    return Object.assign({
        key: `${REPO}#${jobId}#1`, owner: OWNER, repo: REPO_NAME, runId: 5, runAttempt: 1, jobId,
        name: 'unit', labels: POOL.slice(), status: 'queued', conclusion: null, runnerName: null,
        branch: 'feature/xaca-9999', createdAt: new Date(T0).toISOString(), firstSeenAt: new Date(T0 + jobId * 1000).toISOString(),
        inProgressAt: null, completedAt: null,
        run: { event: 'push', repoFullName: REPO, headRepoFullName: REPO },
    }, over);
}

function setup({ failMint = false } = {}) {
    const dir = path.join(TMP, `d${++seq}`);
    fs.mkdirSync(dir, { recursive: true });
    const clock = { t: T0 + 60000 };
    const store = createPoolStore({ file: path.join(dir, 'ci-pool.json'), logger: { error() {} } });
    store.load();
    assert.equal(store.updateConfig({ allowlist: [REPO] }).ok, true);
    assert.equal(store.upsertMachine('m1mini', { enabled: true, paused: false, prefers: 'short' }).ok, true);
    const reports = new Map();
    const ghCalls = [];
    const gh = {
        async generateJitConfig(a) { ghCalls.push(['mint', a]); if (failMint) throw Object.assign(new Error('mint refused'), { code: 'boom', status: 500 }); return { runnerId: 9000 + ghCalls.length, encodedJitConfig: `JITSENTINEL-${ghCalls.length}` }; },
        async deleteRunner(a) { ghCalls.push(['delete', a]); return { deleted: true }; },
    };
    const auditRows = [];
    const audit = { append: (event, fields) => auditRows.push(Object.assign({ event }, fields)) };
    const assignments = createAssignments({ file: path.join(dir, 'state.json'), github: gh, audit, now: () => clock.t, logger: { error() {}, warn() {} } });
    const logger = { log() {}, warn() {}, error() {} };
    const alerts = createAlerts({ now: () => clock.t, logger, getEmitter: () => null });
    const watcher = { async runCycle() { return 15000; }, stop() {} };
    const d = createDispatcher({
        env: ENV_ON, store, assignments, alerts, audit, watcher, reports, logger, now: () => clock.t,
        setTimer: () => ({}), clearTimer: () => {},
    });
    const report = (id, n) => reports.set(id, { receivedAt: clock.t, capacity: capacity(), slots: slots(n) });
    const mints = () => ghCalls.filter((c) => c[0] === 'mint');
    const mintedJobs = () => assignments.snapshot().slice().sort((a, b) => (a.createdAt < b.createdAt ? -1 : 1)).map((a) => a.intendedJob && a.intendedJob.id);
    return { d, report, mints, mintedJobs, auditRows };
}

describe('009 decide(): edges', () => {
    test('slot cap 0 with a CRITICAL job queued: no mint, no surge audit, no throw', async () => {
        const s = setup();
        s.report('m1mini', 0);
        for (let i = 1; i <= 3; i++) s.d.onJob(rec(i, { priority: 'normal' }), 'queued');
        s.d.onJob(rec(4, { priority: 'critical' }), 'queued');
        await s.d.tick();
        assert.equal(s.mints().length, 0);
        assert.equal(s.auditRows.filter((a) => a.event === 'surge').length, 0);
        assert.equal(s.d.queue().find((q) => q.jobId === 4).priority, 'critical', 'the queue still reports the priority');
    });

    test('two label sets, one free slot, CRITICAL in one set and HIGH in the other: exactly one mint, for the critical job', async () => {
        const s = setup();
        s.report('m1mini', 1);
        s.d.onJob(rec(1, { labels: POOL_B, priority: 'high' }), 'queued');
        s.d.onJob(rec(2, { labels: POOL, priority: 'critical' }), 'queued');
        await s.d.tick();
        assert.equal(s.mints().length, 1);
        assert.deepEqual(s.mintedJobs(), [2]);
    });

    test('never mints more runners than there are queued jobs, however many slots are free', async () => {
        const s = setup();
        s.report('m1mini', 8);
        s.d.onJob(rec(1, { priority: 'normal' }), 'queued');
        s.d.onJob(rec(2, { priority: 'critical' }), 'queued');
        await s.d.tick();
        assert.equal(s.mints().length, 2);
        await s.d.tick();
        assert.equal(s.mints().length, 2, 'a second tick adds nothing');
    });

    test('a mint failure stops that label set for the tick: one GitHub mint call per set, not one per queued job', async () => {
        const s = setup({ failMint: true });
        s.report('m1mini', 6);
        for (let i = 1; i <= 3; i++) s.d.onJob(rec(i, { priority: 'normal' }), 'queued');
        s.d.onJob(rec(4, { priority: 'critical' }), 'queued');
        for (let i = 5; i <= 6; i++) s.d.onJob(rec(i, { labels: POOL_B, priority: 'high' }), 'queued');
        await s.d.tick();
        assert.equal(s.mints().length, 2, 'exactly one attempt per label set');
    });

    test('equal priority keeps FIFO by first sight, regardless of arrival order of the events', async () => {
        const s = setup();
        s.report('m1mini', 2);
        s.d.onJob(rec(3, { priority: 'high' }), 'queued');
        s.d.onJob(rec(1, { priority: 'high' }), 'queued');
        s.d.onJob(rec(2, { priority: 'high' }), 'queued');
        await s.d.tick();
        assert.deepEqual(s.mintedJobs(), [1, 2]);
    });
});

describe('009 priority events for jobs that are not queued', () => {
    test('a late priority event for a job never seen does not appear in the queue', () => {
        const s = setup();
        s.d.onJob(rec(77, { priority: 'critical' }), 'priority');
        assert.equal(s.d.queue().some((q) => q.jobId === 77), false);
    });

    test('a priority event for a job that already started does not put it back in the queue', () => {
        const s = setup();
        s.d.onJob(rec(5, { priority: 'normal' }), 'queued');
        s.d.onJob(rec(5, { status: 'in_progress', runnerName: 'r', priority: 'normal' }), 'in_progress');
        s.d.onJob(rec(5, { status: 'in_progress', runnerName: 'r', priority: 'critical' }), 'priority');
        assert.equal(s.d.queue().some((q) => q.jobId === 5), false);
    });
});

describe('009 resolver: the outer fail-to-normal net', () => {
    test('a fork branch never inherits the upstream branch priority from the cache (head owner is in the key)', async () => {
        const calls = [];
        const gh = {
            getRateState() { return { mode: 'normal' }; },
            async listBranchPullLabels(q) {
                calls.push(q.headOwner);
                return q.headOwner === OWNER ? [{ number: 1, labels: ['ci-priority:critical'] }] : [];
            },
        };
        const r = createPriorityResolver({ github: gh, audit: { append() {} } });
        assert.equal(await r.resolve({ owner: OWNER, repo: REPO_NAME, branch: 'fix', headOwner: OWNER }), 'critical');
        assert.equal(await r.resolve({ owner: OWNER, repo: REPO_NAME, branch: 'fix', headOwner: 'someone-else' }), 'normal');
        assert.deepEqual(calls, [OWNER, 'someone-else']);
    });
    test('a throwing getRateState (outside the GitHub call) still resolves NORMAL with an error audit line', async () => {
        const rows = [];
        const gh = {
            getRateState() { throw new Error('rate state exploded'); },
            async listBranchPullLabels() { return [{ number: 1, labels: ['ci-priority:critical'] }]; },
        };
        const r = createPriorityResolver({ github: gh, audit: { append: (e, f) => rows.push(Object.assign({ event: e }, f)) } });
        assert.equal(await r.resolve({ owner: OWNER, repo: REPO_NAME, branch: 'feature/x' }), 'normal');
        assert.equal(rows.filter((a) => a.reason === 'error' && a.priority === 'normal').length, 1, JSON.stringify(rows));
        assert.equal(rows.some((a) => a.priority !== 'normal'), false);
    });
});
