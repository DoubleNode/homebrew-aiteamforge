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

test('XACA-1789: two 50-char machine ids sharing a 40-char prefix both appear, in full (no host-key collision)', async () => {
    const prefix = 'p'.repeat(40);
    const a = prefix + 'aaaaaaaaaa', b = prefix + 'bbbbbbbbbb';
    assert.equal(a.length, 50);
    const s = build({ [a]: { cap: { swapUsedBytes: 3 * GIB } }, [b]: { cap: { swapUsedBytes: 3 * GIB } } });
    s.dispatcher.onJob(job(7, POOL_LINUX), 'queued');
    await s.dispatcher.tick();
    const r = s.dispatcher.queue()[0].refusals;
    assert.deepEqual(Reflect.ownKeys(r).sort(), [a, b]);
    assert.deepEqual(r[a], ['swap-high']);
    assert.deepEqual(r[b], ['swap-high']);
    // The cap is 128 (MACHINE_ID_RE), not unbounded: a longer injected id is truncated, never dropped silently.
    const long = 'L'.repeat(200);
    const s2 = build({ m1mini: { cap: { swapUsedBytes: 3 * GIB } } });
    const realList = s2.store.listMachines.bind(s2.store);
    s2.store.listMachines = () => ({ [long]: realList().m1mini });
    s2.reports.set(long, s2.reports.get('m1mini'));
    s2.dispatcher.onJob(job(8, POOL_LINUX), 'queued');
    await s2.dispatcher.tick();
    const hosts2 = Reflect.ownKeys(s2.dispatcher.queue()[0].refusals);
    assert.equal(hosts2.length, 1);
    assert.equal(hosts2[0].length, 128);
});

test('XACA-1789: the REASONS path strips control characters and caps length on its own (not only via the host path)', async () => {
    // Reasons come from placement, which only emits known codes, so inject dirty ones by wrapping the real
    // evaluateMachines for this one dispatcher (restored in finally). Hosts stay clean: this isolates the reasons map.
    const placement = require('../lib/ci-dispatch-placement');
    const real = placement.evaluateMachines;
    const dirty = 'swap\u0007-high\u001b[31m';
    const longReason = 'x'.repeat(60);
    placement.evaluateMachines = (...args) => real(...args).map((e) => (e.eligible ? e : Object.assign({}, e, { reasons: [dirty, longReason, ...e.reasons] })));
    try {
        const s = build({ m1mini: { cap: { swapUsedBytes: 3 * GIB } } });
        s.dispatcher.onJob(job(9, POOL_LINUX), 'queued');
        await s.dispatcher.tick();
        const r = s.dispatcher.queue()[0].refusals;
        assert.deepEqual(Reflect.ownKeys(r), ['m1mini']);
        const reasons = r.m1mini;
        assert.ok(reasons.length >= 3, JSON.stringify(reasons));   // anti-vacuous: the injection reached refusalsOf
        for (const x of reasons) {
            assert.ok(!/[\u0000-\u001f\u007f]/.test(x), JSON.stringify(x));
            assert.ok(x.length <= 40, JSON.stringify(x));
        }
        assert.ok(reasons.some((x) => x.startsWith('swap') && x.includes('high')));
        assert.ok(reasons.includes('x'.repeat(40)), 'over-long reason truncated to 40, not dropped');
    } finally {
        placement.evaluateMachines = real;
    }
});
