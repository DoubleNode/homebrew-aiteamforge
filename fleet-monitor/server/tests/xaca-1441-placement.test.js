'use strict';
// XACA-1441-004: pure placement rules (offline).
const test = require('node:test');
const assert = require('node:assert/strict');

const P = require('../lib/ci-dispatch-placement');
const { GIB, DEFAULT_THRESHOLDS } = require('../lib/ci-pool-store');

const NOW = 1_800_000_000_000;

function report(over) {
    const r = {
        receivedAt: NOW - 5000,
        capacity: {
            memTotalBytes: 16 * GIB, memReclaimableBytes: 4 * GIB, memFreePct: 45,
            swapUsedBytes: 1 * GIB, swapTotalBytes: 3 * GIB, load1: 2, load5: 2, load15: 2,
            ncpu: 10, teamSessions: 6, vmState: 'running',
        },
        slots: [
            { os: 'Linux', index: 1, state: 'idle', assignmentId: null },
            { os: 'macOS', index: 1, state: 'idle', assignmentId: null },
        ],
    };
    if (over && over.capacity) Object.assign(r.capacity, over.capacity);
    if (over && 'receivedAt' in over) r.receivedAt = over.receivedAt;
    if (over && 'slots' in over) r.slots = over.slots;
    return r;
}
const machine = (o) => Object.assign({ id: 'm4mini', enabled: true, paused: false, prefers: null, thresholds: {} }, o);
const linuxJob = { name: 'x', labels: ['self-hosted', 'Linux', 'ARM64', 'fleet-pool'] };
const macJob = { name: 'x', labels: ['self-hosted', 'macOS', 'ARM64', 'fleet-pool'] };
const opts = { now: NOW, thresholds: DEFAULT_THRESHOLDS };
const check = (m, r, j, o) => P.isEligible(m, r, j, o || opts);

test('jobClass: seeded table, unknown -> short, hostile names safe', () => {
    const t = { 'shell-suite': 'long', bats: 'long', 'pytest-suite': 'long' };
    for (const n of ['shell-suite', 'bats', 'pytest-suite']) assert.equal(P.jobClass(n, t), 'long');
    assert.equal(P.jobClass('lint', t), 'short');
    assert.equal(P.jobClass('constructor', t), 'short');
    assert.equal(P.jobClass('__proto__', t), 'short');
    assert.equal(P.jobClass(undefined, t), 'short');
    assert.equal(P.jobClass('bats', undefined), 'long');       // falls back to the seeded default
    assert.equal(P.jobClass('bats', { bats: 'short' }), 'short');
});

test('isEligible: healthy machine passes for both OS', () => {
    assert.deepEqual(check(machine(), report(), linuxJob), { eligible: true, reasons: [] });
    assert.deepEqual(check(machine(), report(), macJob), { eligible: true, reasons: [] });
});

test('isEligible: enabled / paused gates (default record is dormant)', () => {
    assert.ok(check(machine({ enabled: false }), report(), linuxJob).reasons.includes('not-enabled'));
    assert.ok(check(machine({ paused: true }), report(), linuxJob).reasons.includes('paused'));
    assert.ok(check(machine({ paused: undefined }), report(), linuxJob).reasons.includes('paused'));
    assert.ok(check(machine({ enabled: 'true' }), report(), linuxJob).reasons.includes('not-enabled'));
});

test('isEligible: poll freshness boundary (<= 30 s ok, > 30 s stale)', () => {
    assert.equal(check(machine(), report({ receivedAt: NOW - 30000 }), linuxJob).eligible, true);
    assert.ok(check(machine(), report({ receivedAt: NOW - 30001 }), linuxJob).reasons.includes('stale-poll'));
    assert.equal(check(machine(), report({ receivedAt: new Date(NOW - 1000).toISOString() }), linuxJob).eligible, true);
    assert.ok(check(machine(), report({ receivedAt: NOW + 31000 }), linuxJob).reasons.includes('poll-in-future'));
});

test('isEligible: idle slot per OS', () => {
    const onlyBusyMac = [{ os: 'Linux', state: 'idle' }, { os: 'macOS', state: 'busy' }];
    assert.ok(check(machine(), report({ slots: onlyBusyMac }), macJob).reasons.includes('no-idle-slot'));
    assert.equal(check(machine(), report({ slots: onlyBusyMac }), linuxJob).eligible, true);
    for (const state of ['starting', 'cleaning', 'broken', 'busy']) {
        assert.ok(check(machine(), report({ slots: [{ os: 'Linux', state }] }), linuxJob).reasons.includes('no-idle-slot'), state);
    }
});

test('isEligible: memReclaimable boundary (macOS only: >= 1.5 GiB)', () => {
    const at = report({ capacity: { memReclaimableBytes: 1.5 * GIB } });
    const below = report({ capacity: { memReclaimableBytes: 1.5 * GIB - 1 } });
    assert.equal(check(machine(), at, macJob).eligible, true);
    assert.ok(check(machine(), below, macJob).reasons.includes('mem-reclaimable-low'));
    assert.equal(check(machine(), below, linuxJob).eligible, true);   // VM memory already allocated
});

test('isEligible: swap boundary (< 2.8 GiB, strict) and per-host override', () => {
    assert.ok(check(machine(), report({ capacity: { swapUsedBytes: 2.8 * GIB } }), linuxJob).reasons.includes('swap-high'));
    assert.equal(check(machine(), report({ capacity: { swapUsedBytes: 2.8 * GIB - 1 } }), linuxJob).eligible, true);
    const lenient = machine({ thresholds: { swapUsedBytes: 4 * GIB } });
    assert.equal(check(lenient, report({ capacity: { swapUsedBytes: 3 * GIB } }), linuxJob).eligible, true);
});

test('isEligible: memFreePct boundary (>= 35)', () => {
    assert.equal(check(machine(), report({ capacity: { memFreePct: 35 } }), linuxJob).eligible, true);
    assert.ok(check(machine(), report({ capacity: { memFreePct: 34.9 } }), linuxJob).reasons.includes('mem-free-low'));
});

test('isEligible: load1/ncpu boundary (< 0.75, strict)', () => {
    assert.ok(check(machine(), report({ capacity: { load1: 7.5, ncpu: 10 } }), linuxJob).reasons.includes('load-high'));
    assert.equal(check(machine(), report({ capacity: { load1: 7.49, ncpu: 10 } }), linuxJob).eligible, true);
    assert.ok(check(machine(), report({ capacity: { load1: 33, ncpu: 8 } }), linuxJob).reasons.includes('load-high'));
});

test('isEligible: Linux needs vmState running; macOS does not', () => {
    for (const vmState of ['stopped', 'broken', 'unknown', 'none', undefined]) {
        assert.ok(check(machine(), report({ capacity: { vmState } }), linuxJob).reasons.includes('vm-not-running'), String(vmState));
    }
    assert.equal(check(machine(), report({ capacity: { vmState: 'none' } }), macJob).eligible, true);
});

test('isEligible: every missing / invalid input is ineligible (fail closed)', () => {
    const missing = (field) => { const r = report(); delete r.capacity[field]; return r; };
    for (const f of ['memFreePct', 'swapUsedBytes', 'load1', 'ncpu']) {
        assert.equal(check(machine(), missing(f), linuxJob).eligible, false, `missing ${f}`);
    }
    assert.equal(check(machine(), missing('memReclaimableBytes'), macJob).eligible, false);
    assert.equal(check(machine(), missing('vmState'), linuxJob).eligible, false);
    for (const bad of [NaN, Infinity, '5', null]) {
        assert.equal(check(machine(), report({ capacity: { memFreePct: bad } }), linuxJob).eligible, false, String(bad));
    }
    assert.equal(check(machine(), report({ capacity: { ncpu: 0 } }), linuxJob).eligible, false);
    assert.equal(check(machine(), report({ receivedAt: undefined }), linuxJob).eligible, false);
    assert.equal(check(machine(), report({ receivedAt: 'garbage' }), linuxJob).eligible, false);
    assert.equal(check(machine(), report({ slots: undefined }), linuxJob).eligible, false);
    assert.equal(check(machine(), null, linuxJob).eligible, false);
    assert.equal(check(machine(), {}, linuxJob).eligible, false);
    assert.equal(check(null, report(), linuxJob).eligible, false);
    assert.equal(check(machine(), report(), null).eligible, false);
    assert.equal(check(machine(), report(), { labels: ['self-hosted', 'fleet-pool'] }).eligible, false);   // no OS
    assert.equal(check(machine(), report(), { labels: ['Linux', 'macOS'] }).eligible, false);              // ambiguous OS
    assert.equal(check(machine(), report(), linuxJob, {}).eligible, false);                                // no clock
});

test('isEligible: host-targeting labels', () => {
    const toM4 = { name: 'x', labels: [...linuxJob.labels, 'm4mini'] };
    const toM1 = { name: 'x', labels: [...linuxJob.labels, 'm1mini'] };
    assert.equal(check(machine(), report(), toM4).eligible, true);
    assert.ok(check(machine(), report(), toM1).reasons.includes('label-mismatch'));
    assert.ok(check(machine(), report(), { name: 'x', labels: [...linuxJob.labels, 'gpu'] }).reasons.includes('label-mismatch'));
});

test('rankCandidates: preference first, then reclaimable memory, then id', () => {
    const machines = {
        m1mini: { enabled: true, paused: false, prefers: 'short', thresholds: {} },
        m4mini: { enabled: true, paused: false, prefers: 'long', thresholds: {} },
        zeta:   { enabled: true, paused: false, prefers: null, thresholds: {} },
        alpha:  { enabled: true, paused: false, prefers: null, thresholds: {} },
    };
    const reports = {
        m1mini: report({ capacity: { memReclaimableBytes: 2 * GIB } }),
        m4mini: report({ capacity: { memReclaimableBytes: 3 * GIB } }),
        zeta:   report({ capacity: { memReclaimableBytes: 9 * GIB } }),
        alpha:  report({ capacity: { memReclaimableBytes: 9 * GIB } }),
    };
    const cfg = { now: NOW, thresholds: DEFAULT_THRESHOLDS, jobClasses: { bats: 'long' }, poolLabel: 'fleet-pool' };
    const ids = (job) => P.rankCandidates(machines, reports, job, cfg).map((r) => r.id);
    assert.deepEqual(ids({ name: 'bats', labels: linuxJob.labels }), ['m4mini', 'alpha', 'zeta', 'm1mini']);
    assert.deepEqual(ids({ name: 'lint', labels: linuxJob.labels }), ['m1mini', 'alpha', 'zeta', 'm4mini']);
    // determinism: same inputs, same order, input key order irrelevant
    const rev = Object.fromEntries(Object.entries(machines).reverse());
    assert.deepEqual(P.rankCandidates(rev, reports, { name: 'bats', labels: linuxJob.labels }, cfg).map((r) => r.id),
        ids({ name: 'bats', labels: linuxJob.labels }));
});

test('rankCandidates: preference never blocks (preferred host ineligible -> next host)', () => {
    const machines = {
        m4mini: { enabled: true, paused: true, prefers: 'long', thresholds: {} },      // paused
        m1mini: { enabled: true, paused: false, prefers: 'short', thresholds: {} },
    };
    const reports = { m4mini: report(), m1mini: report() };
    const cfg = { now: NOW, thresholds: DEFAULT_THRESHOLDS, jobClasses: { bats: 'long' } };
    const out = P.rankCandidates(machines, reports, { name: 'bats', labels: linuxJob.labels }, cfg);
    assert.deepEqual(out.map((r) => r.id), ['m1mini']);
    assert.equal(out[0].preferred, false);
    // stale preferred host
    reports.m4mini = report({ receivedAt: NOW - 120000 });
    machines.m4mini.paused = false;
    assert.deepEqual(P.rankCandidates(machines, reports, { name: 'bats', labels: linuxJob.labels }, cfg).map((r) => r.id), ['m1mini']);
    // nobody eligible -> empty, never throws
    assert.deepEqual(P.rankCandidates({}, {}, linuxJob, cfg), []);
    assert.deepEqual(P.rankCandidates(machines, {}, linuxJob, cfg), []);
});

test('evaluateMachines: ineligible machines carry reasons and sort last', () => {
    const machines = { a: { enabled: false, paused: false }, b: { enabled: true, paused: false } };
    const out = P.evaluateMachines(machines, { a: report(), b: report() }, linuxJob, { now: NOW });
    assert.deepEqual(out.map((r) => r.id), ['b', 'a']);
    assert.ok(out[1].reasons.includes('not-enabled'));
});

test('labelSetKey: canonical, case-insensitive, order-insensitive', () => {
    assert.equal(P.labelSetKey(['self-hosted', 'Linux']), P.labelSetKey(['linux', 'SELF-HOSTED', 'Linux']));
    assert.equal(P.labelSetKey(['b', 'a']), 'a,b');
    assert.equal(P.labelSetKey('nope'), null);
    assert.equal(P.labelSetKey(['a', 1]), null);
    assert.equal(P.labelSetKey(['a', ' ']), null);
});

test('computeSupply: mint = max(0, queued - outstanding) per label-set', () => {
    const L = ['self-hosted', 'Linux', 'ARM64', 'fleet-pool'];
    const M = ['self-hosted', 'macOS', 'ARM64', 'fleet-pool'];
    const jobs = [{ labels: L }, { labels: [...L].reverse() }, { labels: L }, { labels: M }, { labels: 'bad' }, null];
    const out = P.computeSupply(jobs, { [P.labelSetKey(L)]: 1, [P.labelSetKey(M)]: 5 });
    const by = Object.fromEntries(out.map((s) => [s.key, s]));
    assert.equal(by[P.labelSetKey(L)].queued, 3);
    assert.equal(by[P.labelSetKey(L)].mint, 2);
    assert.equal(by[P.labelSetKey(M)].mint, 0);            // never negative
    assert.equal(out.length, 2);
});

test('computeSupply: outstanding-only sets, Map input, empty and junk input', () => {
    const key = P.labelSetKey(['self-hosted', 'Linux']);
    const out = P.computeSupply([], new Map([[key, 2], ['x', -1], ['y', 'z']]));
    assert.deepEqual(out.map((s) => [s.key, s.queued, s.outstanding, s.mint]), [[key, 0, 2, 0]]);
    assert.deepEqual(P.computeSupply(undefined, undefined), []);
    assert.deepEqual(P.computeSupply([{ labels: ['A'] }], null).map((s) => s.mint), [1]);
});

test('mintLabels: always the full set (A3)', () => {
    const out = P.mintLabels(linuxJob, { id: 'M4Mini' }, { poolLabel: 'fleet-pool' });
    assert.deepEqual(out, ['self-hosted', 'Linux', 'ARM64', 'fleet-pool', 'm4mini']);
    // a job that asked for fewer labels still gets the full set
    assert.deepEqual(P.mintLabels({ labels: ['self-hosted', 'macOS', 'fleet-pool'] }, { id: 'm1mini' }, { poolLabel: 'fleet-pool' }),
        ['self-hosted', 'macOS', 'ARM64', 'fleet-pool', 'm1mini']);
    // configured pool label and explicit host label
    assert.deepEqual(P.mintLabels({ labels: ['self-hosted', 'Linux', 'my-pool'] }, { id: 'x', hostLabel: 'M4Mini' }, { poolLabel: 'my-pool' }),
        ['self-hosted', 'Linux', 'ARM64', 'my-pool', 'm4mini']);
    // default pool label when cfg omitted
    assert.equal(P.mintLabels(linuxJob, { id: 'm4mini' })[3], 'fleet-pool');
});

test('mintLabels: refuses (null) when the set cannot satisfy the job', () => {
    assert.equal(P.mintLabels({ labels: ['self-hosted', 'fleet-pool'] }, { id: 'm4mini' }), null);                     // no OS
    assert.equal(P.mintLabels({ labels: [...linuxJob.labels, 'gpu'] }, { id: 'm4mini' }), null);                        // foreign label
    assert.equal(P.mintLabels({ labels: [...linuxJob.labels, 'm1mini'] }, { id: 'm4mini' }), null);                     // other host
    assert.equal(P.mintLabels(linuxJob, {}), null);                                                                     // no host label
    assert.equal(P.mintLabels(null, { id: 'm4mini' }), null);
});
