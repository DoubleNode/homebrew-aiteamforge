//
//  xaca-0398-003-admin-tier.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-0398-003 — two credential tiers + the admin session cookie.
 *
 * Normative spec: kanban/plans/XACA-0395/XACA-0395_auth_contract.md §3.6 and
 * §7 "Tiers" (XACA-0398 amendment). Design:
 * kanban/plans/XACA-0398/XACA-0398_credential_design.md.
 *
 * Sections:
 *   1. lib/admin-session.js — issue/verify, expiry, tamper, rotation, cookie
 *      attributes (SameSite=Strict is CSRF layer 1).
 *   2. Tier matrix (in-process app) — each tier accepts the right token and
 *      rejects the wrong one; staging fallback; admin-only; open posture.
 *   3. Cookie login + CSRF — login/logout/session routes, each CSRF layer
 *      rejecting on its own, header auth unaffected, cookie refused on the
 *      fleet tier, rate limit, no echo of the token.
 *   4. Route inventory (static, source-derived) — the 19 admin routes are on
 *      requireAdminKey, the 9 fleet routes stay on the fleet gate, and every
 *      mutating route anywhere is gated or deliberately allowlisted.
 *   5. vault + engines (real route modules) — ALL 9 of their admin routes
 *      refuse the fleet token once FLEET_ADMIN_TOKEN is set.
 *   6. server.js (real child process) — ALL 10 of its admin routes refuse
 *      the fleet token; admin token + cookie reach the handler; the CSRF
 *      header is not approved cross-origin; the startup log never contains a
 *      token.
 *   7. FLEET_REQUIRE_AUTH=1 refuses to start unless BOTH tokens resolve.
 *   8. logAuthStartupNotice — one line per tier.
 *
 * Fixture values are obviously fake (contract §8 L5). None is a real token.
 */

const { test, describe, before, after, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const express = require('express');
const path = require('path');
const os = require('os');
const fs = require('fs');
const net = require('net');
const { spawn } = require('child_process');

// Isolate the vault/engines stores BEFORE anything requires them.
const TEST_VAULT_FILE = path.join(os.tmpdir(), `xaca-0398-003-vault-${process.pid}-${Date.now()}.json`);
const TEST_ENGINES_FILE = path.join(os.tmpdir(), `xaca-0398-003-engines-${process.pid}-${Date.now()}.json`);
process.env.FLEET_VAULT_FILE = TEST_VAULT_FILE;
process.env.FLEET_ENGINES_FILE = TEST_ENGINES_FILE;

const auth = require('../lib/auth-middleware');
const adminSession = require('../lib/admin-session');
const { registerAuthRoutes, createLoginLimiter } = require('../lib/auth-routes');
const { registerVaultRoutes } = require('../lib/vault-routes');
const { registerEnginesRoutes } = require('../lib/engines-routes');

const SERVER_DIR = path.join(__dirname, '..');

const FLEET_TOKEN = 'test-fleet-token-not-a-real-secret';
const ADMIN_TOKEN = 'test-admin-token-not-a-real-secret';
const WRONG_TOKEN = 'test-wrong-token-not-a-real-secret';
const EXPECTED_401_BODY = { error: 'Unauthorized', code: 'unauthorized' };
const EXPECTED_401_TEXT = '{"error":"Unauthorized","code":"unauthorized"}';

const HOST = 'fleet-monitor.test';
const ORIGIN = `https://${HOST}`;

function setTokens({ fleet, admin }) {
    if (fleet === undefined) delete process.env.FLEET_AUTH_TOKEN; else process.env.FLEET_AUTH_TOKEN = fleet;
    if (admin === undefined) delete process.env.FLEET_ADMIN_TOKEN; else process.env.FLEET_ADMIN_TOKEN = admin;
}

function clearTokens() {
    delete process.env.FLEET_AUTH_TOKEN;
    delete process.env.FLEET_ADMIN_TOKEN;
}

clearTokens();

after(() => {
    clearTokens();
    try { fs.unlinkSync(TEST_VAULT_FILE); } catch (_) { /* noop */ }
    try { fs.unlinkSync(TEST_ENGINES_FILE); } catch (_) { /* noop */ }
});

// ===========================================================================
// 1. lib/admin-session.js
// ===========================================================================

describe('admin-session: issue / verify', () => {
    test('a freshly issued session verifies against the same key', () => {
        const s = adminSession.issueSession(ADMIN_TOKEN);
        const v = adminSession.verifySession(s.value, ADMIN_TOKEN);
        assert.equal(v.valid, true);
        assert.equal(v.expiresAtMs, s.expiresAtMs);
    });

    test('TTL is 8 hours (user decision)', () => {
        const now = Date.UTC(2026, 8, 23, 12, 0, 0);
        const s = adminSession.issueSession(ADMIN_TOKEN, { nowMs: now });
        assert.equal(adminSession.SESSION_TTL_SECONDS, 8 * 3600);
        assert.equal(s.expiresAtMs - now, 8 * 3600 * 1000);
    });

    test('the session value never contains the key', () => {
        const s = adminSession.issueSession(ADMIN_TOKEN);
        assert.ok(!s.value.includes(ADMIN_TOKEN));
    });

    test('expired session is rejected', () => {
        const issuedAt = Date.now() - (8 * 3600 + 1) * 1000;
        const s = adminSession.issueSession(ADMIN_TOKEN, { nowMs: issuedAt });
        assert.equal(adminSession.verifySession(s.value, ADMIN_TOKEN).valid, false);
    });

    test('session is still valid one second before expiry', () => {
        const issuedAt = Date.now() - (8 * 3600 - 5) * 1000;
        const s = adminSession.issueSession(ADMIN_TOKEN, { nowMs: issuedAt });
        assert.equal(adminSession.verifySession(s.value, ADMIN_TOKEN).valid, true);
    });

    test('a session claiming an expiry beyond the TTL is rejected (cannot come from issueSession)', () => {
        const s = adminSession.issueSession(ADMIN_TOKEN, { nowMs: Date.now() + 24 * 3600 * 1000 });
        assert.equal(adminSession.verifySession(s.value, ADMIN_TOKEN).valid, false);
    });

    test('rotation: a session issued under one key does not verify under another', () => {
        const s = adminSession.issueSession(ADMIN_TOKEN);
        assert.equal(adminSession.verifySession(s.value, WRONG_TOKEN).valid, false);
    });

    test('tamper: changing any part of the value is rejected', () => {
        const s = adminSession.issueSession(ADMIN_TOKEN);
        const [v, exp, nonce, mac] = s.value.split('.');
        const flip = (str) => (str[0] === 'A' ? 'B' : 'A') + str.slice(1);
        const variants = [
            [v, String(Number(exp) + 60), nonce, mac].join('.'), // extend expiry
            [v, exp, flip(nonce), mac].join('.'),
            [v, exp, nonce, flip(mac)].join('.'),
            ['v2', exp, nonce, mac].join('.'),
            [v, exp, nonce].join('.'),
            [v, exp, nonce, mac, 'x'].join('.'),
            [v, exp, nonce, mac.slice(0, -2)].join('.'),
            '',
            'garbage',
        ];
        for (const bad of variants) {
            assert.equal(adminSession.verifySession(bad, ADMIN_TOKEN).valid, false, `should reject: ${bad}`);
        }
    });

    test('verifySession never throws on hostile input', () => {
        for (const bad of [null, undefined, 42, {}, 'v1.' + 'a'.repeat(600), 'v1.1.%%%.%%%']) {
            assert.doesNotThrow(() => adminSession.verifySession(bad, ADMIN_TOKEN));
            assert.equal(adminSession.verifySession(bad, ADMIN_TOKEN).valid, false);
        }
    });

    test('no key -> issue throws, verify rejects', () => {
        assert.throws(() => adminSession.issueSession(null));
        const s = adminSession.issueSession(ADMIN_TOKEN);
        assert.equal(adminSession.verifySession(s.value, null).valid, false);
    });
});

describe('admin-session: cookie serialization (CSRF layer 1 is SameSite=Strict)', () => {
    test('session cookie carries __Host- name, Path=/, HttpOnly, Secure, SameSite=Strict, 8 h Max-Age, no Domain', () => {
        const c = adminSession.serializeSessionCookie('v1.x.y.z');
        assert.match(c, /^__Host-fleet_admin=v1\.x\.y\.z;/);
        assert.match(c, /; Path=\/(;|$)/);
        assert.match(c, /; HttpOnly(;|$)/);
        assert.match(c, /; Secure(;|$)/);
        assert.match(c, /; SameSite=Strict(;|$)/);
        assert.match(c, /; Max-Age=28800(;|$)/);
        assert.ok(!/Domain=/i.test(c), '__Host- cookies must not carry Domain');
    });

    test('clear cookie has Max-Age=0 and the same security attributes', () => {
        const c = adminSession.serializeClearCookie();
        assert.match(c, /^__Host-fleet_admin=;/);
        assert.match(c, /Max-Age=0/);
        assert.match(c, /HttpOnly/);
        assert.match(c, /Secure/);
        assert.match(c, /SameSite=Strict/);
    });

    test('parseCookies: first occurrence wins, ignores junk, bounds size', () => {
        const c = adminSession.parseCookies('a=1; __Host-fleet_admin=first; __Host-fleet_admin=second; junk; =x');
        assert.equal(c['__Host-fleet_admin'], 'first');
        assert.equal(c.a, '1');
        assert.deepEqual(Object.keys(adminSession.parseCookies('x=' + 'a'.repeat(9000))), []);
    });
});

describe('admin-session: request-side CSRF rules, each on its own', () => {
    const base = { 'x-fleet-csrf': '1', origin: ORIGIN, host: HOST, 'sec-fetch-site': 'same-origin' };
    const req = (overrides) => {
        const headers = { ...base, ...overrides };
        for (const k of Object.keys(headers)) if (headers[k] === undefined) delete headers[k];
        return { headers };
    };

    test('baseline passes', () => assert.equal(adminSession.passesCsrfChecks(req({})), true));
    test('Sec-Fetch-Site absent is allowed (older browsers)', () =>
        assert.equal(adminSession.passesCsrfChecks(req({ 'sec-fetch-site': undefined })), true));
    test('layer 2: missing X-Fleet-CSRF', () => assert.equal(adminSession.passesCsrfChecks(req({ 'x-fleet-csrf': undefined })), false));
    test('layer 2: X-Fleet-CSRF with a value other than 1', () => assert.equal(adminSession.passesCsrfChecks(req({ 'x-fleet-csrf': 'yes' })), false));
    test('layer 3: missing Origin', () => assert.equal(adminSession.passesCsrfChecks(req({ origin: undefined })), false));
    test('layer 3: Origin "null"', () => assert.equal(adminSession.passesCsrfChecks(req({ origin: 'null' })), false));
    test('layer 3: Origin on a sibling *.fly.dev app (shared suffix, no PSL reliance)', () =>
        assert.equal(adminSession.passesCsrfChecks(req({ origin: 'https://evil.fly.dev', host: 'fleet-monitor.fly.dev' })), false));
    test('layer 3: Origin differing only by port', () => assert.equal(adminSession.passesCsrfChecks(req({ origin: `${ORIGIN}:8443` })), false));
    test('layer 3: Origin with a path is not a browser Origin', () => assert.equal(adminSession.passesCsrfChecks(req({ origin: `${ORIGIN}/x` })), false));
    test('layer 3: non-http scheme', () => assert.equal(adminSession.passesCsrfChecks(req({ origin: `ftp://${HOST}` })), false));
    test('layer 3: host comparison is case-insensitive', () =>
        assert.equal(adminSession.passesCsrfChecks(req({ origin: `https://FLEET-monitor.test` })), true));
    test('layer 4: Sec-Fetch-Site cross-site', () => assert.equal(adminSession.passesCsrfChecks(req({ 'sec-fetch-site': 'cross-site' })), false));
    test('layer 4: Sec-Fetch-Site same-site (sibling subdomain)', () => assert.equal(adminSession.passesCsrfChecks(req({ 'sec-fetch-site': 'same-site' })), false));
    test('layer 4: Sec-Fetch-Site none', () => assert.equal(adminSession.passesCsrfChecks(req({ 'sec-fetch-site': 'none' })), false));
});

// ===========================================================================
// 2. Tier matrix (in-process)
// ===========================================================================

function buildTierApp({ limiter } = {}) {
    const app = express();
    app.use(express.json());
    app.post('/fleet', auth.requireApiKey, (req, res) => res.json({ ok: true }));
    app.post('/admin', auth.requireAdminKey, (req, res) => res.json({ ok: true }));
    app.get('/fleet-guard', (req, res) => { if (!auth.checkApiKey(req, res)) return; res.json({ ok: true }); });
    app.get('/admin-guard', (req, res) => { if (!auth.checkAdminKey(req, res)) return; res.json({ ok: true }); });
    registerAuthRoutes(app, { limiter: limiter || createLoginLimiter() });
    return app;
}

async function statusWith(app, route, token, header = 'bearer') {
    const r = request(app).post(route).set('Host', HOST);
    if (token && header === 'bearer') r.set('Authorization', `Bearer ${token}`);
    if (token && header === 'x-api-key') r.set('X-API-Key', token);
    return (await r.send({})).status;
}

describe('tier matrix — both tokens set', () => {
    const app = buildTierApp();
    beforeEach(() => setTokens({ fleet: FLEET_TOKEN, admin: ADMIN_TOKEN }));
    afterEach(clearTokens);

    test('fleet route accepts the fleet token (Bearer and X-API-Key)', async () => {
        assert.equal(await statusWith(app, '/fleet', FLEET_TOKEN), 200);
        assert.equal(await statusWith(app, '/fleet', FLEET_TOKEN, 'x-api-key'), 200);
    });
    test('fleet route accepts the admin token (admin is a superset)', async () => {
        assert.equal(await statusWith(app, '/fleet', ADMIN_TOKEN), 200);
    });
    test('fleet route rejects a wrong token and no token', async () => {
        assert.equal(await statusWith(app, '/fleet', WRONG_TOKEN), 401);
        assert.equal(await statusWith(app, '/fleet', null), 401);
    });
    test('admin route accepts the admin token (Bearer and X-API-Key)', async () => {
        assert.equal(await statusWith(app, '/admin', ADMIN_TOKEN), 200);
        assert.equal(await statusWith(app, '/admin', ADMIN_TOKEN, 'x-api-key'), 200);
    });
    test('admin route REJECTS the fleet token once FLEET_ADMIN_TOKEN is set', async () => {
        assert.equal(await statusWith(app, '/admin', FLEET_TOKEN), 401);
        assert.equal(await statusWith(app, '/admin', FLEET_TOKEN, 'x-api-key'), 401);
    });
    test('admin route rejects a wrong token and no token', async () => {
        assert.equal(await statusWith(app, '/admin', WRONG_TOKEN), 401);
        assert.equal(await statusWith(app, '/admin', null), 401);
    });
    test('admin route: Bearer and X-API-Key disagreeing -> 401 even if one is the admin token', async () => {
        const res = await request(app).post('/admin').set('Authorization', `Bearer ${ADMIN_TOKEN}`).set('X-API-Key', FLEET_TOKEN).send({});
        assert.equal(res.status, 401);
    });
    test('guard forms follow the same tiers', async () => {
        assert.equal((await request(app).get('/fleet-guard').set('Authorization', `Bearer ${FLEET_TOKEN}`)).status, 200);
        assert.equal((await request(app).get('/admin-guard').set('Authorization', `Bearer ${FLEET_TOKEN}`)).status, 401);
        assert.equal((await request(app).get('/admin-guard').set('Authorization', `Bearer ${ADMIN_TOKEN}`)).status, 200);
    });
    test('every rejection on either tier is the byte-identical contract §4 401', async () => {
        const bodies = new Set();
        for (const [route, tok] of [['/fleet', null], ['/fleet', WRONG_TOKEN], ['/admin', null], ['/admin', FLEET_TOKEN], ['/admin', WRONG_TOKEN]]) {
            const r = request(app).post(route);
            if (tok) r.set('Authorization', `Bearer ${tok}`);
            const res = await r.send({});
            assert.equal(res.status, 401);
            bodies.add(res.text);
        }
        assert.deepEqual([...bodies], [EXPECTED_401_TEXT]);
    });
});

describe('tier matrix — staging fallback (FLEET_ADMIN_TOKEN unset)', () => {
    const app = buildTierApp();
    afterEach(clearTokens);

    test('admin route accepts the fleet token while FLEET_ADMIN_TOKEN is unset', async () => {
        setTokens({ fleet: FLEET_TOKEN });
        assert.equal(await statusWith(app, '/admin', FLEET_TOKEN), 200);
        assert.equal(await statusWith(app, '/admin', WRONG_TOKEN), 401);
        assert.equal(await statusWith(app, '/admin', null), 401);
    });
    test('a BLANK FLEET_ADMIN_TOKEN is ignored and falls back to the fleet token (not open)', async () => {
        setTokens({ fleet: FLEET_TOKEN, admin: '   ' });
        assert.equal(await statusWith(app, '/admin', FLEET_TOKEN), 200);
        assert.equal(await statusWith(app, '/admin', null), 401);
    });
    test('getAdminExpectedKey follows the fallback order', () => {
        setTokens({ fleet: FLEET_TOKEN });
        assert.equal(auth.getAdminExpectedKey(), FLEET_TOKEN);
        setTokens({ fleet: FLEET_TOKEN, admin: ADMIN_TOKEN });
        assert.equal(auth.getAdminExpectedKey(), ADMIN_TOKEN);
        clearTokens();
        assert.equal(auth.getAdminExpectedKey(), null);
    });
});

describe('tier matrix — admin token only, and fully open', () => {
    const app = buildTierApp();
    afterEach(clearTokens);

    test('only FLEET_ADMIN_TOKEN set: both tiers are closed and accept only the admin token', async () => {
        setTokens({ admin: ADMIN_TOKEN });
        assert.equal(await statusWith(app, '/fleet', ADMIN_TOKEN), 200);
        assert.equal(await statusWith(app, '/fleet', null), 401);
        assert.equal(await statusWith(app, '/fleet', FLEET_TOKEN), 401);
        assert.equal(await statusWith(app, '/admin', ADMIN_TOKEN), 200);
        assert.equal(await statusWith(app, '/admin', null), 401);
    });
    test('neither token set: both tiers open (contract §7, unchanged)', async () => {
        clearTokens();
        assert.equal(await statusWith(app, '/fleet', null), 200);
        assert.equal(await statusWith(app, '/admin', null), 200);
    });
    test('getAuthPosture reports states only', () => {
        setTokens({ fleet: FLEET_TOKEN, admin: '' });
        assert.deepEqual(auth.getAuthPosture(), { fleet: 'set', admin: 'blank' });
        clearTokens();
        assert.deepEqual(auth.getAuthPosture(), { fleet: 'absent', admin: 'absent' });
    });
});

// ===========================================================================
// 3. Cookie login + CSRF
// ===========================================================================

function csrfHeaders(extra = {}) {
    return { Host: HOST, Origin: ORIGIN, 'X-Fleet-CSRF': '1', 'Sec-Fetch-Site': 'same-origin', ...extra };
}

function applyHeaders(r, headers) {
    for (const [k, v] of Object.entries(headers)) if (v !== undefined) r.set(k, v);
    return r;
}

async function login(app, token, headers = csrfHeaders()) {
    return applyHeaders(request(app).post('/api/auth/login'), headers).send({ token });
}

function cookieFrom(res) {
    const set = res.headers['set-cookie'] || [];
    const line = set.find((c) => c.startsWith('__Host-fleet_admin='));
    return line ? line.split(';')[0] : null;
}

async function adminWithCookie(app, cookie, headers = csrfHeaders()) {
    return applyHeaders(request(app).post('/admin'), { ...headers, Cookie: cookie }).send({});
}

describe('cookie login — happy path and credential scope', () => {
    let app;
    beforeEach(() => { setTokens({ fleet: FLEET_TOKEN, admin: ADMIN_TOKEN }); app = buildTierApp(); });
    afterEach(clearTokens);

    test('login with the admin token -> 200, HttpOnly/Secure/SameSite=Strict cookie, no token echo', async () => {
        const res = await login(app, ADMIN_TOKEN);
        assert.equal(res.status, 200);
        assert.equal(res.body.authenticated, true);
        assert.equal(typeof res.body.expiresAt, 'number');
        const line = (res.headers['set-cookie'] || []).join('\n');
        assert.match(line, /__Host-fleet_admin=v1\./);
        assert.match(line, /HttpOnly/);
        assert.match(line, /Secure/);
        assert.match(line, /SameSite=Strict/);
        assert.match(line, /Max-Age=28800/);
        assert.equal(res.headers['cache-control'], 'no-store');
        assert.ok(!res.text.includes(ADMIN_TOKEN) && !line.includes(ADMIN_TOKEN), 'login must never echo the token');
    });

    test('the cookie authenticates an admin route when every CSRF rule holds', async () => {
        const cookie = cookieFrom(await login(app, ADMIN_TOKEN));
        assert.equal((await adminWithCookie(app, cookie)).status, 200);
    });

    test('the cookie is NOT a credential on a fleet-tier route', async () => {
        const cookie = cookieFrom(await login(app, ADMIN_TOKEN));
        const res = await applyHeaders(request(app).post('/fleet'), { ...csrfHeaders(), Cookie: cookie }).send({});
        assert.equal(res.status, 401);
        assert.equal(res.text, EXPECTED_401_TEXT);
    });

    test('a wrong header credential is decisive even alongside a valid cookie', async () => {
        const cookie = cookieFrom(await login(app, ADMIN_TOKEN));
        const res = await adminWithCookie(app, cookie, csrfHeaders({ Authorization: `Bearer ${WRONG_TOKEN}` }));
        assert.equal(res.status, 401);
    });

    test('header auth is unaffected: no Origin, no CSRF header, no cookie -> still 200', async () => {
        const res = await request(app).post('/admin').set('Authorization', `Bearer ${ADMIN_TOKEN}`).send({});
        assert.equal(res.status, 200);
        const res2 = await request(app).post('/fleet').set('X-API-Key', FLEET_TOKEN).send({});
        assert.equal(res2.status, 200);
    });

    test('GET /api/auth/session reports closed + authenticated with the cookie, and unauthenticated without', async () => {
        const cookie = cookieFrom(await login(app, ADMIN_TOKEN));
        const withCookie = await request(app).get('/api/auth/session').set('Cookie', cookie);
        assert.equal(withCookie.body.gate, 'closed');
        assert.equal(withCookie.body.authenticated, true);
        assert.equal(typeof withCookie.body.expiresAt, 'number');
        const without = await request(app).get('/api/auth/session');
        assert.deepEqual(without.body, { gate: 'closed', authenticated: false, expiresAt: null });
    });

    test('logout clears the cookie (Max-Age=0) and requires the CSRF rules', async () => {
        const ok = await applyHeaders(request(app).post('/api/auth/logout'), csrfHeaders()).send();
        assert.equal(ok.status, 204);
        assert.match((ok.headers['set-cookie'] || []).join('\n'), /__Host-fleet_admin=;.*Max-Age=0/);
        const bad = await request(app).post('/api/auth/logout').set('Host', HOST).send();
        assert.equal(bad.status, 403);
    });
});

describe('cookie login — failures', () => {
    let app;
    beforeEach(() => { setTokens({ fleet: FLEET_TOKEN, admin: ADMIN_TOKEN }); app = buildTierApp(); });
    afterEach(clearTokens);

    test('wrong token -> byte-identical 401, no cookie, no echo', async () => {
        const res = await login(app, WRONG_TOKEN);
        assert.equal(res.status, 401);
        assert.equal(res.text, EXPECTED_401_TEXT);
        assert.equal(cookieFrom(res), null);
        assert.ok(!res.text.includes(WRONG_TOKEN));
    });

    test('the FLEET token cannot log in once FLEET_ADMIN_TOKEN is set', async () => {
        const res = await login(app, FLEET_TOKEN);
        assert.equal(res.status, 401);
        assert.equal(cookieFrom(res), null);
    });

    test('malformed / missing token -> the same 401 bytes', async () => {
        for (const bad of ['short', '', 'has space in it but long enough', undefined]) {
            const res = await login(app, bad);
            assert.equal(res.status, 401);
            assert.equal(res.text, EXPECTED_401_TEXT);
        }
    });

    test('login itself enforces each CSRF rule (login CSRF would plant a hostile session)', async () => {
        const cases = [
            csrfHeaders({ 'X-Fleet-CSRF': undefined }),
            csrfHeaders({ Origin: undefined }),
            csrfHeaders({ Origin: 'https://evil.test' }),
            csrfHeaders({ 'Sec-Fetch-Site': 'cross-site' }),
        ];
        for (const headers of cases) {
            const res = await login(app, ADMIN_TOKEN, headers);
            assert.equal(res.status, 403, JSON.stringify(headers));
            assert.equal(cookieFrom(res), null);
        }
    });

    test('rate limit: after 10 failures from one address even the right token gets 429', async () => {
        const limitedApp = buildTierApp({ limiter: createLoginLimiter({ maxFailures: 10, windowMs: 60000 }) });
        for (let i = 0; i < 10; i++) {
            assert.equal((await login(limitedApp, WRONG_TOKEN)).status, 401);
        }
        const blocked = await login(limitedApp, ADMIN_TOKEN);
        assert.equal(blocked.status, 429);
        assert.equal(cookieFrom(blocked), null);
        assert.ok(blocked.headers['retry-after']);
    });

    test('rate limit window expires', async () => {
        let t = 1_000_000;
        const limiter = createLoginLimiter({ maxFailures: 2, windowMs: 1000, now: () => t });
        limiter.recordFailure('a'); limiter.recordFailure('a');
        assert.equal(limiter.isBlocked('a'), true);
        assert.equal(limiter.isBlocked('b'), false);
        t += 1001;
        assert.equal(limiter.isBlocked('a'), false);
    });

    test('gate open (no tokens): login -> 409, no cookie; session reports open', async () => {
        clearTokens();
        const res = await login(app, ADMIN_TOKEN);
        assert.equal(res.status, 409);
        assert.equal(cookieFrom(res), null);
        const s = await request(app).get('/api/auth/session');
        assert.deepEqual(s.body, { gate: 'open', authenticated: false, expiresAt: null });
    });
});

describe('cookie on an admin route — each CSRF layer rejects on its own', () => {
    let app;
    let cookie;
    before(async () => {
        setTokens({ fleet: FLEET_TOKEN, admin: ADMIN_TOKEN });
        app = buildTierApp();
        cookie = cookieFrom(await login(app, ADMIN_TOKEN));
        assert.ok(cookie, 'precondition: login produced a cookie');
    });
    beforeEach(() => setTokens({ fleet: FLEET_TOKEN, admin: ADMIN_TOKEN }));
    after(clearTokens);

    test('control: all layers satisfied -> 200', async () => {
        assert.equal((await adminWithCookie(app, cookie)).status, 200);
    });
    const cases = {
        'layer 2: no X-Fleet-CSRF header': { 'X-Fleet-CSRF': undefined },
        'layer 3: no Origin': { Origin: undefined },
        'layer 3: Origin is a sibling *.fly.dev app': { Host: 'fleet-monitor.fly.dev', Origin: 'https://attacker.fly.dev' },
        'layer 3: Origin "null"': { Origin: 'null' },
        'layer 4: Sec-Fetch-Site cross-site': { 'Sec-Fetch-Site': 'cross-site' },
        'layer 4: Sec-Fetch-Site same-site': { 'Sec-Fetch-Site': 'same-site' },
    };
    for (const [name, override] of Object.entries(cases)) {
        test(`${name} -> byte-identical 401`, async () => {
            const res = await adminWithCookie(app, cookie, csrfHeaders(override));
            assert.equal(res.status, 401);
            assert.equal(res.text, EXPECTED_401_TEXT);
        });
    }
    test('layer 1: the issued cookie is SameSite=Strict (asserted on the real login response)', async () => {
        const res = await login(app, ADMIN_TOKEN);
        assert.match((res.headers['set-cookie'] || []).join('\n'), /SameSite=Strict/);
    });

    test('expired cookie -> 401', async () => {
        const old = adminSession.issueSession(ADMIN_TOKEN, { nowMs: Date.now() - 9 * 3600 * 1000 });
        const res = await adminWithCookie(app, `${adminSession.COOKIE_NAME}=${old.value}`);
        assert.equal(res.status, 401);
    });

    test('tampered cookie -> 401', async () => {
        const value = cookie.split('=').slice(1).join('=');
        const [v, exp, nonce, mac] = value.split('.');
        const forged = [v, String(Number(exp) + 3600), nonce, mac].join('.');
        const res = await adminWithCookie(app, `${adminSession.COOKIE_NAME}=${forged}`);
        assert.equal(res.status, 401);
    });

    test('rotation: changing FLEET_ADMIN_TOKEN invalidates the existing cookie', async () => {
        process.env.FLEET_ADMIN_TOKEN = 'test-rotated-admin-token-not-real';
        const res = await adminWithCookie(app, cookie);
        assert.equal(res.status, 401);
    });

    test('stage 2 -> 3: a session issued on the shared fleet token dies when FLEET_ADMIN_TOKEN is first set', async () => {
        setTokens({ fleet: FLEET_TOKEN });
        const stage2Cookie = cookieFrom(await login(app, FLEET_TOKEN));
        assert.ok(stage2Cookie);
        assert.equal((await adminWithCookie(app, stage2Cookie)).status, 200);
        setTokens({ fleet: FLEET_TOKEN, admin: ADMIN_TOKEN });
        assert.equal((await adminWithCookie(app, stage2Cookie)).status, 401);
    });
});

// ===========================================================================
// 4. Route inventory (static, source-derived)
// ===========================================================================

// The 19 admin-tier routes, from the design's §1 tier classification. This is
// the EXPECTED list — deliberately not derived from source, so a route moved
// back to requireApiKey disappears from the source-derived admin set and the
// equality assertion below fails.
const ADMIN_ROUTES = [
    { method: 'PUT',    path: '/api/machine/:machineId/nickname',                file: 'server.js' },
    { method: 'POST',   path: '/api/credentials/:integration',                   file: 'server.js' },
    { method: 'DELETE', path: '/api/credentials/:integration',                   file: 'server.js' },
    { method: 'PUT',    path: '/api/dashboards/reorder',                         file: 'server.js' },
    { method: 'POST',   path: '/api/dashboards',                                 file: 'server.js' },
    { method: 'PUT',    path: '/api/dashboards/:id',                             file: 'server.js' },
    { method: 'DELETE', path: '/api/dashboards/:id',                             file: 'server.js' },
    { method: 'POST',   path: '/api/epics/:team',                                file: 'server.js' },
    { method: 'PUT',    path: '/api/epics/:team/:epicId',                        file: 'server.js' },
    { method: 'DELETE', path: '/api/epics/:team/:epicId',                        file: 'server.js' },
    { method: 'POST',   path: '/api/engines/:engineSlug/accounts',               file: 'lib/engines-routes.js' },
    { method: 'PUT',    path: '/api/engines/:engineSlug/accounts/:accountSlug',  file: 'lib/engines-routes.js' },
    { method: 'DELETE', path: '/api/engines/:engineSlug/accounts/:accountSlug',  file: 'lib/engines-routes.js' },
    { method: 'POST',   path: '/api/vault/machines',                             file: 'lib/vault-routes.js' },
    { method: 'PUT',    path: '/api/vault/machines/:id',                         file: 'lib/vault-routes.js' },
    { method: 'DELETE', path: '/api/vault/machines/:id',                         file: 'lib/vault-routes.js' },
    { method: 'POST',   path: '/api/vault/secrets',                              file: 'lib/vault-routes.js' },
    { method: 'PUT',    path: '/api/vault/secrets/:engineSlug/:accountSlug',     file: 'lib/vault-routes.js' },
    { method: 'DELETE', path: '/api/vault/secrets/:engineSlug/:accountSlug',     file: 'lib/vault-routes.js' },
];

// The 9 fleet-tier routes. 6 use requireApiKey middleware; the 3 msg-relay
// routes use the checkApiKey guard form inside the handler.
const FLEET_MIDDLEWARE_ROUTES = [
    'POST /api/status', 'POST /api/team-register', 'POST /api/kanban-push', 'POST /api/knowledge-push',
    'POST /api/token-reports', 'GET /api/token-reports',
];
const FLEET_GUARD_ROUTES = ['POST /api/msg', 'GET /api/msg', 'POST /api/msg/ack'];

// Mutating routes that are deliberately ungated: the login/logout routes are
// unauthenticated by nature (CSRF rules + rate limit instead, contract §3.6).
const UNGATED_MUTATING_ALLOWLIST = ['POST /api/auth/login', 'POST /api/auth/logout'];

function sourceFiles() {
    const libDir = path.join(SERVER_DIR, 'lib');
    return ['server.js', ...fs.readdirSync(libDir).filter((f) => f.endsWith('.js')).map((f) => `lib/${f}`)];
}

/** Every `app.METHOD('/api...', <second arg>` registration, with the second arg's identifier. */
function deriveRegistrations() {
    const re = /app\.(get|post|put|patch|delete)\(\s*['"](\/api[^'"]*)['"]\s*,\s*([A-Za-z_$][\w$]*)?/g;
    const out = [];
    for (const file of sourceFiles()) {
        const src = fs.readFileSync(path.join(SERVER_DIR, file), 'utf8');
        let m;
        while ((m = re.exec(src)) !== null) {
            out.push({ file, method: m[1].toUpperCase(), path: m[2], gate: m[3] || null });
        }
    }
    return out;
}

describe('route inventory — every admin route is on the admin gate (static)', () => {
    const regs = deriveRegistrations();
    const key = (r) => `${r.method} ${r.path}`;

    test('exactly 19 expected admin routes, no duplicates', () => {
        assert.equal(ADMIN_ROUTES.length, 19);
        assert.equal(new Set(ADMIN_ROUTES.map(key)).size, 19);
    });

    test('the source-derived requireAdminKey set equals the 19 expected admin routes exactly', () => {
        const derived = regs.filter((r) => r.gate === 'requireAdminKey').map((r) => `${r.file} ${key(r)}`).sort();
        const expected = ADMIN_ROUTES.map((r) => `${r.file} ${key(r)}`).sort();
        assert.deepEqual(derived, expected);
    });

    for (const r of ADMIN_ROUTES) {
        test(`${r.method} ${r.path} (${r.file}) is registered with requireAdminKey, not the fleet gate`, () => {
            const hits = regs.filter((x) => x.file === r.file && key(x) === key(r));
            assert.equal(hits.length, 1, `expected exactly one registration of ${key(r)} in ${r.file}`);
            assert.equal(hits[0].gate, 'requireAdminKey', `${key(r)} is on ${hits[0].gate}, not the admin gate`);
        });
    }

    test('the requireApiKey (fleet middleware) set is exactly the 6 fleet middleware routes', () => {
        const derived = regs.filter((r) => r.gate === 'requireApiKey').map(key).sort();
        assert.deepEqual(derived, [...FLEET_MIDDLEWARE_ROUTES].sort());
    });

    test('the 3 msg-relay routes keep the checkApiKey guard (fleet tier), including the GET', () => {
        const src = fs.readFileSync(path.join(SERVER_DIR, 'lib', 'msg-relay-routes.js'), 'utf8');
        const derived = regs.filter((r) => r.file === 'lib/msg-relay-routes.js').map(key).sort();
        assert.deepEqual(derived, [...FLEET_GUARD_ROUTES].sort());
        assert.equal((src.match(/if \(!checkApiKey\(req, res\)\) return;/g) || []).length, 3);
        assert.ok(!/checkAdminKey/.test(src));
    });

    test('tier totals: 19 admin + 9 fleet = 28 guarded', () => {
        const admin = regs.filter((r) => r.gate === 'requireAdminKey').length;
        const fleet = regs.filter((r) => r.gate === 'requireApiKey').length + FLEET_GUARD_ROUTES.length;
        assert.equal(admin, 19);
        assert.equal(fleet, 9);
    });

    test('every mutating /api route in the server is gated by a tier or explicitly allowlisted', () => {
        const ungated = regs
            .filter((r) => r.method !== 'GET')
            .filter((r) => r.gate !== 'requireAdminKey' && r.gate !== 'requireApiKey')
            .filter((r) => r.file !== 'lib/msg-relay-routes.js') // guard form, asserted above
            .map(key)
            .filter((k) => !UNGATED_MUTATING_ALLOWLIST.includes(k));
        assert.deepEqual(ungated, [], `ungated mutating route(s): ${ungated.join(', ')}`);
    });

    test('CORS allowedHeaders is still pinned to Content-Type (X-Fleet-CSRF must never be approved cross-origin)', () => {
        const src = fs.readFileSync(path.join(SERVER_DIR, 'server.js'), 'utf8');
        assert.match(src, /allowedHeaders:\s*\['Content-Type'\]/);
        assert.ok(!/allowedHeaders:[^\n]*X-Fleet-CSRF/i.test(src));
    });
});

// ===========================================================================
// 5. vault + engines — real route modules, every admin route
// ===========================================================================

function concretePath(p) {
    return p.replace(/:([A-Za-z]+)/g, (_, name) => `xaca-0398-003-${name.toLowerCase()}`);
}

describe('vault + engines route modules — all 9 admin routes refuse the fleet token', () => {
    let app;
    const libRoutes = ADMIN_ROUTES.filter((r) => r.file !== 'server.js');

    before(() => {
        app = express();
        app.use(express.json({ limit: '10mb' }));
        registerVaultRoutes(app);
        registerEnginesRoutes(app);
    });
    beforeEach(() => setTokens({ fleet: FLEET_TOKEN, admin: ADMIN_TOKEN }));
    afterEach(clearTokens);

    test('9 lib admin routes enumerated', () => assert.equal(libRoutes.length, 9));

    for (const r of libRoutes) {
        const p = concretePath(r.path);
        test(`${r.method} ${r.path}: fleet token -> 401`, async () => {
            const res = await request(app)[r.method.toLowerCase()](p).set('Authorization', `Bearer ${FLEET_TOKEN}`).send({});
            assert.equal(res.status, 401, `${r.method} ${p} accepted the FLEET token — it is not on the admin gate`);
            assert.equal(res.text, EXPECTED_401_TEXT);
        });
        test(`${r.method} ${r.path}: admin token reaches the handler (not 401)`, async () => {
            const res = await request(app)[r.method.toLowerCase()](p).set('Authorization', `Bearer ${ADMIN_TOKEN}`).send({});
            assert.notEqual(res.status, 401);
        });
    }

    test('fallback: with FLEET_ADMIN_TOKEN unset, the fleet token reaches the vault handler', async () => {
        setTokens({ fleet: FLEET_TOKEN });
        const res = await request(app).post('/api/vault/machines').set('Authorization', `Bearer ${FLEET_TOKEN}`).send({});
        assert.notEqual(res.status, 401);
    });

    test('the ungated ciphertext GET is untouched here (subitem 005 owns it)', async () => {
        const res = await request(app).get('/api/vault/secrets/xaca-0398-e/xaca-0398-a/ciphertext');
        assert.notEqual(res.status, 401);
    });
});

// ===========================================================================
// 6 + 7. server.js as a real child process
// ===========================================================================

function getFreePort() {
    return new Promise((resolve, reject) => {
        const srv = net.createServer();
        srv.on('error', reject);
        srv.listen(0, '127.0.0.1', () => {
            const { port } = srv.address();
            srv.close(() => resolve(port));
        });
    });
}

/** Child env: inherit PATH etc., but never inherit auth settings from the developer's shell. */
function childEnv(overrides) {
    const env = { ...process.env };
    delete env.FLEET_AUTH_TOKEN;
    delete env.FLEET_ADMIN_TOKEN;
    delete env.FLEET_REQUIRE_AUTH;
    delete env.FLEET_VAULT_FILE;
    delete env.FLEET_ENGINES_FILE;
    return { ...env, ...overrides };
}

function spawnServer(env) {
    const child = spawn(process.execPath, ['server.js'], { cwd: SERVER_DIR, env, stdio: ['ignore', 'pipe', 'pipe'] });
    const out = { stdout: '', stderr: '' };
    child.stdout.on('data', (d) => { out.stdout += d; });
    child.stderr.on('data', (d) => { out.stderr += d; });
    return { child, out };
}

async function waitForReady(url, child, timeoutMs = 20000) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        if (child.exitCode !== null) throw new Error(`server exited early with code ${child.exitCode}`);
        try {
            const res = await fetch(`${url}/api/health`);
            if (res.ok) return;
        } catch (_) { /* not up yet */ }
        await new Promise((r) => setTimeout(r, 200));
    }
    throw new Error('server did not become ready');
}

function stopServer(child) {
    return new Promise((resolve) => {
        if (!child || child.exitCode !== null) return resolve();
        child.once('exit', resolve);
        child.kill('SIGTERM');
        setTimeout(resolve, 3000);
    });
}

describe('server.js (live) — both tokens set, FLEET_REQUIRE_AUTH=1', () => {
    let child;
    let out;
    let baseUrl;
    let host;
    const serverRoutes = ADMIN_ROUTES.filter((r) => r.file === 'server.js');

    // Concrete paths chosen so that even a REGRESSED (mis-gated) route cannot
    // touch real state: nonexistent machine/team/dashboard ids, and bodies
    // that fail validation before any write.
    const LIVE_PATHS = {
        'PUT /api/machine/:machineId/nickname': '/api/machine/xaca-0398-003-nonexistent/nickname',
        'POST /api/credentials/:integration': '/api/credentials/xaca0398nonexist',
        'DELETE /api/credentials/:integration': '/api/credentials/xaca0398nonexist',
        'PUT /api/dashboards/reorder': '/api/dashboards/reorder',
        'POST /api/dashboards': '/api/dashboards',
        'PUT /api/dashboards/:id': '/api/dashboards/xaca-0398-003-nonexistent',
        'DELETE /api/dashboards/:id': '/api/dashboards/xaca-0398-003-nonexistent',
        'POST /api/epics/:team': '/api/epics/xaca-0398-003-nonexistent-team',
        'PUT /api/epics/:team/:epicId': '/api/epics/xaca-0398-003-nonexistent-team/EPIC-0000',
        'DELETE /api/epics/:team/:epicId': '/api/epics/xaca-0398-003-nonexistent-team/EPIC-0000',
    };

    before(async () => {
        const port = await getFreePort();
        baseUrl = `http://127.0.0.1:${port}`;
        host = `127.0.0.1:${port}`;
        ({ child, out } = spawnServer(childEnv({
            PORT: String(port),
            FLEET_AUTH_TOKEN: FLEET_TOKEN,
            FLEET_ADMIN_TOKEN: ADMIN_TOKEN,
            FLEET_REQUIRE_AUTH: '1',
        })));
        await waitForReady(baseUrl, child);
    });

    after(async () => { await stopServer(child); });

    test('10 server.js admin routes enumerated, each with a live path', () => {
        assert.equal(serverRoutes.length, 10);
        for (const r of serverRoutes) assert.ok(LIVE_PATHS[`${r.method} ${r.path}`], `no live path for ${r.method} ${r.path}`);
    });

    for (const r of ADMIN_ROUTES.filter((x) => x.file === 'server.js')) {
        test(`${r.method} ${r.path}: fleet token -> 401 (admin gate, not fleet)`, async () => {
            const p = LIVE_PATHS[`${r.method} ${r.path}`];
            const res = await fetch(`${baseUrl}${p}`, {
                method: r.method,
                headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${FLEET_TOKEN}` },
                body: r.method === 'DELETE' ? undefined : JSON.stringify({}),
            });
            assert.equal(res.status, 401, `${r.method} ${p} accepted the FLEET token`);
            assert.equal(await res.text(), EXPECTED_401_TEXT);
        });
    }

    test('admin token reaches the real handler (nickname on a nonexistent machine -> 404)', async () => {
        const res = await fetch(`${baseUrl}/api/machine/xaca-0398-003-nonexistent/nickname`, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${ADMIN_TOKEN}` },
            body: JSON.stringify({ nickname: 'x' }),
        });
        assert.equal(res.status, 404);
    });

    test('browser flow end to end: login -> cookie -> admin route reaches the handler', async () => {
        const loginRes = await fetch(`${baseUrl}/api/auth/login`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', Origin: baseUrl, 'X-Fleet-CSRF': '1', 'Sec-Fetch-Site': 'same-origin' },
            body: JSON.stringify({ token: ADMIN_TOKEN }),
        });
        assert.equal(loginRes.status, 200);
        const setCookie = loginRes.headers.get('set-cookie') || '';
        const cookie = setCookie.split(';')[0];
        assert.match(cookie, /^__Host-fleet_admin=v1\./);

        const ok = await fetch(`${baseUrl}/api/machine/xaca-0398-003-nonexistent/nickname`, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json', Cookie: cookie, Origin: baseUrl, 'X-Fleet-CSRF': '1', 'Sec-Fetch-Site': 'same-origin' },
            body: JSON.stringify({ nickname: 'x' }),
        });
        assert.equal(ok.status, 404, 'cookie + CSRF should reach the handler');

        const noHeader = await fetch(`${baseUrl}/api/machine/xaca-0398-003-nonexistent/nickname`, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json', Cookie: cookie, Origin: baseUrl },
            body: JSON.stringify({ nickname: 'x' }),
        });
        assert.equal(noHeader.status, 401);

        const foreign = await fetch(`${baseUrl}/api/machine/xaca-0398-003-nonexistent/nickname`, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json', Cookie: cookie, Origin: 'https://evil.example', 'X-Fleet-CSRF': '1' },
            body: JSON.stringify({ nickname: 'x' }),
        });
        assert.equal(foreign.status, 401);

        const fleetRoute = await fetch(`${baseUrl}/api/token-reports`, {
            headers: { Cookie: cookie, Origin: baseUrl, 'X-Fleet-CSRF': '1', 'Sec-Fetch-Site': 'same-origin' },
        });
        assert.equal(fleetRoute.status, 401, 'the admin cookie must not open a fleet-tier route');
        assert.ok(host);
    });

    test('fleet token still works on a fleet-tier GET (header auth unchanged)', async () => {
        const res = await fetch(`${baseUrl}/api/token-reports`, { headers: { Authorization: `Bearer ${FLEET_TOKEN}` } });
        assert.notEqual(res.status, 401);
    });

    test('a cross-origin preflight asking for X-Fleet-CSRF is not approved', async () => {
        const res = await fetch(`${baseUrl}/api/machine/x/nickname`, {
            method: 'OPTIONS',
            headers: { Origin: 'https://evil.example', 'Access-Control-Request-Method': 'PUT', 'Access-Control-Request-Headers': 'x-fleet-csrf,content-type' },
        });
        assert.equal(res.headers.get('access-control-allow-origin'), null);
        assert.ok(!/x-fleet-csrf/i.test(res.headers.get('access-control-allow-headers') || ''));
    });

    test('startup logged one line per tier, both ACTIVE, and never a token value (contract §8 L6)', () => {
        assert.match(out.stdout, /\[fleet-monitor\] AUTH: gate ACTIVE/);
        assert.match(out.stdout, /\[fleet-monitor\] AUTH ADMIN: gate ACTIVE/);
        const all = out.stdout + out.stderr;
        assert.ok(!all.includes(FLEET_TOKEN), 'fleet token leaked into server output');
        assert.ok(!all.includes(ADMIN_TOKEN), 'admin token leaked into server output');
    });
});

describe('FLEET_REQUIRE_AUTH=1 refuses to start unless BOTH tokens resolve', () => {
    async function runExpectingExit(overrides) {
        const port = await getFreePort();
        const { child, out } = spawnServer(childEnv({ PORT: String(port), FLEET_REQUIRE_AUTH: '1', ...overrides }));
        const code = await new Promise((resolve) => {
            const t = setTimeout(() => { child.kill('SIGKILL'); resolve('timeout'); }, 20000);
            child.once('exit', (c) => { clearTimeout(t); resolve(c); });
        });
        return { code, out };
    }

    const cases = {
        'fleet only (admin absent)': { FLEET_AUTH_TOKEN: FLEET_TOKEN },
        'admin only (fleet absent)': { FLEET_ADMIN_TOKEN: ADMIN_TOKEN },
        'fleet set, admin blank': { FLEET_AUTH_TOKEN: FLEET_TOKEN, FLEET_ADMIN_TOKEN: '  ' },
        'neither': {},
    };
    for (const [name, env] of Object.entries(cases)) {
        test(`${name} -> exit 1 with a FATAL naming the missing variable, no token in output`, async () => {
            const { code, out } = await runExpectingExit(env);
            assert.equal(code, 1);
            assert.match(out.stderr, /FATAL: FLEET_REQUIRE_AUTH=1/);
            if (!env.FLEET_ADMIN_TOKEN || !env.FLEET_ADMIN_TOKEN.trim()) assert.match(out.stderr, /Missing: .*FLEET_ADMIN_TOKEN/);
            if (!env.FLEET_AUTH_TOKEN) assert.match(out.stderr, /Missing: .*FLEET_AUTH_TOKEN/);
            const all = out.stdout + out.stderr;
            assert.ok(!all.includes(FLEET_TOKEN) && !all.includes(ADMIN_TOKEN));
        });
    }
});

// ===========================================================================
// 8. logAuthStartupNotice — one line per tier
// ===========================================================================

function fakeLogger() {
    return {
        logCalls: [],
        warnCalls: [],
        log(...a) { this.logCalls.push(a.join(' ')); },
        warn(...a) { this.warnCalls.push(a.join(' ')); },
    };
}

describe('logAuthStartupNotice — one line per tier, never a value', () => {
    afterEach(clearTokens);

    const cases = [
        { name: 'both set', env: { fleet: FLEET_TOKEN, admin: ADMIN_TOKEN }, log: [/AUTH: gate ACTIVE$/, /AUTH ADMIN: gate ACTIVE$/], warn: [] },
        { name: 'fleet only (fallback)', env: { fleet: FLEET_TOKEN }, log: [/AUTH: gate ACTIVE$/], warn: [/AUTH ADMIN: sharing fleet token/] },
        { name: 'fleet set, admin blank', env: { fleet: FLEET_TOKEN, admin: ' ' }, log: [/AUTH: gate ACTIVE$/], warn: [/AUTH ADMIN: sharing fleet token .*CONFIG ERROR/] },
        { name: 'admin only', env: { admin: ADMIN_TOKEN }, log: [/AUTH ADMIN: gate ACTIVE$/], warn: [/AUTH: gate ACTIVE with the admin token only/] },
        { name: 'neither', env: {}, log: [], warn: [/AUTH: gate OPEN/, /AUTH ADMIN: gate OPEN/] },
        { name: 'admin blank, no fleet', env: { admin: '' }, log: [], warn: [/AUTH: gate OPEN/, /AUTH ADMIN CONFIG ERROR/] },
    ];
    for (const c of cases) {
        test(c.name, () => {
            setTokens(c.env);
            const logger = fakeLogger();
            auth.logAuthStartupNotice(logger);
            assert.equal(logger.logCalls.length + logger.warnCalls.length, 2, 'exactly one line per tier');
            assert.equal(logger.logCalls.length, c.log.length);
            assert.equal(logger.warnCalls.length, c.warn.length);
            c.log.forEach((re, i) => assert.match(logger.logCalls[i], re));
            c.warn.forEach((re, i) => assert.match(logger.warnCalls[i], re));
            const all = logger.logCalls.concat(logger.warnCalls).join('\n');
            assert.ok(!all.includes(FLEET_TOKEN) && !all.includes(ADMIN_TOKEN));
        });
    }
});
