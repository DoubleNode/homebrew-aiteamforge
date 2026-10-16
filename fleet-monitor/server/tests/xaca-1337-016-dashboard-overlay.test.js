'use strict';
/**
 * XACA-1337-016: per-machine dashboards overlay.
 *
 * Client-specific divisions (freelance-<client>-<project>) left the SHIPPED
 * data/dashboards.json; a machine hosting them keeps them in
 * ~/.aiteamforge/dashboards.local.json ($FLEET_DASHBOARDS_LOCAL_FILE), merged
 * by lib/dashboard-overlay.js inside server.js's loadDashboardConfig().
 *
 * Unit tests cover the lib (absent / valid / collision / malformed / split).
 * The integration block spawns the REAL server.js from a SANDBOX copy of the
 * server dir (server.js copied; lib/public/config/node_modules symlinked; a
 * private data/ dir), with HOME and the overlay path pointed at a temp dir, so
 * the repo's data/dashboards.json and the real ~/.aiteamforge are never
 * touched. It proves the CRUD write-back never folds overlay content into the
 * shipped file.
 */

const { test, describe, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const net = require('node:net');
const { spawn } = require('child_process');

const SERVER_DIR = path.join(__dirname, '..');
const SHIPPED_FILE = path.join(SERVER_DIR, 'data', 'dashboards.json');
const overlayLib = require('../lib/dashboard-overlay');

// Client-project form freelance-<client>-<project>: the shape that must never
// ship. Generic on purpose (no client names in shipped test code).
const CLIENT_SLUG_RE = /freelance-[a-z0-9]+-[a-z0-9]/i;

function tmpdir(prefix) {
    return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
}

const SHIPPED = JSON.parse(fs.readFileSync(SHIPPED_FILE, 'utf8'));

const VALID_OVERLAY = {
    dashboards: [
        { id: 'doublenode', divisions: ['freelance-synthclient-alpha', 'freelance-synthclient-beta'] },
        { id: 'synthorg', name: 'SynthOrg', title: 'SYNTHORG', divisions: ['freelance-synthorg-x'], sort_order: 9 },
    ],
    divisions: [
        { id: 'freelance-synthclient-alpha', name: 'Freelance: Alpha', description: 'synthetic' },
        { id: 'academy', name: 'Academy (overlay)', description: 'overlay replaces shipped' },
    ],
};

describe('shipped data/dashboards.json', () => {
    test('carries no client-specific division slugs', () => {
        const raw = fs.readFileSync(SHIPPED_FILE, 'utf8');
        assert.equal(CLIENT_SLUG_RE.test(raw), false, 'client slug found in shipped dashboards.json');
    });
    test('keeps the org-level doublenode dashboard with a non-empty generic division filter', () => {
        // An EMPTY divisions array means "no filter" (all fleet) in the client, so
        // the shipped placeholder must stay non-empty.
        const d = SHIPPED.dashboards.find((x) => x.id === 'doublenode');
        assert.ok(d, 'doublenode dashboard missing');
        assert.deepEqual(d.divisions, ['freelance']);
    });
});

describe('lib/dashboard-overlay readOverlay', () => {
    test('absent overlay -> null (normal consumer case)', () => {
        const dir = tmpdir('x1337016-');
        assert.equal(overlayLib.readOverlay(path.join(dir, 'nope.json')), null);
    });
    test('default path is under HOME/.aiteamforge', () => {
        const saved = process.env.FLEET_DASHBOARDS_LOCAL_FILE;
        delete process.env.FLEET_DASHBOARDS_LOCAL_FILE;
        try {
            assert.equal(overlayLib.overlayPath(), path.join(os.homedir(), '.aiteamforge', 'dashboards.local.json'));
        } finally {
            if (saved !== undefined) process.env.FLEET_DASHBOARDS_LOCAL_FILE = saved;
        }
    });
    const MALFORMED = [
        ['invalid JSON', '{ "dashboards": [', /not valid JSON/],
        ['root array', '[]', /root is not a JSON object/],
        ['empty object', '{}', /neither/],
        ['dashboards not array', '{"dashboards": {}}', /must be an array/],
        ['entry without id', '{"dashboards": [{"divisions": []}]}', /no string "id"/],
        ['duplicate id', '{"divisions": [{"id":"a"},{"id":"a"}]}', /duplicate divisions id "a"/],
        ['divisions not strings', '{"dashboards": [{"id":"doublenode","divisions":[1]}]}', /array of strings/],
    ];
    for (const [label, body, re] of MALFORMED) {
        test(`malformed overlay (${label}) throws DashboardOverlayError`, () => {
            const dir = tmpdir('x1337016-');
            const f = path.join(dir, 'o.json');
            fs.writeFileSync(f, body);
            assert.throws(() => overlayLib.readOverlay(f), (err) => err instanceof overlayLib.DashboardOverlayError && re.test(err.message));
        });
    }
});

describe('lib/dashboard-overlay mergeDashboardConfig', () => {
    test('null overlay -> shipped unchanged', () => {
        assert.deepEqual(overlayLib.mergeDashboardConfig(SHIPPED, null), SHIPPED);
    });
    test('valid overlay: patch existing dashboard, append new dashboard and division', () => {
        const m = overlayLib.mergeDashboardConfig(SHIPPED, VALID_OVERLAY);
        const dn = m.dashboards.find((d) => d.id === 'doublenode');
        assert.deepEqual(dn.divisions, ['freelance-synthclient-alpha', 'freelance-synthclient-beta']);
        assert.equal(dn.name, 'DoubleNode', 'patch must keep the shipped fields it does not override');
        assert.ok(m.dashboards.some((d) => d.id === 'synthorg'));
        assert.ok(m.divisions.some((d) => d.id === 'freelance-synthclient-alpha'));
        assert.equal(m.dashboards.length, SHIPPED.dashboards.length + 1);
    });
    test('collision: overlay division replaces the shipped division with the same id', () => {
        const m = overlayLib.mergeDashboardConfig(SHIPPED, VALID_OVERLAY);
        const ac = m.divisions.filter((d) => d.id === 'academy');
        assert.equal(ac.length, 1);
        assert.equal(ac[0].name, 'Academy (overlay)');
    });
    test('does not mutate its inputs', () => {
        const before = JSON.stringify(SHIPPED);
        overlayLib.mergeDashboardConfig(SHIPPED, VALID_OVERLAY);
        assert.equal(JSON.stringify(SHIPPED), before);
    });
    test('a NEW dashboard without a name is rejected (partial definitions only patch)', () => {
        assert.throws(() => overlayLib.mergeDashboardConfig(SHIPPED, { dashboards: [{ id: 'brandnew', divisions: ['x'] }] }),
            overlayLib.DashboardOverlayError);
    });
});

describe('lib/dashboard-overlay splitForSave', () => {
    test('merged -> split round-trips to the original shipped + overlay', () => {
        const m = overlayLib.mergeDashboardConfig(SHIPPED, VALID_OVERLAY);
        const { shipped, overlay } = overlayLib.splitForSave(m, SHIPPED, VALID_OVERLAY);
        assert.deepEqual(shipped, SHIPPED);
        assert.deepEqual(overlay, VALID_OVERLAY);
    });
    test('an edit to a non-overlay field of a patched dashboard stays in the shipped part', () => {
        const m = overlayLib.mergeDashboardConfig(SHIPPED, VALID_OVERLAY);
        m.dashboards.find((d) => d.id === 'doublenode').sort_order = 42;
        const { shipped, overlay } = overlayLib.splitForSave(m, SHIPPED, VALID_OVERLAY);
        assert.equal(shipped.dashboards.find((d) => d.id === 'doublenode').sort_order, 42);
        assert.deepEqual(shipped.dashboards.find((d) => d.id === 'doublenode').divisions, ['freelance']);
        assert.equal(CLIENT_SLUG_RE.test(JSON.stringify(shipped)) || /synth/.test(JSON.stringify(shipped)), false);
        assert.equal(overlay.dashboards.find((d) => d.id === 'doublenode').sort_order, undefined);
    });
});

// ---------------------------------------------------------------------------
// Integration: the REAL server.js, sandboxed.
// ---------------------------------------------------------------------------
describe('server.js loadDashboardConfig/saveDashboardConfig (sandboxed real server)', () => {
    let child;
    let baseUrl;
    let sandbox;
    let overlayFile;
    let sandboxShipped;
    let stderr = '';

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
            await new Promise((r) => setTimeout(r, 100));
        }
        throw new Error(`sandboxed server did not become ready: ${lastErr}\n${stderr}`);
    }

    before(async () => {
        sandbox = tmpdir('x1337016-srv-');
        const srvDir = path.join(sandbox, 'server');
        fs.mkdirSync(path.join(srvDir, 'data'), { recursive: true });
        fs.mkdirSync(path.join(sandbox, 'home'), { recursive: true });
        fs.copyFileSync(path.join(SERVER_DIR, 'server.js'), path.join(srvDir, 'server.js'));
        for (const name of ['lib', 'public', 'config', 'node_modules', 'package.json']) {
            const src = path.join(SERVER_DIR, name);
            if (fs.existsSync(src)) fs.symlinkSync(src, path.join(srvDir, name));
        }
        sandboxShipped = path.join(srvDir, 'data', 'dashboards.json');
        fs.copyFileSync(SHIPPED_FILE, sandboxShipped);
        overlayFile = path.join(sandbox, 'dashboards.local.json');
        fs.writeFileSync(overlayFile, JSON.stringify(VALID_OVERLAY, null, 2));

        const port = await getFreePort();
        baseUrl = `http://127.0.0.1:${port}`;
        const env = { ...process.env };
        for (const k of ['FLEET_AUTH_TOKEN', 'FLEET_ADMIN_TOKEN', 'TMUX', 'TMUX_PANE']) delete env[k];
        Object.assign(env, {
            PORT: String(port),
            HOME: path.join(sandbox, 'home'),
            FLEET_REQUIRE_AUTH: '0',
            FLEET_DASHBOARDS_LOCAL_FILE: overlayFile,
        });
        child = spawn(process.execPath, ['server.js'], { cwd: srvDir, env, stdio: ['ignore', 'ignore', 'pipe'] });
        child.stderr.on('data', (b) => { stderr += b.toString(); });
        await waitForReady(baseUrl, 20000);
    });

    after(async () => {
        if (!child) return;
        await new Promise((resolve) => {
            child.once('exit', resolve);
            child.kill('SIGTERM');
            setTimeout(resolve, 3000);
        });
    });

    test('GET /api/dashboards serves the merged view (overlay divisions + overlay-only dashboard)', async () => {
        const res = await fetch(`${baseUrl}/api/dashboards`);
        assert.equal(res.status, 200);
        const body = await res.json();
        const dn = body.dashboards.find((d) => d.id === 'doublenode');
        assert.deepEqual(dn.divisions, ['freelance-synthclient-alpha', 'freelance-synthclient-beta']);
        assert.ok(body.dashboards.some((d) => d.id === 'synthorg'));
        assert.equal(JSON.stringify(body).includes('__overlaySource'), false);
    });

    test('PUT write-back keeps overlay content OUT of the shipped file and in the overlay', async () => {
        const res = await fetch(`${baseUrl}/api/dashboards/doublenode`, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ description: 'edited via API' }),
        });
        assert.equal(res.status, 200, await res.text());
        const shippedAfter = fs.readFileSync(sandboxShipped, 'utf8');
        assert.equal(/synth/i.test(shippedAfter), false, 'overlay content leaked into the shipped dashboards.json');
        const parsed = JSON.parse(shippedAfter);
        const dn = parsed.dashboards.find((d) => d.id === 'doublenode');
        assert.equal(dn.description, 'edited via API', 'non-overlay edit must persist to the shipped file');
        assert.deepEqual(dn.divisions, ['freelance']);
        assert.equal(parsed.dashboards.some((d) => d.id === 'synthorg'), false);
        const ov = JSON.parse(fs.readFileSync(overlayFile, 'utf8'));
        assert.deepEqual(ov.dashboards.find((d) => d.id === 'doublenode').divisions,
            ['freelance-synthclient-alpha', 'freelance-synthclient-beta']);
    });

    test('PUT /api/dashboards/reorder (touches every dashboard) still does not leak', async () => {
        const list = await (await fetch(`${baseUrl}/api/dashboards`)).json();
        const order = list.dashboards.map((d) => d.id).reverse();
        const res = await fetch(`${baseUrl}/api/dashboards/reorder`, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ order }),
        });
        assert.equal(res.status, 200, await res.text());
        const shippedAfter = fs.readFileSync(sandboxShipped, 'utf8');
        assert.equal(/synth/i.test(shippedAfter), false, 'reorder leaked overlay content into the shipped file');
    });

    test('malformed overlay -> GET /api/dashboards fails loudly (500), never silently drops it', async () => {
        fs.writeFileSync(overlayFile, '{ "dashboards": [ not json');
        const res = await fetch(`${baseUrl}/api/dashboards`);
        assert.equal(res.status, 500);
        assert.match(stderr, /dashboards overlay .* is not valid JSON/);
        fs.writeFileSync(overlayFile, JSON.stringify(VALID_OVERLAY, null, 2));
    });
});
