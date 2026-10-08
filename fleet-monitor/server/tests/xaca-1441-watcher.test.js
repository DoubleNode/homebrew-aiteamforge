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
            'branch', 'completedAt', 'conclusion', 'createdAt', 'firstSeenAt', 'inProgressAt', 'jobId', 'key', 'labels', 'name',
            'owner', 'repo', 'run', 'runAttempt', 'runId', 'runnerName', 'status', 'url', 'workflow',
        ]);
        assert.equal(r.owner, 'acme'); assert.equal(r.repo, 'widgets');
        assert.equal(r.runId, 7); assert.equal(r.jobId, 70);
        assert.deepEqual(r.run, { event: 'pull_request', repoFullName: REPO, headRepoFullName: 'forker/widgets' });
        assert.equal(r.firstSeenAt, new Date(T0).toISOString());
    });

    test('XACA-1444: branch, workflow and job url are carried from the run/job; null when absent', async () => {
        const { world, events, w } = setup();
        world.queued = [run(9, { head_branch: 'feature/x', name: 'CI' }), run(10)];
        world.jobs[9] = [job(90, { html_url: 'https://github.com/acme/widgets/actions/runs/9/job/90' })];
        world.jobs[10] = [job(100)];
        await w.runCycle();
        const a = events.find((e) => e.rec.jobId === 90).rec;
        assert.equal(a.branch, 'feature/x'); assert.equal(a.workflow, 'CI');
        assert.equal(a.url, 'https://github.com/acme/widgets/actions/runs/9/job/90');
        const b = events.find((e) => e.rec.jobId === 100).rec;
        assert.equal(b.branch, null); assert.equal(b.workflow, null); assert.equal(b.url, null);
    });

    test('XACA-1444: hostile / oversize branch, workflow and url are capped and control chars stripped', async () => {
        const { world, events, w } = setup();
        world.queued = [run(11, { head_branch: 'b'.repeat(5000), name: 'w\u0000\n<script>' })];
        world.jobs[11] = [job(110, { html_url: 'https://x/' + 'u'.repeat(5000) })];
        await w.runCycle();
        const r = events[0].rec;
        assert.equal(r.branch.length, 200);
        assert.equal(r.workflow, 'w  <script>');
        assert.equal(r.url.length, 500);
        world.queued = [run(12, { head_branch: { evil: 1 }, name: 42 })];
        world.jobs[12] = [job(120, { html_url: 7 })];
        await w.runCycle();
        const q = events.find((e) => e.rec.jobId === 120).rec;
        assert.equal(q.branch, null); assert.equal(q.workflow, null); assert.equal(q.url, null);
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

// ---------------------------------------------------------------------------
// XACA-1441-032 pagination and XACA-1441-029 live allowlist
// ---------------------------------------------------------------------------

/**
 * Fake github that honours `page` and `per_page`. world.runs = {queued:[...], in_progress:[...]},
 * world.jobs[runId] = [...]. A page whose body equals the previous body for the same path answers 304.
 */
function makePagedWorld() {
    const world = { queued: [], in_progress: [], jobs: {}, calls: [], seen: new Map(), rate: { mode: 'normal', resumeAt: null } };
    world.github = {
        getRateState: () => ({ ...world.rate }),
        async conditionalGet({ owner, repo, path }) {
            world.calls.push({ owner, repo, path });
            const page = Number((/[?&]page=(\d+)/.exec(path) || [null, 1])[1]);
            const per = Number((/per_page=(\d+)/.exec(path) || [null, 30])[1]);
            let all; let key; let m;
            if ((m = /\/actions\/runs\?status=(\w+)/.exec(path))) { all = world[m[1]]; key = 'workflow_runs'; }
            else if ((m = /\/actions\/runs\/(\d+)\/jobs/.exec(path))) { all = world.jobs[m[1]] || []; key = 'jobs'; }
            else throw new Error(`unexpected path ${path}`);
            const data = { [key]: all.slice((page - 1) * per, page * per) };
            const body = JSON.stringify(data);
            const notModified = world.seen.get(path) === body;
            world.seen.set(path, body);
            return { status: notModified ? 304 : 200, notModified, data, etag: 'x' };
        },
    };
    return world;
}
const many = (n, make, from = 1) => Array.from({ length: n }, (_, i) => make(from + i));
const pagedSetup = (over = {}) => {
    const world = makePagedWorld();
    const events = [];
    const logs = [];
    const clock = { t: T0 };
    const w = createWatcher({
        github: world.github, allowlist: [REPO], now: () => clock.t,
        onJob: (rec, change) => events.push({ change, rec }), log: (l, m) => logs.push([l, m]), ...over,
    });
    return { world, events, logs, w, clock };
};
const pagesOf = (world, re) => world.calls.filter((c) => re.test(c.path)).map((c) => Number((/[?&]page=(\d+)/.exec(c.path) || [null, 1])[1]));

describe('pagination (032)', () => {
    test('a job list of 100/100/37 is read in full: 237 jobs observed, pages 1-3 requested, no page 4', async () => {
        const { world, events, w } = pagedSetup();
        world.queued = [run(1)];
        world.jobs[1] = many(237, (id) => job(id));
        await w.runCycle();
        assert.equal(events.filter((e) => e.change === 'queued').length, 237);
        assert.deepEqual(pagesOf(world, /runs\/1\/jobs/), [1, 2, 3]);
        assert.equal(world.calls.filter((c) => /runs\/1\/jobs/.test(c.path)).every((c) => /per_page=100/.test(c.path)), true);
        assert.match(world.calls.find((c) => /page=2/.test(c.path)).path, /jobs\?filter=latest&per_page=100&page=2$/);
    });

    test('a run list of 100/100/37 is read in full: every run reaches its job fetch', async () => {
        const { world, events, w } = pagedSetup();
        world.queued = many(237, (id) => run(id));
        for (const r of world.queued) world.jobs[r.id] = [job(r.id * 1000)];
        await w.runCycle();
        assert.deepEqual(pagesOf(world, /actions\/runs\?status=queued/), [1, 2, 3]);
        assert.deepEqual(pagesOf(world, /actions\/runs\?status=in_progress/), [1], 'an empty list is one call');
        assert.equal(events.filter((e) => e.change === 'queued').length, 237);
        assert.ok(events.some((e) => e.rec.jobId === 237000), 'a job from the last page of runs');
    });

    test('an exact multiple of the page size costs one extra, empty page and stops there', async () => {
        const { world, events, w } = pagedSetup();
        world.queued = [run(1)];
        world.jobs[1] = many(200, (id) => job(id));
        await w.runCycle();
        assert.equal(events.length, 200);
        assert.deepEqual(pagesOf(world, /runs\/1\/jobs/), [1, 2, 3]);
    });

    test('the cap stops at 10 pages and logs a warning (jobs list)', async () => {
        const { world, events, logs, w } = pagedSetup();
        world.queued = [run(1)];
        world.jobs[1] = many(1500, (id) => job(id));
        await w.runCycle();
        assert.deepEqual(pagesOf(world, /runs\/1\/jobs/), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
        assert.equal(events.length, 1000);
        const warns = logs.filter(([l, m]) => l === 'warn' && /10-page cap/.test(m));
        assert.equal(warns.length, 1);
        assert.match(warns[0][1], /jobs list/);
    });

    test('the cap stops at 10 pages and logs a warning (runs list)', async () => {
        const { world, logs, w } = pagedSetup();
        world.queued = many(1100, (id) => run(id));
        for (const r of world.queued) world.jobs[r.id] = [];
        await w.runCycle();
        assert.deepEqual(pagesOf(world, /actions\/runs\?status=queued/), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
        assert.equal(logs.filter(([l, m]) => l === 'warn' && /workflow_runs list hit the 10-page cap/.test(m)).length, 1);
    });

    test('under the cap there is no warning', async () => {
        const { world, logs, w } = pagedSetup();
        world.queued = [run(1)];
        world.jobs[1] = many(150, (id) => job(id));
        await w.runCycle();
        assert.equal(logs.filter(([l]) => l === 'warn').length, 0);
    });

    describe('vanish needs every page fresh', () => {
        async function twoPageRun() {
            const x = pagedSetup();
            x.world.queued = [run(1)];
            x.world.jobs[1] = many(150, (id) => job(id));
            await x.w.runCycle();
            assert.equal(x.events.filter((e) => e.change === 'queued').length, 150);
            x.world.queued = [];                       // the run finished: it leaves the lists
            x.events.length = 0;
            return x;
        }
        const vanished = (events) => events.filter((e) => e.change === 'completed' && e.rec.conclusion === 'vanished').map((e) => e.rec.jobId);

        test('every page a fresh 200 (the list shifted): the job that is gone vanishes', async () => {
            const x = await twoPageRun();
            x.world.jobs[1] = x.world.jobs[1].filter((j) => j.id !== 1);   // removes the first job: page 1 AND page 2 change
            await x.w.runCycle();
            assert.deepEqual(vanished(x.events), [1]);
        });

        test('one page answers 304 (only the last job is gone): NOTHING vanishes', async () => {
            const x = await twoPageRun();
            x.world.jobs[1] = x.world.jobs[1].filter((j) => j.id !== 150); // page 2 changes, page 1 replays as 304
            await x.w.runCycle();
            assert.deepEqual(vanished(x.events), []);
            assert.deepEqual(pagesOf(x.world, /runs\/1\/jobs/).slice(-2), [1, 2]);
        });

        test('all pages 304 (nothing changed): nothing vanishes', async () => {
            const x = await twoPageRun();
            await x.w.runCycle();
            assert.deepEqual(vanished(x.events), []);
        });

        test('a capped job list never vanishes anything, even when every page is fresh', async () => {
            const x = pagedSetup();
            x.world.queued = [run(1)];
            x.world.jobs[1] = many(1200, (id) => job(id));
            await x.w.runCycle();
            x.world.queued = [];
            x.events.length = 0;
            x.world.jobs[1] = x.world.jobs[1].filter((j) => j.id !== 1);   // shifts every page: all 200, but capped
            await x.w.runCycle();
            assert.deepEqual(vanished(x.events), []);
        });

        test('a single-page list keeps the old behaviour (a fresh 200 without the job vanishes it)', async () => {
            const x = pagedSetup();
            x.world.queued = [run(1)];
            x.world.jobs[1] = [job(11), job(12)];
            await x.w.runCycle();
            x.world.queued = [];
            x.events.length = 0;
            x.world.jobs[1] = [job(11)];
            await x.w.runCycle();
            assert.deepEqual(vanished(x.events), [12]);
        });
    });
});

describe('live allowlist (029)', () => {
    const OTHER = 'acme/gadgets';
    const reposCalled = (world) => [...new Set(world.calls.map((c) => `${c.owner}/${c.repo}`))].sort();

    test('an added repo is polled on the next cycle, and a removed one is no longer polled, with no restart', async () => {
        let list = [REPO];
        const { world, w } = pagedSetup({ allowlist: undefined, getAllowlist: () => list });
        await w.runCycle();
        assert.deepEqual(reposCalled(world), [REPO]);
        world.calls.length = 0;
        list = [REPO, OTHER];
        await w.runCycle();
        assert.deepEqual(reposCalled(world), [OTHER, REPO].sort());
        assert.deepEqual(w.snapshot().repos, [REPO, OTHER]);
        world.calls.length = 0;
        list = [OTHER];
        await w.runCycle();
        assert.deepEqual(reposCalled(world), [OTHER]);
        assert.deepEqual(w.snapshot().repos, [OTHER]);
    });

    test('a removed repo\'s open jobs are completed as vanished so no consumer keeps them as demand', async () => {
        let list = [REPO];
        const { world, events, w } = pagedSetup({ allowlist: undefined, getAllowlist: () => list });
        world.queued = [run(1)];
        world.jobs[1] = [job(11)];
        await w.runCycle();
        assert.equal(events.filter((e) => e.change === 'queued').length, 1);
        list = [];
        await w.runCycle();
        const done = events.filter((e) => e.change === 'completed');
        assert.equal(done.length, 1);
        assert.equal(done[0].rec.conclusion, 'vanished');
        assert.equal(done[0].rec.jobId, 11);
    });

    // PR #1086 review BLOCKING: a removal-vanish poisoned the terminal dedupe, so a repo re-added within
    // the retention window had its still-live jobs ignored as "already terminal": never re-emitted, never
    // tracked, no alert. Rows: [name, job status while removed, cycle between remove and re-add, re-add delay].
    const READD_ROWS = [
        ['queued job, cycle between, re-added within retention', 'queued', true, 60 * 1000],
        ['in_progress job, cycle between, re-added within retention', 'in_progress', true, 60 * 1000],
        ['queued job, NO cycle between remove and re-add', 'queued', false, 0],
        ['queued job, cycle between, re-added past retention', 'queued', true, 2 * 3600 * 1000],
        ['in_progress job, cycle between, re-added past retention', 'in_progress', true, 2 * 3600 * 1000],
    ];
    for (const [name, status, cycleBetween, delayMs] of READD_ROWS) {
        test(`allowlist remove + re-add: ${name} is seen again`, async () => {
            let list = [REPO];
            const { world, clock, events, w } = pagedSetup({ allowlist: undefined, getAllowlist: () => list });
            const runner = status === 'in_progress' ? { runner_name: 'fcp-x-1' } : {};
            world.queued = status === 'queued' ? [run(1)] : [];
            world.in_progress = status === 'in_progress' ? [run(1)] : [];
            world.jobs[1] = [job(11, { status, ...runner })];
            await w.runCycle();
            list = [];
            if (cycleBetween) await w.runCycle();
            clock.t += delayMs;
            list = [REPO];
            const before = events.length;
            await w.runCycle();
            const after = events.slice(before).filter((e) => e.rec.jobId === 11).map((e) => e.change);
            if (cycleBetween) {
                // seen afresh: first sighting again, never silently ignored
                assert.ok(after.includes(status === 'queued' ? 'queued' : 'seen'), `${name}: got [${after}]`);
            } else {
                // nothing changed from the watcher's point of view: no vanish was emitted at all
                assert.equal(events.filter((e) => e.change === 'completed' && e.rec.jobId === 11).length, 0);
            }
            // and the job's REAL completion is still observed afterwards
            world.queued = []; world.in_progress = [];
            world.jobs[1] = [job(11, { status: 'completed', conclusion: 'success', ...runner })];
            await w.runCycle();
            const real = events.filter((e) => e.change === 'completed' && e.rec.jobId === 11 && e.rec.conclusion === 'success');
            assert.equal(real.length, 1, `${name}: real completion observed`);
        });
    }

    test('allowlist remove during a rate-suspended cycle (no prune runs) + re-add: the unchanged run is re-fetched', async () => {
        // A suspended cycle returns before prune(), so only refreshRepos can forget the removed repo's
        // run entries. If it kept them, the re-added run would look unchanged and never be re-fetched.
        let list = [REPO];
        const { world, events, w } = pagedSetup({ allowlist: undefined, getAllowlist: () => list });
        world.queued = [run(1)];
        world.jobs[1] = [job(11)];
        await w.runCycle();
        world.rate = { mode: 'suspended', resumeAt: null };
        list = [];
        await w.runCycle();           // removal applied; cycle returns early, no prune
        world.rate = { mode: 'normal', resumeAt: null };
        list = [REPO];
        const before = events.length;
        await w.runCycle();
        const after = events.slice(before).filter((e) => e.rec.jobId === 11).map((e) => e.change);
        assert.ok(after.includes('queued'), `job 11 seen again after re-add, got [${after}]`);
    });

    test('boot with a getter: an invalid entry is warned about once and no "allowlist now" line is logged (PR #1086 advisory)', async () => {
        const { logs, w } = pagedSetup({ allowlist: [REPO, 'not a repo'], getAllowlist: () => [REPO, 'not a repo'] });
        await w.runCycle();
        await w.runCycle();
        assert.equal(logs.filter(([, m]) => /invalid allowlist entry/.test(m)).length, 1, 'one warning for the invalid entry');
        assert.equal(logs.filter(([, m]) => /allowlist now/.test(m)).length, 0, 'no change line at boot');
    });

    test('the getter is read every cycle, but an unchanged list is parsed (and an invalid entry warned about) once', async () => {
        let reads = 0;
        const { logs, w } = pagedSetup({ allowlist: undefined, getAllowlist: () => { reads++; return [REPO, 'not a repo']; } });
        await w.runCycle(); await w.runCycle(); await w.runCycle();
        assert.equal(reads, 3);
        assert.equal(logs.filter(([, m]) => /invalid allowlist entry/.test(m)).length, 1);
    });

    test('a throwing getter keeps the previous list and the cycle still runs', async () => {
        let boom = false;
        const { world, logs, w } = pagedSetup({ allowlist: undefined, getAllowlist: () => { if (boom) throw new Error('store gone'); return [REPO]; } });
        await w.runCycle();
        boom = true;
        world.calls.length = 0;
        await w.runCycle();
        assert.deepEqual(reposCalled(world), [REPO]);
        assert.ok(logs.some(([l, m]) => l === 'warn' && /getter threw/.test(m)));
    });

    test('backward compatible: with no getter the static allowlist is used exactly as before', async () => {
        const { world, w } = pagedSetup({ allowlist: [REPO, OTHER] });
        await w.runCycle();
        assert.deepEqual(reposCalled(world), [OTHER, REPO].sort());
    });
});
