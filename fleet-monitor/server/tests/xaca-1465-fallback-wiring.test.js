//
//  xaca-1465-fallback-wiring.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1465-004 -- wireCiPool creates the fallback reader only when App credentials exist
 * (independent of FLEET_CI_DISPATCHER) and GET /api/ci-runners serves its snapshot. NO network:
 * every outbound call goes through a recording stub. server.js is never require()d.
 */

const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { test, describe, after } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const express = require('express');

const SAVED = { a: process.env.FLEET_AUTH_TOKEN, b: process.env.FLEET_ADMIN_TOKEN, c: process.env.FLEET_CI_DISPATCHER };
const ADMIN = 'xaca1465-wiring-admin-token-cccc';
delete process.env.FLEET_AUTH_TOKEN;
process.env.FLEET_ADMIN_TOKEN = ADMIN;
delete process.env.FLEET_CI_DISPATCHER;

const { wireCiPool } = require('../lib/ci-dispatcher');
const { registerCiRunnersRoutes } = require('../lib/ci-runners-routes');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca1465-004-wire-'));
const toStop = [];
after(() => {
    for (const p of toStop) { try { p.stop(); } catch (_) { /* best effort */ } }
    fs.rmSync(TMP, { recursive: true, force: true });
    for (const [k, v] of [['FLEET_AUTH_TOKEN', SAVED.a], ['FLEET_ADMIN_TOKEN', SAVED.b], ['FLEET_CI_DISPATCHER', SAVED.c]]) {
        if (v === undefined) delete process.env[k]; else process.env[k] = v;
    }
});

const { privateKey } = crypto.generateKeyPairSync('rsa', {
    modulusLength: 2048,
    publicKeyEncoding: { type: 'spki', format: 'pem' },
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
});
const CREDS = { GITHUB_APP_ID: '424242', GITHUB_APP_PRIVATE_KEY: privateKey };
const T0 = Date.UTC(2026, 9, 6, 12, 0, 0);
const quiet = { log() {}, warn() {}, error() {} };

function res(status, body, headers = {}) {
    const h = new Map(Object.entries(headers).map(([k, v]) => [k.toLowerCase(), String(v)]));
    return { status, headers: { get: (n) => (h.has(n.toLowerCase()) ? h.get(n.toLowerCase()) : null) }, json: async () => body };
}

let seq = 0;
function mount(envVars, { values = {} } = {}) {
    const dir = path.join(TMP, `d${++seq}`);
    const calls = [];
    const fetchStub = async (url, init) => {
        const u = new URL(url);
        calls.push({ method: init.method, path: u.pathname });
        if (/\/installation$/.test(u.pathname)) return res(200, { id: 777 });
        if (/\/access_tokens$/.test(u.pathname)) return res(201, { token: 'ghs_x', expires_at: new Date(T0 + 3600e3).toISOString() });
        const m = /\/actions\/variables\/([A-Z_]+)$/.exec(u.pathname);
        if (m) return values[m[1]] === undefined ? res(404, {}) : res(200, { name: m[1], value: values[m[1]] }, { etag: `"e-${m[1]}"` });
        throw new Error(`unrouted ${init.method} ${u.pathname}`);
    };
    const app = express();
    app.use(express.json());
    const pool = wireCiPool(app, { dataDir: dir, env: envVars, logger: quiet, fetch: fetchStub, now: () => T0 });
    toStop.push(pool);
    registerCiRunnersRoutes(app, {
        file: path.join(dir, 'ci-runners.json'), poolStore: pool.store, fallbackReader: pool.fallbackReader,
    });
    const varCalls = () => calls.filter((c) => /\/actions\/variables\//.test(c.path));
    return { app, pool, calls, varCalls };
}

async function until(fn, ms = 3000) {
    const end = Date.now() + ms;
    while (Date.now() < end) { if (fn()) return true; await new Promise((r) => setTimeout(r, 10)); }
    return fn();
}

describe('XACA-1465-004 no App credentials', () => {
    test('no reader, fallback is null, ZERO GitHub requests even after start()', async () => {
        const m = mount({});
        assert.equal(m.pool.fallbackReader, null);
        m.pool.start();
        const r = await request(m.app).get('/api/ci-runners');
        assert.equal(r.status, 200);
        assert.equal(r.body.fallback, null);
        assert.equal(r.body.schemaVersion, 1);
        await new Promise((x) => setTimeout(x, 50));
        assert.equal(m.calls.length, 0);
    });

    test('credentials with the key missing is still no reader', () => {
        assert.equal(mount({ GITHUB_APP_ID: '1' }).pool.fallbackReader, null);
    });
});

describe('XACA-1465-004 App credentials, FLEET_CI_DISPATCHER unset', () => {
    test('reader exists, starts with a dormant dispatcher, and the route serves linux/macos + switches', async () => {
        const m = mount(CREDS, { values: { CI_LINUX_RUNNER: '["self-hosted","linux"]', CI_MACOS_RUNNER: '["ubuntu-latest"]' } });
        assert.ok(m.pool.fallbackReader);
        assert.equal(m.pool.dispatcher.isEnabled(), false);
        m.pool.start();
        assert.ok(await until(() => m.varCalls().length >= 3), 'reader read the 3 default switches');
        assert.ok(await until(() => m.pool.fallbackReader.snapshot().checkedAt !== null));
        const r = await request(m.app).get('/api/ci-runners');
        assert.equal(r.status, 200);
        assert.equal(r.body.schemaVersion, 1);
        const f = r.body.fallback;
        assert.ok(f && typeof f === 'object');
        assert.equal(f.switches.length, 3);
        assert.equal(f.linux.armed, true);
        assert.equal(f.macos, null, 'a value without self-hosted is malformed => unknown, never hosted');
        assert.equal(f.switches[2].armed, true, 'HEAVY unset follows CI_LINUX_RUNNER (XACA-1465-017)');
        assert.equal(f.switches[2].fallsBackTo, 'CI_LINUX_RUNNER');
        assert.ok(f.switches.every((s) => 'owner' in s && 'repo' in s && 'variable' in s && 'armed' in s));
        assert.equal('refresh' in r.body, false);
        assert.ok(m.varCalls().every((c) => c.method === 'GET'));
    });

    test('stop() halts the reader timer (no more reads)', async () => {
        const m = mount(CREDS);
        m.pool.start();
        assert.ok(await until(() => m.varCalls().length >= 3));
        m.pool.stop();
        const n = m.calls.length;
        await new Promise((x) => setTimeout(x, 60));
        assert.equal(m.calls.length, n);
    });

    test('PUT /api/ci-pool/fallback-switches triggers a re-read of the new list', async () => {
        const m = mount(CREDS, { values: { CI_ONLY: '["self-hosted"]' } });
        m.pool.start();
        assert.ok(await until(() => m.varCalls().length >= 3));
        const before = m.varCalls().length;
        const list = [{ owner: 'Acme', repo: 'widgets', variable: 'CI_ONLY', label: 'Only' }];
        const put = await request(m.app).put('/api/ci-pool/fallback-switches').set('Authorization', `Bearer ${ADMIN}`).send({ switches: list });
        assert.equal(put.status, 200);
        assert.ok(await until(() => m.varCalls().length > before), 're-read happened');
        assert.ok(m.varCalls().some((c) => c.path.endsWith('/widgets/actions/variables/CI_ONLY')));
        assert.ok(await until(() => {
            const s = m.pool.fallbackReader.snapshot();
            return s.switches.length === 1 && s.switches[0].armed === true;
        }));
        const r = await request(m.app).get('/api/ci-runners');
        assert.equal(r.body.fallback.switches.length, 1);
    });
});
