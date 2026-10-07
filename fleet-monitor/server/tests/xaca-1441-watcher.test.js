//
//  xaca-1441-watcher.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/** XACA-1441-003 -- lib/ci-dispatch-watcher.js against a fake client and clock. NO network, NO real timers. */

const { test, describe } = require('node:test');
const assert = require('node:assert/strict');

const { createWatcher, BUSY_INTERVAL_MS, IDLE_INTERVAL_MS } = require('../lib/ci-dispatch-watcher');

const T0 = Date.UTC(2026, 9, 6, 12, 0, 0);
const REPO = 'acme/widgets';

/** Fake github: world = { queued:[run], in_progress:[run], jobs:{runId:[job]} }; a 304 when the body is unchanged. */
function makeWorld() {
    const world = { queued: [], in_progress: [], jobs: {}, calls: [], rate: { mode: 'normal', resumeAt: null }, seen: new Map(), throwNext: null, failJobs: {} };
    world.github = {
        getRateState: () => ({ ...world.rate }),
        async conditionalGet({ owner, repo, path, purpose }) {
            world.calls.push({ owner, repo, path, purpose });
            if (world.throwNext) { const e = world.throwNext; world.throwNext = null; throw e; }
            let data;
            let m;
            // Per-run job-fetch failure (e.g. a deleted run answers 404/410), persistent until cleared.
            if ((m = /\/actions\/runs\/(\d+)\/jobs/.exec(path)) && world.failJobs[m[1]]) throw world.failJobs[m[1]];
            if ((m = /\/actions\/runs\?status=(\w+)/.exec(path))) data = { workflow_runs: world[m[1]] };
            else if ((m = /\/actions\/runs\/(\d+)\/jobs/.exec(path))) data = { jobs: world.jobs[m[1]] || [] };
            else throw new Error(`unexpected path ${path}`);
            const body = JSON.stringify(data);
            const notModified = world.seen.get(path) === body;
            world.seen.set(path, body);
            return { status: notModified ? 304 : 200, notModified, data, etag: 'x' };
        },
    };
    return world;
}

function makeClock() {
    const c = { t: T0, timers: new Map(), id: 0, cleared: [] };
    c.now = () => c.t;
    c.setTimer = (fn, ms) => { const h = ++c.id; c.timers.set(h, { fn, ms }); return h; };
    c.clearTimer = (h) => { c.cleared.push(h); c.timers.delete(h); };
    return c;
}

const run = (id, extra = {}) => ({
    id, run_attempt: 1, event: 'push', updated_at: '2026-10-06T12:00:00Z',
    repository: { full_name: REPO }, head_repository: { full_name: REPO }, ...extra,
});
const job = (id, extra = {}) => ({
    id, name: `job-${id}`, status: 'queued', conclusion: null, runner_name: null,
    labels: ['self-hosted', 'Linux', 'ARM64', 'fleet-pool'], created_at: '2026-10-06T11:59:00Z',
    started_at: '2026-10-06T11:59:00Z', run_attempt: 1, ...extra,
});

function setup(over = {}) {
    const world = makeWorld();
    const clock = makeClock();
    const events = [];
    const w = createWatcher({
        github: world.github, allowlist: [REPO], now: clock.now,
        setTimer: clock.setTimer, clearTimer: clock.clearTimer,
        onJob: (rec, change) => events.push({ change, rec }), ...over,
    });
    return { world, clock, events, w };
}

const jobCalls = (world) => world.calls.filter((c) => /\/jobs\?/.test(c.path));

describe('cadence', () => {
    test('idle repo polls every 60 s, busy every 15 s', async () => {
        const { world, w } = setup();
        assert.equal(await w.runCycle(), IDLE_INTERVAL_MS);
        world.queued = [run(1)]; world.jobs[1] = [job(11)];
        assert.equal(await w.runCycle(), BUSY_INTERVAL_MS);
        world.queued = []; world.jobs[1] = [job(11, { status: 'completed', conclusion: 'success' })];
        assert.equal(await w.runCycle(), IDLE_INTERVAL_MS); // completion observed, nothing open
    });

    test('rate "slow" forces 60 s even when busy', async () => {
        const { world, w } = setup();
        world.queued = [run(1)]; world.jobs[1] = [job(11)];
        world.rate = { mode: 'slow', resumeAt: null };
        assert.equal(await w.runCycle(), IDLE_INTERVAL_MS);
    });

    test('rate "suspended" makes no calls and waits until resumeAt', async () => {
        const { world, clock, w } = setup();
        world.rate = { mode: 'suspended', resumeAt: clock.t + 600000 };
        assert.equal(await w.runCycle(), 600000);
        assert.equal(world.calls.length, 0);
        world.rate = { mode: 'blocked', resumeAt: clock.t + 42000 };
        assert.equal(await w.runCycle(), 42000);
        assert.equal(world.calls.length, 0);
    });

    test('start schedules a cycle, reschedules from its result, stop cancels', async () => {
        const { clock, world, w } = setup();
        world.queued = [run(1)]; world.jobs[1] = [job(11)];
        w.start();
        assert.equal(clock.timers.size, 1);
        const [[h, t]] = [...clock.timers];
        assert.equal(t.ms, 0);
        clock.timers.delete(h);
        await t.fn();
        assert.equal(clock.timers.size, 1);
        assert.equal([...clock.timers.values()][0].ms, BUSY_INTERVAL_MS);
        w.stop();
        assert.equal(clock.timers.size, 0);
        assert.equal(clock.cleared.length, 1);
        assert.equal(w.snapshot().running, false);
    });

    test('a stop() during a cycle does not reschedule', async () => {
        const { clock, w } = setup();
        w.start();
        const [[h, t]] = [...clock.timers];
        clock.timers.delete(h);
        const p = t.fn();
        w.stop();
        await p;
        assert.equal(clock.timers.size, 0);
    });
});

describe('call budget', () => {
    test('lists queued + in_progress per repo with the watcher purpose', async () => {
        const { world, w } = setup();
        await w.runCycle();
        assert.deepEqual(world.calls.map((c) => c.path), [
            `/repos/${REPO}/actions/runs?status=queued&per_page=100`,
            `/repos/${REPO}/actions/runs?status=in_progress&per_page=100`,
        ]);
        assert.ok(world.calls.every((c) => c.purpose === 'watcher'));
    });

    test('jobs are fetched only for new or changed runs; unchanged lists (304) cost no jobs call', async () => {
        const { world, w } = setup();
        world.queued = [run(1)]; world.jobs[1] = [job(11)];
        await w.runCycle();
        assert.equal(jobCalls(world).length, 1);
        assert.match(jobCalls(world)[0].path, /runs\/1\/jobs\?filter=latest&per_page=100$/);
        await w.runCycle();
        await w.runCycle();
        assert.equal(jobCalls(world).length, 1, 'unchanged updated_at => no jobs call');
        world.queued = [run(1, { updated_at: '2026-10-06T12:01:00Z' })];
        await w.runCycle();
        assert.equal(jobCalls(world).length, 2);
    });

    test('a steady cycle spends exactly the two list calls', async () => {
        const { world, w } = setup();
        world.queued = [run(1)]; world.jobs[1] = [job(11)];
        await w.runCycle();
        const before = world.calls.length;
        await w.runCycle();
        assert.equal(world.calls.length - before, 2);
        assert.equal(w.snapshot().lastCycle.calls, 2);
    });

    test('a client error on one repo is logged, not thrown, and the cycle still reschedules', async () => {
        const logs = [];
        const { world, w } = setup({ log: (l, m) => logs.push(m) });
        world.throwNext = Object.assign(new Error('GET runs failed: HTTP 500'), { code: 'HTTP' });
        const d = await w.runCycle();
        assert.equal(d, IDLE_INTERVAL_MS);
        assert.equal(w.snapshot().lastCycle.ok, false);
        assert.ok(logs.some((m) => /HTTP/.test(m)));
    });
});

describe('lifecycle events', () => {
    test('queued -> pickup -> in_progress -> completed, in order, once each', async () => {
        const { world, clock, events, w } = setup();
        world.queued = [run(1)]; world.jobs[1] = [job(11)];
        await w.runCycle();
        await w.runCycle(); // nothing new
        assert.deepEqual(events.map((e) => e.change), ['queued']);

        clock.t += 15000;
        world.jobs[1] = [job(11, { runner_name: 'jit-abc' })];
        world.queued = [run(1, { updated_at: '2026-10-06T12:00:15Z' })];
        await w.runCycle();

        clock.t += 15000;
        world.queued = []; world.in_progress = [run(1, { updated_at: '2026-10-06T12:00:30Z' })];
        world.jobs[1] = [job(11, { runner_name: 'jit-abc', status: 'in_progress' })];
        await w.runCycle();

        clock.t += 15000;
        world.in_progress = [];
        world.jobs[1] = [job(11, { runner_name: 'jit-abc', status: 'completed', conclusion: 'success', completed_at: '2026-10-06T12:00:44Z' })];
        await w.runCycle(); // run left the lists; the watcher looks once more and sees the completion

        assert.deepEqual(events.map((e) => e.change), ['queued', 'pickup', 'in_progress', 'completed']);
        const done = events[3].rec;
        assert.equal(done.status, 'completed');
        assert.equal(done.conclusion, 'success');
        assert.equal(done.runnerName, 'jit-abc');
        assert.equal(done.completedAt, '2026-10-06T12:00:44Z');
        assert.equal(done.key, `${REPO}#11#1`);
    });

    test('inProgressAt is the observation time, never started_at (A6)', async () => {
        const { world, clock, events, w } = setup();
        // started_at == created_at on a job that is still queued, as GitHub really reports
        world.queued = [run(1)]; world.jobs[1] = [job(11, { started_at: '2026-10-06T11:59:00Z', created_at: '2026-10-06T11:59:00Z' })];
        await w.runCycle();
        assert.equal(events[0].rec.inProgressAt, null);

        clock.t += 30000;
        world.queued = []; world.in_progress = [run(1, { updated_at: '2026-10-06T12:00:30Z' })];
        world.jobs[1] = [job(11, { status: 'in_progress', runner_name: 'r1', started_at: '2026-10-06T11:59:00Z' })];
        await w.runCycle();
        const ip = events.find((e) => e.change === 'in_progress').rec;
        assert.equal(ip.inProgressAt, new Date(T0 + 30000).toISOString());
        assert.notEqual(ip.inProgressAt, '2026-10-06T11:59:00Z');
    });

    test('record carries the full inter-module shape, including fork-rule fields', async () => {
        const { world, events, w } = setup();
        world.queued = [run(7, { event: 'pull_request', head_repository: { full_name: 'forker/widgets' } })];
        world.jobs[7] = [job(70)];
        await w.runCycle();
        const r = events[0].rec;
        assert.deepEqual(Reflect.ownKeys(r).sort(), [
            'completedAt', 'conclusion', 'createdAt', 'firstSeenAt', 'inProgressAt', 'jobId', 'key', 'labels', 'name',
            'owner', 'repo', 'run', 'runAttempt', 'runId', 'runnerName', 'status',
        ]);
        assert.equal(r.owner, 'acme'); assert.equal(r.repo, 'widgets');
        assert.equal(r.runId, 7); assert.equal(r.jobId, 70);
        assert.deepEqual(r.run, { event: 'pull_request', repoFullName: REPO, headRepoFullName: 'forker/widgets' });
        assert.equal(r.firstSeenAt, new Date(T0).toISOString());
    });

    test('a missing head_repository is reported as null, not filtered', async () => {
        const { world, events, w } = setup();
        const r = run(8); delete r.head_repository;
        world.queued = [r]; world.jobs[8] = [job(80)];
        await w.runCycle();
        assert.equal(events.length, 1);
        assert.equal(events[0].rec.run.headRepoFullName, null);
    });

    test('a job first seen already in_progress emits seen, pickup, in_progress', async () => {
        const { world, events, w } = setup();
        world.in_progress = [run(2)];
        world.jobs[2] = [job(21, { status: 'in_progress', runner_name: 'r2' })];
        await w.runCycle();
        assert.deepEqual(events.map((e) => e.change), ['seen', 'pickup', 'in_progress']);
        assert.ok(events[2].rec.inProgressAt);
    });

    test('emitted records are copies; mutating one cannot corrupt the watcher', async () => {
        const { world, events, w } = setup();
        world.queued = [run(1)]; world.jobs[1] = [job(11)];
        await w.runCycle();
        events[0].rec.labels.push('evil'); events[0].rec.run.event = 'x';
        world.jobs[1] = [job(11, { runner_name: 'r' })];
        world.queued = [run(1, { updated_at: '2026-10-06T12:00:15Z' })];
        await w.runCycle();
        assert.deepEqual(events[1].rec.labels, ['self-hosted', 'Linux', 'ARM64', 'fleet-pool']);
        assert.equal(events[1].rec.run.event, 'push');
    });

    test('an onJob that throws does not stop the watcher', async () => {
        const { world, w } = setup({ onJob: () => { throw new Error('boom'); }, log: () => {} });
        world.queued = [run(1)]; world.jobs[1] = [job(11), job(12)];
        await w.runCycle();
        assert.equal(w.snapshot().jobs.queued, 2);
    });
});

describe('dedupe', () => {
    test('same job across cycles emits once; a re-run (runAttempt 2) is a new key', async () => {
        const { world, events, w } = setup();
        world.queued = [run(1)]; world.jobs[1] = [job(11)];
        await w.runCycle(); await w.runCycle();
        world.queued = [run(1, { run_attempt: 2, updated_at: '2026-10-06T12:05:00Z' })];
        world.jobs[1] = [job(11, { run_attempt: 2 })];
        await w.runCycle();
        const keys = events.filter((e) => e.change === 'queued').map((e) => e.rec.key);
        assert.deepEqual(keys, [`${REPO}#11#1`, `${REPO}#11#2`]);
    });

    test('a completed job re-appearing does not re-emit', async () => {
        const { world, events, w } = setup();
        world.queued = [run(1)];
        world.jobs[1] = [job(11, { status: 'completed', conclusion: 'failure' })];
        await w.runCycle();
        const n = events.length;
        world.queued = [run(1, { updated_at: '2026-10-06T12:09:00Z' })];
        await w.runCycle();
        assert.equal(events.length, n);
    });
});

describe('memory bound', () => {
    test('completed jobs and their runs are pruned after retention', async () => {
        const { world, clock, w } = setup({ completedRetentionMs: 1000 });
        world.queued = [run(1)];
        world.jobs[1] = [job(11, { status: 'completed', conclusion: 'success' })];
        await w.runCycle();
        assert.equal(w.snapshot().jobs.tracked, 1);
        world.queued = [];
        clock.t += 5000;
        await w.runCycle();
        const s = w.snapshot();
        assert.equal(s.jobs.tracked, 0);
        assert.equal(s.runsTracked, 0);
    });

    test('hard cap evicts the oldest completed jobs first and never an open one', async () => {
        const { world, clock, w } = setup({ maxTrackedJobs: 3 });
        world.queued = [run(1)];
        world.jobs[1] = [job(1), ...[2, 3, 4, 5].map((i) => job(i, { status: 'completed', conclusion: 'success' }))];
        await w.runCycle();
        clock.t += 1000;
        await w.runCycle();
        const s = w.snapshot();
        assert.equal(s.jobs.tracked, 3);
        assert.equal(s.jobs.queued, 1);
    });

    test('an open job that disappears is closed (vanished), never dropped silently, then aged out', async () => {
        // PR #1083: a silent drop left the dispatcher holding the job as demand forever.
        const { world, clock, events, w } = setup();
        world.queued = [run(1)]; world.jobs[1] = [job(11)];
        await w.runCycle();
        world.queued = [];
        world.jobs[1] = []; // the run no longer reports the job and it never completes
        clock.t += 25 * 3600 * 1000;
        await w.runCycle();
        const done = events.filter((e) => e.change === 'completed' && e.rec.jobId === 11);
        assert.equal(done.length, 1);
        assert.equal(done[0].rec.conclusion, 'vanished');
        assert.equal(w.snapshot().jobs.queued, 0);
        clock.t += 2 * 3600 * 1000; // past the completed-retention window
        await w.runCycle();
        assert.equal(w.snapshot().jobs.tracked, 0);
    });
});

describe('snapshot and config', () => {
    test('snapshot reports counts, last cycle and rate mode with no secrets', async () => {
        const { world, w } = setup();
        world.queued = [run(1)]; world.jobs[1] = [job(11), job(12, { status: 'in_progress', runner_name: 'r' })];
        await w.runCycle();
        const s = w.snapshot();
        assert.deepEqual(s.jobs, { queued: 1, inProgress: 1, completed: 0, tracked: 2 });
        assert.equal(s.lastCycle.ok, true);
        assert.equal(s.lastCycle.nextDelayMs, BUSY_INTERVAL_MS);
        assert.equal(s.rateMode, 'normal');
        assert.deepEqual(s.repos, [REPO]);
        assert.ok(!/token|secret|credential/i.test(JSON.stringify(s)));
    });

    test('invalid allowlist entries are ignored; missing client or onJob throws', () => {
        const w = createWatcher({ github: makeWorld().github, allowlist: ['nope', REPO, null, '../x/y'], onJob: () => {}, log: () => {} });
        assert.deepEqual(w.snapshot().repos, [REPO]);
        assert.throws(() => createWatcher({ allowlist: [REPO], onJob: () => {} }), TypeError);
        assert.throws(() => createWatcher({ github: makeWorld().github, allowlist: [REPO] }), TypeError);
    });

    test('RATE_LIMITED from one repo stops the remaining repos this cycle', async () => {
        const world = makeWorld();
        const w = createWatcher({
            github: world.github, allowlist: ['a/one', 'a/two'], now: () => T0, onJob: () => {}, log: () => {},
            setTimer: () => 1, clearTimer: () => {},
        });
        world.throwNext = Object.assign(new Error('limited'), { code: 'RATE_LIMITED' });
        await w.runCycle();
        assert.equal(world.calls.length, 1);
    });
});

// XACA-1441 PR #1083 review (tester BLOCKING): every way an open job leaves GitHub's view must end in
// a terminal event, or the dispatcher keeps it as demand and re-mints runners for it without limit.
describe('vanished jobs end in a terminal event (PR #1083)', () => {
    const { GithubError } = require('../lib/ci-dispatch-github');
    const httpErr = (status) => new GithubError('HTTP', `GET jobs failed: HTTP ${status}`, { status });
    const terminal = (events, jobId) => events.filter((e) => e.change === 'completed' && e.rec.jobId === jobId);

    // Each row: mutate the world after job 11 (run 1, attempt 1) is queued; `advanceMs` then one cycle.
    const ROWS = [
        ['run deleted: its jobs answer 404', (wd) => { wd.queued = []; wd.failJobs[1] = httpErr(404); }, 0, 'vanished'],
        ['run deleted: its jobs answer 410', (wd) => { wd.queued = []; wd.failJobs[1] = httpErr(410); }, 0, 'vanished'],
        ['finished run no longer lists the job (fresh 200)', (wd) => { wd.queued = []; wd.jobs[1] = []; }, 0, 'vanished'],
        ['cancel + re-run: attempt 2 supersedes the attempt-1 job', (wd) => {
            wd.queued = [run(1, { run_attempt: 2, updated_at: '2026-10-06T12:05:00Z' })];
            wd.jobs[1] = [job(31, { run_attempt: 2 })];
        }, 0, 'vanished'],
        ['run left the lists, jobs body unchanged (304): pruned after 24 h, not dropped silently', (wd) => { wd.queued = []; }, 25 * 3600 * 1000, 'vanished'],
        // controls: these must NOT vanish the job
        ['control: still-listed run, job missing from the first page (pagination)', (wd) => {
            wd.queued = [run(1, { updated_at: '2026-10-06T12:05:00Z' })]; wd.jobs[1] = [job(12)];
        }, 0, null],
        ['control: run left the lists, jobs body unchanged (304), within 24 h', (wd) => { wd.queued = []; }, 60 * 1000, null],
        ['control: still-listed, unchanged run keeps its job alive past 24 h', () => {}, 25 * 3600 * 1000, null],
    ];

    for (const [name, mutate, advanceMs, conclusion] of ROWS) {
        test(name, async () => {
            const { world, clock, events, w } = setup();
            world.queued = [run(1)]; world.jobs[1] = [job(11)];
            await w.runCycle();
            assert.equal(events.filter((e) => e.rec.jobId === 11 && e.change === 'queued').length, 1);
            mutate(world);
            clock.t += advanceMs;
            await w.runCycle();
            const done = terminal(events, 11);
            if (conclusion === null) {
                assert.equal(done.length, 0, 'a live job must not be vanished');
            } else {
                assert.equal(done.length, 1, 'exactly one terminal event');
                assert.equal(done[0].rec.conclusion, conclusion);
                assert.equal(done[0].rec.status, 'completed');
            }
        });
    }

    test('a 404 on one gone run does not hide the completion of another gone run', async () => {
        const { world, events, w } = setup();
        world.queued = [run(1), run(2)]; world.jobs[1] = [job(11)]; world.jobs[2] = [job(21)];
        await w.runCycle();
        world.queued = [];
        world.failJobs[1] = httpErr(404);
        world.jobs[2] = [job(21, { status: 'completed', conclusion: 'success' })];
        await w.runCycle();
        assert.equal(terminal(events, 11)[0].rec.conclusion, 'vanished');
        assert.equal(terminal(events, 21)[0].rec.conclusion, 'success');
    });

    test('a rate limit on a gone run is not a vanish (and still propagates to the cycle)', async () => {
        const { world, events, w } = setup();
        world.queued = [run(1)]; world.jobs[1] = [job(11)];
        await w.runCycle();
        world.queued = [];
        world.failJobs[1] = Object.assign(new Error('limited'), { code: 'RATE_LIMITED' });
        await w.runCycle();
        assert.equal(terminal(events, 11).length, 0);
    });

    test('a 5xx on a gone run is retried next cycle, not a vanish', async () => {
        const { world, events, w } = setup();
        world.queued = [run(1)]; world.jobs[1] = [job(11)];
        await w.runCycle();
        world.queued = [];
        world.failJobs[1] = httpErr(502);
        await w.runCycle();
        assert.equal(terminal(events, 11).length, 0);
        delete world.failJobs[1];
        world.jobs[1] = [job(11, { status: 'completed', conclusion: 'success' })];
        await w.runCycle();
        assert.equal(terminal(events, 11)[0].rec.conclusion, 'success');
    });
});
