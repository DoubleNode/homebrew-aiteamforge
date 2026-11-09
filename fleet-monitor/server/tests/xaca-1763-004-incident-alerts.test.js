//
//  xaca-1763-004-incident-alerts.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1763-004 -- ci-no-capacity / ci-queue-age are INCIDENTS: one page when the incident opens,
 * silence while it stays open, ONE ci-capacity-restored when it has stayed clear for the
 * hysteresis, and a flap inside the hysteresis never re-pages.
 *
 * Regression for 2026-11-06: a ~45 min stall re-paged every 15 min per class/label set (and the
 * types were missing from the notice catalog, so no page was ever delivered). A FAKE emitter
 * captures what would reach the operator; real store/assignments/alerts/dispatcher; no network.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const { test, describe, after } = require('node:test');
const assert = require('node:assert/strict');

const { createPoolStore } = require('../lib/ci-pool-store');
const { createAssignments } = require('../lib/ci-dispatch-assignments');
const { createAlerts, RECOVERY_TYPE } = require('../lib/ci-dispatch-alerts');
const { createDispatcher, INCIDENT_CLEAR_MS } = require('../lib/ci-dispatcher');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca1763-004-'));
after(() => fs.rmSync(TMP, { recursive: true, force: true }));

const T0 = Date.UTC(2026, 10, 6, 18, 0, 0);
const TICK = 15000;
const REPO = 'DoubleNode/dev-team';
const CREDS = { GITHUB_APP_CLIENT_ID: 'Iv-test-client', GITHUB_APP_PRIVATE_KEY: 'not-a-real-key-fixture' };
const LABELS = ['self-hosted', 'macOS', 'ARM64', 'fleet-pool', 'm1mini'];
const SET_KEY = 'arm64,fleet-pool,m1mini,macos,self-hosted';
let seq = 0;

// ---------------------------------------------------------------------------------- alerts unit
describe('ci-dispatch-alerts incidents', () => {
    function mk(clearMs = 120000) {
        const clock = { t: T0 };
        const sent = [];
        const alerts = createAlerts({ now: () => clock.t, logger: { warn() {}, log() {} }, clearMs, getEmitter: () => (n) => { sent.push(n); return { ok: true, routed: true, delivered: 1 }; } });
        return { clock, sent, alerts };
    }
    const P = { severity: 'high', title: 'stalled', body: 'b', ref: 'class:long' };

    test('opens with exactly one page; 60 later ticks (45 min, past the 15 min dedupe) page zero more', () => {
        const { clock, sent, alerts } = mk();
        assert.equal(alerts.raiseIncident('ci-no-capacity', P).opened, true);
        for (let i = 0; i < 180; i++) {
            clock.t += TICK;
            assert.equal(alerts.raiseIncident('ci-no-capacity', P).raised, false);
            alerts.sweepIncidents('ci-no-capacity', ['class:long']);
        }
        assert.equal(sent.length, 1);
        assert.deepEqual([sent[0].type, sent[0].severity, sent[0].ref], ['ci-no-capacity', 'high', 'class:long']);
        assert.equal(alerts.list().length, 1, 'the page stays visible in the ring');
    });

    test('exactly one recovery (info, same ref) after the clear-hysteresis, and none after', () => {
        const { clock, sent, alerts } = mk(120000);
        alerts.raiseIncident('ci-no-capacity', P);
        clock.t += TICK;
        assert.deepEqual(alerts.sweepIncidents('ci-no-capacity', []), []);        // clear timer starts
        clock.t += 119000;
        assert.deepEqual(alerts.sweepIncidents('ci-no-capacity', []), []);        // 1 s short of the window
        assert.equal(sent.length, 1);
        clock.t += 2000;
        assert.deepEqual(alerts.sweepIncidents('ci-no-capacity', []), ['class:long']);
        assert.equal(sent.length, 2);
        assert.deepEqual([sent[1].type, sent[1].severity, sent[1].ref], [RECOVERY_TYPE, 'info', 'class:long']);
        for (let i = 0; i < 50; i++) { clock.t += TICK; alerts.sweepIncidents('ci-no-capacity', []); }
        assert.equal(sent.length, 2);
    });

    test('flapping inside the hysteresis neither recovers nor re-pages', () => {
        const { clock, sent, alerts } = mk(120000);
        alerts.raiseIncident('ci-no-capacity', P);
        for (let i = 0; i < 12; i++) {
            clock.t += 60000; alerts.sweepIncidents('ci-no-capacity', []);                 // clear 60 s ...
            clock.t += TICK; alerts.raiseIncident('ci-no-capacity', P); alerts.sweepIncidents('ci-no-capacity', ['class:long']); // ... stalls again
        }
        assert.equal(sent.length, 1);
    });

    test('after the recovery a genuinely new stall pages again', () => {
        const { clock, sent, alerts } = mk(120000);
        alerts.raiseIncident('ci-queue-age', { severity: 'high', title: 't', ref: 'queue:x' });
        clock.t += TICK; alerts.sweepIncidents('ci-queue-age', []);
        clock.t += 121000; alerts.sweepIncidents('ci-queue-age', []);
        assert.equal(sent.length, 2);
        clock.t += TICK;
        assert.equal(alerts.raiseIncident('ci-queue-age', { severity: 'high', title: 't', ref: 'queue:x' }).opened, true);
        assert.equal(sent.length, 3);
    });

    test('incidents are independent per ref and per type', () => {
        const { clock, sent, alerts } = mk(60000);
        alerts.raiseIncident('ci-no-capacity', { title: 'a', ref: 'class:long' });
        alerts.raiseIncident('ci-no-capacity', { title: 'b', ref: 'class:short' });
        alerts.raiseIncident('ci-queue-age', { title: 'c', ref: 'class:long' });
        assert.equal(sent.length, 3);
        clock.t += TICK; alerts.sweepIncidents('ci-no-capacity', ['class:short']);
        clock.t += 61000; alerts.sweepIncidents('ci-no-capacity', ['class:short']);
        assert.deepEqual(sent.slice(3).map((n) => [n.type, n.ref]), [[RECOVERY_TYPE, 'class:long']]);
        assert.equal(alerts.openIncidents().length, 2);
    });

    test('non-incident types are unchanged: 15 min dedupe per type+ref, re-raise after', () => {
        const { clock, sent, alerts } = mk();
        for (const type of ['ci-dispatcher-degraded', 'ci-fork-job-on-pool', 'ci-job-misconfigured']) {
            assert.equal(alerts.raise(type, { title: 't', ref: 'r' }).raised, true);
            clock.t += 14 * 60000;
            assert.deepEqual(alerts.raise(type, { title: 't', ref: 'r' }), { raised: false, deduped: true });
            clock.t += 2 * 60000;
            assert.equal(alerts.raise(type, { title: 't', ref: 'r' }).raised, true);
            clock.t = T0;
        }
        assert.equal(sent.length, 6);
    });

    test('recovery text stays secret-free and bounded', () => {
        const { clock, sent, alerts } = mk(0);
        alerts.raiseIncident('ci-no-capacity', { title: 't', ref: 'class:long' });
        clock.t += 1;
        alerts.sweepIncidents('ci-no-capacity', [], () => ({ title: 'x\u0000y'.repeat(300), body: 'z' }));
        // sweep needs two observations at clearMs 0: first starts the timer at the same instant, so it fires at once
        assert.equal(sent.length, 2);
        assert.ok(sent[1].title.length <= 200);
        assert.ok(!/[\u0000-\u001f]/.test(sent[1].title));
    });
});


// ---------------------------------------------------------------------------------- XACA-1763-013
describe('incident page delivery (XACA-1763-013)', () => {
    const PAYLOAD = { severity: 'high', title: 'stalled', body: 'b', ref: 'class:long' };
    const flush = () => new Promise((r) => setImmediate(r));
    /** results: queue of values the emitter returns/rejects with per call (last one repeats). */
    function mk(results, opts = {}) {
        const clock = { t: T0 };
        const sent = [];
        let i = 0;
        const emitter = (n) => {
            sent.push(n);
            const r = results[Math.min(i++, results.length - 1)];
            if (r === 'throw') throw new Error('boom');
            if (r === 'reject') return Promise.reject(new Error('nope'));
            return r === 'sync-ok' ? { ok: true } : Promise.resolve(r);
        };
        const alerts = createAlerts({ now: () => clock.t, logger: { warn() {}, log() {} }, clearMs: 120000, getEmitter: () => (opts.noEmitter ? null : emitter) });
        return { clock, sent, alerts };
    }
    const OK = { ok: true, routed: true, delivered: 1 };
    const UNROUTED = { ok: false, routed: false, reason: 'no-route', delivered: 0 };
    const tickFor = async (s, n) => { for (let k = 0; k < n; k++) { s.clock.t += TICK; s.alerts.raiseIncident('ci-no-capacity', PAYLOAD); s.alerts.sweepIncidents('ci-no-capacity', ['class:long']); await flush(); } };

    for (const [label, bad] of [['ok:false (unrouted)', UNROUTED], ['rejected promise', 'reject'], ['throwing emitter', 'throw']]) {
        test(`undelivered page (${label}) is retried on the 15 min cadence until one delivers, then silence`, async () => {
            const s = mk([bad, bad, OK]);
            assert.equal(s.alerts.raiseIncident('ci-no-capacity', PAYLOAD).opened, true);
            await flush();
            await tickFor(s, 59);                       // 14m45s: still inside the dedupe window
            assert.equal(s.sent.length, 1);
            await tickFor(s, 1);                        // 15 min: retry #1 (still undelivered)
            assert.equal(s.sent.length, 2);
            await tickFor(s, 60);                       // +15 min: retry #2 delivers
            assert.equal(s.sent.length, 3);
            await tickFor(s, 400);                      // 100 min of silence after the delivered page
            assert.equal(s.sent.length, 3);
        });
    }

    test('no emitter at all: the incident stays unpaged and keeps retrying every 15 min', async () => {
        const s = mk([OK], { noEmitter: true });
        s.alerts.raiseIncident('ci-no-capacity', PAYLOAD);
        await tickFor(s, 61);
        assert.equal(s.alerts.openIncidents()[0].paged, false);
        assert.equal(s.alerts.list().length, 2, 'log-path alert at open and one at the 15 min retry');
    });

    test('a synchronous {ok:true} result counts as delivered', async () => {
        const s = mk(['sync-ok']);
        s.alerts.raiseIncident('ci-no-capacity', PAYLOAD);
        await flush();
        assert.equal(s.alerts.openIncidents()[0].paged, true);
        await tickFor(s, 200);
        assert.equal(s.sent.length, 1);
    });

    test('recovery notice only for an incident that was actually paged', async () => {
        const unpaged = mk([UNROUTED]);
        unpaged.alerts.raiseIncident('ci-no-capacity', PAYLOAD);
        await flush();
        unpaged.clock.t += TICK; unpaged.alerts.sweepIncidents('ci-no-capacity', []);
        unpaged.clock.t += 130000;
        assert.deepEqual(unpaged.alerts.sweepIncidents('ci-no-capacity', []), ['class:long'], 'the incident still closes');
        assert.equal(unpaged.sent.length, 1, 'no ci-capacity-restored for something nobody was told about');
        assert.equal(unpaged.alerts.openIncidents().length, 0);

        const paged = mk([OK]);
        paged.alerts.raiseIncident('ci-no-capacity', PAYLOAD);
        await flush();
        paged.clock.t += TICK; paged.alerts.sweepIncidents('ci-no-capacity', []);
        paged.clock.t += 130000; paged.alerts.sweepIncidents('ci-no-capacity', []);
        assert.deepEqual(paged.sent.map((n) => n.type), ['ci-no-capacity', RECOVERY_TYPE]);
    });

    test('a late-resolving page for an incident that has since closed and reopened does not mark the new one paged', async () => {
        const clock = { t: T0 };
        const resolvers = [];
        const sent = [];
        const alerts = createAlerts({ now: () => clock.t, logger: { warn() {}, log() {} }, clearMs: 0,
            getEmitter: () => (n) => { sent.push(n); return new Promise((res) => { if (n.type === 'ci-no-capacity') resolvers.push(res); else res({ ok: true }); }); } });
        alerts.raiseIncident('ci-no-capacity', PAYLOAD);              // incident A, page in flight
        alerts.sweepIncidents('ci-no-capacity', []);                  // clears (clearMs 0): closes silently, A unpaged
        assert.equal(alerts.openIncidents().length, 0);
        alerts.raiseIncident('ci-no-capacity', PAYLOAD);              // incident B opens
        resolvers[0]({ ok: true });                                   // A's page finally delivers
        await flush();
        assert.equal(alerts.openIncidents()[0].paged, false, 'B has not been paged by A\'s late result');
        assert.equal(sent.filter((n) => n.type === RECOVERY_TYPE).length, 0, 'and A never announced a recovery');
        resolvers[1]({ ok: true });
        await flush();
        assert.equal(alerts.openIncidents()[0].paged, true);
    });
});

// ---------------------------------------------------------------------------------- dispatcher
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
    const sent = [];
    // The REAL alerts shim with the production hysteresis wiring (wireCiPool passes INCIDENT_CLEAR_MS) and a FAKE emitter.
    const alerts = createAlerts({ now: () => clock.t, logger, clearMs: INCIDENT_CLEAR_MS, getEmitter: () => (n) => { sent.push(n); return Promise.resolve({ ok: true, routed: true, delivered: 1 }); } });
    const reports = new Map();
    const watcher = { async runCycle() { return TICK; }, stop() {} };
    const env = Object.assign({ FLEET_CI_DISPATCHER: opts.mode || 'shadow' }, CREDS);
    const d = createDispatcher({
        env,
        store, assignments, alerts, watcher, reports, logger, now: () => clock.t,
        audit: { append() {} }, setTimer: () => ({}), clearTimer() {},
        routeCoverage: opts.routeCoverage,
    });
    const tickFor = async (n) => { for (let i = 0; i < n; i++) { clock.t += TICK; await d.tick(); } };
    const ofType = (t) => sent.filter((n) => n.type === t);
    d.__env = () => env;
    return { d, clock, store, sent, lines, tickFor, ofType, alerts };
}

describe('ci-no-capacity incident (dispatcher, live mode)', () => {
    async function stalled() {
        const s = setup({ mode: '1' });
        s.store.upsertMachine('m1mini', { paused: true });   // no eligible machine: the 2026-11-06 shape
        s.d.onJob(rec(1, 1), 'queued');
        s.d.onJob(rec(2, 1, { name: 'shell-suite' }), 'queued');   // second class
        await s.tickFor(10);                                  // > NO_CAPACITY_AFTER_MS (120 s), incident opens
        return s;
    }

    test('one page per class at open, then ZERO over 200 more ticks (50 min)', async () => {
        const s = await stalled();
        assert.deepEqual(s.ofType('ci-no-capacity').map((n) => n.ref).sort(), ['class:long', 'class:short']);
        const before = s.ofType('ci-no-capacity').length;
        await s.tickFor(200);
        assert.equal(s.ofType('ci-no-capacity').length, before);
        assert.equal(s.ofType(RECOVERY_TYPE).length, 0);
        assert.equal(s.d.noCapacity().active, true, 'Fleet Monitor view (derived) still shows the stall');
    });

    test('exactly one recovery per class once the stall has been clear for INCIDENT_CLEAR_MS', async () => {
        const s = await stalled();
        s.store.upsertMachine('m1mini', { paused: false });
        s.d.onJob(rec(1, 1), 'completed'); s.d.onJob(rec(2, 1, { name: 'shell-suite' }), 'completed');
        await s.tickFor(2);
        assert.equal(s.ofType(RECOVERY_TYPE).length, 0, 'hysteresis: not yet');
        await s.tickFor(Math.ceil(INCIDENT_CLEAR_MS / TICK) + 1);
        const rc = s.ofType(RECOVERY_TYPE);
        assert.deepEqual(rc.map((n) => [n.ref, n.severity]).sort(), [['class:long', 'info'], ['class:short', 'info']]);
        await s.tickFor(100);
        assert.equal(s.ofType(RECOVERY_TYPE).length, 2);
        assert.equal(s.ofType('ci-no-capacity').length, 2);
    });

    test('flapping inside the hysteresis does not re-page and does not recover', async () => {
        const s = setup({ mode: '1' });
        s.store.upsertMachine('m1mini', { paused: true });
        s.d.onJob(rec(1, 1), 'queued');
        await s.tickFor(10);
        assert.equal(s.ofType('ci-no-capacity').length, 1);
        for (let i = 0; i < 10; i++) {
            s.d.onJob(rec(1, 1), 'completed');                // clears for ~30 s ...
            await s.tickFor(2);
            s.d.onJob(rec(1, 1), 'queued');                   // ... the stall is back (noCapSince restarts)
            await s.tickFor(9);                               // 135 s > NO_CAPACITY_AFTER_MS: alertable again
        }
        assert.equal(s.ofType('ci-no-capacity').length, 1);
        assert.equal(s.ofType(RECOVERY_TYPE).length, 0);
    });

    // XACA-1763-014: while not live we cannot observe the stall, so "no longer stalled" is absence of
    // evidence. Those incidents CLOSE SILENTLY (a frozen incident would linger invisibly, and a false
    // "restored" tells the operator the pool is healthy when nobody can see).
    test('switching to shadow mid-incident closes silently: no false ci-capacity-restored', async () => {
        const s = await stalled();
        assert.equal(s.ofType('ci-no-capacity').length, 2);
        s.d.__env().FLEET_CI_DISPATCHER = 'shadow';
        await s.tickFor(Math.ceil(INCIDENT_CLEAR_MS / TICK) + 5);
        assert.equal(s.ofType(RECOVERY_TYPE).length, 0);
        assert.equal(s.alerts.openIncidents().filter((i) => i.type === 'ci-no-capacity').length, 0, 'closed, not frozen');
    });

    test('going dormant mid-incident closes silently too', async () => {
        const s = await stalled();
        s.d.__env().FLEET_CI_DISPATCHER = '0';
        await s.tickFor(Math.ceil(INCIDENT_CLEAR_MS / TICK) + 5);
        assert.equal(s.ofType(RECOVERY_TYPE).length, 0);
        assert.equal(s.alerts.openIncidents().length, 0);
    });

    test('a pinned job whose host leaves live mid-incident closes that class silently', async () => {
        const s = setup({ mode: '1' });
        s.store.upsertMachine('m1mini', { paused: true, mode: 'live' });
        const pinned = rec(1, 1, { labels: ['self-hosted', 'macOS', 'ARM64', 'm1mini'] });   // no pool label: accepted via the host label only
        s.d.onJob(pinned, 'queued');
        await s.tickFor(10);
        assert.equal(s.ofType('ci-no-capacity').length, 1, 'precondition: the pinned job opened an incident');
        s.store.upsertMachine('m1mini', { mode: 'shadow' });  // pinned host leaves live: job is now excluded
        await s.tickFor(Math.ceil(INCIDENT_CLEAR_MS / TICK) + 5);
        assert.equal(s.ofType(RECOVERY_TYPE).filter((n) => n.ref === 'class:short').length, 0);
    });

    test('mixed class: a live stalled job plus a same-class job pinned to a shadow host still gets ONE recovery with hysteresis', async () => {
        const s = setup({ mode: '1' });
        s.store.upsertMachine('m1mini', { paused: true, mode: 'live' });
        s.store.upsertMachine('m4mini', { enabled: true, mode: 'shadow' });
        s.d.onJob(rec(1, 1), 'queued');
        await s.tickFor(10);
        assert.equal(s.ofType('ci-no-capacity').length, 1, 'precondition: the stall opened one incident');
        // Same class, pinned (host label only) to a host that is not live: excluded from live evaluation.
        s.d.onJob(rec(2, 1, { labels: ['self-hosted', 'macOS', 'ARM64', 'm4mini'] }), 'queued');
        await s.tickFor(2);
        s.store.upsertMachine('m1mini', { paused: false });
        s.d.onJob(rec(1, 1), 'completed');   // the stalled job is served: an OBSERVED recovery
        await s.tickFor(4);                  // ~60 s clear, well inside the 5 min hysteresis
        assert.equal(s.alerts.openIncidents().length, 1, 'incident stays open through the hysteresis (no silent close)');
        // Flap: the stall returns inside the hysteresis. It must NOT re-page.
        s.store.upsertMachine('m1mini', { paused: true });
        s.d.onJob(rec(3, 1), 'queued');
        await s.tickFor(12);
        assert.equal(s.ofType('ci-no-capacity').length, 1, 'a flap inside the hysteresis never re-pages');
        s.store.upsertMachine('m1mini', { paused: false });
        s.d.onJob(rec(3, 1), 'completed');
        await s.tickFor(Math.ceil(INCIDENT_CLEAR_MS / TICK) + 5);
        assert.deepEqual(s.ofType(RECOVERY_TYPE).map((n) => n.ref), ['class:short'], 'exactly one recovery');
        assert.equal(s.alerts.openIncidents().length, 0);
    });

    test('real recovery in live mode still notifies (control for the silent closes)', async () => {
        const s = await stalled();
        s.store.upsertMachine('m1mini', { paused: false });
        s.d.onJob(rec(1, 1), 'completed'); s.d.onJob(rec(2, 1, { name: 'shell-suite' }), 'completed');
        await s.tickFor(Math.ceil(INCIDENT_CLEAR_MS / TICK) + 3);
        assert.equal(s.ofType(RECOVERY_TYPE).filter((n) => n.ref.startsWith('class:')).length, 2);
    });

    test('shadow mode still raises nothing for ci-no-capacity (existing rule)', async () => {
        const s = setup({ mode: 'shadow' });
        s.d.onJob(rec(1, 1), 'queued');
        await s.tickFor(40);
        assert.equal(s.ofType('ci-no-capacity').length, 0);
        assert.equal(s.ofType(RECOVERY_TYPE).length, 0);
    });
});

describe('ci-queue-age incident (dispatcher)', () => {
    const queueN = (s, n, minutesOld) => { for (let i = 1; i <= n; i++) s.d.onJob(rec(i, minutesOld - i * 0.01), 'queued'); };

    test('one page per set at open, zero over 200 ticks, one recovery on drain, none after', async () => {
        const s = setup();
        queueN(s, 5, 32);
        await s.tickFor(1);
        assert.deepEqual(s.ofType('ci-queue-age').map((n) => [n.ref, n.severity]), [[`queue:${SET_KEY}`, 'high']]);
        await s.tickFor(200);
        assert.equal(s.sent.length, 1);
        for (let i = 1; i <= 5; i++) s.d.onJob(rec(i, 32), 'completed');
        await s.tickFor(2);
        assert.equal(s.ofType(RECOVERY_TYPE).length, 0, 'hysteresis: not yet');
        await s.tickFor(Math.ceil(INCIDENT_CLEAR_MS / TICK) + 1);
        assert.deepEqual(s.ofType(RECOVERY_TYPE).map((n) => [n.ref, n.severity]), [[`queue:${SET_KEY}`, 'info']]);
        await s.tickFor(100);
        assert.equal(s.sent.length, 2);
    });

    test('flapping (drain for 30 s, jobs come back still old) does not re-page', async () => {
        const s = setup();
        queueN(s, 3, 32);
        await s.tickFor(1);
        for (let i = 0; i < 10; i++) {
            for (let j = 1; j <= 3; j++) s.d.onJob(rec(j, 32), 'completed');
            await s.tickFor(2);
            queueN(s, 3, 32);
            await s.tickFor(2);
        }
        assert.equal(s.sent.length, 1);
    });
});

describe('fleet-route coverage warning (XACA-1763-004)', () => {
    test('warns ONCE, naming the PUT, when the incident types are not routed', async () => {
        const seen = [];
        const s = setup({ mode: '1', routeCoverage: (types) => { seen.push(types); return { configured: true, missing: ['ci-no-capacity', 'ci-queue-age', 'ci-capacity-restored'] }; } });
        await s.tickFor(5);
        const w = s.lines.filter((l) => /WARNING.*not routed in the fleet routes/.test(l));
        assert.equal(w.length, 1);
        assert.match(w[0], /ci-no-capacity, ci-queue-age, ci-capacity-restored/);
        assert.match(w[0], /PUT \/api\/notify\/fleet-routes/);
        assert.equal(seen.length, 1, 'checked once, then never again');
        assert.deepEqual(seen[0], ['ci-no-capacity', 'ci-queue-age', 'ci-capacity-restored']);
    });

    test('hub not wired yet (null) defers to the next tick; fully routed stays silent', async () => {
        let n = 0;
        const s = setup({ mode: '1', routeCoverage: () => (++n < 3 ? null : { configured: true, missing: [] }) });
        await s.tickFor(6);
        assert.equal(n, 3, 'retried until the hub answered, then stopped');
        assert.equal(s.lines.filter((l) => /not routed/.test(l)).length, 0);
    });

    test('re-checks hourly (not once per process): a route that is removed later is warned about again, without per-tick spam', async () => {
        let missing = [];
        let n = 0;
        const s = setup({ mode: '1', routeCoverage: () => { n++; return { configured: true, missing: missing.slice() }; } });
        await s.tickFor(10);
        assert.equal(n, 1);
        missing = ['ci-queue-age'];
        await s.tickFor(200);                                  // 50 min: still inside the hour
        assert.equal(n, 1, 'no re-check inside the hour');
        await s.tickFor(60);                                   // crosses 60 min
        assert.equal(n, 2);
        assert.equal(s.lines.filter((l) => /WARNING.*not routed/.test(l) && /ci-queue-age/.test(l)).length, 1);
        await s.tickFor(240);                                  // another hour: warns again, once
        assert.equal(n, 3);
        assert.equal(s.lines.filter((l) => /WARNING.*not routed/.test(l)).length, 2);
    });

    test('a throwing coverage reader never breaks the tick', async () => {
        const s = setup({ mode: '1', routeCoverage: () => { throw new Error('boom'); } });
        await s.tickFor(3);
        assert.ok(s.d.status());
    });
});
