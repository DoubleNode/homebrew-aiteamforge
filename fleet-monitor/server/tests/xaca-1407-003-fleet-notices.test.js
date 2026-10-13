//
//  xaca-1407-003-fleet-notices.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1407-003 -- emitFleetNotice, the accessory tracker, and the three call sites.
 * Store/receipt files in mkdtemp sandboxes; the only provider is the in-memory test provider;
 * server.js is never required (it binds a port), only checked structurally.
 */

const { test, describe, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const express = require('express');

const SAVED = { a: process.env.FLEET_ADMIN_TOKEN, f: process.env.FLEET_AUTH_TOKEN, k: process.env.NOTIFY_STORE_KEY };
delete process.env.NOTIFY_STORE_KEY;

const { createNotifyStore } = require('../lib/notify-store');
const { createNotifyDispatcher } = require('../lib/notify-dispatcher');
const { createReceiptLog } = require('../lib/notify-receipts');
const { createProviderRegistry, createTestProvider } = require('../lib/notify-providers');
const { wireNotifyHub } = require('../lib/notify-routes');
const fleetNotices = require('../lib/fleet-notices');
const { createAccessoryNoticeTracker } = require('../lib/fleet-notice-sources');
const { createAlerts } = require('../lib/ci-dispatch-alerts');

const KEY = crypto.randomBytes(32).toString('hex');
let dir, n = 0;
before(() => { dir = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca-1407-003-')); });
after(() => {
    fs.rmSync(dir, { recursive: true, force: true });
    fleetNotices._reset();
    for (const [k, v] of [['FLEET_ADMIN_TOKEN', SAVED.a], ['FLEET_AUTH_TOKEN', SAVED.f], ['NOTIFY_STORE_KEY', SAVED.k]]) {
        if (v === undefined) delete process.env[k]; else process.env[k] = v;
    }
});

function build() {
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
    const fn = fleetNotices.createFleetNotices({ dispatcher, store, receipts, logger });
    return { fn, store, provider, receipts, logs, dispatcher };
}

describe('emitFleetNotice contract', () => {
    test('single-object signature: routed notice reaches the connection, receipts are team "fleet"', async () => {
        const c = build();
        c.store.setFleetRoutes({ routes: { 'machine-offline': ['conn-a'] } });
        const out = await c.fn.emitFleetNotice({ type: 'machine-offline', severity: 'critical', title: 'Machine offline: m1', body: 'gone', ref: 'm-1' });
        assert.equal(out.ok, true);
        assert.equal(out.delivered, 1);
        assert.equal(c.provider.calls.length, 1);
        assert.equal(c.provider.calls[0].message.title, 'Machine offline: m1');
        assert.equal(c.provider.calls[0].message.team, 'fleet');
        assert.equal(c.receipts.recent({ team: 'fleet' }).length, 1);
        assert.ok(c.logs.some((l) => /\[FLEET-NOTICE\] machine-offline \(m-1\): delivered=1/.test(l)));
    });

    test('no route: logged, no send, no receipt, no throw', async () => {
        const c = build();
        const out = await c.fn.emitFleetNotice({ type: 'machine-offline', title: 't', body: 'b' });
        assert.equal(out.routed, false);
        assert.equal(c.provider.calls.length, 0);
        assert.equal(c.receipts.recent({}).length, 0);
        assert.ok(c.logs.some((l) => /no fleet route/.test(l)));
    });

    test('unknown (non-catalog) type is NOT silently dropped: warn log + ok:false receipt, nothing sent', async () => {
        const c = build();
        c.store.setFleetRoutes({ routes: { 'machine-offline': ['conn-a'] } });
        const out = await c.fn.emitFleetNotice({ type: 'ci-no-capacity', severity: 'high', title: 't', body: 'b', ref: 'class:long' });
        assert.deepEqual([out.ok, out.routed, out.reason], [false, false, 'unknown-type']);
        assert.equal(c.provider.calls.length, 0);
        const rec = c.receipts.recent({ team: 'fleet' });
        assert.equal(rec.length, 1);
        assert.deepEqual([rec[0].type, rec[0].ok, rec[0].error, rec[0].severity, rec[0].ref], ['ci-no-capacity', false, 'unknown notice type', 'high', 'class:long']);
        assert.ok(c.logs.some((l) => /ci-no-capacity.*unknown notice type/.test(l)));
    });

    test('invalid input never throws and is never sent', async () => {
        const c = build();
        for (const bad of [undefined, null, 42, 'x', {}, { type: 'Bad Type' }, { type: 5 }]) {
            const out = await c.fn.emitFleetNotice(bad);
            assert.equal(out.routed, false);
        }
        assert.equal(c.provider.calls.length, 0);
    });

    test('a dispatcher that throws (or rejects) is contained; it resolves, never rejects', async () => {
        const c = build();
        const boom = fleetNotices.createFleetNotices({
            dispatcher: { dispatchFleet: () => { throw Object.assign(new Error('secret-ish text'), { code: 'receipt_write_failed' }); } },
            store: c.store, logger: { log: (m) => c.logs.push(m), warn: (m) => c.logs.push(m) },
        });
        const out = await boom.emitFleetNotice({ type: 'machine-offline', title: 't', body: 'b' });
        assert.equal(out.reason, 'emit-failed');
        assert.ok(c.logs.some((l) => /emit failed \(Error\/receipt_write_failed\)/.test(l)));
        assert.ok(!c.logs.some((l) => /secret-ish/.test(l)), 'error message text must not be logged');
        const rej = fleetNotices.createFleetNotices({ dispatcher: { dispatchFleet: () => Promise.reject(new Error('x')) }, store: c.store, logger: { log() {}, warn() {} } });
        assert.equal((await rej.emitFleetNotice({ type: 'machine-offline', title: 't', body: 'b' })).reason, 'emit-failed');
    });

    test('sanitises text and ref; severity falls back to the catalog default when invalid', async () => {
        const c = build();
        c.store.setFleetRoutes({ routes: { 'machine-recovered': ['conn-a'] } });
        const out = await c.fn.emitFleetNotice({ type: 'machine-recovered', severity: 'bogus', title: 'a\nb\u0000c', body: 'z'.repeat(5000), ref: 'we ird/ref!' });
        assert.equal(out.severity, 'info');
        const msg = c.provider.calls[0].message;
        assert.equal(msg.title, 'a b c');
        assert.equal(msg.body.length, 1000);
        assert.equal(msg.ref, 'we-ird/ref-');
    });

    test('not configured -> resolves {reason:"not-configured"} and does not throw', async () => {
        fleetNotices._reset();
        const orig = console.warn; console.warn = () => {};
        try {
            const out = await fleetNotices.emitFleetNotice({ type: 'machine-offline', title: 't', body: 'b' });
            assert.equal(out.reason, 'not-configured');
        } finally { console.warn = orig; }
    });
});

describe('ci-dispatch-alerts resolves this module by the require path', () => {
    test('createAlerts default lookup finds emitFleetNotice (no globalThis needed)', async () => {
        const c = build();
        fleetNotices.configure({ dispatcher: c.dispatcher, store: c.store, receipts: c.receipts, logger: { log() {}, warn() {} } });
        assert.equal(typeof globalThis.emitFleetNotice, 'undefined');
        const alerts = createAlerts({ logger: { log() {}, warn() {} } });
        const r = alerts.raise('ci-queue-age', { severity: 'warning', title: 'Queue old', body: 'b', ref: 'class:long' });
        assert.deepEqual(r, { raised: true, via: 'fleet-notice' });
        await new Promise((res) => setImmediate(res));
        const rec = c.receipts.recent({ team: 'fleet' });
        assert.equal(rec.length, 1);
        assert.equal(rec[0].error, 'unknown notice type');
        fleetNotices._reset();
    });
});

describe('wireNotifyHub configures the process-wide emitter end to end', () => {
    test('fleet route set via the store -> module-level emitFleetNotice delivers', async () => {
        const app = express();
        app.use(express.json());
        const logs = [];
        const hub = wireNotifyHub(app, {
            isRegisteredTeam: () => false,
            logger: { log: (m) => logs.push(m), warn: (m) => logs.push(m), error: (m) => logs.push(m) },
            storeOpts: { file: path.join(dir, 'wire-s.json'), key: KEY },
            receiptOpts: { file: path.join(dir, 'wire-r.jsonl') },
        });
        hub.store.createConnection({ id: 'conn-a', provider: 'test', label: 'a', secrets: { token: 'tok' } });
        hub.store.setFleetRoutes({ routes: { 'accessory-on-battery': ['conn-a'] } });
        const out = await fleetNotices.emitFleetNotice({ type: 'accessory-on-battery', severity: 'high', title: 'On battery', body: 'b', ref: 'acc:x' });
        assert.equal(out.ok, true, JSON.stringify(out));
        assert.equal(hub.receipts.recent({ team: 'fleet' })[0].connectionId, 'conn-a');
        fleetNotices._reset();
    });
});

describe('accessory tracker', () => {
    function setup() {
        const sent = [];
        const tr = createAccessoryNoticeTracker({ emit: (x) => { sent.push(x); } });
        return { tr, sent };
    }
    const rec = { id: 'acc-1', name: 'APC', nickname: 'Rack UPS' };

    test('ac -> on_battery emits accessory-on-battery (high); on_battery -> ac emits accessory-restored (info)', () => {
        const { tr, sent } = setup();
        assert.equal(tr.transition(rec, 'ac', 'on_battery'), 'on-battery');
        assert.equal(tr.transition(rec, 'on_battery', 'ac'), 'restored');
        assert.deepEqual(sent.map((s) => [s.type, s.severity, s.ref]), [
            ['accessory-on-battery', 'high', 'acc:acc-1'], ['accessory-restored', 'info', 'acc:acc-1'],
        ]);
        assert.match(sent[0].title, /Rack UPS/);
    });

    test('unknown never notifies: ac -> unknown -> ac is silent', () => {
        const { tr, sent } = setup();
        assert.equal(tr.transition(rec, 'ac', 'unknown'), null);
        assert.equal(tr.transition(rec, 'unknown', 'ac'), null);
        assert.equal(sent.length, 0);
    });

    test('on_battery -> unknown is silent, but the later unknown -> ac still announces the restore', () => {
        const { tr, sent } = setup();
        tr.transition(rec, 'ac', 'on_battery');
        assert.equal(tr.transition(rec, 'on_battery', 'unknown'), null);
        assert.equal(tr.transition(rec, 'unknown', 'ac'), 'restored');
        assert.deepEqual(sent.map((s) => s.type), ['accessory-on-battery', 'accessory-restored']);
    });

    test('an unknown flap while on battery does not re-announce on_battery', () => {
        const { tr, sent } = setup();
        tr.transition(rec, 'ac', 'on_battery');
        tr.transition(rec, 'on_battery', 'unknown');
        assert.equal(tr.transition(rec, 'unknown', 'on_battery'), null);
        assert.equal(sent.length, 1);
    });

    test('unknown -> on_battery on a fresh process announces; a restart-era on_battery -> ac restore announces', () => {
        const a = setup();
        assert.equal(a.tr.transition(rec, 'unknown', 'on_battery'), 'on-battery');
        const b = setup(); // process restarted while on battery: no announced-state, but from === on_battery
        assert.equal(b.tr.transition(rec, 'on_battery', 'ac'), 'restored');
    });

    test('accessories are independent; a second outage after restore announces again', () => {
        const { tr, sent } = setup();
        const other = { id: 'acc-2', name: 'CyberPower' };
        tr.transition(rec, 'ac', 'on_battery');
        assert.equal(tr.transition(other, 'ac', 'on_battery'), 'on-battery');
        tr.transition(rec, 'on_battery', 'ac');
        assert.equal(tr.transition(rec, 'ac', 'on_battery'), 'on-battery');
        assert.equal(sent.length, 4);
        assert.match(sent[1].title, /CyberPower/);
    });

    test('malformed records are ignored without throwing', () => {
        const { tr, sent } = setup();
        for (const bad of [null, undefined, {}, { id: 5 }]) assert.equal(tr.transition(bad, 'ac', 'on_battery'), null);
        assert.equal(sent.length, 0);
    });
});

describe('server.js call sites (structural)', () => {
    const src = fs.readFileSync(path.join(__dirname, '..', 'server.js'), 'utf8');

    test('imports emitFleetNotice from lib/fleet-notices and builds both trackers on it', () => {
        assert.match(src, /const \{ emitFleetNotice \} = require\('\.\/lib\/fleet-notices'\);/);
        assert.match(src, /createMachineNoticeTracker\(\{ emit: emitFleetNotice,/);
        assert.match(src, /createAccessoryNoticeTracker\(\{ emit: emitFleetNotice \}\)/);
    });

    test('the accessory onTransition hook feeds the tracker', () => {
        const hook = src.slice(src.indexOf('function deriveAccessoryStateOrThrow()'));
        assert.match(hook.slice(0, 1200), /accessoryNotices\.transition\(rec, from, to\);/);
    });

    test('nothing is placed on globalThis (the require path is the one resolution route)', () => {
        for (const f of ['server.js', 'lib/fleet-notices.js', 'lib/notify-routes.js']) {
            assert.ok(!/globalThis\.emitFleetNotice\s*=/.test(fs.readFileSync(path.join(__dirname, '..', f), 'utf8')), f);
        }
    });
});
