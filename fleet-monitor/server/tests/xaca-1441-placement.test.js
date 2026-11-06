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

// XACA-1708-003: pressure-based swap gate. `pr` = a report from a NEW agent (reports memPressureLevel).
const pr = (cap) => report({ capacity: Object.assign({ memPressureLevel: 1 }, cap) });
const rs = (m, r, j) => check(m, r, j || linuxJob).reasons;

test('XACA-1708 regression: 3.6 GiB swap + normal pressure + flat growth is ELIGIBLE (m1mini 2026-10-31)', () => {
    const r = pr({ swapUsedBytes: 3.6 * GIB, memFreePct: 55, swapGrowthBytes: 10 * 1024 * 1024, swapGrowthWindowSec: 3600 });
    const v = check(machine(), r, linuxJob);
    assert.deepEqual(v.reasons, []);
    assert.equal(v.eligible, true);
    assert.equal(check(machine(), r, macJob).eligible, true);
});

test('XACA-1708: memPressureLevel >= 2 refuses mem-pressure; 1 passes; threshold overridable per host', () => {
    assert.ok(rs(machine(), pr({ memPressureLevel: 2 })).includes('mem-pressure'));
    assert.ok(rs(machine(), pr({ memPressureLevel: 4 })).includes('mem-pressure'));
    assert.equal(check(machine(), pr({ memPressureLevel: 1 }), linuxJob).eligible, true);
    const strict = machine({ thresholds: { memPressureLevel: 4 } });
    assert.equal(check(strict, pr({ memPressureLevel: 2 }), linuxJob).eligible, true);
    assert.ok(rs(strict, pr({ memPressureLevel: 4 })).includes('mem-pressure'));
});

test('XACA-1708: a malformed memPressureLevel fails closed (never reads as normal)', () => {
    for (const bad of [null, 'normal', '1', NaN, Infinity, 0, -1, {}, []]) {
        const r = rs(machine(), pr({ memPressureLevel: bad }));
        assert.ok(r.includes('mem-pressure-malformed'), String(bad));
        assert.equal(r.includes('swap-high'), false, 'malformed new-field agent does not fall back to legacy gate');
    }
});

test('XACA-1708: swap growth gate (per-hour normalized, strict >), negative growth fine, absent -> no verdict', () => {
    const th = DEFAULT_THRESHOLDS.swapGrowthBytesPerHour;
    assert.ok(rs(machine(), pr({ swapGrowthBytes: th + 1, swapGrowthWindowSec: 3600 })).includes('swap-growing'));
    assert.equal(rs(machine(), pr({ swapGrowthBytes: th, swapGrowthWindowSec: 3600 })).includes('swap-growing'), false);
    // normalization: half a GiB over 15 min = 2 GiB/h
    assert.ok(rs(machine(), pr({ swapGrowthBytes: 0.5 * GIB, swapGrowthWindowSec: 900 })).includes('swap-growing'));
    assert.equal(rs(machine(), pr({ swapGrowthBytes: 0.5 * GIB, swapGrowthWindowSec: 7200 })).includes('swap-growing'), false);
    assert.equal(check(machine(), pr({ swapGrowthBytes: -2 * GIB, swapGrowthWindowSec: 600 }), linuxJob).eligible, true);
    const none = rs(machine(), pr({}));
    assert.deepEqual(none, []);
    const lenient = machine({ thresholds: { swapGrowthBytesPerHour: 4 * GIB } });
    assert.equal(check(lenient, pr({ swapGrowthBytes: 2 * GIB, swapGrowthWindowSec: 3600 }), linuxJob).eligible, true);
});

test('XACA-1708: half-present or invalid growth fields fail closed', () => {
    for (const cap of [
        { swapGrowthBytes: 5 },
        { swapGrowthWindowSec: 600 },
        { swapGrowthBytes: 5, swapGrowthWindowSec: 0 },
        { swapGrowthBytes: 5, swapGrowthWindowSec: -1 },
        { swapGrowthBytes: '5', swapGrowthWindowSec: 600 },
        { swapGrowthBytes: null, swapGrowthWindowSec: 600 },
    ]) assert.ok(rs(machine(), pr(cap)).includes('swap-growth-malformed'), JSON.stringify(cap));
});

test('XACA-1708: LEGACY agent (no memPressureLevel) keeps the absolute swap-high gate exactly', () => {
    assert.ok(rs(machine(), report({ capacity: { swapUsedBytes: 2.8 * GIB } })).includes('swap-high'));
    assert.ok(rs(machine(), report({ capacity: { swapUsedBytes: 3.6 * GIB } })).includes('swap-high'));
    assert.equal(check(machine(), report({ capacity: { swapUsedBytes: 2.8 * GIB - 1 } }), linuxJob).eligible, true);
    // growth fields without the level are ignored by the legacy path
    assert.equal(rs(machine(), report({ capacity: { swapGrowthBytes: 99 * GIB, swapGrowthWindowSec: 60 } })).includes('swap-growing'), false);
});

test('XACA-1708: new-field agent is not gated on absolute swap, but swap-missing still refuses', () => {
    assert.equal(rs(machine(), pr({ swapUsedBytes: 100 * GIB })).includes('swap-high'), false);
    const r = pr({}); delete r.capacity.swapUsedBytes;
    assert.ok(rs(machine(), r).includes('swap-missing'));
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
