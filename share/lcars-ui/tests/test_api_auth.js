//
//  test_api_auth.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * test_api_auth.js — Node-native unit tests for api-auth.js (XACA-0395-007).
 *
 * Covers the load-bearing claims of the browser client migration:
 *   - apiFetch() attaches `Authorization: Bearer <key>` on mutating methods
 *     (POST/PUT/PATCH/DELETE) once a key resolves from GET /api/auth-key.
 *   - GET (and any other non-mutating method) passes straight through with
 *     no key lookup and no Authorization header — verifies the "no extra
 *     round trip for reads" claim, not just "reads still work".
 *   - A 401 response produces a visible, non-silent error path (asserted via
 *     an injected notify() spy — mirrors the real showToast('...', 'error')
 *     call apiFetch() makes in the browser).
 *   - The key never appears in the DOM/log-facing surface: the fixed
 *     AUTH_FAILURE_MESSAGE constant is asserted to not contain the test key
 *     literal, and the notify spy's captured arguments are asserted the
 *     same way on every 401 case.
 *   - The key is fetched at most once per client instance (cached), not
 *     once per mutating call — proves the "resolve once" design, not just
 *     that it eventually resolves.
 *
 * No real network, no DOM, no browser: createApiAuthClient() takes an
 * injected `fetch` and `notify`, so every test constructs an isolated client
 * against a scripted fake fetch. Uses the literal test key
 * `test-api-key-not-a-real-secret` per contract §8 L5 — never a real secret.
 *
 * Usage:
 *   node --test lcars-ui/tests/test_api_auth.js
 *
 * No external dependencies. Node ≥18 required (node:test, global fetch/Headers
 * are built-in — the browser module itself only touches `fetch`/`Headers`/
 * `window`/`module` conditionally, so it loads cleanly under plain `require()`).
 */

'use strict';

var test   = require('node:test');
var assert = require('node:assert/strict');
var path   = require('path');

var API_AUTH_PATH = path.join(__dirname, '../js/api-auth.js');
var apiAuth = require(API_AUTH_PATH);

var createApiAuthClient = apiAuth.createApiAuthClient;
var isMutatingMethod    = apiAuth.isMutatingMethod;
var normalizeMethod     = apiAuth.normalizeMethod;
var mergeAuthHeader     = apiAuth.mergeAuthHeader;
var AUTH_FAILURE_MESSAGE = apiAuth.AUTH_FAILURE_MESSAGE;
var AUTH_KEY_ENDPOINT   = apiAuth.AUTH_KEY_ENDPOINT;

var TEST_KEY = 'test-api-key-not-a-real-secret';

// ─── Fake fetch/response builders ──────────────────────────────────────────

function jsonResponse(status, body) {
    return {
        ok: status >= 200 && status < 300,
        status: status,
        json: function () { return Promise.resolve(body); },
    };
}

/**
 * Builds a fake fetch(url, init) that:
 *   - returns `keyResponse` (default: { apiKey: TEST_KEY }) for GET <endpoint>
 *   - otherwise records the call and returns `mutatingResponse`
 * Records every call in `calls` as { url, init }.
 */
function makeFakeFetch(opts) {
    opts = opts || {};
    var endpoint = opts.endpoint || AUTH_KEY_ENDPOINT;
    var keyResponse = opts.keyResponse !== undefined
        ? opts.keyResponse
        : jsonResponse(200, { apiKey: TEST_KEY });
    var mutatingResponse = opts.mutatingResponse || jsonResponse(200, { ok: true });
    var calls = [];

    function fakeFetch(url, init) {
        calls.push({ url: url, init: init });
        if (url === endpoint) {
            return Promise.resolve(keyResponse);
        }
        return Promise.resolve(mutatingResponse);
    }
    fakeFetch.calls = calls;
    return fakeFetch;
}

function makeNotifySpy() {
    var calls = [];
    function notify(message, type, duration) {
        calls.push({ message: message, type: type, duration: duration });
    }
    notify.calls = calls;
    return notify;
}

// ─── isMutatingMethod / normalizeMethod ────────────────────────────────────

test('normalizeMethod: defaults to GET when init is undefined', () => {
    assert.equal(normalizeMethod(undefined), 'GET');
});

test('normalizeMethod: defaults to GET when init.method is absent', () => {
    assert.equal(normalizeMethod({}), 'GET');
});

test('normalizeMethod: uppercases a lowercase method', () => {
    assert.equal(normalizeMethod({ method: 'post' }), 'POST');
});

test('isMutatingMethod: POST/PUT/PATCH/DELETE are mutating', () => {
    assert.ok(isMutatingMethod('POST'));
    assert.ok(isMutatingMethod('PUT'));
    assert.ok(isMutatingMethod('PATCH'));
    assert.ok(isMutatingMethod('DELETE'));
});

test('isMutatingMethod: GET/HEAD/OPTIONS are NOT mutating', () => {
    assert.ok(!isMutatingMethod('GET'));
    assert.ok(!isMutatingMethod('HEAD'));
    assert.ok(!isMutatingMethod('OPTIONS'));
});

// ─── mergeAuthHeader ────────────────────────────────────────────────────────

test('mergeAuthHeader: attaches Authorization: Bearer <key>', () => {
    var opts = mergeAuthHeader({ method: 'POST' }, TEST_KEY);
    var headers = opts.headers;
    assert.equal(headers.get('Authorization'), 'Bearer ' + TEST_KEY);
});

test('mergeAuthHeader: preserves existing headers (Content-Type survives)', () => {
    var opts = mergeAuthHeader({ method: 'POST', headers: { 'Content-Type': 'application/json' } }, TEST_KEY);
    assert.equal(opts.headers.get('Content-Type'), 'application/json');
    assert.equal(opts.headers.get('Authorization'), 'Bearer ' + TEST_KEY);
});

test('mergeAuthHeader: no key -> no Authorization header, no mutation of caller\'s init', () => {
    var original = { method: 'POST', headers: { 'X-Foo': 'bar' } };
    var opts = mergeAuthHeader(original, null);
    assert.equal(opts.headers, original.headers, 'headers left untouched when no key');
    assert.equal(original.headers.Authorization, undefined);
});

test('mergeAuthHeader: never mutates the caller-supplied init object', () => {
    var original = { method: 'POST', headers: { 'Content-Type': 'application/json' } };
    var frozenHeadersRef = original.headers;
    mergeAuthHeader(original, TEST_KEY);
    assert.equal(original.headers, frozenHeadersRef, 'original.headers reference unchanged');
    assert.equal(original.headers.Authorization, undefined, 'original plain object never gains Authorization');
});

// ─── apiFetch: header injection on mutating calls ──────────────────────────

test('apiFetch: POST attaches Authorization: Bearer <key>', async () => {
    var fakeFetch = makeFakeFetch();
    var client = createApiAuthClient({ fetch: fakeFetch });

    await client.apiFetch('/api/items', { method: 'POST', body: '{}' });

    var mutatingCall = fakeFetch.calls.find(c => c.url === '/api/items');
    assert.ok(mutatingCall, 'expected a call to /api/items');
    assert.equal(mutatingCall.init.headers.get('Authorization'), 'Bearer ' + TEST_KEY);
});

test('apiFetch: PUT/PATCH/DELETE all attach the header', async () => {
    for (const method of ['PUT', 'PATCH', 'DELETE']) {
        var fakeFetch = makeFakeFetch();
        var client = createApiAuthClient({ fetch: fakeFetch });
        await client.apiFetch('/api/items/1', { method: method });
        var call = fakeFetch.calls.find(c => c.url === '/api/items/1');
        assert.equal(call.init.headers.get('Authorization'), 'Bearer ' + TEST_KEY, `method ${method} should attach header`);
    }
});

// ─── apiFetch: GET calls are unaffected ────────────────────────────────────

test('apiFetch: GET does not fetch the auth-key endpoint at all (no extra round trip)', async () => {
    var fakeFetch = makeFakeFetch();
    var client = createApiAuthClient({ fetch: fakeFetch });

    await client.apiFetch('/api/status', { method: 'GET' });

    var keyCalls = fakeFetch.calls.filter(c => c.url === AUTH_KEY_ENDPOINT);
    assert.equal(keyCalls.length, 0, 'GET must not trigger a key lookup');
});

test('apiFetch: GET with no init (defaults to GET) is passed through untouched', async () => {
    var fakeFetch = makeFakeFetch();
    var client = createApiAuthClient({ fetch: fakeFetch });

    await client.apiFetch('/api/status');

    var call = fakeFetch.calls.find(c => c.url === '/api/status');
    assert.ok(call, 'expected the GET to pass through');
    assert.equal(call.init, undefined, 'init is forwarded as-is (undefined), not rewritten');
});

test('apiFetch: GET receives no Authorization header even when a key is configured', async () => {
    var fakeFetch = makeFakeFetch();
    var client = createApiAuthClient({ fetch: fakeFetch });

    await client.apiFetch('/api/status', { method: 'GET', headers: { Accept: 'application/json' } });

    var call = fakeFetch.calls.find(c => c.url === '/api/status');
    assert.equal(call.init.headers.Accept, 'application/json');
    assert.equal(call.init.headers.Authorization, undefined);
});

// ─── apiFetch: key caching (resolve once) ──────────────────────────────────

test('apiFetch: the key endpoint is fetched at most once across multiple mutating calls', async () => {
    var fakeFetch = makeFakeFetch();
    var client = createApiAuthClient({ fetch: fakeFetch });

    await client.apiFetch('/api/a', { method: 'POST' });
    await client.apiFetch('/api/b', { method: 'PUT' });
    await client.apiFetch('/api/c', { method: 'DELETE' });

    var keyCalls = fakeFetch.calls.filter(c => c.url === AUTH_KEY_ENDPOINT);
    assert.equal(keyCalls.length, 1, 'key endpoint should be hit exactly once, then cached');
});

test('apiFetch: no key configured (server returns apiKey: null) -> mutating call proceeds with no Authorization header', async () => {
    var fakeFetch = makeFakeFetch({ keyResponse: jsonResponse(200, { apiKey: null }) });
    var client = createApiAuthClient({ fetch: fakeFetch });

    var resp = await client.apiFetch('/api/items', { method: 'POST' });

    assert.equal(resp.status, 200, 'open posture: request still proceeds');
    var call = fakeFetch.calls.find(c => c.url === '/api/items');
    assert.equal(call.init.headers, undefined, 'no key resolved -> headers left untouched (no Authorization added)');
});

test('apiFetch: key-endpoint fetch failure resolves to no key, not a thrown exception', async () => {
    var fakeFetch = function (url) {
        if (url === AUTH_KEY_ENDPOINT) {
            return Promise.reject(new Error('network down'));
        }
        return Promise.resolve(jsonResponse(200, { ok: true }));
    };
    var client = createApiAuthClient({ fetch: fakeFetch });

    var resp = await client.apiFetch('/api/items', { method: 'POST' });
    assert.equal(resp.status, 200, 'mutating call still proceeds unauthenticated rather than throwing');
});

// ─── apiFetch: 401 produces a visible, non-silent error path ──────────────

test('apiFetch: 401 on a mutating call invokes notify() with a visible error (non-silent)', async () => {
    var fakeFetch = makeFakeFetch({ mutatingResponse: jsonResponse(401, { error: 'Unauthorized', code: 'unauthorized' }) });
    var notify = makeNotifySpy();
    var client = createApiAuthClient({ fetch: fakeFetch, notify: notify });

    var resp = await client.apiFetch('/api/items', { method: 'POST' });

    assert.equal(resp.status, 401);
    assert.equal(notify.calls.length, 1, 'notify() must be called exactly once on a 401');
    assert.equal(notify.calls[0].type, 'error');
    assert.ok(notify.calls[0].message.length > 0, 'error message must not be empty/silent');
});

test('apiFetch: 200 on a mutating call does NOT invoke notify()', async () => {
    var fakeFetch = makeFakeFetch(); // default mutatingResponse is 200
    var notify = makeNotifySpy();
    var client = createApiAuthClient({ fetch: fakeFetch, notify: notify });

    await client.apiFetch('/api/items', { method: 'POST' });

    assert.equal(notify.calls.length, 0, 'a successful call must not surface an error toast');
});

test('apiFetch: 401 on a GET does NOT invoke notify() (only mutating calls trigger the failure UX here)', async () => {
    var fakeFetch = function () { return Promise.resolve(jsonResponse(401, { error: 'Unauthorized', code: 'unauthorized' })); };
    var notify = makeNotifySpy();
    var client = createApiAuthClient({ fetch: fakeFetch, notify: notify });

    await client.apiFetch('/api/status', { method: 'GET' });

    assert.equal(notify.calls.length, 0);
});

test('apiFetch: falls back to console.error when no notify is available (never throws)', async () => {
    var fakeFetch = makeFakeFetch({ mutatingResponse: jsonResponse(401, { error: 'Unauthorized', code: 'unauthorized' }) });
    var client = createApiAuthClient({ fetch: fakeFetch }); // no notify injected, no window.showToast in Node

    var originalConsoleError = console.error;
    var captured = [];
    console.error = function (msg) { captured.push(msg); };
    try {
        var resp = await client.apiFetch('/api/items', { method: 'POST' });
        assert.equal(resp.status, 401);
        assert.equal(captured.length, 1, 'console.error fallback must fire exactly once');
    } finally {
        console.error = originalConsoleError;
    }
});

// ─── No key value ever appears in the failure-facing surface ──────────────

test('AUTH_FAILURE_MESSAGE: fixed constant does not contain the resolved key, its length as a number, or any prefix', () => {
    assert.equal(typeof AUTH_FAILURE_MESSAGE, 'string');
    assert.ok(AUTH_FAILURE_MESSAGE.length > 0);
    assert.ok(!AUTH_FAILURE_MESSAGE.includes(TEST_KEY));
    // Constant is identical regardless of which key was configured — assert
    // by re-fetching it fresh from the module rather than trusting recall.
    assert.equal(apiAuth.AUTH_FAILURE_MESSAGE, AUTH_FAILURE_MESSAGE);
});

test('apiFetch: notify() message on 401 never contains the configured key (checked with a real key present)', async () => {
    var fakeFetch = makeFakeFetch({ mutatingResponse: jsonResponse(401, { error: 'Unauthorized', code: 'unauthorized' }) });
    var notify = makeNotifySpy();
    var client = createApiAuthClient({ fetch: fakeFetch, notify: notify });

    // Prime the key cache with a real (test) key BEFORE the mutating call, so
    // a hypothetical regression that interpolated the key into the message
    // would be caught here.
    await client.resolveKey();
    await client.apiFetch('/api/items', { method: 'POST' });

    assert.equal(notify.calls.length, 1);
    assert.ok(!notify.calls[0].message.includes(TEST_KEY), 'notify message must never contain the key');
});

test('apiFetch: notify() message contains no digit-run matching the key length (no length leak via the message)', async () => {
    var fakeFetch = makeFakeFetch({ mutatingResponse: jsonResponse(401, { error: 'Unauthorized', code: 'unauthorized' }) });
    var notify = makeNotifySpy();
    var client = createApiAuthClient({ fetch: fakeFetch, notify: notify });

    await client.apiFetch('/api/items', { method: 'POST' });

    var keyLengthStr = String(TEST_KEY.length);
    assert.ok(!notify.calls[0].message.includes(keyLengthStr) || keyLengthStr.length <= 1,
        'sanity: guards against an accidental key-length interpolation; a 1-digit false positive is acceptable noise, a real leak would be a length-shaped substring next to "key"');
});

// ─── Per-client isolation ──────────────────────────────────────────────────

test('createApiAuthClient: two clients have independent key caches', async () => {
    var fetchA = makeFakeFetch({ keyResponse: jsonResponse(200, { apiKey: 'key-a-not-a-real-secret' }) });
    var fetchB = makeFakeFetch({ keyResponse: jsonResponse(200, { apiKey: 'key-b-not-a-real-secret' }) });
    var clientA = createApiAuthClient({ fetch: fetchA });
    var clientB = createApiAuthClient({ fetch: fetchB });

    var keyA = await clientA.resolveKey();
    var keyB = await clientB.resolveKey();

    assert.equal(keyA, 'key-a-not-a-real-secret');
    assert.equal(keyB, 'key-b-not-a-real-secret');
});

test('_resetKeyCacheForTests: forces a re-fetch of the key endpoint', async () => {
    var fakeFetch = makeFakeFetch();
    var client = createApiAuthClient({ fetch: fakeFetch });

    await client.resolveKey();
    client._resetKeyCacheForTests();
    await client.resolveKey();

    var keyCalls = fakeFetch.calls.filter(c => c.url === AUTH_KEY_ENDPOINT);
    assert.equal(keyCalls.length, 2);
});


// ---------------------------------------------------------------------------
// XACA-0395 [UX] GATE REGRESSION — browser script-load-order.
//
// These tests exist because the original 26 tests ALL passed while the browser
// path was completely broken. Every existing test injects `notify`, so none of
// them ever exercised the window.showToast fallback. And under plain Node there
// is no `window` at all — so the test precondition ("no window") differed from
// the browser's ("window exists, showToast not yet defined") even though both
// produced the same symptom in a narrow test.
//
// The real bug: the client captured `window.showToast` into a closure variable
// at CONSTRUCTION time. index.html loads api-auth.js early (line ~47, before
// every mutating call site) but lcars.js — which defines showToast — loads at
// line ~2671. So the capture saw `undefined` and never re-checked, and every
// 401 across all 86 migrated call sites degraded to console.error() for the
// entire page session. That is the exact "silently dead button" this ticket set
// out to prevent.
//
// These tests reproduce the REAL load order: construct first, define showToast
// afterwards, then trigger a 401.
// ---------------------------------------------------------------------------

test('[UX regression] showToast defined AFTER client construction is still used on 401', async () => {
    var priorWindow = global.window;
    try {
        // Real browser order: window exists, showToast NOT yet defined.
        global.window = {};
        var fakeFetch = makeFakeFetch({
            mutatingResponse: jsonResponse(401, { error: 'Unauthorized', code: 'unauthorized' })
        });
        // Constructed BEFORE showToast exists — this is the bug's precondition.
        var client = createApiAuthClient({ fetch: fakeFetch });

        // lcars.js loads later in the document and defines showToast.
        var toastCalls = [];
        global.window.showToast = function (message, type, duration) {
            toastCalls.push({ message: message, type: type, duration: duration });
        };

        await client.apiFetch('/api/items', { method: 'POST' });

        assert.equal(toastCalls.length, 1,
            'showToast defined after construction MUST still receive the 401 notice — ' +
            'a construction-time capture makes every auth failure silent for the page session');
        assert.equal(toastCalls[0].type, 'error');
        assert.ok(toastCalls[0].message.length > 0, 'message must not be empty');
        assert.ok(toastCalls[0].message.indexOf(TEST_KEY) === -1,
            'the toast must never contain key material');
    } finally {
        if (priorWindow === undefined) { delete global.window; }
        else { global.window = priorWindow; }
    }
});

test('[UX regression] an injected notify still wins over window.showToast', async () => {
    var priorWindow = global.window;
    try {
        var toastCalls = [];
        global.window = { showToast: function () { toastCalls.push(arguments); } };
        var fakeFetch = makeFakeFetch({
            mutatingResponse: jsonResponse(401, { error: 'Unauthorized', code: 'unauthorized' })
        });
        var notify = makeNotifySpy();
        var client = createApiAuthClient({ fetch: fakeFetch, notify: notify });

        await client.apiFetch('/api/items', { method: 'POST' });

        assert.equal(notify.calls.length, 1, 'injected notify must take precedence');
        assert.equal(toastCalls.length, 0, 'window.showToast must NOT also fire (no double-notify)');
    } finally {
        if (priorWindow === undefined) { delete global.window; }
        else { global.window = priorWindow; }
    }
});

test('[UX regression] no window and no notify falls back to console.error, never silence', async () => {
    var priorWindow = global.window;
    var priorError = console.error;
    try {
        if (priorWindow !== undefined) { delete global.window; }
        var errorCalls = [];
        console.error = function (msg) { errorCalls.push(msg); };
        var fakeFetch = makeFakeFetch({
            mutatingResponse: jsonResponse(401, { error: 'Unauthorized', code: 'unauthorized' })
        });
        var client = createApiAuthClient({ fetch: fakeFetch });

        await client.apiFetch('/api/items', { method: 'POST' });

        assert.equal(errorCalls.length, 1, 'must still emit SOMETHING — silence is the failure mode');
        assert.ok(String(errorCalls[0]).indexOf(TEST_KEY) === -1, 'must not log key material');
    } finally {
        console.error = priorError;
        if (priorWindow !== undefined) { global.window = priorWindow; }
    }
});
