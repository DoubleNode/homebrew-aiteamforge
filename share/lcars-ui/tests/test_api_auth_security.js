//
//  test_api_auth_security.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * test_api_auth_security.js — XACA-0395 post-review security corrections to
 * api-auth.js. Kept separate from test_api_auth.js (which covers the module's
 * ordinary behaviour) so the two review findings below have one obvious home:
 *
 *   Finding 018 — apiFetch() attached the LCARS key to ANY url. A future call
 *     site written against an absolute URL could have shipped
 *     AITEAMFORGE_API_KEY to a foreign host. Now guarded by
 *     isSameOriginTarget().
 *   Finding 021 — resolveKey() cached the null from a FAILED /api/auth-key
 *     lookup for the life of the page, so one transient blip left every later
 *     mutation 401ing until a manual reload. Now the cache is cleared on
 *     failure and kept only on an authoritative answer.
 *
 * No real network, no DOM: createApiAuthClient() takes an injected `fetch`
 * (and now an injected `baseHref`, so the same-origin guard is exercised
 * deterministically without a browser `location`). Uses the literal test key
 * `test-api-key-not-a-real-secret` per contract §8 L5 — never a real secret.
 *
 * Usage:
 *   node --test lcars-ui/tests/test_api_auth_security.js
 */

'use strict';

var test   = require('node:test');
var assert = require('node:assert/strict');
var path   = require('path');

var API_AUTH_PATH = path.join(__dirname, '../js/api-auth.js');
var apiAuth = require(API_AUTH_PATH);

var createApiAuthClient = apiAuth.createApiAuthClient;
var isSameOriginTarget  = apiAuth.isSameOriginTarget;

var TEST_KEY  = 'test-api-key-not-a-real-secret';
var PAGE_HREF = 'http://localhost:8203/index.html';

/**
 * Scripted fake fetch. `authKeyResponses` is consumed one entry per
 * GET /api/auth-key; each entry is either {ok, json} or {throws: true}.
 * Every non-auth-key call is recorded so a test can inspect exactly what
 * headers (if any) went out.
 */
function makeFetch(authKeyResponses) {
    var queue = authKeyResponses.slice();
    var calls = [];
    var authKeyCallCount = 0;

    function fake(input, init) {
        var url = (typeof input === 'string') ? input : (input && input.url) || String(input);
        if (url === '/api/auth-key') {
            authKeyCallCount += 1;
            var next = queue.length ? queue.shift() : { ok: true, json: { apiKey: TEST_KEY } };
            if (next.throws) {
                return Promise.reject(new Error('network down'));
            }
            return Promise.resolve({
                ok: next.ok,
                status: next.status || (next.ok ? 200 : 500),
                json: function () {
                    if (next.badJson) {
                        return Promise.reject(new Error('bad json'));
                    }
                    return Promise.resolve(next.json);
                },
            });
        }
        calls.push({ input: input, init: init });
        return Promise.resolve({ ok: true, status: 200, json: function () { return Promise.resolve({}); } });
    }

    fake.calls = calls;
    fake.authKeyCallCount = function () { return authKeyCallCount; };
    return fake;
}

function authHeaderOf(call) {
    var headers = call.init && call.init.headers;
    if (!headers) return null;
    if (typeof headers.get === 'function') return headers.get('Authorization');
    return headers.Authorization || null;
}

function clientWith(fetchImpl) {
    return createApiAuthClient({ fetch: fetchImpl, notify: function () {}, baseHref: PAGE_HREF });
}


// ---------------------------------------------------------------------------
// Finding 018 — same-origin guard
// ---------------------------------------------------------------------------

test('018: relative URLs are same-origin and still get the key', async function () {
    var fake = makeFetch([]);
    var client = clientWith(fake);

    await client.apiFetch('/api/todos', { method: 'POST' });

    assert.equal(fake.calls.length, 1);
    assert.equal(authHeaderOf(fake.calls[0]), 'Bearer ' + TEST_KEY);
});

test('018: absolute same-origin URL still gets the key', async function () {
    var fake = makeFetch([]);
    var client = clientWith(fake);

    await client.apiFetch('http://localhost:8203/api/todos', { method: 'POST' });

    assert.equal(authHeaderOf(fake.calls[0]), 'Bearer ' + TEST_KEY);
});

test('018: absolute FOREIGN URL never receives the key', async function () {
    var fake = makeFetch([]);
    var client = clientWith(fake);

    var response = await client.apiFetch('https://evil.example/collect', { method: 'POST' });

    // The call is passed through, not blocked...
    assert.equal(response.ok, true);
    assert.equal(fake.calls.length, 1);
    // ...but carries no credential, and never even looked one up.
    assert.equal(authHeaderOf(fake.calls[0]), null);
    assert.equal(fake.authKeyCallCount(), 0);
});

test('018: the key literal appears nowhere in a cross-origin request', async function () {
    // Belt-and-braces on the assertion above: serialise everything that went
    // out and prove the key is absent, not merely absent from the one header
    // we thought to check.
    var fake = makeFetch([]);
    var client = clientWith(fake);

    await client.apiFetch('https://evil.example/collect', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: '{"x":1}',
    });

    var serialised = JSON.stringify(fake.calls, function (k, v) {
        if (v && typeof v.entries === 'function' && typeof v.get === 'function') {
            return Array.from(v.entries());   // Headers instance
        }
        return v;
    });
    assert.ok(serialised.indexOf(TEST_KEY) === -1, 'key leaked into a cross-origin request');
});

test('018: protocol-relative //host is treated as cross-origin, not relative', async function () {
    // '//evil.example/x' keeps the scheme but replaces the HOST — a naive
    // "does it start with a scheme?" check reads it as relative. It is not.
    var fake = makeFetch([]);
    var client = clientWith(fake);

    await client.apiFetch('//evil.example/collect', { method: 'POST' });

    assert.equal(authHeaderOf(fake.calls[0]), null);
});

test('018: same-origin guard covers Request and URL inputs, not just strings', function () {
    assert.equal(isSameOriginTarget({ url: 'http://localhost:8203/api/todos' }, PAGE_HREF), true);
    assert.equal(isSameOriginTarget({ url: 'https://evil.example/x' }, PAGE_HREF), false);
    assert.equal(isSameOriginTarget(new URL('http://localhost:8203/api/x'), PAGE_HREF), true);
    assert.equal(isSameOriginTarget(new URL('https://evil.example/x'), PAGE_HREF), false);
});

test('018: unrecognised input shapes and unverifiable bases fail CLOSED', function () {
    assert.equal(isSameOriginTarget(null, PAGE_HREF), false);
    assert.equal(isSameOriginTarget(42, PAGE_HREF), false);
    assert.equal(isSameOriginTarget({}, PAGE_HREF), false);
    // Absolute URL with no page to compare against -> cannot verify -> withhold.
    assert.equal(isSameOriginTarget('https://evil.example/x', null), false);
    // A relative URL needs no base and is same-origin by construction.
    assert.equal(isSameOriginTarget('/api/todos', null), true);
});

test('018: a different PORT on the same host is cross-origin', function () {
    assert.equal(isSameOriginTarget('http://localhost:9999/api/x', PAGE_HREF), false);
});

test('018: GET to a foreign URL is unaffected (no key was ever attached to reads)', async function () {
    var fake = makeFetch([]);
    var client = clientWith(fake);

    await client.apiFetch('https://evil.example/read', { method: 'GET' });

    assert.equal(authHeaderOf(fake.calls[0]), null);
    assert.equal(fake.authKeyCallCount(), 0);
});


// ---------------------------------------------------------------------------
// Finding 021 — a transient key-lookup failure must self-heal
// ---------------------------------------------------------------------------

test('021: a transient network failure does not poison the cache', async function () {
    var fake = makeFetch([
        { throws: true },                              // 1st lookup: blip
        { ok: true, json: { apiKey: TEST_KEY } },      // 2nd lookup: recovered
    ]);
    var client = clientWith(fake);

    await client.apiFetch('/api/todos', { method: 'POST' });
    assert.equal(authHeaderOf(fake.calls[0]), null, 'first call has no key, as expected');

    await client.apiFetch('/api/todos', { method: 'POST' });
    assert.equal(
        authHeaderOf(fake.calls[1]), 'Bearer ' + TEST_KEY,
        'the NEXT mutation must retry and recover without a page reload'
    );
    assert.equal(fake.authKeyCallCount(), 2);
});

test('021: a non-2xx auth-key response is retried, not cached', async function () {
    var fake = makeFetch([
        { ok: false, status: 502 },
        { ok: true, json: { apiKey: TEST_KEY } },
    ]);
    var client = clientWith(fake);

    await client.apiFetch('/api/todos', { method: 'POST' });
    await client.apiFetch('/api/todos', { method: 'POST' });

    assert.equal(authHeaderOf(fake.calls[1]), 'Bearer ' + TEST_KEY);
});

test('021: an unparseable auth-key body is retried, not cached', async function () {
    var fake = makeFetch([
        { ok: true, badJson: true },
        { ok: true, json: { apiKey: TEST_KEY } },
    ]);
    var client = clientWith(fake);

    await client.apiFetch('/api/todos', { method: 'POST' });
    await client.apiFetch('/api/todos', { method: 'POST' });

    assert.equal(authHeaderOf(fake.calls[1]), 'Bearer ' + TEST_KEY);
});

test('021: an AUTHORITATIVE {"apiKey": null} IS cached — open posture stays one fetch', async function () {
    // The counterpart the fix must not break: a machine with no key
    // configured answers 200/null on every lookup. Re-asking per mutation
    // would turn "resolve once" into "fetch per call".
    var fake = makeFetch([
        { ok: true, json: { apiKey: null } },
        { ok: true, json: { apiKey: null } },
        { ok: true, json: { apiKey: null } },
    ]);
    var client = clientWith(fake);

    await client.apiFetch('/api/todos', { method: 'POST' });
    await client.apiFetch('/api/todos', { method: 'POST' });
    await client.apiFetch('/api/todos', { method: 'POST' });

    assert.equal(fake.authKeyCallCount(), 1, 'open posture must not re-fetch per mutation');
});

test('021: a successful key resolution is still cached (resolve-once preserved)', async function () {
    var fake = makeFetch([{ ok: true, json: { apiKey: TEST_KEY } }]);
    var client = clientWith(fake);

    await client.apiFetch('/api/todos', { method: 'POST' });
    await client.apiFetch('/api/todos', { method: 'PUT' });
    await client.apiFetch('/api/todos', { method: 'DELETE' });

    assert.equal(fake.authKeyCallCount(), 1, 'this must not become a per-call fetch');
    assert.equal(authHeaderOf(fake.calls[2]), 'Bearer ' + TEST_KEY);
});

test('021: concurrent mutations during one failed lookup share it, then recover once', async function () {
    var fake = makeFetch([
        { throws: true },
        { ok: true, json: { apiKey: TEST_KEY } },
    ]);
    var client = clientWith(fake);

    // Both start before the first lookup settles -> one shared in-flight
    // lookup, not two.
    await Promise.all([
        client.apiFetch('/api/todos', { method: 'POST' }),
        client.apiFetch('/api/todos', { method: 'POST' }),
    ]);
    assert.equal(fake.authKeyCallCount(), 1);

    await client.apiFetch('/api/todos', { method: 'POST' });
    assert.equal(authHeaderOf(fake.calls[2]), 'Bearer ' + TEST_KEY);
    assert.equal(fake.authKeyCallCount(), 2);
});
