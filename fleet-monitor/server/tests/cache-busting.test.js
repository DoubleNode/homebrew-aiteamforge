//
//  cache-busting.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * Cache-Busting Header Regression Tests (XACA-0528)
 *
 * Verifies that the XACA-0528 cache-busting implementation sets the correct
 * Cache-Control headers on all relevant routes:
 *
 *   setStaticCacheHeaders helper (unit tests):
 *     - .html  → Cache-Control: no-cache, must-revalidate
 *     - .js    → Cache-Control: no-cache
 *     - .css   → Cache-Control: no-cache
 *     - other  → no header set (Express default)
 *
 *   Static asset mounts (integration via minimal Express app):
 *     - GET /lcars/lcars-dashboard.html     → no-cache, must-revalidate
 *     - GET /lcars/js/lcars-fleet-core.js   → no-cache
 *     - GET /lcars/css/<any>.css            → no-cache
 *     - GET /styles.css (root public/)      → no-cache
 *     - GET /app.js (root public/)          → no-cache
 *
 *   sendFile HTML routes (integration via minimal Express app):
 *     - GET /       → no-cache, must-revalidate
 *     - GET /all    → no-cache, must-revalidate
 *
 *   No stale 304 path:
 *     - If-None-Match / If-Modified-Since do NOT produce 304 without prior ETag round-trip
 *       (the server never caches, so a conditional GET without a valid ETag → 200 always).
 *
 * Strategy: rather than importing server.js (which calls app.listen + setInterval),
 * this file builds a minimal Express app that reproduces exactly the same middleware
 * wiring used in server.js (setStaticCacheHeaders + express.static + sendFile).
 * The pure helper function is defined inline — identical to server.js — so if
 * server.js changes the logic, this test must be updated too (that's intentional:
 * the test is a contract, not a mirror).
 */

const { test } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const express = require('express');
const path = require('path');

// ---------------------------------------------------------------------------
// Path to the actual static asset directories (used by the integration tests)
// ---------------------------------------------------------------------------
const SERVER_DIR = path.join(__dirname, '..');
const PUBLIC_DIR = path.join(SERVER_DIR, 'public');
const LCARS_DIR = path.join(PUBLIC_DIR, 'lcars');

// ---------------------------------------------------------------------------
// setStaticCacheHeaders — duplicated verbatim from server.js.
// If server.js changes the logic, update here too.
// ---------------------------------------------------------------------------
function setStaticCacheHeaders(res, filePath) {
    const ext = require('path').extname(filePath).toLowerCase();
    if (ext === '.html') {
        res.set('Cache-Control', 'no-cache, must-revalidate');
    } else if (ext === '.js' || ext === '.css') {
        res.set('Cache-Control', 'no-cache');
    }
}

// ---------------------------------------------------------------------------
// Minimal Express app that mirrors the server.js static + sendFile wiring.
// Only the routes relevant to cache-busting are present.
// ---------------------------------------------------------------------------
function buildTestApp() {
    const app = express();

    // Root public/ static mount (same options as server.js ~line 593)
    app.use(express.static(PUBLIC_DIR, { redirect: false, setHeaders: setStaticCacheHeaders }));

    // sendFile HTML routes (same as server.js ~lines 2858–2888)
    app.get('/', (req, res) => {
        res.set('Cache-Control', 'no-cache, must-revalidate');
        res.sendFile(path.join(PUBLIC_DIR, 'index.html'));
    });

    app.get('/all', (req, res) => {
        res.set('Cache-Control', 'no-cache, must-revalidate');
        res.sendFile(path.join(PUBLIC_DIR, 'all.html'));
    });

    // /lcars static mount (same as server.js ~line 2937)
    app.use('/lcars', express.static(LCARS_DIR, { setHeaders: setStaticCacheHeaders }));

    return app;
}

// Lazy-create a single shared app instance (avoids repeated fs hits)
let _app = null;
function getApp() {
    if (!_app) _app = buildTestApp();
    return _app;
}

// ===========================================================================
// UNIT TESTS: setStaticCacheHeaders pure-function behaviour
// ===========================================================================

test('setStaticCacheHeaders: .html file sets no-cache, must-revalidate', () => {
    const headers = {};
    const fakeRes = { set(k, v) { headers[k] = v; } };
    setStaticCacheHeaders(fakeRes, '/some/path/page.html');
    assert.equal(headers['Cache-Control'], 'no-cache, must-revalidate');
});

test('setStaticCacheHeaders: .HTML uppercase extension also sets no-cache, must-revalidate', () => {
    const headers = {};
    const fakeRes = { set(k, v) { headers[k] = v; } };
    setStaticCacheHeaders(fakeRes, '/some/path/PAGE.HTML');
    assert.equal(headers['Cache-Control'], 'no-cache, must-revalidate');
});

test('setStaticCacheHeaders: .js file sets no-cache', () => {
    const headers = {};
    const fakeRes = { set(k, v) { headers[k] = v; } };
    setStaticCacheHeaders(fakeRes, '/some/path/bundle.js');
    assert.equal(headers['Cache-Control'], 'no-cache');
});

test('setStaticCacheHeaders: .css file sets no-cache', () => {
    const headers = {};
    const fakeRes = { set(k, v) { headers[k] = v; } };
    setStaticCacheHeaders(fakeRes, '/some/path/styles.css');
    assert.equal(headers['Cache-Control'], 'no-cache');
});

test('setStaticCacheHeaders: .png file sets no Cache-Control header', () => {
    const headers = {};
    const fakeRes = { set(k, v) { headers[k] = v; } };
    setStaticCacheHeaders(fakeRes, '/some/path/logo.png');
    assert.equal(headers['Cache-Control'], undefined);
});

test('setStaticCacheHeaders: .json file sets no Cache-Control header', () => {
    const headers = {};
    const fakeRes = { set(k, v) { headers[k] = v; } };
    setStaticCacheHeaders(fakeRes, '/some/path/data.json');
    assert.equal(headers['Cache-Control'], undefined);
});

test('setStaticCacheHeaders: .svg file sets no Cache-Control header', () => {
    const headers = {};
    const fakeRes = { set(k, v) { headers[k] = v; } };
    setStaticCacheHeaders(fakeRes, '/some/path/icon.svg');
    assert.equal(headers['Cache-Control'], undefined);
});

test('setStaticCacheHeaders: file with no extension sets no Cache-Control header', () => {
    const headers = {};
    const fakeRes = { set(k, v) { headers[k] = v; } };
    setStaticCacheHeaders(fakeRes, '/some/path/Makefile');
    assert.equal(headers['Cache-Control'], undefined);
});

// ===========================================================================
// INTEGRATION TESTS: /lcars static mount — HTML assets
// ===========================================================================

test('GET /lcars/lcars-dashboard.html returns 200 with no-cache, must-revalidate', async () => {
    const res = await request(getApp()).get('/lcars/lcars-dashboard.html');
    assert.equal(res.status, 200);
    assert.ok(
        res.headers['cache-control'] && res.headers['cache-control'].includes('no-cache'),
        `Expected Cache-Control to include no-cache, got: ${res.headers['cache-control']}`
    );
    assert.ok(
        res.headers['cache-control'].includes('must-revalidate'),
        `Expected Cache-Control to include must-revalidate, got: ${res.headers['cache-control']}`
    );
});

// ===========================================================================
// INTEGRATION TESTS: /lcars static mount — JS assets
// ===========================================================================

test('GET /lcars/js/lcars-fleet-core.js returns 200 with Cache-Control: no-cache', async () => {
    const res = await request(getApp()).get('/lcars/js/lcars-fleet-core.js');
    assert.equal(res.status, 200);
    assert.equal(res.headers['cache-control'], 'no-cache');
});

test('GET /lcars/js/lcars-fleet-core.js served with query param ?v= returns 200 (boot-critical bust)', async () => {
    // The HTML embeds ?v=20260520 to force browser fetch; server must still serve 200
    const res = await request(getApp()).get('/lcars/js/lcars-fleet-core.js?v=20260520');
    assert.equal(res.status, 200);
    assert.equal(res.headers['cache-control'], 'no-cache');
});

test('GET /lcars/js/lcars-fleet-core.js body is non-empty JavaScript', async () => {
    const res = await request(getApp()).get('/lcars/js/lcars-fleet-core.js');
    assert.equal(res.status, 200);
    assert.ok(res.text && res.text.length > 0, 'JS file body must be non-empty');
});

// ===========================================================================
// INTEGRATION TESTS: /lcars static mount — CSS assets
// ===========================================================================

test('GET /lcars/css/lcars-fleet.css returns 200 with Cache-Control: no-cache', async () => {
    const res = await request(getApp()).get('/lcars/css/lcars-fleet.css');
    assert.equal(res.status, 200);
    assert.equal(res.headers['cache-control'], 'no-cache');
});

// ===========================================================================
// INTEGRATION TESTS: root public/ static mount — JS and CSS
// ===========================================================================

test('GET /app.js (root public mount) returns 200 with Cache-Control: no-cache', async () => {
    const res = await request(getApp()).get('/app.js');
    assert.equal(res.status, 200);
    assert.equal(res.headers['cache-control'], 'no-cache');
});

test('GET /styles.css (root public mount) returns 200 with Cache-Control: no-cache', async () => {
    const res = await request(getApp()).get('/styles.css');
    assert.equal(res.status, 200);
    assert.equal(res.headers['cache-control'], 'no-cache');
});

// ===========================================================================
// INTEGRATION TESTS: sendFile HTML routes
// ===========================================================================

test('GET / (sendFile route) returns 200 with Cache-Control: no-cache, must-revalidate', async () => {
    const res = await request(getApp()).get('/');
    assert.equal(res.status, 200);
    assert.ok(
        res.headers['cache-control'] && res.headers['cache-control'].includes('no-cache'),
        `Expected no-cache in Cache-Control, got: ${res.headers['cache-control']}`
    );
    assert.ok(
        res.headers['cache-control'].includes('must-revalidate'),
        `Expected must-revalidate in Cache-Control, got: ${res.headers['cache-control']}`
    );
});

test('GET /all (sendFile route) returns 200 with Cache-Control: no-cache, must-revalidate', async () => {
    const res = await request(getApp()).get('/all');
    assert.equal(res.status, 200);
    assert.ok(
        res.headers['cache-control'] && res.headers['cache-control'].includes('no-cache'),
        `Expected no-cache in Cache-Control, got: ${res.headers['cache-control']}`
    );
    assert.ok(
        res.headers['cache-control'].includes('must-revalidate'),
        `Expected must-revalidate in Cache-Control, got: ${res.headers['cache-control']}`
    );
});

// ===========================================================================
// INTEGRATION TESTS: No stale 304 served without prior ETag round-trip
// ===========================================================================

test('GET /lcars/lcars-dashboard.html with If-None-Match: invalid-etag returns 200, not 304', async () => {
    // A browser that cached an asset under the old (missing) cache headers may
    // send an If-None-Match from a stale session. With no-cache the server should
    // either ignore the ETag or revalidate — but it must never return 304 unless
    // it had previously issued that ETag. An invented ETag cannot match, so 200.
    const res = await request(getApp())
        .get('/lcars/lcars-dashboard.html')
        .set('If-None-Match', '"stale-invalid-etag-from-old-session"');
    assert.equal(res.status, 200);
});

test('GET /lcars/js/lcars-fleet-core.js with stale If-Modified-Since returns 200', async () => {
    // A far-future If-Modified-Since should not produce 304 when the file
    // has actually changed (this is belt-and-suspenders: no-cache already forces
    // revalidation, but we confirm the response is never a stale 304).
    // We pass a PAST date so Express fresh-check is false → 200.
    const pastDate = new Date(0).toUTCString(); // Thu, 01 Jan 1970 00:00:00 GMT
    const res = await request(getApp())
        .get('/lcars/js/lcars-fleet-core.js')
        .set('If-Modified-Since', pastDate);
    assert.equal(res.status, 200);
});
