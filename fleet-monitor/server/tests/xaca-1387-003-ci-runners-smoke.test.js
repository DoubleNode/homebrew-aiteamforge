'use strict';

/**
 * XACA-1387-003 smoke test for lib/ci-runners-routes.js. Mounts the real
 * module on a bare express app (no port, temp store file). Thok's dedicated
 * suite (XACA-1387-005) covers push validation/persistence; xaca-1387-016
 * covers the GET contract shape.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const { test } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const express = require('express');

delete process.env.FLEET_AUTH_TOKEN;
const { registerCiRunnersRoutes } = require('../lib/ci-runners-routes');
const { createPoolStore } = require('../lib/ci-pool-store');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca1387-003-'));
const file = path.join(TMP, 'ci-runners.json');

// XACA-1422: the push route takes a per-host telemetry credential from the pool store, not the fleet token.
const CRED = `fct_${'s'.repeat(43)}`;
const bearer = (r) => r.set('Authorization', `Bearer ${CRED}`);

function mount() {
    const app = express();
    app.use(express.json({ limit: '10mb' }));
    const pool = createPoolStore({ file: path.join(TMP, 'ci-pool.json') });
    pool.upsertMachine('m1mini', {});
    assert.ok(pool.setTelemetrySecret('m1mini', CRED).ok);
    const store = registerCiRunnersRoutes(app, { file, poolStore: pool });
    return { app, store };
}

const job = (id, over = {}) => ({
    id, runner: 'm1mini-macos-1', workflow: 'W', jobName: 'j', repo: 'DoubleNode/dev-team',
    runUrl: 'https://github.com/DoubleNode/dev-team/actions/runs/1/job/2',
    startedAt: '2026-10-02T14:10:02Z', endedAt: '2026-10-02T14:17:32Z', result: 'success', minutes: 7.5, ...over,
});
const payload = (over = {}) => ({
    schema_version: 1, machine: 'm1mini', reportedAt: '2026-10-02T14:30:00Z', reporterVersion: '1.0.0',
    host: { uptimeSeconds: 10 }, vm: null,
    runners: [{ name: 'm1mini-macos-1', serviceState: 'up', labels: ['self-hosted'], currentJob: null }],
    jobs: [job('1')], ...over,
});

test('push -> persist -> reload -> GET; bad job dropped; dedupe; 400/413', async () => {
    const { app, store } = mount();
    let r = await bearer(request(app).post('/api/ci-runners-push')).send(payload({ jobs: [job('1', { evil: 'x' }), job('2', { runUrl: 'http://x' })] }));
    assert.equal(r.status, 200);
    assert.equal(r.body.jobsAccepted, 1);
    assert.deepEqual(r.body.jobsRejected.map((j) => j.id), ['2']);
    r = await bearer(request(app).post('/api/ci-runners-push')).send(payload());
    assert.equal(r.body.jobsDuplicate, 1);
    assert.equal((await bearer(request(app).post('/api/ci-runners-push')).send(payload({ schema_version: 2 }))).status, 400);
    const big = payload({ runners: [{ name: 'a', serviceState: 'up', labels: ['x'], currentJob: null, pad: 'y'.repeat(70000) }] });
    assert.equal((await bearer(request(app).post('/api/ci-runners-push')).send(big)).status, 413);

    store.save();
    const { app: app2 } = mount(); // fresh load from disk
    const g = await request(app2).get('/api/ci-runners');
    assert.equal(g.status, 200);
    // v1 contract shape (CI-RUNNERS-API-CONTRACT.md); full shape test is xaca-1387-016.
    assert.equal(g.body.schemaVersion, 1);
    assert.equal(g.body.machines[0].recentJobs.length, 1);
    assert.equal(g.body.machines[0].recentJobs[0].evil, undefined);
    assert.equal(typeof g.body.machines[0].lastReportAt, 'string');
    assert.equal(g.body.machines[0].runners[0].service, 'online');
});

test('corrupt store file starts empty, does not crash', async () => {
    fs.writeFileSync(file, '{not json');
    const { app } = mount();
    const g = await request(app).get('/api/ci-runners');
    assert.equal(g.status, 200);
    assert.deepEqual(g.body.machines, []);
    assert.equal(g.body.summary, null);
});
