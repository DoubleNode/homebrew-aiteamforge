//
//  notify-connections-routes.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Integration tests for the /api/notify connection CRUD routes (XACA-1400-001).
 * Bare express app + supertest; store file in a mkdtemp sandbox; admin key and
 * store key are set in-test only.
 */

const { test, describe, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const express = require('express');
const request = require('supertest');

const ADMIN = 'admin-' + crypto.randomBytes(8).toString('hex');
const SENTINEL = 'SENTINEL-s3cret-' + crypto.randomBytes(6).toString('hex');
const SAVED = { a: process.env.FLEET_ADMIN_TOKEN, f: process.env.FLEET_AUTH_TOKEN };
process.env.FLEET_ADMIN_TOKEN = ADMIN;
delete process.env.FLEET_AUTH_TOKEN;

const { createNotifyStore } = require('../lib/notify-store');
const { registerNotifyRoutes } = require('../lib/notify-routes');

class NotifyConfigError extends Error {}
const stub = {
    name: 'stub', paramFields: ['url'], secretFields: ['token'],
    validate(c) {
        if (!c.params.url) throw new NotifyConfigError('url is required');
        if (c.secrets.token === 'leaky') throw new NotifyConfigError(`rejected token leaky and ${c.secrets.token}`);
    },
};
const registry = { has: (n) => n === 'stub', get: (n) => (n === 'stub' ? stub : undefined), names: () => ['stub'] };

let dir, n = 0;
before(() => { dir = fs.mkdtempSync(path.join(os.tmpdir(), 'notify-routes-test-')); });
after(() => {
    fs.rmSync(dir, { recursive: true, force: true });
    if (SAVED.a === undefined) delete process.env.FLEET_ADMIN_TOKEN; else process.env.FLEET_ADMIN_TOKEN = SAVED.a;
    if (SAVED.f !== undefined) process.env.FLEET_AUTH_TOKEN = SAVED.f;
});

function build(key) {
    const file = path.join(dir, `s-${++n}.json`);
    const store = createNotifyStore({ file, key, registry });
    const app = express();
    app.use(express.json());
    registerNotifyRoutes(app, { store, registry });
    return { app, file, store };
}
const KEY = crypto.randomBytes(32).toString('base64');
const auth = (r) => r.set('x-api-key', ADMIN);
const body = (over) => Object.assign({ id: 'phone-sms', provider: 'stub', label: 'Phone', params: { url: 'https://x.example' }, secrets: { token: SENTINEL } }, over);

describe('auth', () => {
    test('every route rejects missing and wrong admin key', async () => {
        const { app } = build(KEY);
        const calls = [
            ['get', '/api/notify/status'], ['get', '/api/notify/connections'], ['get', '/api/notify/connections/x'],
            ['post', '/api/notify/connections'], ['put', '/api/notify/connections/x'], ['delete', '/api/notify/connections/x'],
        ];
        for (const [m, p] of calls) {
            const r1 = await request(app)[m](p).send(body());
            assert.ok([401, 403].includes(r1.status), `${m} ${p} no key -> ${r1.status}`);
            const r2 = await request(app)[m](p).set('x-api-key', 'wrong').send(body());
            assert.ok([401, 403].includes(r2.status), `${m} ${p} wrong key -> ${r2.status}`);
        }
    });
});

describe('CRUD', () => {
    test('create/list/get/update/delete; secrets never in any body or on disk', async () => {
        const { app, file } = build(KEY);
        const bodies = [];
        const note = (r) => { bodies.push(JSON.stringify(r.body) + r.text); return r; };

        let r = note(await auth(request(app).post('/api/notify/connections')).send(body()));
        assert.equal(r.status, 201);
        assert.deepEqual(r.body.secrets, { token: 'set' });

        r = note(await auth(request(app).get('/api/notify/connections')));
        assert.equal(r.status, 200);
        assert.equal(r.body.connections.length, 1);

        r = note(await auth(request(app).get('/api/notify/connections/phone-sms')));
        assert.equal(r.status, 200);
        assert.equal(r.body.label, 'Phone');

        r = note(await auth(request(app).put('/api/notify/connections/phone-sms')).send({ label: 'Renamed', secrets: { token: SENTINEL + '-2' } }));
        assert.equal(r.status, 200);
        assert.equal(r.body.label, 'Renamed');

        // error paths with the sentinel in the submitted body
        for (const bad of [
            body({ id: 'BAD ID' }), body({ id: 'x2', provider: 'nope' }),
            body({ id: 'x3', params: { url: 'u', evil: 1 } }), body({ id: 'x4', secrets: { token: SENTINEL, evil: SENTINEL } }),
            body({ id: 'x5', params: {}, secrets: { token: SENTINEL } }), body({ id: 'x6', secrets: { token: 'leaky' } }),
            body(), // duplicate
        ]) {
            r = note(await auth(request(app).post('/api/notify/connections')).send(bad));
            assert.ok(r.status >= 400 && r.status < 500, `status ${r.status}`);
        }
        r = note(await auth(request(app).put('/api/notify/connections/nope')).send({ secrets: { token: SENTINEL } }));
        assert.equal(r.status, 404);
        r = note(await auth(request(app).get('/api/notify/connections/nope')));
        assert.equal(r.status, 404);
        r = note(await auth(request(app).get('/api/notify/status')));
        assert.deepEqual(r.body, { enabled: true, reason: null, providers: ['stub'] });

        r = note(await auth(request(app).delete('/api/notify/connections/phone-sms')));
        assert.equal(r.status, 200);
        r = note(await auth(request(app).delete('/api/notify/connections/phone-sms')));
        assert.equal(r.status, 404);

        for (const b of bodies) {
            assert.ok(!b.includes(SENTINEL), 'secret leaked in a response body');
            assert.ok(!b.includes('leaky and leaky'), 'provider message not scrubbed');
        }
        assert.ok(!fs.readFileSync(file, 'utf8').includes(SENTINEL));
    });

    test('secret on disk is ciphertext after create', async () => {
        const { app, file } = build(KEY);
        await auth(request(app).post('/api/notify/connections')).send(body());
        const raw = fs.readFileSync(file, 'utf8');
        assert.ok(!raw.includes(SENTINEL));
        assert.ok(JSON.parse(raw).connections['phone-sms'].secrets.token.ct);
    });
});

describe('disabled store', () => {
    for (const [label, key] of [['missing key', undefined], ['malformed key', 'not-a-key']]) {
        test(`${label}: 503 on connection routes, status reports disabled, no file written`, async () => {
            const saved = process.env.NOTIFY_STORE_KEY;
            delete process.env.NOTIFY_STORE_KEY;
            try {
                const { app, file } = build(key === undefined ? null : key);
                for (const [m, p] of [['get', '/api/notify/connections'], ['get', '/api/notify/connections/x'],
                    ['post', '/api/notify/connections'], ['put', '/api/notify/connections/x'], ['delete', '/api/notify/connections/x']]) {
                    const r = await auth(request(app)[m](p)).send(body());
                    assert.equal(r.status, 503, `${m} ${p}`);
                    assert.ok(!(JSON.stringify(r.body) + r.text).includes(SENTINEL));
                }
                const s = await auth(request(app).get('/api/notify/status'));
                assert.equal(s.status, 200);
                assert.equal(s.body.enabled, false);
                assert.ok(s.body.reason);
                assert.ok(!fs.existsSync(file));
            } finally {
                if (saved !== undefined) process.env.NOTIFY_STORE_KEY = saved;
            }
        });
    }
});
