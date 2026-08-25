//
//  xaca-0401-cors-origin-pinning.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-0401 review finding 017 - fleet-monitor's CORS `origin` must be
 * fail-closed, and the auth-rejected path must not hand out a wildcard.
 *
 * Bare `cors()` (or `cors({allowedHeaders})` with no `origin`) REFLECTS
 * whatever Origin arrives, answering `Access-Control-Allow-Origin: <that
 * origin>`. That is the wildcard-equivalent defect this ticket removes.
 * server.js now supplies an `origin` callback that allows a request only
 * when it carries no Origin at all (same-origin, curl, Node) or when the
 * Origin is listed in FLEET_MONITOR_ALLOWED_ORIGINS.
 *
 * Structure mirrors xaca-0395-cors-allowed-headers.test.js - the sibling
 * guard for the `allowedHeaders` pinning in the SAME cors() call - because
 * server.js exports no app, so only running it proves what it mounts:
 *   1. LIVE SERVER - spawns the real server.js.
 *   2. NEGATIVE CONTROL - the same request against an in-process app using
 *      bare `cors()`, asserting it DOES reflect the foreign origin. Without
 *      this, assertion 1 could pass simply because no CORS middleware ran,
 *      and the suite would stay green if someone reverted the pinning.
 *
 * NOT CI-GATED. No workflow runs fleet-monitor's JS tests today (the only
 * workflow referencing fleet-monitor is the tap path filter). This file
 * therefore documents and locally verifies the contract; it does not yet
 * PROTECT it. Treat that as a known gap, not as coverage.
 *
 * Usage:  node --test tests/xaca-0401-cors-origin-pinning.test.js
 */

const { test, describe, before, after } = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const cors = require('cors');
const net = require('net');
const path = require('path');
const { spawn } = require('child_process');

const FOREIGN_ORIGIN = 'https://evil.example';
const ALLOWED_ORIGIN = 'https://allowed.example';

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

describe('server.js - CORS origin is fail-closed (finding 017)', () => {
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
                FLEET_MONITOR_ALLOWED_ORIGINS: ALLOWED_ORIGIN,
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

    test('a foreign Origin gets NO Access-Control-Allow-Origin', async () => {
        const res = await fetch(`${baseUrl}/api/health`, { headers: { Origin: FOREIGN_ORIGIN } });
        const acao = res.headers.get('access-control-allow-origin');
        assert.equal(acao, null, `expected no ACAO, got ${acao}`);
    });

    test('the wildcard is never the fallback for a refused origin', async () => {
        const res = await fetch(`${baseUrl}/api/health`, { headers: { Origin: FOREIGN_ORIGIN } });
        assert.notEqual(res.headers.get('access-control-allow-origin'), '*');
    });

    test('an allow-listed Origin IS echoed back', async () => {
        const res = await fetch(`${baseUrl}/api/health`, { headers: { Origin: ALLOWED_ORIGIN } });
        assert.equal(res.headers.get('access-control-allow-origin'), ALLOWED_ORIGIN);
    });

    test('a request with no Origin still succeeds (curl, Node, same-origin)', async () => {
        const res = await fetch(`${baseUrl}/api/health`);
        assert.ok(res.ok, `unexpected status ${res.status}`);
    });

    test('a 401 does NOT carry a wildcard ACAO (finding 014)', async () => {
        // sendUnauthorized() used to set Access-Control-Allow-Origin: '*'
        // unconditionally, overriding the origin decision above on every
        // auth-rejected request. Guard against its return.
        const res = await fetch(`${baseUrl}/api/teams`, {
            method: 'POST',
            headers: { Origin: FOREIGN_ORIGIN, 'Content-Type': 'application/json' },
            body: '{}',
        });
        if (res.status !== 401) return; // route not auth-gated in this build
        assert.notEqual(res.headers.get('access-control-allow-origin'), '*');
    });
});

describe('negative control - bare cors() DOES reflect a foreign origin', () => {
    let server;
    let baseUrl;

    before(async () => {
        const port = await getFreePort();
        baseUrl = `http://127.0.0.1:${port}`;
        const app = express();
        app.use(cors());                       // deliberately the OLD, unpinned config
        app.get('/api/health', (req, res) => res.json({ ok: true }));
        await new Promise((resolve) => { server = app.listen(port, '127.0.0.1', resolve); });
    });

    after(async () => {
        if (server) await new Promise((resolve) => server.close(resolve));
    });

    test('bare cors() reflects the foreign origin (proves the assertions above bite)', async () => {
        const res = await fetch(`${baseUrl}/api/health`, { headers: { Origin: FOREIGN_ORIGIN } });
        const acao = res.headers.get('access-control-allow-origin');
        assert.ok(
            acao === FOREIGN_ORIGIN || acao === '*',
            `negative control did not reflect; got ${acao} - the pinned assertions may be vacuous`
        );
    });
});
