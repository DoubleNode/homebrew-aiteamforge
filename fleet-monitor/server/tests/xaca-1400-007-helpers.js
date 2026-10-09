//
//  xaca-1400-007-helpers.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Shared harness for the XACA-1400-007 adversarial suites. Not a test file
 * (does not match *.test.js). Everything is sandboxed under os.tmpdir(); keys
 * are generated in-process; the real data/ dir is never touched.
 *
 * NOTE: requiring this module sets FLEET_AUTH_TOKEN / FLEET_ADMIN_TOKEN, so it
 * MUST be required before lib/auth-middleware is loaded. Call restoreEnv() in
 * an after() hook.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const express = require('express');
const request = require('supertest');

const rand = (n = 8) => crypto.randomBytes(n).toString('hex');
const ADMIN = 'admin-' + rand();
const FLEET = 'fleet-' + rand();
const SAVED = { a: process.env.FLEET_ADMIN_TOKEN, f: process.env.FLEET_AUTH_TOKEN, k: process.env.NOTIFY_STORE_KEY };
process.env.FLEET_ADMIN_TOKEN = ADMIN;
process.env.FLEET_AUTH_TOKEN = FLEET;
delete process.env.NOTIFY_STORE_KEY;

const { createNotifyStore } = require('../lib/notify-store');
const { registerNotifyRoutes } = require('../lib/notify-routes');
const { createNotifyDispatcher } = require('../lib/notify-dispatcher');
const { createReceiptLog } = require('../lib/notify-receipts');
const { createProviderRegistry, createTestProvider, NotifyConfigError, NotifySendError } = require('../lib/notify-providers');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca1400-007-'));
const KEY = crypto.randomBytes(32).toString('hex');
let seq = 0;

function cleanup() {
    try { fs.chmodSync(TMP, 0o700); } catch (_) { /* ignore */ }
    fs.rmSync(TMP, { recursive: true, force: true });
}

function restoreEnv() {
    for (const [k, v] of [['FLEET_ADMIN_TOKEN', SAVED.a], ['FLEET_AUTH_TOKEN', SAVED.f], ['NOTIFY_STORE_KEY', SAVED.k]]) {
        if (v === undefined) delete process.env[k]; else process.env[k] = v;
    }
}

function makeClock(iso = '2026-06-15T12:00:00.000Z') {
    const c = { t: Date.parse(iso), date() { return new Date(c.t); }, advance(ms) { c.t += ms; }, set(i) { c.t = Date.parse(i); } };
    return c;
}

/** A configurable in-memory provider. `rawSend` replaces send entirely (to test sync throws). */
function makeProvider(name, { send, validate, rawSend } = {}) {
    const calls = [];
    const p = {
        name, paramFields: ['url'], secretFields: ['token'], calls,
        validate(c) {
            if (validate) return validate(c);
            const t = c.secrets && c.secrets.token;
            if (typeof t !== 'string' || !t) throw new NotifyConfigError('token required');
            return undefined;
        },
        async send(c, m) {
            calls.push({ id: c.id, message: { ...m } });
            if (send) return send(c, m, calls.length);
            return { providerMessageId: `${name}-${calls.length}` };
        },
    };
    if (rawSend) p.send = rawSend;
    return p;
}

function captureConsole() {
    const lines = [];
    const orig = {};
    for (const m of ['log', 'info', 'warn', 'error', 'debug']) {
        orig[m] = console[m];
        console[m] = (...a) => lines.push(a.map((x) => (typeof x === 'string' ? x : (x && x.stack) || JSON.stringify(x))).join(' '));
    }
    return { lines, restore() { for (const m of Object.keys(orig)) console[m] = orig[m]; } };
}

/**
 * Build a full hub on a bare express app. Options:
 *   key, providers[], teams[], clock, isRegisteredTeam, storeOpts, receiptOpts, dispatcherOpts, dir
 */
function makeHarness(o = {}) {
    const id = ++seq;
    const dir = o.dir || path.join(TMP, `h${id}`);
    fs.mkdirSync(dir, { recursive: true });
    const registry = createProviderRegistry();
    for (const p of (o.providers || [createTestProvider()])) registry.register(p.name, p);
    const clock = o.clock || makeClock();
    const clk = () => clock.date();
    const storeFile = path.join(dir, 'store.json');
    const receiptFile = path.join(dir, 'receipts.jsonl');
    const key = Object.prototype.hasOwnProperty.call(o, 'key') ? o.key : KEY;
    const store = createNotifyStore({ file: storeFile, key, registry, clock: clk, ...(o.storeOpts || {}) });
    const receipts = createReceiptLog({ file: receiptFile, clock: clk, ...(o.receiptOpts || {}) });
    const dispatcher = createNotifyDispatcher({ store, registry, receipts, clock: clk, ...(o.dispatcherOpts || {}) });
    const teams = new Set(o.teams || ['team-a', 'team-b', 'academy']);
    const isRegisteredTeam = Object.prototype.hasOwnProperty.call(o, 'isRegisteredTeam') ? o.isRegisteredTeam : (t) => teams.has(t);
    const app = express();
    app.set('env', 'development'); // what Fly gets: NODE_ENV is not set by the Dockerfile/fly.toml
    app.use(express.json({ limit: '10mb' }));
    registerNotifyRoutes(app, { store, registry, isRegisteredTeam, dispatcher, receipts });
    return { id, dir, app, registry, store, receipts, dispatcher, clock, teams, storeFile, receiptFile };
}

const adm = (r) => r.set('x-api-key', ADMIN);
const flt = (r) => r.set('x-api-key', FLEET);

const cfg = (routes, extra) => ({ $schema: 'release-notify/v2', version: 2, routes, ...(extra || {}) });
const pushRoutes = (h, team, routes, extra, catalog) => {
    const body = { config: cfg(routes, extra) };
    if (catalog !== undefined) body.catalog = catalog;
    return flt(request(h.app).put(`/api/notify/routes/${team}`)).send(body);
};
const notice = (over) => ({ team: 'team-a', type: 'pr-merged', title: 'T-title', body: 'B-body', ref: 'PR-1', ...(over || {}) });
const post = (h, n) => flt(request(h.app).post('/api/notify')).send(n || notice());
const mkConn = (h, id, provider = 'test', token) => h.store.createConnection({
    id, provider, label: id, secrets: { token: token || `tok-${id}-${rand(4)}` },
});
const readLines = (file) => {
    try { return fs.readFileSync(file, 'utf8').split('\n').filter((l) => l.trim()); } catch (_) { return []; }
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Assert none of `needles` appears in any of `hay` ([label, text] pairs). */
function assertNoLeak(assert, hay, needles) {
    for (const [label, text] of hay) {
        for (const n of needles) {
            assert.ok(!String(text).includes(n), `LEAK: '${String(n).slice(0, 24)}' found in ${label}`);
        }
    }
}

module.exports = {
    ADMIN, FLEET, KEY, TMP, rand, cleanup, restoreEnv, makeClock, makeProvider, captureConsole, makeHarness,
    adm, flt, cfg, pushRoutes, notice, post, mkConn, readLines, sleep, assertNoLeak,
    request, express, fs, path, os, crypto,
    NotifyConfigError, NotifySendError, createTestProvider, createNotifyStore, createReceiptLog,
    createNotifyDispatcher, createProviderRegistry, registerNotifyRoutes,
};
