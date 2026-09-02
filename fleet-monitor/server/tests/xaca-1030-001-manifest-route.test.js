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

const { test, describe, before, after } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const express = require('express');
const path = require('path');
const fs = require('fs');
const net = require('node:net');
const { spawn } = require('child_process');

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

        if (ui === 'lcars2' && Object.prototype.hasOwnProperty.call(MANIFEST_LCARS2_PATHS, dashboardId)) {
            startUrl = MANIFEST_LCARS2_PATHS[dashboardId];
        } else {
            startUrl = `/lcars/lcars-dashboard.html?dashboard=${dashboardId}`;
        }

        shortName = name.slice(0, MANIFEST_SHORT_NAME_MAX_LEN).trim();
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

// ============================================================================
// XACA-1030-018 / -019 / -022: gate-round review findings.
// ============================================================================

test('XACA-1030-019: the lcars2 path map is not a bare object index (constructor/__proto__ cannot resolve)', () => {
    // dashboardId is gated by validIds, but those ids come from dashboards.json.
    // A dashboard whose id is 'constructor' would, under a bare index, resolve
    // through Object.prototype to a FUNCTION and be emitted as start_url.
    const SERVER_JS = path.join(SERVER_DIR, 'server.js');
    const src = fs.readFileSync(SERVER_JS, 'utf8');
    assert.ok(
        src.includes('Object.prototype.hasOwnProperty.call(MANIFEST_LCARS2_PATHS, dashboardId)'),
        'MANIFEST_LCARS2_PATHS must be probed with hasOwnProperty, not a bare index'
    );
    assert.ok(
        !/if \(ui === 'lcars2' && MANIFEST_LCARS2_PATHS\[dashboardId\]\)/.test(src),
        'the bare-index form must not have come back'
    );
});

test('XACA-1030-018: short_name is trimmed after the length cap', () => {
    const SERVER_JS = path.join(SERVER_DIR, 'server.js');
    const src = fs.readFileSync(SERVER_JS, 'utf8');
    assert.ok(
        src.includes('name.slice(0, MANIFEST_SHORT_NAME_MAX_LEN).trim()'),
        'short_name must be trimmed after slicing, or a name cut on a space leaves a trailing gap in the home-screen label'
    );
    // Demonstrate the case the trim exists for: 'Academy Ops Center' cuts to
    // 'Academy Ops ' at 12 chars -- a trailing space that renders as a gap.
    const MAX = 12;
    assert.equal('Academy Ops Center'.slice(0, MAX), 'Academy Ops ');
    assert.equal('Academy Ops Center'.slice(0, MAX).trim(), 'Academy Ops');
});

test('XACA-1030-022: the handler copied into this file has not diverged from server.js', () => {
    // This suite duplicates manifestRouteHandler rather than importing it
    // (server.js has no module.exports and calls app.listen() at import time).
    // The copy can silently drift from the original, which would make every
    // contract test in this file assert against code that is not what ships.
    //
    // THIS GUARD HAS BEEN DEFEATED TWICE. Both failures are worth recording,
    // because both looked correct:
    //
    //   v1 pinned three CONSTANTS (the lcars2 map, the short_name cap, the
    //   default dashboard) and nothing else. It passed green while the copy
    //   still carried the pre-fix bare index and un-trimmed slice that the
    //   review round had just changed in server.js -- the exact divergence it
    //   is named for, sitting undetected inside the detector.
    //
    //   v2 pinned those two LOGIC lines as string markers, searched for in
    //   `readFileSync(__filename)`. But the markers are string literals in
    //   THIS function, so `selfSrc.includes(marker)` matched the guard's own
    //   source and could never fail. Its companion banned-form check, which
    //   pinned exact spellings, was dodged by inserting one space.
    //
    // Both failures share a root cause: matching TEXT somewhere in a FILE.
    // v3 stops doing that. It extracts the two handler bodies, normalises
    // them, and compares them whole -- so any drift fails, not only the
    // spellings someone thought to enumerate, and the guard's own source is
    // never in the searched region.
    const serverSrc = fs.readFileSync(path.join(SERVER_DIR, 'server.js'), 'utf8');
    const selfSrc = fs.readFileSync(__filename, 'utf8');

    // Extract the {...} body that begins at the first '{' at or after `from`.
    // Template-literal ${...} spans balance correctly under a brace count, so
    // they need no special handling here.
    function balancedBody(src, from, label) {
        const open = src.indexOf('{', from);
        assert.notEqual(open, -1, `could not find the opening brace of ${label}`);
        let depth = 0;
        for (let i = open; i < src.length; i++) {
            if (src[i] === '{') depth++;
            else if (src[i] === '}') {
                depth--;
                if (depth === 0) return src.slice(open + 1, i);
            }
        }
        throw new Error(`unbalanced braces while extracting ${label}`);
    }

    function normalise(body) {
        return body
            .replace(/\/\*[\s\S]*?\*\//g, ' ')   // block comments
            .replace(/^\s*\/\/.*$/gm, ' ')       // line comments
            .replace(/\s+/g, ' ')                // all whitespace runs -> one space
            .trim();
    }

    const serverAnchor = serverSrc.indexOf("app.get('/appicons/fleet.webmanifest'");
    assert.notEqual(serverAnchor, -1,
        'could not find the manifest route registration in server.js -- if it was renamed, update this guard IN THE SAME DIFF');
    const selfAnchor = selfSrc.indexOf('function manifestRouteHandler(req, res)');
    assert.notEqual(selfAnchor, -1,
        "could not find this file's copy of manifestRouteHandler");

    const shipped = normalise(balancedBody(serverSrc, serverAnchor, 'the server.js route handler'));
    const copied = normalise(balancedBody(selfSrc, selfAnchor, "this file's manifestRouteHandler"));

    assert.ok(shipped.length > 200, 'extracted server.js handler body is implausibly short -- the extraction is wrong, not the code');

    if (shipped !== copied) {
        // Point at the first divergence rather than dumping two long strings.
        let i = 0;
        while (i < Math.min(shipped.length, copied.length) && shipped[i] === copied[i]) i++;
        const ctx = 90;
        assert.fail(
            "this file's COPY of the handler has diverged from server.js, so every contract test in this file is asserting against code that is not what ships.\n" +
            `  first difference at normalised offset ${i}\n` +
            `  server.js: ...${shipped.slice(Math.max(0, i - ctx), i + ctx)}...\n` +
            `  this file: ...${copied.slice(Math.max(0, i - ctx), i + ctx)}...`
        );
    }
});

// ============================================================================
// XACA-1030 gate round 2: shadowing proof (e) -- the REAL server, over HTTP.
//
// Proof (d) asserts SOURCE order in server.js: the route registration's
// indexOf precedes the express.static mount's. The code review defeated it
// with an ordinary refactor -- wrap the route in
// `function registerManifestRoute(app) { ... }` DEFINED above the static
// mount and INVOKED below it. Both markers are still found, source order
// still holds, the suite still passes -- and a live server on that build
// serves the static file again, with the original bug fully restored.
//
// Source order was a proxy for REGISTRATION order, and the two came apart.
// This section removes the proxy: it boots the actual server.js as a child
// process on an ephemeral port and asks it over HTTP. There is no textual
// stand-in left to defeat -- whatever Express actually ends up with is what
// gets asserted.
//
// Proof (d) is kept, not replaced: it fails fast and with a precise message
// on a rename, a deletion, or a move into a Router, and costs no spawn. This
// section covers what it structurally cannot.
//
// The spawn + getFreePort + waitForReady + SIGTERM teardown shape follows
// tests/xaca-0395-005-auth-wiring.test.js's own "live server" section, rather
// than inventing a second convention in the same directory.
// ============================================================================
describe('shadowing proof (e): the real server.js answers the manifest route (live HTTP)', () => {
    const STARTUP_TIMEOUT_MS = 20000;
    const POLL_INTERVAL_MS = 200;

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
        const childEnv = Object.assign({}, process.env, {
            PORT: String(port),
            FLEET_REQUIRE_AUTH: '0',
        });
        child = spawn(process.execPath, ['server.js'], {
            cwd: SERVER_DIR,
            env: childEnv,
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

    test('the ROUTE answers, not the static file -- scope is present and start_url varies by query', async () => {
        // The static public/appicons/fleet.webmanifest is a fixed document with
        // no "scope" key and a hardcoded academy start_url. It cannot vary by
        // query string. Both properties holding at once is what proves Express
        // resolved to the route rather than to the file.
        const rootRes = await fetch(`${baseUrl}/appicons/fleet.webmanifest?ui=root`);
        assert.equal(rootRes.status, 200);
        const root = await rootRes.json();
        assert.equal(root.start_url, '/', 'ui=root must give the site root -- the static file cannot');
        assert.ok(Object.prototype.hasOwnProperty.call(root, 'scope'),
            'no "scope" key: the STATIC file answered, so express.static is mounted ahead of the route and XACA-1030 is live again');

        const allRes = await fetch(`${baseUrl}/appicons/fleet.webmanifest?dashboard=all&ui=lcars2`);
        const all = await allRes.json();
        assert.equal(all.start_url, '/lcars2/lcars-all.html');
        assert.notEqual(root.start_url, all.start_url,
            'the response did not vary by query string, which is what a static file does');
    });

    test('the SHIPPED handler rejects prototype-shaped ids at the validIds gate (defence layer 1 of 2)', async () => {
        // Honest scope note. This does NOT exercise the -019 hasOwnProperty
        // fix. A prototype-shaped id never reaches MANIFEST_LCARS2_PATHS,
        // because validIds (built from dashboards.json) rejects it first and
        // dashboardId falls back to academy. -019's fix guards the case where
        // dashboards.json ITSELF contains such an id, which cannot be produced
        // over HTTP without editing that file -- the textual guard above
        // covers that layer. What this asserts is that layer 1 holds and that
        // nothing prototype-shaped reaches the response body.
        //
        // The expected value is deliberately the lcars2 form: the id falls back
        // to academy, and academy on ui=lcars2 is lcars-index.html, NOT the
        // lcars form. An earlier draft asserted the lcars form and failed --
        // against correct shipped behaviour.
        for (const hostile of ['constructor', '__proto__', 'toString', 'hasOwnProperty']) {
            const res = await fetch(`${baseUrl}/appicons/fleet.webmanifest?dashboard=${encodeURIComponent(hostile)}&ui=lcars2`);
            assert.equal(res.status, 200, `${hostile} did not return 200`);
            const body = await res.json();
            assert.equal(body.start_url, '/lcars2/lcars-index.html',
                `dashboard=${hostile} must fall back to academy on the lcars2 ui`);
            assert.equal(typeof body.start_url, 'string', `${hostile} produced a non-string start_url`);
            const serialized = JSON.stringify(body);
            assert.ok(!/function|\[native code\]/.test(serialized),
                `a prototype member leaked into the manifest body for ${hostile}`);
            assert.ok(!serialized.includes(hostile),
                `the ${hostile} payload was echoed into the response body`);
        }
    });

    test('the SHIPPED handler still serves the no-query academy default and the right content-type', async () => {
        const res = await fetch(`${baseUrl}/appicons/fleet.webmanifest`);
        const body = await res.json();
        assert.equal(body.start_url, '/lcars/lcars-dashboard.html?dashboard=academy');
        assert.ok((res.headers.get('content-type') || '').startsWith('application/manifest+json'));
    });
});
