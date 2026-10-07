//
//  xaca-1441-assignments.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1441-005 -- lib/ci-dispatch-assignments.js: lifecycle, every timeout, idempotent
 * state posts, at-most-once delivery, restart expiry, wrong-job-pickup audit.
 * Fake github + injected clock; the audit and state files are real files in a mkdtemp dir.
 * NO network, NO real timers.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const { test, describe, after } = require('node:test');
const assert = require('node:assert/strict');

const { createAssignments, DEFAULT_TIMEOUTS, ID_RE } = require('../lib/ci-dispatch-assignments');
const { createAudit } = require('../lib/ci-dispatch-audit');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca1441-005-asg-'));
after(() => fs.rmSync(TMP, { recursive: true, force: true }));
let seq = 0;

const T0 = Date.UTC(2026, 9, 6, 12, 0, 0);
const SENTINEL = 'JITCFG-SENTINEL-3f9a0c71-do-not-leak';
const FULL_LABELS = ['self-hosted', 'Linux', 'ARM64', 'fleet-pool', 'm4mini'];

function jobRec(over = {}) {
    return Object.assign({
        key: 'acme/widgets#100#1', owner: 'acme', repo: 'widgets', runId: 50, runAttempt: 1, jobId: 100,
        name: 'shell-suite', labels: ['self-hosted', 'Linux', 'ARM64', 'fleet-pool'], status: 'queued',
        runnerName: null,
    }, over);
}

function harness(over = {}) {
    const dir = path.join(TMP, `h${++seq}`);
    fs.mkdirSync(dir, { recursive: true });
    const clock = { t: T0, now() { return this.t; } };
    let runnerSeq = 7000;
    const gh = {
        mints: [], deletes: [], deleteMode: null, mintError: null,
        async generateJitConfig(a) {
            if (gh.mintError) throw gh.mintError;
            gh.mints.push(a);
            return { runnerId: ++runnerSeq, encodedJitConfig: `${SENTINEL}-${runnerSeq}` };
        },
        async deleteRunner(a) {
            gh.deletes.push(a);
            const m = typeof gh.deleteMode === 'function' ? gh.deleteMode(a) : gh.deleteMode;
            if (m === 422) { const e = new Error('busy'); e.status = 422; throw e; }
            if (m === 404) return { deleted: false, alreadyGone: true };
            return { deleted: true };
        },
    };
    const auditFile = path.join(dir, 'ci-dispatch-audit.jsonl');
    const audit = createAudit({ path: auditFile, keep: 2, now: () => new Date(clock.t) });
    let n = 0;
    let hexN = 0;
    const logs = [];
    const file = path.join(dir, 'ci-dispatch-state.json');
    const mk = () => createAssignments(Object.assign({
        file, github: gh, audit, now: () => clock.t,
        randomUUID: () => { n++; return `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`; },
        randomHex: () => `deadbe${String(++hexN).padStart(2, '0')}`,
        logger: { error: (m) => logs.push(m), warn: (m) => logs.push(m) },
    }, over));
    const a = mk();
    const auditRows = () => (fs.existsSync(auditFile) ? fs.readFileSync(auditFile, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l)) : []);
    return { a, mk, gh, clock, dir, file, auditFile, auditRows, logs };
}

async function mintOn(h, machine = 'm4mini', job = jobRec()) {
    const r = await h.a.mint({ job, machine, labels: FULL_LABELS, os: 'Linux' });
    assert.equal(r.ok, true);
    return r.assignment;
}

describe('mint', () => {
    test('registers a full-label JIT runner, holds the config only in memory, audits assign', async () => {
        const h = harness();
        const view = await mintOn(h);
        assert.match(view.id, ID_RE);
        assert.equal(view.state, 'pending');
        assert.equal(view.runnerName, 'fcp-m4mini-deadbe01');
        assert.equal(h.gh.mints.length, 1);
        assert.deepEqual(h.gh.mints[0].labels, FULL_LABELS);
        assert.equal(h.gh.mints[0].owner, 'acme');
        assert.equal(h.gh.mints[0].name, 'fcp-m4mini-deadbe01');
        assert.equal(h.a.holdsConfig(view.id), true);
        assert.equal(JSON.stringify(view).includes(SENTINEL), false);
        const row = h.auditRows().find((r) => r.event === 'assign');
        assert.equal(row.id, view.id);
        assert.equal(row.machine, 'm4mini');
        assert.equal(row.jobId, 100);
        assert.equal(row.jobName, 'shell-suite');
    });

    test('a failed mint records nothing and audits the failure without the error body', async () => {
        const h = harness();
        const e = new Error('secret-body-should-not-appear'); e.code = 'HTTP'; e.status = 403;
        h.gh.mintError = e;
        const r = await h.a.mint({ job: jobRec(), machine: 'm4mini', labels: FULL_LABELS, os: 'Linux' });
        assert.equal(r.ok, false);
        assert.equal(r.reason, 'mint-failed');
        assert.equal(h.a.snapshot().length, 0);
        const row = h.auditRows().find((x) => x.event === 'assign');
        assert.equal(row.state, 'mint-failed');
        assert.equal(JSON.stringify(h.auditRows()).includes('secret-body'), false);
    });

    test('bad arguments mint nothing and never call GitHub', async () => {
        const h = harness();
        for (const p of [null, {}, { job: jobRec(), machine: '', labels: FULL_LABELS, os: 'Linux' },
            { job: jobRec(), machine: 'm', labels: [], os: 'Linux' }, { job: jobRec(), machine: 'm', labels: FULL_LABELS, os: 'Windows' },
            { job: jobRec({ owner: 'bad owner' }), machine: 'm', labels: FULL_LABELS, os: 'Linux' }]) {
            assert.equal((await h.a.mint(p)).ok, false);
        }
        assert.equal(h.gh.mints.length, 0);
    });
});

describe('delivery is at-most-once to the owning machine', () => {
    test('a poll gets the config once; the second poll gets nothing and the config is gone', async () => {
        const h = harness();
        const v = await mintOn(h);
        h.clock.t += 5000;
        const first = h.a.takeForMachine('m4mini');
        assert.equal(first.length, 1);
        assert.equal(first[0].id, v.id);
        assert.equal(first[0].jitConfig, `${SENTINEL}-7001`);
        assert.equal(first[0].runnerName, 'fcp-m4mini-deadbe01');
        assert.equal(first[0].jobBindTimeoutSeconds, 300);
        assert.equal(first[0].startBy, new Date(h.clock.t + 120000).toISOString());
        assert.deepEqual(first[0].intendedJob, { id: 100, name: 'shell-suite', runId: 50 });
        assert.equal(h.a.holdsConfig(v.id), false);
        assert.equal(h.a.get(v.id).state, 'delivered');
        assert.deepEqual(h.a.takeForMachine('m4mini'), []);
    });

    test('another machine never receives it', async () => {
        const h = harness();
        await mintOn(h, 'm4mini');
        assert.deepEqual(h.a.takeForMachine('m1mini'), []);
        assert.equal(h.a.takeForMachine('m4mini').length, 1);
    });

    test('a pending assignment past its timeout is expired, not delivered', async () => {
        const h = harness();
        const v = await mintOn(h);
        h.clock.t += DEFAULT_TIMEOUTS.pendingMs;
        assert.deepEqual(h.a.takeForMachine('m4mini'), []);
        assert.equal(h.a.get(v.id).state, 'expired');
    });
});

describe('lifecycle and timeouts (C5)', () => {
    test('happy path: pending > delivered > started > running > completed, every transition audited', async () => {
        const h = harness();
        const v = await mintOn(h);
        h.a.takeForMachine('m4mini');
        assert.deepEqual(h.a.report(v.id, 'm4mini', { state: 'started' }), { status: 'ok', state: 'started', changed: true });
        const bound = h.a.bindJob({ ...jobRec(), runnerName: 'fcp-m4mini-deadbe01', status: 'in_progress' }, 'in_progress');
        assert.equal(bound.state, 'running');
        assert.equal(bound.boundJob.id, 100);
        assert.deepEqual(h.a.report(v.id, 'm4mini', { state: 'completed', exitCode: 0 }), { status: 'ok', state: 'completed', changed: true });
        const stats = await h.a.sweep();
        assert.equal(stats.deleted, 0);
        assert.equal(h.gh.deletes.length, 0, 'a bound job self-deregisters (E1); no DELETE');
        const transitions = h.auditRows().filter((r) => r.event === 'state').map((r) => `${r.from}>${r.to}`);
        assert.deepEqual(transitions, ['pending>delivered', 'delivered>started', 'started>running', 'running>completed']);
    });

    test('pending expires at 60 s: registration deleted, no kill instruction (nothing was delivered)', async () => {
        const h = harness();
        const v = await mintOn(h);
        h.clock.t += DEFAULT_TIMEOUTS.pendingMs - 1;
        assert.equal(h.a.expireDue(), 0);
        h.clock.t += 1;
        const stats = await h.a.sweep();
        assert.equal(stats.expired, 1);
        assert.equal(h.a.get(v.id).state, 'expired');
        assert.deepEqual(h.gh.deletes, [{ owner: 'acme', repo: 'widgets', runnerId: 7001 }]);
        assert.deepEqual(h.a.cancelListFor('m4mini'), []);
        assert.equal(h.a.holdsConfig(v.id), false);
        assert.equal(h.auditRows().filter((r) => r.event === 'expire').length, 1);
    });

    test('delivered expires at 120 s: DELETE plus a kill instruction on the next poll (A4)', async () => {
        const h = harness();
        const v = await mintOn(h);
        h.a.takeForMachine('m4mini');
        h.clock.t += DEFAULT_TIMEOUTS.deliveredMs - 1;
        assert.equal(h.a.expireDue(), 0);
        h.clock.t += 1;
        await h.a.sweep();
        assert.equal(h.a.get(v.id).state, 'expired');
        assert.equal(h.gh.deletes.length, 1);
        assert.deepEqual(h.a.cancelListFor('m4mini'), [v.id]);
        assert.deepEqual(h.a.cancelListFor('m1mini'), []);
    });

    test('started with no job bound is cancelled at 300 s, DELETEd, and the listener kill is requested', async () => {
        const h = harness();
        const v = await mintOn(h);
        h.a.takeForMachine('m4mini');
        h.a.report(v.id, 'm4mini', { state: 'started' });
        h.clock.t += DEFAULT_TIMEOUTS.boundMs - 1;
        assert.equal(h.a.expireDue(), 0);
        h.clock.t += 1;
        await h.a.sweep();
        assert.equal(h.a.get(v.id).state, 'cancelled');
        assert.equal(h.gh.deletes.length, 1);
        assert.deepEqual(h.a.cancelListFor('m4mini'), [v.id]);
    });

    test('running is lost at 375 min; DELETE issued; no kill instruction for a running job', async () => {
        const h = harness();
        const v = await mintOn(h);
        h.a.takeForMachine('m4mini');
        h.a.report(v.id, 'm4mini', { state: 'started' });
        h.a.bindJob({ ...jobRec(), runnerName: 'fcp-m4mini-deadbe01' }, 'pickup');
        h.clock.t += DEFAULT_TIMEOUTS.runningMs - 1;
        assert.equal(h.a.expireDue(), 0);
        h.clock.t += 1;
        await h.a.sweep();
        assert.equal(h.a.get(v.id).state, 'lost');
        assert.equal(h.gh.deletes.length, 1);
        assert.deepEqual(h.a.cancelListFor('m4mini'), []);
    });

    test('a bound job is never cancelled by the 300 s bind timeout', async () => {
        const h = harness();
        const v = await mintOn(h);
        h.a.takeForMachine('m4mini');
        h.a.report(v.id, 'm4mini', { state: 'started' });
        h.a.bindJob({ ...jobRec(), runnerName: 'fcp-m4mini-deadbe01' }, 'pickup');
        h.clock.t += 3600 * 1000;
        assert.equal(h.a.expireDue(), 0);
        assert.equal(h.a.get(v.id).state, 'running');
    });

    test('the kill instruction stops after the agent acknowledges, and after the retention window', async () => {
        const h = harness();
        const v = await mintOn(h);
        h.a.takeForMachine('m4mini');
        h.clock.t += DEFAULT_TIMEOUTS.deliveredMs;
        await h.a.sweep();
        assert.deepEqual(h.a.cancelListFor('m4mini'), [v.id]);
        assert.deepEqual(h.a.report(v.id, 'm4mini', { state: 'cancelled' }), { status: 'ok', state: 'expired', changed: true });
        assert.deepEqual(h.a.cancelListFor('m4mini'), []);
        assert.equal(h.a.report(v.id, 'm4mini', { state: 'cancelled' }).changed, false);

        const v2 = await mintOn(h, 'm4mini', jobRec({ jobId: 101 }));
        h.a.takeForMachine('m4mini');
        h.clock.t += DEFAULT_TIMEOUTS.deliveredMs;
        await h.a.sweep();
        assert.deepEqual(h.a.cancelListFor('m4mini'), [v2.id]);
        h.clock.t += DEFAULT_TIMEOUTS.cancelRetainMs;
        assert.deepEqual(h.a.cancelListFor('m4mini'), []);
    });
});

describe('registration cleanup', () => {
    test('422 (runner busy) is retried on the next sweep and never forced; 404 counts as gone', async () => {
        const h = harness();
        const v = await mintOn(h);
        h.clock.t += DEFAULT_TIMEOUTS.pendingMs;
        h.gh.deleteMode = 422;
        let s = await h.a.sweep();
        assert.deepEqual([s.deleted, s.retry], [0, 1]);
        s = await h.a.sweep();
        assert.equal(s.retry, 1);
        assert.equal(h.gh.deletes.length, 2);
        h.gh.deleteMode = 404;
        s = await h.a.sweep();
        assert.equal(s.deleted, 1);
        s = await h.a.sweep();
        assert.equal(h.gh.deletes.length, 3, 'done is done');
        assert.equal(h.a.get(v.id).state, 'expired');
        const dereg = h.auditRows().filter((r) => r.event === 'deregister');
        assert.equal(dereg.length, 2, 'first busy retry + final success; no per-cycle spam');
        assert.equal(dereg[0].httpStatus, 422);
        assert.equal(dereg[1].ok, true);
    });

    test('gives up after the attempt cap and says so', async () => {
        const h = harness({ timeouts: { maxCleanupAttempts: 3 } });
        await mintOn(h);
        h.clock.t += DEFAULT_TIMEOUTS.pendingMs;
        h.gh.deleteMode = 422;
        await h.a.sweep(); await h.a.sweep();
        const s = await h.a.sweep();
        assert.equal(s.failed, 1);
        await h.a.sweep();
        assert.equal(h.gh.deletes.length, 3);
        assert.equal(h.auditRows().filter((r) => r.event === 'deregister').pop().reason, 'giving-up');
    });

    test('failed with no job bound owes a DELETE (A4); failed with a bound job does not', async () => {
        const h = harness();
        const v = await mintOn(h);
        h.a.takeForMachine('m4mini');
        h.a.report(v.id, 'm4mini', { state: 'failed', exitCode: 3, reason: 'listener would not start' });
        await h.a.sweep();
        assert.equal(h.gh.deletes.length, 1);

        const w = await mintOn(h, 'm4mini', jobRec({ jobId: 101 }));
        h.a.takeForMachine('m4mini');
        h.a.report(w.id, 'm4mini', { state: 'started' });
        h.a.bindJob({ ...jobRec({ jobId: 101 }), runnerName: 'fcp-m4mini-deadbe02' }, 'pickup');
        h.a.report(w.id, 'm4mini', { state: 'failed', exitCode: 1 });
        await h.a.sweep();
        assert.equal(h.gh.deletes.length, 1, 'no second DELETE');
    });

    // XACA-1441-026: a runner that died (reason `runner-lost`) leaves a registration GitHub only auto-removes
    // after about a day (documentation-sourced), so the DELETE is owed even when a job was bound.
    const LOST_TABLE = [
        // [description, job bound, reason, DELETE owed]
        ['runner-lost, no job bound', false, 'runner-lost', true],
        ['runner-lost, job bound', true, 'runner-lost', true],
        ['other failure, no job bound (A4)', false, 'listener would not start', true],
        ['other failure, job bound: GitHub already consumed the runner', true, 'job-failed', false],
        ['no reason, job bound', true, undefined, false],
        ['runner-lost lookalike, job bound', true, 'runner-lost-ish', false],
    ];
    async function failedRunner(h, bound, reason) {
        const jobId = 300 + h.gh.mints.length;
        const v = await mintOn(h, 'm4mini', jobRec({ jobId }));
        h.a.takeForMachine('m4mini');
        h.a.report(v.id, 'm4mini', { state: 'started' });
        if (bound) h.a.bindJob({ ...jobRec({ jobId }), runnerName: v.runnerName }, 'pickup');
        const body = { state: 'failed' };
        if (reason !== undefined) body.reason = reason;
        assert.equal(h.a.report(v.id, 'm4mini', body).status, 'ok');
        return v;
    }
    for (const [name, bound, reason, owed] of LOST_TABLE) {
        test(`failed report: ${name} -> DELETE ${owed ? 'queued' : 'not queued'}`, async () => {
            const h = harness();
            const v = await failedRunner(h, bound, reason);
            assert.equal((h.a.get(v.id).boundJob !== null), bound, 'fixture: bound as intended');
            await h.a.sweep();
            assert.equal(h.gh.deletes.length, owed ? 1 : 0);
            if (owed) assert.equal(h.gh.deletes[0].runnerId, 7001);
        });
    }

    test('runner-lost with a bound job: a 404 counts as success and is not repeated', async () => {
        const h = harness();
        await failedRunner(h, true, 'runner-lost');
        h.gh.deleteMode = 404;
        const s = await h.a.sweep();
        assert.equal(s.deleted, 1);
        await h.a.sweep();
        assert.equal(h.gh.deletes.length, 1);
        assert.equal(h.auditRows().filter((r) => r.event === 'deregister').pop().httpStatus, 404);
    });

    test('runner-lost with a bound job: a 422 (still busy) is retried every sweep, never forced, and capped', async () => {
        const h = harness({ timeouts: { maxCleanupAttempts: 3 } });
        await failedRunner(h, true, 'runner-lost');
        h.gh.deleteMode = 422;
        let s = await h.a.sweep();
        assert.deepEqual([s.deleted, s.retry], [0, 1]);
        s = await h.a.sweep();
        assert.equal(s.retry, 1);
        s = await h.a.sweep();
        assert.equal(s.failed, 1, 'attempt cap reached');
        await h.a.sweep();
        assert.equal(h.gh.deletes.length, 3, 'no fourth attempt');
        assert.ok(h.gh.deletes.every((d) => d.force === undefined), 'never forced');
    });

    test('concurrent sweeps share one run (no double DELETE)', async () => {
        const h = harness();
        await mintOn(h);
        h.clock.t += DEFAULT_TIMEOUTS.pendingMs;
        const [a, b] = await Promise.all([h.a.sweep(), h.a.sweep()]);
        assert.equal(a, b);
        assert.equal(h.gh.deletes.length, 1);
    });

    test('a no-op first sweep does not pin the guard: later sweeps still expire and DELETE', async () => {
        const h = harness();
        const first = await h.a.sweep();
        assert.deepEqual(first, { expired: 0, deleted: 0, retry: 0, failed: 0 });
        const v = await mintOn(h);
        h.clock.t += DEFAULT_TIMEOUTS.pendingMs + 1000;
        const second = await h.a.sweep();
        assert.notEqual(second, first, 'second sweep returned the stale first result');
        assert.equal(second.expired, 1);
        assert.equal(second.deleted, 1);
        assert.equal(h.a.get(v.id).state, 'expired');
        assert.equal(h.gh.deletes.length, 1);
    });
});

describe('agent reports: idempotency, conflicts, ownership', () => {
    async function delivered() {
        const h = harness();
        const v = await mintOn(h);
        h.a.takeForMachine('m4mini');
        return { h, id: v.id };
    }

    test('repeating a transition returns 200 with the current state and changes nothing', async () => {
        const { h, id } = await delivered();
        assert.equal(h.a.report(id, 'm4mini', { state: 'started' }).changed, true);
        const rowsBefore = h.auditRows().length;
        assert.deepEqual(h.a.report(id, 'm4mini', { state: 'started' }), { status: 'ok', state: 'started', changed: false });
        assert.equal(h.auditRows().length, rowsBefore, 'a repeat writes no audit row');
        h.a.bindJob({ ...jobRec(), runnerName: 'fcp-m4mini-deadbe01' }, 'pickup');
        assert.equal(h.a.report(id, 'm4mini', { state: 'started' }).state, 'running', 'late started after the watcher bound: benign');
        h.a.report(id, 'm4mini', { state: 'completed', exitCode: 0 });
        assert.deepEqual(h.a.report(id, 'm4mini', { state: 'completed', exitCode: 0 }), { status: 'ok', state: 'completed', changed: false });
    });

    test('illegal or backwards transitions are 409', async () => {
        const h = harness();
        const v = await mintOn(h);
        assert.equal(h.a.report(v.id, 'm4mini', { state: 'started' }).status, 'conflict', 'pending is not startable');
        h.a.takeForMachine('m4mini');
        assert.equal(h.a.report(v.id, 'm4mini', { state: 'completed' }).status, 'conflict', 'delivered cannot complete');
        h.a.report(v.id, 'm4mini', { state: 'started' });
        h.a.bindJob({ ...jobRec(), runnerName: 'fcp-m4mini-deadbe01' }, 'pickup');
        assert.equal(h.a.report(v.id, 'm4mini', { state: 'cancelled' }).status, 'conflict', 'the agent never cancels a running job');
        h.a.report(v.id, 'm4mini', { state: 'completed' });
        assert.equal(h.a.report(v.id, 'm4mini', { state: 'started' }).status, 'conflict');
        assert.equal(h.a.report(v.id, 'm4mini', { state: 'failed' }).status, 'conflict');
        assert.equal(h.a.report(v.id, 'm4mini', { state: 'cancelled' }).status, 'conflict');
        assert.equal(h.a.report(v.id, 'm4mini', { state: 'bogus' }).status, 'conflict');
        assert.equal(h.a.get(v.id).state, 'completed');
    });

    test('unknown id and another machine\'s id are indistinguishable', async () => {
        const { h, id } = await delivered();
        assert.deepEqual(h.a.report(id, 'm1mini', { state: 'started' }), { status: 'notfound' });
        assert.deepEqual(h.a.report('a_00000000-0000-4000-8000-0000000000ff', 'm4mini', { state: 'started' }), { status: 'notfound' });
        assert.deepEqual(h.a.report(undefined, 'm4mini', { state: 'started' }), { status: 'notfound' });
        assert.equal(h.a.get(id).state, 'delivered');
    });

    test('the agent may cancel its own un-bound listener; that owes a DELETE but no kill instruction', async () => {
        const { h, id } = await delivered();
        h.a.report(id, 'm4mini', { state: 'started' });
        assert.equal(h.a.report(id, 'm4mini', { state: 'cancelled', reason: 'operator stop' }).state, 'cancelled');
        assert.deepEqual(h.a.cancelListFor('m4mini'), []);
        await h.a.sweep();
        assert.equal(h.gh.deletes.length, 1);
    });

    test('a late completed/failed report corrects a presumed expired/lost state', async () => {
        const { h, id } = await delivered();
        h.clock.t += DEFAULT_TIMEOUTS.deliveredMs;
        await h.a.sweep();
        assert.equal(h.a.get(id).state, 'expired');
        assert.equal(h.a.report(id, 'm4mini', { state: 'failed', exitCode: 9 }).state, 'failed');
    });

    test('free-text reason is stripped of control characters and capped at 200', async () => {
        const { h, id } = await delivered();
        h.a.report(id, 'm4mini', { state: 'failed', reason: `bad\u0000\u001b[31m${'x'.repeat(500)}` });
        const r = h.a.get(id).reason;
        assert.equal(r.length <= 200, true);
        assert.equal(/[\u0000-\u001f]/.test(r), false);
    });
});

describe('binding by runner_name (A2) and wrong-job-pickup audit', () => {
    test('binds only on a runner_name match in the same repo, once', async () => {
        const h = harness();
        const v = await mintOn(h);
        h.a.takeForMachine('m4mini');
        assert.equal(h.a.bindJob({ ...jobRec(), runnerName: 'someone-else' }, 'pickup'), null);
        assert.equal(h.a.bindJob({ ...jobRec({ repo: 'other' }), runnerName: 'fcp-m4mini-deadbe01' }, 'pickup'), null);
        assert.equal(h.a.bindJob({ ...jobRec(), runnerName: null }, 'pickup'), null);
        assert.equal(h.a.bindJob({ ...jobRec(), runnerName: 'fcp-m4mini-deadbe01' }, 'queued'), null);
        assert.equal(h.a.get(v.id).state, 'delivered');
        assert.equal(h.a.bindJob({ ...jobRec(), runnerName: 'fcp-m4mini-deadbe01' }, 'pickup').state, 'running');
        assert.equal(h.a.bindJob({ ...jobRec(), runnerName: 'fcp-m4mini-deadbe01' }, 'in_progress'), null, 'second event is a no-op');
        assert.equal(h.auditRows().filter((r) => r.event === 'wrong-job-pickup').length, 0, 'intended job: no row');
    });

    test('a pending assignment is never bound (its config was never delivered)', async () => {
        const h = harness();
        await mintOn(h);
        assert.equal(h.a.bindJob({ ...jobRec(), runnerName: 'fcp-m4mini-deadbe01' }, 'pickup'), null);
    });

    test('a pickup of a job other than the intended one writes wrong-job-pickup naming both ids', async () => {
        const h = harness();
        const v = await mintOn(h);
        h.a.takeForMachine('m4mini');
        h.a.bindJob({ ...jobRec({ jobId: 222, key: 'acme/widgets#222#1', name: 'lint' }), runnerName: 'fcp-m4mini-deadbe01' }, 'pickup');
        const rows = h.auditRows().filter((r) => r.event === 'wrong-job-pickup');
        assert.equal(rows.length, 1);
        assert.equal(rows[0].id, v.id);
        assert.equal(rows[0].jobId, 222);
        assert.equal(rows[0].reason, 'intended:100 bound:222');
        assert.equal(rows[0].machine, 'm4mini');
        assert.deepEqual(h.a.get(v.id).boundJob, { id: 222, name: 'lint', runId: 50 });
    });
});

describe('supply accounting (D5)', () => {
    test('outstanding counts pending/delivered/started per demand label-set, not running or terminal', async () => {
        const h = harness();
        const a = await mintOn(h, 'm4mini', jobRec({ jobId: 1 }));
        const b = await mintOn(h, 'm4mini', jobRec({ jobId: 2 }));
        const c = await mintOn(h, 'm4mini', jobRec({ jobId: 3, labels: ['self-hosted', 'Linux', 'ARM64', 'fleet-pool', 'm4mini'] }));
        const key = 'arm64,fleet-pool,linux,self-hosted';
        assert.equal(h.a.outstandingBySet().get(key), 2);
        h.a.takeForMachine('m4mini');
        h.a.report(a.id, 'm4mini', { state: 'started' });
        assert.equal(h.a.outstandingBySet().get(key), 2, 'delivered and started both still count');
        h.a.bindJob({ ...jobRec({ jobId: 1 }), runnerName: 'fcp-m4mini-deadbe01' }, 'pickup');
        assert.equal(h.a.outstandingBySet().get(key), 1, 'a bound assignment leaves the outstanding count');
        assert.equal(h.a.outstandingBySet().get('arm64,fleet-pool,linux,m4mini,self-hosted'), 1, 'a different demand label-set is counted separately');
        assert.ok(b && c);
    });
});

describe('persistence and restart', () => {
    test('the state file is non-secret metadata, atomic, mode 600, with no temp file left', async () => {
        const h = harness();
        const v = await mintOn(h);
        const raw = fs.readFileSync(h.file, 'utf8');
        assert.equal(raw.includes(SENTINEL), false);
        const doc = JSON.parse(raw);
        assert.equal(doc.assignments[0].id, v.id);
        assert.equal(doc.assignments[0].runnerId, 7001);
        assert.equal((fs.statSync(h.file).mode & 0o777), 0o600);
        assert.deepEqual(fs.readdirSync(h.dir).filter((f) => f.includes('.tmp-')), []);
        assert.equal(Object.keys(doc.assignments[0]).includes('jitConfig'), false);
    });

    test('restart: every non-terminal assignment expires, its registration is DELETEd, configs are gone', async () => {
        const h = harness();
        const p = await mintOn(h, 'm4mini', jobRec({ jobId: 1 }));
        const d = await mintOn(h, 'm4mini', jobRec({ jobId: 2 }));
        const s = await mintOn(h, 'm4mini', jobRec({ jobId: 3 }));
        const r = await mintOn(h, 'm4mini', jobRec({ jobId: 4 }));
        const done = await mintOn(h, 'm4mini', jobRec({ jobId: 5 }));
        h.a.takeForMachine('m4mini');                                  // all delivered...
        // ...re-mint a fresh pending one that stays pending
        const pending = await mintOn(h, 'm4mini', jobRec({ jobId: 6 }));
        h.a.report(s.id, 'm4mini', { state: 'started' });
        h.a.report(r.id, 'm4mini', { state: 'started' });
        h.a.bindJob({ ...jobRec({ jobId: 4 }), runnerName: 'fcp-m4mini-deadbe04' }, 'pickup');
        h.a.report(done.id, 'm4mini', { state: 'started' });
        h.a.report(done.id, 'm4mini', { state: 'failed' });
        await h.a.sweep();
        const deletesBefore = h.gh.deletes.length;

        const h2 = { ...h, a: h.mk() };
        const loaded = h2.a.load();
        assert.equal(loaded.ok, true);
        const nonTerminal = 5;                                         // p,d,s,r,pending... (done was terminal)
        assert.equal(loaded.expired >= 1, true);
        for (const x of [p, d, s, r, pending]) {
            assert.equal(h2.a.get(x.id).state, 'expired', x.id);
            assert.equal(h2.a.holdsConfig(x.id), false);
        }
        assert.equal(h2.a.get(done.id).state, 'failed');
        assert.equal(loaded.expired, nonTerminal);
        await h2.a.sweep();
        assert.equal(h.gh.deletes.length - deletesBefore, nonTerminal, 'one DELETE per orphan');
        const ids = h.gh.deletes.slice(deletesBefore).map((x) => x.runnerId).sort();
        assert.equal(new Set(ids).size, nonTerminal);
        assert.equal(h2.a.takeForMachine('m4mini').length, 0, 'a pending assignment cannot be delivered after a restart');
        assert.equal(h.auditRows().filter((x) => x.event === 'expire' && x.reason === 'restart').length, nonTerminal);
        // kill instructions only where a listener may exist (delivered/started), never for pending or running
        const cancel = h2.a.cancelListFor('m4mini').sort();
        assert.deepEqual(cancel, [p.id, d.id, s.id].sort());
    });

    test('a corrupt state file is moved aside and load reports it without throwing', () => {
        const h = harness();
        fs.writeFileSync(h.file, '{not json');
        const r = h.a.load();
        assert.equal(r.ok, false);
        assert.equal(fs.existsSync(h.file), false);
        assert.equal(fs.readdirSync(h.dir).some((f) => f.includes('.corrupt-')), true);
        assert.equal(h.logs.length > 0, true);
    });

    test('a missing state file is a clean first boot', () => {
        const h = harness();
        assert.deepEqual(h.a.load(), { ok: true, fresh: true, expired: 0 });
    });

    test('old terminal records are pruned once their cleanup is done', async () => {
        const h = harness({ timeouts: { retainTerminalMs: 1000 } });
        const v = await mintOn(h);
        h.clock.t += DEFAULT_TIMEOUTS.pendingMs;
        await h.a.sweep();
        assert.ok(h.a.get(v.id));
        h.clock.t += 2000;
        await h.a.sweep();
        assert.equal(h.a.get(v.id), null);
    });
});
