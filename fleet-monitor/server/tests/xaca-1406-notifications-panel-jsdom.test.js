//
//  xaca-1406-notifications-panel-jsdom.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1406-002 -- jsdom tests for the team LCARS Notifications panel.
 *
 * Loads the REAL lcars-ui/js/lcars-notifications.js (never a paraphrase) and drives
 * window.lcarsNotifications.createPanel against a stubbed fetch that speaks the
 * documented LCARS server API (GET/POST /api/notify-config, /connections, /test).
 * It lives under fleet-monitor/server/tests because jsdom is only a dependency
 * there; lcars-ui/tests has no npm install step.
 *
 * Vacuous-green guard: a missing implementation file FAILS (loadImpl throws).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

// dev-team keeps lcars-ui/ at the repo root; the homebrew-tap mirror (whose CI runs this
// suite via package.json) keeps it at share/lcars-ui/. Take the first that exists; if
// neither does, point at the dev-team path so loadImpl fails loudly (no vacuous green).
const REPO_ROOT = path.join(__dirname, '..', '..', '..');
const LCARS_UI = ['lcars-ui', path.join('share', 'lcars-ui')]
    .map((rel) => path.join(REPO_ROOT, rel))
    .find((dir) => fs.existsSync(path.join(dir, 'js', 'lcars-notifications.js')))
    || path.join(REPO_ROOT, 'lcars-ui');
const IMPL = path.join(LCARS_UI, 'js', 'lcars-notifications.js');
const INDEX_HTML = path.join(LCARS_UI, 'index.html');

const CATALOG = [
    { id: 'release-cut', label: 'Release cut', description: 'A release branch was cut.', defaultSeverity: 'info' },
    { id: 'gate-failed', label: 'Gate failed', description: 'A merge gate failed.', defaultSeverity: 'high' },
    { id: 'ci-down', label: 'CI down', description: 'CI pool is down.', defaultSeverity: 'critical' }
];
const SEVERITIES = ['info', 'warning', 'high', 'critical'];
const CONNS = [
    { id: 'ops-slack', provider: 'slack', label: 'Ops Slack', enabled: true },
    { id: 'pager-sms', provider: 'pushover', label: 'Pager', enabled: false }
];

function v2(extra) {
    return Object.assign({
        $schema: 'release-notify/v2', version: 2,
        aliases: { legacy: { provider: 'slack', target: { secretRef: 'env:RELEASE_X_Y' } } },
        dedupeWindow: 120,
        routes: { 'release-cut': ['ops-slack'], 'gate-failed': ['ops-slack', 'pager-sms'] }
    }, extra || {});
}

function loadImpl() {
    if (!fs.existsSync(IMPL)) throw new Error('MISSING IMPLEMENTATION: ' + IMPL);
    const dom = new JSDOM('<!doctype html><html><body><div id="root"></div></body></html>',
        { runScripts: 'outside-only', url: 'http://localhost/' });
    dom.window.eval(fs.readFileSync(IMPL, 'utf8'));
    const api = dom.window.lcarsNotifications;
    assert.ok(api && typeof api.createPanel === 'function', 'window.lcarsNotifications.createPanel must be exposed');
    return { dom, window: dom.window, document: dom.window.document, api, root: dom.window.document.getElementById('root') };
}

function json(status, data) {
    return { ok: status >= 200 && status < 300, status, json: async () => data };
}

/** routes: { 'GET /api/notify-config': resp | fn(call) -> resp, ... } */
function mkFetch(routes) {
    const calls = [];
    const f = async function (url, init) {
        const method = (init && init.method) || 'GET';
        const p = String(url).split('?')[0];
        const call = { url: String(url), method, path: p, body: init && init.body ? JSON.parse(init.body) : null };
        calls.push(call);
        const h = routes[method + ' ' + p];
        if (!h) return json(404, { error: 'not_found', message: 'no stub for ' + method + ' ' + p });
        const r = typeof h === 'function' ? h(call) : h;
        if (r instanceof Error) throw r;
        return r;
    };
    f.calls = calls;
    return f;
}

function configResp(config, over) {
    return json(200, Object.assign({
        team: 'academy', exists: config !== null, config, sourceVersion: config ? 2 : null,
        catalog: CATALOG, severities: SEVERITIES
    }, over || {}));
}

async function settle() { for (let i = 0; i < 8; i++) await new Promise((r) => setTimeout(r, 0)); }

async function setup(opts) {
    opts = opts || {};
    const env = loadImpl();
    env.confirms = [];
    env.confirmAnswer = true;
    const routes = Object.assign({
        'GET /api/notify-config': configResp(v2()),
        'GET /api/notify-config/connections': json(200, { team: 'academy', connections: CONNS })
    }, opts.routes || {});
    env.fetch = mkFetch(routes);
    env.panel = env.api.createPanel({
        root: env.root, team: 'academy', fetch: env.fetch,
        confirm: (m) => { env.confirms.push(m); return env.confirmAnswer; }
    });
    await env.panel.load();
    await settle();
    return env;
}

const q = (env, sel) => env.root.querySelector(sel);
const qa = (env, sel) => Array.from(env.root.querySelectorAll(sel));
const cell = (env, t, c) => q(env, 'button.notif-toggle[data-type="' + t + '"][data-conn="' + c + '"]');
const pressed = (env, t, c) => cell(env, t, c).getAttribute('aria-pressed');

// ---------------------------------------------------------------------------
test('matrix renders one row per catalog type and one column per FM connection', async () => {
    const env = await setup();
    assert.equal(qa(env, 'tbody tr[data-type]').length, 3);
    assert.deepEqual(qa(env, 'thead th[data-conn]').map((t) => t.getAttribute('data-conn')), ['ops-slack', 'pager-sms']);
    assert.equal(qa(env, 'button.notif-toggle').length, 6);
    // row header carries label and description tooltip
    const th = q(env, 'tr[data-type="gate-failed"] th[scope="row"]');
    assert.match(th.textContent, /Gate failed/);
    assert.equal(th.getAttribute('title'), 'A merge gate failed.');
    // column header carries label and provider
    const ch = q(env, 'thead th[data-conn="ops-slack"]');
    assert.match(ch.textContent, /Ops Slack/);
    assert.match(ch.textContent, /slack/);
    // initial pressed state mirrors the loaded routes
    assert.equal(pressed(env, 'release-cut', 'ops-slack'), 'true');
    assert.equal(pressed(env, 'release-cut', 'pager-sms'), 'false');
    assert.equal(pressed(env, 'gate-failed', 'pager-sms'), 'true');
    assert.equal(pressed(env, 'ci-down', 'ops-slack'), 'false');
    assert.equal(q(env, '.notif-dirty').getAttribute('data-dirty'), 'false');
});

test('cells are real buttons with an accessible name; disabled connections are dimmed but toggleable', async () => {
    const env = await setup();
    const b = cell(env, 'ci-down', 'pager-sms');
    assert.equal(b.tagName, 'BUTTON');
    assert.equal(b.getAttribute('type'), 'button');
    assert.match(b.getAttribute('aria-label'), /CI down.*Pager/);
    assert.ok(q(env, 'thead th[data-conn="pager-sms"]').classList.contains('notif-col-disabled'));
    assert.match(q(env, 'thead th[data-conn="pager-sms"]').textContent, /DISABLED/);
    assert.ok(q(env, '[data-notif="disabled-note"]'), 'a note explains dimmed columns');
    assert.equal(b.disabled, false);
    b.click();
    assert.equal(b.getAttribute('aria-pressed'), 'true');
});

test('toggle builds the correct routes in the POSTed config and keeps untouched fields', async () => {
    const env = await setup({ routes: { 'POST /api/notify-config': json(200, { ok: true, saved: true, push: { ok: true, action: 'pushed' } }) } });
    cell(env, 'ci-down', 'ops-slack').click();          // add
    cell(env, 'gate-failed', 'pager-sms').click();      // remove
    assert.equal(q(env, '.notif-dirty').getAttribute('data-dirty'), 'true');
    assert.equal(q(env, '.notif-dirty').textContent, 'UNSAVED CHANGES');
    q(env, '.notif-btn-primary').click();
    await settle();
    const post = env.fetch.calls.find((c) => c.method === 'POST' && c.path === '/api/notify-config');
    assert.ok(post, 'POST /api/notify-config was made');
    assert.equal(post.body.team, 'academy');
    assert.deepEqual(post.body.config.routes, {
        'release-cut': ['ops-slack'], 'gate-failed': ['ops-slack'], 'ci-down': ['ops-slack']
    });
    // the panel does not edit these; they must survive the round trip
    assert.deepEqual(post.body.config.aliases, v2().aliases);
    assert.equal(post.body.config.dedupeWindow, 120);
    assert.equal(post.body.config.version, 2);
    assert.equal(post.body.config.$schema, 'release-notify/v2');
    assert.equal(q(env, '.notif-dirty').getAttribute('data-dirty'), 'false', 'clean after a successful save');
});

test('untoggling the last connection of a type that had an explicit key keeps it as [] ; a never-routed type drops the key', async () => {
    const env = await setup({ routes: { 'POST /api/notify-config': json(200, { ok: true, saved: true, push: { ok: true, action: 'pushed' } }) } });
    cell(env, 'release-cut', 'ops-slack').click();      // existed -> []
    cell(env, 'ci-down', 'ops-slack').click();          // new
    cell(env, 'ci-down', 'ops-slack').click();          // new, then removed -> key dropped
    q(env, '.notif-btn-primary').click();
    await settle();
    const post = env.fetch.calls.find((c) => c.method === 'POST');
    assert.deepEqual(post.body.config.routes['release-cut'], []);
    assert.equal(Object.prototype.hasOwnProperty.call(post.body.config.routes, 'ci-down'), false);
});

test('an unknown connection id in config.routes is shown as a warning column and preserved on save', async () => {
    const cfg = v2({ routes: { 'release-cut': ['ops-slack', 'ghost-conn'], 'gate-failed': ['ghost-conn'] } });
    const env = await setup({
        routes: {
            'GET /api/notify-config': configResp(cfg),
            'POST /api/notify-config': json(200, { ok: true, saved: true, push: { ok: true, action: 'pushed' } })
        }
    });
    const th = q(env, 'thead th[data-conn="ghost-conn"]');
    assert.ok(th, 'unknown column is rendered');
    assert.match(th.textContent, /UNKNOWN CONNECTION/);
    assert.equal(pressed(env, 'release-cut', 'ghost-conn'), 'true');
    // save without touching it: it must still be in the payload
    cell(env, 'ci-down', 'ops-slack').click();
    q(env, '.notif-btn-primary').click();
    await settle();
    const post = env.fetch.calls.find((c) => c.method === 'POST');
    assert.deepEqual(post.body.config.routes['release-cut'], ['ops-slack', 'ghost-conn']);
    assert.deepEqual(post.body.config.routes['gate-failed'], ['ghost-conn']);
});

test('REMOVE on an unknown column strips that id from every route and marks the form dirty', async () => {
    const cfg = v2({ routes: { 'release-cut': ['ops-slack', 'ghost-conn'], 'gate-failed': ['ghost-conn'] } });
    const env = await setup({
        routes: {
            'GET /api/notify-config': configResp(cfg),
            'POST /api/notify-config': json(200, { ok: true, saved: true, push: { ok: true, action: 'pushed' } })
        }
    });
    q(env, '[data-remove-conn="ghost-conn"]').click();
    assert.equal(q(env, 'thead th[data-conn="ghost-conn"]'), null);
    assert.equal(q(env, '.notif-dirty').getAttribute('data-dirty'), 'true');
    q(env, '.notif-btn-primary').click();
    await settle();
    const post = env.fetch.calls.find((c) => c.method === 'POST');
    assert.deepEqual(post.body.config.routes['release-cut'], ['ops-slack']);
    assert.deepEqual(post.body.config.routes['gate-failed'], []);
});

test('severity override: default option is "Catalog default (<sev>)"; choosing a value sets it; choosing default removes the key', async () => {
    const cfg = v2({ severityOverrides: { 'release-cut': 'warning' } });
    const env = await setup({
        routes: {
            'GET /api/notify-config': configResp(cfg),
            'POST /api/notify-config': json(200, { ok: true, saved: true, push: { ok: true, action: 'pushed' } })
        }
    });
    const sel = q(env, 'select[data-sev-for="release-cut"]');
    assert.equal(sel.options[0].value, '');
    assert.equal(sel.options[0].textContent, 'Catalog default (info)');
    assert.deepEqual(Array.from(sel.options).slice(1).map((o) => o.value), SEVERITIES);
    assert.equal(sel.value, 'warning');
    // set another type, clear the first
    const sel2 = q(env, 'select[data-sev-for="ci-down"]');
    sel2.value = 'high'; sel2.dispatchEvent(new env.window.Event('change', { bubbles: true }));
    sel.value = ''; sel.dispatchEvent(new env.window.Event('change', { bubbles: true }));
    q(env, '.notif-btn-primary').click();
    await settle();
    const post = env.fetch.calls.find((c) => c.method === 'POST');
    assert.deepEqual(post.body.config.severityOverrides, { 'ci-down': 'high' });
});

test('clearing the last severity override omits severityOverrides entirely', async () => {
    const cfg = v2({ severityOverrides: { 'release-cut': 'warning' } });
    const env = await setup({
        routes: {
            'GET /api/notify-config': configResp(cfg),
            'POST /api/notify-config': json(200, { ok: true, saved: true, push: { ok: true, action: 'pushed' } })
        }
    });
    const sel = q(env, 'select[data-sev-for="release-cut"]');
    sel.value = ''; sel.dispatchEvent(new env.window.Event('change', { bubbles: true }));
    q(env, '.notif-btn-primary').click();
    await settle();
    const post = env.fetch.calls.find((c) => c.method === 'POST');
    assert.equal(Object.prototype.hasOwnProperty.call(post.body.config, 'severityOverrides'), false);
});

test('quiet hours: start == end is invalid inline and blocks the POST; a valid window is sent', async () => {
    const env = await setup({ routes: { 'POST /api/notify-config': json(200, { ok: true, saved: true, push: { ok: true, action: 'pushed' } }) } });
    const en = q(env, '#notif-qh-enabled');
    en.checked = true; en.dispatchEvent(new env.window.Event('change', { bubbles: true }));
    const s = q(env, '#notif-qh-start'), e = q(env, '#notif-qh-end'), tz = q(env, '#notif-qh-tz');
    // default timezone is the browser IANA zone
    assert.equal(tz.value, new env.window.Intl.DateTimeFormat().resolvedOptions().timeZone);
    s.value = '22:00'; s.dispatchEvent(new env.window.Event('input', { bubbles: true }));
    e.value = '22:00'; e.dispatchEvent(new env.window.Event('input', { bubbles: true }));
    assert.match(q(env, '#notif-qh-end-err').textContent, /different/);
    assert.equal(e.getAttribute('aria-invalid'), 'true');
    q(env, '.notif-btn-primary').click();
    await settle();
    assert.equal(env.fetch.calls.filter((c) => c.method === 'POST').length, 0, 'no POST while invalid');
    assert.match(q(env, '[data-notif="save-result"]').textContent, /quiet hours/i);

    e.value = '07:00'; e.dispatchEvent(new env.window.Event('input', { bubbles: true }));
    assert.equal(q(env, '#notif-qh-end-err').textContent, '');
    tz.value = 'America/Chicago'; tz.dispatchEvent(new env.window.Event('input', { bubbles: true }));
    q(env, '.notif-btn-primary').click();
    await settle();
    const post = env.fetch.calls.find((c) => c.method === 'POST');
    assert.deepEqual(post.body.config.quietHours, { start: '22:00', end: '07:00', timezone: 'America/Chicago' });
});

test('quiet hours: a bogus time zone is rejected inline', async () => {
    const env = await setup();
    const en = q(env, '#notif-qh-enabled');
    en.checked = true; en.dispatchEvent(new env.window.Event('change', { bubbles: true }));
    const tz = q(env, '#notif-qh-tz');
    tz.value = 'Mars/Olympus_Mons'; tz.dispatchEvent(new env.window.Event('input', { bubbles: true }));
    assert.match(q(env, '#notif-qh-tz-err').textContent, /Unknown time zone/);
});

test('disabling quiet hours removes quietHours from the payload', async () => {
    const cfg = v2({ quietHours: { start: '23:00', end: '06:00', timezone: 'UTC' } });
    const env = await setup({
        routes: {
            'GET /api/notify-config': configResp(cfg),
            'POST /api/notify-config': json(200, { ok: true, saved: true, push: { ok: true, action: 'pushed' } })
        }
    });
    assert.equal(q(env, '#notif-qh-enabled').checked, true);
    const en = q(env, '#notif-qh-enabled');
    en.checked = false; en.dispatchEvent(new env.window.Event('change', { bubbles: true }));
    q(env, '.notif-btn-primary').click();
    await settle();
    const post = env.fetch.calls.find((c) => c.method === 'POST');
    assert.equal(Object.prototype.hasOwnProperty.call(post.body.config, 'quietHours'), false);
});

test('400 invalid response shows message and details inline; nothing is marked saved', async () => {
    const env = await setup({
        routes: { 'POST /api/notify-config': json(400, { error: 'invalid', message: 'Configuration rejected', details: ['routes.ci-down: unknown notice type', 'quietHours: start equals end'] }) }
    });
    cell(env, 'ci-down', 'ops-slack').click();
    q(env, '.notif-btn-primary').click();
    await settle();
    const box = q(env, '[data-notif="save-result"]');
    assert.match(box.textContent, /Not saved/);
    const items = Array.from(box.querySelectorAll('li')).map((l) => l.textContent);
    assert.deepEqual(items, ['routes.ci-down: unknown notice type', 'quietHours: start equals end']);
    assert.equal(q(env, '.notif-dirty').getAttribute('data-dirty'), 'true');
    assert.equal(q(env, '[data-notif="push-result"]'), null);
});

test('saved:true with push ok shows success and a separate push status', async () => {
    const env = await setup({ routes: { 'POST /api/notify-config': json(200, { ok: true, saved: true, push: { ok: true, action: 'pushed', hash: 'abc' } }) } });
    cell(env, 'ci-down', 'ops-slack').click();
    q(env, '.notif-btn-primary').click();
    await settle();
    assert.match(q(env, '[data-notif="save-result"]').textContent, /Saved/);
    assert.match(q(env, '[data-notif="push-result"]').textContent, /pushed to Fleet Monitor/i);
});

test('push skipped is reported as such', async () => {
    const env = await setup({ routes: { 'POST /api/notify-config': json(200, { ok: true, saved: true, push: { ok: true, action: 'skipped', reason: 'unchanged' } }) } });
    cell(env, 'ci-down', 'ops-slack').click();
    q(env, '.notif-btn-primary').click();
    await settle();
    assert.match(q(env, '[data-notif="push-result"]').textContent, /skipped: unchanged/);
});

const PUSH_ERRORS = [
    ['no-fm-url', /Fleet Monitor not configured/],
    ['unauthorized', /team notify key rejected \(401\)/],
    ['forbidden', /key belongs to another team \(403\)/],
    ['key-resolver-unavailable', /Key resolver unavailable/],
    ['no-key', /No notify key found/]
];
for (const [code, re] of PUSH_ERRORS) {
    test('push failure "' + code + '" is a WARNING, the save still counts', async () => {
        const env = await setup({ routes: { 'POST /api/notify-config': json(200, { ok: true, saved: true, push: { ok: false, action: 'error', error: code, team: 'academy' } }) } });
        cell(env, 'ci-down', 'ops-slack').click();
        q(env, '.notif-btn-primary').click();
        await settle();
        assert.match(q(env, '[data-notif="save-result"]').textContent, /Saved/);
        assert.ok(q(env, '[data-notif="save-result"]').classList.contains('notif-msg-ok'), 'save is a success');
        const push = q(env, '[data-notif="push-result"]');
        assert.match(push.textContent, re);
        assert.ok(push.classList.contains('notif-msg-warn'), 'push failure is a warning, not an error');
        assert.equal(q(env, '.notif-dirty').getAttribute('data-dirty'), 'false', 'saved state is committed');
    });
}

const CONN_ERRORS = [
    ['no-fm-url', /Fleet Monitor not configured/],
    ['no-key', /No notify key found/],
    ['key-resolver-unavailable', /Key resolver unavailable/],
    ['unauthorized', /team notify key rejected \(401\)/],
    ['forbidden', /key belongs to another team \(403\)/],
    ['fm-unreachable', /Fleet Monitor unreachable/],
    ['fm-error', /Fleet Monitor returned an error/]
];
for (const [code, re] of CONN_ERRORS) {
    test('connections load error "' + code + '" renders its message; rows + severity + quiet hours stay, no connection columns', async () => {
        const env = await setup({ routes: { 'GET /api/notify-config/connections': json(code === 'unauthorized' ? 401 : 502, { error: code, message: 'static' }) } });
        const note = q(env, '[data-notif="conn-error"]');
        assert.ok(note, 'conn error note rendered');
        assert.match(note.textContent, re);
        assert.equal(qa(env, 'thead th[data-conn]').length, 0);
        assert.equal(qa(env, 'button.notif-toggle').length, 0);
        assert.equal(qa(env, 'tbody tr[data-type]').length, 3, 'type rows remain');
        assert.equal(qa(env, 'select[data-sev-for]').length, 3, 'severity selects remain');
        assert.ok(q(env, '#notif-qh-enabled'), 'quiet hours remains');
        // existing routes are not dropped when saving without connections
    });
}

test('saving while connections failed to load still sends the loaded routes unchanged', async () => {
    const env = await setup({ routes: {
        'GET /api/notify-config/connections': json(502, { error: 'fm-unreachable', message: 'x' }),
        'POST /api/notify-config': json(200, { ok: true, saved: true, push: { ok: true, action: 'pushed' } })
    } });
    const sel = q(env, 'select[data-sev-for="ci-down"]');
    sel.value = 'warning'; sel.dispatchEvent(new env.window.Event('change', { bubbles: true }));
    q(env, '.notif-btn-primary').click();
    await settle();
    const post = env.fetch.calls.find((c) => c.method === 'POST');
    assert.deepEqual(post.body.config.routes, v2().routes);
});

test('sourceVersion 1 shows the upgrade notice and allows saving a clean form; aliases are not sent as edited', async () => {
    const env = await setup({ routes: {
        'GET /api/notify-config': configResp(null, { exists: true, sourceVersion: 1 }),
        'POST /api/notify-config': json(200, { ok: true, saved: true, push: { ok: true, action: 'pushed' } })
    } });
    const n = q(env, '[data-notif="v1-notice"]');
    assert.ok(n);
    assert.match(n.textContent, /upgrades it to version 2/);
    assert.match(n.textContent, /aliases are kept/);
    assert.equal(q(env, '.notif-btn-primary').disabled, false, 'upgrade save allowed even when clean');
    q(env, '.notif-btn-primary').click();
    await settle();
    const post = env.fetch.calls.find((c) => c.method === 'POST');
    assert.equal(post.body.config.version, 2);
    assert.deepEqual(post.body.config.routes, {});
    assert.equal(Object.prototype.hasOwnProperty.call(post.body.config, 'aliases'), false, 'server preserves v1 aliases');
    assert.equal(q(env, '[data-notif="v1-notice"]'), null, 'notice gone after upgrade');
});

test('Save is disabled while clean on a v2 file', async () => {
    const env = await setup();
    assert.equal(q(env, '.notif-btn-primary').disabled, true);
    cell(env, 'ci-down', 'ops-slack').click();
    assert.equal(q(env, '.notif-btn-primary').disabled, false);
    cell(env, 'ci-down', 'ops-slack').click();
    assert.equal(q(env, '.notif-btn-primary').disabled, true, 'toggling back to the saved state is clean again');
});

test('canLeave: clean leaves silently; dirty asks, declining keeps edits, accepting discards them', async () => {
    const env = await setup();
    assert.equal(env.panel.canLeave(), true);
    assert.equal(env.confirms.length, 0);
    cell(env, 'ci-down', 'ops-slack').click();
    env.confirmAnswer = false;
    assert.equal(env.panel.canLeave(), false);
    assert.equal(env.confirms.length, 1);
    assert.equal(pressed(env, 'ci-down', 'ops-slack'), 'true', 'edits kept after declining');
    env.confirmAnswer = true;
    assert.equal(env.panel.canLeave(), true);
    assert.equal(pressed(env, 'ci-down', 'ops-slack'), 'false', 'edits discarded after accepting');
    assert.equal(env.panel.canLeave(), true);
    assert.equal(env.confirms.length, 2, 'does not ask twice');
});

test('load failure shows an error with RETRY', async () => {
    const env = await setup({ routes: { 'GET /api/notify-config': json(500, { error: 'server_error', message: 'Could not read notify config' }) } });
    assert.match(q(env, '.notif-msg-error').textContent, /Could not read notify config/);
    assert.equal(qa(env, 'table').length, 0);
    assert.ok(Array.from(env.root.querySelectorAll('button')).some((b) => b.textContent === 'RETRY'));
});

// ---------------------------------------------------------------------------
// Test send
// ---------------------------------------------------------------------------
async function sendTest(env, type) {
    q(env, '[data-test-for="' + type + '"]').click();
    await settle();
    return q(env, '[data-receipt-for="' + type + '"]');
}

test('SEND TEST posts {team,type}, disables the button in flight, and shows per-connection receipts', async () => {
    let release;
    const gate = new Promise((r) => { release = r; });
    const env = await setup({ routes: { 'POST /api/notify-config/test': () => ({
        ok: true, status: 200,
        json: async () => { await gate; return {
            ok: true, deliveredVia: 'hub',
            result: { ok: true, routed: true, delivered: 2, failed: 0, suppressed: 0, severity: 'high', warnings: [],
                receipts: [{ connectionId: 'ops-slack', provider: 'slack', ok: true }, { connectionId: 'pager-sms', provider: 'pushover', ok: true }] }
        }; }
    }) } });
    const b = q(env, '[data-test-for="gate-failed"]');
    b.click();
    await new Promise((r) => setTimeout(r, 0));
    const inFlight = q(env, '[data-test-for="gate-failed"]');
    assert.equal(inFlight.disabled, true, 'disabled while in flight');
    assert.match(inFlight.textContent, /SENDING/);
    const post = env.fetch.calls.find((c) => c.path === '/api/notify-config/test');
    assert.deepEqual(post.body, { team: 'academy', type: 'gate-failed' });
    release();
    await settle();
    const row = q(env, '[data-receipt-for="gate-failed"]');
    assert.equal(row.querySelector('[data-receipt-level]').getAttribute('data-receipt-level'), 'ok');
    assert.deepEqual(Array.from(row.querySelectorAll('li')).map((l) => l.textContent),
        ['Ops Slack (slack): delivered', 'Pager (pushover): delivered']);
    assert.equal(q(env, '[data-test-for="gate-failed"]').disabled, false);
    assert.equal(env.window.document.activeElement, q(env, '[data-test-for="gate-failed"]'), 'focus returns to the button');
});

test('SEND TEST: suppressed (deliveredVia none) is shown as suppressed, not as failure', async () => {
    const env = await setup({ routes: { 'POST /api/notify-config/test': json(200, {
        ok: true, deliveredVia: 'none',
        result: { ok: false, routed: true, delivered: 0, failed: 0, suppressed: 1, warnings: [],
            receipts: [{ connectionId: 'ops-slack', provider: 'slack', ok: false, error: '', suppressed: 'dedupe' }] }
    }) } });
    const row = await sendTest(env, 'release-cut');
    const box = row.querySelector('[data-receipt-level]');
    assert.equal(box.getAttribute('data-receipt-level'), 'suppressed');
    assert.match(box.textContent, /Suppressed/);
    assert.match(box.textContent, /duplicate inside the dedupe window/);
});

test('SEND TEST: partial delivery (hub 5xx with delivered>0 or a failed connection) is a warning with the server warning text', async () => {
    const env = await setup({ routes: { 'POST /api/notify-config/test': json(200, {
        ok: true, deliveredVia: 'hub', warning: 'Fleet Monitor returned 502 after delivering to 1 connection',
        result: { ok: true, routed: true, delivered: 1, failed: 1, suppressed: 0, warnings: ['quiet hours table stale'],
            receipts: [{ connectionId: 'ops-slack', provider: 'slack', ok: true }, { connectionId: 'pager-sms', provider: 'pushover', ok: false, error: 'timeout' }] }
    }) } });
    const row = await sendTest(env, 'gate-failed');
    const box = row.querySelector('[data-receipt-level]');
    assert.equal(box.getAttribute('data-receipt-level'), 'warn');
    assert.match(box.textContent, /Partial delivery: 1 of 2/);
    assert.match(box.textContent, /Pager \(pushover\): failed - timeout/);
    assert.match(box.textContent, /Fleet Monitor returned 502 after delivering/);
    assert.match(box.textContent, /quiet hours table stale/);
});

test('SEND TEST: hub warning with no receipts is still partial delivery', async () => {
    const env = await setup({ routes: { 'POST /api/notify-config/test': json(200, {
        ok: true, deliveredVia: 'hub', warning: 'hub 5xx after delivery', result: {}
    }) } });
    const row = await sendTest(env, 'ci-down');
    assert.equal(row.querySelector('[data-receipt-level]').getAttribute('data-receipt-level'), 'warn');
    assert.match(row.textContent, /hub 5xx after delivery/);
});

test('SEND TEST: nothing routed is reported as not sent', async () => {
    const env = await setup({ routes: { 'POST /api/notify-config/test': json(200, {
        ok: false, deliveredVia: 'none', result: { ok: false, routed: false, reason: 'no-route', receipts: [], warnings: [] }
    }) } });
    const row = await sendTest(env, 'ci-down');
    assert.equal(row.querySelector('[data-receipt-level]').getAttribute('data-receipt-level'), 'warn');
    assert.match(row.textContent, /no route is pushed/);
});

for (const [code, re, status] of [
    ['no-fm-url', /Fleet Monitor not configured/, 400],
    ['no-key', /No notify key found/, 400],
    ['key-resolver-unavailable', /Key resolver unavailable/, 503],
    ['unauthorized', /team notify key rejected \(401\)/, 401],
    ['forbidden', /key belongs to another team \(403\)/, 403],
    ['fm-unreachable', /Fleet Monitor unreachable/, 502],
    ['fm-error', /Fleet Monitor returned an error/, 502]
]) {
    test('SEND TEST: error code "' + code + '" renders its message and re-enables the button', async () => {
        const env = await setup({ routes: { 'POST /api/notify-config/test': json(status, { ok: false, error: code, message: 'static' }) } });
        const row = await sendTest(env, 'ci-down');
        const box = row.querySelector('[data-receipt-level]');
        assert.equal(box.getAttribute('data-receipt-level'), 'error');
        assert.match(box.textContent, re);
        assert.equal(q(env, '[data-test-for="ci-down"]').disabled, false);
    });
}

test('SEND TEST: a network failure is reported, not thrown', async () => {
    const env = await setup({ routes: { 'POST /api/notify-config/test': new Error('boom') } });
    const row = await sendTest(env, 'ci-down');
    assert.equal(row.querySelector('[data-receipt-level]').getAttribute('data-receipt-level'), 'error');
});

test('test-send note warns about real delivery, SMS paging, and that unsaved edits are not used', async () => {
    const env = await setup();
    const note = () => q(env, '.notif-panel > p.notif-hint').textContent;
    assert.match(note(), /real notice/);
    assert.match(note(), /SMS/);
    assert.doesNotMatch(note(), /unsaved changes/);
    cell(env, 'ci-down', 'ops-slack').click();
    assert.match(note(), /unsaved changes: they are NOT used by the test/);
});

// ---------------------------------------------------------------------------
// Safety + wiring
// ---------------------------------------------------------------------------
test('dynamic strings are rendered as text, never HTML', async () => {
    const evil = '<img src=x onerror="window.__pwned=1">';
    const env = await setup({ routes: {
        'GET /api/notify-config': configResp(v2({ routes: { 'release-cut': [evil.replace(/[^a-z-]/g, '')] } }), { catalog: [{ id: 'release-cut', label: evil, description: evil, defaultSeverity: 'info' }] }),
        'GET /api/notify-config/connections': json(200, { team: 'academy', connections: [{ id: 'ops-slack', provider: evil, label: evil, enabled: true }] })
    } });
    assert.equal(qa(env, 'img').length, 0);
    assert.equal(env.window.__pwned, undefined);
    assert.ok(env.root.textContent.indexOf(evil) !== -1);
});

test('index.html registers the NOTIFICATIONS section: sidebar button, tab-bar button, section element, script', () => {
    const html = fs.readFileSync(INDEX_HTML, 'utf8');
    assert.match(html, /<div class="sidebar-button" data-section="notifications">\s*<span>NOTIFICATIONS<\/span>/);
    assert.match(html, /<div class="tabbar-button" data-section="notifications">/);
    assert.match(html, /<section class="notifications-section" data-mode="settings">/);
    assert.match(html, /id="notifications-root"/);
    assert.match(html, /<script src="js\/lcars-notifications\.js[^"]*"><\/script>/);
    assert.match(html, /css\/lcars-notifications\.css/);
    const lcars = fs.readFileSync(path.join(path.dirname(INDEX_HTML), 'js', 'lcars.js'), 'utf8');
    assert.match(lcars, /const SECTIONS = \[[^\]]*'notifications'/);
});
