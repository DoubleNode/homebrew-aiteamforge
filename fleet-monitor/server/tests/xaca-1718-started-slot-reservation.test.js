//
//  xaca-1718-started-slot-reservation.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1718-001 -- dispatcher over-mint race (observed 2026-11-01, m1mini, ONE macOS slot).
 * Assignment A (job 1) is delivered then STARTED; before the agent's next capacity report shows the
 * slot busy, decide() mints B (job 2) into the same slot and the agent refuses B with `no-slot`.
 * Hypothesis: decide() reserves only pending|delivered assignments, so a `started` one is judged
 * from the stored (stale, idle) agent report.
 *
 * Same harness as xaca-1441-dispatcher.test.js: real pool store / assignments / alerts, fake
 * GitHub, fake clock. No network, no real timers.
 *
 * (a) REPRO       started A + stale-idle report => no second mint          (fails on unfixed code)
 * (b) control     report lists A busy/starting/cleaning (identity, XACA-1718-013) => no mint
 * (c) control     A terminal + idle report => job 2 IS minted (no over-reserving)
 * (d) fairness    `no-slot` refusals do not count toward the ghost bound    (fails on unfixed code)
 *     d-control   genuine expiries still retire the job
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const { test, describe, after } = require('node:test');
const assert = require('node:assert/strict');

const { createPoolStore } = require('../lib/ci-pool-store');
const { createAssignments } = require('../lib/ci-dispatch-assignments');
const { createAlerts } = require('../lib/ci-dispatch-alerts');
const { createDispatcher, MAX_MINTS_PER_JOB, reportAccountsFor } = require('../lib/ci-dispatcher');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca1718-001-'));
after(() => fs.rmSync(TMP, { recursive: true, force: true }));

const T0 = Date.UTC(2026, 10, 1, 12, 0, 0);
const ENV_ON = { FLEET_CI_DISPATCHER: '1', GITHUB_APP_CLIENT_ID: 'Iv-test-client', GITHUB_APP_PRIVATE_KEY: 'not-a-real-key-fixture' };
const REPO = 'DoubleNode/dev-team';
const MAC = ['self-hosted', 'macOS', 'ARM64', 'fleet-pool'];
const MACHINE = 'm1mini';
let seq = 0;

const capacity = () => ({
    memTotalBytes: 17179869184, memReclaimableBytes: 4080000000, memFreePct: 45,
    swapUsedBytes: 100, swapTotalBytes: 3221225472, load1: 1.2, load5: 1, load15: 1, ncpu: 10,
    teamSessions: 6, vmState: 'running',
});

function rec(jobId) {
    return {
        key: `${REPO}#${jobId}#1`, owner: 'DoubleNode', repo: 'dev-team', runId: 5, runAttempt: 1, jobId,
        name: 'unit', labels: MAC.slice(), status: 'queued', conclusion: null, runnerName: null,
        createdAt: new Date(T0).toISOString(), firstSeenAt: new Date(T0 + jobId).toISOString(),
        inProgressAt: null, completedAt: null,
        run: { event: 'push', repoFullName: REPO, headRepoFullName: REPO },
    };
}

function setup(opts = {}) {
    const dir = path.join(TMP, `s${++seq}`);
    fs.mkdirSync(dir, { recursive: true });
    const clock = { t: T0 };
    const store = createPoolStore({ file: path.join(dir, 'ci-pool.json'), logger: { error() {} } });
    store.load();
    assert.equal(store.updateConfig({ allowlist: [REPO] }).ok, true);
    assert.equal(store.upsertMachine(MACHINE, { enabled: true, prefers: 'short' }).ok, true);
    const reports = new Map();
    const ghCalls = [];
    const gh = {
        async generateJitConfig(a) { ghCalls.push(['mint', a]); return { runnerId: 9000 + ghCalls.length, encodedJitConfig: `JITSENTINEL-${ghCalls.length}` }; },
        async deleteRunner(a) { ghCalls.push(['delete', a]); return { deleted: true }; },
    };
    const auditRows = [];
    const audit = { append: (event, fields) => auditRows.push(Object.assign({ event }, fields)) };
    const assignments = createAssignments({ file: path.join(dir, 'state.json'), github: gh, audit, now: () => clock.t, logger: { error() {}, warn() {} } });
    const logger = { log() {}, warn() {}, error() {} };
    const alerts = createAlerts({ now: () => clock.t, logger, getEmitter: () => null });
    const watcher = { async runCycle() { return 15000; }, stop() {} };
    const d = createDispatcher({
        maxMintsPerJob: opts.maxMintsPerJob,
        env: ENV_ON, store, assignments, alerts, audit, watcher, reports, logger, now: () => clock.t,
        setTimer: (fn, ms) => ({ fn, ms }), clearTimer() {},
    });
    // One macOS slot, reported idle at the CURRENT fake time.
    const reportIdle = () => reports.set(MACHINE, { receivedAt: clock.t, capacity: capacity(), slots: [{ os: 'macOS', index: 1, state: 'idle', assignmentId: null }] });
    const reportBusy = (assignmentId) => reports.set(MACHINE, { receivedAt: clock.t, capacity: capacity(), slots: [{ os: 'macOS', index: 1, state: 'busy', assignmentId }] });
    return { d, store, assignments, alerts, reports, clock, ghCalls, auditRows, reportIdle, reportBusy };
}

const mints = (s) => s.ghCalls.filter((c) => c[0] === 'mint');

/** Mint A for job 1, deliver it, and have the agent ack `started` (the real agent path). */
async function startA(s) {
    s.reportIdle();
    s.d.onJob(rec(1), 'queued');
    await s.d.tick();
    assert.equal(mints(s).length, 1, 'precondition: A minted for job 1');
    const A = s.assignments.snapshot()[0];
    s.clock.t += 2000;
    assert.equal(s.assignments.takeForMachine(MACHINE, s.clock.t).length, 1, 'precondition: A delivered');
    s.clock.t += 2000;
    const r = s.assignments.report(A.id, MACHINE, { state: 'started' });
    assert.equal(r.status, 'ok');
    assert.equal(s.assignments.get(A.id).state, 'started', 'precondition: A started');
    return A;
}

describe('XACA-1718-001 started-assignment slot reservation', () => {
    test('(a) REPRO: started A + stale idle report => job 2 is NOT minted into the same single slot', async () => {
        const s = setup();
        await startA(s);
        // NO newer capacity report: the stored report (received before A started) still shows the slot idle.
        s.d.onJob(rec(2), 'queued');
        await s.d.tick();
        assert.equal(mints(s).length, 1, `over-mint: ${mints(s).length} mints for ONE macOS slot (A started, report stale)`);
        assert.equal(s.assignments.snapshot().length, 1);
    });

    test('(a2) running A (GitHub bound the job before the agent\'s next report) + stale idle report => job 2 is NOT minted', async () => {
        for (const viaStarted of [true, false]) {
            const s = setup();
            let A;
            if (viaStarted) A = await startA(s);
            else {
                s.reportIdle();
                s.d.onJob(rec(1), 'queued');
                await s.d.tick();
                A = s.assignments.snapshot()[0];
                s.clock.t += 2000;
                assert.equal(s.assignments.takeForMachine(MACHINE, s.clock.t).length, 1, 'precondition: A delivered');
            }
            s.clock.t += 1000;
            const bound = s.assignments.bindJob({ owner: 'DoubleNode', repo: 'dev-team', runnerName: s.assignments.get(A.id).runnerName, jobId: 1, name: 'unit', runId: 5 }, 'in_progress');
            assert.ok(bound, 'precondition: A bound');
            assert.equal(s.assignments.get(A.id).state, 'running', 'precondition: A running');
            s.d.onJob(rec(2), 'queued');
            await s.d.tick();
            assert.equal(mints(s).length, 1, `viaStarted=${viaStarted}: over-mint into a running A's slot`);
        }
    });

    test('(b) control: report lists A in a busy / starting / cleaning slot => no reservation needed, no mint', async () => {
        for (const state of ['busy', 'starting', 'cleaning']) {
            const s = setup();
            const A = await startA(s);
            s.clock.t += 1000;
            s.reports.set(MACHINE, { receivedAt: s.clock.t, capacity: capacity(), slots: [{ os: 'macOS', index: 1, state, assignmentId: A.id }] });
            s.d.onJob(rec(2), 'queued');
            await s.d.tick();
            assert.equal(mints(s).length, 1, `A listed ${state}: slot is taken`);
        }
    });

    test('(c) control: A terminal (completed) + idle report => job 2 IS minted', async () => {
        const s = setup();
        const A = await startA(s);
        assert.equal(s.assignments.report(A.id, MACHINE, { state: 'completed' }).status, 'ok');
        assert.equal(s.assignments.get(A.id).state, 'completed');
        s.clock.t += 1000;
        s.reportIdle();
        s.d.onJob(rec(2), 'queued');
        await s.d.tick();
        assert.equal(mints(s).length, 2, 'slot is free again: job 2 must be minted');
    });

    test('(c2) control: A terminal (cancelled by bound timeout) + idle report => job 2 IS minted', async () => {
        const s = setup();
        const A = await startA(s);
        s.clock.t += 301 * 1000;   // started with no job bound -> cancelled by sweep (boundMs 300 s)
        await s.assignments.sweep();
        assert.equal(s.assignments.get(A.id).state, 'cancelled', 'precondition: A terminal');
        s.reportIdle();
        s.d.onJob(rec(2), 'queued');
        await s.d.tick();
        assert.equal(mints(s).length >= 2, true, 'terminal A must not hold a reservation');
    });

    const isRetired = (s) => s.auditRows.some((r) => r.event === 'expire' && r.jobId === 1 && /^ghost-bound: /.test(r.reason));
    const degraded = (s) => s.alerts.list().filter((a) => a.type === 'ci-dispatcher-degraded');

    // Drive N refusals/expiries for job 1. Each round: idle report -> tick mints -> deliver -> terminal.
    async function churn(s, n, terminal) {
        for (let i = 0; i < n; i++) {
            s.clock.t += 1000;
            s.reportIdle();
            await s.d.tick();
            const live = s.assignments.snapshot().filter((a) => a.state === 'pending');
            assert.equal(live.length, 1, `round ${i + 1}: one pending assignment minted`);
            s.clock.t += 1000;
            s.assignments.takeForMachine(MACHINE, s.clock.t);
            s.clock.t += 1000;
            terminal(s, live[0]);
        }
    }

    test('(d) no-slot refusals (never bound) do NOT count toward the ghost bound', async () => {
        const s = setup();
        s.d.onJob(rec(1), 'queued');
        await churn(s, MAX_MINTS_PER_JOB, (st, a) => {
            const r = st.assignments.report(a.id, MACHINE, { state: 'failed', reason: 'no-slot' });
            assert.equal(r.status, 'ok');
            assert.equal(st.assignments.get(a.id).state, 'failed');
        });
        s.clock.t += 1000;
        s.reportIdle();
        await s.d.tick();
        assert.equal(isRetired(s), false, `job 1 was retired by ${MAX_MINTS_PER_JOB} no-slot refusals (ghost-bound)`);
        assert.equal(degraded(s).filter((a) => /^ghost:/.test(a.ref)).length, 0, 'no ghost-bound alert for no-slot refusals');
        assert.equal(s.d.queue().length, 1, 'job 1 is still tracked');
    });

    test('(d2) repeated no-slot refusals raise ONE noslot alert + audit row, without retiring the job (XACA-1718-012)', async () => {
        const s = setup();
        s.d.onJob(rec(1), 'queued');
        const refuse = (st, a) => { assert.equal(st.assignments.report(a.id, MACHINE, { state: 'failed', reason: 'no-slot' }).status, 'ok'); };
        const noslot = () => degraded(s).filter((x) => /^noslot:/.test(x.ref));
        const tickNow = async () => { s.clock.t += 1000; s.reportIdle(); await s.d.tick(); };
        await churn(s, MAX_MINTS_PER_JOB - 1, refuse);
        await tickNow();
        assert.equal(noslot().length, 0, `below ${MAX_MINTS_PER_JOB} refusals: no alert yet`);
        await churn(s, 1, refuse);
        await tickNow();
        assert.equal(noslot().length, 1, 'one noslot alert at the bound');
        assert.equal(s.auditRows.filter((r) => r.event === 'alert' && /^no-slot-repeated: /.test(r.reason || '')).length, 1);
        assert.equal(isRetired(s), false, 'still not retired');
        assert.equal(s.d.queue().length, 1, 'job 1 is still tracked');
        await churn(s, 1, refuse);
        await tickNow();
        assert.equal(noslot().length, 1, 'raised once per job, not per tick');
        assert.equal(s.auditRows.filter((r) => r.event === 'alert' && /^no-slot-repeated: /.test(r.reason || '')).length, 1, 'one audit row per job, not per tick');
    });

    test('(d-control) genuine expiries (delivered, never started) DO still retire the job', async () => {
        const s = setup();
        s.d.onJob(rec(1), 'queued');
        await churn(s, MAX_MINTS_PER_JOB, async (st, a) => {
            st.clock.t += 121 * 1000;            // delivered 120 s -> expired
            await st.assignments.sweep();
            assert.equal(st.assignments.get(a.id).state, 'expired');
        });
        s.clock.t += 1000;
        s.reportIdle();
        await s.d.tick();
        assert.equal(isRetired(s), true, 'genuine unpicked expiries must still retire a ghost');
        assert.equal(degraded(s).length, 1);
    });
});

// ---------------------------------------------------------------------------------------------
// XACA-1718-004 / -013 adversarial review. A started assignment is accounted for by IDENTITY: the stored
// report lists it (assignmentId === A.id, state !== 'idle'). Timestamps are not compared at all.
// ---------------------------------------------------------------------------------------------
describe('XACA-1718-004 adversarial: reportAccountsFor identity rule', () => {
    const two = (s, slots) => s.reports.set(MACHINE, { receivedAt: s.clock.t, capacity: capacity(), slots });
    const mac = (index, state, assignmentId) => ({ os: 'macOS', index, state, assignmentId });

    test('(e) XACA-1718-013 REPRO: a poll built BEFORE the claim but received AFTER the started ack (slot idle, A unlisted) stays reserved', async () => {
        const s = setup();
        await startA(s);
        s.clock.t += 5000;                      // receivedAt is strictly newer than startedAt
        s.reportIdle();
        s.d.onJob(rec(2), 'queued');
        await s.d.tick();
        assert.equal(mints(s).length, 1, 'newer-looking idle report that does not list A must not release the slot');
    });

    test('(f0) harness control: 2 slots, report lists A busy in slot 2 and slot 1 idle => the free slot IS used', async () => {
        const s = setup();
        const A = await startA(s);
        s.clock.t += 1000;
        two(s, [mac(1, 'idle', null), mac(2, 'busy', A.id)]);
        s.d.onJob(rec(2), 'queued');
        await s.d.tick();
        assert.equal(mints(s).length, 2, 'A accounted (busy), no reservation: slot 1 is genuinely free (no double count)');
    });

    test('(f0-running) running A listed busy by id in slot 2, slot 1 idle => no extra reservation, the free slot IS used; unlisted running A holds it', async () => {
        for (const listed of [true, false]) {
            const s = setup();
            const A = await startA(s);
            s.clock.t += 1000;
            assert.ok(s.assignments.bindJob({ owner: 'DoubleNode', repo: 'dev-team', runnerName: s.assignments.get(A.id).runnerName, jobId: 1, name: 'unit', runId: 5 }, 'in_progress'), 'precondition: A bound');
            assert.equal(s.assignments.get(A.id).state, 'running', 'precondition: A running');
            two(s, [mac(1, 'idle', null), mac(2, 'busy', listed ? A.id : null)]);
            s.d.onJob(rec(2), 'queued');
            await s.d.tick();
            assert.equal(mints(s).length, listed ? 2 : 1, listed ? 'running A accounted: slot 1 is free (no double count)' : 'running A not listed: slot 1 stays reserved');
        }
    });

    test('(f) 2 slots, slot 2 busy but NOT carrying A.id (null / other id) => A stays reserved, free slot is held, no mint', async () => {
        for (const id of [null, 'ci-other-assignment']) {
            const s = setup();
            await startA(s);
            s.clock.t += 1000;
            two(s, [mac(1, 'idle', null), mac(2, 'busy', id)]);
            s.d.onJob(rec(2), 'queued');
            await s.d.tick();
            assert.equal(mints(s).length, 1, `assignmentId=${String(id)} does not account for A`);
        }
    });

    test('(g) slot entries without an assignmentId key at all fail closed (A reserved, no mint)', async () => {
        const s = setup();
        await startA(s);
        s.clock.t += 1000;
        two(s, [{ os: 'macOS', index: 1, state: 'idle' }, { os: 'macOS', index: 2, state: 'busy' }]);
        s.d.onJob(rec(2), 'queued');
        await s.d.tick();
        assert.equal(mints(s).length, 1);
    });

    test('(h) reportAccountsFor unit table: only a non-idle slot carrying A.id accounts for it', () => {
        const A = { id: 'ci-aaaa1111' };
        const slot = (state, assignmentId) => ({ report: { slots: [{ os: 'macOS', index: 1, state: 'idle', assignmentId: null }, { os: 'macOS', index: 2, state, assignmentId }] } });
        for (const st of ['busy', 'starting', 'cleaning', 'broken']) assert.equal(reportAccountsFor(slot(st, A.id).report, A), true, st);
        assert.equal(reportAccountsFor(slot('idle', A.id).report, A), false, 'listed but idle');
        assert.equal(reportAccountsFor(slot('busy', 'ci-bbbb2222').report, A), false, 'other id');
        assert.equal(reportAccountsFor(slot('busy', null).report, A), false, 'null id');
        assert.equal(reportAccountsFor(undefined, A), false, 'no report');
        assert.equal(reportAccountsFor(null, A), false, 'null report');
        assert.equal(reportAccountsFor({}, A), false, 'no slots');
        assert.equal(reportAccountsFor({ slots: null }, A), false, 'null slots');
        assert.equal(reportAccountsFor({ slots: 'busy' }, A), false, 'slots not an array');
        assert.equal(reportAccountsFor({ slots: { 0: { state: 'busy', assignmentId: A.id } } }, A), false, 'slots object, not array');
        assert.equal(reportAccountsFor({ slots: [null, undefined, 7, {}, { state: 'busy' }] }, A), false, 'junk entries');
        assert.equal(reportAccountsFor(slot('busy', A.id).report, undefined), false, 'no assignment');
        assert.equal(reportAccountsFor(slot('busy', A.id).report, {}), false, 'assignment without id');
        assert.equal(reportAccountsFor(slot('busy', undefined).report, { id: undefined }), false, 'undefined id never matches undefined');
        assert.equal(reportAccountsFor({ receivedAt: 'garbage', slots: slot('busy', A.id).report.slots }, A), true, 'timestamps are irrelevant');
        assert.equal(reportAccountsFor({ receivedAt: 0, slots: slot('busy', A.id).report.slots }, A), true, 'even an ancient receivedAt');
    });

    test('(i) report with ISO-string receivedAt listing A busy => no mint (receivedAt format is irrelevant)', async () => {
        const s = setup();
        const A = await startA(s);
        s.clock.t += 1000;
        s.reports.set(MACHINE, { receivedAt: new Date(s.clock.t).toISOString(), capacity: capacity(), slots: [{ os: 'macOS', index: 1, state: 'busy', assignmentId: A.id }] });
        s.d.onJob(rec(2), 'queued');
        await s.d.tick();
        assert.equal(mints(s).length, 1);
    });

    test('(j) machine offline: stale report + started A => nothing minted (stale-poll refuses independently of the reservation)', async () => {
        const s = setup();
        await startA(s);
        s.clock.t += 120 * 1000;                // > pollStaleMs (30 s), < bound timeout (300 s): A still `started`
        s.d.onJob(rec(2), 'queued');
        await s.d.tick();
        assert.equal(s.assignments.get(s.assignments.snapshot()[0].id).state, 'started', 'precondition: A still started');
        assert.equal(mints(s).length, 1, 'an offline machine is not placeable, reservation or not');
    });
});

describe('XACA-1718-004 adversarial: two started assignments on a 2-slot machine', () => {
    const slots2 = (a, b) => [
        { os: 'macOS', index: 1, state: a ? 'busy' : 'idle', assignmentId: a || null },
        { os: 'macOS', index: 2, state: b ? 'busy' : 'idle', assignmentId: b || null },
    ];

    test('(k) report lists x busy only; y started but unlisted: y stays reserved, job 3 is NOT minted', async () => {
        const s = setup();
        const put = (a, b) => s.reports.set(MACHINE, { receivedAt: s.clock.t, capacity: capacity(), slots: slots2(a, b) });
        put(null, null);
        s.d.onJob(rec(1), 'queued');
        s.d.onJob(rec(2), 'queued');
        await s.d.tick();
        assert.equal(mints(s).length, 2, 'precondition: two slots, two mints');
        const [x, y] = s.assignments.snapshot().slice().sort((p, q) => (p.createdAt < q.createdAt ? -1 : 1));
        s.clock.t += 2000;
        assert.equal(s.assignments.takeForMachine(MACHINE, s.clock.t).length, 2);
        s.clock.t += 1000;
        assert.equal(s.assignments.report(x.id, MACHINE, { state: 'started' }).status, 'ok');
        assert.equal(s.assignments.report(y.id, MACHINE, { state: 'started' }).status, 'ok');
        s.clock.t += 1000;
        put(x.id, null);                         // newer than both starts, lists only x, slot 2 idle
        s.d.onJob(rec(3), 'queued');
        await s.d.tick();
        assert.equal(mints(s).length, 2, 'slot 2 is held by y (started, unlisted): job 3 must not be minted');
        s.clock.t += 1000;
        put(x.id, y.id);
        await s.d.tick();
        assert.equal(mints(s).length, 2, 'both slots busy per a report listing both');
        assert.equal(s.assignments.report(x.id, MACHINE, { state: 'completed' }).status, 'ok');
        s.clock.t += 1000;
        put(null, y.id);
        await s.d.tick();
        assert.equal(mints(s).length, 3, 'one slot freed: job 3 is minted exactly once');
    });
});
