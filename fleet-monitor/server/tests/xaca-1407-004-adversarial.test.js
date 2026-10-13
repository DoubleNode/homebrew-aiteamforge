//
//  xaca-1407-004-adversarial.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1407-004 -- adversarial pass over fleet-originated notices.
 * Fake clocks, mkdtemp stores, in-memory test provider; server.js is never required and no
 * network or live service is touched.
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
const ENV = process['env'];
const SAVED = { a: ENV.FLEET_ADMIN_TOKEN, k: ENV.NOTIFY_STORE_KEY };
ENV.FLEET_ADMIN_TOKEN = ADMIN;
delete ENV.NOTIFY_STORE_KEY;

const { createNotifyStore } = require('../lib/notify-store');
const { registerNotifyRoutes } = require('../lib/notify-routes');
const { createNotifyDispatcher } = require('../lib/notify-dispatcher');
const { createReceiptLog } = require('../lib/notify-receipts');
const { createProviderRegistry, createTestProvider } = require('../lib/notify-providers');
const fleetNotices = require('../lib/fleet-notices');
const { createMachineNoticeTracker, createAccessoryNoticeTracker } = require('../lib/fleet-notice-sources');
const { createAlerts } = require('../lib/ci-dispatch-alerts');

const KEY = crypto.randomBytes(32).toString('hex');
let dir, n = 0;
before(() => { dir = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca-1407-004-')); });
after(() => {
    fs.rmSync(dir, { recursive: true, force: true });
    fleetNotices._reset();
    if (SAVED.a === undefined) delete ENV.FLEET_ADMIN_TOKEN; else ENV.FLEET_ADMIN_TOKEN = SAVED.a;
    if (SAVED.k !== undefined) ENV.NOTIFY_STORE_KEY = SAVED.k;
});

// ---------------------------------------------------------------------------------------------
// machine tracker, fake clock
// ---------------------------------------------------------------------------------------------
const W = 1000;
function machine(extra = {}) {
    const state = { t: 1_000_000, out: [] };
    const tr = createMachineNoticeTracker(Object.assign({
        emit: (x) => state.out.push(x), now: () => state.t, flapWindowMs: W, logger: { warn() {}, log() {} },
    }, extra));
    const at = (dt) => { state.t += dt; };
    const types = () => state.out.map((x) => x.type);
    return { state, tr, at, types };
}

describe('machine tracker: window boundaries', () => {
    test('still-down escalation fires at exactly flapWindowMs (not before) and exactly ONCE', () => {
        const m = machine();
        m.tr.observe('m1', 'online');                 // baseline
        m.at(10); assert.equal(m.tr.observe('m1', 'offline'), 'offline');
        m.at(10); assert.equal(m.tr.observe('m1', 'online'), 'recovered');
        m.at(10); assert.equal(m.tr.observe('m1', 'offline'), 'suppressed-offline');
        m.at(W - 1); assert.equal(m.tr.observe('m1', 'offline'), null, 'one ms short of the window');
        m.at(1); assert.equal(m.tr.observe('m1', 'offline'), 'escalated-offline', 'exactly the window');
        for (let i = 0; i < 20; i++) { m.at(30_000); assert.equal(m.tr.observe('m1', 'offline'), null); }
        assert.deepEqual(m.types(), ['machine-offline', 'machine-recovered', 'machine-offline']);
        m.at(5); m.tr.observe('m1', 'online');
        assert.deepEqual(m.types().slice(-1), ['machine-recovered'], 'the escalated offline is paired with its recovery');
    });

    test('an offline exactly flapWindowMs after a recovery is NOT suppressed; one ms earlier is', () => {
        for (const [gap, expected] of [[W - 1, 'suppressed-offline'], [W, 'offline']]) {
            const m = machine();
            m.tr.observe('m1', 'online');
            m.at(5); m.tr.observe('m1', 'offline');
            m.at(5); m.tr.observe('m1', 'online');
            m.at(gap); assert.equal(m.tr.observe('m1', 'offline'), expected, `gap ${gap}`);
        }
    });

    test('a flap storm inside one window yields exactly one offline/recovered pair', () => {
        const m = machine();
        m.tr.observe('m1', 'online');
        for (let i = 0; i < 12; i++) {
            m.at(10); m.tr.observe('m1', 'offline');
            m.at(10); m.tr.observe('m1', 'online');
        }
        assert.deepEqual(m.types(), ['machine-offline', 'machine-recovered']);
    });

    test('flapWindowMs 0 disables damping: every real edge notifies', () => {
        const m = machine({ flapWindowMs: 0 });
        m.tr.observe('m1', 'online');
        for (let i = 0; i < 3; i++) { m.at(1); m.tr.observe('m1', 'offline'); m.at(1); m.tr.observe('m1', 'online'); }
        assert.equal(m.types().filter((t) => t === 'machine-offline').length, 3);
        assert.equal(m.types().filter((t) => t === 'machine-recovered').length, 3);
    });
});

describe('machine tracker: duplicate observers, removal, restart', () => {
    test('heartbeat path and tick path both observing one recovery -> ONE machine-recovered', () => {
        const m = machine();
        m.tr.observe('m1', 'online');
        m.at(5); m.tr.observe('m1', 'offline');
        m.at(5); m.tr.observe('m1', 'online');   // heartbeat
        m.tr.observe('m1', 'online');             // same-instant tick
        m.at(30_000); m.tr.observe('m1', 'warning'); m.tr.observe('m1', 'online');
        assert.equal(m.types().filter((t) => t === 'machine-recovered').length, 1);
    });

    test('removing a machine mid-window leaks no state and no deferred notice ever fires', () => {
        const m = machine();
        m.tr.observe('m1', 'online');
        m.at(5); m.tr.observe('m1', 'offline');
        m.at(5); m.tr.observe('m1', 'online');
        m.at(5); m.tr.observe('m1', 'offline');          // suppressed, pending escalation
        const before = m.state.out.length;
        m.tr.forget('m1');
        assert.equal(m.tr._size(), 0);
        m.at(10 * W);                                     // nothing observes it; time passes
        assert.equal(m.state.out.length, before, 'no timer-driven emit for a deleted machine');
        // If it ever reappears already down it is a fresh baseline, not an offline burst.
        assert.equal(m.tr.observe('m1', 'offline'), 'baseline');
        assert.equal(m.state.out.length, before);
    });

    test('server restart: machine stale at boot is baselined silently, its recovery IS announced once', () => {
        const m = machine();
        assert.equal(m.tr.observe('m1', 'offline'), 'baseline');
        m.at(30_000); assert.equal(m.tr.observe('m1', 'offline'), null);
        assert.equal(m.state.out.length, 0);
        m.at(30_000); assert.equal(m.tr.observe('m1', 'online'), 'recovered');
        assert.deepEqual(m.types(), ['machine-recovered']);
    });

    test('garbage input never throws and never emits', () => {
        const m = machine();
        for (const [id, st] of [[undefined, 'online'], ['', 'online'], [5, 'online'], ['m1', 'bogus'], ['m1', undefined], ['m1', null], ['m1', 'OFFLINE']]) {
            assert.doesNotThrow(() => m.tr.observe(id, st));
        }
        assert.equal(m.state.out.length, 0);
        assert.equal(m.tr._size(), 0, 'rejected observations must not create state');
    });
});

describe('machine tracker: emitter failures and untrusted labels', () => {
    test('sync-throwing and async-rejecting emitters never propagate (no unhandled rejection)', async () => {
        const rejections = [];
        const onRej = (e) => rejections.push(e);
        process.on('unhandledRejection', onRej);
        try {
            for (const emit of [() => { throw new Error('boom'); }, () => Promise.reject(new Error('async boom'))]) {
                const m = machine({ emit });
                m.tr.observe('m1', 'online');
                m.at(1);
                assert.doesNotThrow(() => m.tr.observe('m1', 'offline'));
                m.at(1);
                assert.doesNotThrow(() => m.tr.observe('m1', 'online'));
            }
            await new Promise((r) => setImmediate(r));
            await new Promise((r) => setImmediate(r));
        } finally { process.off('unhandledRejection', onRej); }
        assert.deepEqual(rejections, []);
    });

    test('hostile label / lastSeen are scrubbed of control chars and bounded in title, body and ref', () => {
        const m = machine();
        m.tr.observe('m1', 'online');
        m.at(1);
        m.tr.observe('m1', 'offline', { label: 'evil\nname\r\u0000\u001b[31m' + 'x'.repeat(5000), lastSeen: 'L\n' + 'y'.repeat(5000) });
        const note = m.state.out[0];
        // eslint-disable-next-line no-control-regex
        for (const f of [note.title, note.body, note.ref]) assert.ok(!/[\u0000-\u001f\u007f]/.test(f), JSON.stringify(f));
        assert.ok(note.title.length <= 120 && note.body.length < 400, `title ${note.title.length} body ${note.body.length}`);
        const big = machine();
        big.tr.observe('z'.repeat(500), 'online'); big.at(1);
        big.tr.observe('z'.repeat(500), 'offline');
        assert.ok(big.state.out[0].ref.length <= 128);
    });
});

// ---------------------------------------------------------------------------------------------
// accessory tracker
// ---------------------------------------------------------------------------------------------
function accessory() {
    const out = [];
    const tr = createAccessoryNoticeTracker({ emit: (x) => out.push(x), logger: { warn() {}, log() {} } });
    const rec = { id: 'ups1', name: 'UPS', nickname: null };
    const go = (...seq) => seq.slice(1).forEach((to, i) => tr.transition(rec, seq[i], to));
    return { out, tr, go, types: () => out.map((x) => x.type) };
}

describe('accessory tracker: transition sequences', () => {
    test('ac -> on_battery -> unknown -> on_battery announces on-battery ONCE', () => {
        const a = accessory();
        a.go('ac', 'on_battery', 'unknown', 'on_battery');
        assert.deepEqual(a.types(), ['accessory-on-battery']);
    });

    test('on_battery -> unknown -> ac announces exactly one restored; a second ac->unknown->ac adds nothing', () => {
        const a = accessory();
        a.go('ac', 'on_battery', 'unknown', 'ac', 'unknown', 'ac');
        assert.deepEqual(a.types(), ['accessory-on-battery', 'accessory-restored']);
    });

    test('ac -> unknown -> ac and unknown -> ac announce nothing', () => {
        const a = accessory();
        a.go('ac', 'unknown', 'ac');
        a.tr.transition({ id: 'ups1' }, 'unknown', 'ac');
        assert.deepEqual(a.types(), []);
    });

    test('full cycle on_battery -> ac -> on_battery announces the second outage again', () => {
        const a = accessory();
        a.go('ac', 'on_battery', 'ac', 'on_battery');
        assert.deepEqual(a.types(), ['accessory-on-battery', 'accessory-restored', 'accessory-on-battery']);
    });

    test('restart while on_battery: the restore after restart is still announced (from === on_battery)', () => {
        const a = accessory();                       // fresh tracker == restarted process
        a.tr.transition({ id: 'ups1', name: 'UPS' }, 'on_battery', 'ac');
        assert.deepEqual(a.types(), ['accessory-restored']);
    });

    test('restart while on_battery, then on_battery -> unknown -> ac: the restore is still announced', () => {
        const a = accessory();                       // fresh tracker never saw the on-battery edge
        a.go('on_battery', 'unknown', 'ac');
        assert.deepEqual(a.types(), ['accessory-restored']);
    });

    test('accessories are independent; hostile name is scrubbed; bad records are ignored', () => {
        const a = accessory();
        a.tr.transition({ id: 'u1', name: 'A' }, 'ac', 'on_battery');
        a.tr.transition({ id: 'u2', name: 'B\nINJECT' }, 'ac', 'on_battery');
        assert.equal(a.out.length, 2);
        assert.ok(!/\n/.test(a.out[1].title));
        assert.equal(a.tr.transition(null, 'ac', 'on_battery'), null);
        assert.equal(a.tr.transition({ id: 7 }, 'ac', 'on_battery'), null);
    });
});

// ---------------------------------------------------------------------------------------------
// emitFleetNotice
// ---------------------------------------------------------------------------------------------
function hub(overrides = {}) {
    const id = ++n;
    const logs = [];
    const logger = { log: (m) => logs.push(String(m)), warn: (m) => logs.push(String(m)) };
    const provider = createTestProvider();
    const registry = createProviderRegistry();
    registry.register('test', provider);
    const store = createNotifyStore({ file: path.join(dir, `s-${id}.json`), key: KEY, registry });
    const receipts = createReceiptLog({ file: path.join(dir, `r-${id}.jsonl`) });
    const dispatcher = createNotifyDispatcher({ store, registry, receipts });
    store.createConnection({ id: 'conn-a', provider: 'test', label: 'a', secrets: { token: 'tok' } });
    const deps = Object.assign({ dispatcher, store, receipts, logger }, overrides);
    return { fn: fleetNotices.createFleetNotices(deps), store, provider, receipts, logs, dispatcher, registry, file: path.join(dir, `s-${id}.json`) };
}

describe('emitFleetNotice: never throws', () => {
    test('dispatcher that throws synchronously, rejects, or returns garbage resolves to a failure envelope', async () => {
        const unhandled = [];
        const onRej = (e) => unhandled.push(e);
        process.on('unhandledRejection', onRej);
        try {
            const cases = [
                { dispatchFleet() { throw new TypeError('sync'); } },
                { dispatchFleet() { return Promise.reject(new RangeError('async')); } },
                { dispatchFleet() { return undefined; } },
            ];
            for (const d of cases) {
                const c = hub({ dispatcher: d });
                const out = await c.fn.emitFleetNotice({ type: 'machine-offline', title: 't', body: 'b', ref: 'r' });
                assert.equal(typeof out, 'object');
                assert.equal(out.routed === true, false);
            }
            const c2 = hub({ store: { catalogTypeIds() { throw new Error('store dead'); } } });
            const out2 = await c2.fn.emitFleetNotice({ type: 'machine-offline' });
            assert.equal(out2.reason, 'unknown-type');
            for (const bad of [undefined, null, 5, 'x', [], { type: {} }, { type: '../../etc' }, { type: 'A'.repeat(100) }]) {
                const o = await c2.fn.emitFleetNotice(bad);
                assert.equal(o.ok, false);
            }
            // a logger that throws must not break the emitter either
            const c3 = hub({ logger: { log() { throw new Error('log'); }, warn() { throw new Error('warn'); } } });
            const o3 = await c3.fn.emitFleetNotice({ type: 'machine-offline' });
            assert.equal(typeof o3, 'object');
            await new Promise((r) => setImmediate(r));
        } finally { process.off('unhandledRejection', onRej); }
        assert.deepEqual(unhandled, []);
    });

    test('process-wide emitFleetNotice before configure() resolves not-configured, and logs title/body', async () => {
        fleetNotices._reset();
        const seen = [];
        const orig = console.warn;
        console.warn = (m) => seen.push(String(m));
        let out;
        try { out = await fleetNotices.emitFleetNotice({ type: 'ci-no-capacity', title: 'No capacity', body: 'queue stuck' }); } finally { console.warn = orig; }
        assert.equal(out.reason, 'not-configured');
        assert.ok(seen.some((l) => /No capacity/.test(l) && /queue stuck/.test(l)), seen.join('|'));
    });
});

describe('emitFleetNotice: untrusted strings', () => {
    test('control chars are scrubbed and title/body/ref bounded before reaching the provider', async () => {
        const c = hub();
        c.store.setFleetRoutes({ routes: { 'machine-offline': ['conn-a'] } });
        const out = await c.fn.emitFleetNotice({
            type: 'machine-offline', severity: 'critical',
            title: 'T\nline2\u0000\u001b[1m' + 'a'.repeat(5000), body: 'B\r\n' + 'b'.repeat(50000), ref: 'ref with space/../\n' + 'r'.repeat(500),
        });
        assert.equal(out.delivered, 1, JSON.stringify(out));
        const msg = c.provider.calls[0].message;
        // eslint-disable-next-line no-control-regex
        assert.ok(!/[\u0000-\u001f\u007f]/.test(msg.title) && !/[\u0000-\u001f\u007f]/.test(msg.body));
        assert.ok(msg.title.length <= 200, String(msg.title.length));
        assert.ok(msg.body.length <= 1000, String(msg.body.length));
        const rec = c.receipts.recent({ team: 'fleet' });
        assert.ok(rec[0].ref.length <= 128 && /^[A-Za-z0-9._:/#-]+$/.test(rec[0].ref), rec[0].ref);
    });

    test('an invalid severity falls back to the catalog default instead of being trusted', async () => {
        const c = hub();
        c.store.setFleetRoutes({ routes: { 'machine-offline': ['conn-a'] } });
        const out = await c.fn.emitFleetNotice({ type: 'machine-offline', severity: '__proto__', title: 't', body: 'b' });
        assert.equal(out.severity, 'critical');
    });
});

// ---------------------------------------------------------------------------------------------
// REGRESSION: ci-dispatch-alerts stays observable once the real emitter is resolvable
// ---------------------------------------------------------------------------------------------
describe('ci-dispatch-alerts keeps operator visibility through the fleet emitter', () => {
    test('a ci-* alert (not in the catalog) leaves type + severity in a receipt AND title + body in the log', async () => {
        const c = hub();
        const sink = (m) => c.logs.push(String(m));
        fleetNotices.configure({ dispatcher: c.dispatcher, store: c.store, receipts: c.receipts, logger: { log: sink, warn: sink } });
        const alerts = createAlerts({ logger: { warn: sink, log: sink } });
        const r = alerts.raise('ci-no-capacity', { severity: 'high', title: 'No pool capacity for class:long', body: 'queue age 900s, 0 eligible runners', ref: 'class:long' });
        assert.equal(r.via, 'fleet-notice');
        await new Promise((res) => setImmediate(res));
        await new Promise((res) => setImmediate(res));
        const rec = c.receipts.recent({ team: 'fleet' });
        assert.equal(rec.length, 1);
        assert.deepEqual([rec[0].type, rec[0].severity, rec[0].ref, rec[0].ok], ['ci-no-capacity', 'high', 'class:long', false]);
        const all = c.logs.join('\n');
        assert.match(all, /ci-no-capacity/);
        assert.match(all, /No pool capacity for class:long/, 'title must still reach an operator-visible log');
        assert.match(all, /queue age 900s, 0 eligible runners/, 'body must still reach an operator-visible log');
        assert.equal(alerts.list()[0].body, 'queue age 900s, 0 eligible runners', 'ring (GET /api/ci-pool) intact');
        fleetNotices._reset();
    });

    test('a known type with no fleet route is log-only but the log still carries title and body', async () => {
        const c = hub();
        const out = await c.fn.emitFleetNotice({ type: 'machine-offline', severity: 'critical', title: 'Machine offline: m9', body: 'stopped reporting', ref: 'm9' });
        assert.equal(out.routed, false);
        const all = c.logs.join('\n');
        assert.match(all, /Machine offline: m9/);
        assert.match(all, /stopped reporting/);
    });
});

// ---------------------------------------------------------------------------------------------
// route-set API
// ---------------------------------------------------------------------------------------------
function api() {
    const c = hub();
    const app = express();
    app.use(express.json());
    registerNotifyRoutes(app, { store: c.store, registry: c.registry, receipts: c.receipts, dispatcher: c.dispatcher, isRegisteredTeam: () => true });
    c.store.createConnection({ id: 'conn-b', provider: 'test', label: 'b', secrets: { token: 'tok' } });
    return Object.assign(c, { app });
}
const adm = (r) => r.set('x-api-key', ADMIN);
const rawPut = (app, text) => adm(request(app).put('/api/notify/fleet-routes')).set('content-type', 'application/json').send(text);

describe('fleet-routes API: hostile bodies', () => {
    test('__proto__ / constructor keys, arrays, non-strings and duplicates are rejected and pollute nothing', async () => {
        const c = api();
        const bodies = [
            '{"routes":{"__proto__":["conn-a"]}}',
            '{"__proto__":{"polluted":true},"routes":{}}',
            '{"routes":{"constructor":["conn-a"]}}',
            '{"routes":{"machine-offline":[{"__proto__":{"polluted":true}}]}}',
            '{"routes":{"machine-offline":[1,2]}}',
            '{"routes":{"machine-offline":["conn-a","conn-a"]}}',
            '{"routes":["machine-offline"]}',
            '[]', '"str"', 'null', '7',
        ];
        for (const b of bodies) {
            const r = await rawPut(c.app, b);
            assert.ok([400, 413].includes(r.status), `${b} -> ${r.status}`);
        }
        assert.equal(({}).polluted, undefined);
        assert.equal(Object.prototype.polluted, undefined);
        assert.equal(c.store.getFleetRoutes(), null, 'no rejected PUT may mutate state');
    });

    test('an oversized payload is refused without storing anything', async () => {
        const c = api();
        const big = JSON.stringify({ routes: { 'machine-offline': Array.from({ length: 20000 }, (_, i) => 'conn-' + i) } });
        const r = await rawPut(c.app, big);
        assert.ok(r.status >= 400, String(r.status)); // body-parser limit (currently surfaces as 500 via the scoped handler)
        assert.equal(c.store.getFleetRoutes(), null);
    });

    test('an empty set is accepted, clears prior routes, and the next notice is unrouted (not an error)', async () => {
        const c = api();
        let r = await rawPut(c.app, '{"routes":{"machine-offline":["conn-a"]}}');
        assert.equal(r.status, 200);
        r = await rawPut(c.app, '{"routes":{}}');
        assert.equal(r.status, 200);
        const out = await c.fn.emitFleetNotice({ type: 'machine-offline', title: 't', body: 'b' });
        assert.equal(out.routed, false);
        assert.equal(c.provider.calls.length, 0);
    });

    test('routes survive a store reload; a connection deleted later yields a failed receipt for that id only', async () => {
        const c = api();
        const r = await rawPut(c.app, '{"routes":{"machine-offline":["conn-a","conn-b"]}}');
        assert.equal(r.status, 200);
        const reloaded = createNotifyStore({ file: c.file, key: KEY, registry: c.registry });
        assert.deepEqual(reloaded.getFleetRoutes().routes, { 'machine-offline': ['conn-a', 'conn-b'] });
        c.store.deleteConnection('conn-b');
        const out = await c.fn.emitFleetNotice({ type: 'machine-offline', title: 't', body: 'b' });
        assert.equal(out.delivered, 1);
        assert.equal(out.failed, 1);
    });

    test('key-less requests and team keys are refused on both verbs (fleet routes are admin-only)', async () => {
        const c = api();
        const teamKey = c.store.mintTeamKey('academy');
        for (const key of [null, teamKey, 'nope']) {
            for (const m of ['get', 'put']) {
                let r = request(c.app)[m]('/api/notify/fleet-routes');
                if (key) r = r.set('x-api-key', key);
                const res = await r.send({ routes: {} });
                assert.ok([401, 403].includes(res.status), `${m} ${key && key.slice(0, 4)} -> ${res.status}`);
            }
        }
        assert.equal(c.store.getFleetRoutes(), null);
    });
});
