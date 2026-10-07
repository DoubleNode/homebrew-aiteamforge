'use strict';
// XACA-1445-013: host-label pinning (plan D1) for the CI dispatcher placement rules.
const { test, describe } = require('node:test');
const assert = require('node:assert/strict');
const plc = require('../lib/ci-dispatch-placement');

const NOW = 1700000000000;
const GB = 1024 ** 3;
const mach = (extra) => Object.assign({ enabled: true, paused: false }, extra);
const report = (memReclaimableBytes) => ({
    receivedAt: NOW,
    capacity: { memReclaimableBytes, swapUsedBytes: 0, memFreePct: 50, load1: 0.1, ncpu: 8, vmState: 'running' },
    slots: [{ os: 'Linux', state: 'idle' }, { os: 'macOS', state: 'idle' }],
});
// m4mini has MORE free capacity than m1mini, so a capacity-only ranking would pick it.
const machines = { m1mini: mach(), m4mini: mach() };
const reports = { m1mini: report(2 * GB), m4mini: report(20 * GB) };
const cfg = { now: NOW };
const job = (labels) => ({ name: 'build', labels });
const rank = (labels, ms = machines, rs = reports) => plc.rankCandidates(ms, rs, job(labels), cfg).map((r) => r.id);

describe('XACA-1445 D1: host-pinned placement', () => {
    test('(a) m1mini-labelled job places ONLY on m1mini despite m4mini having more capacity', () => {
        assert.deepEqual(rank(['self-hosted', 'Linux', 'ARM64', 'm1mini']), ['m1mini']);
    });
    test('(b) m4mini-labelled job places ONLY on m4mini', () => {
        assert.deepEqual(rank(['self-hosted', 'Linux', 'ARM64', 'm4mini']), ['m4mini']);
        assert.deepEqual(rank(['self-hosted', 'Linux', 'ARM64', 'm4mini'], machines, { m1mini: report(50 * GB), m4mini: report(1 * GB) }), ['m4mini']);
    });
    test('(c) pool-labelled job may go to either host, largest reclaimable first', () => {
        assert.deepEqual(rank(['self-hosted', 'Linux', 'ARM64', 'fleet-pool']), ['m4mini', 'm1mini']);
    });
    test('(d) unknown host label yields no placement and reports label-mismatch (no fallback)', () => {
        const labels = ['self-hosted', 'Linux', 'ARM64', 'm9mini'];
        assert.deepEqual(rank(labels), []);
        for (const row of plc.evaluateMachines(machines, reports, job(labels), cfg)) {
            assert.equal(row.eligible, false);
            assert.ok(row.reasons.includes('label-mismatch'));
        }
    });
    test('(d2) job carrying two different host labels is unplaceable', () => {
        assert.deepEqual(rank(['self-hosted', 'Linux', 'ARM64', 'm1mini', 'm4mini']), []);
    });
    test('(d3) pinned host that is ineligible (paused) does not fall back to the other host', () => {
        const ms = { m1mini: mach({ paused: true }), m4mini: mach() };
        assert.deepEqual(rank(['self-hosted', 'Linux', 'ARM64', 'm1mini'], ms), []);
    });
    test('(d4) host label matching is case-insensitive', () => {
        assert.deepEqual(rank(['self-hosted', 'Linux', 'ARM64', 'M1Mini']), ['m1mini']);
    });
    test('(e) minted label set carries the host label AND every job label', () => {
        const jl = ['self-hosted', 'Linux', 'ARM64', 'm1mini'];
        const minted = plc.mintLabels(job(jl), Object.assign({ id: 'm1mini' }, machines.m1mini), { poolLabel: 'fleet-pool' });
        const lower = minted.map((l) => l.toLowerCase());
        assert.ok(lower.includes('m1mini'));
        assert.ok(lower.includes('fleet-pool'));
        for (const l of jl) assert.ok(lower.includes(l.toLowerCase()));
    });
    test('(e2) mint refuses a job whose host label differs from the chosen machine', () => {
        assert.equal(plc.mintLabels(job(['self-hosted', 'Linux', 'ARM64', 'm1mini']), { id: 'm4mini' }, {}), null);
    });
    test('(e3) default pool label is fleet-pool; config override respected', () => {
        assert.equal(plc.DEFAULT_POOL_LABEL, 'fleet-pool');
        assert.ok(plc.mintLabels(job(['self-hosted', 'Linux', 'ARM64', 'm1mini']), { id: 'm1mini' }, { poolLabel: 'x-pool' }).includes('x-pool'));
    });
    test('(f) wrong-job pickup: an m4mini runner label set is NOT a superset of an m1mini-pinned job', () => {
        const runner = plc.mintLabels(job(['self-hosted', 'Linux', 'ARM64', 'fleet-pool']), { id: 'm4mini' }, {}).map((l) => l.toLowerCase());
        const superset = (jobLabels) => jobLabels.every((l) => runner.includes(l.toLowerCase()));
        assert.equal(superset(['self-hosted', 'Linux', 'ARM64', 'm1mini']), false);
        assert.equal(superset(['self-hosted', 'Linux', 'ARM64', 'm4mini']), true);
        assert.equal(superset(['self-hosted', 'Linux', 'ARM64', 'fleet-pool']), true);
        assert.equal(superset(['self-hosted', 'macOS', 'ARM64', 'm4mini']), false);
    });
});
