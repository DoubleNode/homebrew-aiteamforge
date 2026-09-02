//
//  xaca-1030-001-manifest-route.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * Per-Dashboard Web App Manifest Route Tests (XACA-1030-001)
 *
 * Bug: public/appicons/fleet.webmanifest is ONE static file with
 * `start_url` hardcoded to the Academy dashboard, and all 16 dashboard HTML
 * pages link it. iOS 16.4+ reads `start_url` from the manifest at
 * Add-to-Home-Screen time, so a bookmark created from any OTHER dashboard
 * (e.g. ALL FLEET) silently opens Academy instead.
 *
 * Fix: GET /appicons/fleet.webmanifest?dashboard=<id>&ui=<root|lcars|lcars2>
 * registered in server.js BEFORE the express.static(public) mount, so it
 * SHADOWS the static file for this exact path and computes start_url/name/
 * short_name from validated query params instead.
 *
 * ── Why this file builds its own minimal Express app instead of requiring
 *    server.js or using tests/helpers/app-factory.js's createApp() ────────
 * server.js has no module.exports and calls app.listen() unconditionally at
 * import time (see every other suite in this directory's header comment on
 * why they use app-factory.js's createApp() mirror instead of require()-ing
 * server.js directly). app-factory.js's mirror does not include this route
 * or the root public/ static mount. Following the SAME pattern already
 * established by tests/cache-busting.test.js ("rather than importing
 * server.js ... this file builds a minimal Express app that reproduces
 * exactly the same middleware wiring used in server.js"), this file
 * duplicates ONLY the two pieces of wiring relevant to the shadowing bug
 * this ticket exists to prevent regressing:
 *   1. the manifest route handler, copied verbatim from server.js
 *   2. the express.static(public) mount, registered AFTER it -- same order
 *      as server.js (server.js:727 route, server.js:789 static mount)
 * If server.js's route logic changes, this duplicate must be updated too
 * (that's intentional -- the test is a contract, not a mirror, same as
 * cache-busting.test.js's convention).
 *
 * This suite also hits the REAL public/appicons/fleet.webmanifest static
 * file and the REAL data/dashboards.json on disk (no fixtures/mocks for
 * either) so the "route shadows the static file" proof is against the
 * actual shipped static file, not a stand-in.
 */

const { test } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const express = require('express');
const path = require('path');
const fs = require('fs');

const SERVER_DIR = path.join(__dirname, '..');
const PUBLIC_DIR = path.join(SERVER_DIR, 'public');
const DASHBOARDS_FILE = path.join(SERVER_DIR, 'data', 'dashboards.json');
const STATIC_MANIFEST_FILE = path.join(PUBLIC_DIR, 'appicons', 'fleet.webmanifest');

// ---------------------------------------------------------------------------
// Route logic -- duplicated verbatim from server.js (see file header).
// ---------------------------------------------------------------------------
function loadDashboardConfig() {
    try {
        if (fs.existsSync(DASHBOARDS_FILE)) {
            return JSON.parse(fs.readFileSync(DASHBOARDS_FILE, 'utf8'));
        }
    } catch (error) {
        console.error('Error loading dashboard config:', error.message);
    }
    return { dashboards: [], divisions: [], meta: { version: '1.0.0' } };
}

const MANIFEST_LCARS2_PATHS = {
    academy: '/lcars2/lcars-index.html',
    mainevent: '/lcars2/lcars-mainevent.html',
    doublenode: '/lcars2/lcars-doublenode.html',
    all: '/lcars2/lcars-all.html',
};

const MANIFEST_VALID_UI = new Set(['root', 'lcars', 'lcars2']);
const MANIFEST_DEFAULT_DASHBOARD = 'academy';
const MANIFEST_DEFAULT_UI = 'lcars';
const MANIFEST_SHORT_NAME_MAX_LEN = 12;

function manifestRouteHandler(req, res) {
    const config = loadDashboardConfig();
    const dashboards = config.dashboards || [];
    const validIds = new Set(dashboards.map((d) => d.id));

    const rawDashboard = typeof req.query.dashboard === 'string' ? req.query.dashboard : '';
    const dashboardId = validIds.has(rawDashboard) ? rawDashboard : MANIFEST_DEFAULT_DASHBOARD;

    const rawUi = typeof req.query.ui === 'string' ? req.query.ui : '';
    const ui = MANIFEST_VALID_UI.has(rawUi) ? rawUi : MANIFEST_DEFAULT_UI;

    let startUrl;
    let name;
    let shortName;

    if (ui === 'root') {
        startUrl = '/';
        name = 'Fleet Monitor';
        shortName = 'Fleet';
    } else {
        const dashboardEntry = dashboards.find((d) => d.id === dashboardId);
        name = (dashboardEntry && dashboardEntry.name) || 'Academy';

        if (ui === 'lcars2' && MANIFEST_LCARS2_PATHS[dashboardId]) {
            startUrl = MANIFEST_LCARS2_PATHS[dashboardId];
        } else {
            startUrl = `/lcars/lcars-dashboard.html?dashboard=${dashboardId}`;
        }

        shortName = name.slice(0, MANIFEST_SHORT_NAME_MAX_LEN);
    }

    const manifest = {
        name,
        short_name: shortName,
        start_url: startUrl,
        scope: '/',
        display: 'standalone',
        background_color: '#000000',
        theme_color: '#000000',
        icons: [
            { src: '/appicons/icon-192.png', sizes: '192x192', type: 'image/png' },
            { src: '/appicons/icon-512.png', sizes: '512x512', type: 'image/png' },
            { src: '/appicons/icon-maskable-512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' },
        ],
    };

    res.set('Content-Type', 'application/manifest+json');
    res.set('Cache-Control', 'public, max-age=0, must-revalidate');
    res.json(manifest);
}

// ---------------------------------------------------------------------------
// Two apps: one with the CORRECT registration order (route before static --
// what server.js actually does), one with the order flipped (static before
// route). The flipped app exists ONLY to prove that registration order is
// what makes the correct app work -- see the "shadowing" test group below.
// ---------------------------------------------------------------------------
function buildAppRouteFirst() {
    const app = express();
    app.get('/appicons/fleet.webmanifest', manifestRouteHandler);
    app.use(express.static(PUBLIC_DIR, { redirect: false }));
    return app;
}

function buildAppStaticFirst() {
    const app = express();
    app.use(express.static(PUBLIC_DIR, { redirect: false }));
    app.get('/appicons/fleet.webmanifest', manifestRouteHandler);
    return app;
}

let _routeFirstApp = null;
function getRouteFirstApp() {
    if (!_routeFirstApp) _routeFirstApp = buildAppRouteFirst();
    return _routeFirstApp;
}

let _staticFirstApp = null;
function getStaticFirstApp() {
    if (!_staticFirstApp) _staticFirstApp = buildAppStaticFirst();
    return _staticFirstApp;
}

// Sanity: the real dashboards.json actually has the 5 ids this suite
// exercises against, so a future removal of one fails loudly here instead
// of these tests quietly asserting against dashboards that no longer exist.
const REAL_DASHBOARD_IDS = new Set(
    (loadDashboardConfig().dashboards || []).map((d) => d.id)
);
for (const id of ['academy', 'mainevent', 'doublenode', 'finance', 'all']) {
    assert.ok(REAL_DASHBOARD_IDS.has(id), `expected dashboards.json to contain id "${id}"`);
}

// ============================================================================
// CONTRACT TESTS (against the correctly-ordered app -- matches server.js)
// ============================================================================

test('dashboard=all, ui=lcars -> lcars form + "All Fleet" name/short_name', async () => {
    const res = await request(getRouteFirstApp()).get('/appicons/fleet.webmanifest?dashboard=all&ui=lcars');
    assert.equal(res.status, 200);
    assert.equal(res.headers['content-type'], 'application/manifest+json; charset=utf-8');
    assert.equal(res.body.start_url, '/lcars/lcars-dashboard.html?dashboard=all');
    assert.equal(res.body.name, 'All Fleet');
    assert.equal(res.body.short_name, 'All Fleet');
    assert.equal(res.body.scope, '/');
});

test('dashboard=all, ui=lcars2 -> irregular lcars2 filename map', async () => {
    const res = await request(getRouteFirstApp()).get('/appicons/fleet.webmanifest?dashboard=all&ui=lcars2');
    assert.equal(res.status, 200);
    assert.equal(res.body.start_url, '/lcars2/lcars-all.html');
});

test('dashboard=academy, ui=lcars2 -> lcars-index.html (the irregular one)', async () => {
    const res = await request(getRouteFirstApp()).get('/appicons/fleet.webmanifest?dashboard=academy&ui=lcars2');
    assert.equal(res.status, 200);
    assert.equal(res.body.start_url, '/lcars2/lcars-index.html');
});

test('dashboard=finance, ui=lcars2 -> falls back to lcars form (no lcars2 page exists)', async () => {
    const res = await request(getRouteFirstApp()).get('/appicons/fleet.webmanifest?dashboard=finance&ui=lcars2');
    assert.equal(res.status, 200);
    assert.equal(res.body.start_url, '/lcars/lcars-dashboard.html?dashboard=finance');
    assert.equal(res.body.name, 'Finance');
});

test('ui=root -> "/" start_url, "Fleet Monitor"/"Fleet" name, dashboard ignored', async () => {
    const res = await request(getRouteFirstApp()).get('/appicons/fleet.webmanifest?ui=root&dashboard=mainevent');
    assert.equal(res.status, 200);
    assert.equal(res.body.start_url, '/');
    assert.equal(res.body.name, 'Fleet Monitor');
    assert.equal(res.body.short_name, 'Fleet');
});

test('no query at all -> preserves today\'s pre-existing academy default behavior', async () => {
    const res = await request(getRouteFirstApp()).get('/appicons/fleet.webmanifest');
    assert.equal(res.status, 200);
    assert.equal(res.body.start_url, '/lcars/lcars-dashboard.html?dashboard=academy');
    assert.equal(res.body.name, 'Academy');
    assert.equal(res.body.short_name, 'Academy');
});

// ============================================================================
// FALLBACK + INJECTION TESTS
// ============================================================================

test('unknown dashboard id falls back to academy default', async () => {
    const res = await request(getRouteFirstApp()).get('/appicons/fleet.webmanifest?dashboard=not-a-real-team&ui=lcars');
    assert.equal(res.status, 200);
    assert.equal(res.body.start_url, '/lcars/lcars-dashboard.html?dashboard=academy');
    assert.equal(res.body.name, 'Academy');
});

test('unknown ui falls back to lcars default', async () => {
    const res = await request(getRouteFirstApp()).get('/appicons/fleet.webmanifest?dashboard=all&ui=bogus');
    assert.equal(res.status, 200);
    assert.equal(res.body.start_url, '/lcars/lcars-dashboard.html?dashboard=all');
});

test('path-traversal payload in dashboard falls back to academy and never appears in the response body', async () => {
    const res = await request(getRouteFirstApp())
        .get('/appicons/fleet.webmanifest')
        .query({ dashboard: '../../etc/passwd', ui: 'lcars' });
    assert.equal(res.status, 200);
    assert.equal(res.body.start_url, '/lcars/lcars-dashboard.html?dashboard=academy');
    const raw = JSON.stringify(res.body);
    assert.ok(!raw.includes('etc/passwd'), 'response body must never echo the raw query value');
    assert.ok(!raw.includes('..'), 'response body must never echo the raw query value');
});

test('script-injection payload in dashboard falls back to academy and never appears in the response body', async () => {
    const res = await request(getRouteFirstApp())
        .get('/appicons/fleet.webmanifest')
        .query({ dashboard: '<script>alert(1)</script>' });
    assert.equal(res.status, 200);
    assert.equal(res.body.start_url, '/lcars/lcars-dashboard.html?dashboard=academy');
    const raw = JSON.stringify(res.body);
    assert.ok(!raw.includes('script'), 'response body must never echo the raw query value');
    assert.ok(!raw.includes('alert'), 'response body must never echo the raw query value');
});

test('array-form dashboard query param (malformed, not a string) falls back to academy', async () => {
    const res = await request(getRouteFirstApp()).get('/appicons/fleet.webmanifest?dashboard[]=all&dashboard[]=academy');
    assert.equal(res.status, 200);
    assert.equal(res.body.start_url, '/lcars/lcars-dashboard.html?dashboard=academy');
});

// ============================================================================
// SHADOWING PROOF -- the point of this whole ticket
// ============================================================================
//
// A passing contract test above tells us nothing about registration order:
// if the static file happened to already contain today's academy default,
// the SAME assertions could pass whether the route or the static file
// answered the "no query" and "unknown dashboard" cases. These tests prove
// the route -- not the static file -- is the one responding, two
// independent ways:
//
//   (a) query-string variance: the static file is a fixed file on disk: it
//       cannot possibly vary its response by query string. A response that
//       DOES vary by query string could only have come from the route.
//   (b) structural marker: the static file (captured in this suite) has NO
//       "scope" key at all. Every route response includes "scope". Any
//       response with a "scope" key did not come from the static file.
//   (c) direct order-flip: building a second app with the identical route
//       handler registered AFTER express.static (buildAppStaticFirst)
//       reproduces the ORIGINAL bug -- proving order is what makes the
//       correctly-ordered app work, not something else entirely.

test('shadowing proof (a): response varies by query string -- the static file cannot do this', async () => {
    const app = getRouteFirstApp();
    const rootRes = await request(app).get('/appicons/fleet.webmanifest?ui=root');
    const noQueryRes = await request(app).get('/appicons/fleet.webmanifest');
    assert.notEqual(rootRes.body.start_url, noQueryRes.body.start_url);
    assert.equal(rootRes.body.start_url, '/');
    assert.equal(noQueryRes.body.start_url, '/lcars/lcars-dashboard.html?dashboard=academy');
});

test('shadowing proof (b): static file has no "scope" key; every route response does', async () => {
    const staticRaw = fs.readFileSync(STATIC_MANIFEST_FILE, 'utf8');
    const staticJson = JSON.parse(staticRaw);
    assert.equal(Object.prototype.hasOwnProperty.call(staticJson, 'scope'), false,
        'test assumption broken: static file now has a scope key -- update this proof');

    const res = await request(getRouteFirstApp()).get('/appicons/fleet.webmanifest');
    assert.equal(res.body.scope, '/');
});

test('shadowing proof (c): with the SAME handler registered AFTER express.static, the static file wins and the bug reproduces', async () => {
    const app = getStaticFirstApp();
    const res = await request(app).get('/appicons/fleet.webmanifest?ui=root');
    assert.equal(res.status, 200);
    // If the route were answering, ui=root would give start_url "/". Because
    // the static mount is registered FIRST in this deliberately-flipped app,
    // Express serves the static file instead, which ignores the query
    // string entirely and always returns the hardcoded academy start_url --
    // reproducing the exact XACA-1030 bug this ticket fixes.
    assert.equal(res.body.start_url, '/lcars/lcars-dashboard.html?dashboard=academy');
    assert.equal(Object.prototype.hasOwnProperty.call(res.body, 'scope'), false);
});

test('static file is still present on disk (deliberate belt-and-braces fallback, not deleted)', () => {
    assert.ok(fs.existsSync(STATIC_MANIFEST_FILE), 'public/appicons/fleet.webmanifest must remain in place');
});

// ============================================================================
// XACA-1030 gate round: shadowing proof (d) -- the ONLY one that reads the
// production file.
//
// Proofs (a), (b) and (c) above exercise a handler COPIED into this file and
// apps BUILT in this file. They demonstrate that route-before-static is the
// correct ordering, but they cannot detect a regression in server.js: the
// code review for PR #806 deleted server.js outright, re-ran this suite, and
// still got 15/15. A test that runs against a copy of the code is the same
// failure class as a test that never runs -- which is exactly the defect this
// ticket already hit twice at the CI-registration layer, reproduced one layer
// down inside the thing that was supposed to guard it.
//
// This case asserts source order in the REAL server.js. It is deliberately a
// textual check rather than an import: server.js has no module.exports and
// calls app.listen() at import time, so requiring it here would bind a port.
//
// The indexOf !== -1 guards are load-bearing. Without them a rename makes
// both lookups return -1, and `-1 < -1` is false... but `routeAt < staticAt`
// with only ONE found silently inverts into a pass (e.g. routeAt = -1 against
// a real staticAt is trivially "before" it). Not finding a marker must FAIL,
// not quietly succeed -- an absent marker means this guard has stopped
// guarding anything, which is precisely the state it exists to detect.
// ============================================================================
test('shadowing proof (d): server.js itself registers the route BEFORE express.static(public)', () => {
    const SERVER_JS = path.join(SERVER_DIR, 'server.js');
    assert.ok(fs.existsSync(SERVER_JS), 'server.js must exist -- this guard is meaningless without it');
    const src = fs.readFileSync(SERVER_JS, 'utf8');

    const routeAt = src.indexOf("app.get('/appicons/fleet.webmanifest'");
    const staticAt = src.indexOf("app.use(express.static(path.join(__dirname, 'public')");

    assert.notEqual(routeAt, -1,
        "could not find the manifest route registration in server.js -- if it was renamed, update this guard IN THE SAME DIFF; a marker this guard cannot find is a guard that has silently stopped working");
    assert.notEqual(staticAt, -1,
        "could not find the express.static(public) mount in server.js -- same rule as above");
    assert.ok(routeAt < staticAt,
        `server.js registers express.static(public) at index ${staticAt} BEFORE the manifest route at index ${routeAt}. The static file then shadows the route and every Add-to-Home-Screen bookmark launches Academy again -- the exact XACA-1030 defect.`);
});
