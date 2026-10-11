//
//  xaca-1406-team-connections.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1406-001 -- GET /api/notify/teams/:team/connections (team-key tier).
 * Mounted via wireNotifyHub on a bare express app over a temp dir; team keys are minted
 * through the real admin route.
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
const ADMIN = 'admin-' + crypto.randomBytes(8).toString('hex');
const SAVED = { a: process.env.FLEET_ADMIN_TOKEN, f: process.env.FLEET_AUTH_TOKEN, k: process.env.NOTIFY_STORE_KEY };
process.env.FLEET_AUTH_TOKEN = FLEET;
process.env.FLEET_ADMIN_TOKEN = ADMIN;
delete process.env.NOTIFY_STORE_KEY;

const { wireNotifyHub } = require('../lib/notify-routes');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca1406-conns-'));
const STORE_KEY = crypto.randomBytes(32).toString('hex');
const TEAMS = new Set(['academy', 'ios']);
const SECRET = 'SECRET-TOKEN-VALUE-1406';
let seq = 0;

after(() => {
    fs.rmSync(TMP, { recursive: true, force: true });
    for (const [k, v] of [['FLEET_ADMIN_TOKEN', SAVED.a], ['FLEET_AUTH_TOKEN', SAVED.f], ['NOTIFY_STORE_KEY', SAVED.k]]) {
        if (v === undefined) delete process.env[k]; else process.env[k] = v;
    }
});

function mount() {
    const id = ++seq;
    const quiet = { log() {}, warn() {}, error() {} };
    const app = express();
    app.use(express.json());
    const hub = wireNotifyHub(app, {
        isRegisteredTeam: (t) => TEAMS.has(t), logger: quiet,
        storeOpts: { file: path.join(TMP, `s-${id}.json`), key: STORE_KEY },
        receiptOpts: { file: path.join(TMP, `r-${id}.jsonl`) },
    });
    // A connection that HAS a secret (the 'test' provider is the registry's fixture provider).
    hub.store.createConnection({ id: 'conn-a', provider: 'test', label: 'Alpha', secrets: { token: SECRET } });
    return { app, hub };
}
const as = (r, key) => r.set('x-api-key', key);
const get = (m, team, key) => as(request(m.app).get(`/api/notify/teams/${team}/connections`), key);
async function mint(m, team) {
    const r = await as(request(m.app).post(`/api/notify/teams/${team}/key`), ADMIN);
    assert.equal(r.status, 201, r.text);
    return r.body.key;
}

describe('GET /api/notify/teams/:team/connections', () => {
    test('exact shape: only {team, connections:[{id,provider,label,enabled}]}, no secret material', async () => {
        const m = mount();
        const k = await mint(m, 'academy');
        const r = await get(m, 'academy', k);
        assert.equal(r.status, 200, r.text);
        assert.deepEqual(r.body, {
            team: 'academy',
            connections: [{ id: 'conn-a', provider: 'test', label: 'Alpha', enabled: true }],
        });
        assert.deepEqual(Object.keys(r.body).sort(), ['connections', 'team']);
        assert.deepEqual(Object.keys(r.body.connections[0]).sort(), ['enabled', 'id', 'label', 'provider']);
        assert.ok(!r.text.includes(SECRET));
        assert.ok(!/secrets|params|token|createdAt/.test(r.text), r.text);
    });

    test('empty store returns an empty list, not an error', async () => {
        const m = mount();
        m.hub.store.deleteConnection('conn-a');
        const k = await mint(m, 'academy');
        const r = await get(m, 'academy', k);
        assert.equal(r.status, 200);
        assert.deepEqual(r.body, { team: 'academy', connections: [] });
    });

    test('bogus key and no key: 401', async () => {
        const m = mount();
        assert.equal((await get(m, 'academy', 'fnt_' + 'x'.repeat(40))).status, 401);
        assert.equal((await get(m, 'academy', 'not-a-key')).status, 401);
        assert.equal((await request(m.app).get('/api/notify/teams/academy/connections')).status, 401);
    });

    test('fleet key: 401 (fleet tier does not open team routes)', async () => {
        const m = mount();
        assert.equal((await get(m, 'academy', FLEET)).status, 401);
    });

    test('wrong-team key: 403 with a fixed body that names neither team', async () => {
        const m = mount();
        const k = await mint(m, 'academy');
        const r = await get(m, 'ios', k);
        assert.equal(r.status, 403);
        assert.deepEqual(r.body, { error: 'forbidden', message: 'key not valid for this team' });
    });

    test('admin key keeps existing semantics: any registered team, 404 unknown, 400 malformed', async () => {
        const m = mount();
        for (const t of ['academy', 'ios']) {
            const r = await get(m, t, ADMIN);
            assert.equal(r.status, 200, r.text);
            assert.equal(r.body.team, t);
            assert.equal(r.body.connections.length, 1);
        }
        assert.equal((await get(m, 'nosuchteam', ADMIN)).status, 404);
        assert.equal((await get(m, 'BAD_TEAM', ADMIN)).status, 400);
    });

    test('a valid team key on an unknown team: 404 before the 403 (same ordering as routes)', async () => {
        const m = mount();
        const k = await mint(m, 'academy');
        assert.equal((await get(m, 'nosuchteam', k)).status, 404);
    });
});
