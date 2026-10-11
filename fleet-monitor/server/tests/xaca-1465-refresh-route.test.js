//
//  xaca-1465-refresh-route.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1465-012 -- GET /api/ci-runners?refresh=1: bounded, throttled, coalesced re-read of the
 * routing switches. NO network: a recording fetch stub; the clock is injected.
 */

const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { test, describe, after } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const express = require('express');

const { createGithubClient } = require('../lib/ci-dispatch-github');
const { createFallbackReader } = require('../lib/ci-fallback-reader');
const { createPoolStore } = require('../lib/ci-pool-store');
const { registerCiRunnersRoutes } = require('../lib/ci-runners-routes');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca1465-012-refresh-'));
after(() => fs.rmSync(TMP, { recursive: true, force: true }));

const { privateKey } = crypto.generateKeyPairSync('rsa', {
    modulusLength: 2048,
    publicKeyEncoding: { type: 'spki', format: 'pem' },
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
});
const quiet = { log() {}, warn() {}, error() {} };

function res(status, body) {
    return { status, headers: { get: () => null }, json: async () => body };
}

let seq = 0;
function build({ withReader = true, readerOverride = null, refreshTimeoutMs } = {}) {
    const dir = path.join(TMP, `d${++seq}`);
    fs.mkdirSync(dir, { recursive: true });
    let clock = Date.UTC(2026, 9, 6, 12, 0, 0);
    const varCalls = [];
    let gate = null;                       // when set, variable GETs wait on it
    const fetchStub = async (url, init) => {
        const u = new URL(url);
        if (/\/installation$/.test(u.pathname)) return res(200, { id: 1 });
        if (/\/access_tokens$/.test(u.pathname)) return res(201, { token: 'ghs_x', expires_at: new Date(clock + 3600e3).toISOString() });
        if (/\/actions\/variables\//.test(u.pathname)) {
            varCalls.push(u.pathname);
            if (gate) await gate;
            return res(200, { name: 'X', value: '["self-hosted"]' });
        }
        throw new Error(`unrouted ${init.method} ${u.pathname}`);
    };
    const github = createGithubClient({
        config: { GITHUB_APP_ID: '1', GITHUB_APP_PRIVATE_KEY: privateKey }, fetch: fetchStub, now: () => clock,
    });
    const store = createPoolStore({ file: path.join(dir, 'ci-pool.json'), logger: quiet });
    store.load();
    let reader = null;
    if (readerOverride) reader = readerOverride;
    else if (withReader) reader = createFallbackReader({ github, store, now: () => clock, logger: quiet, minRefreshIntervalMs: 30000 });
    const app = express();
    app.use(express.json());
    registerCiRunnersRoutes(app, {
        file: path.join(dir, 'ci-runners.json'), poolStore: store, fallbackReader: reader, refreshTimeoutMs,
    });
    return {
        app, reader, varCalls,
        advance: (ms) => { clock += ms; },
        hold: () => { let open; gate = new Promise((r) => { open = r; }); return () => { gate = null; open(); }; },
    };
}

const GET = (app, q = '') => request(app).get(`/api/ci-runners${q}`);

describe('XACA-1465-012 ?refresh=1', () => {
    test('first refresh runs a read (3 default switches); the body carries fallback + refresh', async () => {
        const h = build();
        const r = await GET(h.app, '?refresh=1');
        assert.equal(r.status, 200);
        assert.deepEqual(r.body.refresh, { ran: true });
        assert.equal(h.varCalls.length, 3);
        assert.equal(r.body.fallback.switches.length, 3);
        assert.ok(r.body.fallback.switches.every((s) => s.armed === true));
        assert.equal(r.body.schemaVersion, 1);
        assert.match(r.headers['cache-control'], /no-store/);
    });

    test('second refresh inside the minimum interval is throttled: ZERO extra GitHub requests', async () => {
        const h = build();
        await GET(h.app, '?refresh=1');
        const n = h.varCalls.length;
        h.advance(5000);
        const r = await GET(h.app, '?refresh=1');
        assert.equal(r.body.refresh.ran, false);
        assert.equal(r.body.refresh.throttled, true);
        assert.ok(r.body.refresh.retryAfterSec >= 1 && r.body.refresh.retryAfterSec <= 30);
        assert.equal(h.varCalls.length, n);
        h.advance(30000);
        assert.deepEqual((await GET(h.app, '?refresh=1')).body.refresh, { ran: true });
        assert.equal(h.varCalls.length, n * 2);
    });

    test('a concurrent pair of refreshes performs ONE read', async () => {
        const h = build();
        const release = h.hold();
        const a = GET(h.app, '?refresh=1').then((r) => r);
        const b = GET(h.app, '?refresh=1').then((r) => r);
        await new Promise((x) => setTimeout(x, 60));
        release();
        const [ra, rb] = await Promise.all([a, b]);
        assert.equal(h.varCalls.length, 3, 'one read of 3 switches, not 6');
        const flags = [ra.body.refresh, rb.body.refresh];
        assert.ok(flags.every((f) => f.ran === true));
        assert.ok(flags.some((f) => f.coalesced === true));
    });

    test('plain GET: no refresh field, no read, even after a prior refresh', async () => {
        const h = build();
        const r0 = await GET(h.app);
        assert.equal('refresh' in r0.body, false);
        assert.equal(h.varCalls.length, 0);
        await GET(h.app, '?refresh=1');
        const n = h.varCalls.length;
        h.advance(60000);
        const r = await GET(h.app);
        assert.equal('refresh' in r.body, false);
        assert.equal(h.varCalls.length, n);
        assert.doesNotMatch(r.headers['cache-control'] || '', /no-store/);
    });

    test('only refresh=1 counts: 0, true, empty and repeated forms do not trigger a read', async () => {
        const h = build();
        for (const q of ['?refresh=0', '?refresh=true', '?refresh=', '?refresh=1&refresh=1', '?refresh[a]=1']) {
            const r = await GET(h.app, q);
            assert.equal(r.status, 200, q);
            assert.equal('refresh' in r.body, false, q);
        }
        assert.equal(h.varCalls.length, 0);
    });

    test('no reader (no App credentials): refresh answers disabled, fallback stays null', async () => {
        const h = build({ withReader: false });
        const r = await GET(h.app, '?refresh=1');
        assert.equal(r.status, 200);
        assert.deepEqual(r.body.refresh, { ran: false, disabled: true });
        assert.equal(r.body.fallback, null);
        assert.equal(h.varCalls.length, 0);
    });

    test('a slow reader is cut off at the bound: current snapshot + timedOut', async () => {
        const never = { refreshNow: () => new Promise(() => {}), snapshot: () => ({ linux: null, macos: null, checkedAt: null, switches: [] }) };
        const h = build({ readerOverride: never, refreshTimeoutMs: 80 });
        const t0 = Date.now();
        const r = await GET(h.app, '?refresh=1');
        assert.ok(Date.now() - t0 < 2000);
        assert.equal(r.status, 200);
        assert.deepEqual(r.body.refresh, { ran: false, timedOut: true });
        assert.deepEqual(r.body.fallback.switches, []);
    });

    test('a reader that throws never leaks detail', async () => {
        const boom = { refreshNow: async () => { throw new Error('SECRET-DETAIL ghs_leak'); }, snapshot: () => null };
        const h = build({ readerOverride: boom });
        const r = await GET(h.app, '?refresh=1');
        assert.equal(r.status, 200);
        assert.deepEqual(r.body.refresh, { ran: false });
        assert.doesNotMatch(JSON.stringify(r.body), /SECRET-DETAIL|ghs_leak/);
    });
});
