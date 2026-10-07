//
//  xaca-1441-dispatcher.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1441-007 -- lib/ci-dispatcher.js orchestration.
 * Real pool store / assignments / alerts / placement / policy over a temp dir;
 * fake GitHub (counts calls, throws nothing), fake watcher, fake clock and timers.
 * NO network, no real timers, no real data dir.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const { test, describe, after } = require('node:test');
const assert = require('node:assert/strict');

const { createPoolStore } = require('../lib/ci-pool-store');
const { createAssignments } = require('../lib/ci-dispatch-assignments');
const { createAlerts } = require('../lib/ci-dispatch-alerts');
const { createDispatcher, NO_CAPACITY_AFTER_MS } = require('../lib/ci-dispatcher');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca1441-007-disp-'));
after(() => fs.rmSync(TMP, { recursive: true, force: true }));

const T0 = Date.UTC(2026, 9, 6, 12, 0, 0);
const ENV_ON = { FLEET_CI_DISPATCHER: '1', GITHUB_APP_CLIENT_ID: 'Iv-test-client', GITHUB_APP_PRIVATE_KEY: 'not-a-real-key-fixture' };
const REPO = 'DoubleNode/dev-team';
const POOL = ['self-hosted', 'Linux', 'ARM64', 'fleet-pool'];
let seq = 0;

const capacity = (over = {}) => Object.assign({
    memTotalBytes: 17179869184, memReclaimableBytes: 4080000000, memFreePct: 45,
    swapUsedBytes: 100, swapTotalBytes: 3221225472, load1: 1.2, load5: 1, load15: 1, ncpu: 10,
    teamSessions: 6, vmState: 'running',
}, over);
const slots = (n, osName = 'Linux') => Array.from({ length: n }, (_, i) => ({ os: osName, index: i + 1, state: 'idle', assignmentId: null }));

function rec(jobId, over = {}) {
    return Object.assign({
        key: `${REPO}#${jobId}#1`, owner: 'DoubleNode', repo: 'dev-team', runId: 5, runAttempt: 1, jobId,
        name: 'unit', labels: POOL.slice(), status: 'queued', conclusion: null, runnerName: null,
        createdAt: new Date(T0).toISOString(), firstSeenAt: new Date(T0 + jobId).toISOString(),
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
    const reports = new Map();
    for (const [id, prefers] of [['m4mini', 'long'], ['m1mini', 'short']]) {
        if (opts.machines && !opts.machines.includes(id)) continue;
        assert.equal(store.upsertMachine(id, { enabled: true, prefers }).ok, true);
    }
    const ghCalls = [];
    const gh = {
        async generateJitConfig(a) { ghCalls.push(['mint', a]); return { runnerId: 9000 + ghCalls.length, encodedJitConfig: `JITSENTINEL-${ghCalls.length}` }; },
        async deleteRunner(a) { ghCalls.push(['delete', a]); return { deleted: true }; },
    };
    const auditRows = [];
    const audit = { append: (event, fields) => auditRows.push(Object.assign({ event }, fields)) };
    const assignments = createAssignments({ file: path.join(dir, 'state.json'), github: gh, audit, now: () => clock.t, logger: { error() {}, warn() {} } });
    const lines = [];
    const logger = { log: (m) => lines.push(m), warn: (m) => lines.push(m), error: (m) => lines.push(m) };
    const alerts = createAlerts({ now: () => clock.t, logger, getEmitter: () => null });
    const timers = { set: [], cleared: [] };
    const watcher = { cycles: 0, stopped: 0, async runCycle() { this.cycles++; if (this.onCycle) this.onCycle(); return 15000; }, stop() { this.stopped++; } };
    const d = createDispatcher({
        env: opts.env || ENV_ON, store, assignments, alerts, audit, watcher, reports, logger, now: () => clock.t,
        setTimer: (fn, ms) => { const h = { fn, ms }; timers.set.push(h); return h; },
        clearTimer: (h) => timers.cleared.push(h),
    });
    const report = (id, over = {}, n = 1, osName = 'Linux') => reports.set(id, { receivedAt: clock.t, capacity: capacity(over.capacity), slots: over.slots || slots(n, osName) });
    return { d, store, assignments, alerts, reports, report, clock, ghCalls, auditRows, lines, timers, watcher, gh };
}

const mints = (s) => s.ghCalls.filter((c) => c[0] === 'mint');

describe('dormant (Requirement 3)', () => {
    for (const [name, env] of [['FLEET_CI_DISPATCHER unset', {}], ['flag set but no App credentials', { FLEET_CI_DISPATCHER: '1' }], ['credentials but flag unset', { GITHUB_APP_ID: '1', GITHUB_APP_PRIVATE_KEY: 'x' }], ['flag is "true", not "1"', { FLEET_CI_DISPATCHER: 'true', GITHUB_APP_ID: '1', GITHUB_APP_PRIVATE_KEY: 'x' }]]) {
        test(`${name}: no watcher cycle, no GitHub call, no timer; one dormant log line`, async () => {
            const s = setup({ env });
            assert.equal(s.d.isEnabled(), false);
            assert.equal(s.d.start(), false);
            assert.equal(await s.d.tick(), null);
            s.d.onJob(rec(1), 'queued'); // even a stray event does nothing harmful
            assert.equal(s.watcher.cycles, 0);
            assert.equal(s.ghCalls.length, 0);
            assert.equal(s.timers.set.length, 0);
            assert.equal(s.lines.filter((l) => /dormant/.test(l)).length, 1);
            assert.equal(s.lines.some((l) => /not-a-real-key|BEGIN/.test(l)), false);
        });
    }

    test('createDispatcher without a watcher source is a programming error', () => {
        const s = setup();
        assert.throws(() => createDispatcher({ env: {}, store: s.store, assignments: s.assignments, alerts: s.alerts }), TypeError);
    });
});

describe('lifecycle', () => {
    test('start() schedules exactly one timer; stop() clears it and stops the watcher; start logs the machine id and no secret', () => {
        const s = setup();
        s.d.start();
        assert.equal(s.timers.set.length, 1);
        assert.equal(s.timers.set[0].ms, 0);
        assert.equal(s.d.status().running, true);
        s.d.stop();
        assert.deepEqual(s.timers.cleared, [s.timers.set[0]]);
        assert.equal(s.watcher.stopped, 1);
        assert.equal(s.d.status().running, false);
        assert.ok(s.lines.some((l) => /ENABLED/.test(l)));
        assert.equal(s.lines.some((l) => /Iv-test-client|not-a-real-key/.test(l)), false);
    });

    test('the timer callback runs a tick and reschedules with the watcher delay', async () => {
        const s = setup();
        s.d.start();
        await s.timers.set[0].fn();
        assert.equal(s.watcher.cycles, 1);
        assert.equal(s.timers.set.length, 2);
        assert.equal(s.timers.set[1].ms, 15000);
        s.d.stop();
    });

    test('after stop() a tick is a no-op and nothing reschedules', async () => {
        const s = setup();
        s.d.start();
        s.d.stop();
        assert.equal(await s.d.tick(), null);
        assert.equal(s.watcher.cycles, 0);
    });

    test('a throwing watcher never throws out of tick(); 3 failures raise ci-dispatcher-degraded', async () => {
        const s = setup();
        s.watcher.runCycle = async () => { throw new Error('socket hang up'); };
        for (let i = 0; i < 3; i++) assert.equal(await s.d.tick(), 60000);
        const a = s.alerts.list();
        assert.equal(a.length, 1);
        assert.equal(a[0].type, 'ci-dispatcher-degraded');
        assert.match(a[0].ref, /tick-failed/);
    });

    test('github onDegraded -> ci-dispatcher-degraded alert, deduped', () => {
        const s = setup();
        s.d.onDegraded({ remaining: 12, limit: 5000, resetAt: T0 + 600000 });
        s.d.onDegraded({ remaining: 11, limit: 5000, resetAt: T0 + 600000 });
        const a = s.alerts.list();
        assert.equal(a.length, 1);
        assert.equal(a[0].type, 'ci-dispatcher-degraded');
        assert.equal(a[0].severity, 'warning');
        assert.match(a[0].body, /remaining=12 limit=5000/);
        assert.equal(s.d.alerts().length, 1);
    });
});

describe('policy first (D7)', () => {
    test('fork job carrying the pool label: reject:fork audited once, alert raised, never tracked or minted', async () => {
        const s = setup();
        s.report('m4mini', {}, 2);
        const fork = rec(7, { run: { event: 'pull_request', repoFullName: REPO, headRepoFullName: 'evil/dev-team' } });
        s.d.onJob(fork, 'queued');
        s.d.onJob(fork, 'queued'); // re-sighting: still one audit row
        await s.d.tick();
        const rows = s.auditRows.filter((r) => r.event === 'reject');
        assert.equal(rows.length, 1);
        assert.equal(rows[0].reason, 'reject:fork');
        assert.equal(rows[0].jobId, 7);
        const a = s.alerts.list();
        assert.equal(a.length, 1);
        assert.equal(a[0].type, 'ci-fork-job-on-pool');
        assert.equal(a[0].severity, 'warning');
        assert.equal(s.d.queue().length, 0);
        assert.equal(mints(s).length, 0);
    });

    test('fork job NOT on the pool label: audited, no alert (a plain hosted fork PR is normal)', () => {
        const s = setup();
        s.d.onJob(rec(8, { labels: ['ubuntu-latest'], run: { event: 'pull_request', repoFullName: REPO, headRepoFullName: 'x/y' } }), 'queued');
        assert.equal(s.auditRows.filter((r) => r.reason === 'reject:fork').length, 1);
        assert.equal(s.alerts.list().length, 0);
    });

    test('non-pool job (hosted labels) is skipped silently: not tracked, not audited, counted', () => {
        const s = setup();
        s.d.onJob(rec(9, { labels: ['ubuntu-latest'] }), 'queued');
        assert.equal(s.d.queue().length, 0);
        assert.equal(s.auditRows.length, 0);
        assert.equal(s.d.status().notPoolSkipped, 1);
    });

    test('repo not on the allowlist is rejected and audited', () => {
        const s = setup();
        s.store.updateConfig({ allowlist: ['DoubleNode/other'] });
        s.d.onJob(rec(10), 'queued');
        assert.equal(s.auditRows[0].reason, 'not-allowlisted');
    });

    test('a job picked up or completed leaves the queue', () => {
        const s = setup();
        s.d.onJob(rec(11), 'queued');
        assert.equal(s.d.queue().length, 1);
        s.d.onJob(rec(11, { status: 'in_progress', runnerName: 'fcp-x-1' }), 'pickup');
        assert.equal(s.d.queue().length, 0);
        s.d.onJob(rec(12), 'queued');
        s.d.onJob(rec(12, { status: 'completed' }), 'completed');
        assert.equal(s.d.queue().length, 0);
    });
});

describe('placement: preference only orders (D4/D5)', () => {
    test('long job prefers m4mini when both are eligible', async () => {
        const s = setup();
        s.report('m4mini'); s.report('m1mini');
        s.d.onJob(rec(1, { name: 'shell-suite' }), 'queued');
        await s.d.tick();
        assert.equal(mints(s).length, 1);
        assert.equal(s.assignments.snapshot()[0].machine, 'm4mini');
        assert.ok(mints(s)[0][1].labels.includes('m4mini'));
    });

    test('short job prefers m1mini when both are eligible', async () => {
        const s = setup();
        s.report('m4mini'); s.report('m1mini');
        s.d.onJob(rec(1, { name: 'unit' }), 'queued');
        await s.d.tick();
        assert.equal(s.assignments.snapshot()[0].machine, 'm1mini');
    });

    test('preferred host ineligible (stale poll): the mint goes to the other host, no waiting', async () => {
        const s = setup();
        s.report('m1mini');
        s.reports.set('m4mini', { receivedAt: T0 - 5 * 60 * 1000, capacity: capacity(), slots: slots(1) });
        s.d.onJob(rec(1, { name: 'shell-suite' }), 'queued');
        await s.d.tick();
        assert.equal(mints(s).length, 1);
        assert.equal(s.assignments.snapshot()[0].machine, 'm1mini');
        assert.deepEqual(mints(s)[0][1].labels, ['self-hosted', 'Linux', 'ARM64', 'fleet-pool', 'm1mini']);
    });

    test('paused machine is never chosen', async () => {
        const s = setup();
        s.report('m4mini'); s.report('m1mini');
        s.store.upsertMachine('m1mini', { paused: true, pauseReason: 'user' }, { by: 'test', now: T0 });
        s.d.onJob(rec(1, { name: 'unit' }), 'queued');
        await s.d.tick();
        assert.equal(s.assignments.snapshot()[0].machine, 'm4mini');
    });
});

describe('supply per label-set (A2) and slot accounting', () => {
    test('mixed-case label sets are ONE set end to end', async () => {
        const s = setup({ machines: ['m4mini'] });
        s.report('m4mini', {}, 3);
        s.d.onJob(rec(1, { labels: ['self-hosted', 'Linux', 'ARM64', 'fleet-pool'] }), 'queued');
        s.d.onJob(rec(2, { labels: ['self-hosted', 'linux', 'arm64', 'FLEET-POOL'] }), 'queued');
        await s.d.tick();
        assert.equal(mints(s).length, 2);
        const keys = new Set(s.assignments.snapshot().map((a) => a.id) && [...s.assignments.outstandingBySet().keys()]);
        assert.deepEqual([...keys], ['arm64,fleet-pool,linux,self-hosted']);
        assert.equal(s.assignments.outstandingBySet().get('arm64,fleet-pool,linux,self-hosted'), 2);

        // Nothing new queued: the same tick again must not mint (outstanding covers demand) ...
        s.clock.t += 5000;
        s.report('m4mini', {}, 3);
        await s.d.tick();
        assert.equal(mints(s).length, 2);

        // ... and a third job spelled differently still counts as the same set: exactly one more mint.
        s.d.onJob(rec(3, { labels: ['SELF-HOSTED', 'LINUX', 'Arm64', 'Fleet-Pool'] }), 'queued');
        await s.d.tick();
        assert.equal(mints(s).length, 3);
        assert.equal(s.assignments.outstandingBySet().get('arm64,fleet-pool,linux,self-hosted'), 3);
    });

    test('different label-sets mint independently (macOS vs Linux)', async () => {
        const s = setup({ machines: ['m4mini'] });
        s.reports.set('m4mini', { receivedAt: T0, capacity: capacity(), slots: [...slots(1, 'Linux'), ...slots(1, 'macOS')] });
        s.d.onJob(rec(1), 'queued');
        s.d.onJob(rec(2, { labels: ['self-hosted', 'macOS', 'ARM64', 'fleet-pool'] }), 'queued');
        await s.d.tick();
        assert.equal(mints(s).length, 2);
        assert.deepEqual(s.assignments.snapshot().map((a) => a.os).sort(), ['Linux', 'macOS']);
    });

    test('one idle slot is never promised twice: 2 queued jobs, 1 slot -> 1 mint', async () => {
        const s = setup({ machines: ['m4mini'] });
        s.report('m4mini', {}, 1);
        s.d.onJob(rec(1), 'queued');
        s.d.onJob(rec(2), 'queued');
        await s.d.tick();
        assert.equal(mints(s).length, 1);
        // The pending runner covers the older job; the other waits for capacity without a false alarm.
        s.clock.t += 5000; s.report('m4mini', {}, 1);
        await s.d.tick();
        assert.equal(mints(s).length, 1);
        assert.equal(s.alerts.list().length, 0);
    });

    test('mint failure stops the set for the tick and 3 consecutive failures raise degraded', async () => {
        const s = setup({ machines: ['m4mini'] });
        s.gh.generateJitConfig = async () => { const e = new Error('x'); e.code = 'HTTP'; e.status = 403; throw e; };
        s.report('m4mini', {}, 2);
        s.d.onJob(rec(1), 'queued'); s.d.onJob(rec(2), 'queued');
        for (let i = 0; i < 3; i++) { s.clock.t += 1000; s.report('m4mini', {}, 2); await s.d.tick(); }
        assert.equal(s.assignments.snapshot().length, 0);
        const a = s.alerts.list();
        assert.equal(a.length, 1);
        assert.equal(a[0].type, 'ci-dispatcher-degraded');
        assert.match(a[0].body, /3 consecutive mint failures/);
    });

    // Regression for the sweep() guard that pinned itself after a no-op first sweep (fixed in
    // lib/ci-dispatch-assignments.js; direct test in xaca-1441-assignments.test.js).
    test('tick sweeps assignments first (expired pending runner is DELETEd from GitHub)', async () => {
        const s = setup({ machines: ['m4mini'] });
        s.report('m4mini', {}, 1);
        s.d.onJob(rec(1), 'queued');
        await s.d.tick();
        assert.equal(mints(s).length, 1);
        s.clock.t += 61 * 1000;
        s.report('m4mini', {}, 1);
        await s.d.tick();
        assert.equal(s.ghCalls.filter((c) => c[0] === 'delete').length, 1);
    });

    test('bound pickup flows to assignments.bindJob via onJob', async () => {
        const s = setup({ machines: ['m4mini'] });
        s.report('m4mini', {}, 1);
        s.d.onJob(rec(1), 'queued');
        await s.d.tick();
        const a = s.assignments.snapshot()[0];
        s.assignments.takeForMachine('m4mini', s.clock.t);
        s.assignments.report(a.id, 'm4mini', { state: 'started' });
        s.d.onJob(rec(1, { status: 'in_progress', runnerName: a.runnerName }), 'pickup');
        assert.equal(s.assignments.get(a.id).state, 'running');
        assert.equal(s.d.queue().length, 0);
    });
});

describe('no-capacity alert (Requirement 10)', () => {
    test('fires at 120 s, not before; carries per-machine reasons; no secrets', async () => {
        const s = setup();
        s.report('m1mini');                                  // eligible slot...
        s.store.upsertMachine('m1mini', { paused: true, pauseReason: 'user' }, { by: 't', now: T0 });
        // m4mini never reported -> no-report
        s.d.onJob(rec(1, { name: 'unit' }), 'queued');
        assert.equal(NO_CAPACITY_AFTER_MS, 120000);
        await s.d.tick();                                    // t0: starts the clock
        assert.equal(s.alerts.list().length, 0);
        s.clock.t = T0 + 119 * 1000; s.report('m1mini'); await s.d.tick();
        assert.equal(s.alerts.list().length, 0);
        s.clock.t = T0 + 120 * 1000; s.report('m1mini'); await s.d.tick();
        const a = s.alerts.list();
        assert.equal(a.length, 1);
        assert.equal(a[0].type, 'ci-no-capacity');
        assert.equal(a[0].severity, 'high');
        assert.equal(a[0].ref, 'class:short');
        assert.match(a[0].body, /m1mini: paused/);
        assert.match(a[0].body, /m4mini: no-report/);
        assert.match(a[0].body, /120s/);
        assert.equal(/JITSENTINEL|BEGIN|ghs_/.test(a[0].body), false);
        const row = s.auditRows.find((r) => r.event === 'alert');
        assert.equal(row.jobClass, 'short');
        assert.equal(row.waitedMs, 120000);
    });

    test('deduped per job class for 15 min; another class alerts separately; alerts again after 15 min', async () => {
        const s = setup();                                    // no reports at all
        s.d.onJob(rec(1, { name: 'unit' }), 'queued');
        s.d.onJob(rec(2, { name: 'lint' }), 'queued');       // same class: deduped with job 1
        s.d.onJob(rec(3, { name: 'shell-suite' }), 'queued'); // long: own alert
        await s.d.tick();
        s.clock.t = T0 + 120 * 1000; await s.d.tick();
        assert.deepEqual(s.alerts.list().map((a) => a.ref).sort(), ['class:long', 'class:short']);
        s.clock.t = T0 + 600 * 1000; await s.d.tick();
        assert.equal(s.alerts.list().length, 2);
        s.clock.t = T0 + 120 * 1000 + 15 * 60 * 1000; await s.d.tick();
        assert.equal(s.alerts.list().length, 4);
    });

    test('capacity returning within the window resets the clock (continuous wait only)', async () => {
        const s = setup({ machines: ['m4mini'] });
        s.d.onJob(rec(1), 'queued');
        await s.d.tick();                                     // no report: clock starts
        s.clock.t = T0 + 100 * 1000; s.report('m4mini', {}, 1); await s.d.tick(); // eligible -> minted, clock reset
        assert.equal(mints(s).length, 1);
        s.clock.t = T0 + 130 * 1000; await s.d.tick();
        assert.equal(s.alerts.list().length, 0);
    });

    test('a job already covered by a pending runner is not a no-capacity signal', async () => {
        const s = setup({ machines: ['m4mini'] });
        s.report('m4mini', {}, 1);
        s.d.onJob(rec(1), 'queued');
        await s.d.tick();                                      // mint; slot now reserved
        for (let i = 1; i <= 3; i++) { s.clock.t = T0 + i * 40 * 1000; s.report('m4mini', {}, 1); await s.d.tick(); }
        assert.equal(s.alerts.list().filter((a) => a.type === 'ci-no-capacity').length, 0);
    });
});

describe('queue()/status() views', () => {
    test('queue entries carry class and waits, and nothing secret', async () => {
        const s = setup();
        s.d.onJob(rec(1, { name: 'shell-suite' }), 'queued');
        await s.d.tick();
        s.clock.t += 30000;
        const q = s.d.queue();
        assert.equal(q.length, 1);
        assert.equal(q[0].jobClass, 'long');
        assert.equal(q[0].repo, REPO);
        assert.ok(q[0].waitingMs >= 29000);
        assert.deepEqual(Object.keys(q[0]).sort(), ['jobClass', 'jobId', 'key', 'name', 'noCapacityMs', 'repo', 'waitingMs']);
    });
});
