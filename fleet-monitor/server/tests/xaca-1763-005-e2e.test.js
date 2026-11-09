//
//  xaca-1763-005-e2e.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1763-005 -- END-TO-END: sandboxed CI dispatcher -> REAL ci-dispatch-alerts -> REAL
 * emitFleetNotice -> REAL notify store (bundled catalog + fleet routes) -> REAL dispatcher ->
 * REAL receipt log, with the in-memory test provider as the only fake and a fake clock.
 *
 * The 004 suite proves the page-once logic against a FAKE emitter; that cannot see the 2026-11-06
 * root cause (the ci-* types were missing from the catalog, so every receipt was ok:false
 * "unknown notice type" and nobody was paged). This suite asserts on RECEIPTS.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { describe, test, after } = require('node:test');
const assert = require('node:assert/strict');

const { createPoolStore, GIB, DEFAULT_THRESHOLDS } = require('../lib/ci-pool-store');
const { createAssignments } = require('../lib/ci-dispatch-assignments');
const { createAlerts, RECOVERY_TYPE } = require('../lib/ci-dispatch-alerts');
const { createDispatcher, INCIDENT_CLEAR_MS } = require('../lib/ci-dispatcher');
const { createNotifyStore } = require('../lib/notify-store');
const { createNotifyDispatcher } = require('../lib/notify-dispatcher');
const { createReceiptLog } = require('../lib/notify-receipts');
const { createProviderRegistry, createTestProvider } = require('../lib/notify-providers');
const fleetNotices = require('../lib/fleet-notices');
const P = require('../lib/ci-dispatch-placement');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca1763-005-'));
after(() => { fs.rmSync(TMP, { recursive: true, force: true }); fleetNotices._reset(); });

const T0 = Date.UTC(2026, 10, 6, 18, 0, 0);
const TICK = 15000;
const REPO = 'DoubleNode/dev-team';
const CREDS = { GITHUB_APP_CLIENT_ID: 'Iv-test-client', GITHUB_APP_PRIVATE_KEY: 'not-a-real-key-fixture' };
const LABELS = ['self-hosted', 'macOS', 'ARM64', 'fleet-pool', 'm1mini'];
// The notify layer sanitises ref (commas become '-'), so receipts carry the sanitised form.
const QUEUE_REF = 'queue:arm64-fleet-pool-m1mini-macos-self-hosted';
const CI_TYPES = ['ci-no-capacity', 'ci-queue-age', RECOVERY_TYPE];
let seq = 0;

function rec(jobId, minutesOld) {
    return {
        key: `${REPO}#${jobId}#1`, owner: 'DoubleNode', repo: 'dev-team', runId: 5, runAttempt: 1, jobId,
        name: 'unit', labels: LABELS.slice(), status: 'queued', conclusion: null, runnerName: null,
        createdAt: new Date(T0 - minutesOld * 60000).toISOString(), firstSeenAt: new Date(T0).toISOString(),
        inProgressAt: null, completedAt: null,
        run: { event: 'push', repoFullName: REPO, headRepoFullName: REPO },
    };
}

/** Full sandboxed stack. routedTypes: which notice types the fleet routes send to the test connection. */
function stack({ mode = 'shadow', routedTypes = CI_TYPES } = {}) {
    const dir = path.join(TMP, `s${++seq}`);
    fs.mkdirSync(dir, { recursive: true });
    const clock = { t: T0 };
    const lines = [];
    const logger = { log: (m) => lines.push(String(m)), warn: (m) => lines.push(String(m)), error: (m) => lines.push(String(m)) };

    // ---- real notify path (only the provider is fake) ----
    const provider = createTestProvider();
    const registry = createProviderRegistry();
    registry.register('test', provider);
    const nstore = createNotifyStore({ file: path.join(dir, 'notify.json'), key: crypto.randomBytes(32).toString('hex'), registry });
    const receipts = createReceiptLog({ file: path.join(dir, 'receipts.jsonl') });
    const ndisp = createNotifyDispatcher({ store: nstore, registry, receipts });
    nstore.createConnection({ id: 'conn-a', provider: 'test', label: 'a', secrets: { token: 'tok' } });
    const routes = {};
    for (const t of routedTypes) routes[t] = ['conn-a'];
    if (routedTypes.length) nstore.setFleetRoutes({ routes });
    const fn = fleetNotices.configure({ dispatcher: ndisp, store: nstore, receipts, logger });
    const pending = [];
    // Exactly what the production shim does: fire and forget (the promise is only kept so the test can flush).
    // The shim reads the returned promise's {ok} to decide whether the incident was actually paged (XACA-1763-013).
    const emitter = (n) => { const p = fn.emitFleetNotice(n); pending.push(p); return p; };

    // ---- sandboxed CI dispatcher ----
    const pstore = createPoolStore({ file: path.join(dir, 'ci-pool.json'), logger: { error() {} } });
    pstore.load();
    assert.equal(pstore.updateConfig({ allowlist: [REPO] }).ok, true);
    assert.equal(pstore.upsertMachine('m1mini', { enabled: true }).ok, true);
    const gh = { async generateJitConfig() { return { runnerId: 1, encodedJitConfig: 'JITSENTINEL' }; }, async deleteRunner() { return { deleted: true }; } };
    const assignments = createAssignments({ file: path.join(dir, 'state.json'), github: gh, audit: { append() {} }, now: () => clock.t, logger: { error() {}, warn() {} } });
    const alerts = createAlerts({ now: () => clock.t, logger, clearMs: INCIDENT_CLEAR_MS, getEmitter: () => emitter });
    const d = createDispatcher({
        env: Object.assign({ FLEET_CI_DISPATCHER: mode }, CREDS),
        store: pstore, assignments, alerts, watcher: { async runCycle() { return TICK; }, stop() {} }, reports: new Map(),
        logger, now: () => clock.t, audit: { append() {} }, setTimer: () => ({}), clearTimer() {},
        routeCoverage: (types) => fleetNotices.fleetRouteCoverage(types),
    });
    const tickFor = async (n) => { for (let i = 0; i < n; i++) { clock.t += TICK; await d.tick(); } await Promise.all(pending.splice(0)); };
    // Receipts are the ground truth: what the notify hub recorded as delivered (ok:true) or refused.
    const fleetReceipts = () => receipts.recent({ team: 'fleet' });
    const okReceipts = (type) => fleetReceipts().filter((r) => r.type === type && r.ok === true);
    const allReceipts = (type) => fleetReceipts().filter((r) => r.type === type);
    return { d, clock, pstore, provider, lines, tickFor, okReceipts, allReceipts, fleetReceipts, nstore, routes };
}

const clearTicks = () => Math.ceil(INCIDENT_CLEAR_MS / TICK) + 2;

describe('(a)+(b) no-capacity stall > 1 h of fake time, then recovery, through the real notify path', () => {
    async function stalled(opts) {
        const s = stack(Object.assign({ mode: '1' }, opts));
        s.pstore.upsertMachine('m1mini', { paused: true });
        s.d.onJob(rec(1, 1), 'queued');
        await s.tickFor(10);
        return s;
    }

    test('exactly ONE ok:true ci-no-capacity receipt across 90 min of stall (360 ticks); zero "unknown notice type"', async () => {
        const s = await stalled();
        const t0 = s.clock.t;
        await s.tickFor(360);
        assert.ok(s.clock.t - t0 >= 60 * 60000, 'stall spans well over an hour of fake time');
        const ok = s.okReceipts('ci-no-capacity'); // (a 4th-minute ci-queue-age page for the same job is a different incident type and is expected)
        assert.equal(ok.length, 1);
        assert.equal(ok[0].ref, 'class:short');
        assert.equal(s.allReceipts('ci-no-capacity').length, 1, 'no failed receipts either');
        assert.equal(s.fleetReceipts().filter((r) => /unknown notice type/.test(r.error || '')).length, 0);
        assert.equal(s.provider.calls.filter((c) => c.message.type === 'ci-no-capacity').length, 1, 'the provider was called once for the page');
        assert.equal(s.okReceipts(RECOVERY_TYPE).length, 0, 'no recovery while still stalled');
    });

    test('recovery produces exactly ONE ok:true ci-capacity-restored receipt, and no more afterwards', async () => {
        const s = await stalled();
        await s.tickFor(240);
        s.pstore.upsertMachine('m1mini', { paused: false });
        s.d.onJob(rec(1, 1), 'completed');
        await s.tickFor(clearTicks());
        // One recovery PER incident: the stall's class:short, plus the queue-age incident the same 4 h-old
        // job also opened (a distinct incident type). Never more than one each.
        const refs = () => s.okReceipts(RECOVERY_TYPE).map((r) => r.ref).sort();
        assert.deepEqual(refs(), ['class:short', QUEUE_REF]);
        await s.tickFor(200);
        assert.deepEqual(refs(), ['class:short', QUEUE_REF]);
        assert.equal(s.okReceipts('ci-no-capacity').length, 1);
        assert.equal(s.allReceipts(RECOVERY_TYPE).length, 2, 'no failed recovery receipts');
        assert.equal(s.provider.calls.filter((c) => c.message.type === RECOVERY_TYPE && c.message.ref === 'class:short').length, 1);
    });

    test('NEGATIVE CONTROL: types absent from fleet routes -> zero ok:true receipts and the WARNING is logged', async () => {
        const s = await stalled({ routedTypes: ['machine-offline'] });
        await s.tickFor(240);
        assert.equal(s.okReceipts('ci-no-capacity').length, 0);
        assert.equal(s.provider.calls.length, 0, 'nothing reached the provider');
        assert.ok(s.lines.some((l) => /WARNING.*not routed in the fleet routes/.test(l) && /ci-no-capacity/.test(l)));
    });

    test('NEGATIVE CONTROL: with no fleet routes at all, still zero ok:true receipts', async () => {
        const s = await stalled({ routedTypes: [] });
        await s.tickFor(40);
        assert.equal(s.okReceipts('ci-no-capacity').length, 0);
        assert.equal(s.provider.calls.length, 0);
    });
});

describe('(e) undelivered page is retried until delivered (XACA-1763-013)', () => {
    test('unrouted at open: no ok receipt; retried each 15 min; once routed, ONE delivery, then silence; recovery announced', async () => {
        const s = stack({ mode: '1', routedTypes: [] });
        s.pstore.upsertMachine('m1mini', { paused: true });
        s.d.onJob(rec(1, 1), 'queued');
        await s.tickFor(10);
        assert.equal(s.okReceipts('ci-no-capacity').length, 0);
        await s.tickFor(120);                                  // 30 min: still unrouted, still not paged
        assert.equal(s.okReceipts('ci-no-capacity').length, 0);
        s.nstore.setFleetRoutes({ routes: { 'ci-no-capacity': ['conn-a'], 'ci-queue-age': ['conn-a'], [RECOVERY_TYPE]: ['conn-a'] } });
        await s.tickFor(70);                                   // next 15 min retry delivers
        assert.equal(s.okReceipts('ci-no-capacity').length, 1);
        await s.tickFor(400);                                  // 100 min more: silent
        assert.equal(s.okReceipts('ci-no-capacity').length, 1);
        s.pstore.upsertMachine('m1mini', { paused: false });
        s.d.onJob(rec(1, 1), 'completed');
        await s.tickFor(clearTicks());
        assert.equal(s.okReceipts(RECOVERY_TYPE).filter((r) => r.ref === 'class:short').length, 1, 'paged incident is announced');
    });

    test('unrouted for the whole incident: it clears with NO recovery receipt of any kind', async () => {
        const s = stack({ mode: '1', routedTypes: [] });
        s.pstore.upsertMachine('m1mini', { paused: true });
        s.d.onJob(rec(1, 1), 'queued');
        await s.tickFor(10);
        s.pstore.upsertMachine('m1mini', { paused: false });
        s.d.onJob(rec(1, 1), 'completed');
        await s.tickFor(clearTicks() + 10);
        assert.equal(s.provider.calls.length, 0);
        assert.equal(s.allReceipts(RECOVERY_TYPE).length, 0);
        // An unrouted emit leaves no receipt, so also assert nothing was even ATTEMPTED for the recovery type.
        assert.equal(s.lines.filter((l) => /\[FLEET-NOTICE\] ci-capacity-restored/.test(l)).length, 0);
    });
});

describe('(c) ci-queue-age incident through the real notify path', () => {
    test('one ok:true page for a 32 min-old queue held 90 min, one ok:true recovery after drain', async () => {
        const s = stack();
        for (let i = 1; i <= 5; i++) s.d.onJob(rec(i, 32 - i * 0.01), 'queued');
        await s.tickFor(361);
        const ok = s.okReceipts('ci-queue-age');
        assert.equal(ok.length, 1);
        assert.equal(ok[0].ref, QUEUE_REF);
        assert.equal(s.allReceipts('ci-queue-age').length, 1);
        for (let i = 1; i <= 5; i++) s.d.onJob(rec(i, 32), 'completed');
        await s.tickFor(clearTicks());
        const rc = s.okReceipts(RECOVERY_TYPE);
        assert.equal(rc.length, 1);
        assert.equal(rc[0].ref, QUEUE_REF);
        await s.tickFor(100);
        assert.equal(s.okReceipts(RECOVERY_TYPE).length, 1);
        assert.equal(s.okReceipts('ci-queue-age').length, 1);
    });

    test('NEGATIVE CONTROL: unrouted -> zero ok:true receipts', async () => {
        const s = stack({ routedTypes: [] });
        for (let i = 1; i <= 5; i++) s.d.onJob(rec(i, 32 - i * 0.01), 'queued');
        await s.tickFor(40);
        assert.equal(s.okReceipts('ci-queue-age').length, 0);
    });
});

describe('(d) placement: load1 spike vs sustained load', () => {
    const NOW = 1_800_000_000_000;
    const report = (cap) => ({
        receivedAt: NOW - 5000,
        capacity: Object.assign({
            memTotalBytes: 16 * GIB, memReclaimableBytes: 4 * GIB, memFreePct: 45, swapUsedBytes: 1 * GIB, swapTotalBytes: 3 * GIB,
            load1: 2, load5: 2, load15: 2, ncpu: 10, teamSessions: 6, vmState: 'running',
        }, cap),
        slots: [{ os: 'Linux', index: 1, state: 'idle', assignmentId: null }],
    });
    const machine = { id: 'm4mini', enabled: true, paused: false, prefers: null, thresholds: {} };
    const job = { name: 'x', labels: ['self-hosted', 'Linux', 'ARM64', 'fleet-pool'] };
    const run = (cap) => P.isEligible(machine, report(cap), job, { now: NOW, thresholds: DEFAULT_THRESHOLDS });

    test('load1/ncpu = 1.2 (>= 0.75) with low load5 is eligible', () => {
        const r = run({ load1: 12, load5: 2 });
        assert.equal(r.eligible, true, r.reasons.join());
    });
    test('load1 and load5 both >= 0.75/cpu is refused load-high', () => {
        const r = run({ load1: 12, load5: 8 });
        assert.equal(r.eligible, false);
        assert.ok(r.reasons.includes('load-high'));
    });
});
