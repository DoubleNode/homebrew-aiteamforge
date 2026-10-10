//
//  xaca-1488-team-notify-keys.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1488-006 -- per-team notify keys. One test group per Verification Checklist line.
 * Mounted via wireNotifyHub (the real composition) on a bare express app over a temp dir.
 * Team keys are minted through the real admin route, never fabricated.
 */

const { test, describe, after, before } = require('node:test');
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
const { createNotifyStore } = require('../lib/notify-store');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca1488-keys-'));
const STORE_KEY = crypto.randomBytes(32).toString('hex');
const TEAMS = new Set(['academy', 'ios', 'android']);
let seq = 0;

const realConsole = { log: console.log, warn: console.warn, error: console.error };
const captured = [];
before(() => {
    for (const m of ['log', 'warn', 'error']) console[m] = (...a) => { captured.push(a.map(String).join(' ')); };
});
after(() => {
    Object.assign(console, realConsole);
    fs.rmSync(TMP, { recursive: true, force: true });
    for (const [k, v] of [['FLEET_ADMIN_TOKEN', SAVED.a], ['FLEET_AUTH_TOKEN', SAVED.f], ['NOTIFY_STORE_KEY', SAVED.k]]) {
        if (v === undefined) delete process.env[k]; else process.env[k] = v;
    }
});

function mount(storeKey = STORE_KEY, preload) {
    // pass null for a disabled store (undefined would take the default key)
    if (storeKey === null) storeKey = undefined;
    const id = ++seq;
    const logs = [];
    const logger = { log: (m) => logs.push(String(m)), warn: (m) => logs.push(String(m)), error: (m) => logs.push(String(m)) };
    const app = express();
    app.use(express.json());
    const storeFile = path.join(TMP, `s-${id}.json`);
    const receiptFile = path.join(TMP, `r-${id}.jsonl`);
    if (preload) fs.writeFileSync(storeFile, preload);
    const storeOpts = { file: storeFile };
    if (storeKey !== undefined) storeOpts.key = storeKey;
    const hub = wireNotifyHub(app, { isRegisteredTeam: (t) => TEAMS.has(t), logger, storeOpts, receiptOpts: { file: receiptFile } });
    return { app, hub, logs, storeFile, receiptFile };
}

const ROUTES = { config: { $schema: 'release-notify/v2', version: 2, routes: { 'pr-merged': ['conn-a'] } } };
const notice = (team) => ({ team, type: 'pr-merged', title: 'T-1488', body: 'B-1488', ref: 'PR-1' });
const as = (r, key) => r.set('x-api-key', key);

async function mint(m, team) {
    const r = await as(request(m.app).post(`/api/notify/teams/${team}/key`), ADMIN);
    assert.equal(r.status, 201, r.text);
    return r.body.key;
}
function withConn(m) {
    m.hub.store.createConnection({ id: 'conn-a', provider: 'test', label: 'a', secrets: { token: 'tok-secret' } });
}
// The three gated routes, each targeting `team` (path or body binding).
const ROUTE_CALLS = {
    put: (m, team, key) => as(request(m.app).put(`/api/notify/routes/${team}`), key).send(ROUTES),
    get: (m, team, key) => as(request(m.app).get(`/api/notify/routes/${team}`), key),
    post: (m, team, key) => as(request(m.app).post('/api/notify'), key).send(notice(team)),
};

describe('team key scope: own team succeeds, other team 403 (path + body binding)', () => {
    test('team-A key: PUT/GET routes/A and POST /api/notify team A succeed', async () => {
        const m = mount(); withConn(m);
        const k = await mint(m, 'academy');
        assert.match(k, /^fnt_/);
        assert.equal((await ROUTE_CALLS.put(m, 'academy', k)).status, 200);
        assert.equal((await ROUTE_CALLS.get(m, 'academy', k)).status, 200);
        const p = await ROUTE_CALLS.post(m, 'academy', k);
        assert.equal(p.status, 200, p.text);
        assert.equal(p.body.delivered, 1);
    });
    for (const name of ['put', 'get', 'post']) {
        test(`team-A key on team B via ${name}: 403`, async () => {
            const m = mount(); withConn(m);
            const k = await mint(m, 'academy');
            const r = await ROUTE_CALLS[name](m, 'ios', k);
            assert.equal(r.status, 403, r.text);
            assert.equal(r.body.error, 'forbidden');
        });
    }
    test('403 on POST is a binding refusal: nothing was dispatched', async () => {
        const m = mount(); withConn(m);
        const k = await mint(m, 'academy');
        await ROUTE_CALLS.put(m, 'ios', ADMIN);
        await ROUTE_CALLS.post(m, 'ios', k);
        const rec = await as(request(m.app).get('/api/notify/receipts?team=ios'), ADMIN);
        assert.equal(rec.body.receipts.length, 0);
    });
    test('a body naming the key\'s own team does not widen a path bound to another team', async () => {
        const m = mount(); withConn(m);
        const k = await mint(m, 'academy');
        const r = await as(request(m.app).put('/api/notify/routes/ios'), k).send({ ...ROUTES, team: 'academy' });
        assert.equal(r.status, 403);
    });
});

describe('fleet key is rejected on all three routes; admin key succeeds on all three', () => {
    for (const name of ['put', 'get', 'post']) {
        test(`fleet key on ${name}: 401`, async () => {
            const m = mount(); withConn(m);
            await ROUTE_CALLS.put(m, 'academy', ADMIN);
            const r = await ROUTE_CALLS[name](m, 'academy', FLEET);
            assert.equal(r.status, 401, r.text);
        });
        test(`admin key on ${name}: succeeds for any registered team`, async () => {
            const m = mount(); withConn(m);
            for (const t of ['academy', 'ios']) {
                await ROUTE_CALLS.put(m, t, ADMIN);
                const r = await ROUTE_CALLS[name](m, t, ADMIN);
                assert.equal(r.status, 200, r.text);
            }
        });
    }
    test('no credential and garbage credentials: 401', async () => {
        const m = mount();
        assert.equal((await request(m.app).get('/api/notify/routes/academy')).status, 401);
        for (const g of ['fnt_', 'fnt_' + 'x'.repeat(40), 'short', 'fnt_bad key!!!!!!!!!!!!!!']) {
            assert.equal((await as(request(m.app).get('/api/notify/routes/academy'), g)).status, 401, g);
        }
    });
    test('fleet 401 body is byte-identical to the no-credential 401 body', async () => {
        const m = mount();
        const a = await as(request(m.app).get('/api/notify/routes/academy'), FLEET);
        const b = await request(m.app).get('/api/notify/routes/academy');
        assert.equal(a.text, b.text);
    });
});

describe('revoke and re-mint', () => {
    test('revoked key: 401 on all three routes on the next request', async () => {
        const m = mount(); withConn(m);
        const k = await mint(m, 'academy');
        assert.equal((await ROUTE_CALLS.put(m, 'academy', k)).status, 200);
        const d = await as(request(m.app).delete('/api/notify/teams/academy/key'), ADMIN);
        assert.equal(d.status, 200);
        assert.deepEqual(d.body, { team: 'academy', revoked: true });
        for (const name of ['put', 'get', 'post']) assert.equal((await ROUTE_CALLS[name](m, 'academy', k)).status, 401, name);
    });
    test('revoke is idempotent: second DELETE reports revoked false', async () => {
        const m = mount();
        await mint(m, 'academy');
        await as(request(m.app).delete('/api/notify/teams/academy/key'), ADMIN);
        const d = await as(request(m.app).delete('/api/notify/teams/academy/key'), ADMIN);
        assert.equal(d.status, 200);
        assert.equal(d.body.revoked, false);
    });
    test('re-mint invalidates the old key; the new key works', async () => {
        const m = mount();
        const k1 = await mint(m, 'academy');
        const k2 = await mint(m, 'academy');
        assert.notEqual(k1, k2);
        assert.equal((await ROUTE_CALLS.get(m, 'academy', k1)).status, 401);
        assert.equal((await ROUTE_CALLS.get(m, 'academy', k2)).status, 404); // authorised; no routes pushed yet
    });
    test('revoking team A leaves team B key valid', async () => {
        const m = mount();
        const ka = await mint(m, 'academy');
        const kb = await mint(m, 'ios');
        await as(request(m.app).delete('/api/notify/teams/academy/key'), ADMIN);
        assert.equal((await ROUTE_CALLS.get(m, 'academy', ka)).status, 401);
        assert.equal((await ROUTE_CALLS.get(m, 'ios', kb)).status, 404);
    });
    test('keys survive a store reload (hash persisted)', async () => {
        const m = mount();
        const k = await mint(m, 'academy');
        const again = createNotifyStore({ file: m.storeFile, key: STORE_KEY, registry: m.hub.registry });
        assert.equal(again.verifyTeamKey(k), 'academy');
        assert.equal(again.verifyTeamKey(k + 'x'), null);
    });
});

describe('mint response is the only place plaintext appears', () => {
    test('sentinel key never in other responses, logs, store file or receipts file', async () => {
        captured.length = 0;
        const m = mount(); withConn(m);
        const mintRes = await as(request(m.app).post('/api/notify/teams/academy/key'), ADMIN);
        assert.equal(mintRes.status, 201);
        const k = mintRes.body.key;
        assert.match(mintRes.headers['cache-control'], /no-store/);
        assert.equal(mintRes.body.team, 'academy');
        assert.ok(mintRes.body.createdAt);
        assert.ok(mintRes.body.note);
        const bodies = [];
        const take = (r) => { bodies.push(r.text, JSON.stringify(r.headers)); return r; };
        take(await ROUTE_CALLS.put(m, 'academy', k));
        take(await ROUTE_CALLS.get(m, 'academy', k));
        take(await ROUTE_CALLS.post(m, 'academy', k));
        take(await ROUTE_CALLS.get(m, 'ios', k));                  // 403
        take(await ROUTE_CALLS.post(m, 'ios', k));                 // 403
        take(await as(request(m.app).get('/api/notify/status'), ADMIN));
        take(await as(request(m.app).get('/api/notify/connections'), ADMIN));
        take(await as(request(m.app).get('/api/notify/receipts'), ADMIN));
        take(await as(request(m.app).get('/api/notify/routes/academy'), ADMIN));
        take(await as(request(m.app).post('/api/notify/teams/academy/key'), k));   // non-admin mint attempt
        take(await request(m.app).put('/api/notify/routes/academy').set('x-api-key', k).set('content-type', 'application/json').send('{bad json'));
        take(await as(request(m.app).delete('/api/notify/teams/academy/key'), ADMIN));
        take(await ROUTE_CALLS.get(m, 'academy', k));              // revoked 401
        const hay = [...bodies, captured.join('\n'), m.logs.join('\n'),
            fs.readFileSync(m.storeFile, 'utf8'), fs.existsSync(m.receiptFile) ? fs.readFileSync(m.receiptFile, 'utf8') : ''].join('\n');
        const raw = k.slice('fnt_'.length);
        assert.equal(hay.includes(k), false, 'plaintext key leaked');
        assert.equal(hay.includes(raw), false, 'key body leaked');
    });
    test('store file holds only a sha256 hash, not the key', async () => {
        const m = mount();
        const k = await mint(m, 'academy');
        const disk = JSON.parse(fs.readFileSync(m.storeFile, 'utf8'));
        assert.equal(disk.teamKeys.academy.hash, crypto.createHash('sha256').update(k).digest('hex'));
        assert.equal(JSON.stringify(disk).includes(k), false);
    });
});

describe('disabled store', () => {
    test('mint, revoke and the three routes answer 503; nothing written', async () => {
        const m = mount(null);
        assert.equal(m.hub.store.status().enabled, false);
        const fake = () => 'fnt_' + crypto.randomBytes(32).toString('base64url');
        const rs = [
            await as(request(m.app).post('/api/notify/teams/academy/key'), ADMIN),
            await as(request(m.app).delete('/api/notify/teams/academy/key'), ADMIN),
            await ROUTE_CALLS.put(m, 'academy', ADMIN),
            await ROUTE_CALLS.get(m, 'academy', ADMIN),
            await ROUTE_CALLS.post(m, 'academy', ADMIN),
            await ROUTE_CALLS.get(m, 'academy', fake()),
            await ROUTE_CALLS.post(m, 'academy', fake()),
        ];
        for (const r of rs) assert.equal(r.status, 503, r.text);
        assert.equal(fs.existsSync(m.storeFile), false);
        assert.equal(fs.existsSync(m.receiptFile), false);
    });
    test('store API: mint/revoke/verify throw store_disabled', () => {
        const s = createNotifyStore({ file: path.join(TMP, 'dis.json'), key: undefined, registry: mount().hub.registry });
        for (const f of [() => s.mintTeamKey('academy'), () => s.revokeTeamKey('academy'), () => s.verifyTeamKey('fnt_' + 'a'.repeat(40))]) {
            assert.throws(f, (e) => e.code === 'store_disabled');
        }
    });
});

describe('legacy store file (no teamKeys)', () => {
    test('loads unchanged and behaves as no keys minted', async () => {
        const ver = mount().hub.store._state().version;
        const m = mount(STORE_KEY, JSON.stringify({ version: ver, connections: {}, routes: {} }));
        assert.deepEqual(m.hub.store.listTeamKeys(), []);
        assert.equal(m.hub.store.status().enabled, true);
        assert.equal(m.hub.store.status().recovered, undefined);
        const fake = 'fnt_' + crypto.randomBytes(32).toString('base64url');
        assert.equal(m.hub.store.verifyTeamKey(fake), null);
        assert.equal((await ROUTE_CALLS.get(m, 'academy', fake)).status, 401);
        assert.equal((await ROUTE_CALLS.get(m, 'academy', ADMIN)).status, 404);
        const k = await mint(m, 'academy');           // minting works on the legacy file
        assert.equal((await ROUTE_CALLS.get(m, 'academy', k)).status, 404);
    });
    test('malformed teamKeys entries are dropped (fail closed)', () => {
        const ver = mount().hub.store._state().version;
        const m = mount(STORE_KEY, JSON.stringify({ version: ver, connections: {}, routes: {},
            teamKeys: { academy: { hash: 'nothex' }, ios: 'x', 'BAD TEAM': { hash: 'a'.repeat(64) } } }));
        assert.deepEqual(m.hub.store.listTeamKeys(), []);
    });
});

describe('403 body is identical for every wrong-team case and names no team', () => {
    test('byte-identical across routes and team pairs; contains neither team id', async () => {
        const m = mount(); withConn(m);
        const ka = await mint(m, 'academy');
        const ki = await mint(m, 'ios');
        const texts = new Set();
        for (const [k, target] of [[ka, 'ios'], [ka, 'android'], [ki, 'academy'], [ki, 'android']]) {
            for (const name of ['put', 'get', 'post']) {
                const r = await ROUTE_CALLS[name](m, target, k);
                assert.equal(r.status, 403);
                texts.add(r.text);
                for (const t of ['academy', 'ios', 'android']) assert.equal(r.text.includes(t), false, `${t} in 403 body`);
            }
        }
        assert.equal(texts.size, 1, [...texts].join(' | '));
    });
});

describe('mint/revoke are admin-only', () => {
    test('fleet key, team key, and no credential are all rejected 401', async () => {
        const m = mount();
        const k = await mint(m, 'academy');
        for (const key of [FLEET, k, undefined]) {
            for (const method of ['post', 'delete']) {
                const req = request(m.app)[method]('/api/notify/teams/ios/key');
                const r = await (key ? as(req, key) : req);
                assert.equal(r.status, 401, `${method} ${String(key).slice(0, 8)}`);
            }
        }
        assert.deepEqual(m.hub.store.listTeamKeys().map((e) => e.team), ['academy']);
    });
    test('a team key cannot mint a key for its own team', async () => {
        const m = mount();
        const k = await mint(m, 'academy');
        assert.equal((await as(request(m.app).post('/api/notify/teams/academy/key'), k)).status, 401);
        assert.equal((await ROUTE_CALLS.get(m, 'academy', k)).status, 404);
    });
});

// Fail closed unless the admin tier is SEPARATE (FLEET_ADMIN_TOKEN set and different from FLEET_AUTH_TOKEN).
function withPosture(admin, fn) {
    const prev = process.env.FLEET_ADMIN_TOKEN;
    if (admin === undefined) delete process.env.FLEET_ADMIN_TOKEN; else process.env.FLEET_ADMIN_TOKEN = admin;
    const restore = () => { if (prev === undefined) delete process.env.FLEET_ADMIN_TOKEN; else process.env.FLEET_ADMIN_TOKEN = prev; };
    return Promise.resolve().then(fn).then((v) => { restore(); return v; }, (e) => { restore(); throw e; });
}
const NOT_SEPARATE = [
    ['FLEET_ADMIN_TOKEN unset (admin falls back to the fleet key)', undefined],
    ['FLEET_ADMIN_TOKEN identical to FLEET_AUTH_TOKEN', FLEET],
];
describe('admin tier not separate: fail closed', () => {
    for (const [label, admin] of NOT_SEPARATE) {
        test(`${label}: fleet key 401 on all 3 routes, 503 on mint/revoke, nothing minted`, () => withPosture(admin, async () => {
            const m = mount(); withConn(m);
            for (const name of ['put', 'get', 'post']) {
                const r = await ROUTE_CALLS[name](m, 'academy', FLEET);
                assert.equal(r.status, 401, `${name}: ${r.text}`);
            }
            for (const method of ['post', 'delete']) {
                const r = await as(request(m.app)[method]('/api/notify/teams/academy/key'), FLEET);
                assert.equal(r.status, 503, `${method}: ${r.text}`);
                assert.equal(r.body.error, 'admin_tier_not_configured');
                assert.equal(r.body.key, undefined);
            }
            assert.deepEqual(m.hub.store.listTeamKeys(), []);
        }));
        test(`${label}: an existing fnt_ key still works for its own team only`, () => withPosture(admin, async () => {
            const m = mount(); withConn(m);
            const k = m.hub.store.mintTeamKey('academy');
            assert.equal((await ROUTE_CALLS.put(m, 'academy', k)).status, 200);
            assert.equal((await ROUTE_CALLS.post(m, 'academy', k)).status, 200);
            assert.equal((await ROUTE_CALLS.get(m, 'ios', k)).status, 403);
        }));
    }
    test('neither token set (open posture): 3 routes 401 without an fnt_ key, mint/revoke 503', () => {
        const prevF = process.env.FLEET_AUTH_TOKEN;
        delete process.env.FLEET_AUTH_TOKEN;
        return withPosture(undefined, async () => {
            const m = mount(); withConn(m);
            for (const name of ['put', 'get', 'post']) {
                const r = await ROUTE_CALLS[name](m, 'academy', 'x'.repeat(20));
                assert.equal(r.status, 401, name);
                const none = await request(m.app)[name === 'post' ? 'post' : name](name === 'post' ? '/api/notify' : '/api/notify/routes/academy').send(name === 'post' ? notice('academy') : ROUTES);
                assert.equal(none.status, 401, `${name} no credential`);
            }
            for (const method of ['post', 'delete']) {
                const r = await request(m.app)[method]('/api/notify/teams/academy/key');
                assert.equal(r.status, 503, method);
                assert.equal(r.body.error, 'admin_tier_not_configured');
            }
            assert.deepEqual(m.hub.store.listTeamKeys(), []);
        }).finally(() => { process.env.FLEET_AUTH_TOKEN = prevF; });
    });
    test('separate admin token: admin mints (201) and the fleet key still cannot', async () => {
        const m = mount();
        assert.equal((await as(request(m.app).post('/api/notify/teams/academy/key'), FLEET)).status, 401);
        assert.equal((await as(request(m.app).post('/api/notify/teams/academy/key'), ADMIN)).status, 201);
    });
});

describe('team id validation on mint/revoke and gated routes', () => {
    test('unregistered team: 404; malformed id: 400 (admin mint/revoke)', async () => {
        const m = mount();
        assert.equal((await as(request(m.app).post('/api/notify/teams/ghost/key'), ADMIN)).status, 404);
        assert.equal((await as(request(m.app).delete('/api/notify/teams/ghost/key'), ADMIN)).status, 404);
        assert.equal((await as(request(m.app).post('/api/notify/teams/Bad_Team!/key'), ADMIN)).status, 400);
        assert.equal((await as(request(m.app).delete('/api/notify/teams/Bad_Team!/key'), ADMIN)).status, 400);
        assert.deepEqual(m.hub.store.listTeamKeys(), []);
    });
    test('valid key + unregistered/malformed target keeps 404/400 ahead of 403', async () => {
        const m = mount(); withConn(m);
        const k = await mint(m, 'academy');
        assert.equal((await ROUTE_CALLS.get(m, 'ghost', k)).status, 404);
        assert.equal((await ROUTE_CALLS.post(m, 'ghost', k)).status, 404);
        assert.equal((await ROUTE_CALLS.get(m, 'Bad_Team!', k)).status, 400);
        assert.equal((await as(request(m.app).post('/api/notify'), k).send({ ...notice('academy'), type: '!!' })).status, 400);
    });
    test('POST /api/notify with missing/non-string team under a team key is 400, not 500', async () => {
        const m = mount();
        const k = await mint(m, 'academy');
        for (const body of [{}, { ...notice('academy'), team: 5 }, { ...notice('academy'), team: ['academy'] }]) {
            const r = await as(request(m.app).post('/api/notify'), k).send(body);
            assert.equal(r.status, 400, r.text);
        }
    });
});
