//
//  notify-dispatch.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1400-003: POST /api/notify + GET /api/notify/receipts. Real store and
 * receipt log in a mkdtemp sandbox, injected clock, injected test provider.
 */

const { test, describe, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const express = require('express');
const request = require('supertest');

const FLEET = 'fleet-' + crypto.randomBytes(8).toString('hex');
const SAVED = { a: process.env.FLEET_ADMIN_TOKEN, f: process.env.FLEET_AUTH_TOKEN };
process.env.FLEET_AUTH_TOKEN = FLEET;
delete process.env.FLEET_ADMIN_TOKEN;

const { createNotifyStore } = require('../lib/notify-store');
const { registerNotifyRoutes } = require('../lib/notify-routes');
const { createNotifyDispatcher } = require('../lib/notify-dispatcher');
const { createReceiptLog } = require('../lib/notify-receipts');
const { createProviderRegistry, createTestProvider } = require('../lib/notify-providers');

const SENTINEL = 'SENTINEL-s3cret-' + crypto.randomBytes(6).toString('hex');
const TITLE = 'TITLE-marker-' + crypto.randomBytes(5).toString('hex');
const BODY = 'BODY-marker-' + crypto.randomBytes(5).toString('hex');
const KEY = crypto.randomBytes(32).toString('hex');
const TEAMS = new Set(['academy', 'ios']);

let dir, n = 0;
before(() => { dir = fs.mkdtempSync(path.join(os.tmpdir(), 'notify-dispatch-test-')); });
after(() => {
    fs.rmSync(dir, { recursive: true, force: true });
    if (SAVED.a !== undefined) process.env.FLEET_ADMIN_TOKEN = SAVED.a;
    if (SAVED.f === undefined) delete process.env.FLEET_AUTH_TOKEN; else process.env.FLEET_AUTH_TOKEN = SAVED.f;
});

function hangProvider() {
    return {
        name: 'hang', paramFields: [], secretFields: ['token'],
        validate() {}, send() { return new Promise(() => {}); },
    };
}

function build(opts = {}) {
    const id = ++n;
    const clockState = { now: new Date('2026-03-01T15:00:00Z') };
    const clock = () => clockState.now;
    const provider = createTestProvider();
    const registry = createProviderRegistry();
    registry.register('test', provider);
    registry.register('hang', hangProvider());
    const store = createNotifyStore({ file: path.join(dir, `s-${id}.json`), key: 'key' in opts ? opts.key : KEY, registry });
    const receiptsFile = opts.receiptsFile || path.join(dir, `r-${id}.jsonl`);
    const receipts = createReceiptLog({ file: receiptsFile, clock });
    const dispatcher = createNotifyDispatcher({ store, registry, receipts, clock, sendTimeoutMs: opts.sendTimeoutMs || 200 });
    const app = express();
    app.use(express.json());
    registerNotifyRoutes(app, {
        store: opts.storeWrap ? opts.storeWrap(store) : store, registry, receipts,
        isRegisteredTeam: (t) => TEAMS.has(t),
        dispatcher: opts.storeWrap ? createNotifyDispatcher({ store: opts.storeWrap(store), registry, receipts, clock, sendTimeoutMs: 200 }) : dispatcher,
    });
    if (store.status().enabled) {
        for (const cid of ['conn-a', 'conn-b']) {
            store.createConnection({ id: cid, provider: 'test', label: cid, secrets: { token: SENTINEL } });
        }
    }
    return { app, store, provider, receipts, receiptsFile, clockState };
}

const cfg = (over) => Object.assign({
    $schema: 'release-notify/v2', version: 2,
    routes: { 'pr-merged': ['conn-a', 'conn-b'], 'build-failed': [] },
}, over);
const push = (ctx, config, team = 'academy') => ctx.store.setTeamRoutes(team, { config });
const post = (app, body, key = FLEET) => {
    const r = request(app).post('/api/notify');
    return (key ? r.set('x-api-key', key) : r).send(body);
};
const notice = (over) => Object.assign({ team: 'academy', type: 'pr-merged', title: TITLE, body: BODY, ref: 'PR-1' }, over);
const noLeak = (text) => {
    for (const s of [SENTINEL, TITLE, BODY]) assert.ok(!text.includes(s), `leaked ${s.slice(0, 10)}`);
};

describe('delivery', () => {
    test('happy path: 2 connections, 2 ok receipts persisted, provider got the message', async () => {
        const ctx = build(); push(ctx, cfg());
        const r = await post(ctx.app, notice());
        assert.equal(r.status, 200, r.text);
        assert.equal(r.body.ok, true);
        assert.equal(r.body.delivered, 2);
        assert.equal(r.body.failed, 0);
        assert.equal(r.body.receipts.length, 2);
        assert.ok(r.body.receipts.every((x) => x.ok && x.provider === 'test'));
        assert.equal(ctx.provider.calls.length, 2);
        assert.deepEqual(ctx.provider.calls[0].message, {
            team: 'academy', type: 'pr-merged', title: TITLE, body: BODY, ref: 'PR-1', severity: r.body.severity,
        });
        const persisted = ctx.receipts.recent({ team: 'academy' });
        assert.equal(persisted.length, 2);
        noLeak(r.text);
        noLeak(fs.readFileSync(ctx.receiptsFile, 'utf8'));
    });

    test('caller severity wins over override and catalog default', async () => {
        const ctx = build(); push(ctx, cfg({ severityOverrides: { 'pr-merged': 'warning' } }));
        assert.equal((await post(ctx.app, notice({ ref: 'a' }))).body.severity, 'warning');
        assert.equal((await post(ctx.app, notice({ ref: 'b', severity: 'high' }))).body.severity, 'high');
    });

    test('one connection failing: ok true, failed 1, failure receipt', async () => {
        const ctx = build(); push(ctx, cfg());
        ctx.provider.failNext(1);
        const r = await post(ctx.app, notice());
        assert.equal(r.body.ok, true);
        assert.equal(r.body.delivered, 1);
        assert.equal(r.body.failed, 1);
        const bad = r.body.receipts.filter((x) => !x.ok);
        assert.equal(bad.length, 1);
        assert.equal(bad[0].error, 'test provider forced failure');
    });

    test('all failing: ok false and NO dedupe record, so a re-send goes out', async () => {
        const ctx = build(); push(ctx, cfg());
        ctx.provider.failNext(2);
        const r1 = await post(ctx.app, notice());
        assert.equal(r1.status, 200);
        assert.equal(r1.body.ok, false);
        assert.equal(r1.body.failed, 2);
        const r2 = await post(ctx.app, notice());
        assert.equal(r2.body.ok, true);
        assert.equal(r2.body.delivered, 2);
        assert.equal(r2.body.suppressed, 0);
    });

    test('deleted connection: unknown connection receipt, others still delivered', async () => {
        const ctx = build(); push(ctx, cfg());
        ctx.store.deleteConnection('conn-b');
        const r = await post(ctx.app, notice());
        assert.equal(r.body.ok, true);
        const bad = r.body.receipts.find((x) => !x.ok);
        assert.equal(bad.connectionId, 'conn-b');
        assert.equal(bad.error, 'unknown connection');
    });

    test('hung provider: send timed out', async () => {
        const ctx = build({ sendTimeoutMs: 50 });
        ctx.store.createConnection({ id: 'conn-h', provider: 'hang', label: 'h', secrets: { token: SENTINEL } });
        push(ctx, cfg({ routes: { 'pr-merged': ['conn-h', 'conn-a'] } }));
        const r = await post(ctx.app, notice());
        assert.equal(r.status, 200);
        assert.equal(r.body.ok, true);
        const h = r.body.receipts.find((x) => x.connectionId === 'conn-h');
        assert.equal(h.ok, false);
        assert.equal(h.error, 'send timed out');
        assert.equal(h.provider, 'hang');
    });
});

describe('policies', () => {
    test('dedupe within window: suppressed receipts, provider not called', async () => {
        const ctx = build(); push(ctx, cfg());
        await post(ctx.app, notice());
        ctx.provider.calls.length = 0;
        const r = await post(ctx.app, notice());
        assert.equal(r.status, 200);
        assert.equal(r.body.ok, false);
        assert.equal(r.body.suppressed, 2);
        assert.ok(r.body.receipts.every((x) => x.suppressed === 'dedupe' && x.ok === false));
        assert.equal(ctx.provider.calls.length, 0);
        ctx.clockState.now = new Date(ctx.clockState.now.getTime() + 301 * 1000);
        assert.equal((await post(ctx.app, notice())).body.delivered, 2);
    });

    test('quiet hours suppress info but critical is delivered', async () => {
        const ctx = build();
        push(ctx, cfg({ quietHours: { start: '10:00', end: '20:00', timezone: 'UTC' } }));
        const q = await post(ctx.app, notice({ severity: 'info', ref: 'q1' }));
        assert.equal(q.body.suppressed, 2);
        assert.ok(q.body.receipts.every((x) => x.suppressed === 'quiet-hours'));
        assert.equal(ctx.provider.calls.length, 0);
        const c = await post(ctx.app, notice({ severity: 'critical', ref: 'q2' }));
        assert.equal(c.body.delivered, 2);
    });

    test('invalid quiet-hours zone in stored config: delivered plus a warning', async () => {
        const ctx = build({
            storeWrap: (store) => ({
                ...store,
                getTeamRoutes: (team) => {
                    const rec = store.getTeamRoutes(team);
                    return rec && { ...rec, config: { ...rec.config, quietHours: { start: '10:00', end: '20:00', timezone: 'Mars/Olympus' } } };
                },
            }),
        });
        push(ctx, cfg());
        const r = await post(ctx.app, notice({ severity: 'info' }));
        assert.equal(r.body.delivered, 2);
        assert.deepEqual(r.body.warnings, ['invalid-timezone']);
    });

    test('rate limit: 21st send to a connection is suppressed', async () => {
        const ctx = build(); push(ctx, cfg({ routes: { 'pr-merged': ['conn-a'] } }));
        let last;
        for (let i = 1; i <= 21; i++) last = await post(ctx.app, notice({ ref: `r${i}` }));
        assert.equal(ctx.provider.calls.length, 20);
        assert.equal(last.body.receipts[0].suppressed, 'rate-limit');
        assert.equal(last.body.ok, false);
    });
});

describe('routing outcomes', () => {
    test('no routes pushed: 404', async () => {
        const ctx = build();
        const r = await post(ctx.app, notice());
        assert.equal(r.status, 404);
        assert.equal(r.body.message, 'no routes pushed for team');
    });
    test('unknown type: 400', async () => {
        const ctx = build(); push(ctx, cfg());
        const r = await post(ctx.app, notice({ type: 'no-such-type' }));
        assert.equal(r.status, 400);
        assert.equal(r.body.message, 'unknown notice type');
    });
    test('route-nowhere is an explicit 200 routed:false', async () => {
        const ctx = build(); push(ctx, cfg());
        const r = await post(ctx.app, notice({ type: 'build-failed' }));
        assert.equal(r.status, 200);
        assert.equal(r.body.routed, false);
        assert.equal(r.body.ok, false);
        assert.equal(r.body.reason, 'route-nowhere');
        assert.equal(ctx.provider.calls.length, 0);
    });
    test('type with no route entry: reason no-route', async () => {
        const ctx = build(); push(ctx, cfg({ routes: { 'build-failed': ['conn-a'] } }));
        const r = await post(ctx.app, notice());
        assert.equal(r.status, 200);
        assert.equal(r.body.reason, 'no-route');
    });
});

describe('gate and validation', () => {
    test('unregistered team: 404', async () => {
        const ctx = build();
        assert.equal((await post(ctx.app, notice({ team: 'nope' }))).status, 404);
    });
    test('missing isRegisteredTeam fails closed', async () => {
        const ctx = build();
        const app = express(); app.use(express.json());
        registerNotifyRoutes(app, { store: ctx.store, registry: createProviderRegistry(), receipts: ctx.receipts });
        assert.equal((await post(app, notice())).status, 404);
    });
    test('no API key: 401', async () => {
        const ctx = build(); push(ctx, cfg());
        assert.equal((await post(ctx.app, notice(), null)).status, 401);
        assert.equal(ctx.provider.calls.length, 0);
    });
    test('store disabled: 503', async () => {
        const ctx = build({ key: undefined });
        const r = await post(ctx.app, notice());
        assert.equal(r.status, 503);
    });
    test('bad input: 400 and nothing echoed', async () => {
        const ctx = build(); push(ctx, cfg());
        const ECHO = 'ECHO-' + crypto.randomBytes(4).toString('hex');
        const cases = [
            notice({ [ECHO]: 1 }),
            notice({ title: ECHO.repeat(40) }),
            notice({ title: '' }),
            notice({ body: ECHO.repeat(800) }),
            notice({ ref: `bad ref ${ECHO}` }),
            notice({ severity: ECHO }),
            notice({ type: ECHO }),
            notice({ team: ECHO }),
        ];
        for (const c of cases) {
            const r = await post(ctx.app, c);
            assert.equal(r.status, 400, r.text);
            assert.ok(!r.text.includes(ECHO));
        }
        assert.equal((await post(ctx.app, [1])).status, 400);
        assert.equal(ctx.provider.calls.length, 0);
    });
    test('empty body string is allowed', async () => {
        const ctx = build(); push(ctx, cfg());
        assert.equal((await post(ctx.app, notice({ body: '' }))).status, 200);
    });
});

describe('receipts', () => {
    test('append failure: still 500 with the computed result, never swallowed', async () => {
        const blocker = path.join(dir, 'blocker');
        fs.writeFileSync(blocker, 'x');
        const ctx = build({ receiptsFile: path.join(blocker, 'sub', 'r.jsonl') });
        push(ctx, cfg());
        const r = await post(ctx.app, notice());
        assert.equal(r.status, 500);
        assert.equal(r.body.error, 'receipt_write_failed');
        assert.equal(r.body.result.delivered, 2);
        assert.equal(ctx.provider.calls.length, 2);
        noLeak(r.text);
    });

    test('GET /api/notify/receipts needs the admin key, filters by team, caps limit', async () => {
        const ctx = build(); push(ctx, cfg());
        await post(ctx.app, notice());
        const g = (q, key = FLEET) => request(ctx.app).get(`/api/notify/receipts${q}`).set('x-api-key', key);
        assert.equal((await request(ctx.app).get('/api/notify/receipts')).status, 401);
        const ok = await g('?team=academy&limit=1');
        assert.equal(ok.status, 200);
        assert.equal(ok.body.receipts.length, 1);
        assert.equal((await g('?team=ios')).body.receipts.length, 0);
        assert.equal((await g('?limit=201')).status, 400);
        assert.equal((await g('?limit=abc')).status, 400);
        assert.equal((await g('?team=Bad_Team')).status, 400);
        noLeak(ok.text);
    });
});
