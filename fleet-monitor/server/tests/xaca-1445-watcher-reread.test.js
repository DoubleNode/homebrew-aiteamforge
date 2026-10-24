//
//  xaca-1445-watcher-reread.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1445-031 -- the watcher must not depend on run.updated_at to see job changes.
 *
 * Measured live 2026-10-19: GitHub does NOT move a run's updated_at when a job is created, picked up,
 * started or completed while the run's status stays the same. The watcher used to read a run's jobs
 * only when updated_at moved, which hid 41 queued jobs in one shadow week (shape A: an `always()` gate
 * created ~1 s after a cancel; shape B: the run was read before its first jobs were listed) and kept
 * an already-finished job "queued" so the dispatcher minted ghost JIT runners for it.
 *
 * Every case below keeps updated_at FIXED, which is the whole point. Fake client + clock, no network.
 */

const { test, describe } = require('node:test');
const assert = require('node:assert/strict');

const {
    createWatcher, GRACE_MIN_MS, GRACE_MAX_MS, MAX_GRACE_RUNS, IN_PROGRESS_REREAD_CYCLES, BUSY_INTERVAL_MS,
} = require('../lib/ci-dispatch-watcher');
const { GithubError } = require('../lib/ci-dispatch-github');

const T0 = Date.UTC(2026, 9, 19, 23, 0, 0);
const REPO = 'acme/widgets';
const U = '2026-10-19T23:00:00Z'; // the one updated_at every run keeps

/**
 * Same fake as xaca-1441-watcher.test.js: a 304 when a path's body is unchanged; failJobs[runId] throws.
 * world.<status> answers `?status=<status>`; world.recent answers the unfiltered `?per_page=N` page.
 */
function makeWorld() {
    const world = { queued: [], in_progress: [], pending: [], requested: [], recent: [], jobs: {}, calls: [], rate: { mode: 'normal', resumeAt: null }, seen: new Map(), failJobs: {} };
    world.github = {
        getRateState: () => ({ ...world.rate }),
        async conditionalGet({ owner, repo, path, purpose }) {
            world.calls.push({ owner, repo, path, purpose });
            let data;
            let m;
            if ((m = /\/actions\/runs\/(\d+)\/jobs/.exec(path)) && world.failJobs[m[1]]) throw world.failJobs[m[1]];
            if ((m = /\/actions\/runs\?status=(\w+)/.exec(path))) data = { workflow_runs: world[m[1]] };
            else if (/\/actions\/runs\?per_page=\d+$/.test(path)) data = { workflow_runs: world.recent }; // XACA-1445-037 backstop
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

const run = (id, extra = {}) => ({
    id, run_attempt: 1, event: 'pull_request', updated_at: U, head_branch: 'feature/x', name: 'shell suite',
    repository: { full_name: REPO }, head_repository: { full_name: REPO }, ...extra,
});
const job = (id, extra = {}) => ({
    id, name: `job-${id}`, status: 'queued', conclusion: null, runner_name: null,
    labels: ['self-hosted', 'Linux', 'ARM64', 'fleet-pool'], created_at: U, run_attempt: 1, ...extra,
});
const done = (id, conclusion = 'success', extra = {}) => job(id, { status: 'completed', conclusion, runner_name: 'm1mini-linux-2', ...extra });

function setup(over = {}) {
    const world = makeWorld();
    const clock = { t: T0 };
    const events = [];
    const logs = [];
    const w = createWatcher({
        github: world.github, allowlist: [REPO], now: () => clock.t,
        setTimer: () => 1, clearTimer: () => {},
        onJob: (rec, change) => events.push({ change, rec }), log: (l, m) => logs.push([l, m]), ...over,
    });
    /** One cycle, `ms` after the previous one (default: the busy cadence). */
    const cycle = async (ms = BUSY_INTERVAL_MS) => { clock.t += ms; return w.runCycle(); };
    return { world, clock, events, logs, w, cycle };
}

const jobCalls = (world, runId) => world.calls.filter((c) => new RegExp(`/runs/${runId}/jobs\\?`).test(c.path)).length;
const changesFor = (events, jobId) => events.filter((e) => e.rec.jobId === jobId).map((e) => e.change);

describe('XACA-1445-031 F1: queued runs are re-read every cycle', () => {
    test('1. shape B: first read returns no jobs; next cycle, same updated_at, the queued job is emitted', async () => {
        const { world, events, w, cycle } = setup();
        world.queued = [run(7)];
        world.jobs[7] = [];
        await w.runCycle();
        assert.equal(events.length, 0);
        world.jobs[7] = [job(70)];               // job listed now; run.updated_at did NOT move
        await cycle();
        assert.deepEqual(changesFor(events, 70), ['queued']);
        assert.equal(events[0].rec.runId, 7);
        assert.equal(events[0].rec.branch, 'feature/x');
    });

    test('4. ghost-mint case: a job picked up and COMPLETED while the run stays queued (updated_at fixed) leaves queued', async () => {
        const { world, events, w, cycle } = setup();
        world.queued = [run(1)];
        world.jobs[1] = [job(11), job(12)];
        await w.runCycle();
        assert.equal(w.snapshot().jobs.queued, 2);
        // appicon-drift-check ran on a persistent runner; its sibling is still queued, so the run is too.
        world.jobs[1] = [done(11), job(12)];
        await cycle();
        assert.deepEqual(changesFor(events, 11), ['queued', 'pickup', 'completed']);
        const fin = events.find((e) => e.rec.jobId === 11 && e.change === 'completed').rec;
        assert.equal(fin.conclusion, 'success', 'a real completion, not a vanish');
        assert.equal(fin.runnerName, 'm1mini-linux-2');
        assert.equal(w.snapshot().jobs.queued, 1, 'only the genuinely queued sibling is still demand');
    });

    test('4b. a persistent-runner pickup (queued -> in_progress) in a still-queued run is seen next cycle', async () => {
        const { world, events, w, cycle } = setup();
        world.queued = [run(1)];
        world.jobs[1] = [job(11), job(12)];
        await w.runCycle();
        world.jobs[1] = [job(11, { status: 'in_progress', runner_name: 'm4mini-linux-1' }), job(12)];
        await cycle();
        assert.deepEqual(changesFor(events, 11), ['queued', 'pickup', 'in_progress']);
    });

    test(`in_progress-only runs: backstop re-read every ${IN_PROGRESS_REREAD_CYCLES} cycles, not every cycle`, async () => {
        const { world, events, w, cycle } = setup();
        world.in_progress = [run(2)];
        world.jobs[2] = [job(21, { status: 'in_progress', runner_name: 'r1' })];
        await w.runCycle();
        world.jobs[2] = [done(21, 'success', { runner_name: 'r1' })];
        for (let i = 1; i < IN_PROGRESS_REREAD_CYCLES; i++) await cycle();
        assert.equal(jobCalls(world, 2), 1, 'no re-read before the backstop is due');
        assert.ok(!changesFor(events, 21).includes('completed'));
        await cycle();
        assert.equal(jobCalls(world, 2), 2, 'one backstop read');
        assert.deepEqual(changesFor(events, 21), ['seen', 'pickup', 'in_progress', 'completed']);
    });
});

describe('XACA-1445-031 F2: runs that leave the lists get grace re-reads', () => {
    test('2. shape A: shards cancelled, run leaves the lists with no gate; the gate appears later and is emitted', async () => {
        const { world, events, w, cycle } = setup();
        world.in_progress = [run(5)];
        world.jobs[5] = [job(51, { status: 'in_progress', runner_name: 'r1' }), job(52, { status: 'in_progress', runner_name: 'r2' })];
        await w.runCycle();
        world.in_progress = [];                 // cancelled by a newer push: the run leaves both lists
        world.jobs[5] = [done(51, 'cancelled', { runner_name: 'r1' }), done(52, 'cancelled', { runner_name: 'r2' })];
        await cycle();
        assert.equal(w.snapshot().jobs.inProgress, 0, 'both shards observed cancelled');
        world.jobs[5] = [...world.jobs[5], job(53, { name: 'shell-suite' })]; // the always() gate, created late
        await cycle();
        assert.deepEqual(changesFor(events, 53), ['queued']);
        assert.equal(events.find((e) => e.rec.jobId === 53).rec.workflow, 'shell suite', 'run metadata carried into grace');
    });

    test('2b. shape A variant: a run we never held a job of (read empty) leaves the lists; its late job is emitted', async () => {
        const { world, events, w, cycle } = setup();
        world.queued = [run(6)];
        world.jobs[6] = [];
        await w.runCycle();
        world.queued = [];
        await cycle();
        world.jobs[6] = [job(61)];
        await cycle();
        assert.deepEqual(changesFor(events, 61), ['queued']);
    });

    test('2c. a still-listed run whose last open job closes keeps being read until the follow-on job appears', async () => {
        const { world, events, w, cycle } = setup();
        world.in_progress = [run(8)];
        world.jobs[8] = [job(81, { status: 'in_progress', runner_name: 'r1' })];
        await w.runCycle();
        world.in_progress = [run(8, { updated_at: '2026-10-19T23:00:30Z' })]; // the completion moved it once
        world.jobs[8] = [done(81, 'success', { runner_name: 'r1' })];
        await cycle();
        world.jobs[8] = [...world.jobs[8], job(82)]; // the needs: successor, created with no updated_at move
        await cycle();
        assert.deepEqual(changesFor(events, 82), ['queued']);
    });

    test('5a. a run is dropped from grace after a read >= GRACE_MIN_MS shows every job completed; then no more reads', async () => {
        const { world, w, cycle } = setup();
        world.queued = [run(9)];
        world.jobs[9] = [job(91)];
        await w.runCycle();
        world.queued = [];
        world.jobs[9] = [done(91)];
        await cycle();                            // leaves the lists: completion seen, grace starts
        assert.equal(w.snapshot().runsInGrace, 1);
        let elapsed = 0;
        while (elapsed + BUSY_INTERVAL_MS < GRACE_MIN_MS) { await cycle(); elapsed += BUSY_INTERVAL_MS; }
        assert.equal(w.snapshot().runsInGrace, 1, 'still in grace inside the min window');
        await cycle();                            // first read past the window
        assert.equal(w.snapshot().runsInGrace, 0);
        const reads = jobCalls(world, 9);
        await cycle(); await cycle(); await cycle();
        assert.equal(jobCalls(world, 9), reads, 'a dropped run costs nothing more');
    });

    test(`5b. the grace set is capped at MAX_GRACE_RUNS (${MAX_GRACE_RUNS}); the oldest are evicted`, async () => {
        const { world, logs, w, cycle } = setup();
        const N = MAX_GRACE_RUNS + 5;
        world.queued = Array.from({ length: N }, (_, i) => run(1000 + i));
        for (const r of world.queued) world.jobs[r.id] = [];
        await w.runCycle();
        world.queued = [];
        await cycle();
        assert.equal(w.snapshot().runsInGrace, MAX_GRACE_RUNS);
        assert.ok(logs.some(([l, m]) => l === 'warn' && /grace set full/.test(m)));
    });

    test('5c. a grace run that never settles (job stays open) is dropped from grace at GRACE_MAX_MS', async () => {
        const { world, w, cycle } = setup();
        world.in_progress = [run(4)];
        world.jobs[4] = [job(41, { status: 'in_progress', runner_name: 'r1' })];
        await w.runCycle();
        world.in_progress = [];                  // left the lists, job still reported open (e.g. a stuck run)
        await cycle();
        assert.equal(w.snapshot().runsInGrace, 1);
        await cycle(GRACE_MAX_MS);
        assert.equal(w.snapshot().runsInGrace, 0);
        // the open job is still followed by the pre-existing "gone run with open jobs" path
        const before = jobCalls(world, 4);
        await cycle();
        assert.equal(jobCalls(world, 4), before + 1);
    });

    test('5d. a deleted run (404) leaves grace at once', async () => {
        const { world, w, cycle } = setup();
        world.queued = [run(3)];
        world.jobs[3] = [];
        await w.runCycle();
        world.queued = [];
        await cycle();
        assert.equal(w.snapshot().runsInGrace, 1, 'precondition: the run is in grace (else this test is vacuous)');
        world.failJobs[3] = new GithubError('HTTP', 'GET jobs failed: HTTP 404', { status: 404 });
        await cycle();
        assert.equal(w.snapshot().runsInGrace, 0);
    });
});

describe('XACA-1445-031 F3: a failed jobs fetch does not mark the run as read', () => {
    test('3. fetchJobs throws once on first sighting: the (in_progress, unchanged) run is re-read next cycle', async () => {
        // in_progress on purpose: a queued run is re-read every cycle by F1 anyway, which would mask F3.
        const { world, events, w, cycle } = setup();
        world.in_progress = [run(2)];
        world.jobs[2] = [job(21, { status: 'in_progress', runner_name: 'r1' })];
        world.failJobs[2] = new GithubError('HTTP', 'GET jobs failed: HTTP 500', { status: 500 });
        await w.runCycle();
        assert.equal(w.snapshot().lastCycle.ok, false);
        assert.equal(events.length, 0);
        delete world.failJobs[2];
        await cycle();
        assert.equal(jobCalls(world, 2), 2, 're-read on the very next cycle, not at the backstop');
        assert.deepEqual(changesFor(events, 21), ['seen', 'pickup', 'in_progress']);
    });
});

describe('XACA-1445-031: no duplicate events across repeated re-reads', () => {
    test('6. one queued (and one completed) per job across fresh 200s, 304s and grace reads', async () => {
        const { world, events, w, cycle } = setup();
        world.queued = [run(1)];
        world.jobs[1] = [job(11), job(12)];
        await w.runCycle();
        for (let i = 0; i < 6; i++) {
            // alternate a fresh 200 (12's name churns) with a 304 replay; 11 stays queued throughout
            if (i % 2 === 0) world.jobs[1] = [job(11), job(12, { name: `job-12-${i}` })];
            await cycle();
        }
        world.jobs[1] = [job(11, { status: 'in_progress', runner_name: 'r1' }), job(12)];
        await cycle(); await cycle();
        world.queued = [];
        world.jobs[1] = [done(11, 'success', { runner_name: 'r1' }), done(12)];
        for (let i = 0; i < 8; i++) await cycle(); // through the whole grace window
        const per = (id, ch) => events.filter((e) => e.rec.jobId === id && e.change === ch).length;
        assert.equal(per(11, 'queued'), 1);
        assert.equal(per(12, 'queued'), 1);
        assert.equal(per(11, 'pickup'), 1);
        assert.equal(per(11, 'in_progress'), 1);
        assert.equal(per(11, 'completed'), 1);
        assert.equal(per(12, 'completed'), 1);
        assert.equal(w.snapshot().runsInGrace, 0);
    });
});

describe('XACA-1445-034: a failed repo poll does not lose a run before its grace re-reads', () => {
    test('run leaves the lists after a cycle whose repo poll threw; its late gate job is still emitted', async () => {
        const { world, events, w, cycle } = setup();
        world.queued = [run(9)];
        world.jobs[9] = [];                      // no job of this run is held, so nothing in `jobs` keeps it live
        await w.runCycle();
        assert.equal(events.length, 0);

        // Cycle 2: the runs listing fails. prune() runs anyway; only the inLists guard keeps run 9's entry.
        const realGet = world.github.conditionalGet;
        world.github.conditionalGet = async (req) => {
            if (/\/actions\/runs\?status=/.test(req.path)) throw new GithubError('HTTP', 'GET runs failed: HTTP 502', { status: 502 });
            return realGet(req);
        };
        await cycle();
        world.github.conditionalGet = realGet;

        // Cycle 3: the run is gone from both lists (cancelled), and an always() gate job appeared in it.
        world.queued = [];
        world.jobs[9] = [job(90)];
        await cycle();
        assert.deepEqual(changesFor(events, 90), ['queued'], 'the gate must be seen via the grace re-read');
    });
});

describe('XACA-1445-037: pending/requested runs and the recent-runs backstop', () => {
    const changes = (events, jobId, ch) => events.filter((e) => e.rec.jobId === jobId && e.change === ch).length;

    test('1. a run only in the status=pending list: its queued job is emitted in cycle 1', async () => {
        const { world, events, w } = setup();
        world.pending = [run(31, { status: 'pending' })];
        world.jobs[31] = [job(310)];
        await w.runCycle();
        assert.deepEqual(changesFor(events, 310), ['queued']);
        assert.equal(world.calls.filter((c) => /runs\?status=pending&per_page=100$/.test(c.path)).length, 1);
    });

    test('2. a pending run read empty in cycle 1 is re-read with updated_at fixed; its job is emitted in cycle 2', async () => {
        const { world, events, w, cycle } = setup();
        world.pending = [run(32, { status: 'pending' })];
        world.jobs[32] = [];
        await w.runCycle();
        assert.equal(events.length, 0);
        world.jobs[32] = [job(320)];
        await cycle();
        assert.deepEqual(changesFor(events, 320), ['queued']);
        assert.equal(jobCalls(world, 32), 2, 're-read every cycle, not gated on updated_at');
    });

    test('3. the same for status=requested (cycle 1 and a cycle-2 re-read)', async () => {
        const { world, events, w, cycle } = setup();
        world.requested = [run(33, { status: 'requested' }), run(34, { status: 'requested' })];
        world.jobs[33] = [job(330)];
        world.jobs[34] = [];
        await w.runCycle();
        assert.deepEqual(changesFor(events, 330), ['queued']);
        world.jobs[34] = [job(340)];
        await cycle();
        assert.deepEqual(changesFor(events, 340), ['queued']);
        assert.equal(changes(events, 330, 'queued'), 1, 'the re-read does not repeat the cycle-1 event');
    });

    test('4. list lag: a queued run only on the unfiltered recent page is emitted; no duplicate when the list catches up', async () => {
        const { world, events, w, cycle } = setup();
        world.recent = [run(35, { status: 'queued' }), run(36, { status: 'completed' })];
        world.jobs[35] = [job(350)];
        world.jobs[36] = [done(360)];
        await w.runCycle();
        assert.deepEqual(changesFor(events, 350), ['queued']);
        assert.equal(w.snapshot().lastCycle.backstopAdded, 1);
        assert.equal(jobCalls(world, 36), 0, 'a completed run on the recent page costs no jobs fetch');
        world.queued = [run(35, { status: 'queued' })];   // the list caught up
        await cycle();
        assert.equal(w.snapshot().lastCycle.backstopAdded, 0, 'already listed => not counted as a backstop add');
        assert.equal(changes(events, 350, 'queued'), 1);
        assert.equal(w.snapshot().runsInGrace, 0, 'moving between sources is not leaving the lists');
    });

    test('4b. a backstop-only run read empty in cycle 1 is re-read every cycle (updated_at fixed); its job is emitted', async () => {
        const { world, events, w, cycle } = setup();
        world.recent = [run(39, { status: 'queued' })];
        world.jobs[39] = [];
        await w.runCycle();
        world.jobs[39] = [job(390)];
        await cycle();
        assert.deepEqual(changesFor(events, 390), ['queued']);
        assert.equal(jobCalls(world, 39), 2);
    });

    test('5. a `waiting` run (environment approval) is never demand: no event, no jobs fetch, from any source', async () => {
        const { world, events, w, cycle } = setup();
        world.recent = [run(37, { status: 'waiting' })];
        world.pending = [run(38, { status: 'waiting' })];       // defensive: waiting is ignored wherever listed
        world.jobs[37] = [job(370, { status: 'waiting' })];
        world.jobs[38] = [job(380, { status: 'waiting' })];
        await w.runCycle();
        await cycle();
        assert.equal(events.length, 0);
        assert.equal(jobCalls(world, 37), 0);
        assert.equal(jobCalls(world, 38), 0);
        assert.equal(w.snapshot().runsTracked, 0);
    });

    test('6. concurrency replacement: A cancelled, B pending -> queued -> in_progress; B queued exactly once, no duplicates', async () => {
        const { world, events, w, cycle } = setup();
        world.in_progress = [run(40, { status: 'in_progress' })];
        world.jobs[40] = [job(400, { status: 'in_progress', runner_name: 'r1' })];
        await w.runCycle();
        // A is cancelling and leaves the lists; B (same workflow + PR) is pending during the hand-off, jobs not created yet.
        world.in_progress = [];
        world.jobs[40] = [done(400, 'cancelled', { runner_name: 'r1' })];
        world.pending = [run(41, { status: 'pending' })];
        world.jobs[41] = [];
        await cycle();
        world.jobs[41] = [job(410, { status: 'pending' })];       // still pending, job created, updated_at fixed
        await cycle();
        assert.deepEqual(changesFor(events, 410), ['queued'], 'demand seen while B is still pending');
        world.pending = [];
        world.queued = [run(41, { status: 'queued' })];
        world.jobs[41] = [job(410)];
        await cycle(); await cycle();
        world.queued = [];
        world.in_progress = [run(41, { status: 'in_progress', updated_at: '2026-10-19T23:01:00Z' })];
        world.jobs[41] = [job(410, { status: 'in_progress', runner_name: 'jit-1' })];
        await cycle();
        world.in_progress = [];
        world.jobs[41] = [done(410, 'success', { runner_name: 'jit-1' })];
        for (let i = 0; i < 6; i++) await cycle();
        assert.deepEqual(changesFor(events, 410), ['queued', 'pickup', 'in_progress', 'completed']);
        assert.deepEqual(changesFor(events, 400), ['seen', 'pickup', 'in_progress', 'completed']);
        assert.equal(events.find((e) => e.rec.jobId === 400 && e.change === 'completed').rec.conclusion, 'cancelled');
        assert.equal(w.snapshot().jobs.queued, 0);
    });

    test('a backstop failure is logged and counted, and the filtered lists still produce demand', async () => {
        const { world, events, logs, w } = setup();
        world.queued = [run(42, { status: 'queued' })];
        world.jobs[42] = [job(420)];
        const realGet = world.github.conditionalGet;
        world.github.conditionalGet = async (req) => {
            if (/\/actions\/runs\?per_page=/.test(req.path)) throw new GithubError('HTTP', 'GET runs failed: HTTP 502', { status: 502 });
            return realGet(req);
        };
        await w.runCycle();
        assert.deepEqual(changesFor(events, 420), ['queued']);
        assert.equal(w.snapshot().lastCycle.backstopFailed, 1);
        assert.ok(logs.some(([l, m]) => l === 'warn' && /recent-runs backstop failed/.test(m)));
    });

    test('a rate-limited backstop propagates like any list call (the poll fails, the cycle backs off)', async () => {
        const { world, w } = setup();
        const realGet = world.github.conditionalGet;
        world.github.conditionalGet = async (req) => {
            if (/\/actions\/runs\?per_page=/.test(req.path)) throw new GithubError('RATE_LIMITED', 'rate limited', { status: 403 });
            return realGet(req);
        };
        await w.runCycle();
        assert.equal(w.snapshot().lastCycle.ok, false);
        assert.match(w.snapshot().lastCycle.error, /RATE_LIMITED/);
        assert.equal(w.snapshot().lastCycle.backstopFailed, 0);
    });
});
