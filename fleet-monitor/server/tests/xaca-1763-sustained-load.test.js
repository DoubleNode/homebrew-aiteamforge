'use strict';
// XACA-1763-003: sustained-load gate (load1 AND load5) replacing the load1-only 'load-high' gate.
const test = require('node:test');
const assert = require('node:assert/strict');

const P = require('../lib/ci-dispatch-placement');
const { GIB, DEFAULT_THRESHOLDS } = require('../lib/ci-pool-store');

const NOW = 1_800_000_000_000;
function report(capacity) {
    return {
        receivedAt: NOW - 5000,
        capacity: Object.assign({
            memTotalBytes: 16 * GIB, memReclaimableBytes: 4 * GIB, memFreePct: 45,
            swapUsedBytes: 1 * GIB, swapTotalBytes: 3 * GIB, load1: 2, load5: 2, load15: 2,
            ncpu: 10, teamSessions: 6, vmState: 'running',
        }, capacity),
        slots: [{ os: 'Linux', index: 1, state: 'idle', assignmentId: null }],
    };
}
const machine = (o) => Object.assign({ id: 'm4mini', enabled: true, paused: false, prefers: null, thresholds: {} }, o);
const job = { name: 'x', labels: ['self-hosted', 'Linux', 'ARM64', 'fleet-pool'] };
const opts = { now: NOW, thresholds: DEFAULT_THRESHOLDS };
const reasons = (m, cap) => P.isEligible(m, report(cap), job, opts).reasons;

test('load1 spike with calm load5 is NOT refused (m4mini co-tenant spike)', () => {
    const r = P.isEligible(machine(), report({ load1: 12, load5: 3, ncpu: 10 }), job, opts);
    assert.equal(r.eligible, true, r.reasons.join());
});

test('sustained: both load1 and load5 over the line is refused', () => {
    assert.ok(reasons(machine(), { load1: 12, load5: 8, ncpu: 10 }).includes('load-high'));
});

test('load5 high but load1 already recovered is NOT refused', () => {
    assert.ok(!reasons(machine(), { load1: 2, load5: 9, ncpu: 10 }).includes('load-high'));
});

test('boundary is >= on both averages (7.5/10 = 0.75 trips; 7.49 does not)', () => {
    assert.ok(reasons(machine(), { load1: 7.5, load5: 7.5, ncpu: 10 }).includes('load-high'));
    assert.ok(!reasons(machine(), { load1: 7.5, load5: 7.49, ncpu: 10 }).includes('load-high'));
    assert.ok(!reasons(machine(), { load1: 7.49, load5: 7.5, ncpu: 10 }).includes('load-high'));
});

test('legacy agent (load5 absent) keeps the load1-only gate exactly', () => {
    const run = (load1) => { const r = report({ load1, ncpu: 10 }); delete r.capacity.load5; return P.isEligible(machine(), r, job, opts).reasons; };
    assert.ok(run(7.5).includes('load-high'));
    assert.ok(!run(7.49).includes('load-high'));
});

test('load5 present but unusable fails closed as load-malformed (not load-high, not eligible)', () => {
    for (const bad of [null, '2', NaN, Infinity, -1, {}, []]) {
        const r = P.isEligible(machine(), report({ load5: bad }), job, opts);
        assert.ok(r.reasons.includes('load-malformed'), String(bad));
        assert.equal(r.eligible, false, String(bad));
    }
});

test('load1/ncpu missing stays load-missing, regardless of load5', () => {
    for (const cap of [{ load1: undefined }, { ncpu: undefined }, { ncpu: 0 }]) {
        const rs = reasons(machine(), cap);
        assert.ok(rs.includes('load-missing'), JSON.stringify(cap));
        assert.ok(!rs.includes('load-malformed') && !rs.includes('load-high'));
    }
});

test('per-machine loadPerCpu override applies to both averages of the new gate', () => {
    const strict = machine({ thresholds: { loadPerCpu: 0.3 } });
    assert.ok(reasons(strict, { load1: 4, load5: 4, ncpu: 10 }).includes('load-high'));
    assert.ok(!reasons(machine(), { load1: 4, load5: 4, ncpu: 10 }).includes('load-high'));
    const lax = machine({ thresholds: { loadPerCpu: 2 } });
    assert.ok(!reasons(lax, { load1: 12, load5: 12, ncpu: 10 }).includes('load-high'));
    assert.ok(reasons(lax, { load1: 20, load5: 20, ncpu: 10 }).includes('load-high'));
    assert.ok(!reasons(strict, { load1: 4, load5: 2, ncpu: 10 }).includes('load-high'), 'calm load5 still exempts under a stricter override');
});
