//
//  xaca-1400-006-notify-wiring.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1400-006 -- notification hub wiring.
 *
 * server.js binds a port at load, so it is never require()d. (a) wireNotifyHub() -- the one
 * composition server.js calls -- is mounted on a bare express app over a temp dir; (b) server.js
 * is checked structurally for the require and the single call site.
 */

const { test, describe, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const express = require('express');
const request = require('supertest');

const FLEET = 'fleet-' + crypto.randomBytes(8).toString('hex');
const ADMIN = 'admin-' + crypto.randomBytes(8).toString('hex'); // XACA-1488: a SEPARATE admin tier is required for the notify team routes
const SAVED = { a: process.env.FLEET_ADMIN_TOKEN, f: process.env.FLEET_AUTH_TOKEN, k: process.env.NOTIFY_STORE_KEY };
process.env.FLEET_AUTH_TOKEN = FLEET;
process.env.FLEET_ADMIN_TOKEN = ADMIN;
delete process.env.NOTIFY_STORE_KEY;

const { wireNotifyHub } = require('../lib/notify-routes');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca1400-006-wire-'));
after(() => {
    fs.rmSync(TMP, { recursive: true, force: true });
    for (const [k, v] of [['FLEET_ADMIN_TOKEN', SAVED.a], ['FLEET_AUTH_TOKEN', SAVED.f], ['NOTIFY_STORE_KEY', SAVED.k]]) {
        if (v === undefined) delete process.env[k]; else process.env[k] = v;
    }
});

const KEY = crypto.randomBytes(32).toString('hex');
const TEAMS = new Set(['academy']);
let seq = 0;

function mount(storeKey) {
    const id = ++seq;
    const logs = [];
    const logger = { log: (m) => logs.push(String(m)), warn: (m) => logs.push(String(m)), error: (m) => logs.push(String(m)) };
    const app = express();
    app.use(express.json({ limit: '10mb' }));
    app.get('/ping', (req, res) => res.json({ ok: true }));
    const storeOpts = { file: path.join(TMP, `s-${id}.json`) };
    if (storeKey !== undefined) storeOpts.key = storeKey;
    const hub = wireNotifyHub(app, {
        isRegisteredTeam: (t) => TEAMS.has(t),
        logger, storeOpts, receiptOpts: { file: path.join(TMP, `r-${id}.jsonl`) },
    });
    return { app, hub, logs };
}

const ROUTES = { config: { $schema: 'release-notify/v2', version: 2, routes: { 'pr-merged': ['conn-a'] } } };
const NOTICE = { team: 'academy', type: 'pr-merged', title: 'T-wire', body: 'B-wire', ref: 'PR-1' };

describe('wireNotifyHub with a key', () => {
    test('routes pushed over HTTP + test-provider connection: POST /api/notify delivers end to end', async () => {
        const m = mount(KEY);
        assert.deepEqual(m.hub.store.status(), { enabled: true });
        m.hub.store.createConnection({ id: 'conn-a', provider: 'test', label: 'a', secrets: { token: 'tok-secret' } });
        const put = await request(m.app).put('/api/notify/routes/academy').set('x-api-key', ADMIN).send(ROUTES);
        assert.equal(put.status, 200, put.text);
        const r = await request(m.app).post('/api/notify').set('x-api-key', ADMIN).send(NOTICE);
        assert.equal(r.status, 200, r.text);
        assert.equal(r.body.ok, true);
        assert.equal(r.body.delivered, 1);
        const rec = await request(m.app).get('/api/notify/receipts?team=academy').set('x-api-key', ADMIN);
        assert.equal(rec.status, 200, rec.text);
        assert.equal(rec.body.receipts.length, 1);
        assert.equal(rec.body.receipts[0].ok, true);
    });

    test('an unregistered team is refused (isRegisteredTeam is honoured)', async () => {
        const m = mount(KEY);
        const r = await request(m.app).post('/api/notify').set('x-api-key', ADMIN).send({ ...NOTICE, team: 'nosuch' });
        assert.equal(r.status, 404);
    });

    test('logs exactly one startup line, "enabled", never the key or any part of it', () => {
        const m = mount(KEY);
        assert.equal(m.logs.length, 1);
        assert.match(m.logs[0], /\[NOTIFY\] hub enabled/);
        for (const frag of [KEY, KEY.slice(0, 16), KEY.slice(-16)]) assert.equal(m.logs.join('\n').includes(frag), false);
    });
});

describe('wireNotifyHub without a usable key (disabled)', () => {
    test('no key: status reports disabled, store endpoints 503, the app still serves', async () => {
        const m = mount();
        assert.equal(m.hub.store.status().enabled, false);
        const st = await request(m.app).get('/api/notify/status').set('x-api-key', ADMIN);
        assert.equal(st.status, 200, st.text);
        assert.equal(st.body.enabled, false);
        assert.match(st.body.reason, /NOTIFY_STORE_KEY is not set/);
        assert.ok(st.body.providers.includes('test'));
        for (const r of [
            await request(m.app).get('/api/notify/connections').set('x-api-key', ADMIN),
            await request(m.app).put('/api/notify/routes/academy').set('x-api-key', ADMIN).send(ROUTES),
            await request(m.app).post('/api/notify').set('x-api-key', ADMIN).send(NOTICE),
        ]) assert.equal(r.status, 503, r.text);
        assert.equal((await request(m.app).get('/ping')).status, 200);
        assert.equal(m.logs.length, 1);
        assert.match(m.logs[0], /hub disabled \(NOTIFY_STORE_KEY is not set\)/);
    });

    test('a malformed key disables the hub and is not echoed in the log line', () => {
        const bad = 'BAD-KEY-SENTINEL-' + crypto.randomBytes(6).toString('hex');
        const m = mount(bad);
        assert.equal(m.hub.store.status().enabled, false);
        assert.equal(m.logs.length, 1);
        assert.match(m.logs[0], /hub disabled/);
        assert.equal(m.logs[0].includes(bad), false);
        assert.equal(m.logs[0].includes('BAD-KEY-SENTINEL'), false);
    });

    test('isRegisteredTeam is required', () => {
        assert.throws(() => wireNotifyHub(express(), {}), TypeError);
    });
});

describe('server.js call sites (structural)', () => {
    const src = fs.readFileSync(path.join(__dirname, '..', 'server.js'), 'utf8');

    test('requires wireNotifyHub from lib/notify-routes exactly once', () => {
        assert.equal((src.match(/const \{ wireNotifyHub \} = require\('\.\/lib\/notify-routes'\);/g) || []).length, 1);
    });

    test('calls wireNotifyHub(app, ...) exactly once, after express.json( and registerVaultRoutes(app), before app.listen(', () => {
        assert.equal((src.match(/wireNotifyHub\(app,/g) || []).length, 1);
        const at = src.indexOf('wireNotifyHub(app,');
        assert.ok(src.indexOf('app.use(express.json(') > 0 && src.indexOf('app.use(express.json(') < at, 'after express.json(');
        assert.ok(src.indexOf('registerVaultRoutes(app);') > 0 && src.indexOf('registerVaultRoutes(app);') < at, 'after registerVaultRoutes');
        assert.ok(at < src.indexOf('app.listen(PORT'), 'before app.listen(');
    });

    test('isRegisteredTeam reads the live registeredTeams map', () => {
        assert.match(src, /wireNotifyHub\(app, \{ isRegisteredTeam: \(teamId\) => registeredTeams\.has\(teamId\) \}\);/);
    });
});
