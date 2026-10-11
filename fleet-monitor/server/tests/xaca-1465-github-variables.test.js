//
//  xaca-1465-github-variables.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1465-001 -- getRepoVariable + the 'variables' token purpose, against a stubbed fetch.
 * NO network. The RSA key is generated at runtime.
 */

const crypto = require('crypto');
const { test, describe } = require('node:test');
const assert = require('node:assert/strict');

const { createGithubClient, GithubError, PURPOSE_PERMISSIONS } = require('../lib/ci-dispatch-github');

const { privateKey } = crypto.generateKeyPairSync('rsa', {
    modulusLength: 2048,
    publicKeyEncoding: { type: 'spki', format: 'pem' },
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
});

const T0 = Date.UTC(2026, 9, 6, 12, 0, 0);
const TOKEN = 'ghs_xaca1465_SENTINEL_token';

function res(status, body, headers = {}) {
    const h = new Map(Object.entries(headers).map(([k, v]) => [k.toLowerCase(), String(v)]));
    return {
        status,
        headers: { get: (n) => (h.has(n.toLowerCase()) ? h.get(n.toLowerCase()) : null) },
        json: async () => { if (body === undefined) throw new Error('no body'); return body; },
    };
}

/** varRes: handler for the variable GET. mintStatus overrides the token mint response. */
function harness({ varRes, mintStatus = 201 } = {}) {
    const calls = [];
    const fetchStub = async (url, init) => {
        const u = new URL(url);
        const call = {
            method: init.method, path: u.pathname, headers: init.headers,
            body: init.body ? JSON.parse(init.body) : undefined,
        };
        calls.push(call);
        if (call.method === 'GET' && /\/installation$/.test(call.path)) return res(200, { id: 777 });
        if (call.method === 'POST' && /\/access_tokens$/.test(call.path)) {
            return mintStatus === 201
                ? res(201, { token: TOKEN, expires_at: new Date(T0 + 3600e3).toISOString() })
                : res(mintStatus, {});
        }
        if (/\/actions\/variables\//.test(call.path)) return varRes(call);
        throw new Error(`unrouted ${call.method} ${call.path}`);
    };
    const client = createGithubClient({
        config: { GITHUB_APP_ID: '424242', GITHUB_APP_PRIVATE_KEY: privateKey },
        fetch: fetchStub, now: () => T0,
    });
    return { client, calls };
}

const varCalls = (calls) => calls.filter((c) => /\/actions\/variables\//.test(c.path));

describe('XACA-1465-001 getRepoVariable', () => {
    test('purpose table: variables => exactly {actions_variables:"read"}', () => {
        assert.deepEqual({ ...PURPOSE_PERMISSIONS.variables }, { actions_variables: 'read' });
    });

    test('token mint requests exactly {actions_variables:read} scoped to the repo', async () => {
        const { client, calls } = harness({ varRes: () => res(200, { name: 'X', value: 'true' }) });
        await client.getRepoVariable('acme', 'widgets', 'TAP_PUBLISHER_ENABLED');
        const mint = calls.find((c) => c.method === 'POST');
        assert.deepEqual(mint.body, { repositories: ['widgets'], permissions: { actions_variables: 'read' } });
        const v = varCalls(calls)[0];
        assert.equal(v.method, 'GET');
        assert.equal(v.path, '/repos/acme/widgets/actions/variables/TAP_PUBLISHER_ENABLED');
        assert.equal(v.headers.Authorization, `Bearer ${TOKEN}`);
        assert.equal(v.headers['If-None-Match'], undefined);
    });

    test('200 => found/value/updatedAt/etag', async () => {
        const { client } = harness({
            varRes: () => res(200, { name: 'V', value: 'TrUe', updated_at: '2026-10-01T00:00:00Z' }, { etag: 'W/"abc"' }),
        });
        assert.deepEqual(await client.getRepoVariable('acme', 'widgets', 'V'),
            { found: true, value: 'TrUe', updatedAt: '2026-10-01T00:00:00Z', etag: 'W/"abc"' });
    });

    test('200 without updated_at/etag => nulls', async () => {
        const { client } = harness({ varRes: () => res(200, { value: '' }) });
        assert.deepEqual(await client.getRepoVariable('acme', 'widgets', 'V'),
            { found: true, value: '', updatedAt: null, etag: null });
    });

    test('200 with malformed body => BAD_RESPONSE', async () => {
        const { client } = harness({ varRes: () => res(200, { value: 5 }) });
        await assert.rejects(client.getRepoVariable('acme', 'widgets', 'V'), (e) => e instanceof GithubError && e.code === 'BAD_RESPONSE');
    });

    test('404 => found:false', async () => {
        const { client } = harness({ varRes: () => res(404, { message: 'Not Found' }) });
        assert.deepEqual(await client.getRepoVariable('acme', 'widgets', 'V'), { found: false });
    });

    test('304 with etag => notModified, sends If-None-Match', async () => {
        const { client, calls } = harness({ varRes: () => res(304) });
        const r = await client.getRepoVariable('acme', 'widgets', 'V', { etag: 'W/"abc"' });
        assert.deepEqual(r, { notModified: true, etag: 'W/"abc"' });
        assert.equal(varCalls(calls)[0].headers['If-None-Match'], 'W/"abc"');
    });

    for (const status of [403, 500]) {
        test(`${status} => GithubError HTTP with status, no secret in message`, async () => {
            const { client } = harness({ varRes: () => res(status, { message: `leak ${TOKEN}` }) });
            await assert.rejects(client.getRepoVariable('acme', 'widgets', 'V'), (e) => {
                assert.ok(e instanceof GithubError);
                assert.equal(e.code, 'HTTP');
                assert.equal(e.status, status);
                assert.equal(e.message.includes(TOKEN), false);
                assert.equal(/eyJ/.test(e.message), false, 'no JWT');
                assert.match(e.message, /\{owner\}\/\{repo\}\/actions\/variables\/\{name\}/);
                return true;
            });
        });
    }

    test('token mint 403 (permission not approved) => GithubError w/ status, no variable GET', async () => {
        const { client, calls } = harness({ mintStatus: 403, varRes: () => res(200, { value: 'true' }) });
        await assert.rejects(client.getRepoVariable('acme', 'widgets', 'V'), (e) => {
            assert.ok(e instanceof GithubError);
            assert.equal(e.status, 403);
            assert.equal(e.message.includes(TOKEN), false);
            return true;
        });
        assert.equal(varCalls(calls).length, 0);
    });

    test('invalid owner/repo/name rejected before any HTTP', async () => {
        const { client, calls } = harness({ varRes: () => res(200, { value: 'x' }) });
        const bad = [
            ['bad owner!', 'widgets', 'V', 'BAD_REPO'],
            ['acme', '..', 'V', 'BAD_REPO'],
            ['acme', 'wid gets', 'V', 'BAD_REPO'],
            ['acme', 'widgets', '1BAD', 'BAD_ARGS'],
            ['acme', 'widgets', 'a/b', 'BAD_ARGS'],
            ['acme', 'widgets', 'a-b', 'BAD_ARGS'],
            ['acme', 'widgets', '', 'BAD_ARGS'],
            ['acme', 'widgets', 'A'.repeat(256), 'BAD_ARGS'],
            ['acme', 'widgets', undefined, 'BAD_ARGS'],
            ['acme', 'widgets', '../../x', 'BAD_ARGS'],
        ];
        for (const [o, r, n, code] of bad) {
            await assert.rejects(client.getRepoVariable(o, r, n), (e) => e instanceof GithubError && e.code === code, `${o}/${r}/${n}`);
        }
        assert.equal(calls.length, 0);
        await client.getRepoVariable('acme', 'widgets', 'A'.repeat(255)); // boundary is accepted
        assert.equal(varCalls(calls).length, 1);
    });
});
