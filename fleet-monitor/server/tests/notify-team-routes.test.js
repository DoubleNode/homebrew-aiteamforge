//
//  notify-team-routes.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1400-002: PUT/GET /api/notify/routes/:team. Bare express app + supertest;
 * store file in a mkdtemp sandbox; keys set in-test only.
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
const SENTINEL = 'SENTINEL-s3cret-' + crypto.randomBytes(6).toString('hex');
const SAVED = { a: process.env.FLEET_ADMIN_TOKEN, f: process.env.FLEET_AUTH_TOKEN };
process.env.FLEET_AUTH_TOKEN = FLEET;
delete process.env.FLEET_ADMIN_TOKEN;

const { createNotifyStore } = require('../lib/notify-store');
const { registerNotifyRoutes } = require('../lib/notify-routes');

const stub = { name: 'stub', paramFields: ['url'], secretFields: ['token'], validate() {} };
const registry = { has: (n) => n === 'stub', get: (n) => (n === 'stub' ? stub : undefined), names: () => ['stub'] };
const TEAMS = new Set(['academy', 'ios']);
const KEY = crypto.randomBytes(32).toString('base64');

let dir, n = 0;
before(() => { dir = fs.mkdtempSync(path.join(os.tmpdir(), 'notify-team-routes-test-')); });
after(() => {
    fs.rmSync(dir, { recursive: true, force: true });
    if (SAVED.a !== undefined) process.env.FLEET_ADMIN_TOKEN = SAVED.a;
    if (SAVED.f === undefined) delete process.env.FLEET_AUTH_TOKEN; else process.env.FLEET_AUTH_TOKEN = SAVED.f;
});

function build(key, withGate = true) {
    const file = path.join(dir, `s-${++n}.json`);
    const store = createNotifyStore({ file, key, registry });
    const app = express();
    app.use(express.json());
    const deps = { store, registry };
    if (withGate) deps.isRegisteredTeam = (t) => TEAMS.has(t);
    registerNotifyRoutes(app, deps);
    return { app, store, file };
}
const auth = (r) => r.set('x-api-key', FLEET);
const cfg = (over) => Object.assign({
    $schema: 'release-notify/v2', version: 2,
    routes: { 'pr-merged': ['phone-sms'], 'build-failed': ['phone-sms', 'team-chat'] },
}, over);
const put = (app, team, body) => auth(request(app).put(`/api/notify/routes/${team}`)).send(body);

describe('PUT/GET round trip', () => {
    test('valid push is stored with merged catalog and read back', async () => {
        const { app } = build(KEY);
        const r = await put(app, 'academy', { config: cfg({ severityOverrides: { 'pr-merged': 'warning' }, dedupeWindow: 0 }) });
        assert.equal(r.status, 200, r.text);
        assert.equal(r.body.team, 'academy');
        const g = await auth(request(app).get('/api/notify/routes/academy'));
        assert.equal(g.status, 200);
        assert.deepEqual(g.body.config.routes['build-failed'], ['phone-sms', 'team-chat']);
        assert.equal(g.body.catalog['machine-offline'].defaultSeverity, 'critical');
        assert.equal(g.body.catalog['pr-merged'].source, 'default');
        assert.ok(g.body.updatedAt);
    });
    test('persists across a store reload', async () => {
        const { app, file } = build(KEY);
        await put(app, 'academy', { config: cfg() });
        const again = createNotifyStore({ file, key: KEY, registry });
        assert.equal(again.getTeamRoutes('academy').config.routes['pr-merged'][0], 'phone-sms');
    });
    test('GET before any push is 404', async () => {
        const { app } = build(KEY);
        assert.equal((await auth(request(app).get('/api/notify/routes/ios'))).status, 404);
    });
    test('team A is unaffected by a push for team B', async () => {
        const { app } = build(KEY);
        await put(app, 'academy', { config: cfg() });
        await put(app, 'ios', { config: cfg({ routes: { 'pr-merged': [] } }) });
        const a = await auth(request(app).get('/api/notify/routes/academy'));
        const i = await auth(request(app).get('/api/notify/routes/ios'));
        assert.deepEqual(a.body.config.routes['pr-merged'], ['phone-sms']);
        assert.deepEqual(i.body.config.routes, { 'pr-merged': [] });
    });
    test('a re-push replaces the previous record', async () => {
        const { app } = build(KEY);
        await put(app, 'academy', { config: cfg() });
        await put(app, 'academy', { config: cfg({ routes: { 'pr-merged': ['x-one'] } }) });
        const g = await auth(request(app).get('/api/notify/routes/academy'));
        assert.deepEqual(g.body.config.routes, { 'pr-merged': ['x-one'] });
    });
});

describe('validation', () => {
    async function rejects(body, re) {
        const { app } = build(KEY);
        const r = await put(app, 'academy', body);
        assert.equal(r.status, 400, r.text);
        if (re) assert.match(r.body.message, re);
        assert.equal((await auth(request(app).get('/api/notify/routes/academy'))).status, 404, 'nothing persisted');
        return r;
    }
    test('v1 config rejected with a message that says so', async () => {
        await rejects({ config: { $schema: 'release-notify/v1', version: 1, aliases: {} } }, /release-notify\/v2/);
        await rejects({ config: { version: 1, aliases: {} } }, /\$schema/);
    });
    test('non-object body / missing config rejected', async () => {
        await rejects({});
        await rejects({ config: 'nope' });
    });
    test('unknown type id in routes rejected (id named, value not echoed)', async () => {
        const r = await rejects({ config: cfg({ routes: { 'no-such-type': ['a-b'] } }) }, /unknown notice type 'no-such-type'/);
        assert.doesNotMatch(r.text, /a-b/);
    });
    test('unknown type id in severityOverrides rejected', async () => {
        await rejects({ config: cfg({ severityOverrides: { ghost: 'high' } }) }, /severityOverrides.*ghost/);
    });
    test('bad severity override value rejected', async () => {
        await rejects({ config: cfg({ severityOverrides: { 'pr-merged': 'urgent' } }) }, /severityOverrides/);
    });
    test('team layer adding a new type makes it routable', async () => {
        const { app } = build(KEY);
        const catalog = {
            $schema: 'notice-types/v1', schemaVersion: 1,
            types: [{ id: 'deploy-done', defaultSeverity: 'info', description: 'A deploy finished.' }],
        };
        const r = await put(app, 'academy', { config: cfg({ routes: { 'deploy-done': ['phone-sms'] } }), catalog });
        assert.equal(r.status, 200, r.text);
        const g = await auth(request(app).get('/api/notify/routes/academy'));
        assert.equal(g.body.catalog['deploy-done'].source, 'team');
        assert.equal(g.body.catalog['deploy-done'].severitySource, 'team-catalog');
    });
    test('team layer overriding an existing severity is marked', async () => {
        const { app } = build(KEY);
        const catalog = { $schema: 'notice-types/v1', schemaVersion: 1, types: [{ id: 'pr-merged', defaultSeverity: 'high' }] };
        const r = await put(app, 'academy', { config: cfg(), catalog });
        assert.equal(r.status, 200, r.text);
        const g = await auth(request(app).get('/api/notify/routes/academy'));
        assert.equal(g.body.catalog['pr-merged'].defaultSeverity, 'high');
        assert.equal(g.body.catalog['pr-merged'].source, 'override');
        assert.equal(g.body.catalog['pr-merged'].severitySource, 'team-catalog');
    });
    test('team layer new type missing defaultSeverity rejected', async () => {
        const catalog = { $schema: 'notice-types/v1', schemaVersion: 1, types: [{ id: 'deploy-done', description: 'x' }] };
        await rejects({ config: cfg(), catalog }, /deploy-done.*defaultSeverity/);
    });
    test('team layer duplicate id / bad tag rejected', async () => {
        await rejects({ config: cfg(), catalog: { $schema: 'notice-types/v1', schemaVersion: 1, types: [{ id: 'pr-merged' }, { id: 'pr-merged' }] } }, /duplicate/);
        await rejects({ config: cfg(), catalog: { $schema: 'nope', schemaVersion: 1, types: [{ id: 'pr-merged' }] } }, /\$schema/);
    });
    test('quietHours start == end rejected', async () => {
        await rejects({ config: cfg({ quietHours: { start: '22:00', end: '22:00', timezone: 'UTC' } }) }, /must differ/);
    });
    test('bogus timezone rejected; real zone accepted', async () => {
        await rejects({ config: cfg({ quietHours: { start: '22:00', end: '07:00', timezone: 'Mars/Olympus' } }) }, /IANA/);
        const { app } = build(KEY);
        const r = await put(app, 'academy', { config: cfg({ quietHours: { start: '22:00', end: '07:00', timezone: 'America/Phoenix' } }) });
        assert.equal(r.status, 200, r.text);
    });
    test('malformed HH:MM rejected', async () => {
        await rejects({ config: cfg({ quietHours: { start: '25:00', end: '07:00', timezone: 'UTC' } }) }, /HH:MM/);
    });
    test('dedupeWindow out of range / non-integer rejected', async () => {
        await rejects({ config: cfg({ dedupeWindow: 86401 }) }, /dedupeWindow/);
        await rejects({ config: cfg({ dedupeWindow: -1 }) }, /dedupeWindow/);
        await rejects({ config: cfg({ dedupeWindow: 1.5 }) }, /dedupeWindow/);
        await rejects({ config: cfg({ dedupeWindow: '300' }) }, /dedupeWindow/);
    });
    test('duplicate / oversized / malformed connection lists rejected', async () => {
        await rejects({ config: cfg({ routes: { 'pr-merged': ['a-b', 'a-b'] } }) }, /unique/);
        await rejects({ config: cfg({ routes: { 'pr-merged': Array.from({ length: 17 }, (_, i) => `c${i}`) } }) }, /at most 16/);
        await rejects({ config: cfg({ routes: { 'pr-merged': ['Bad Id'] } }) }, /malformed/);
    });
    test('more than 64 route types rejected', async () => {
        const routes = {};
        for (let i = 0; i < 65; i++) routes[`t${i}`] = [];
        await rejects({ config: cfg({ routes }) }, /at most 64/);
    });
    test('unexpected top-level field and literal secretRef rejected', async () => {
        await rejects({ config: cfg({ extra: 1 }) }, /unexpected/);
        const r = await rejects({ config: cfg({ aliases: { sms: { provider: 'sms', target: { secretRef: 'https://hooks.example/LITERAL' } } } }) }, /secretRef/);
        assert.doesNotMatch(r.text, /LITERAL/);
    });
    test('valid alias with secretRef accepted', async () => {
        const { app } = build(KEY);
        const r = await put(app, 'academy', { config: cfg({ aliases: { sms: { provider: 'sms', target: { secretRef: 'env:RELEASE_ACADEMY_SMS' } } } }) });
        assert.equal(r.status, 200, r.text);
    });
});

describe('auth + team scoping', () => {
    test('no / wrong API key -> 401', async () => {
        const { app } = build(KEY);
        for (const m of ['put', 'get']) {
            assert.equal((await request(app)[m]('/api/notify/routes/academy').send({ config: cfg() })).status, 401);
            assert.equal((await request(app)[m]('/api/notify/routes/academy').set('x-api-key', 'wrong').send({ config: cfg() })).status, 401);
        }
    });
    test('unregistered team -> 404 unknown team', async () => {
        const { app } = build(KEY);
        const r = await put(app, 'nosuchteam', { config: cfg() });
        assert.equal(r.status, 404);
        assert.equal(r.body.message, 'unknown team');
        assert.equal((await auth(request(app).get('/api/notify/routes/nosuchteam'))).status, 404);
    });
    test('missing isRegisteredTeam fails closed', async () => {
        const { app } = build(KEY, false);
        assert.equal((await put(app, 'academy', { config: cfg() })).status, 404);
        assert.equal((await auth(request(app).get('/api/notify/routes/academy'))).status, 404);
    });
    test('malformed team id -> 400', async () => {
        const { app } = build(KEY);
        for (const t of ['Academy', '1abc', 'a_b', 'a'.repeat(65), '..%2Fetc']) {
            const r = await put(app, t, { config: cfg() });
            assert.equal(r.status, 400, `${t} -> ${r.status}`);
        }
    });
    test('disabled store fails closed with 503 (no special-casing)', async () => {
        const { app } = build(null);
        const r = await put(app, 'academy', { config: cfg() });
        assert.equal(r.status, 503);
        assert.equal((await auth(request(app).get('/api/notify/routes/academy'))).status, 503);
    });
});

describe('secrets', () => {
    test('connection secrets never appear in routes responses or the routes record', async () => {
        const { app, store, file } = build(KEY);
        store.createConnection({ id: 'phone-sms', provider: 'stub', label: 'P', params: {}, secrets: { token: SENTINEL } });
        const bodies = [];
        let r = await put(app, 'academy', { config: cfg() }); bodies.push(r.text);
        r = await auth(request(app).get('/api/notify/routes/academy')); bodies.push(r.text);
        r = await put(app, 'academy', { config: cfg({ routes: { ghost: [] } }) }); bodies.push(r.text);
        for (const b of bodies) assert.ok(!b.includes(SENTINEL));
        assert.ok(!fs.readFileSync(file, 'utf8').includes(SENTINEL));
        assert.equal(store.listConnections()[0].secrets.token, 'set');
    });
});
