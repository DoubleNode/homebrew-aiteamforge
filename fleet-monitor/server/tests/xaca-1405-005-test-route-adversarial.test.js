//
//  xaca-1405-005-test-route-adversarial.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1405-005: adversarial tests for POST /api/notify/connections/:id/test.
 *
 *   - REAL slack / ntfy / pushover / teams providers (fetch stubbed) whose transport error
 *     text embeds the webhook URL / topic / token: none of it may reach the response or the
 *     receipt, and the receipt carries only allowlisted keys
 *   - timeout path (answers ok:false 'send timed out', aborts the provider's signal)
 *   - the in-flight guard releases after a completed send, a timeout and a receipt-write failure
 *   - two DIFFERENT connections may send concurrently
 *   - object-prototype ids are 404, never a crash or a hit
 *   - admin cookie session without the CSRF header is refused, with it is accepted
 */
const { test, describe, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const express = require('express');
const request = require('./helpers/loopback-request');

const ADMIN = 'admin-' + crypto.randomBytes(8).toString('hex');
const SAVED = { a: process.env.FLEET_ADMIN_TOKEN, f: process.env.FLEET_AUTH_TOKEN };
process.env.FLEET_ADMIN_TOKEN = ADMIN;
delete process.env.FLEET_AUTH_TOKEN;

const { createNotifyStore } = require('../lib/notify-store');
const { registerNotifyRoutes } = require('../lib/notify-routes');
const { createReceiptLog, ALLOWED_FIELDS } = require('../lib/notify-receipts');
const { createProviderRegistry, NotifyConfigError, NotifySendError } = require('../lib/notify-providers');
const { createSlackProvider } = require('../lib/notify-providers/slack');
const { createNtfyProvider } = require('../lib/notify-providers/ntfy');
const { createPushoverProvider } = require('../lib/notify-providers/pushover');
const { createTeamsProvider } = require('../lib/notify-providers/teams');
const adminSession = require('../lib/admin-session');

const KEY = crypto.randomBytes(32).toString('base64');
const auth = (r) => r.set('x-api-key', ADMIN);
let dir, n = 0;
before(() => { dir = fs.mkdtempSync(path.join(os.tmpdir(), 'x1405-005-')); });
after(() => {
    fs.rmSync(dir, { recursive: true, force: true });
    if (SAVED.a === undefined) delete process.env.FLEET_ADMIN_TOKEN; else process.env.FLEET_ADMIN_TOKEN = SAVED.a;
    if (SAVED.f !== undefined) process.env.FLEET_AUTH_TOKEN = SAVED.f;
});

function build(providers, { sendTimeoutMs, receipts } = {}) {
    const registry = createProviderRegistry();
    for (const p of providers) registry.register(p.name, p);
    const file = path.join(dir, `s-${++n}.json`);
    const store = createNotifyStore({ file, key: KEY, registry });
    const rlog = receipts || createReceiptLog({ file: path.join(dir, `r-${n}.jsonl`) });
    const app = express();
    app.use(express.json());
    registerNotifyRoutes(app, { store, registry, receipts: rlog, sendTimeoutMs });
    return { app, store, rlog };
}
const post = (app, id, body) => auth(request(app).post(`/api/notify/connections/${id}/test`)).send(body);
const mkConn = (app, body) => auth(request(app).post('/api/notify/connections')).send(body);
const everything = (r, rlog) => JSON.stringify(r.body) + r.text + JSON.stringify(rlog.recent({ limit: 50 }));

describe('real providers: a transport error that embeds the destination never leaks it', () => {
    const TOKEN = 'tok' + crypto.randomBytes(8).toString('hex');
    const cases = [
        {
            name: 'slack', secrets: { webhookUrl: `https://hooks.slack.com/services/T0001/B0002/${TOKEN}` }, params: {},
            make: (f) => createSlackProvider({ fetchImpl: f }), pieces: [TOKEN, 'T0001', 'B0002', '/services/'],
        },
        {
            name: 'ntfy', secrets: { topic: 'topic' + TOKEN, token: 'tk_' + TOKEN }, params: { server: 'https://ntfy.example.org' },
            make: (f) => createNtfyProvider({ fetchImpl: f }), pieces: [TOKEN, 'ntfy.example.org'],
        },
        {
            name: 'pushover', secrets: { appToken: 'a' + TOKEN, userKey: 'u' + TOKEN }, params: {},
            make: (f) => createPushoverProvider({ fetchImpl: f }), pieces: [TOKEN],
        },
        {
            name: 'teams', secrets: { webhookUrl: `https://prod-01.logic.azure.com/workflows/${TOKEN}/triggers/manual` }, params: { shape: 'flow' },
            make: (f) => createTeamsProvider({ fetchImpl: f }), pieces: [TOKEN, 'prod-01.logic.azure.com'],
        },
    ];
    for (const c of cases) {
        test(`${c.name}: rejected fetch whose message echoes the URL, and a non-2xx`, async () => {
            let mode = 'throw';
            const fetchImpl = async (url) => {
                if (mode === 'throw') throw new TypeError(`request to ${url} failed, reason: connect ECONNREFUSED ${TOKEN}`);
                return { ok: false, status: 500, text: async () => `echo ${TOKEN}` };
            };
            const { app, rlog } = build([c.make(fetchImpl)]);
            const created = await mkConn(app, { id: 'c1', provider: c.name, label: 'C', params: c.params, secrets: c.secrets });
            assert.equal(created.status, 201, created.text);
            for (mode of ['throw', 'status']) {
                const r = await post(app, 'c1', { send: true });
                assert.equal(r.status, 200);
                assert.equal(r.body.ok, false);
                assert.equal(r.body.sent, false);
                assert.ok(r.body.error.length > 0 && r.body.error.length <= 200);
                const all = everything(r, rlog);
                for (const piece of c.pieces) assert.ok(!all.includes(piece), `${c.name}/${mode}: "${piece}" leaked: ${all.slice(0, 300)}`);
            }
            const recs = rlog.recent({ limit: 10 });
            assert.equal(recs.length, 2);
            for (const rec of recs) {
                assert.equal(rec.type, 'test');
                assert.equal(rec.ok, false);
                for (const k of Object.keys(rec)) assert.ok(ALLOWED_FIELDS.includes(k), `receipt key ${k} is not allowlisted`);
                assert.equal(rec.title, undefined);
                assert.equal(rec.body, undefined);
            }
        });
    }
});

describe('timeout, in-flight guard, concurrency', () => {
    function hangingProvider(name) {
        const p = {
            name, paramFields: [], secretFields: ['token'], calls: 0, aborted: 0, mode: 'hang', secretSeen: null,
            validate(c) { if (!c.secrets.token) throw new NotifyConfigError('token required'); },
            async send(c, m, ctx) {
                p.calls += 1;
                if (p.mode === 'hang') {
                    await new Promise((resolve, reject) => ctx.signal.addEventListener('abort', () => { p.aborted += 1; reject(new NotifySendError(`aborted ${c.secrets.token}`)); }, { once: true }));
                }
                return { providerMessageId: 'pm-' + p.calls };
            },
        };
        return p;
    }
    const mk = (id) => ({ id, provider: 'hp', label: id, params: {}, secrets: { token: 'SECRET-TOKEN-VALUE' } });

    test('a hung provider is cut off at the timeout: ok:false "send timed out", signal aborted, failed receipt, guard released', async () => {
        const p = hangingProvider('hp');
        const { app, rlog } = build([p], { sendTimeoutMs: 60 });
        await mkConn(app, mk('slow'));
        const t0 = Date.now();
        const r = await post(app, 'slow', { send: true });
        assert.ok(Date.now() - t0 < 1000, 'answered at the injected timeout, not the 10s default');
        assert.equal(r.status, 200);
        assert.deepEqual(r.body, { ok: false, validated: true, sent: false, error: 'send timed out' });
        assert.equal(p.aborted, 1, 'the provider was told to stop');
        const rec = rlog.recent({ limit: 1 })[0];
        assert.equal(rec.ok, false);
        assert.equal(rec.error, 'send timed out');
        assert.equal(rec.type, 'test');
        p.mode = 'ok';
        const again = await post(app, 'slow', { send: true });
        assert.equal(again.status, 200, 'the in-flight guard was released by the timeout');
        assert.equal(again.body.sent, true);
        assert.ok(!everything(again, rlog).includes('SECRET-TOKEN-VALUE'));
    });

    test('the guard releases after a completed send and after a receipt-write failure', async () => {
        const p = hangingProvider('hp');
        p.mode = 'ok';
        const rlog = createReceiptLog({ file: path.join(dir, 'g.jsonl') });
        const realAppend = rlog.append;
        const { app } = build([p], { receipts: rlog });
        await mkConn(app, mk('g1'));
        assert.equal((await post(app, 'g1', { send: true })).status, 200);
        assert.equal((await post(app, 'g1', { send: true })).status, 200, 'sequential sends are never 409');
        rlog.append = () => { throw new Error('disk full'); };
        assert.equal((await post(app, 'g1', { send: true })).status, 500);
        rlog.append = realAppend;
        const after500 = await post(app, 'g1', { send: true });
        assert.equal(after500.status, 200, 'a receipt-write failure does not wedge the connection at 409');
    });

    test('two different connections may send at the same time; the same one may not', async () => {
        const p = hangingProvider('hp');
        const { app } = build([p], { sendTimeoutMs: 400 });
        await mkConn(app, mk('one'));
        await mkConn(app, mk('two'));
        const a = post(app, 'one', { send: true }).then((r) => r);
        const b = post(app, 'two', { send: true }).then((r) => r);
        for (let i = 0; i < 50 && p.calls < 2; i++) await new Promise((res) => setTimeout(res, 10));
        assert.equal(p.calls, 2, 'both reached the provider concurrently');
        const dup = await post(app, 'one', { send: true });
        assert.equal(dup.status, 409);
        assert.equal(dup.body.error, 'conflict');
        const [ra, rb] = await Promise.all([a, b]);
        assert.equal(ra.status, 200);
        assert.equal(rb.status, 200);
    });

    test('a validate-only request is never blocked by, and never blocks, an in-flight send', async () => {
        const p = hangingProvider('hp');
        const { app } = build([p], { sendTimeoutMs: 300 });
        await mkConn(app, mk('v'));
        const sending = post(app, 'v', { send: true }).then((r) => r);
        for (let i = 0; i < 50 && p.calls < 1; i++) await new Promise((res) => setTimeout(res, 10));
        const v = await post(app, 'v', {});
        assert.deepEqual(v.body, { ok: true, validated: true, sent: false });
        await sending;
    });
});

describe('ids and credentials', () => {
    test('object-prototype and malformed ids are 404, never a crash', async () => {
        const { app } = build([{ name: 'hp', paramFields: [], secretFields: ['token'], validate() {}, async send() { return {}; } }]);
        for (const id of ['__proto__', 'constructor', 'toString', 'hasOwnProperty', '%00', 'a%2Fb', 'x'.repeat(300)]) {
            const r = await post(app, id, { send: true });
            assert.equal(r.status, 404, `${id.slice(0, 20)} -> ${r.status} ${r.text.slice(0, 100)}`);
        }
    });

    test('an admin cookie session needs the CSRF header + matching Origin; header-less is a 401 and never sends', async () => {
        let sends = 0;
        const { app } = build([{ name: 'hp', paramFields: [], secretFields: ['token'], validate() {}, async send() { sends += 1; return {}; } }]);
        await mkConn(app, { id: 'cs', provider: 'hp', label: 'cs', params: {}, secrets: { token: 'x' } });
        const cookie = `${adminSession.COOKIE_NAME}=${adminSession.issueSession(ADMIN).value}`;
        const bare = await request(app).post('/api/notify/connections/cs/test').set('Cookie', cookie).send({ send: true });
        assert.equal(bare.status, 401);
        const crossOrigin = await request(app).post('/api/notify/connections/cs/test').set('Cookie', cookie)
            .set('X-Fleet-CSRF', '1').set('Host', 'fleet.example').set('Origin', 'https://evil.example').send({ send: true });
        assert.equal(crossOrigin.status, 401);
        assert.equal(sends, 0);
        const ok = await request(app).post('/api/notify/connections/cs/test').set('Cookie', cookie)
            .set('X-Fleet-CSRF', '1').set('Host', 'fleet.example').set('Origin', 'https://fleet.example').send({ send: true });
        assert.equal(ok.status, 200, ok.text);
        assert.equal(sends, 1);
    });
});
