'use strict';
// XACA-1704-001: hostGate() extracted from isEligible(). (a) PARITY: isEligible keeps the exact verdict AND
// reason order of the frozen pre-extraction copy over a broad generated matrix. (b) hostGate contract.
const test = require('node:test');
const assert = require('node:assert/strict');

const P = require('../lib/ci-dispatch-placement');
const OLD = require('./fixtures/xaca-1704-legacy-placement');
const { GIB, DEFAULT_THRESHOLDS } = require('../lib/ci-pool-store');

const NOW = 1_800_000_000_000;
const base = () => ({
    memTotalBytes: 16 * GIB, memReclaimableBytes: 4 * GIB, memFreePct: 45, swapUsedBytes: 1 * GIB,
    swapTotalBytes: 3 * GIB, load1: 2, load5: 2, ncpu: 10, vmState: 'running', memPressureLevel: 1,
});
const mk = (cap, extra) => Object.assign({
    receivedAt: NOW - 5000, capacity: Object.assign(base(), cap), slots: [{ os: 'Linux', state: 'idle' }, { os: 'macOS', state: 'idle' }],
}, extra);

function* cases() {
    const caps = [
        {}, { swapUsedBytes: 3 * GIB }, { swapUsedBytes: undefined }, { memPressureLevel: undefined, swapUsedBytes: 3 * GIB },
        { memPressureLevel: 4 }, { memPressureLevel: null }, { memPressureLevel: 0 }, { swapGrowthBytes: 9 * GIB, swapGrowthWindowSec: 600 },
        { swapGrowthBytes: 1 }, { swapGrowthBytes: 1, swapGrowthWindowSec: 0 }, { memFreePct: 3 }, { memFreePct: undefined },
        { memReclaimableBytes: 1 }, { memReclaimableBytes: undefined }, { load1: 12, load5: 12 }, { load1: 12, load5: 1 },
        { load1: 12, load5: undefined }, { load5: null }, { load1: undefined }, { ncpu: 0 }, { vmState: 'stopped' },
        { swapUsedBytes: 3 * GIB, memFreePct: 3, load1: 12, load5: 12, vmState: 'x', memReclaimableBytes: 0 },
    ];
    const reps = [];
    for (const c of caps) reps.push(mk(c));
    reps.push(null, {}, { capacity: null }, mk({}, { receivedAt: NOW - 10 * 60 * 1000 }), mk({}, { receivedAt: NOW + 10 * 60 * 1000 }),
        mk({}, { receivedAt: 'garbage' }), mk({}, { receivedAt: undefined }), mk({}, { slots: [] }), mk({}, { slots: null }),
        mk({}, { slots: [{ os: 'macOS', state: 'busy' }] }), mk({}, { receivedAt: new Date(NOW - 1000).toISOString() }));
    const machines = [
        { id: 'm1mini', enabled: true, paused: false }, { id: 'm1mini', enabled: false, paused: false },
        { id: 'm1mini', enabled: true, paused: true }, { id: 'm1mini', enabled: true, paused: undefined },
        { id: 'm1mini', enabled: true, paused: false, thresholds: { swapUsedBytes: 8 * GIB, loadPerCpu: 0.1 } },
        { id: 'm1mini', enabled: true, paused: false, repos: ['a/b'] }, { id: 'm1mini', enabled: true, paused: false, repos: 'bad' },
        { id: 'm1mini', enabled: true, paused: false, hostLabel: 'other' }, null,
    ];
    const jobs = [
        { labels: ['self-hosted', 'Linux', 'ARM64', 'fleet-pool'], owner: 'a', repo: 'b' },
        { labels: ['self-hosted', 'macOS', 'ARM64', 'fleet-pool', 'm1mini'] }, { labels: ['self-hosted', 'macOS', 'weird'] },
        { labels: ['Linux', 'macOS'] }, { labels: 'x' }, null,
    ];
    for (const m of machines) for (const r of reps) for (const j of jobs) yield [m, r, j];
}

test('PARITY: isEligible output (verdict + reason ORDER) identical to the pre-extraction implementation', () => {
    let n = 0;
    for (const [m, r, j] of cases()) {
        for (const opts of [{ now: NOW, thresholds: DEFAULT_THRESHOLDS, boundRepos: new Set(['a/b']) }, { thresholds: {} }, undefined]) {
            assert.deepEqual(P.isEligible(m, r, j, opts), OLD.isEligible(m, r, j, opts), JSON.stringify({ m, r, j }));
            n++;
        }
    }
    assert.ok(n > 5000, `matrix too small: ${n}`);
});

test('hostGate: healthy host passes with no checks', () => {
    const g = P.hostGate(mk({}), { id: 'm1mini', enabled: true, paused: false }, { now: NOW, thresholds: DEFAULT_THRESHOLDS });
    assert.deepEqual(g, { eligible: true, reasons: [], checks: [] });
});

test('hostGate: the 2026-10-31 m1mini swap-high shape reports measured vs limit', () => {
    const cap = { swapUsedBytes: 2877 * 1024 * 1024 };
    const th = Object.assign({}, DEFAULT_THRESHOLDS, { swapUsedBytes: 2867 * 1024 * 1024 });
    const g = P.hostGate(mk({ memPressureLevel: undefined, ...cap }), { id: 'm1mini', enabled: true, paused: false }, { now: NOW, thresholds: th });
    assert.deepEqual(g.reasons, ['swap-high']);
    assert.deepEqual(g.checks, [{ reason: 'swap-high', measured: 2877 * 1024 * 1024, limit: 2867 * 1024 * 1024 }]);
});

test('hostGate: per-host override beats pool config (effective limit reported)', () => {
    const m = { id: 'x', enabled: true, paused: false, thresholds: { memFreePct: 90 } };
    const g = P.hostGate(mk({ memFreePct: 45 }), m, { now: NOW, thresholds: { memFreePct: 5 } });
    assert.deepEqual(g.checks, [{ reason: 'mem-free-low', measured: 45, limit: 90 }]);
});

test('hostGate: sustained load check carries load1/ncpu and load5/ncpu', () => {
    const g = P.hostGate(mk({ load1: 12, load5: 9, ncpu: 10 }), { id: 'x', enabled: true, paused: false }, { now: NOW, thresholds: DEFAULT_THRESHOLDS });
    assert.deepEqual(g.reasons, ['load-high']);
    assert.deepEqual(g.checks, [{ reason: 'load-high', measured: { load1PerCpu: 1.2, load5PerCpu: 0.9 }, limit: DEFAULT_THRESHOLDS.loadPerCpu }]);
});

test('hostGate: pressure and swap-growth gates report numbers', () => {
    const th = DEFAULT_THRESHOLDS;
    const g = P.hostGate(mk({ memPressureLevel: th.memPressureLevel, swapGrowthBytes: 9 * GIB, swapGrowthWindowSec: 3600 }), { id: 'x', enabled: true, paused: false }, { now: NOW, thresholds: th });
    assert.deepEqual(g.reasons, ['mem-pressure', 'swap-growing']);
    assert.deepEqual(g.checks[0], { reason: 'mem-pressure', measured: th.memPressureLevel, limit: th.memPressureLevel });
    assert.deepEqual(g.checks[1], { reason: 'swap-growing', measured: 9 * GIB, limit: th.swapGrowthBytesPerHour });
});

test('hostGate (XACA-1704-017): swap-growing measured is bytes PER HOUR, same unit as the limit, whatever the window', () => {
    const th = DEFAULT_THRESHOLDS;
    const m = { id: 'x', enabled: true, paused: false };
    // 1 GiB over a 600 s window is 6 GiB/h, not 1 GiB.
    const g = P.hostGate(mk({ memPressureLevel: 1, swapGrowthBytes: GIB, swapGrowthWindowSec: 600 }), m, { now: NOW, thresholds: th });
    assert.deepEqual(g.reasons, ['swap-growing']);
    assert.equal(g.checks[0].measured, 6 * GIB);
    assert.equal(g.checks[0].limit, th.swapGrowthBytesPerHour);
    assert.ok(g.checks[0].measured > g.checks[0].limit, 'a refusing check always has measured > limit in the SAME unit');
    // Decision unchanged: exactly at the limit over a 2 h window does not trip.
    const ok = P.hostGate(mk({ memPressureLevel: 1, swapGrowthBytes: 2 * th.swapGrowthBytesPerHour, swapGrowthWindowSec: 7200 }), m, { now: NOW, thresholds: th });
    assert.equal(ok.reasons.includes('swap-growing'), false);
});

test('hostGate: stale poll, no-report, admin state', () => {
    const m = { id: 'x', enabled: false, paused: true };
    assert.deepEqual(P.hostGate(null, m, { now: NOW }).reasons, ['not-enabled', 'paused', 'no-report']);
    const g = P.hostGate(mk({}, { receivedAt: NOW - 10 * 60 * 1000 }), { id: 'x', enabled: true, paused: false }, { now: NOW, thresholds: DEFAULT_THRESHOLDS });
    assert.deepEqual(g.reasons, ['stale-poll']);
    assert.deepEqual(g.checks, [{ reason: 'stale-poll', measured: 10 * 60 * 1000, limit: DEFAULT_THRESHOLDS.pollStaleMs }]);
});

test('hostGate: no machine record fails closed; never throws on junk', () => {
    assert.deepEqual(P.hostGate(mk({}), null, { now: NOW }).reasons, ['no-machine-record']);
    for (const bad of [undefined, 1, 'x', [], { capacity: 5 }]) assert.doesNotThrow(() => P.hostGate(bad, { id: 'x' }, undefined));
});
