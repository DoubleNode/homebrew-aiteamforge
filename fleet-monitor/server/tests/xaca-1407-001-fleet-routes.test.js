//
//  xaca-1407-001-fleet-routes.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1407-001: fleet-level route set (store + admin API + dispatcher.dispatchFleet).
 * Store/receipt files live in mkdtemp sandboxes; the only provider is an in-memory test
 * provider, so nothing touches the network or any live server.
 */

const { test, describe, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const express = require('express');
const request = require('./helpers/loopback-request');

const FLEET = 'fleet-' + crypto.randomBytes(8).toString('hex');
const ADMIN = 'admin-' + crypto.randomBytes(8).toString('hex');
const SAVED = { a: process.env.FLEET_ADMIN_TOKEN, f: process.env.FLEET_AUTH_TOKEN };
process.env.FLEET_AUTH_TOKEN = FLEET;
process.env.FLEET_ADMIN_TOKEN = ADMIN;

const { createNotifyStore } = require('../lib/notify-store');
const { registerNotifyRoutes } = require('../lib/notify-routes');
const { createNotifyDispatcher } = require('../lib/notify-dispatcher');
const { createReceiptLog } = require('../lib/notify-receipts');
const { createProviderRegistry, createTestProvider } = require('../lib/notify-providers');

const KEY = crypto.randomBytes(32).toString('hex');
let dir, n = 0;
before(() => { dir = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca-1407-001-')); });
after(() => {
    fs.rmSync(dir, { recursive: true, force: true });
    if (SAVED.a === undefined) delete process.env.FLEET_ADMIN_TOKEN; else process.env.FLEET_ADMIN_TOKEN = SAVED.a;
    if (SAVED.f === undefined) delete process.env.FLEET_AUTH_TOKEN; else process.env.FLEET_AUTH_TOKEN = SAVED.f;
});

function build(opts = {}) {
    const id = ++n;
    const clock = () => new Date('2026-03-01T15:00:00Z');
    const provider = createTestProvider();
    const registry = createProviderRegistry();
    registry.register('test', provider);
    const file = path.join(dir, `s-${id}.json`);
    const store = createNotifyStore({ file, key: 'key' in opts ? opts.key : KEY, registry, clock });
    const receipts = createReceiptLog({ file: path.join(dir, `r-${id}.jsonl`), clock });
    const dispatcher = createNotifyDispatcher({ store, registry, receipts, clock });
    const app = express();
    app.use(express.json());
    registerNotifyRoutes(app, { store, registry, receipts, dispatcher, isRegisteredTeam: () => true });
    if (store.status().enabled) {
        for (const cid of ['conn-a', 'conn-b']) store.createConnection({ id: cid, provider: 'test', label: cid, secrets: { token: 'tok' } });
    }
    return { app, store, registry, provider, receipts, dispatcher, file, clock };
}
const admin = (r) => r.set('x-api-key', ADMIN);

describe('store: setFleetRoutes / getFleetRoutes', () => {
    test('stores a validated route set, returns copies, and persists across a reload', () => {
        const c = build();
        assert.equal(c.store.getFleetRoutes(), null);
        const rec = c.store.setFleetRoutes({ routes: { 'machine-offline': ['conn-a', 'conn-b'], 'machine-recovered': [] } });
        assert.deepEqual(rec.routes['machine-offline'], ['conn-a', 'conn-b']);
        assert.equal(rec.updatedAt, '2026-03-01T15:00:00.000Z');
        const got = c.store.getFleetRoutes();
        got.routes['machine-offline'].push('mutated');
        assert.deepEqual(c.store.getFleetRoutes().routes['machine-offline'], ['conn-a', 'conn-b']);

        const reloaded = createNotifyStore({ file: c.file, key: KEY, registry: c.registry });
        assert.deepEqual(reloaded.getFleetRoutes().routes, { 'machine-offline': ['conn-a', 'conn-b'], 'machine-recovered': [] });
        assert.equal(fs.statSync(c.file).mode & 0o777, 0o600);
    });

    test('a second PUT replaces the whole set (not a merge)', () => {
        const c = build();
        c.store.setFleetRoutes({ routes: { 'machine-offline': ['conn-a'] } });
        c.store.setFleetRoutes({ routes: { 'accessory-on-battery': ['conn-b'] } });
        assert.deepEqual(c.store.getFleetRoutes().routes, { 'accessory-on-battery': ['conn-b'] });
    });

    test('rejects unknown notice types, unknown connections, malformed ids, duplicates, bad shapes', () => {
        const c = build();
        const bad = (body, re) => assert.throws(() => c.store.setFleetRoutes(body), (e) => e.status === 400 && re.test(e.message), JSON.stringify(body));
        bad({ routes: { 'not-a-type': ['conn-a'] } }, /unknown notice type 'not-a-type'/);
        bad({ routes: { 'machine-offline': ['ghost'] } }, /unknown connection 'ghost'/);
        bad({ routes: { 'machine-offline': ['BAD ID'] } }, /connection id malformed/);
        bad({ routes: { 'machine-offline': ['conn-a', 'conn-a'] } }, /unique/);
        bad({ routes: { 'machine-offline': 'conn-a' } }, /list of connection ids/);
        bad({ routes: [] }, /routes: must be an object/);
        bad({ routes: {}, extra: 1 }, /unexpected field/);
        bad(null, /body must be an object/);
        bad({ routes: { 'machine-offline': Array.from({ length: 17 }, (_, i) => `c${i}`) } }, /at most 16/);
        assert.equal(c.store.getFleetRoutes(), null, 'a rejected PUT must not mutate state');
    });

    test('disabled store fails closed (503 class), and a pre-1407 file loads with no fleet routes', () => {
        const off = build({ key: null });
        assert.throws(() => off.store.setFleetRoutes({ routes: {} }), (e) => e.status === 503);
        const f = path.join(dir, 'legacy.json');
        fs.writeFileSync(f, JSON.stringify({ version: 1, connections: {}, routes: {}, teamKeys: {} }));
        const legacy = createNotifyStore({ file: f, key: KEY, registry: build().registry });
        assert.equal(legacy.getFleetRoutes(), null);
        assert.equal(legacy.resolveFleetRoutes(), null);
    });

    test('a malformed persisted fleet entry is dropped on load, valid ones kept', () => {
        const c = build();
        c.store.setFleetRoutes({ routes: { 'machine-offline': ['conn-a'] } });
        const j = JSON.parse(fs.readFileSync(c.file, 'utf8'));
        j.fleetRoutes.routes['machine-recovered'] = 'oops';
        j.fleetRoutes.routes['BAD'] = ['conn-a'];
        fs.writeFileSync(c.file, JSON.stringify(j));
        const reloaded = createNotifyStore({ file: c.file, key: KEY, registry: c.registry });
        assert.deepEqual(reloaded.getFleetRoutes().routes, { 'machine-offline': ['conn-a'] });
    });

    test('resolveFleetRoutes shapes {config, catalog} for the dispatcher; catalogTypeIds lists the bundled catalog', () => {
        const c = build();
        c.store.setFleetRoutes({ routes: { 'machine-offline': ['conn-a'] } });
        const r = c.store.resolveFleetRoutes();
        assert.deepEqual(r.config.routes, { 'machine-offline': ['conn-a'] });
        assert.equal(r.catalog['machine-offline'].defaultSeverity, 'critical');
        assert.ok(c.store.catalogTypeIds().includes('accessory-on-battery'));
    });
});

describe('API: GET/PUT /api/notify/fleet-routes (admin tier)', () => {
    test('both verbs reject a missing key, the fleet key, and a wrong key', async () => {
        const { app } = build();
        for (const m of ['get', 'put']) {
            for (const hdr of [null, FLEET, 'wrong']) {
                let r = request(app)[m]('/api/notify/fleet-routes');
                if (hdr) r = r.set('x-api-key', hdr);
                const res = await r.send({ routes: {} });
                assert.ok([401, 403].includes(res.status), `${m} ${hdr} -> ${res.status}`);
            }
        }
    });

    test('a team notify key is not accepted on the fleet route set', async () => {
        const c = build();
        const teamKey = c.store.mintTeamKey('academy');
        const res = await request(c.app).put('/api/notify/fleet-routes').set('x-api-key', teamKey).send({ routes: {} });
        assert.ok([401, 403].includes(res.status), String(res.status));
        assert.equal(c.store.getFleetRoutes(), null);
    });

    test('GET with nothing set -> 200 empty; PUT then GET round-trips; noticeTypes lists the catalog', async () => {
        const { app } = build();
        let r = await admin(request(app).get('/api/notify/fleet-routes'));
        assert.equal(r.status, 200);
        assert.deepEqual(r.body.routes, {});
        assert.equal(r.body.updatedAt, null);
        assert.ok(r.body.noticeTypes.includes('machine-offline'));

        r = await admin(request(app).put('/api/notify/fleet-routes')).send({ routes: { 'machine-offline': ['conn-a'] } });
        assert.equal(r.status, 200, r.text);
        assert.deepEqual(r.body.routes, { 'machine-offline': ['conn-a'] });

        r = await admin(request(app).get('/api/notify/fleet-routes'));
        assert.deepEqual(r.body.routes, { 'machine-offline': ['conn-a'] });
        assert.equal(r.body.updatedAt, '2026-03-01T15:00:00.000Z');
    });

    test('PUT validation errors are 400 and name ids only; disabled store answers 503', async () => {
        const { app } = build();
        let r = await admin(request(app).put('/api/notify/fleet-routes')).send({ routes: { 'machine-offline': ['ghost'] } });
        assert.equal(r.status, 400);
        assert.match(r.body.message, /unknown connection 'ghost'/);
        r = await admin(request(app).put('/api/notify/fleet-routes')).send({ routes: { nope: ['conn-a'] } });
        assert.equal(r.status, 400);

        const off = build({ key: null });
        r = await admin(request(off.app).put('/api/notify/fleet-routes')).send({ routes: {} });
        assert.equal(r.status, 503);
        r = await admin(request(off.app).get('/api/notify/fleet-routes'));
        assert.equal(r.status, 503);
    });
});

describe('dispatcher.dispatchFleet', () => {
    test('delivers through the fleet route set with team "fleet" receipts', async () => {
        const c = build();
        c.store.setFleetRoutes({ routes: { 'machine-offline': ['conn-a', 'conn-b'] } });
        const out = await c.dispatcher.dispatchFleet({ type: 'machine-offline', title: 'T', body: 'B', ref: 'm-1' });
        assert.equal(out.ok, true);
        assert.equal(out.team, 'fleet');
        assert.equal(out.severity, 'critical'); // catalog default
        assert.equal(out.delivered, 2);
        assert.equal(c.provider.calls.length, 2);
        assert.equal(c.provider.calls[0].message.team, 'fleet');
        const recent = c.receipts.recent({ team: 'fleet' });
        assert.equal(recent.length, 2);
        assert.ok(recent.every((r) => r.ok && r.type === 'machine-offline' && r.ref === 'm-1'));
    });

    test('no fleet routes at all, or no route for the type -> unrouted envelope, no throw, no send', async () => {
        const c = build();
        let out = await c.dispatcher.dispatchFleet({ type: 'machine-offline', title: 'T', body: 'B' });
        assert.equal(out.routed, false);
        assert.equal(out.reason, 'no-route');
        c.store.setFleetRoutes({ routes: { 'machine-recovered': ['conn-a'] } });
        out = await c.dispatcher.dispatchFleet({ type: 'machine-offline', title: 'T', body: 'B' });
        assert.equal(out.routed, false);
        assert.equal(out.reason, 'no-route');
        out = await c.dispatcher.dispatchFleet({ type: 'machine-offline', severity: 'info', title: 'T', body: 'B' });
        assert.equal(out.severity, 'info');
        assert.equal(c.provider.calls.length, 0);
    });

    test('caller severity pins; a dangling connection id yields an unknown-connection receipt', async () => {
        const c = build();
        c.store.setFleetRoutes({ routes: { 'machine-recovered': ['conn-a'] } });
        c.store.deleteConnection('conn-a');
        const out = await c.dispatcher.dispatchFleet({ type: 'machine-recovered', title: 'T', body: 'B' });
        assert.equal(out.ok, false);
        assert.equal(out.failed, 1);
        assert.equal(out.receipts[0].error, 'unknown connection');
        assert.equal(out.severity, 'info');
    });
});
