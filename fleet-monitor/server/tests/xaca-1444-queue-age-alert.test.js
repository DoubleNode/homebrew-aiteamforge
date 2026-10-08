//
//  xaca-1444-queue-age-alert.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1444-011 (server half) -- the queue-AGE alert in lib/ci-dispatcher.js.
 *
 * Regression for 2026-10-07: 44 jobs queued on `fleet-pool,m1mini`, oldest ~32 min, 1 JIT runner
 * busy, 2 persistent runners idle. The old `ci-no-capacity` path stayed silent (shadow mode raises
 * no operational alerts; and with runners present it is not a capacity outage). The queue-age
 * alert must fire regardless of runner state. Real store/assignments/alerts/dispatcher; fake
 * GitHub, watcher and clock. NO network.
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

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca1444-qage-'));
after(() => fs.rmSync(TMP, { recursive: true, force: true }));

const T0 = Date.UTC(2026, 9, 7, 18, 0, 0);
const REPO = 'DoubleNode/dev-team';
const CREDS = { GITHUB_APP_CLIENT_ID: 'Iv-test-client', GITHUB_APP_PRIVATE_KEY: 'not-a-real-key-fixture' };
const LABELS = ['self-hosted', 'macOS', 'ARM64', 'fleet-pool', 'm1mini'];
const SET_KEY = 'arm64,fleet-pool,m1mini,macos,self-hosted';
let seq = 0;

function rec(jobId, minutesOld, over = {}) {
    return Object.assign({
        key: `${REPO}#${jobId}#1`, owner: 'DoubleNode', repo: 'dev-team', runId: 5, runAttempt: 1, jobId,
        name: 'unit', labels: LABELS.slice(), status: 'queued', conclusion: null, runnerName: null,
        createdAt: new Date(T0 - minutesOld * 60000).toISOString(), firstSeenAt: new Date(T0).toISOString(),
        inProgressAt: null, completedAt: null,
        run: { event: 'push', repoFullName: REPO, headRepoFullName: REPO },
    }, over);
}

function setup(opts = {}) {
    const dir = path.join(TMP, `s${++seq}`);
    fs.mkdirSync(dir, { recursive: true });
    const clock = { t: T0 };
    const store = createPoolStore({ file: path.join(dir, 'ci-pool.json'), logger: { error() {} } });
    store.load();
    assert.equal(store.updateConfig({ allowlist: [REPO] }).ok, true);
    assert.equal(store.upsertMachine('m1mini', { enabled: true }).ok, true);
    const gh = { async generateJitConfig() { return { runnerId: 1, encodedJitConfig: 'JITSENTINEL' }; }, async deleteRunner() { return { deleted: true }; } };
    const assignments = createAssignments({ file: path.join(dir, 'state.json'), github: gh, audit: { append() {} }, now: () => clock.t, logger: { error() {}, warn() {} } });
    const lines = [];
    const logger = { log: (m) => lines.push(m), warn: (m) => lines.push(m), error: (m) => lines.push(m) };
    const alerts = createAlerts({ now: () => clock.t, logger, getEmitter: () => null });
    const auditRows = [];
    const reports = new Map();
    const watcher = { async runCycle() { return 15000; }, stop() {} };
    const d = createDispatcher({
        env: Object.assign({ FLEET_CI_DISPATCHER: opts.mode || 'shadow' }, CREDS, opts.env || {}),
        store, assignments, alerts, watcher, reports, logger, now: () => clock.t,
        audit: { append: (event, fields) => auditRows.push(Object.assign({ event }, fields)) },
        setTimer: () => ({}), clearTimer() {},
    });
    // m1mini: one busy slot (the JIT runner) and two idle ones (the persistent runners).
    reports.set('m1mini', {
        receivedAt: T0, slots: [
            { os: 'macOS', index: 1, state: 'busy', assignmentId: 'a_1' },
            { os: 'macOS', index: 2, state: 'idle', assignmentId: null },
            { os: 'macOS', index: 3, state: 'idle', assignmentId: null },
        ],
        capacity: { memTotalBytes: 17179869184, memReclaimableBytes: 4080000000, memFreePct: 45, swapUsedBytes: 100, load1: 1, ncpu: 10, vmState: 'running' },
    });
    const queueN = (n, minutesOld) => { for (let i = 1; i <= n; i++) d.onJob(rec(i, minutesOld - i * 0.01), 'queued'); };
    const queueAgeAlerts = () => alerts.list().filter((a) => a.type === 'ci-queue-age');
    return { d, alerts, clock, lines, auditRows, queueN, queueAgeAlerts, store };
}

describe('queue-age alert (XACA-1444-011)', () => {
    test('REGRESSION 2026-10-07: 44 jobs, oldest ~32 min, runners busy/idle -> alert fires, queueAge + noCapacity reflect it', async () => {
        const s = setup();   // shadow: the mode in which the old no-capacity path stayed silent
        s.queueN(44, 32);
        await s.d.tick();
        const a = s.queueAgeAlerts();
        assert.equal(a.length, 1);
        assert.equal(a[0].severity, 'high');
        assert.equal(a[0].ref, `queue:${SET_KEY}`);
        assert.match(a[0].title, /32 min/);
        assert.match(a[0].body, /44 job/);
        assert.match(a[0].body, /host m1mini/);
        // the OLD path really was silent here: that is the miss this alert closes
        assert.equal(s.alerts.list().filter((x) => x.type === 'ci-no-capacity').length, 0);

        const q = s.d.queueAge();
        assert.equal(q.length, 1);
        assert.equal(q[0].labels, SET_KEY);
        assert.equal(q[0].host, 'm1mini');
        assert.equal(q[0].depth, 44);
        assert.equal(q[0].overThreshold, true);
        assert.ok(q[0].oldestWaitSec >= 32 * 60 - 1 && q[0].oldestWaitSec <= 32 * 60 + 1);

        const nc = s.d.noCapacity();
        assert.equal(nc.active, true);
        assert.equal(nc.queuedCount, 44);
        assert.equal(nc.oldestQueuedAt, q[0].oldestQueuedAt);
        assert.equal(s.auditRows.some((r) => r.event === 'alert' && r.reason === 'ci-queue-age' && r.machine === 'm1mini'), true);
    });

    test('also fires in live mode when an eligible machine exists (busy runners must not hide a stuck queue)', async () => {
        const s = setup({ mode: '1' });
        s.queueN(3, 20);
        await s.d.tick();
        assert.equal(s.queueAgeAlerts().length, 1);
    });

    test('under the threshold: no alert, queueAge listed but not over, noCapacity inactive', async () => {
        const s = setup();
        s.queueN(44, 14);
        await s.d.tick();
        assert.equal(s.queueAgeAlerts().length, 0);
        assert.equal(s.d.queueAge()[0].overThreshold, false);
        assert.equal(s.d.queueAge()[0].depth, 44);
        assert.deepEqual(s.d.noCapacity(), { active: false, since: null, queuedCount: 0, oldestQueuedAt: null });
    });

    test('crosses the threshold as time passes: silent, then fires', async () => {
        const s = setup();
        s.queueN(5, 14);
        await s.d.tick();
        assert.equal(s.queueAgeAlerts().length, 0);
        s.clock.t += 2 * 60000;
        await s.d.tick();
        assert.equal(s.queueAgeAlerts().length, 1);
    });

    test('dedupes within 15 min, re-raises after; one alert per stuck label set', async () => {
        const s = setup();
        s.queueN(5, 40);
        s.d.onJob(rec(900, 40, { labels: ['self-hosted', 'Linux', 'ARM64', 'fleet-pool'] }), 'queued');
        await s.d.tick();
        assert.equal(s.queueAgeAlerts().length, 2);
        s.clock.t += 5 * 60000;
        await s.d.tick();
        assert.equal(s.queueAgeAlerts().length, 2);
        s.clock.t += 11 * 60000;
        await s.d.tick();
        assert.equal(s.queueAgeAlerts().length, 4);
    });

    test('clears when the queue drains: queueAge empty, noCapacity inactive, one "cleared" log line', async () => {
        const s = setup();
        s.queueN(4, 32);
        await s.d.tick();
        assert.equal(s.d.noCapacity().active, true);
        for (let i = 1; i <= 4; i++) s.d.onJob(rec(i, 32), 'completed');
        await s.d.tick();
        assert.deepEqual(s.d.queueAge(), []);
        assert.equal(s.d.noCapacity().active, false);
        assert.equal(s.lines.filter((l) => /queue-age alert cleared/.test(l)).length, 1);
        await s.d.tick();
        assert.equal(s.lines.filter((l) => /queue-age alert cleared/.test(l)).length, 1);
    });

    test('threshold is configurable: FLEET_CI_QUEUE_AGE_ALERT_SEC', async () => {
        const s = setup({ env: { FLEET_CI_QUEUE_AGE_ALERT_SEC: '60' } });
        s.queueN(2, 2);
        await s.d.tick();
        assert.equal(s.queueAgeAlerts().length, 1);
        assert.equal(s.d.queueAgeThresholdSec(), 60);
        const s2 = setup();
        assert.equal(s2.d.queueAgeThresholdSec(), 900);
    });

    test('dormant dispatcher: nothing tracked, nothing raised', async () => {
        const s = setup({ mode: '0' });
        s.queueN(10, 60);
        await s.d.tick();
        assert.deepEqual(s.d.queueAge(), []);
        assert.equal(s.queueAgeAlerts().length, 0);
        assert.equal(s.d.noCapacity().active, false);
    });

    test('noCapacity from no eligible machine (live) counts only once alertable (>= 120 s)', async () => {
        const s = setup({ mode: '1' });
        s.store.upsertMachine('m1mini', { paused: true });
        s.queueN(2, 1);
        await s.d.tick();
        assert.equal(s.d.noCapacity().active, false);
        s.clock.t += 130000;
        await s.d.tick();
        const nc = s.d.noCapacity();
        assert.equal(nc.active, true);
        assert.equal(nc.queuedCount, 2);
        assert.equal(nc.since, new Date(T0).toISOString());
    });
});
