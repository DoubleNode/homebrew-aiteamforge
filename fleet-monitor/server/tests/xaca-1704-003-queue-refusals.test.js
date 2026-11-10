'use strict';
// XACA-1704-003: queue()[].refusals {host: reasons[]} from the job's LAST evaluateMachines() pass.
const { test, after } = require('node:test');
const assert = require('node:assert/strict');

const { build, job, POOL_M1MINI, POOL_LINUX, GIB } = require('./helpers/xaca-1704-dispatcher-harness');

test('refused job: queue()[].refusals lists every refused host with its reason codes', async () => {
    const s = build({
        m1mini: { cap: { swapUsedBytes: 2877 * 1024 * 1024 } },
        m4mini: { cap: { swapUsedBytes: 3 * GIB, memFreePct: 3 } },
    });
    s.dispatcher.onJob(job(1, POOL_M1MINI), 'queued');
    await s.dispatcher.tick();
    const q = s.dispatcher.queue();
    assert.equal(q.length, 1);
    assert.deepEqual(q[0].refusals.m1mini, ['swap-high']);
    for (const r of ['label-mismatch', 'swap-high', 'mem-free-low']) assert.ok(q[0].refusals.m4mini.includes(r), r);
});

test('a job a host can take has NO refusals (placed) and eligible hosts never appear', async () => {
    const s = build({ m1mini: {}, m4mini: { cap: { swapUsedBytes: 3 * GIB } } });
    s.dispatcher.onJob(job(2, POOL_LINUX), 'queued');
    await s.dispatcher.tick();
    assert.deepEqual(s.dispatcher.queue()[0].refusals, {});
});

test('refusals clear once the host recovers (last pass wins, not sticky)', async () => {
    const s = build({ m1mini: { cap: { swapUsedBytes: 3 * GIB } } });
    s.dispatcher.onJob(job(3, POOL_M1MINI), 'queued');
    await s.dispatcher.tick();
    assert.deepEqual(s.dispatcher.queue()[0].refusals, { m1mini: ['swap-high'] });
    s.reports.get('m1mini').capacity.swapUsedBytes = 100;
    await s.dispatcher.tick();
    assert.deepEqual(s.dispatcher.queue()[0].refusals, {});
});

test('bounded: host count, reasons per host and string length are capped', async () => {
    const m = {};
    for (let i = 0; i < 30; i++) m[`h${String(i).padStart(2, '0')}`] = { cap: { swapUsedBytes: 3 * GIB } };
    const s = build(m);
    s.dispatcher.onJob(job(4, POOL_LINUX), 'queued');
    await s.dispatcher.tick();
    const r = s.dispatcher.queue()[0].refusals;
    assert.equal(Reflect.ownKeys(r).length, 16);
    for (const reasons of Object.values(r)) {
        assert.ok(reasons.length <= 12);
        for (const x of reasons) assert.ok(typeof x === 'string' && x.length <= 40);
    }
});

test('not yet evaluated job (no tick) has empty refusals', () => {
    const s = build({ m1mini: {} });
    s.dispatcher.onJob(job(5, POOL_M1MINI), 'queued');
    assert.deepEqual(s.dispatcher.queue()[0].refusals, {});
});

test('XACA-1704-018: control characters in host ids and reasons are stripped, as the contract documents', async () => {
    // The pool store rejects such ids at the door, so inject one BELOW it (listMachines + reports): refusalsOf is the
    // last line of defence for a string that reaches the operator API and the audit log.
    const s = build({ m1mini: { cap: { swapUsedBytes: 3 * GIB } } });
    const dirty = 'bad\u0007host\u001b[31m';
    const realList = s.store.listMachines.bind(s.store);
    s.store.listMachines = () => { const o = realList(); return { [dirty]: o.m1mini }; };
    s.reports.set(dirty, s.reports.get('m1mini'));
    s.dispatcher.onJob(job(6, POOL_LINUX), 'queued');
    await s.dispatcher.tick();
    const r = s.dispatcher.queue()[0].refusals;
    const hosts = Reflect.ownKeys(r);
    assert.equal(hosts.length, 1, JSON.stringify(hosts));
    assert.ok(!/[\u0000-\u001f\u007f]/.test(hosts[0]), JSON.stringify(hosts[0]));
    assert.ok(hosts[0].startsWith('bad') && hosts[0].includes('host'));
    assert.ok(r[hosts[0]].includes('swap-high'));
    for (const x of r[hosts[0]]) assert.ok(!/[\u0000-\u001f\u007f]/.test(x));
});
