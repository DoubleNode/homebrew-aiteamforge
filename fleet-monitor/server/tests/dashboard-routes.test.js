//
//  dashboard-routes.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * Dashboard Configuration Route Tests
 * Tests: GET /api/dashboards, POST /api/dashboards, GET /api/dashboards/:id,
 *        PUT /api/dashboards/:id, DELETE /api/dashboards/:id,
 *        PUT /api/dashboards/reorder, GET /api/divisions
 */
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { createApp } = require('./helpers/app-factory.js');

// Track temp dirs for cleanup
const tmpDirs = [];

// Helper: create app with a fresh temp dir (dashboard file is in tmpDir)
function freshApp() {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fleet-dash-test-'));
    tmpDirs.push(tmpDir);
    return createApp({ tmpDir });
}

// Clean up all temp dirs after tests complete
after(() => {
    for (const dir of tmpDirs) {
        try { fs.rmSync(dir, { recursive: true, force: true }); } catch (e) { /* noop */ }
    }
});

// ============================================================================
// GET /api/dashboards
// ============================================================================

test('GET /api/dashboards returns empty list initially', async () => {
    const { app } = freshApp();
    const res = await request(app).get('/api/dashboards');
    assert.equal(res.status, 200);
    assert.deepEqual(res.body.dashboards, []);
    assert.equal(res.body.total, 0);
});

test('GET /api/dashboards returns dashboards sorted by sort_order', async () => {
    const { app } = freshApp();
    await request(app).post('/api/dashboards').send({ name: 'Zeta', sort_order: 3 });
    await request(app).post('/api/dashboards').send({ name: 'Alpha', sort_order: 1 });
    await request(app).post('/api/dashboards').send({ name: 'Beta', sort_order: 2 });

    const res = await request(app).get('/api/dashboards');
    assert.equal(res.body.total, 3);
    // First created gets sort_order 1, second 2, third 3 — check name order
    const names = res.body.dashboards.map(d => d.name);
    // sort_order is auto-assigned sequentially: Zeta=1, Alpha=2, Beta=3
    assert.equal(names[0], 'Zeta');
    assert.equal(names[1], 'Alpha');
    assert.equal(names[2], 'Beta');
});

// ============================================================================
// POST /api/dashboards
// ============================================================================

test('POST /api/dashboards creates a new dashboard with 201', async () => {
    const { app } = freshApp();
    const res = await request(app).post('/api/dashboards').send({ name: 'Academy Monitor' });
    assert.equal(res.status, 201);
    assert.equal(res.body.id, 'academy-monitor');
    assert.equal(res.body.name, 'Academy Monitor');
    assert.equal(res.body.system, false);
    assert.ok(res.body.created_at);
    assert.ok(res.body.updated_at);
});

test('POST /api/dashboards generates ID from name', async () => {
    const { app } = freshApp();
    const res = await request(app).post('/api/dashboards').send({ name: 'Main Event Ops!' });
    assert.equal(res.body.id, 'main-event-ops');
});

test('POST /api/dashboards appends numeric suffix for duplicate IDs', async () => {
    const { app } = freshApp();
    await request(app).post('/api/dashboards').send({ name: 'Academy' });
    const res = await request(app).post('/api/dashboards').send({ name: 'Academy' });
    assert.equal(res.body.id, 'academy-2');
});

test('POST /api/dashboards increments suffix until unique', async () => {
    const { app } = freshApp();
    await request(app).post('/api/dashboards').send({ name: 'Test' });
    await request(app).post('/api/dashboards').send({ name: 'Test' });
    const res = await request(app).post('/api/dashboards').send({ name: 'Test' });
    assert.equal(res.body.id, 'test-3');
});

test('POST /api/dashboards uppercases title', async () => {
    const { app } = freshApp();
    const res = await request(app).post('/api/dashboards').send({ name: 'academy', title: 'My Title' });
    assert.equal(res.body.title, 'MY TITLE');
});

test('POST /api/dashboards defaults title to uppercased name', async () => {
    const { app } = freshApp();
    const res = await request(app).post('/api/dashboards').send({ name: 'academy' });
    assert.equal(res.body.title, 'ACADEMY');
});

test('POST /api/dashboards defaults subtitle to OPERATIONS MONITOR', async () => {
    const { app } = freshApp();
    const res = await request(app).post('/api/dashboards').send({ name: 'academy' });
    assert.equal(res.body.subtitle, 'OPERATIONS MONITOR');
});

test('POST /api/dashboards sets url_path and html_file from id', async () => {
    const { app } = freshApp();
    const res = await request(app).post('/api/dashboards').send({ name: 'My Dashboard' });
    assert.equal(res.body.url_path, '/lcars/my-dashboard');
    assert.equal(res.body.html_file, 'lcars-my-dashboard.html');
});

test('POST /api/dashboards defaults org_color to lavender', async () => {
    const { app } = freshApp();
    const res = await request(app).post('/api/dashboards').send({ name: 'test' });
    assert.equal(res.body.org_color, 'lavender');
});

test('POST /api/dashboards returns 400 if name is missing', async () => {
    const { app } = freshApp();
    const res = await request(app).post('/api/dashboards').send({ subtitle: 'ops' });
    assert.equal(res.status, 400);
    assert.ok(res.body.error);
});

test('POST /api/dashboards returns 400 if name is empty string', async () => {
    const { app } = freshApp();
    const res = await request(app).post('/api/dashboards').send({ name: '  ' });
    assert.equal(res.status, 400);
});

// ============================================================================
// GET /api/dashboards/:id
// ============================================================================

test('GET /api/dashboards/:id returns specific dashboard', async () => {
    const { app } = freshApp();
    await request(app).post('/api/dashboards').send({ name: 'Academy Monitor' });
    const res = await request(app).get('/api/dashboards/academy-monitor');
    assert.equal(res.status, 200);
    assert.equal(res.body.id, 'academy-monitor');
    assert.equal(res.body.name, 'Academy Monitor');
});

test('GET /api/dashboards/:id returns 404 for unknown id', async () => {
    const { app } = freshApp();
    const res = await request(app).get('/api/dashboards/does-not-exist');
    assert.equal(res.status, 404);
    assert.ok(res.body.error);
});

// ============================================================================
// PUT /api/dashboards/:id
// ============================================================================

test('PUT /api/dashboards/:id updates a dashboard', async () => {
    const { app } = freshApp();
    await request(app).post('/api/dashboards').send({ name: 'Academy Monitor' });
    const res = await request(app)
        .put('/api/dashboards/academy-monitor')
        .send({ name: 'Updated Academy', org_color: 'gold' });
    assert.equal(res.status, 200);
    assert.equal(res.body.name, 'Updated Academy');
    assert.equal(res.body.org_color, 'gold');
});

test('PUT /api/dashboards/:id returns 404 for unknown id', async () => {
    const { app } = freshApp();
    const res = await request(app).put('/api/dashboards/ghost').send({ name: 'Ghost' });
    assert.equal(res.status, 404);
});

test('PUT /api/dashboards/:id updates title to uppercase', async () => {
    const { app } = freshApp();
    await request(app).post('/api/dashboards').send({ name: 'Academy' });
    const res = await request(app)
        .put('/api/dashboards/academy')
        .send({ title: 'new title' });
    assert.equal(res.body.title, 'NEW TITLE');
});

test('PUT /api/dashboards/:id updates subtitle to uppercase', async () => {
    const { app } = freshApp();
    await request(app).post('/api/dashboards').send({ name: 'Academy' });
    const res = await request(app)
        .put('/api/dashboards/academy')
        .send({ subtitle: 'ops center' });
    assert.equal(res.body.subtitle, 'OPS CENTER');
});

test('PUT /api/dashboards/:id updates divisions array', async () => {
    const { app } = freshApp();
    await request(app).post('/api/dashboards').send({ name: 'Academy' });
    const res = await request(app)
        .put('/api/dashboards/academy')
        .send({ divisions: ['academy', 'command'] });
    assert.deepEqual(res.body.divisions, ['academy', 'command']);
});

test('PUT /api/dashboards/:id updates updated_at', async () => {
    const { app } = freshApp();
    const created = await request(app).post('/api/dashboards').send({ name: 'Academy' });
    const originalUpdatedAt = created.body.updated_at;
    await new Promise(r => setTimeout(r, 5));
    const updated = await request(app).put('/api/dashboards/academy').send({ name: 'Academy 2' });
    assert.notEqual(updated.body.updated_at, originalUpdatedAt);
});

// ============================================================================
// DELETE /api/dashboards/:id
// ============================================================================

test('DELETE /api/dashboards/:id deletes a non-system dashboard', async () => {
    const { app } = freshApp();
    await request(app).post('/api/dashboards').send({ name: 'Temporary' });
    const del = await request(app).delete('/api/dashboards/temporary');
    assert.equal(del.status, 200);
    assert.equal(del.body.success, true);
    assert.equal(del.body.deleted_id, 'temporary');

    // Verify it's gone
    const get = await request(app).get('/api/dashboards/temporary');
    assert.equal(get.status, 404);
});

test('DELETE /api/dashboards/:id returns 404 for unknown id', async () => {
    const { app } = freshApp();
    const res = await request(app).delete('/api/dashboards/ghost');
    assert.equal(res.status, 404);
});

test('DELETE /api/dashboards/:id returns 403 for system dashboard', async () => {
    // Pre-populate config with a system dashboard
    const tmpDir2 = fs.mkdtempSync(path.join(os.tmpdir(), 'fleet-sys-test-'));
    tmpDirs.push(tmpDir2);
    const config = {
        dashboards: [{
            id: 'sys-dashboard',
            name: 'System Dashboard',
            system: true,
            sort_order: 1,
            created_at: new Date().toISOString(),
            updated_at: new Date().toISOString(),
            meta: {}
        }],
        divisions: [],
        meta: { version: '1.0.0' }
    };
    fs.writeFileSync(path.join(tmpDir2, 'dashboards.json'), JSON.stringify(config));
    const { app: sysApp } = createApp({ tmpDir: tmpDir2 });

    const res = await request(sysApp).delete('/api/dashboards/sys-dashboard');
    assert.equal(res.status, 403);
    assert.match(res.body.error, /system dashboard/i);
});

// ============================================================================
// PUT /api/dashboards/reorder
// ============================================================================

test('PUT /api/dashboards/reorder reorders dashboards', async () => {
    const { app } = freshApp();
    await request(app).post('/api/dashboards').send({ name: 'Alpha' });
    await request(app).post('/api/dashboards').send({ name: 'Beta' });
    await request(app).post('/api/dashboards').send({ name: 'Gamma' });

    const res = await request(app)
        .put('/api/dashboards/reorder')
        .send({ order: ['gamma', 'alpha', 'beta'] });

    assert.equal(res.status, 200);
    assert.equal(res.body.success, true);
    assert.equal(res.body.order[0], 'gamma');
    assert.equal(res.body.order[1], 'alpha');
    assert.equal(res.body.order[2], 'beta');
});

test('PUT /api/dashboards/reorder returns 400 if order is not an array', async () => {
    const { app } = freshApp();
    const res = await request(app).put('/api/dashboards/reorder').send({ order: 'not-an-array' });
    assert.equal(res.status, 400);
    assert.ok(res.body.error);
});

test('PUT /api/dashboards/reorder returns 400 if order contains unknown id', async () => {
    const { app } = freshApp();
    await request(app).post('/api/dashboards').send({ name: 'Real' });
    const res = await request(app)
        .put('/api/dashboards/reorder')
        .send({ order: ['real', 'ghost-id'] });
    assert.equal(res.status, 400);
    assert.match(res.body.error, /not found/);
});

test('PUT /api/dashboards/reorder returns 400 for missing order field', async () => {
    const { app } = freshApp();
    const res = await request(app).put('/api/dashboards/reorder').send({});
    assert.equal(res.status, 400);
});

// ============================================================================
// GET /api/divisions
// ============================================================================

test('GET /api/divisions returns static divisions from config', async () => {
    const { app } = freshApp();
    const res = await request(app).get('/api/divisions');
    assert.equal(res.status, 200);
    assert.ok(Array.isArray(res.body.divisions));
    assert.ok(typeof res.body.total === 'number');
});
