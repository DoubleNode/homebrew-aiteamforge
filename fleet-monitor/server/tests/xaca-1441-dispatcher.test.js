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
    const ref = {};
    const watcher = opts.makeWatcher
        ? opts.makeWatcher({ now: () => clock.t, onJob: (r, c) => ref.d.onJob(r, c) })
        : { cycles: 0, stopped: 0, async runCycle() { this.cycles++; if (this.onCycle) this.onCycle(); return 15000; }, stop() { this.stopped++; } };
    const d = ref.d = createDispatcher({
        maxMintsPerJob: opts.maxMintsPerJob, maxTrackedMs: opts.maxTrackedMs,
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

    test('workflow_run job (run-level head == base, as GitHub emits it): reject:fork-unverifiable, alert, never minted', async () => {
        // PR #1083 review BLOCKING 1: a workflow_run chained from a fork PR reports head_repository = base.
        const s = setup();
        s.report('m4mini', {}, 2);
        const chained = rec(11, { run: { event: 'workflow_run', repoFullName: REPO, headRepoFullName: REPO } });
        s.d.onJob(chained, 'queued');
        await s.d.tick();
        const rows = s.auditRows.filter((r) => r.event === 'reject');
        assert.equal(rows.length, 1);
        assert.equal(rows[0].reason, 'reject:fork-unverifiable');
        assert.equal(rows[0].runEvent, 'workflow_run');
        const a = s.alerts.list();
        assert.equal(a.length, 1);
        assert.equal(a[0].type, 'ci-fork-job-on-pool');
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

// XACA-1441 PR #1083 review (tester BLOCKING): a tracked job that leaves GitHub's view without a
// `completed` event must stop being demand. Real watcher + real dispatcher + real assignments over a
// fake GitHub; machines re-report every step so a stale poll can never make a row pass vacuously.
describe('ghost demand is bounded end to end (PR #1083)', () => {
    const { createWatcher } = require('../lib/ci-dispatch-watcher');
    const { GithubError } = require('../lib/ci-dispatch-github');
    const { MAX_MINTS_PER_JOB } = require('../lib/ci-dispatcher');
    const httpErr = (status) => new GithubError('HTTP', `GET jobs failed: HTTP ${status}`, { status });

    function fakeWorld() {
        const w = { queued: [], in_progress: [], jobs: {}, failJobs: {}, seen: new Map() };
        w.github = {
            getRateState: () => ({ mode: 'normal', resumeAt: null }),
            async conditionalGet({ path: p }) {
                let m;
                if ((m = /\/actions\/runs\/(\d+)\/jobs/.exec(p)) && w.failJobs[m[1]]) throw w.failJobs[m[1]];
                let data;
                if ((m = /\/actions\/runs\?status=(\w+)/.exec(p))) data = { workflow_runs: w[m[1]] };
                else if ((m = /\/actions\/runs\/(\d+)\/jobs/.exec(p))) data = { jobs: w.jobs[m[1]] || [] };
                else throw new Error(`unexpected path ${p}`);
                const body = JSON.stringify(data);
                const notModified = w.seen.get(p) === body;
                w.seen.set(p, body);
                return { status: notModified ? 304 : 200, notModified, data, etag: 'x' };
            },
        };
        return w;
    }
    const ghRun = (id, extra = {}) => ({ id, run_attempt: 1, event: 'push', updated_at: '2026-10-06T12:00:00Z',
        repository: { full_name: REPO }, head_repository: { full_name: REPO }, ...extra });
    const ghJob = (id, extra = {}) => ({ id, name: 'unit', status: 'queued', conclusion: null, runner_name: null,
        labels: POOL.slice(), created_at: '2026-10-06T11:59:00Z', run_attempt: 1, ...extra });

    function build() {
        const world = fakeWorld();
        world.queued = [ghRun(7)]; world.jobs[7] = [ghJob(101)];
        const s = setup({
            machines: ['m4mini'],
            makeWatcher: ({ now, onJob }) => createWatcher({ github: world.github, allowlist: [REPO], now, onJob, log: () => {} }),
        });
        const step = async (ms = 30 * 1000) => { s.clock.t += ms; s.report('m4mini', {}, 2); await s.d.tick(); };
        const mintsFor = (jobId) => s.auditRows.filter((r) => r.event === 'assign' && r.jobId === jobId && r.state !== 'mint-failed').length;
        const queued = (jobId) => s.d.queue().some((q) => q.jobId === jobId);
        return { world, s, step, mintsFor, queued };
    }

    const VANISH_ROWS = [
        ['run deleted: jobs answer 404', (w) => { w.queued = []; w.failJobs[7] = httpErr(404); }],
        ['run deleted: jobs answer 410', (w) => { w.queued = []; w.failJobs[7] = httpErr(410); }],
        ['finished run no longer lists the job', (w) => { w.queued = []; w.jobs[7] = []; }],
        ['cancel + re-run: attempt 2 supersedes the attempt-1 job', (w) => {
            w.queued = [ghRun(7, { run_attempt: 2, updated_at: '2026-10-06T12:05:00Z' })];
            w.jobs[7] = [ghJob(301, { run_attempt: 2 })];
        }],
    ];
    for (const [name, mutate] of VANISH_ROWS) {
        test(`${name}: leaves the queue and is never minted again`, async () => {
            const g = build();
            await g.step();
            assert.equal(g.mintsFor(101), 1, 'fixture: the job was dispatched once');
            mutate(g.world);
            for (let i = 0; i < 40; i++) await g.step(); // 20 min: pending/delivered/started expiries all pass
            assert.equal(g.queued(101), false, 'ghost left the queue');
            assert.equal(g.mintsFor(101), 1, 'no further generate-jitconfig for the ghost');
        });
    }

    test('run parked off the lists with an unchanged body (e.g. waiting): mints capped, then retired', async () => {
        const g = build();
        await g.step();
        g.world.queued = []; // jobs body unchanged: every fetch is a 304 replay
        for (let i = 0; i < 80; i++) await g.step(); // 40 min of runner expiries, no pickup
        assert.ok(g.mintsFor(101) <= MAX_MINTS_PER_JOB, `bounded: ${g.mintsFor(101)} mints`);
        assert.equal(g.queued(101), false);
        assert.ok(g.s.auditRows.some((r) => r.event === 'expire' && r.jobId === 101 && /^ghost-bound: /.test(r.reason)));
        assert.ok(g.s.alerts.list().some((a) => a.type === 'ci-dispatcher-degraded'));
    });

    test('backstop: tracked longer than maxTrackedMs is retired even with no mints', async () => {
        const world = fakeWorld();
        world.queued = [ghRun(7)]; world.jobs[7] = [ghJob(101)];
        const s = setup({ machines: ['m4mini'], maxTrackedMs: 60 * 60 * 1000,
            makeWatcher: ({ now, onJob }) => createWatcher({ github: world.github, allowlist: [REPO], now, onJob, log: () => {} }) });
        await s.d.tick();               // tracked; no machine has reported, so nothing is minted
        assert.equal(s.d.queue().length, 1);
        s.clock.t += 61 * 60 * 1000;
        await s.d.tick();
        assert.equal(s.d.queue().length, 0);
        assert.equal(s.ghCalls.filter((c) => c[0] === 'mint').length, 0);
        assert.ok(s.auditRows.some((r) => r.event === 'expire' && /tracked over 1 h/.test(r.reason)));
    });

    test('control: a live, listed, still-queued job keeps being dispatched (no false retirement)', async () => {
        const g = build();
        await g.step();
        for (let i = 0; i < 6; i++) await g.step(); // 3 min: one expiry, one re-mint at most
        assert.equal(g.queued(101) || g.mintsFor(101) >= 1, true);
        assert.ok(g.mintsFor(101) < MAX_MINTS_PER_JOB);
        assert.equal(g.s.auditRows.filter((r) => r.event === 'expire' && /ghost-bound/.test(r.reason || '')).length, 0);
    });
});

// XACA-1441-031: a pool job that no single runner can satisfy is a workflow misconfiguration, never a
// capacity outage. It is audited, raises ci-job-misconfigured (deduped per repo) and never waits on the
// no-capacity timer.
describe('ambiguous pool jobs are misconfigurations (031)', () => {
    const OTHER = 'DoubleNode/other';
    const LABEL_TABLE = [
        // [description, labels, expected audit reason or null when accepted]
        ['one OS label', ['self-hosted', 'Linux', 'ARM64', 'fleet-pool'], null],
        ['one OS label + one host label', ['self-hosted', 'Linux', 'ARM64', 'fleet-pool', 'm4mini'], null],
        ['two OS labels', ['self-hosted', 'Linux', 'macOS', 'fleet-pool'], 'label:ambiguous'],
        ['no OS label', ['self-hosted', 'ARM64', 'fleet-pool'], 'label:ambiguous'],
        ['two host labels', ['self-hosted', 'Linux', 'fleet-pool', 'm4mini', 'm1mini'], 'label:ambiguous'],
    ];
    for (const [name, labels, reason] of LABEL_TABLE) {
        test(`${name}: ${reason ? 'rejected as label:ambiguous with a ci-job-misconfigured alert' : 'accepted and tracked'}`, () => {
            const s = setup();
            s.d.onJob(rec(1, { labels }), 'queued');
            const rows = s.auditRows.filter((r) => r.event === 'reject');
            if (reason === null) {
                assert.equal(rows.length, 0);
                assert.equal(s.d.queue().length, 1);
                assert.equal(s.alerts.list().length, 0);
                return;
            }
            assert.equal(rows.length, 1);
            assert.equal(rows[0].reason, 'label:ambiguous');
            assert.equal(s.d.queue().length, 0);
            const a = s.alerts.list();
            assert.equal(a.length, 1);
            assert.equal(a[0].type, 'ci-job-misconfigured');
            assert.equal(a[0].severity, 'warning');
            assert.equal(a[0].ref, REPO);
            assert.match(a[0].body, /exactly one OS label/);
        });
    }

    test('never a ci-no-capacity alert, however long it waits, and never minted', async () => {
        const s = setup();
        s.report('m4mini', {}, 2);
        s.d.onJob(rec(1, { labels: ['self-hosted', 'Linux', 'macOS', 'fleet-pool'] }), 'queued');
        for (let i = 0; i < 8; i++) { s.clock.t += NO_CAPACITY_AFTER_MS; s.report('m4mini', {}, 2); await s.d.tick(); }
        assert.equal(mints(s).length, 0);
        assert.deepEqual([...new Set(s.alerts.list().map((a) => a.type))], ['ci-job-misconfigured']);
    });

    test('control: a REAL capacity outage (valid labels, no machine) still raises ci-no-capacity, not ci-job-misconfigured', async () => {
        const s = setup();
        s.d.onJob(rec(2), 'queued');
        await s.d.tick();
        s.clock.t += NO_CAPACITY_AFTER_MS + 1000;
        await s.d.tick();
        assert.deepEqual([...new Set(s.alerts.list().map((a) => a.type))], ['ci-no-capacity']);
    });

    test('deduped per repo: two ambiguous jobs in one repo raise once; a second repo raises its own', () => {
        const s = setup();
        s.store.updateConfig({ allowlist: [REPO, OTHER] });
        const amb = ['self-hosted', 'fleet-pool'];
        s.d.onJob(rec(1, { labels: amb }), 'queued');
        s.d.onJob(rec(2, { labels: amb }), 'queued');
        assert.equal(s.alerts.list().length, 1);
        s.d.onJob(rec(3, { owner: 'DoubleNode', repo: 'other', key: `${OTHER}#3#1`, labels: amb, run: { event: 'push', repoFullName: OTHER, headRepoFullName: OTHER } }), 'queued');
        assert.deepEqual(s.alerts.list().map((a) => a.ref).sort(), [OTHER, REPO].sort());
        assert.equal(s.auditRows.filter((r) => r.reason === 'label:ambiguous').length, 3, 'each job is audited once');
    });

    test('a host label appearing in config turns label:unknown into accepted without touching ambiguity', () => {
        const s = setup({ machines: ['m4mini'] });
        s.d.onJob(rec(1, { labels: ['self-hosted', 'Linux', 'fleet-pool', 'm9mini'] }), 'queued');
        assert.equal(s.auditRows.at(-1).reason, 'label:unknown');
    });
});

// XACA-1441-029: a config change must reach jobs that were rejected under the old config, and the
// watcher's allowlist must be live.
describe('config changes re-evaluate rejected jobs (029)', () => {
    const FORK_RUN = { event: 'pull_request', repoFullName: REPO, headRepoFullName: 'evil/dev-team' };

    test('a job rejected not-allowlisted becomes tracked demand and is minted once its repo is added', async () => {
        const s = setup();
        s.report('m4mini', {}, 2);
        s.store.updateConfig({ allowlist: ['DoubleNode/other'] });
        s.d.onJob(rec(10), 'queued');
        assert.equal(s.auditRows[0].reason, 'not-allowlisted');
        await s.d.tick();
        assert.equal(mints(s).length, 0);
        s.store.updateConfig({ allowlist: ['DoubleNode/other', REPO] });
        assert.deepEqual(s.d.onConfigChanged(), { promoted: 1, dropped: 0 });
        assert.equal(s.d.queue().length, 1);
        await s.d.tick();
        assert.equal(mints(s).length, 1);
        assert.equal(s.auditRows.filter((r) => r.event === 'reject').length, 1, 'one reject row, not re-audited by the re-check');
    });

    const CONFIG_ROWS = [
        ['label:not-pool, then the pool label is renamed to match the job', () => ({ labels: ['self-hosted', 'Linux', 'ARM64', 'new-pool'] }),
            (s) => s.store.updateConfig({ poolLabel: 'new-pool' })],
        ['label:unknown, then the host label is registered', () => ({ labels: [...POOL, 'm9mini'] }),
            (s) => s.store.upsertMachine('m9mini', { enabled: true })],
    ];
    for (const [name, over, change] of CONFIG_ROWS) {
        test(`${name}: promoted`, () => {
            const s = setup();
            s.d.onJob(rec(1, over()), 'queued');
            assert.equal(s.d.queue().length, 0);
            assert.equal(change(s).ok, true);
            assert.equal(s.d.onConfigChanged().promoted, 1);
            assert.equal(s.d.queue().length, 1);
        });
    }

    test('label:ambiguous is remembered too, and still ambiguous after an unrelated config change', () => {
        const s = setup();
        s.d.onJob(rec(1, { labels: ['self-hosted', 'fleet-pool'] }), 'queued');
        assert.equal(s.d.status().configRejected, 1);
        s.store.updateConfig({ jobClasses: { x: 'long' } });
        assert.equal(s.d.onConfigChanged().promoted, 0);
        assert.equal(s.d.queue().length, 0);
        assert.equal(s.auditRows.filter((r) => r.event === 'reject').length, 1);
    });

    test('a fork-rejected job is NEVER promoted by a config change (not even one that allowlists its repo)', async () => {
        const s = setup();
        s.report('m4mini', {}, 2);
        s.d.onJob(rec(7, { run: FORK_RUN }), 'queued');
        s.d.onJob(rec(8, { run: { event: 'workflow_run', repoFullName: REPO, headRepoFullName: REPO } }), 'queued');
        assert.equal(s.d.status().configRejected, 0, 'fork reasons are not remembered');
        for (const change of [{ allowlist: [REPO, 'DoubleNode/other'] }, { poolLabel: 'fleet-pool' }, { jobClasses: { unit: 'long' } }]) {
            s.store.updateConfig(change);
            assert.deepEqual(s.d.onConfigChanged(), { promoted: 0, dropped: 0 });
        }
        s.store.upsertMachine('m9mini', { enabled: true });
        s.d.onConfigChanged();
        await s.d.tick();
        assert.equal(s.d.queue().length, 0);
        assert.equal(mints(s).length, 0);
    });

    test('a job that was not-allowlisted AND from a fork is rejected as not-allowlisted, then as FORK once its repo is allowlisted (never accepted)', async () => {
        const s = setup();
        s.report('m4mini', {}, 2);
        s.store.updateConfig({ allowlist: ['DoubleNode/other'] });
        s.d.onJob(rec(7, { run: FORK_RUN }), 'queued');
        assert.equal(s.auditRows.at(-1).reason, 'not-allowlisted');
        s.store.updateConfig({ allowlist: ['DoubleNode/other', REPO] });
        assert.deepEqual(s.d.onConfigChanged(), { promoted: 0, dropped: 0 });
        assert.equal(s.d.queue().length, 0);
        assert.equal(s.d.status().configRejected, 0, 'now a fork reason: forgotten');
        await s.d.tick();
        assert.equal(mints(s).length, 0);
        assert.ok(s.alerts.list().some((a) => a.type === 'ci-fork-job-on-pool'));
    });

    test('entries are dropped on pickup, in_progress and completed, so they are never re-evaluated', () => {
        const s = setup();
        s.store.updateConfig({ allowlist: ['DoubleNode/other'] });
        for (const [id, change] of [[1, 'pickup'], [2, 'in_progress'], [3, 'completed']]) {
            s.d.onJob(rec(id), 'queued');
            assert.equal(s.d.status().configRejected, 1, 'remembered while queued');
            s.d.onJob(rec(id, { status: change === 'completed' ? 'completed' : 'in_progress', runnerName: 'fcp-x' }), change);
            assert.equal(s.d.status().configRejected, 0, change);
        }
        s.store.updateConfig({ allowlist: [REPO] });
        assert.equal(s.d.onConfigChanged().promoted, 0);
        assert.equal(s.d.queue().length, 0);
    });

    test('the memory is bounded at MAX_CONFIG_REJECTED: the oldest are evicted, the newest survive', () => {
        const { MAX_CONFIG_REJECTED } = require('../lib/ci-dispatcher');
        assert.equal(MAX_CONFIG_REJECTED, 500);
        const s = setup();
        s.store.updateConfig({ allowlist: ['DoubleNode/other'] });
        for (let i = 1; i <= MAX_CONFIG_REJECTED + 25; i++) s.d.onJob(rec(i), 'queued');
        assert.equal(s.d.status().configRejected, MAX_CONFIG_REJECTED);
        s.store.updateConfig({ allowlist: [REPO] });
        assert.equal(s.d.onConfigChanged().promoted, MAX_CONFIG_REJECTED);
        const ids = new Set(s.d.queue().map((q) => q.jobId));
        assert.equal(ids.has(1), false, 'oldest evicted');
        assert.equal(ids.has(25), false);
        assert.equal(ids.has(26), true);
        assert.equal(ids.has(MAX_CONFIG_REJECTED + 25), true, 'newest kept');
    });

    test('removing a repo from the allowlist stops dispatching its already-tracked jobs', async () => {
        const s = setup();
        s.report('m4mini', {}, 2);
        s.d.onJob(rec(1), 'queued');
        assert.equal(s.d.queue().length, 1);
        s.store.updateConfig({ allowlist: ['DoubleNode/other'] });
        assert.deepEqual(s.d.onConfigChanged(), { promoted: 0, dropped: 1 });
        await s.d.tick();
        assert.equal(s.d.queue().length, 0);
        assert.equal(mints(s).length, 0);
    });

    test('a ghost-retired job is not resurrected by a config change', async () => {
        const s = setup({ maxTrackedMs: 60 * 60 * 1000 });
        s.d.onJob(rec(1), 'queued');
        s.clock.t += 61 * 60 * 1000;
        await s.d.tick();
        assert.equal(s.d.queue().length, 0);
        s.d.onConfigChanged();
        assert.equal(s.d.queue().length, 0);
    });

    test('onConfigChanged is safe on a dormant dispatcher and never throws', () => {
        const s = setup({ env: {} });
        assert.deepEqual(s.d.onConfigChanged(), { promoted: 0, dropped: 0 });
    });

    test('start() hands the watcher a LIVE allowlist getter that tracks the store', () => {
        const dir = path.join(TMP, `s${++seq}`);
        fs.mkdirSync(dir, { recursive: true });
        const store = createPoolStore({ file: path.join(dir, 'ci-pool.json'), logger: { error() {} } });
        store.load();
        store.updateConfig({ allowlist: [REPO] });
        const gh = { async generateJitConfig() { throw new Error('no'); }, async deleteRunner() { return {}; } };
        const assignments = createAssignments({ file: path.join(dir, 's.json'), github: gh, now: () => T0, logger: { error() {}, warn() {} } });
        let args = null;
        const d = createDispatcher({
            env: ENV_ON, store, assignments, alerts: createAlerts({ now: () => T0, logger: { warn() {} }, getEmitter: () => null }),
            createWatcher: (a) => { args = a; return { async runCycle() { return 15000; }, stop() {} }; },
            setTimer: () => ({}), clearTimer() {}, logger: { log() {}, warn() {}, error() {} },
        });
        d.start();
        assert.equal(typeof args.getAllowlist, 'function');
        assert.deepEqual(args.getAllowlist(), [REPO]);
        store.updateConfig({ allowlist: ['DoubleNode/other'] });
        assert.deepEqual(args.getAllowlist(), ['DoubleNode/other']);
        d.stop();
    });
});

// XACA-1441-033: the ghost backstop counts runners minted FOR a job that expired without ever binding
// a job. Under label contention GitHub may hand job A's runner to job B; that must not retire a real job A.
describe('ghost backstop counts unpicked runners, not mints (033)', () => {
    const A = 101;
    const isRetired = (s) => s.auditRows.some((r) => r.event === 'expire' && r.jobId === A && /^ghost-bound: \d+ runners expired unpicked$/.test(r.reason));

    /** One more runner for job A that is never delivered: it expires `pending` after 60 s. */
    async function mintAndLetExpire(s) {
        s.report('m4mini', {}, 2);
        await s.d.tick();                 // sweeps older ones, mints one if A is still demand
        s.clock.t += 61 * 1000;
    }
    /** One more runner for job A that GitHub hands to job `other`: it binds and runs. */
    async function mintAndBindElsewhere(s, other) {
        s.report('m4mini', {}, 2);
        await s.d.tick();
        const before = s.assignments.snapshot().filter((x) => x.state === 'pending' && x.intendedJob.id === A);
        assert.equal(before.length, 1, 'fixture: a runner was minted for A');
        s.assignments.takeForMachine('m4mini');
        s.d.onJob(rec(other, { status: 'in_progress', runnerName: before[0].runnerName }), 'pickup');
        assert.equal(s.assignments.get(before[0].id).boundJob.id, other, 'fixture: bound to the other job');
        s.clock.t += 5 * 1000;
    }

    for (const [expired, retired] of [[4, false], [5, true]]) {
        test(`${expired} expired-unbound runners ${retired ? 'retire' : 'do not retire'} the job`, async () => {
            const s = setup({ machines: ['m4mini'] });
            s.d.onJob(rec(A), 'queued');
            for (let i = 0; i < expired; i++) await mintAndLetExpire(s);
            s.report('m4mini', {}, 2);
            await s.d.tick();             // sweep records the expiries; decide judges the count
            assert.equal(s.assignments.snapshot().filter((x) => x.state === 'expired').length, expired);
            assert.equal(isRetired(s), retired);
            assert.equal(s.d.queue().some((q) => q.jobId === A), !retired);
            if (retired) {
                assert.ok(s.alerts.list().some((x) => x.type === 'ci-dispatcher-degraded' && /5 runners expired unpicked/.test(x.body)));
                assert.equal(mints(s).length, 5, 'no sixth runner');
            } else {
                assert.equal(mints(s).length, 5, 'still dispatched: the fifth runner goes out');
            }
        });
    }

    test('runners minted for A but bound to a different job do NOT count: 8 of them leave A tracked', async () => {
        const s = setup({ machines: ['m4mini'] });
        s.d.onJob(rec(A), 'queued');
        for (let i = 0; i < 8; i++) await mintAndBindElsewhere(s, 500 + i);
        assert.equal(isRetired(s), false);
        assert.equal(s.d.queue().some((q) => q.jobId === A), true);
        assert.equal(mints(s).length, 8, 'each stolen runner is replaced');
    });

    test('runners bound elsewhere that then FAIL (runner-lost, job failure) still do not count: a bound job is never "unpicked"', async () => {
        const s = setup({ machines: ['m4mini'] });
        s.d.onJob(rec(A), 'queued');
        for (let i = 0; i < 7; i++) {
            await mintAndBindElsewhere(s, 700 + i);
            const mine = s.assignments.snapshot().find((x) => x.state === 'running' && x.intendedJob.id === A);
            assert.equal(s.assignments.report(mine.id, 'm4mini', { state: 'failed', reason: 'runner-lost' }).status, 'ok');
        }
        s.report('m4mini', {}, 2);
        await s.d.tick();
        assert.equal(s.assignments.snapshot().filter((x) => x.state === 'failed' && x.boundJob).length, 7, 'fixture: seven bound-then-failed runners');
        assert.equal(isRetired(s), false);
        assert.equal(s.d.queue().some((q) => q.jobId === A), true);
    });

    test('mixed: 6 bound elsewhere + 4 expired-unbound keeps A; the 5th expired-unbound retires it', async () => {
        const s = setup({ machines: ['m4mini'] });
        s.d.onJob(rec(A), 'queued');
        for (let i = 0; i < 6; i++) await mintAndBindElsewhere(s, 600 + i);
        for (let i = 0; i < 4; i++) await mintAndLetExpire(s);
        s.report('m4mini', {}, 2);
        await s.d.tick();
        assert.equal(isRetired(s), false);
        assert.equal(s.d.queue().some((q) => q.jobId === A), true);
        await mintAndLetExpire(s);        // the 5th unpicked runner for A (minted during the previous tick)
        s.report('m4mini', {}, 2);
        await s.d.tick();
        assert.equal(isRetired(s), true);
        assert.equal(s.d.queue().some((q) => q.jobId === A), false);
    });

    test('restart-expired assignments say nothing about the job and are not counted', async () => {
        const s = setup({ machines: ['m4mini'], maxMintsPerJob: 1 });
        s.d.onJob(rec(A), 'queued');
        s.report('m4mini', {}, 2);
        await s.d.tick();
        // a restart: a second assignments instance over the same state file expires the live record with reason `restart`
        const again = createAssignments({ file: s.assignments.file, github: s.gh, now: () => s.clock.t, logger: { error() {}, warn() {} } });
        assert.equal(again.load().expired, 1);
        assert.equal(again.snapshot()[0].reason, 'restart');
        const d2 = createDispatcher({
            maxMintsPerJob: 1, env: ENV_ON, store: s.store, assignments: again, alerts: s.alerts, audit: { append: (e, f) => s.auditRows.push({ event: e, ...f }) },
            watcher: { async runCycle() { return 15000; } }, reports: s.reports, logger: { log() {}, warn() {}, error() {} }, now: () => s.clock.t,
        });
        d2.onJob(rec(A), 'queued');
        s.clock.t += 1000;
        await d2.tick();
        assert.equal(isRetired(s), false);
    });

    test('the 24 h age bound is unchanged', async () => {
        const s = setup({ machines: ['m4mini'], maxTrackedMs: 60 * 60 * 1000 });
        s.d.onJob(rec(A), 'queued');
        await s.d.tick();
        s.clock.t += 61 * 60 * 1000;
        await s.d.tick();
        assert.equal(s.d.queue().length, 0);
        assert.ok(s.auditRows.some((r) => r.event === 'expire' && /tracked over 1 h/.test(r.reason)));
    });
});
