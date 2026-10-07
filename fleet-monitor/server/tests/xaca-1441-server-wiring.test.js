//
//  xaca-1441-server-wiring.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1441-007 -- server wiring.
 *
 * server.js binds a port and reads its real data dir at load, so it is never require()d here.
 * Instead: (1) wireCiPool() -- the single composition server.js calls -- is mounted on a bare
 * express app over a temp dir, with FLEET_CI_DISPATCHER unset and a fetch that records (and
 * refuses) every outbound call; (2) server.js is checked structurally for the call sites.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const { test, describe, after } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const express = require('express');

const SAVED = { a: process.env.FLEET_AUTH_TOKEN, b: process.env.FLEET_ADMIN_TOKEN, c: process.env.FLEET_CI_DISPATCHER };
delete process.env.FLEET_AUTH_TOKEN;
delete process.env.FLEET_ADMIN_TOKEN;
delete process.env.FLEET_CI_DISPATCHER;

const { wireCiPool } = require('../lib/ci-dispatcher');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca1441-007-wire-'));
after(() => {
    fs.rmSync(TMP, { recursive: true, force: true });
    for (const [k, v] of [['FLEET_AUTH_TOKEN', SAVED.a], ['FLEET_ADMIN_TOKEN', SAVED.b], ['FLEET_CI_DISPATCHER', SAVED.c]]) {
        if (v === undefined) delete process.env[k]; else process.env[k] = v;
    }
});

const KEY = `fcp_${'K'.repeat(43)}`;
let seq = 0;

function mount(env) {
    const dataDir = path.join(TMP, `d${++seq}`);
    const fetchCalls = [];
    const logs = [];
    const logger = { log: (m) => logs.push(m), warn: (m) => logs.push(m), error: (m) => logs.push(m) };
    const app = express();
    app.use(express.json({ limit: '10mb' }));
    const pool = wireCiPool(app, {
        dataDir, env, logger,
        fetch: async (...a) => { fetchCalls.push(a[0]); throw new Error('network is forbidden in tests'); },
    });
    return { app, pool, dataDir, fetchCalls, logs };
}

const validPoll = () => ({
    schemaVersion: 1, agentVersion: '1.0.0',
    capacity: {
        memTotalBytes: 17179869184, memReclaimableBytes: 4080000000, memFreePct: 45,
        swapUsedBytes: 100, swapTotalBytes: 3221225472, load1: 1.2, load5: 1, load15: 1, ncpu: 10,
        teamSessions: 6, vmState: 'running',
    },
    slots: [{ os: 'Linux', index: 1, state: 'idle', assignmentId: null }],
});

describe('wireCiPool with FLEET_CI_DISPATCHER unset (dormant)', () => {
    test('GET /api/ci-pool answers with dispatcherEnabled:false, empty queue and alerts', async () => {
        const m = mount({});
        const r = await request(m.app).get('/api/ci-pool');
        assert.equal(r.status, 200);
        assert.equal(r.body.dispatcherEnabled, false);
        assert.deepEqual(r.body.queue, []);
        assert.deepEqual(r.body.alerts, []);
        assert.deepEqual(r.body.assignments, []);
        assert.deepEqual(r.body.machines, {});
    });

    test('agent poll answers enabled:false and hands out nothing, even for an enabled machine', async () => {
        const m = mount({});
        assert.equal(m.pool.store.upsertMachine('m4mini', { enabled: true }).ok, true);
        assert.equal(m.pool.store.setHostSecret('m4mini', KEY).ok, true);
        const r = await request(m.app).post('/api/ci-pool/agent/poll').set('Authorization', `Bearer ${KEY}`).send(validPoll());
        assert.equal(r.status, 200);
        assert.equal(r.body.enabled, false);
        assert.deepEqual(r.body.assignments, []);
        assert.ok(r.body.pollAfterSeconds >= 60);
        // the poll fed the capacity report the dispatcher will read once enabled
        assert.ok(m.pool.reports.has('m4mini'));
    });

    test('start() is a no-op: no loop, no outbound call, one dormant log line', async () => {
        const m = mount({});
        assert.equal(m.pool.start(), false);
        assert.equal(m.pool.dispatcher.status().running, false);
        assert.equal(await m.pool.dispatcher.tick(), null);
        await request(m.app).get('/api/ci-pool');
        assert.deepEqual(m.fetchCalls, []);
        assert.equal(m.logs.filter((l) => /dormant/.test(l)).length, 1);
        m.pool.stop();
    });

    test('with the flag set but no App secrets it stays dormant and says so without naming a secret value', () => {
        const m = mount({ FLEET_CI_DISPATCHER: '1' });
        assert.equal(m.pool.dispatcher.isEnabled(), false);
        assert.equal(m.pool.start(), false);
        assert.deepEqual(m.fetchCalls, []);
        assert.ok(m.logs.some((l) => /credentials are not configured/.test(l)));
    });

    test('flag + credentials: the poll reports enabled (not started here, so still no outbound call)', async () => {
        const m = mount({ FLEET_CI_DISPATCHER: '1', GITHUB_APP_CLIENT_ID: 'Iv-test', GITHUB_APP_PRIVATE_KEY: 'fixture-not-a-key' });
        assert.equal(m.pool.store.upsertMachine('m4mini', { enabled: true }).ok, true);
        assert.equal(m.pool.store.setHostSecret('m4mini', KEY).ok, true);
        const g = await request(m.app).get('/api/ci-pool');
        assert.equal(g.body.dispatcherEnabled, true);
        const r = await request(m.app).post('/api/ci-pool/agent/poll').set('Authorization', `Bearer ${KEY}`).send(validPoll());
        assert.equal(r.body.enabled, true);
        assert.deepEqual(m.fetchCalls, []);
    });

    test('save() persists the pool store under dataDir and a second wire reloads it', async () => {
        const m = mount({});
        assert.equal(m.pool.store.updateConfig({ allowlist: ['DoubleNode/dev-team'] }).ok, true);
        assert.equal(m.pool.save().ok, true);
        assert.ok(fs.existsSync(path.join(m.dataDir, 'ci-pool.json')));
        const app2 = express();
        app2.use(express.json());
        const again = wireCiPool(app2, { dataDir: m.dataDir, env: {}, logger: { log() {}, warn() {}, error() {} } });
        assert.deepEqual(again.store.getConfig().allowlist, ['DoubleNode/dev-team']);
    });

    test('no secret-looking text in anything the dormant stack logs', async () => {
        const m = mount({ FLEET_CI_DISPATCHER: '1', GITHUB_APP_PRIVATE_KEY: 'PRIVATE-KEY-SENTINEL-77' });
        m.pool.start();
        assert.equal(m.logs.some((l) => /PRIVATE-KEY-SENTINEL-77/.test(l)), false);
    });
});

describe('server.js call sites (structural)', () => {
    const src = fs.readFileSync(path.join(__dirname, '..', 'server.js'), 'utf8');

    test('requires lib/ci-dispatcher and builds the pool once, BEFORE registerCiRunnersRoutes (XACA-1422: it needs ciPool.store), over data/', () => {
        assert.equal((src.match(/require\('\.\/lib\/ci-dispatcher'\)/g) || []).length, 1);
        const calls = src.match(/wireCiPool\(app,/g) || [];
        assert.equal(calls.length, 1);
        assert.match(src, /const ciPool = wireCiPool\(app, \{ dataDir: path\.join\(__dirname, 'data'\) \}\);/);
        assert.ok(src.indexOf('wireCiPool(app,') < src.indexOf('registerCiRunnersRoutes(app,'));
        assert.match(src, /registerCiRunnersRoutes\(app, \{ poolStore: ciPool\.store \}\)/);
    });

    test('ciPool.save() is in the periodic save block and both shutdown handlers', () => {
        assert.ok(src.includes('ciRunnersStore.save();\n    ciPool.save();\n}, SAVE_INTERVAL_MS);'), 'periodic block has ciPool.save()');
        for (const sig of ['SIGTERM', 'SIGINT']) {
            const at = src.indexOf(`process.on('${sig}'`);
            const block = src.slice(at, src.indexOf('process.exit(0);', at));
            assert.match(block, /ciPool\.stop\(\);/);
            assert.match(block, /ciPool\.save\(\);/);
        }
        assert.equal((src.match(/^\s*ciPool\.save\(\);/gm) || []).length, 3);
    });

    test('ciPool.start() is called inside the app.listen callback', () => {
        const at = src.indexOf('app.listen(PORT, () => {');
        assert.ok(at > 0);
        const end = src.indexOf('\n});', at);
        assert.ok(src.slice(at, end).includes('ciPool.start();'));
        assert.equal((src.match(/^\s*ciPool\.start\(\);/gm) || []).length, 1);
    });
});
