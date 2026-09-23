//
//  xaca-0398-006-login-rate-limit-key.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-0398-006 — the login rate limiter keys on the REAL client address.
 *
 * Defect: lib/auth-routes.js keyed failed-login buckets on req.ip. `trust
 * proxy` is unset, so on Fly req.ip is the edge proxy for EVERY request —
 * one shared bucket, and one attacker's 10 bad guesses locked the operator
 * out for 15 minutes.
 *
 * Fix: resolveLoginClientKey() uses the Fly-Client-IP header, but ONLY when
 * FLY_APP_NAME is set (Fly's proxy overwrites that header; nowhere else does
 * anything vouch for it). These tests prove:
 *   1. on Fly, two clients get independent buckets (the lockout is gone);
 *   2. off Fly, a client-supplied Fly-Client-IP is ignored, so rotating it
 *      does NOT escape the limiter (the anti-spoofing half);
 *   3. on Fly, a malformed header falls back to the peer bucket rather than
 *      minting a fresh bucket per request;
 *   4. `trust proxy` stays unset and the session cookie stays `Secure`
 *      regardless of transport — the fix changed nothing else.
 */

const { test, describe, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const express = require('express');
const fs = require('fs');
const path = require('path');

const { registerAuthRoutes, createLoginLimiter, resolveLoginClientKey } = require('../lib/auth-routes');

const ADMIN_TOKEN = 'test-admin-token-not-a-real-secret';
const WRONG_TOKEN = 'test-wrong-token-not-a-real-secret';
const HOST = 'fleet-monitor.test';
const ORIGIN = `https://${HOST}`;

const SAVED = {
    FLY_APP_NAME: process.env.FLY_APP_NAME,
    FLEET_AUTH_TOKEN: process.env.FLEET_AUTH_TOKEN,
    FLEET_ADMIN_TOKEN: process.env.FLEET_ADMIN_TOKEN,
};

function restoreVar(name) {
    if (SAVED[name] === undefined) delete process.env[name];
    else process.env[name] = SAVED[name];
}

function buildApp() {
    const app = express();
    app.use(express.json());
    registerAuthRoutes(app, { limiter: createLoginLimiter({ maxFailures: 10, windowMs: 60000 }) });
    return app;
}

function login(app, token, flyClientIp) {
    const r = request(app).post('/api/auth/login')
        .set('Host', HOST)
        .set('Origin', ORIGIN)
        .set('X-Fleet-CSRF', '1')
        .set('Sec-Fetch-Site', 'same-origin');
    if (flyClientIp !== undefined) r.set('Fly-Client-IP', flyClientIp);
    return r.send({ token });
}

function fakeReq(headers, remoteAddress = '10.0.0.1') {
    const lower = {};
    for (const [k, v] of Object.entries(headers)) lower[k.toLowerCase()] = v;
    return { headers: lower, socket: { remoteAddress }, get: (n) => lower[n.toLowerCase()] };
}

describe('resolveLoginClientKey (unit)', () => {
    test('off Fly: a client-supplied Fly-Client-IP is ignored -> TCP peer', () => {
        assert.equal(resolveLoginClientKey(fakeReq({ 'Fly-Client-IP': '203.0.113.9' }), {}), '10.0.0.1');
    });

    test('off Fly: FLY_APP_NAME empty string counts as off Fly', () => {
        assert.equal(resolveLoginClientKey(fakeReq({ 'Fly-Client-IP': '203.0.113.9' }), { FLY_APP_NAME: '' }), '10.0.0.1');
    });

    test('on Fly: a valid IPv4 header is the key', () => {
        assert.equal(resolveLoginClientKey(fakeReq({ 'Fly-Client-IP': '203.0.113.9' }), { FLY_APP_NAME: 'fleet-monitor' }), '203.0.113.9');
    });

    test('on Fly: a valid IPv6 header is the key (surrounding whitespace tolerated)', () => {
        assert.equal(resolveLoginClientKey(fakeReq({ 'Fly-Client-IP': ' 2001:db8::7 ' }), { FLY_APP_NAME: 'fleet-monitor' }), '2001:db8::7');
    });

    test('on Fly: malformed / duplicate-joined / empty header -> TCP peer, never the raw string', () => {
        for (const bad of ['203.0.113.9, 198.51.100.1', 'evil', '', '999.1.1.1', '1.2.3.4:5678']) {
            assert.equal(
                resolveLoginClientKey(fakeReq({ 'Fly-Client-IP': bad }), { FLY_APP_NAME: 'fleet-monitor' }),
                '10.0.0.1',
                `header ${JSON.stringify(bad)}`,
            );
        }
    });

    test('on Fly: header absent -> TCP peer', () => {
        assert.equal(resolveLoginClientKey(fakeReq({}), { FLY_APP_NAME: 'fleet-monitor' }), '10.0.0.1');
    });
});

describe('login limiter end-to-end', () => {
    beforeEach(() => {
        process.env.FLEET_AUTH_TOKEN = 'test-fleet-token-not-a-real-secret';
        process.env.FLEET_ADMIN_TOKEN = ADMIN_TOKEN;
    });
    afterEach(() => {
        restoreVar('FLY_APP_NAME');
        restoreVar('FLEET_AUTH_TOKEN');
        restoreVar('FLEET_ADMIN_TOKEN');
    });

    test('on Fly: an attacker exhausting its bucket does NOT lock out the operator', async () => {
        process.env.FLY_APP_NAME = 'fleet-monitor';
        const app = buildApp();
        for (let i = 0; i < 10; i++) {
            assert.equal((await login(app, WRONG_TOKEN, '203.0.113.9')).status, 401);
        }
        assert.equal((await login(app, WRONG_TOKEN, '203.0.113.9')).status, 429, 'attacker is limited');
        const operator = await login(app, ADMIN_TOKEN, '198.51.100.7');
        assert.equal(operator.status, 200, 'operator from a different client address still logs in');
    });

    test('off Fly: rotating Fly-Client-IP per request does NOT escape the limiter', async () => {
        delete process.env.FLY_APP_NAME;
        const app = buildApp();
        for (let i = 0; i < 10; i++) {
            assert.equal((await login(app, WRONG_TOKEN, `203.0.113.${i + 1}`)).status, 401);
        }
        const blocked = await login(app, ADMIN_TOKEN, '198.51.100.7');
        assert.equal(blocked.status, 429, 'the spoofed header was ignored; all attempts share the peer bucket');
    });

    test('on Fly: rotating MALFORMED header values stays in one bucket', async () => {
        process.env.FLY_APP_NAME = 'fleet-monitor';
        const app = buildApp();
        for (let i = 0; i < 10; i++) {
            assert.equal((await login(app, WRONG_TOKEN, `not-an-ip-${i}`)).status, 401);
        }
        assert.equal((await login(app, ADMIN_TOKEN, 'not-an-ip-final')).status, 429);
    });

    test('the session cookie is still Secure over plain HTTP (no trust-proxy dependence)', async () => {
        process.env.FLY_APP_NAME = 'fleet-monitor';
        const res = await login(buildApp(), ADMIN_TOKEN, '198.51.100.7');
        assert.equal(res.status, 200);
        const line = (res.headers['set-cookie'] || []).find((c) => c.startsWith('__Host-fleet_admin='));
        assert.ok(line, 'cookie issued');
        assert.match(line, /;\s*Secure(;|$)/);
    });
});

// Comments are stripped first: auth-routes.js documents WHY it does not call
// app.set('trust proxy', ...), and that prose must not trip the guard.
function codeOnly(src) {
    return src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');
}

describe('scope guard: the fix did not turn on trust proxy', () => {
    test("server.js never calls app.set('trust proxy', ...)", () => {
        const src = codeOnly(fs.readFileSync(path.join(__dirname, '..', 'server.js'), 'utf8'));
        assert.doesNotMatch(src, /\.set\(\s*['"]trust proxy['"]/);
        assert.doesNotMatch(src, /\.enable\(\s*['"]trust proxy['"]/);
    });

    test('lib/ never sets trust proxy either', () => {
        const dir = path.join(__dirname, '..', 'lib');
        for (const f of fs.readdirSync(dir).filter((n) => n.endsWith('.js'))) {
            const src = codeOnly(fs.readFileSync(path.join(dir, f), 'utf8'));
            assert.doesNotMatch(src, /\.(set|enable)\(\s*['"]trust proxy['"]/, f);
        }
    });
});
