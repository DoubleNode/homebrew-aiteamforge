//
//  xaca-0395-005-auth-wiring.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Wiring-proof tests for XACA-0395-005 ("fleet-monitor wiring: mount
 * middleware on server.js mutating routes + vault/engines route modules").
 *
 * auth-middleware.test.js already proves requireApiKey/checkApiKey correctly
 * reject bad credentials IN ISOLATION, against a throwaway test app that
 * mounts the middleware itself. It does NOT prove that server.js,
 * lib/vault-routes.js, and lib/engines-routes.js actually MOUNT the
 * middleware on their real routes. "Imported but never mounted" is a silent
 * no-op (kanban/plans/XACA-0395/XACA-0395_api_key_auth_mutating_routes.md
 * § "Wiring gaps found during Waves 2" — the XACA-0297 failure mode). This
 * file closes that gap by issuing real HTTP requests against the SHIPPED
 * route registrations and asserting 401 without credentials.
 *
 * Route counts (re-derived at suite-write time per contract §0 — "no count is
 * asserted from recall"; re-run these against the source, don't trust this
 * comment blindly):
 *   grep -noE "app\.(get|post|put|patch|delete)\(" server.js | sort | uniq -c
 *     -> 7 post + 4 put + 3 delete = 14 mutating routes
 *   grep -nE "^\s*app\.(get|post|put|patch|delete)\(" lib/vault-routes.js
 *     -> 6 mutating (2 post, 2 put, 2 delete); 4 GET, including the
 *        ciphertext route, deliberately left ungated (contract §6 — GET is
 *        outside this ticket's verb scope; XACA-0398 carries that gap)
 *   grep -nE "^\s*app\.(get|post|put|patch|delete)\(" lib/engines-routes.js
 *     -> 3 mutating (1 post, 1 put, 1 delete); 2 GET left ungated
 *
 * Sections:
 *   1. vault-routes.js  — mounts the REAL registerVaultRoutes() (same pattern
 *      as vault-routes.test.js: isolated FLEET_VAULT_FILE/FLEET_ENGINES_FILE
 *      temp paths, no real data touched).
 *   2. engines-routes.js — mounts the REAL registerEnginesRoutes().
 *   3. server.js — spawns the REAL server.js as a child process (isolated to
 *      THIS worktree's own fleet-monitor/server/data/, never the live
 *      machine's production fleet-monitor instance, because __dirname
 *      resolves inside the worktree checkout) and issues real HTTP requests.
 *      This is the only way to prove server.js's routes are gated: unlike
 *      vault/engines, server.js has no exported route-registration function
 *      and no env-var-based data-file isolation seam, so app-factory.js
 *      (used by fleet-routes.test.js etc.) is a hand-maintained
 *      reimplementation, not the shipped code — mounting requireApiKey there
 *      would prove nothing about server.js itself.
 */

const { test, describe, before, after } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const express = require('express');
const path = require('path');
const os = require('os');
const fs = require('fs');
const { spawn } = require('child_process');
const net = require('net');

const TEST_TOKEN = 'test-api-key-not-a-real-secret';

// ---------------------------------------------------------------------------
// Section 1 + 2: vault + engines — isolate BEFORE requiring the stores.
// ---------------------------------------------------------------------------

const TEST_VAULT_FILE = path.join(os.tmpdir(), `auth-wiring-vault-${process.pid}-${Date.now()}.json`);
const TEST_ENGINES_FILE = path.join(os.tmpdir(), `auth-wiring-engines-${process.pid}-${Date.now()}.json`);
process.env.FLEET_VAULT_FILE = TEST_VAULT_FILE;
process.env.FLEET_ENGINES_FILE = TEST_ENGINES_FILE;

const { registerVaultRoutes } = require('../lib/vault-routes');
const { registerEnginesRoutes } = require('../lib/engines-routes');

function buildVaultApp() {
    const app = express();
    app.use(express.json({ limit: '10mb' }));
    registerVaultRoutes(app);
    return app;
}

function buildEnginesApp() {
    const app = express();
    app.use(express.json({ limit: '1mb' }));
    registerEnginesRoutes(app);
    return app;
}

describe('vault-routes.js — requireApiKey actually mounted (not just imported)', () => {
    let app;
    const EXPECTED_401_BODY = { error: 'Unauthorized', code: 'unauthorized' };

    before(() => {
        process.env.FLEET_AUTH_TOKEN = TEST_TOKEN;
        app = buildVaultApp();
    });

    after(() => {
        delete process.env.FLEET_AUTH_TOKEN;
        try { fs.unlinkSync(TEST_VAULT_FILE); } catch (_) { /* noop */ }
        try { fs.unlinkSync(TEST_ENGINES_FILE); } catch (_) { /* noop */ }
    });

    const MUTATING_ROUTES = [
        { method: 'post',   path: '/api/vault/machines' },
        { method: 'put',    path: '/api/vault/machines/dummy-id' },
        { method: 'delete', path: '/api/vault/machines/dummy-id' },
        { method: 'post',   path: '/api/vault/secrets' },
        { method: 'put',    path: '/api/vault/secrets/dummy-engine/dummy-account' },
        { method: 'delete', path: '/api/vault/secrets/dummy-engine/dummy-account' },
    ];

    test('re-derived count matches this test list (6 mutating routes)', () => {
        assert.equal(MUTATING_ROUTES.length, 6);
    });

    for (const { method, path: routePath } of MUTATING_ROUTES) {
        test(`${method.toUpperCase()} ${routePath} rejects an unauthenticated request with 401`, async () => {
            const res = await request(app)[method](routePath).send({});
            assert.equal(res.status, 401, `expected 401, got ${res.status} (body: ${JSON.stringify(res.body)})`);
            assert.deepEqual(res.body, EXPECTED_401_BODY);
        });
    }

    test('the same POST /api/vault/machines with a valid credential is NOT 401 (mount does not misfire on real callers)', async () => {
        const res = await request(app)
            .post('/api/vault/machines')
            .set('Authorization', `Bearer ${TEST_TOKEN}`)
            .send({}); // will fail validation downstream — the point is it's not 401
        assert.notEqual(res.status, 401);
    });

    test('GET /api/vault/secrets/:engineSlug/:accountSlug/ciphertext stays UNGATED — known, accepted gap (contract §6, carried to XACA-0398)', async () => {
        const res = await request(app).get('/api/vault/secrets/dummy-engine/dummy-account/ciphertext');
        assert.notEqual(res.status, 401, 'ciphertext GET must remain reachable without auth — this is a documented gap, not a regression to fix here');
    });

    test('GET /api/vault/machines stays UNGATED (read routes are out of this ticket verb scope)', async () => {
        const res = await request(app).get('/api/vault/machines');
        assert.notEqual(res.status, 401);
    });
});

describe('engines-routes.js — requireApiKey actually mounted (not just imported)', () => {
    let app;
    const EXPECTED_401_BODY = { error: 'Unauthorized', code: 'unauthorized' };

    before(() => {
        process.env.FLEET_AUTH_TOKEN = TEST_TOKEN;
        app = buildEnginesApp();
    });

    after(() => {
        delete process.env.FLEET_AUTH_TOKEN;
    });

    const MUTATING_ROUTES = [
        { method: 'post',   path: '/api/engines/dummy-engine/accounts' },
        { method: 'put',    path: '/api/engines/dummy-engine/accounts/dummy-account' },
        { method: 'delete', path: '/api/engines/dummy-engine/accounts/dummy-account' },
    ];

    test('re-derived count matches this test list (3 mutating routes)', () => {
        assert.equal(MUTATING_ROUTES.length, 3);
    });

    for (const { method, path: routePath } of MUTATING_ROUTES) {
        test(`${method.toUpperCase()} ${routePath} rejects an unauthenticated request with 401`, async () => {
            const res = await request(app)[method](routePath).send({});
            assert.equal(res.status, 401, `expected 401, got ${res.status} (body: ${JSON.stringify(res.body)})`);
            assert.deepEqual(res.body, EXPECTED_401_BODY);
        });
    }

    test('GET /api/engines stays UNGATED', async () => {
        const res = await request(app).get('/api/engines');
        assert.notEqual(res.status, 401);
    });
});

// ---------------------------------------------------------------------------
// Section 3: server.js — real child process, real HTTP, real mount.
// ---------------------------------------------------------------------------

describe('server.js — requireApiKey actually mounted on all 14 mutating routes (live server)', () => {
    const STARTUP_TIMEOUT_MS = 20000;
    const POLL_INTERVAL_MS = 200;
    const SERVER_DIR = path.join(__dirname, '..');

    let child;
    let baseUrl;

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
                FLEET_AUTH_TOKEN: TEST_TOKEN,
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
            setTimeout(resolve, 3000); // don't hang the suite if it's stubborn
        });
    });

    // The 14 mutating routes from server.js, re-derived at suite-write time
    // (contract §0 grounding rule — do not trust this list without re-running
    // the grep in the file-header comment above).
    const MUTATING_ROUTES = [
        { method: 'POST', path: '/api/status' },
        { method: 'POST', path: '/api/team-register' },
        { method: 'POST', path: '/api/kanban-push' },
        { method: 'POST', path: '/api/knowledge-push' },
        { method: 'POST', path: '/api/credentials/anthropic' },
        { method: 'POST', path: '/api/dashboards' },
        { method: 'POST', path: '/api/epics/academy' },
        { method: 'PUT', path: '/api/dashboards/reorder' },
        { method: 'PUT', path: '/api/dashboards/dummy-id' },
        { method: 'PUT', path: '/api/epics/academy/dummy-epic' },
        { method: 'PUT', path: '/api/machine/dummy-machine/nickname' },
        { method: 'DELETE', path: '/api/credentials/anthropic' },
        { method: 'DELETE', path: '/api/dashboards/dummy-id' },
        { method: 'DELETE', path: '/api/epics/academy/dummy-epic' },
    ];

    test('re-derived count matches this test list (14 mutating routes: 7 post, 4 put, 3 delete)', () => {
        assert.equal(MUTATING_ROUTES.length, 14);
        assert.equal(MUTATING_ROUTES.filter((r) => r.method === 'POST').length, 7);
        assert.equal(MUTATING_ROUTES.filter((r) => r.method === 'PUT').length, 4);
        assert.equal(MUTATING_ROUTES.filter((r) => r.method === 'DELETE').length, 3);
    });

    for (const { method, path: routePath } of MUTATING_ROUTES) {
        test(`${method} ${routePath} rejects an unauthenticated request with 401 (contract §4 body)`, async () => {
            const res = await fetch(`${baseUrl}${routePath}`, {
                method,
                headers: { 'Content-Type': 'application/json' },
                body: method === 'DELETE' ? undefined : JSON.stringify({}),
            });
            assert.equal(res.status, 401, `${method} ${routePath} should be 401 without credentials, got ${res.status}`);
            const body = await res.json();
            assert.deepEqual(body, { error: 'Unauthorized', code: 'unauthorized' }, `${method} ${routePath} 401 body must match contract §4`);
        });
    }

    test('a valid credential clears the gate (goes past 401 into the real handler)', async () => {
        const res = await fetch(`${baseUrl}/api/machine/xaca-0395-005-nonexistent-machine/nickname`, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${TEST_TOKEN}` },
            body: JSON.stringify({ nickname: 'wiring-test' }),
        });
        // Machine doesn't exist -> the REAL handler returns 404, proving the
        // request reached the handler rather than being 401'd.
        assert.equal(res.status, 404);
    });

    test('GET /api/health remains unauthenticated (out of this ticket verb scope)', async () => {
        const res = await fetch(`${baseUrl}/api/health`);
        assert.equal(res.status, 200);
    });

    test('OPTIONS preflight succeeds without credentials (contract §6 allowlist A)', async () => {
        const res = await fetch(`${baseUrl}/api/dashboards`, { method: 'OPTIONS' });
        assert.ok(res.status < 400, `OPTIONS preflight must not require auth, got ${res.status}`);
    });
});
