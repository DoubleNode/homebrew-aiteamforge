'use strict';
// XACA-1704-002: GET /api/ci-pool machines[id].eligibility from hostGate() with EFFECTIVE thresholds.
const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');
const { test, after } = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const request = require('./helpers/loopback-request');

const { createPoolStore, GIB } = require('../lib/ci-pool-store');
const { createAssignments } = require('../lib/ci-dispatch-assignments');
const { createAudit } = require('../lib/ci-dispatch-audit');
const { createAlerts } = require('../lib/ci-dispatch-alerts');
const { registerCiPoolRoutes } = require('../lib/ci-pool-routes');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca1704-002-'));
const servers = [];
after(() => { for (const s of servers) s.close(); fs.rmSync(TMP, { recursive: true, force: true }); });

const T0 = Date.UTC(2026, 10, 1, 12, 0, 0);
const CAP = { memTotalBytes: 16 * GIB, memReclaimableBytes: 4 * GIB, memFreePct: 45, swapUsedBytes: 100, swapTotalBytes: 3 * GIB, load1: 1, load5: 1, load15: 1, ncpu: 10, vmState: 'running' };
let seq = 0;

async function get(machines, { config } = {}) {
    const dir = path.join(TMP, `s${++seq}`);
    fs.mkdirSync(dir, { recursive: true });
    const store = createPoolStore({ file: path.join(dir, 'ci-pool.json'), logger: { error() {} } });
    store.load();
    if (config) {
        const r = store.updateConfig(Object.assign({}, config, { thresholds: Object.assign({}, store.getConfig().thresholds, config.thresholds) }));
        assert.equal(r.ok, true, JSON.stringify(r));
    }
    const reports = new Map();
    for (const [id, spec] of Object.entries(machines)) {
        assert.equal(store.upsertMachine(id, Object.assign({ enabled: true }, spec.record || {})).ok, true);
        if (spec.cap) reports.set(id, { receivedAt: T0 - (spec.ageMs || 4000), capacity: Object.assign({}, CAP, spec.cap), slots: [{ os: 'Linux', index: 1, state: 'idle', assignmentId: null }], agentVersion: '1.0.0' });
    }
    const audit = createAudit({ path: path.join(dir, 'a.jsonl'), keep: 2, now: () => new Date(T0) });
    const assignments = createAssignments({ file: path.join(dir, 'st.json'), github: { async generateJitConfig() { return {}; }, async deleteRunner() { return {}; } }, audit, now: () => T0, logger: { error() {}, warn() {} } });
    const app = express();
    registerCiPoolRoutes(app, { store, assignments, audit, reports, now: () => T0, logger: { log() {}, warn() {}, error() {} } });
    const srv = http.createServer(app);
    servers.push(srv);
    await new Promise((r) => srv.listen(0, '127.0.0.1', r));
    const res = await request(srv).get('/api/ci-pool');
    assert.equal(res.status, 200);
    return res.body;
}

test('healthy host: eligible, no reasons, no checks', async () => {
    const b = await get({ m4mini: { cap: {} } });
    assert.deepEqual(b.machines.m4mini.eligibility, {
        eligible: true, reasons: [], checks: [],
        os: { macOS: { eligible: true, reasons: [] }, Linux: { eligible: true, reasons: [] } },
    });
});

test('incident shape: swap-high host reads accepting by state but refused by eligibility, with numbers', async () => {
    const th = { swapUsedBytes: 2867 * 1024 * 1024 };
    const b = await get({ m1mini: { cap: { swapUsedBytes: 2877 * 1024 * 1024 } } }, { config: { thresholds: th } });
    const e = b.machines.m1mini.eligibility;
    assert.equal(e.eligible, false);
    assert.deepEqual(e.reasons, ['swap-high']);
    assert.deepEqual(e.checks, [{ reason: 'swap-high', measured: 2877 * 1024 * 1024, limit: 2867 * 1024 * 1024 }]);
    assert.deepEqual(e.os.macOS.reasons, ['swap-high']);
    assert.deepEqual(e.os.Linux.reasons, ['swap-high']);
});

test('EFFECTIVE limit: per-host override beats pool config', async () => {
    const b = await get({
        a: { cap: { memFreePct: 45 }, record: { thresholds: { memFreePct: 90 } } },
        b: { cap: { memFreePct: 45 } },
    }, { config: { thresholds: { memFreePct: 5 } } });
    assert.deepEqual(b.machines.a.eligibility.checks, [{ reason: 'mem-free-low', measured: 45, limit: 90 }]);
    assert.equal(b.machines.b.eligibility.eligible, true);
});

test('OS breakdown applies job-OS host checks: stopped VM refuses Linux only; low reclaimable refuses macOS only', async () => {
    const b = await get({ vm: { cap: { vmState: 'stopped' } }, mem: { cap: { memReclaimableBytes: 1 } } });
    assert.equal(b.machines.vm.eligibility.eligible, true);   // host-level gate is OS-independent
    assert.deepEqual(b.machines.vm.eligibility.os.Linux, { eligible: false, reasons: ['vm-not-running'] });
    assert.equal(b.machines.vm.eligibility.os.macOS.eligible, true);
    assert.deepEqual(b.machines.mem.eligibility.os.macOS, { eligible: false, reasons: ['mem-reclaimable-low'] });
    assert.equal(b.machines.mem.eligibility.os.Linux.eligible, true);
});

test('no report: eligible false, reasons [no-report], no checks, per-OS also no-report', async () => {
    const b = await get({ ghost: {} });
    assert.deepEqual(b.machines.ghost.eligibility, {
        eligible: false, reasons: ['no-report'], checks: [],
        os: { macOS: { eligible: false, reasons: ['no-report'] }, Linux: { eligible: false, reasons: ['no-report'] } },
    });
});

test('admin state and staleness show up as reasons', async () => {
    const b = await get({ p: { cap: {}, record: { paused: true, enabled: false }, ageMs: 10 * 60 * 1000 } });
    assert.deepEqual(b.machines.p.eligibility.reasons, ['not-enabled', 'paused', 'stale-poll']);
    assert.equal(b.machines.p.eligibility.checks[0].reason, 'stale-poll');
});

test('eligibility carries numbers only: no key material anywhere in the block', async () => {
    const b = await get({ m: { cap: { swapUsedBytes: 9 * GIB } } });
    const s = JSON.stringify(b.machines.m.eligibility);
    assert.ok(!/keyHash|secret|token/i.test(s), s);
});
