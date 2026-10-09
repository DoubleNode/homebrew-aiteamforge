//
//  xaca-1441-github-app.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1441-002 -- lib/ci-dispatch-github.js against a stubbed fetch. NO network.
 * The RSA key is generated at runtime; nothing key-shaped is committed.
 */

const crypto = require('crypto');
const { test, describe } = require('node:test');
const assert = require('node:assert/strict');

const {
    createGithubClient, GithubError, TOKEN_REFRESH_MARGIN_MS, JWT_BACKDATE_S, JWT_LIFETIME_S,
} = require('../lib/ci-dispatch-github');

const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', {
    modulusLength: 2048,
    publicKeyEncoding: { type: 'spki', format: 'pem' },
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
});

const T0 = Date.UTC(2026, 9, 6, 12, 0, 0);
const APP_ID = '424242';
const KEY_BODY = privateKey.split('\n').filter((l) => l && !l.startsWith('-----'))[0];

function res(status, body, headers = {}) {
    const h = new Map(Object.entries(headers).map(([k, v]) => [k.toLowerCase(), String(v)]));
    return {
        status,
        headers: { get: (n) => (h.has(n.toLowerCase()) ? h.get(n.toLowerCase()) : null) },
        json: async () => { if (body === undefined) throw new Error('no body'); return body; },
    };
}

const rl = (remaining, limit = 5000, reset = (T0 / 1000) + 3600) => ({
    'x-ratelimit-remaining': remaining, 'x-ratelimit-limit': limit, 'x-ratelimit-reset': reset,
});

let activeClock = { t: T0 }; // the most recently built harness's clock (authRoutes reads it lazily)

/** Harness: scripted fetch + manual clock. routes: array of [matcher, handler]. */
function harness({ config, routes = [] } = {}) {
    const calls = [];
    const clock = { t: T0 };
    activeClock = clock;
    const fetchStub = async (url, init) => {
        const u = new URL(url);
        const call = {
            method: init.method, path: u.pathname + u.search, headers: init.headers,
            body: init.body ? JSON.parse(init.body) : undefined,
        };
        calls.push(call);
        for (const [match, handler] of routes) {
            if (match(call)) return handler(call);
        }
        throw new Error(`unrouted ${call.method} ${call.path}`);
    };
    const degraded = [];
    const client = createGithubClient({
        config: config || { GITHUB_APP_ID: APP_ID, GITHUB_APP_PRIVATE_KEY: privateKey },
        fetch: fetchStub,
        now: () => clock.t,
        onDegraded: (e) => degraded.push(e),
    });
    return { client, calls, clock, degraded };
}

const isInstall = (c) => c.method === 'GET' && /\/installation$/.test(c.path);
const isTokenMint = (c) => c.method === 'POST' && /\/access_tokens$/.test(c.path);
const expiresIn = (ms) => new Date(activeClock.t + ms).toISOString();

/** Standard install + token routes; tokens are numbered so refreshes are visible. */
function authRoutes({ ttlMs = 60 * 60 * 1000 } = {}) {
    let n = 0;
    return [
        [isInstall, () => res(200, { id: 777 }, rl(4999))],
        [isTokenMint, () => res(201, { token: `ghs_tok${++n}`, expires_at: expiresIn(ttlMs) }, rl(4998))],
    ];
}

function verifyJwt(jwt, nowMs) {
    const [h, c, s] = jwt.split('.');
    const header = JSON.parse(Buffer.from(h, 'base64url'));
    const claims = JSON.parse(Buffer.from(c, 'base64url'));
    const ok = crypto.createVerify('RSA-SHA256').update(`${h}.${c}`).verify(publicKey, Buffer.from(s, 'base64url'));
    return { header, claims, ok, nowS: Math.floor(nowMs / 1000) };
}

describe('App JWT', () => {
    test('RS256, iat = now-60s, exp <= now+9min, iss = App ID, signature verifies', async () => {
        const routes = authRoutes();
        const h = harness({ routes });
        h.clock.t = T0;
        await h.client.getToken({ owner: 'o', repo: 'r', purpose: 'watcher' });
        const installCall = h.calls.find(isInstall);
        const jwt = installCall.headers.Authorization.replace('Bearer ', '');
        const v = verifyJwt(jwt, T0);
        assert.deepEqual(v.header, { alg: 'RS256', typ: 'JWT' });
        assert.equal(v.claims.iat, v.nowS - JWT_BACKDATE_S);
        assert.ok(v.claims.exp <= v.nowS + 9 * 60);
        assert.equal(v.claims.exp, v.nowS + JWT_LIFETIME_S);
        assert.equal(v.claims.iss, APP_ID);
        assert.equal(v.ok, true);
        // The access-token mint is also authenticated with an App JWT, not the installation token.
        const mint = h.calls.find(isTokenMint);
        assert.equal(verifyJwt(mint.headers.Authorization.replace('Bearer ', ''), T0).ok, true);
    });

    test('PEM with literal \\n sequences (secret-store paste) still signs', async () => {
        const routes = authRoutes();
        const h2 = harness({ config: { GITHUB_APP_ID: APP_ID, GITHUB_APP_PRIVATE_KEY: privateKey.replace(/\n/g, '\\n') }, routes });
        await h2.client.getToken({ owner: 'o', repo: 'r', purpose: 'watcher' });
        const jwt = h2.calls[0].headers.Authorization.replace('Bearer ', '');
        assert.equal(verifyJwt(jwt, T0).ok, true);
    });

    test('missing credentials -> NOT_CONFIGURED, no fetch', async () => {
        const h = harness({ config: {} });
        await assert.rejects(() => h.client.getToken({ owner: 'o', repo: 'r', purpose: 'watcher' }),
            (e) => e instanceof GithubError && e.code === 'NOT_CONFIGURED');
        assert.equal(h.calls.length, 0);
    });

    test('iss = Client ID when both Client ID and App ID are set', async () => {
        const h = harness({ config: { GITHUB_APP_CLIENT_ID: 'Iv23liTESTCLIENT', GITHUB_APP_ID: APP_ID, GITHUB_APP_PRIVATE_KEY: privateKey }, routes: authRoutes() });
        await h.client.getToken({ owner: 'o', repo: 'r', purpose: 'watcher' });
        const v = verifyJwt(h.calls.find(isInstall).headers.Authorization.replace('Bearer ', ''), T0);
        assert.equal(v.claims.iss, 'Iv23liTESTCLIENT');
        assert.equal(v.ok, true);
    });

    test('iss = App ID when only App ID is set (numeric config value too)', async () => {
        const h = harness({ config: { GITHUB_APP_ID: 424242, GITHUB_APP_PRIVATE_KEY: privateKey }, routes: authRoutes() });
        await h.client.getToken({ owner: 'o', repo: 'r', purpose: 'watcher' });
        const v = verifyJwt(h.calls.find(isInstall).headers.Authorization.replace('Bearer ', ''), T0);
        assert.equal(v.claims.iss, '424242');
    });

    test('blank Client ID falls back to App ID', async () => {
        const h = harness({ config: { GITHUB_APP_CLIENT_ID: '  ', GITHUB_APP_ID: APP_ID, GITHUB_APP_PRIVATE_KEY: privateKey }, routes: authRoutes() });
        await h.client.getToken({ owner: 'o', repo: 'r', purpose: 'watcher' });
        const v = verifyJwt(h.calls.find(isInstall).headers.Authorization.replace('Bearer ', ''), T0);
        assert.equal(v.claims.iss, APP_ID);
    });

    test('neither Client ID nor App ID -> NOT_CONFIGURED naming both, no fetch, no key echo', async () => {
        const h = harness({ config: { GITHUB_APP_PRIVATE_KEY: 'SENTINEL-KEY-BODY' } });
        await assert.rejects(() => h.client.getToken({ owner: 'o', repo: 'r', purpose: 'watcher' }),
            (e) => e.code === 'NOT_CONFIGURED' && /GITHUB_APP_CLIENT_ID/.test(e.message)
                && /GITHUB_APP_ID/.test(e.message) && !e.message.includes('SENTINEL-KEY-BODY'));
        assert.equal(h.calls.length, 0);
    });

    test('malformed issuer is rejected without echoing it', async () => {
        const h = harness({ config: { GITHUB_APP_CLIENT_ID: 'bad id SENTINEL-ISS', GITHUB_APP_PRIVATE_KEY: privateKey } });
        await assert.rejects(() => h.client.getToken({ owner: 'o', repo: 'r', purpose: 'watcher' }),
            (e) => e.code === 'NOT_CONFIGURED' && !e.message.includes('SENTINEL-ISS'));
        assert.equal(h.calls.length, 0);
    });

    test('garbage key -> KEY_INVALID without echoing it', async () => {
        const h = harness({ config: { GITHUB_APP_ID: APP_ID, GITHUB_APP_PRIVATE_KEY: 'not-a-pem-SENTINEL-KEY' } });
        await assert.rejects(() => h.client.getToken({ owner: 'o', repo: 'r', purpose: 'watcher' }),
            (e) => e.code === 'KEY_INVALID' && !e.message.includes('SENTINEL-KEY'));
    });
});

describe('installation lookup + token cache + down-scoping', () => {
    test('installation id is cached; token cached until 5 min before expiry, then refreshed', async () => {
        let n = 0;
        const routes = [
            [isInstall, () => res(200, { id: 777 })],
            [isTokenMint, () => res(201, { token: `ghs_tok${++n}`, expires_at: new Date(T0 + 3600e3).toISOString() })],
        ];
        const h = harness({ routes });
        const ctx = { owner: 'o', repo: 'r', purpose: 'watcher' };
        assert.equal(await h.client.getToken(ctx), 'ghs_tok1');
        assert.equal(await h.client.getToken(ctx), 'ghs_tok1');
        assert.equal(h.calls.filter(isInstall).length, 1, 'installation id cached');
        assert.equal(h.calls.filter(isTokenMint).length, 1, 'token cache hit');

        // Just inside the margin: still cached.
        h.clock.t = T0 + 3600e3 - TOKEN_REFRESH_MARGIN_MS - 1000;
        assert.equal(await h.client.getToken(ctx), 'ghs_tok1');
        // At the margin: refreshed.
        h.clock.t = T0 + 3600e3 - TOKEN_REFRESH_MARGIN_MS;
        assert.equal(await h.client.getToken(ctx), 'ghs_tok2');
        assert.equal(h.calls.filter(isTokenMint).length, 2);
        assert.equal(h.calls.filter(isInstall).length, 1);
    });

    test('watcher => {actions:read}; admin => {administration:write}; repositories down-scoped; tokens not shared across purposes', async () => {
        const routes = authRoutes();
        const g = harness({ routes });
        const w = await g.client.getToken({ owner: 'o', repo: 'r', purpose: 'watcher' });
        const a = await g.client.getToken({ owner: 'o', repo: 'r', purpose: 'admin' });
        assert.notEqual(w, a);
        const mints = g.calls.filter(isTokenMint);
        assert.equal(mints.length, 2);
        assert.deepEqual(mints[0].body, { repositories: ['r'], permissions: { actions: 'read' } });
        assert.deepEqual(mints[1].body, { repositories: ['r'], permissions: { administration: 'write' } });
        assert.ok(mints[0].path.includes('/app/installations/777/access_tokens'));
    });

    test('unknown purpose and bad owner/repo are rejected before any fetch', async () => {
        const g = harness();
        await assert.rejects(() => g.client.getToken({ owner: 'o', repo: 'r', purpose: 'root' }),
            (e) => e.code === 'BAD_PURPOSE' || e.code === 'BAD_REPO');
        await assert.rejects(() => g.client.getToken({ owner: 'o', repo: '../x', purpose: 'watcher' }),
            (e) => e.code === 'BAD_REPO');
        assert.equal(g.calls.length, 0);
    });

    test('404 on installation lookup -> NOT_INSTALLED', async () => {
        const g = harness({ routes: [[isInstall, () => res(404, { message: 'Not Found' })]] });
        await assert.rejects(() => g.client.getToken({ owner: 'o', repo: 'r', purpose: 'watcher' }),
            (e) => e.code === 'NOT_INSTALLED' && e.status === 404);
    });
});

describe('conditional GET (ETag)', () => {
    function setup() {
        const seen = [];
        const routes = [
            ...authRoutes(),
            [(c) => c.method === 'GET' && c.path.startsWith('/repos/o/r/actions/runs'), (c) => {
                seen.push(c.headers['If-None-Match'] || null);
                if (c.headers['If-None-Match'] === '"v1"') return res(304, undefined, { etag: '"v1"', ...rl(4990) });
                return res(200, { total_count: 1, workflow_runs: [{ id: 9 }] }, { etag: '"v1"', ...rl(4991) });
            }],
        ];
        const g = harness({ routes });
        return { g, seen };
    }

    test('first call is unconditional 200; second sends If-None-Match and reports 304 with the cached body', async () => {
        const { g, seen } = setup();
        const p = { owner: 'o', repo: 'r', path: '/repos/o/r/actions/runs?status=queued&per_page=100' };
        const first = await g.client.conditionalGet(p);
        assert.equal(first.notModified, false);
        assert.equal(first.status, 200);
        assert.equal(first.etag, '"v1"');
        const second = await g.client.conditionalGet(p);
        assert.equal(second.notModified, true);
        assert.equal(second.status, 304);
        assert.deepEqual(second.data, { total_count: 1, workflow_runs: [{ id: 9 }] });
        assert.deepEqual(seen, [null, '"v1"']);
    });

    test('a different path does not borrow another path\'s ETag', async () => {
        const { g, seen } = setup();
        await g.client.conditionalGet({ owner: 'o', repo: 'r', path: '/repos/o/r/actions/runs?status=queued' });
        await g.client.conditionalGet({ owner: 'o', repo: 'r', path: '/repos/o/r/actions/runs?status=in_progress' });
        assert.deepEqual(seen, [null, null]);
    });

    test('non-200/304 is an HTTP error that names a path template, not the body', async () => {
        const g = harness({ routes: [...authRoutes(), [() => true, () => res(500, { message: 'boom-BODY' })]] });
        await assert.rejects(() => g.client.conditionalGet({ owner: 'o', repo: 'r', path: '/repos/o/r/actions/runs/123/jobs' }),
            (e) => e.code === 'HTTP' && e.status === 500 && !e.message.includes('BODY') && e.message.includes('{n}'));
    });

    test('a 401 on a cached token drops it and retries once with a fresh one', async () => {
        let first = true;
        const routes = [
            ...authRoutes(),
            [(c) => c.path.startsWith('/repos/o/r/actions/runs'), (c) => {
                if (first) { first = false; return res(401, { message: 'Bad credentials' }); }
                return res(200, { ok: true }, { etag: '"e"' });
            }],
        ];
        const g = harness({ routes });
        const out = await g.client.conditionalGet({ owner: 'o', repo: 'r', path: '/repos/o/r/actions/runs' });
        assert.equal(out.status, 200);
        assert.equal(g.calls.filter(isTokenMint).length, 2);
    });
});

describe('rate-limit tracking and self-protection', () => {
    async function withRemaining(remaining, limit = 5000) {
        const routes = [
            ...authRoutes(),
            [(c) => c.path.startsWith('/repos/o/r/actions/runs'), () => res(200, {}, rl(remaining, limit))],
        ];
        const g = harness({ routes });
        await g.client.conditionalGet({ owner: 'o', repo: 'r', path: '/repos/o/r/actions/runs' });
        return g;
    }

    test('>=20% remaining is normal', async () => {
        const g = await withRemaining(1000); // exactly 20%
        const s = g.client.getRateState();
        assert.equal(s.mode, 'normal');
        assert.equal(s.remaining, 1000);
        assert.equal(s.limit, 5000);
    });

    test('<20% remaining -> slow cadence', async () => {
        const g = await withRemaining(999);
        assert.equal(g.client.getRateState().mode, 'slow');
    });

    test('<5% remaining -> suspended until x-ratelimit-reset, degraded signalled exactly once per window', async () => {
        const g = await withRemaining(249); // 4.98%
        const s = g.client.getRateState();
        assert.equal(s.mode, 'suspended');
        assert.equal(s.resumeAt, (T0 / 1000 + 3600) * 1000);
        assert.equal(g.degraded.length, 1);
        assert.equal(g.degraded[0].remaining, 249);
        // A second low reading in the same window does not re-alert.
        await g.client.conditionalGet({ owner: 'o', repo: 'r', path: '/repos/o/r/actions/runs' });
        assert.equal(g.degraded.length, 1);
    });

    test('exactly 5% is slow, not suspended', async () => {
        const g = await withRemaining(250);
        assert.equal(g.client.getRateState().mode, 'slow');
        assert.equal(g.degraded.length, 0);
    });

    test('after the reset time passes the state returns to normal', async () => {
        const g = await withRemaining(10);
        assert.equal(g.client.getRateState().mode, 'suspended');
        g.clock.t = T0 + 3600e3 + 1;
        assert.equal(g.client.getRateState().mode, 'normal');
    });

    test('secondary limit: 403 + retry-after is honoured exactly, no fetch until it elapses', async () => {
        let hits = 0;
        const routes = [
            ...authRoutes(),
            [(c) => c.path.startsWith('/repos/o/r/actions/runs'), () => {
                hits++;
                return hits === 1 ? res(403, { message: 'secondary' }, { 'retry-after': 37 }) : res(200, {}, rl(4000));
            }],
        ];
        const g = harness({ routes });
        const p = { owner: 'o', repo: 'r', path: '/repos/o/r/actions/runs' };
        await assert.rejects(() => g.client.conditionalGet(p),
            (e) => e.code === 'RATE_LIMITED' && e.retryAfterMs === 37000 && e.status === 403);
        assert.equal(g.client.getRateState().mode, 'blocked');
        const before = g.calls.length;

        g.clock.t = T0 + 36999;
        await assert.rejects(() => g.client.conditionalGet(p), (e) => e.code === 'RATE_LIMITED' && e.retryAfterMs === 1);
        assert.equal(g.calls.length, before, 'no request while blocked');

        g.clock.t = T0 + 37000;
        const ok = await g.client.conditionalGet(p);
        assert.equal(ok.status, 200);
        assert.equal(g.client.getRateState().mode, 'normal');
    });

    test('429 + retry-after also blocks; plain 403 without retry-after/zero-remaining is an ordinary HTTP error', async () => {
        const g1 = harness({ routes: [[isInstall, () => res(429, {}, { 'retry-after': 5 })]] });
        await assert.rejects(() => g1.client.getInstallationId('o', 'r'), (e) => e.code === 'RATE_LIMITED' && e.retryAfterMs === 5000);
        const g2 = harness({ routes: [[isInstall, () => res(403, { message: 'forbidden' })]] });
        await assert.rejects(() => g2.client.getInstallationId('o', 'r'), (e) => e.code === 'HTTP' && e.status === 403);
    });

    test('primary exhaustion (403, remaining 0) reports time to reset', async () => {
        const g = harness({ routes: [[isInstall, () => res(403, {}, rl(0))]] });
        await assert.rejects(() => g.client.getInstallationId('o', 'r'),
            (e) => e.code === 'RATE_LIMITED' && e.retryAfterMs === 3600e3);
    });
});

describe('runner admin calls', () => {
    const JIT = 'SENTINEL-JIT-CONFIG-b64';

    test('generateJitConfig uses an administration:write token and the documented body', async () => {
        const routes = [
            ...authRoutes(),
            [(c) => c.method === 'POST' && c.path === '/repos/o/r/actions/runners/generate-jitconfig',
                () => res(201, { runner: { id: 55, name: 'n' }, encoded_jit_config: JIT }, rl(4900))],
        ];
        const g = harness({ routes });
        const out = await g.client.generateJitConfig({ owner: 'o', repo: 'r', name: 'fcp-1', labels: ['self-hosted', 'fcp'], runnerGroupId: 3, workFolder: '_work' });
        assert.deepEqual(out, { runnerId: 55, encodedJitConfig: JIT });
        const mint = g.calls.find(isTokenMint);
        assert.deepEqual(mint.body.permissions, { administration: 'write' });
        const call = g.calls.find((c) => c.path.endsWith('generate-jitconfig'));
        assert.deepEqual(call.body, { name: 'fcp-1', runner_group_id: 3, labels: ['self-hosted', 'fcp'], work_folder: '_work' });
        assert.equal(call.headers.Authorization, 'Bearer ghs_tok1');
    });

    test('generateJitConfig argument and response validation', async () => {
        const g = harness();
        await assert.rejects(() => g.client.generateJitConfig({ owner: 'o', repo: 'r', name: 'x', labels: [] }), (e) => e.code === 'BAD_ARGS');
        const g2 = harness({ routes: [...authRoutes(), [(c) => c.path.endsWith('generate-jitconfig'), () => res(201, { runner: {} })]] });
        await assert.rejects(() => g2.client.generateJitConfig({ owner: 'o', repo: 'r', name: 'x', labels: ['a'] }), (e) => e.code === 'BAD_RESPONSE');
    });

    test('deleteRunner: 204 deleted, 404 already gone, other statuses throw', async () => {
        let status = 204;
        const routes = [
            ...authRoutes(),
            [(c) => c.method === 'DELETE' && c.path === '/repos/o/r/actions/runners/55', () => res(status, undefined, rl(4800))],
        ];
        const g = harness({ routes });
        assert.deepEqual(await g.client.deleteRunner({ owner: 'o', repo: 'r', runnerId: 55 }), { deleted: true });
        status = 404;
        assert.deepEqual(await g.client.deleteRunner({ owner: 'o', repo: 'r', runnerId: 55 }), { deleted: false, alreadyGone: true });
        status = 500;
        await assert.rejects(() => g.client.deleteRunner({ owner: 'o', repo: 'r', runnerId: 55 }), (e) => e.code === 'HTTP' && e.status === 500);
        await assert.rejects(() => g.client.deleteRunner({ owner: 'o', repo: 'r', runnerId: 'x' }), (e) => e.code === 'BAD_ARGS');
        assert.deepEqual(g.calls.find(isTokenMint).body.permissions, { administration: 'write' });
    });
});

describe('secrets never leak (sentinel)', () => {
    const SENT_TOKEN = 'ghs_SENTINEL-INSTALL-TOKEN';
    const SENT_JIT = 'SENTINEL-JIT-CONFIG-LEAK';
    const SENT_KEY_BODY = KEY_BODY;

    test('thrown errors and console output contain no key, JWT, token or JIT config on any failure path', async () => {
        const captured = [];
        const saved = {};
        for (const m of ['log', 'info', 'warn', 'error', 'debug']) {
            saved[m] = console[m];
            console[m] = (...a) => captured.push(a.map(String).join(' '));
        }
        const writes = [];
        const origOut = process.stdout.write;
        const origErr = process.stderr.write;
        // Only capture, then pass through so the runner's own reporting still works.
        process.stdout.write = function (c, ...r) { writes.push(String(c)); return origOut.call(this, c, ...r); };
        process.stderr.write = function (c, ...r) { writes.push(String(c)); return origErr.call(this, c, ...r); };

        const errors = [];
        const jwts = [];
        try {
                // Failure scenarios; every response/rejection body deliberately carries the sentinels.
            const echo = { message: `echo ${SENT_TOKEN} ${SENT_JIT} ${SENT_KEY_BODY}` };
            const scenarios = [
                // network error whose own message carries secrets
                [[(c) => { jwts.push(c.headers.Authorization); return true; }, () => { throw new Error(`socket ${SENT_TOKEN} ${SENT_KEY_BODY}`); }]],
                // HTTP errors with echoing bodies
                [[isInstall, () => res(500, echo)]],
                [[isInstall, () => res(404, echo)]],
                [[isInstall, () => res(200, { id: 777 })], [isTokenMint, () => res(422, echo)]],
                // malformed success bodies
                [[isInstall, () => res(200, { id: 777 })], [isTokenMint, () => res(201, { token: SENT_TOKEN, expires_at: 'nonsense' })]],
                // rate limit with echoing body
                [[isInstall, () => res(403, echo, { 'retry-after': 3 })]],
                // jit config malformed / failing after a good token
                [[isInstall, () => res(200, { id: 777 })],
                    [isTokenMint, () => res(201, { token: SENT_TOKEN, expires_at: new Date(T0 + 3600e3).toISOString() })],
                    [(c) => c.path.endsWith('generate-jitconfig'), () => res(201, { runner: { id: 'bad' }, encoded_jit_config: SENT_JIT })]],
                [[isInstall, () => res(200, { id: 777 })],
                    [isTokenMint, () => res(201, { token: SENT_TOKEN, expires_at: new Date(T0 + 3600e3).toISOString() })],
                    [(c) => c.path.endsWith('generate-jitconfig'), () => res(500, { message: SENT_JIT })]],
                [[isInstall, () => res(200, { id: 777 })],
                    [isTokenMint, () => res(201, { token: SENT_TOKEN, expires_at: new Date(T0 + 3600e3).toISOString() })],
                    [(c) => c.method === 'DELETE', () => res(500, echo)]],
            ];
            for (const routes of scenarios) {
                const g = harness({ routes });
                const ctx = { owner: 'o', repo: 'r' };
                for (const call of [
                    () => g.client.conditionalGet({ ...ctx, path: '/repos/o/r/actions/runs' }),
                    () => g.client.generateJitConfig({ ...ctx, name: 'n', labels: ['l'] }),
                    () => g.client.deleteRunner({ ...ctx, runnerId: 9 }),
                ]) {
                    try { await call(); } catch (e) { errors.push(e); }
                }
            }
            // Bad key on a real signing attempt.
            const bad = harness({ config: { GITHUB_APP_ID: APP_ID, GITHUB_APP_PRIVATE_KEY: `-----BEGIN PRIVATE KEY-----\n${SENT_KEY_BODY}\n-----END PRIVATE KEY-----` } });
            try { await bad.client.getToken({ owner: 'o', repo: 'r', purpose: 'watcher' }); } catch (e) { errors.push(e); }
        } finally {
            for (const m of Object.keys(saved)) console[m] = saved[m];
            process.stdout.write = origOut;
            process.stderr.write = origErr;
        }

        assert.ok(errors.length >= 20, `expected many failure paths exercised, got ${errors.length}`);
        const forbidden = [SENT_TOKEN, SENT_JIT, SENT_KEY_BODY, 'PRIVATE KEY', 'eyJ' /* any JWT segment */, 'Bearer '];
        for (const e of errors) {
            const blob = `${e.name} ${e.message} ${e.stack ? e.stack.split('\n')[0] : ''} ${JSON.stringify(e)}`;
            for (const f of forbidden) assert.ok(!blob.includes(f), `error leaked ${f}: ${blob}`);
        }
        assert.deepEqual(captured, [], 'module wrote to console');
        const leaked = writes.filter((w) => forbidden.some((f) => w.includes(f) && f !== 'Bearer '));
        assert.deepEqual(leaked, []);
        assert.ok(jwts.length > 0, 'the network-error scenario really ran with a signed JWT');
    });

    test('public surface never hands back the key or a JWT: client has no accessor for them', () => {
        const g = harness();
        assert.deepEqual(Object.keys(g.client).sort(),
            // XACA-1479-005 added listBranchPullLabels: it returns PR numbers + label names only.
            ['conditionalGet', 'deleteRunner', 'generateJitConfig', 'getInstallationId', 'getRateState', 'getToken', 'listBranchPullLabels']);
        assert.ok(!JSON.stringify(g.client.getRateState()).includes('PRIVATE'));
    });
});
