//
//  xaca-0395-cors-allowed-headers.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-0395 review finding 019 — fleet-monitor's CORS must not approve a
 * cross-origin preflight that asks for `Authorization`.
 *
 * Bare `cors()` REFLECTS whatever arrives in Access-Control-Request-Headers.
 * A hostile page could therefore preflight `Authorization`, be told yes, and
 * send a credentialed cross-origin mutation. This is the twin of the LCARS
 * do_OPTIONS widening reverted earlier in this ticket (see
 * tests/test_xaca0395_auth_gate.py ::
 * test_options_allow_headers_excludes_auth_headers); server.js now pins
 * `allowedHeaders: ['Content-Type']` for parity.
 *
 * Two halves, and the second is the point:
 *   1. LIVE SERVER — spawns the REAL server.js (the shipped wiring, not a
 *      hand-rolled app-factory reimplementation) and issues a real preflight.
 *      Same spawn pattern as xaca-0395-005-auth-wiring.test.js, and for the
 *      same reason: server.js exports no app, so nothing short of running it
 *      proves what it actually mounts.
 *   2. NEGATIVE CONTROL — the identical preflight against an in-process app
 *      using BARE `cors()`, asserting it DOES reflect Authorization. Without
 *      this, assertion 1 could be passing because the preflight never
 *      reached any CORS middleware at all, and the suite would stay green if
 *      someone reverted server.js to `app.use(cors())`.
 *
 * Usage:  node --test tests/xaca-0395-cors-allowed-headers.test.js
 */

const { test, describe, before, after } = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const cors = require('cors');
const net = require('net');
const path = require('path');
const { spawn } = require('child_process');

const FOREIGN_ORIGIN = 'https://evil.example';

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

/** The exact request a hostile page's credentialed cross-origin mutation preflights with. */
function preflightAuthorization(baseUrl, routePath) {
    return fetch(`${baseUrl}${routePath}`, {
        method: 'OPTIONS',
        headers: {
            Origin: FOREIGN_ORIGIN,
            'Access-Control-Request-Method': 'POST',
            'Access-Control-Request-Headers': 'authorization',
        },
    });
}

describe('server.js — CORS preflight refuses to approve Authorization (finding 019)', () => {
    const STARTUP_TIMEOUT_MS = 20000;
    const POLL_INTERVAL_MS = 200;
    const SERVER_DIR = path.join(__dirname, '..');

    let child;
    let baseUrl;

    async function waitForReady(url, timeoutMs) {
        const deadline = Date.now() + timeoutMs;
        let lastErr;
        while (Date.now() < deadline) {
            try {
                const res = await fetch(`${url}/api/health`);
                if (res.ok) return;
            } catch (err) {
                lastErr = err;
            }
            await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
        }
        throw new Error(`server did not become ready within ${timeoutMs}ms: ${lastErr}`);
    }

    before(async () => {
        const port = await getFreePort();
        baseUrl = `http://127.0.0.1:${port}`;
        child = spawn(process.execPath, ['server.js'], {
            cwd: SERVER_DIR,
            env: {
                ...process.env,
                PORT: String(port),
                FLEET_AUTH_TOKEN: 'test-fleet-token-not-a-real-secret',
            },
            stdio: ['ignore', 'ignore', 'ignore'],
        });
        await waitForReady(baseUrl, STARTUP_TIMEOUT_MS);
    });

    after(async () => {
        if (!child) return;
        await new Promise((resolve) => {
            child.once('exit', resolve);
            child.kill('SIGTERM');
            setTimeout(resolve, 3000);
        });
    });

    test('preflight asking for Authorization is answered with Content-Type only', async () => {
        const res = await preflightAuthorization(baseUrl, '/api/status');
        const allowHeaders = res.headers.get('access-control-allow-headers');

        assert.equal(allowHeaders, 'Content-Type');
        assert.ok(
            !/authorization/i.test(allowHeaders || ''),
            'Authorization must never be reflected back as an allowed header'
        );
    });

    test('preflight asking for X-API-Key is likewise not reflected', async () => {
        // The gate accepts X-API-Key as an alternative credential header
        // (contract §3), so it must not become a cross-origin loophole either.
        const res = await fetch(`${baseUrl}/api/status`, {
            method: 'OPTIONS',
            headers: {
                Origin: FOREIGN_ORIGIN,
                'Access-Control-Request-Method': 'POST',
                'Access-Control-Request-Headers': 'x-api-key',
            },
        });
        const allowHeaders = res.headers.get('access-control-allow-headers');

        assert.equal(allowHeaders, 'Content-Type');
    });

    test('ordinary Content-Type preflight is still approved (nothing legitimate broke)', async () => {
        const res = await fetch(`${baseUrl}/api/status`, {
            method: 'OPTIONS',
            headers: {
                Origin: FOREIGN_ORIGIN,
                'Access-Control-Request-Method': 'POST',
                'Access-Control-Request-Headers': 'content-type',
            },
        });

        assert.ok(res.status === 200 || res.status === 204, `unexpected status ${res.status}`);
        assert.equal(res.headers.get('access-control-allow-headers'), 'Content-Type');
    });
});

describe('negative control — bare cors() DOES reflect Authorization', () => {
    let server;
    let baseUrl;

    before(async () => {
        const port = await getFreePort();
        baseUrl = `http://127.0.0.1:${port}`;
        const app = express();
        app.use(cors());                       // deliberately the OLD, unpinned config
        app.post('/api/status', (req, res) => res.json({ ok: true }));
        await new Promise((resolve) => { server = app.listen(port, '127.0.0.1', resolve); });
    });

    after(async () => {
        if (server) await new Promise((resolve) => server.close(resolve));
    });

    test('reflection is real, so the assertions above are not vacuous', async () => {
        const res = await preflightAuthorization(baseUrl, '/api/status');
        const allowHeaders = res.headers.get('access-control-allow-headers');

        assert.ok(
            /authorization/i.test(allowHeaders || ''),
            'bare cors() was expected to reflect Authorization — if it no longer does, ' +
            'the live-server assertions above stop proving anything and this suite needs rethinking'
        );
    });
});
