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
const request = require('./helpers/loopback-request');

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

// ===========================================================================
// POST /api/notify/connections/:id/test  (XACA-1405-003)
// ===========================================================================

describe('POST /api/notify/connections/:id/test', () => {
    const { NotifyConfigError: RealConfigError, NotifySendError } = require('../lib/notify-providers');
    const { createReceiptLog } = require('../lib/notify-receipts');
    const DEST = 'dest-' + crypto.randomBytes(6).toString('hex') + '@example.com';

    // One provider factory per test so call counters and switches never leak between tests.
    function makeProvider(name, over) {
        const p = {
            name, paramFields: ['dest'], secretFields: ['token'], calls: [], rejectNow: false, failSend: false, hold: null,
            validate(c) {
                if (p.rejectNow) throw new RealConfigError(`config rejected for ${c.secrets.token}`);
                if (!c.params.dest) throw new RealConfigError('dest is required');
            },
            async send(c, message) {
                p.calls.push({ id: c.id, message });
                if (p.hold) await p.hold;
                if (p.failSend) throw new NotifySendError(`upstream refused ${c.secrets.token} for ${c.params.dest}`);
                return { providerMessageId: 'pm-1' };
            },
        };
        return Object.assign(p, over || {});
    }
    function buildT(provider, { key = KEY, receipts } = {}) {
        const file = path.join(dir, `t-${++n}.json`);
        const reg = { has: (x) => x === provider.name, get: () => provider, names: () => [provider.name] };
        const store = createNotifyStore({ file, key, registry: reg });
        const rlog = receipts || createReceiptLog({ file: path.join(dir, `r-${n}.jsonl`) });
        const app = express();
        app.use(express.json());
        registerNotifyRoutes(app, { store, registry: reg, receipts: rlog });
        return { app, store, rlog, file };
    }
    const mk = (provider, over) => ({ id: 'tconn', provider, label: 'T', params: { dest: DEST }, secrets: { token: SENTINEL }, ...(over || {}) });
    const create = (app, provider, over) => auth(request(app).post('/api/notify/connections')).send(mk(provider, over));
    const leak = (r) => JSON.stringify(r.body) + r.text;

    test('rejects a missing and a wrong admin key', async () => {
        const p = makeProvider('okprov');
        const { app } = buildT(p);
        await create(app, 'okprov');
        const r1 = await request(app).post('/api/notify/connections/tconn/test').send({});
        const r2 = await request(app).post('/api/notify/connections/tconn/test').set('x-api-key', 'wrong').send({});
        assert.ok([401, 403].includes(r1.status), `no key -> ${r1.status}`);
        assert.ok([401, 403].includes(r2.status), `wrong key -> ${r2.status}`);
        assert.equal(p.calls.length, 0);
    });

    test('validate only (empty body and {send:false}): no send, no receipt', async () => {
        const p = makeProvider('okprov');
        const { app, rlog } = buildT(p);
        await create(app, 'okprov');
        for (const b of [undefined, {}, { send: false }]) {
            const r = await auth(request(app).post('/api/notify/connections/tconn/test')).send(b);
            assert.equal(r.status, 200);
            assert.deepEqual(r.body, { ok: true, validated: true, sent: false });
        }
        assert.equal(p.calls.length, 0, 'validate-only must never call send');
        assert.deepEqual(rlog.recent({ limit: 10 }), []);
    });

    test('validation failure: validated false, no send, error scrubbed of the secret', async () => {
        const p = makeProvider('okprov');
        const { app, rlog } = buildT(p);
        await create(app, 'okprov');
        p.rejectNow = true;
        for (const b of [{}, { send: true }]) {
            const r = await auth(request(app).post('/api/notify/connections/tconn/test')).send(b);
            assert.equal(r.status, 200);
            assert.equal(r.body.ok, false);
            assert.equal(r.body.validated, false);
            assert.equal(r.body.sent, false);
            assert.match(r.body.error, /config rejected for \[redacted\]/);
            assert.ok(!leak(r).includes(SENTINEL));
        }
        assert.equal(p.calls.length, 0);
        assert.deepEqual(rlog.recent({ limit: 10 }), [], 'a failed validation is not a delivery attempt');
    });

    test('send:true: ONE send with the fixed message, a type "test" receipt, no secret or destination in any output', async () => {
        const p = makeProvider('okprov');
        const { app, rlog } = buildT(p);
        await create(app, 'okprov');
        const r = await auth(request(app).post('/api/notify/connections/tconn/test')).send({ send: true });
        assert.equal(r.status, 200);
        assert.deepEqual(r.body, { ok: true, validated: true, sent: true });
        assert.equal(p.calls.length, 1);
        assert.equal(p.calls[0].id, 'tconn');
        assert.equal(p.calls[0].message.severity, 'info');
        assert.equal(p.calls[0].message.type, 'test');
        const recs = rlog.recent({ limit: 10 });
        assert.equal(recs.length, 1);
        assert.equal(recs[0].type, 'test');
        assert.equal(recs[0].connectionId, 'tconn');
        assert.equal(recs[0].provider, 'okprov');
        assert.equal(recs[0].ok, true);
        assert.equal(recs[0].providerMessageId, 'pm-1');
        assert.equal(recs[0].stage, undefined, 'a synchronous provider has no accepted stage');
        // The receipt is what the screen's "last delivery" reads.
        const list = await auth(request(app).get('/api/notify/receipts?limit=5'));
        assert.equal(list.body.receipts[0].connectionId, 'tconn');
        for (const out of [leak(r), JSON.stringify(recs), leak(list)]) {
            assert.ok(!out.includes(SENTINEL) && !out.includes(DEST), 'secret or destination leaked');
        }
    });

    test('a failing send answers ok:false with a scrubbed error and records a failed receipt', async () => {
        const p = makeProvider('okprov');
        const { app, rlog } = buildT(p);
        await create(app, 'okprov');
        p.failSend = true;
        const r = await auth(request(app).post('/api/notify/connections/tconn/test')).send({ send: true });
        assert.equal(r.status, 200);
        assert.equal(r.body.ok, false);
        assert.equal(r.body.validated, true);
        assert.equal(r.body.sent, false);
        assert.match(r.body.error, /upstream refused \[redacted\] for \[redacted\]/);
        const rec = rlog.recent({ limit: 1 })[0];
        assert.equal(rec.ok, false);
        assert.equal(rec.type, 'test');
        const all = leak(r) + JSON.stringify(rec);
        assert.ok(!all.includes(SENTINEL) && !all.includes(DEST));
    });

    test('an asyncDelivery provider (imessage-shaped) records stage "accepted"', async () => {
        const p = makeProvider('asyncprov', { asyncDelivery: true });
        const { app, rlog } = buildT(p);
        await create(app, 'asyncprov');
        const r = await auth(request(app).post('/api/notify/connections/tconn/test')).send({ send: true });
        assert.equal(r.body.sent, true);
        assert.equal(rlog.recent({ limit: 1 })[0].stage, 'accepted');
    });

    test('malformed bodies are 400 and never reach the provider', async () => {
        const p = makeProvider('okprov');
        const { app } = buildT(p);
        await create(app, 'okprov');
        for (const b of [{ send: 'yes' }, { send: 1 }, { send: true, extra: 1 }, { foo: 1 }, [true]]) {
            const r = await auth(request(app).post('/api/notify/connections/tconn/test')).send(b);
            assert.equal(r.status, 400, JSON.stringify(b));
            assert.equal(r.body.error, 'invalid');
        }
        assert.equal(p.calls.length, 0);
    });

    test('unknown connection is 404', async () => {
        const { app } = buildT(makeProvider('okprov'));
        const r = await auth(request(app).post('/api/notify/connections/nope/test')).send({ send: true });
        assert.equal(r.status, 404);
        assert.equal(r.body.error, 'not_found');
    });

    test('a disabled store is 503 store_disabled', async () => {
        const saved = process.env.NOTIFY_STORE_KEY;
        delete process.env.NOTIFY_STORE_KEY;
        try {
            const { app } = buildT(makeProvider('okprov'), { key: null });
            const r = await auth(request(app).post('/api/notify/connections/tconn/test')).send({ send: true });
            assert.equal(r.status, 503);
            assert.equal(r.body.error, 'store_disabled');
        } finally {
            if (saved !== undefined) process.env.NOTIFY_STORE_KEY = saved;
        }
    });

    test('unreadable stored secrets (store key changed) are 409 secrets_unreadable, no send', async () => {
        const p = makeProvider('okprov');
        const a = buildT(p);
        await create(a.app, 'okprov');
        // Same file, different key: decrypt fails.
        const reg = { has: () => true, get: () => p, names: () => ['okprov'] };
        const store2 = createNotifyStore({ file: a.file, key: crypto.randomBytes(32).toString('base64'), registry: reg });
        const app2 = express();
        app2.use(express.json());
        registerNotifyRoutes(app2, { store: store2, registry: reg, receipts: a.rlog });
        const r = await auth(request(app2).post('/api/notify/connections/tconn/test')).send({ send: true });
        assert.equal(r.status, 409);
        assert.equal(r.body.error, 'secrets_unreadable');
        assert.equal(p.calls.length, 0);
        assert.ok(!leak(r).includes(SENTINEL));
    });

    test('a second send while one is in flight is 409 conflict (no double send)', async () => {
        let release;
        const p = makeProvider('okprov', { hold: new Promise((res) => { release = res; }) });
        const { app } = buildT(p);
        await create(app, 'okprov');
        const first = auth(request(app).post('/api/notify/connections/tconn/test')).send({ send: true }).then((r) => r);
        for (let i = 0; i < 50 && p.calls.length === 0; i++) await new Promise((res) => setTimeout(res, 10));
        assert.equal(p.calls.length, 1, 'first send reached the provider');
        const second = await auth(request(app).post('/api/notify/connections/tconn/test')).send({ send: true });
        assert.equal(second.status, 409);
        assert.equal(second.body.error, 'conflict');
        release();
        const r1 = await first;
        assert.equal(r1.status, 200);
        assert.equal(p.calls.length, 1);
    });

    test('a receipt write failure is surfaced (500) with the computed result, never swallowed', async () => {
        const p = makeProvider('okprov');
        const rlog = createReceiptLog({ file: path.join(dir, 'unused.jsonl') });
        rlog.append = () => { throw new Error('disk full'); };
        const { app } = buildT(p, { receipts: rlog });
        await create(app, 'okprov');
        const r = await auth(request(app).post('/api/notify/connections/tconn/test')).send({ send: true });
        assert.equal(r.status, 500);
        assert.equal(r.body.error, 'receipt_write_failed');
        assert.deepEqual(r.body.result, { ok: true, validated: true, sent: true });
    });
});
