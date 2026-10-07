//
//  xaca-1445-shadow-mode.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1445-011 -- dispatcher SHADOW mode + the per-job decision record (plan D2/D3).
 * Same harness as xaca-1441-dispatcher.test.js: real store / assignments / alerts / placement /
 * policy over a temp dir, fake GitHub (every mint is counted), fake watcher, fake clock.
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
const { createDispatcher, globalMode } = require('../lib/ci-dispatcher');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca1445-011-shadow-'));
after(() => fs.rmSync(TMP, { recursive: true, force: true }));

const T0 = Date.UTC(2026, 9, 6, 12, 0, 0);
const CREDS = { GITHUB_APP_CLIENT_ID: 'Iv-test-client', GITHUB_APP_PRIVATE_KEY: 'not-a-real-key-fixture' };
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
        key: `${REPO}#${jobId}#1`, owner: 'DoubleNode', repo: 'dev-team', runId: 5000 + jobId, runAttempt: 1, jobId,
        name: 'unit', labels: POOL.slice(), status: 'queued', conclusion: null, runnerName: null,
        createdAt: new Date(T0).toISOString(), firstSeenAt: new Date(T0 + jobId).toISOString(),
        inProgressAt: null, completedAt: null,
        run: { event: 'push', repoFullName: REPO, headRepoFullName: REPO },
    }, over);
}

function setup(opts = {}) {
    const dir = path.join(TMP, `s${++seq}`);
    fs.mkdirSync(dir, { recursive: true });
    const logFile = opts.logFile || path.join(dir, 'decisions.jsonl');
    const clock = { t: T0 };
    const store = createPoolStore({ file: path.join(dir, 'ci-pool.json'), logger: { error() {} } });
    store.load();
    assert.equal(store.updateConfig({ allowlist: [REPO] }).ok, true);
    const reports = new Map();
    for (const [id, prefers] of [['m4mini', 'long'], ['m1mini', 'short']]) {
        if (opts.machines && !opts.machines.includes(id)) continue;
        assert.equal(store.upsertMachine(id, Object.assign({ enabled: true, prefers }, (opts.modes || {})[id] ? { mode: opts.modes[id] } : {})).ok, true);
    }
    const ghCalls = [];
    const gh = {
        async generateJitConfig(a) { ghCalls.push(['mint', a]); return { runnerId: 9000 + ghCalls.length, encodedJitConfig: `JITSENTINEL-${ghCalls.length}` }; },
        async deleteRunner(a) { ghCalls.push(['delete', a]); return { deleted: true }; },
    };
    const assignments = createAssignments({ file: path.join(dir, 'state.json'), github: gh, audit: { append() {} }, now: () => clock.t, logger: { error() {}, warn() {} } });
    const lines = [];
    const logger = { log: (m) => lines.push(m), warn: (m) => lines.push(m), error: (m) => lines.push(m) };
    const alerts = createAlerts({ now: () => clock.t, logger, getEmitter: () => null });
    const timers = { set: [] };
    const env = Object.assign({ FLEET_CI_DISPATCHER: 'shadow', FLEET_CI_SHADOW_LOG: logFile }, CREDS, opts.env || {});
    const watcher = { cycles: 0, async runCycle() { this.cycles++; return 15000; }, stop() {} };
    const d = createDispatcher({
        env, store, assignments, alerts, watcher, reports, logger, now: () => clock.t,
        setTimer: (fn, ms) => { const h = { fn, ms }; timers.set.push(h); return h; },
        clearTimer() {},
    });
    const report = (id, over = {}, n = 1) => reports.set(id, { receivedAt: clock.t, capacity: capacity(over.capacity), slots: over.slots || slots(n) });
    const records = () => (fs.existsSync(logFile) ? fs.readFileSync(logFile, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l)) : []);
    return { d, store, assignments, alerts, reports, report, clock, ghCalls, lines, timers, watcher, logFile, records, env };
}

const mints = (s) => s.ghCalls.filter((c) => c[0] === 'mint');

describe('mode parsing (fail closed)', () => {
    test('1 = live, shadow = shadow (any case), unset/0 = dormant, anything else = dormant AND flagged unknown', () => {
        assert.equal(globalMode({ FLEET_CI_DISPATCHER: '1' }).mode, 'live');
        assert.equal(globalMode({ FLEET_CI_DISPATCHER: 'shadow' }).mode, 'shadow');
        assert.equal(globalMode({ FLEET_CI_DISPATCHER: ' SHADOW ' }).mode, 'shadow');
        for (const v of [undefined, '', '0']) assert.deepEqual([globalMode({ FLEET_CI_DISPATCHER: v }).mode, globalMode({ FLEET_CI_DISPATCHER: v }).unknown], ['dormant', false]);
        for (const v of ['true', 'live', 'shdow', 'on', '2']) assert.deepEqual([globalMode({ FLEET_CI_DISPATCHER: v }).mode, globalMode({ FLEET_CI_DISPATCHER: v }).unknown], ['dormant', true]);
    });

    test('an unknown global mode is dormant with a logged reason: no cycle, no mint, no record, no timer', async () => {
        const s = setup({ env: { FLEET_CI_DISPATCHER: 'shdow' } });
        s.report('m4mini');
        assert.equal(s.d.isEnabled(), false);
        assert.equal(s.d.start(), false);
        s.d.onJob(rec(1), 'queued');
        assert.equal(await s.d.tick(), null);
        assert.equal(s.d.status().mode, 'dormant');
        assert.equal(s.watcher.cycles, 0);
        assert.equal(s.timers.set.length, 0);
        assert.equal(mints(s).length, 0);
        assert.equal(fs.existsSync(s.logFile), false);
        assert.ok(s.lines.some((l) => /dormant/.test(l) && /unknown mode "shdow"/.test(l)), s.lines.join('\n'));
    });

    test('status() reports the effective mode', () => {
        assert.equal(setup().d.status().mode, 'shadow');
        assert.equal(setup({ env: { FLEET_CI_DISPATCHER: '1' } }).d.status().mode, 'live');
        assert.equal(setup({ env: { FLEET_CI_DISPATCHER: '' } }).d.status().mode, 'dormant');
    });

    test('shadow still needs App credentials (the watcher polls GitHub)', () => {
        const s = setup({ env: { GITHUB_APP_PRIVATE_KEY: '' } });
        assert.equal(s.d.isEnabled(), false);
    });
});

describe('global shadow never mints', () => {
    test('queued jobs with ample capacity: a decision is recorded, NOTHING is minted or tracked as supply', async () => {
        const s = setup();
        s.report('m4mini', {}, 2); s.report('m1mini', {}, 2);
        for (const id of [1, 2, 3]) s.d.onJob(rec(id), 'queued');
        await s.d.tick(); await s.d.tick();
        assert.equal(mints(s).length, 0, 'shadow must not call the GitHub runner-creation API');
        assert.equal(s.ghCalls.length, 0);
        assert.equal(s.assignments.snapshot().length, 0, 'shadow must not create an assignment (no in-flight demand)');
        assert.equal(s.assignments.outstandingBySet().size, 0);
        const r = s.records();
        assert.equal(r.length, 3);
        assert.ok(r.every((x) => x.mode === 'shadow' && x.decision.host !== null && /^(placed|pinned:)/.test(x.decision.reason)));
        assert.equal(s.d.status().decisionsRecorded, 3);
    });

    test('shadow raises no no-capacity alert even past the wait threshold', async () => {
        const s = setup();
        s.report('m4mini', { capacity: { memFreePct: 1 } }); s.report('m1mini', { capacity: { memFreePct: 1 } });
        s.d.onJob(rec(1), 'queued');
        await s.d.tick();
        s.clock.t += 10 * 60 * 1000;
        s.report('m4mini', { capacity: { memFreePct: 1 } }); s.report('m1mini', { capacity: { memFreePct: 1 } });
        await s.d.tick();
        assert.equal(s.alerts.list().filter((a) => a.type === 'ci-no-capacity').length, 0);
        assert.equal(s.records()[0].decision.reason, 'no-capacity');
        assert.equal(s.records()[0].decision.host, null);
    });
});

describe('per-host shadow while the global mode is live (rollback R1)', () => {
    test('a job decided onto a shadow host is recorded (mode shadow) but never minted', async () => {
        const s = setup({ env: { FLEET_CI_DISPATCHER: '1' }, machines: ['m4mini'], modes: { m4mini: 'shadow' } });
        s.report('m4mini');
        s.d.onJob(rec(1, { labels: POOL.concat('m4mini') }), 'queued');
        await s.d.tick(); await s.d.tick();
        assert.equal(mints(s).length, 0);
        assert.equal(s.assignments.snapshot().length, 0);
        const r = s.records();
        assert.equal(r.length, 1);
        assert.deepEqual(r[0].decision, { host: 'm4mini', reason: 'pinned:m4mini' });
        assert.equal(r[0].mode, 'shadow');
    });

    test('the OTHER host stays live: its pinned job mints, the shadow host\'s pinned job does not', async () => {
        const s = setup({ env: { FLEET_CI_DISPATCHER: '1' }, modes: { m4mini: 'shadow' } });
        s.report('m4mini'); s.report('m1mini');
        s.d.onJob(rec(1, { labels: POOL.concat('m4mini') }), 'queued');
        s.d.onJob(rec(2, { labels: POOL.concat('m1mini') }), 'queued');
        await s.d.tick();
        assert.equal(mints(s).length, 1);
        assert.ok(mints(s)[0][1].labels.includes('m1mini'));
        assert.equal(s.assignments.snapshot().length, 1);
        const byJob = Object.fromEntries(s.records().map((x) => [x.job_id, x]));
        assert.equal(byJob[1].mode, 'shadow');
        assert.equal(byJob[2].mode, 'live');
        assert.equal(byJob[2].decision.host, 'm1mini');
    });

    test('an unknown per-host mode value fails closed to shadow (never mints)', async () => {
        const s = setup({ env: { FLEET_CI_DISPATCHER: '1' }, machines: ['m4mini'] });
        const real = s.store.listMachines.bind(s.store);
        s.store.listMachines = () => { const m = real(); m.m4mini.mode = 'turbo'; return m; };
        s.report('m4mini');
        s.d.onJob(rec(1), 'queued');
        await s.d.tick(); await s.d.tick();
        assert.equal(mints(s).length, 0);
        assert.equal(s.records()[0].mode, 'shadow');
    });

    test('the store accepts only live|shadow, an absent mode stays valid, and the patch is persisted', () => {
        const s = setup({ machines: ['m4mini'] });
        assert.equal(s.store.upsertMachine('m4mini', { mode: 'turbo' }).ok, false);
        assert.equal(s.store.upsertMachine('m4mini', { mode: 'shadow' }).ok, true);
        assert.equal(s.store.getMachine('m4mini').mode, 'shadow');
        assert.equal(s.store.upsertMachine('m4mini', { mode: 'live' }).ok, true);
        assert.equal(s.store.getMachine('m4mini').mode, 'live');
    });
});

describe('live mode keeps recording (comparable) and still mints', () => {
    test('live: mode "live", mints, one record per job', async () => {
        const s = setup({ env: { FLEET_CI_DISPATCHER: '1' } });
        s.report('m1mini');
        s.d.onJob(rec(1), 'queued');
        await s.d.tick(); await s.d.tick();
        assert.equal(mints(s).length, 1);
        const r = s.records();
        assert.equal(r.length, 1);
        assert.equal(r[0].mode, 'live');
        assert.deepEqual(r[0].decision, { host: 'm1mini', reason: 'placed' });
    });
});

describe('decision record contract (fixed; a reader is coded against it)', () => {
    test('exact shape: ts, job_id, run_id, labels, mode, decision{host,reason}, capacity{host:{online,enabled,paused,free_slots,reason}}', async () => {
        const s = setup();
        s.report('m4mini', {}, 2); s.report('m1mini', { capacity: { memFreePct: 1 } }, 1);
        s.d.onJob(rec(7), 'queued');
        await s.d.tick();
        const raw = fs.readFileSync(s.logFile, 'utf8');
        assert.ok(raw.endsWith('\n') && raw.split('\n').length === 2, 'exactly one newline-terminated line');
        const r = JSON.parse(raw);
        assert.deepEqual(Object.keys(r), ['ts', 'job_id', 'run_id', 'labels', 'mode', 'decision', 'capacity']);
        assert.equal(r.ts, new Date(T0).toISOString());
        assert.match(r.ts, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/);
        assert.equal(r.job_id, 7);
        assert.equal(r.run_id, 5007);
        assert.deepEqual(r.labels, POOL);
        assert.equal(r.mode, 'shadow');
        assert.deepEqual(Object.keys(r.decision), ['host', 'reason']);
        assert.deepEqual(r.decision, { host: 'm4mini', reason: 'placed' });
        assert.deepEqual(Object.keys(r.capacity).sort(), ['m1mini', 'm4mini']);
        assert.deepEqual(r.capacity.m4mini, { online: true, enabled: true, paused: false, free_slots: 2, reason: null });
        assert.deepEqual(Object.keys(r.capacity.m1mini), ['online', 'enabled', 'paused', 'free_slots', 'reason']);
        assert.equal(r.capacity.m1mini.online, true);
        assert.equal(r.capacity.m1mini.free_slots, 1);
        assert.equal(r.capacity.m1mini.reason, 'mem-free-low');
        assert.equal(typeof r.run_id, 'number');
    });

    test('reasons: pinned:<host>, host-paused, no-capacity, not-pool, reject:fork (host null for the last four)', async () => {
        const s = setup();
        s.report('m4mini'); s.report('m1mini');
        assert.equal(s.store.upsertMachine('m1mini', { paused: true, pauseReason: 'drain' }, { by: 't', now: T0 }).ok, true);
        s.d.onJob(rec(1, { labels: POOL.concat('m4mini') }), 'queued');
        s.d.onJob(rec(2, { labels: POOL.concat('m1mini') }), 'queued');
        s.d.onJob(rec(3, { labels: ['self-hosted', 'Linux', 'ARM64'] }), 'queued');
        s.d.onJob(rec(4, { run: { event: 'pull_request', repoFullName: REPO, headRepoFullName: 'evil/fork' } }), 'queued');
        await s.d.tick();
        const by = Object.fromEntries(s.records().map((x) => [x.job_id, x.decision]));
        assert.deepEqual(by[1], { host: 'm4mini', reason: 'pinned:m4mini' });
        assert.deepEqual(by[2], { host: null, reason: 'host-paused' });
        assert.deepEqual(by[3], { host: null, reason: 'not-pool' });
        assert.deepEqual(by[4], { host: null, reason: 'reject:fork' });
        const paused = s.records().find((x) => x.job_id === 2).capacity.m1mini;
        assert.equal(paused.paused, true);
    });

    test('earlier decisions in a tick consume capacity: one idle slot is not promised twice', async () => {
        const s = setup({ machines: ['m4mini'] });
        s.report('m4mini', {}, 1);
        s.d.onJob(rec(1), 'queued'); s.d.onJob(rec(2), 'queued');
        await s.d.tick();
        const by = Object.fromEntries(s.records().map((x) => [x.job_id, x.decision]));
        assert.deepEqual(by[1], { host: 'm4mini', reason: 'placed' });
        assert.deepEqual(by[2], { host: null, reason: 'no-capacity' });
    });

    test('dedup: one record per job_id across ticks, repeat events and a config re-evaluation', async () => {
        const s = setup();
        s.report('m4mini');
        s.d.onJob(rec(1), 'queued');
        s.d.onJob(rec(1), 'seen');
        s.d.onJob(rec(9, { labels: ['self-hosted', 'Linux', 'ARM64'] }), 'queued');
        s.d.onJob(rec(9, { labels: ['self-hosted', 'Linux', 'ARM64'] }), 'seen');
        for (let i = 0; i < 3; i++) { s.report('m4mini'); await s.d.tick(); }
        s.d.onConfigChanged();
        await s.d.tick();
        assert.deepEqual(s.records().map((x) => x.job_id).sort(), [1, 9]);
    });

    test('dedup survives a restart: a new dispatcher re-primes from the log tail', async () => {
        const s = setup();
        s.report('m4mini');
        s.d.onJob(rec(1), 'queued');
        await s.d.tick();
        const s2 = setup({ logFile: s.logFile });
        s2.report('m4mini');
        s2.d.onJob(rec(1), 'queued'); s2.d.onJob(rec(2), 'queued');
        await s2.d.tick();
        assert.deepEqual(s.records().map((x) => x.job_id), [1, 2]);
    });

    test('no secret ever reaches the record or the logs', async () => {
        const s = setup({ env: { FLEET_CI_DISPATCHER: '1' } });
        s.report('m1mini');
        s.d.onJob(rec(1), 'queued');
        await s.d.tick();
        const blob = fs.readFileSync(s.logFile, 'utf8') + s.lines.join('\n');
        assert.equal(/JITSENTINEL|not-a-real-key|BEGIN|encodedJitConfig/.test(blob), false);
    });

    test('without FLEET_CI_SHADOW_LOG or a shadowLogPath nothing is written (unit-test harnesses stay clean)', async () => {
        const s = setup({ env: { FLEET_CI_SHADOW_LOG: '' } });
        s.report('m4mini');
        s.d.onJob(rec(1), 'queued');
        await s.d.tick();
        assert.equal(fs.existsSync(s.logFile), false);
        assert.equal(s.d.status().decisionsRecorded, 0);
    });
});

describe('a log write error never crashes the tick', () => {
    test('unwritable log path (parent is a regular file): tick resolves, live minting still works, error logged', async () => {
        const dir = path.join(TMP, `blocked${++seq}`);
        fs.mkdirSync(dir, { recursive: true });
        const blocker = path.join(dir, 'file');
        fs.writeFileSync(blocker, 'x');
        const s = setup({ env: { FLEET_CI_DISPATCHER: '1' }, logFile: path.join(blocker, 'decisions.jsonl') });
        s.report('m1mini');
        s.d.onJob(rec(1), 'queued');
        const delay = await s.d.tick();
        assert.equal(delay, 15000);
        assert.equal(mints(s).length, 1, 'a logging failure must not stop dispatch');
        assert.equal(s.d.status().decisionsRecorded, 0);
        assert.ok(s.lines.some((l) => /decision record not written/.test(l)), s.lines.join('\n'));
    });

    test('log path is a directory (EISDIR) in shadow: still no throw, nothing minted', async () => {
        const dir = path.join(TMP, `isdir${++seq}`);
        fs.mkdirSync(dir, { recursive: true });
        const s = setup({ logFile: dir });
        s.report('m4mini');
        s.d.onJob(rec(1), 'queued');
        assert.equal(await s.d.tick(), 15000);
        assert.equal(mints(s).length, 0);
    });
});

describe('static-label jobs in shadow (plan D1a)', () => {
  const STATIC = ['self-hosted', 'Linux', 'ARM64', 'm1mini'];
  test('a static-label job is accepted, decided onto its host as pinned:<host>, and nothing is minted', async () => {
    const s = setup();
    s.report('m4mini', {}, 2); s.report('m1mini');
    s.d.onJob(rec(1, { labels: STATIC }), 'queued');
    await s.d.tick(); await s.d.tick();
    assert.equal(mints(s).length, 0);
    assert.deepEqual(s.records().map((x) => [x.decision, x.mode]), [[{ host: 'm1mini', reason: 'pinned:m1mini' }, 'shadow']]);
  });

  test('pinned host paused: the reason names the pause; no free slot: the reason names capacity', async () => {
    const s = setup();
    s.report('m4mini'); s.report('m1mini', { slots: [] });
    s.d.onJob(rec(1, { labels: STATIC }), 'queued');
    assert.equal(s.store.upsertMachine('m4mini', { paused: true }, { by: 't', now: T0 }).ok, true);
    s.d.onJob(rec(2, { labels: ['self-hosted', 'Linux', 'ARM64', 'm4mini'] }), 'queued');
    await s.d.tick();
    const by = Object.fromEntries(s.records().map((x) => [x.job_id, x.decision.reason]));
    assert.match(by[1], /capacity|slot/);
    assert.match(by[2], /paus/);
  });

  test('rejections stay: unknown extra label, fork + host label, two host labels, no pool/host label', async () => {
    const s = setup();
    s.report('m1mini');
    s.d.onJob(rec(1, { labels: STATIC.concat('gpu') }), 'queued');
    s.d.onJob(rec(2, { labels: STATIC, run: { event: 'pull_request', repoFullName: REPO, headRepoFullName: 'evil/fork' } }), 'queued');
    s.d.onJob(rec(3, { labels: STATIC.concat('m4mini') }), 'queued');
    s.d.onJob(rec(4, { labels: ['self-hosted', 'Linux', 'ARM64'] }), 'queued');
    await s.d.tick();
    const by = Object.fromEntries(s.records().map((x) => [x.job_id, x.decision]));
    assert.deepEqual(by[1], { host: null, reason: 'label:unknown' });
    assert.deepEqual(by[2], { host: null, reason: 'reject:fork' });
    assert.deepEqual(by[3], { host: null, reason: 'label:ambiguous' });
    assert.deepEqual(by[4], { host: null, reason: 'not-pool' });
  });
});

// XACA-1445-014: a job accepted ONLY via its static host label may mint solely on a host whose mode is
// EXPLICITLY 'live' (absent = shadow), under a live global mode. Pool-labelled jobs are unchanged.
describe('static host-label jobs mint only on an explicitly-live host (014)', () => {
  const LABEL_ROWS = [
    ['Linux', ['self-hosted', 'Linux', 'ARM64', 'm1mini']],
    ['macOS', ['self-hosted', 'macOS', 'ARM64', 'm1mini']],
    ['Linux', ['self-hosted', 'linux', 'arm64', 'm1mini']],
  ];
  for (const [osName, labels] of LABEL_ROWS) {
    for (const hostMode of [undefined, 'shadow', 'live']) {
      for (const globalMode of ['1', 'shadow']) {
        const minting = hostMode === 'live' && globalMode === '1';
        test(`[${labels.join(',')}] host mode ${hostMode === undefined ? 'absent' : hostMode} x global ${globalMode}: ${minting ? 'exactly 1 mint' : '0 mints'}, record written`, async () => {
          const s = setup({ env: { FLEET_CI_DISPATCHER: globalMode }, machines: ['m1mini'], modes: hostMode ? { m1mini: hostMode } : {} });
          s.report('m1mini', { slots: slots(1, osName) });
          s.d.onJob(rec(1, { labels }), 'queued');
          await s.d.tick(); await s.d.tick();
          assert.equal(mints(s).length, minting ? 1 : 0, `mints: ${mints(s).length}`);
          if (minting) assert.ok(mints(s)[0][1].labels.map((l) => l.toLowerCase()).includes(osName.toLowerCase()));
          assert.equal(s.assignments.snapshot().length, minting ? 1 : 0);
          const r = s.records();
          assert.equal(r.length, 1, 'a decision record in every cell');
          assert.deepEqual(r[0].decision, { host: 'm1mini', reason: 'pinned:m1mini' });
          assert.equal(r[0].mode, minting ? 'live' : 'shadow');
          assert.equal(s.alerts.list().filter((a) => a.type === 'ci-no-capacity').length, 0);
        });
      }
    }
  }

  test('a static job whose pinned host has no slot is recorded as shadow with no-capacity, with an absent host mode', async () => {
    const s = setup({ env: { FLEET_CI_DISPATCHER: '1' }, machines: ['m1mini'] });
    s.report('m1mini', { slots: [] });
    s.d.onJob(rec(1, { labels: ['self-hosted', 'Linux', 'ARM64', 'm1mini'] }), 'queued');
    await s.d.tick();
    assert.equal(mints(s).length, 0);
    assert.equal(s.records()[0].mode, 'shadow');
    assert.match(s.records()[0].decision.reason, /capacity|slot/);
  });

  test('control: a POOL-labelled job on a host with mode absent under global 1 still mints (unchanged)', async () => {
    const s = setup({ env: { FLEET_CI_DISPATCHER: '1' }, machines: ['m1mini'] });
    s.report('m1mini');
    s.d.onJob(rec(1), 'queued');
    await s.d.tick();
    assert.equal(mints(s).length, 1);
    assert.equal(s.records()[0].mode, 'live');
  });
});
