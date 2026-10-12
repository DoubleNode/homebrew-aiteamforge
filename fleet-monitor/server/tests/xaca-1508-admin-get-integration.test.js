//
//  xaca-1508-admin-get-integration.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1508-004 -- REAL client + REAL server, nothing stubbed on either auth layer.
 *
 * WHY THIS FILE EXISTS: XACA-1405 shipped with every admin-tier GET returning 401 after a
 * successful unlock (Notifications stayed LOCKED). Its jsdom tests stubbed fleetApiFetch and its
 * server tests hand-built request headers, so the client's header logic and the server's CSRF
 * check were each green while the PAIR was broken. Here the unmodified
 * public/lcars/js/fleet-api-auth.js talks over a real loopback socket to the unmodified
 * auth-middleware / admin-session / auth-routes / notify-routes / ci-pool-routes.
 *
 * BROWSER EMULATION (the crux). The only fake is the transport, and it follows what a browser
 * does for a SAME-ORIGIN fetch(credentials:'same-origin'):
 *   - sends the cookie jar (Cookie: name=value) filled from Set-Cookie responses;
 *   - adds `Sec-Fetch-Site: same-origin`;
 *   - adds `Origin` ONLY on POST/PUT/PATCH/DELETE -- never on GET/HEAD (browsers omit Origin on
 *     same-origin GET; that omission is precisely what the original bug tripped over);
 *   - passes through whatever headers the app code set (so X-Fleet-CSRF is present only if the
 *     client module added it). The Secure attribute is ignored: browsers treat loopback as a
 *     secure context, and the jar here keeps the __Host- cookie as a browser would.
 * Nothing in the transport adds X-Fleet-CSRF or edits the app's headers.
 *
 * REGRESSION PROOF: set XACA_1508_SRC_ROOT to a scratch copy of the server dir holding the
 * pre-fix (bb4a40cb) admin-session.js and fleet-api-auth.js; the "after unlock" GET tests must
 * then fail. Default is this checkout.
 *
 * All data lives in a temp dir; no real ~/.aiteamforge, no live server, synthetic names only.
 */

const { test, describe, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');
const crypto = require('crypto');
const express = require('express');
const { JSDOM } = require('jsdom');

const ROOT = process.env.XACA_1508_SRC_ROOT
    ? path.resolve(process.env.XACA_1508_SRC_ROOT)
    : path.join(__dirname, '..');

const ADMIN = 'adm' + crypto.randomBytes(16).toString('hex');
const FLEET = 'flt' + crypto.randomBytes(16).toString('hex');
const SAVED = { a: process.env.FLEET_ADMIN_TOKEN, f: process.env.FLEET_AUTH_TOKEN };
process.env.FLEET_ADMIN_TOKEN = ADMIN;   // admin tier SEPARATE from the fleet tier
process.env.FLEET_AUTH_TOKEN = FLEET;

const lib = (name) => require(path.join(ROOT, 'lib', name));
const { createFleetApiAuth } = require(path.join(ROOT, 'public', 'lcars', 'js', 'fleet-api-auth.js'));
const { registerAuthRoutes, createLoginLimiter } = lib('auth-routes');
const { registerNotifyRoutes } = lib('notify-routes');
const { createNotifyStore } = lib('notify-store');
const { createProviderRegistry } = lib('notify-providers');
const { createReceiptLog } = lib('notify-receipts');
const { registerCiPoolRoutes } = lib('ci-pool-routes');
const { createPoolStore } = lib('ci-pool-store');
const { createAssignments } = lib('ci-dispatch-assignments');
const { createAudit } = lib('ci-dispatch-audit');
const adminSession = lib('admin-session');

const NOTIFY_STATUS = '/api/notify/status';
const FALLBACK = '/api/ci-pool/fallback-switches';

let tmp, server, port, origin, dom, auth, jar;

/** One real HTTP round trip; no header is added or removed here. */
function raw(method, urlPath, headers = {}, body) {
    return new Promise((resolve, reject) => {
        const req = http.request({ host: '127.0.0.1', port, method, path: urlPath, headers }, (res) => {
            const chunks = [];
            res.on('data', (c) => chunks.push(c));
            res.on('end', () => {
                const text = Buffer.concat(chunks).toString('utf8');
                resolve({
                    status: res.statusCode,
                    ok: res.statusCode >= 200 && res.statusCode < 300,
                    headers: res.headers,
                    setCookie: res.headers['set-cookie'] || [],
                    text: async () => text,
                    json: async () => JSON.parse(text),
                });
            });
        });
        req.on('error', reject);
        if (body !== undefined) req.write(body);
        req.end();
    });
}

function toHeaderObject(h) {
    const out = {};
    if (!h) return out;
    if (typeof h.forEach === 'function' && typeof h.get === 'function') h.forEach((v, k) => { out[k] = v; });
    else for (const k of Object.keys(h)) out[k] = h[k];
    return out;
}

/** Browser-faithful same-origin fetch (see header comment). */
async function browserFetch(url, init = {}) {
    const u = new URL(String(url), origin);
    assert.equal(u.origin, origin, 'emulated browser fetch is same-origin only');
    const method = String(init.method || 'GET').toUpperCase();
    const headers = toHeaderObject(init.headers);
    headers['Sec-Fetch-Site'] = 'same-origin';
    if (['POST', 'PUT', 'PATCH', 'DELETE'].includes(method)) headers.Origin = origin; // NEVER on GET/HEAD
    if (init.credentials === 'same-origin' && jar.size) {
        headers.Cookie = [...jar].map(([k, v]) => `${k}=${v}`).join('; ');
    }
    let body;
    if (init.body !== undefined && init.body !== null) {
        body = String(init.body);
        headers['Content-Length'] = Buffer.byteLength(body);
    }
    const res = await raw(method, u.pathname + u.search, headers, body);
    for (const sc of res.setCookie) {
        const [pair, ...attrs] = sc.split(';').map((s) => s.trim());
        const i = pair.indexOf('=');
        const name = pair.slice(0, i);
        const val = pair.slice(i + 1);
        const maxAge = attrs.find((a) => /^max-age=/i.test(a));
        if (val === '' || (maxAge && Number(maxAge.split('=')[1]) <= 0)) jar.delete(name);
        else jar.set(name, val);
    }
    return res;
}

/** Drive the real unlock dialog exactly as an operator would. */
async function unlockViaDialog(token) {
    const pending = auth.unlock();
    const doc = dom.window.document;
    const input = doc.getElementById('fleet-unlock-token');
    assert.ok(input, 'unlock dialog rendered');
    input.value = token;
    const form = doc.querySelector('.fleet-unlock-form');
    form.dispatchEvent(new dom.window.Event('submit', { bubbles: true, cancelable: true }));
    return pending;
}

before(async () => {
    tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'x1508-004-'));
    const app = express();
    app.use(express.json());
    registerAuthRoutes(app, { limiter: createLoginLimiter() });

    const registry = createProviderRegistry();
    const notifyStore = createNotifyStore({
        file: path.join(tmp, 'notify.json'),
        key: crypto.randomBytes(32).toString('base64'),
        registry,
    });
    registerNotifyRoutes(app, {
        store: notifyStore, registry,
        receipts: createReceiptLog({ file: path.join(tmp, 'receipts.jsonl') }),
    });

    const poolStore = createPoolStore({ file: path.join(tmp, 'ci-pool.json'), logger: { error() {} } });
    poolStore.load();
    const audit = createAudit({ path: path.join(tmp, 'audit.jsonl'), keep: 2, now: () => new Date() });
    const assignments = createAssignments({
        file: path.join(tmp, 'state.json'),
        github: { async generateJitConfig() { throw new Error('unused'); }, async deleteRunner() { return { deleted: true }; } },
        audit, now: () => Date.now(), logger: { error() {}, warn() {} },
    });
    registerCiPoolRoutes(app, { store: poolStore, assignments, audit, now: () => Date.now(), logger: { error() {} } });

    server = http.createServer(app);
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    port = server.address().port;
    origin = `http://127.0.0.1:${port}`;

    jar = new Map();
    dom = new JSDOM('<!doctype html><html><head></head><body><main id="app"></main></body></html>', { url: origin + '/' });
    // REAL module, REAL jsdom document/location; only the transport is the browser emulation above.
    auth = createFleetApiAuth({ fetch: browserFetch, document: dom.window.document, location: dom.window.location });
});

after(async () => {
    if (server) await new Promise((resolve) => server.close(resolve));
    if (dom) dom.window.close();
    if (tmp) fs.rmSync(tmp, { recursive: true, force: true });
    if (SAVED.a === undefined) delete process.env.FLEET_ADMIN_TOKEN; else process.env.FLEET_ADMIN_TOKEN = SAVED.a;
    if (SAVED.f === undefined) delete process.env.FLEET_AUTH_TOKEN; else process.env.FLEET_AUTH_TOKEN = SAVED.f;
});

describe('real fleet-api-auth.js <-> real admin-tier middleware', () => {
    test('before unlock: both admin-tier GETs are 401 through apiFetch', async () => {
        assert.equal(jar.size, 0);
        for (const p of [NOTIFY_STATUS, FALLBACK]) {
            const r = await auth.apiFetch(p);
            assert.equal(r.status, 401, `${p} must be locked before unlock`);
        }
    });

    test('unlock through the real dialog stores the session cookie', async () => {
        const ok = await unlockViaDialog(ADMIN);
        assert.equal(ok, true, 'dialog resolved true');
        assert.ok(jar.has(adminSession.COOKIE_NAME), 'session cookie in the jar');
        const session = await (await browserFetch('/api/auth/session', { credentials: 'same-origin' })).json();
        assert.equal(session.authenticated, true);
    });

    test('after unlock: apiFetch GET /api/notify/status -> 200', async () => {
        const r = await auth.apiFetch(NOTIFY_STATUS);
        assert.equal(r.status, 200);
        const body = await r.json();
        assert.equal(typeof body.enabled, 'boolean');
    });

    test('after unlock: apiFetch GET /api/ci-pool/fallback-switches -> 200', async () => {
        const r = await auth.apiFetch(FALLBACK);
        assert.equal(r.status, 200);
        assert.ok(Array.isArray((await r.json()).switches));
    });

    test('after unlock: a mutating admin call (PUT fallback-switches, reset) still works end to end', async () => {
        const r = await auth.apiFetch(FALLBACK, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ switches: null }),
        });
        assert.equal(r.status, 200);
    });

    test('the emulation sends no Origin on GET while the client supplies X-Fleet-CSRF (guards the harness itself)', async () => {
        let appHeaders;
        let wireHeaders;
        const spy = createFleetApiAuth({
            fetch: async (u, i) => { appHeaders = toHeaderObject(i.headers); return browserFetch(u, i); },
            document: dom.window.document, location: dom.window.location,
        });
        const real = http.request;
        http.request = function patched(opts, cb) { wireHeaders = opts.headers; return real.call(this, opts, cb); };
        try {
            await spy.apiFetch(NOTIFY_STATUS);
        } finally {
            http.request = real;
        }
        const lower = (o) => Object.fromEntries(Object.entries(o).map(([k, v]) => [k.toLowerCase(), v]));
        assert.equal(lower(appHeaders)['x-fleet-csrf'], '1', 'client module added the CSRF header');
        assert.equal(lower(appHeaders).origin, undefined, 'app code supplies no Origin');
        assert.equal(lower(wireHeaders).origin, undefined, 'transport adds no Origin on GET');
    });
});

describe('raw adversarial requests with a VALID session cookie (same server)', () => {
    let cookie;
    before(async () => {
        const body = JSON.stringify({ token: ADMIN });
        const login = await raw('POST', '/api/auth/login', {
            'Content-Type': 'application/json', 'X-Fleet-CSRF': '1', Origin: origin,
            'Sec-Fetch-Site': 'same-origin', 'Content-Length': Buffer.byteLength(body),
        }, body);
        assert.equal(login.status, 200);
        cookie = login.setCookie[0].split(';')[0];
    });

    const get = (p, extra) => raw('GET', p, Object.assign({ Cookie: cookie }, extra));

    for (const p of [NOTIFY_STATUS, FALLBACK]) {
        test(`${p}: cookie + header, no Origin (the browser shape) -> 200`, async () => {
            assert.equal((await get(p, { 'X-Fleet-CSRF': '1', 'Sec-Fetch-Site': 'same-origin' })).status, 200);
        });
        test(`${p}: cookie WITHOUT X-Fleet-CSRF -> 401`, async () => {
            assert.equal((await get(p, { 'Sec-Fetch-Site': 'same-origin' })).status, 401);
        });
        test(`${p}: cookie + header + foreign Origin -> 401`, async () => {
            assert.equal((await get(p, { 'X-Fleet-CSRF': '1', Origin: 'https://evil.example' })).status, 401);
        });
        test(`${p}: cookie + header + Origin "null" -> 401`, async () => {
            assert.equal((await get(p, { 'X-Fleet-CSRF': '1', Origin: 'null' })).status, 401);
        });
        test(`${p}: cookie + header + Sec-Fetch-Site cross-site -> 401`, async () => {
            assert.equal((await get(p, { 'X-Fleet-CSRF': '1', 'Sec-Fetch-Site': 'cross-site' })).status, 401);
        });
        test(`${p}: no cookie, header only -> 401`, async () => {
            assert.equal((await raw('GET', p, { 'X-Fleet-CSRF': '1' })).status, 401);
        });
    }

    test('PUT with cookie + header but NO Origin -> 401 (strict path preserved)', async () => {
        const body = JSON.stringify({ switches: null });
        const r = await raw('PUT', FALLBACK, {
            Cookie: cookie, 'X-Fleet-CSRF': '1', 'Content-Type': 'application/json',
            'Content-Length': Buffer.byteLength(body),
        }, body);
        assert.equal(r.status, 401);
    });

    test('POST (login) with header but NO Origin -> 403 CSRF refusal (strict path preserved)', async () => {
        const body = JSON.stringify({ token: ADMIN });
        const r = await raw('POST', '/api/auth/login', {
            'X-Fleet-CSRF': '1', 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body),
        }, body);
        assert.equal(r.status, 403);
    });

    test('PUT with cookie + header + matching Origin -> 200 (positive control for the strict path)', async () => {
        const body = JSON.stringify({ switches: null });
        const r = await raw('PUT', FALLBACK, {
            Cookie: cookie, 'X-Fleet-CSRF': '1', Origin: origin, 'Content-Type': 'application/json',
            'Content-Length': Buffer.byteLength(body),
        }, body);
        assert.equal(r.status, 200);
    });
});
