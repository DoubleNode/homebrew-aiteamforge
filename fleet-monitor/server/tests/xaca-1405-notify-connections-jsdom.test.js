//
//  xaca-1405-notify-connections-jsdom.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1405: boots the REAL shipped dashboard pages (v1 lcars/lcars-dashboard.html and
 * v2 lcars2/lcars-all.html, every local <script> executed in document order, including the
 * real fleet-api-auth.js) in jsdom against a stubbed /api/notify backend, and asserts the
 * NOTIFICATIONS (Notification Connections) section end to end:
 *
 *   - XSS: a hostile label / param / id / provider / delivery error / server message / test
 *     result renders as inert text, never as markup or a handler
 *   - secrets are write-only: never in the DOM after load or after submit, secret inputs are
 *     password + autocomplete=off and are emptied once the request is sent
 *   - an edit with a blank secret OMITS `secrets` from the PUT body; an explicit clear sends null
 *   - a GET 401 renders LOCKED with an UNLOCK button that calls FleetApiAuth.unlock
 *   - a disabled store renders the reason and offers no ADD
 *   - last delivery = newest receipt per connection (settled stage beats `accepted`)
 *   - delete (and a real test send) require a confirm step that names the connection
 *   - client-side validation blocks a bad submit before any request is made
 *   - the poll runs only while the section is the visible one
 *
 * The list / XSS / locked cases run against both trees so the shared script and each tree's
 * markup cannot drift apart unnoticed.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const PUB = path.join(__dirname, '..', 'public');
const SENTINEL = 'SENTINEL-s3cret-' + crypto.randomBytes(6).toString('hex');
const HOSTILE = '<img src=x onerror="window.__pwn=1">';
const ALL_PROVIDERS = ['email', 'imessage', 'ntfy', 'pushover', 'slack', 'stub', 'teams', 'test'];

const TREES = {
    v1: { html: 'lcars/lcars-dashboard.html' },
    v2: { html: 'lcars2/lcars-all.html' }
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(fn, ms) {
    const end = Date.now() + (ms || 3000);
    while (Date.now() < end) { try { if (fn()) return true; } catch (e) { /* not yet */ } await sleep(15); }
    return false;
}

const iso = (minsAgo) => new Date(Date.now() - minsAgo * 60000).toISOString();

function conn(over) {
    return Object.assign({
        id: 'work-slack', provider: 'slack', label: 'Work Slack', params: {}, secrets: { webhookUrl: 'set' },
        createdAt: iso(100), updatedAt: iso(100)
    }, over);
}

// A tiny in-memory stand-in for the admin-tier /api/notify routes.
function makeApi(over) {
    const api = Object.assign({
        status: { enabled: true, reason: null, providers: ALL_PROVIDERS },
        conns: [], receipts: [], locked: false, calls: [],
        createError: null, putError: null, testResult: null
    }, over || {});
    api.handle = function (method, url, body) {
        const p = url.replace(/^\/api\/notify/, '').split('?')[0];
        const respond = (status, data) => ({ status, data });
        if (api.locked && method === 'GET') return respond(401, { error: 'unauthorized' });
        if (method === 'GET' && p === '/status') return respond(200, api.status);
        if (!api.status.enabled && p !== '/status') return respond(503, { error: 'store_disabled', message: 'notify store disabled: ' + api.status.reason });
        if (method === 'GET' && p === '/connections') return respond(200, { connections: api.conns });
        if (method === 'GET' && p === '/receipts') return respond(200, { receipts: api.receipts });
        if (method === 'POST' && p === '/connections') {
            if (api.createError) return respond(400, { error: 'invalid', message: api.createError });
            const secrets = {};
            Object.keys(body.secrets || {}).forEach((k) => { if (body.secrets[k]) secrets[k] = 'set'; });
            const c = { id: body.id, provider: body.provider, label: body.label, params: body.params, secrets };
            api.conns.push(c);
            return respond(201, c);
        }
        let m = /^\/connections\/([^/]+)\/test$/.exec(p);
        if (method === 'POST' && m) return respond(200, api.testResult || { ok: true, validated: true, sent: !!(body && body.send) });
        m = /^\/connections\/([^/]+)$/.exec(p);
        if (method === 'PUT' && m) {
            if (api.putError) return respond(400, { error: 'invalid', message: api.putError });
            const c = api.conns.find((x) => x.id === decodeURIComponent(m[1]));
            if (!c) return respond(404, { error: 'not_found', message: 'connection not found' });
            if (body.label !== undefined) c.label = body.label;
            if (body.params !== undefined) c.params = body.params;
            Object.keys(body.secrets || {}).forEach((k) => { if (body.secrets[k] === null || body.secrets[k] === '') delete c.secrets[k]; else c.secrets[k] = 'set'; });
            return respond(200, c);
        }
        if (method === 'DELETE' && m) {
            const i = api.conns.findIndex((x) => x.id === decodeURIComponent(m[1]));
            if (i < 0) return respond(404, { error: 'not_found', message: 'connection not found' });
            api.conns.splice(i, 1);
            return respond(200, { deleted: m[1] });
        }
        return respond(404, {});
    };
    return api;
}

async function boot(tree, api) {
    const T = TREES[tree];
    const html = fs.readFileSync(path.join(PUB, T.html), 'utf8');
    const dom = new JSDOM(html, { url: 'http://localhost:1/' + T.html, runScripts: 'outside-only', pretendToBeVisual: true });
    const w = dom.window;
    w.fetch = async (u, init) => {
        const url = String(u);
        if (/^\/api\/notify(\/|$)/.test(url)) {
            const method = String((init && init.method) || 'GET').toUpperCase();
            let body;
            if (init && typeof init.body === 'string') body = JSON.parse(init.body);
            api.calls.push({ method, url, body });
            const out = api.handle(method, url, body);
            return { ok: out.status >= 200 && out.status < 300, status: out.status, json: async () => JSON.parse(JSON.stringify(out.data)), text: async () => JSON.stringify(out.data) };
        }
        return { ok: false, status: 404, json: async () => ({}), text: async () => '' };
    };
    w.EventSource = function () { this.close = function () {}; };
    // Skip the animated startup sequence: it defers LCARS.sections.init() (the sidebar click
    // binding) until it finishes, which would leave the nav inert for the test.
    try { w.localStorage.setItem('lcars-skip-startup', 'true'); } catch (e) { /* storage blocked */ }
    w.console.error = function () {}; w.console.log = function () {}; w.console.warn = function () {};
    const errors = [];
    w.addEventListener('error', (e) => errors.push(e.message));
    const srcs = Array.from(w.document.querySelectorAll('script[src]')).map((s) => s.getAttribute('src')).filter((s) => !/^https?:/.test(s));
    assert.ok(srcs.some((s) => /lcars-notify-connections\.js/.test(s)), tree + ': page loads lcars-notify-connections.js');
    for (const s of srcs) {
        const f = path.join(PUB, path.dirname(T.html), s.split('?')[0]);
        try { w.eval(fs.readFileSync(f, 'utf8')); } catch (e) { errors.push(s + ': ' + e.message); }
    }
    w.document.dispatchEvent(new w.Event('DOMContentLoaded'));
    const d = w.document;
    return { w, d, api, errors, close() { try { w.LCARSNotifyConnections.stop(); w.close(); } catch (e) { /* already closed */ } } };
}

async function openSection(pg) {
    const btn = pg.d.querySelector('.sidebar-button[data-section="notifications"]');
    assert.ok(btn, 'sidebar button exists');
    btn.click();
    return until(() => !pg.d.querySelector('#notify-content .empty-state-text') || !/LOADING/.test(pg.d.getElementById('notify-content').textContent), 3000);
}

const content = (pg) => pg.d.getElementById('notify-content');
const rowFor = (pg, id) => Array.from(pg.d.querySelectorAll('#notify-content tr[data-id]')).find((r) => r.getAttribute('data-id') === id);
const btnIn = (root, act) => root.querySelector('button[data-act="' + act + '"]');
const callsTo = (api, method, re) => api.calls.filter((c) => c.method === method && re.test(c.url));

// The picker defaults to the first available provider (teams); switch like an operator would.
async function pickProvider(pg, name) {
    const prov = pg.d.getElementById('nf-provider');
    prov.value = name;
    prov.dispatchEvent(new pg.w.Event('change', { bubbles: true }));
    assert.equal(pg.d.getElementById('nf-provider').value, name);
}

async function openEdit(pg, id) {
    btnIn(rowFor(pg, id), 'edit').click();
    assert.ok(await until(() => pg.d.getElementById('nf-label')), 'edit form opened');
}

// ---------------------------------------------------------------------------
// Both trees
// ---------------------------------------------------------------------------

for (const tree of ['v1', 'v2']) {
    test(tree + ': sidebar button, section and script are wired; list shows label, provider, id, params, secrets', async () => {
        const api = makeApi({
            conns: [
                conn(),
                conn({ id: 'mail', provider: 'email', label: 'Gmail', params: { host: 'smtp.example.com', port: 587, from: 'a@example.com', to: 'b@example.com', secure: 'starttls' }, secrets: { user: 'set', pass: 'set' } }),
                conn({ id: 'sms', provider: 'imessage', label: 'My phone', params: { recipient: '+15551234567', minSeverity: 'high', pool: ['m1', 'm2'] }, secrets: {} }),
                conn({ id: 'ntfy-1', provider: 'ntfy', label: 'Phone push', params: {}, secrets: { topic: 'set' } })
            ]
        });
        const pg = await boot(tree, api);
        try {
            assert.ok(await openSection(pg));
            const sec = pg.d.querySelector('.lcars-section[data-section="notifications"]');
            assert.ok(sec, 'section markup present');
            assert.equal(pg.errors.filter((e) => /notify/i.test(e)).length, 0, pg.errors.join('|'));
            assert.equal(content(pg).querySelectorAll('tr[data-id]').length, 4);
            const slack = rowFor(pg, 'work-slack').textContent;
            assert.match(slack, /Work Slack/);
            assert.match(slack, /Slack/);
            assert.match(slack, /webhookUrl: set/);
            assert.match(rowFor(pg, 'mail').textContent, /host\s*smtp\.example\.com/);
            assert.match(rowFor(pg, 'mail').textContent, /user: set/);
            assert.match(rowFor(pg, 'mail').textContent, /pass: set/);
            assert.match(rowFor(pg, 'sms').textContent, /SMS \/ iMessage/);
            assert.match(rowFor(pg, 'sms').textContent, /m1, m2/);
            assert.match(rowFor(pg, 'sms').textContent, /none/);
            assert.match(rowFor(pg, 'ntfy-1').textContent, /topic: set/);
            assert.match(rowFor(pg, 'ntfy-1').textContent, /token: not set/);
            assert.match(rowFor(pg, 'work-slack').textContent, /no deliveries yet/);
        } finally { pg.close(); }
    });

    test(tree + ': hostile label / param / id / provider / delivery error render inert', async () => {
        const api = makeApi({
            conns: [conn({
                id: 'evil', provider: '<b>nope</b>', label: HOSTILE,
                params: { host: HOSTILE, 'k"><script>window.__pwn=2</script>': 'v' }, secrets: { '<i>s</i>': 'set' }
            })],
            receipts: [{ id: 'r1', ts: iso(2), team: 'fleet', type: 'test', severity: 'info', connectionId: 'evil', provider: 'x', ok: false, error: HOSTILE + '<script>window.__pwn=3</script>' }]
        });
        const pg = await boot(tree, api);
        try {
            assert.ok(await openSection(pg));
            const c = content(pg);
            assert.ok(await until(() => c.querySelector('tr[data-id]')));
            assert.equal(c.querySelectorAll('img, script, b, i').length, 0, 'no element was injected');
            assert.equal(pg.w.__pwn, undefined, 'no handler ran');
            assert.ok(c.textContent.includes(HOSTILE), 'the hostile text is shown literally');
            assert.ok(!/onerror=/.test(Array.from(c.querySelectorAll('*')).map((e) => e.getAttributeNames().join(' ')).join(' ')), 'no attribute was injected');
        } finally { pg.close(); }
    });

    test(tree + ': GET 401 renders LOCKED with an UNLOCK button that calls FleetApiAuth.unlock, then loads', async () => {
        const api = makeApi({ locked: true, conns: [conn()] });
        const pg = await boot(tree, api);
        try {
            assert.ok(await openSection(pg));
            assert.match(content(pg).textContent, /LOCKED/);
            assert.match(content(pg).textContent, /ADMIN KEY REQUIRED/);
            assert.equal(pg.d.querySelectorAll('#notify-toolbar button').length, 0, 'no ADD while locked');
            assert.equal(content(pg).querySelectorAll('tr[data-id]').length, 0);
            let unlockCalls = 0;
            pg.w.FleetApiAuth.unlock = async () => { unlockCalls += 1; api.locked = false; return true; };
            btnIn(content(pg), 'unlock').click();
            assert.ok(await until(() => rowFor(pg, 'work-slack')), 'list loads after unlock');
            assert.equal(unlockCalls, 1);
        } finally { pg.close(); }
    });
}

// ---------------------------------------------------------------------------
// States
// ---------------------------------------------------------------------------

test('store_disabled: shows the reason and how to fix it, offers no ADD, makes no connection calls', async () => {
    const api = makeApi({ status: { enabled: false, reason: 'NOTIFY_STORE_KEY is not set', providers: ALL_PROVIDERS } });
    const pg = await boot('v1', api);
    try {
        assert.ok(await openSection(pg));
        assert.match(content(pg).textContent, /NOTIFICATION STORE DISABLED/);
        assert.match(content(pg).textContent, /NOTIFY_STORE_KEY is not set/);
        assert.equal(pg.d.querySelectorAll('#notify-toolbar button').length, 0);
        assert.equal(callsTo(api, 'GET', /\/connections/).length, 0, 'does not hit 503 routes');
    } finally { pg.close(); }
});

test('store_disabled arriving as a 503 from /connections (after an enabled status) also renders the disabled state', async () => {
    const api = makeApi();
    const orig = api.handle;
    api.handle = (m, u, b) => (m === 'GET' && /\/connections/.test(u) ? { status: 503, data: { error: 'store_disabled', message: 'notify store disabled: ' + HOSTILE } } : orig(m, u, b));
    const pg = await boot('v1', api);
    try {
        assert.ok(await openSection(pg));
        assert.match(content(pg).textContent, /NOTIFICATION STORE DISABLED/);
        assert.equal(content(pg).querySelectorAll('img').length, 0);
    } finally { pg.close(); }
});

test('empty store: NO CONNECTIONS CONFIGURED with an ADD button', async () => {
    const pg = await boot('v1', makeApi());
    try {
        assert.ok(await openSection(pg));
        assert.match(content(pg).textContent, /NO CONNECTIONS CONFIGURED/);
        assert.ok(btnIn(pg.d.getElementById('notify-toolbar'), 'add'));
    } finally { pg.close(); }
});

// ---------------------------------------------------------------------------
// Last delivery
// ---------------------------------------------------------------------------

test('last delivery is the NEWEST receipt per connection, whatever order the server returns', async () => {
    const api = makeApi({
        conns: [conn({ id: 'a', label: 'A' }), conn({ id: 'b', label: 'B' }), conn({ id: 'c', label: 'C' }), conn({ id: 'd', label: 'D', provider: 'imessage', params: { recipient: '+15551234567' }, secrets: {} })],
        receipts: [
            { id: 'r-old-fail', ts: iso(60), connectionId: 'a', ok: false, error: 'old failure text', type: 'build-failed', team: 'academy' },
            { id: 'r-new-ok', ts: iso(5), connectionId: 'a', ok: true, error: '', type: 'build-failed', team: 'academy' },
            { id: 'r-mid-fail', ts: iso(30), connectionId: 'a', ok: false, error: 'mid failure text', type: 'x', team: 'academy' },
            { id: 'r-b', ts: iso(3), connectionId: 'b', ok: false, error: '', suppressed: 'dedupe', type: 'x', team: 'academy' },
            // imessage: acceptance stub is the NEWER of the pair, the settled receipt must win
            { id: 'r-d-acc', ts: iso(1), connectionId: 'd', ok: true, error: '', stage: 'accepted', providerMessageId: 'pm-9', type: 'x', team: 'academy' },
            { id: 'r-d-del', ts: iso(2), connectionId: 'd', ok: false, error: 'relay could not send', stage: 'failed', providerMessageId: 'pm-9', type: 'x', team: 'academy' },
            { id: 'r-other', ts: iso(1), connectionId: 'ghost', ok: true, error: '', type: 'x', team: 'academy' }
        ]
    });
    const pg = await boot('v1', api);
    try {
        assert.ok(await openSection(pg));
        assert.ok(await until(() => rowFor(pg, 'a')));
        const a = rowFor(pg, 'a').textContent;
        assert.match(a, /DELIVERED/);
        assert.ok(!/old failure text|mid failure text/.test(a), 'older receipts are not shown');
        assert.match(rowFor(pg, 'b').textContent, /SUPPRESSED \(dedupe\)/);
        assert.match(rowFor(pg, 'c').textContent, /no deliveries yet/);
        const dd = rowFor(pg, 'd').textContent;
        assert.match(dd, /FAILED/);
        assert.match(dd, /relay could not send/);
        assert.ok(!/ACCEPTED/.test(dd), 'the settled stage replaces the acceptance stub');
        assert.match(a, /\d+m ago|just now/);
        // the receipts call asks for the maximum window
        assert.ok(callsTo(api, 'GET', /\/receipts\?limit=200$/).length >= 1);
    } finally { pg.close(); }
});

test('an unsettled imessage receipt shows ACCEPTED, AWAITING RELAY; a test receipt is labelled', async () => {
    const api = makeApi({
        conns: [conn({ id: 'd', label: 'D', provider: 'imessage', params: { recipient: '+15551234567' }, secrets: {} })],
        receipts: [{ id: 'r1', ts: iso(1), connectionId: 'd', ok: true, error: '', stage: 'accepted', providerMessageId: 'pm-1', type: 'test', team: 'fleet' }]
    });
    const pg = await boot('v1', api);
    try {
        assert.ok(await openSection(pg));
        assert.ok(await until(() => rowFor(pg, 'd')));
        assert.match(rowFor(pg, 'd').textContent, /ACCEPTED, AWAITING RELAY/);
        assert.match(rowFor(pg, 'd').textContent, /\(test\)/);
    } finally { pg.close(); }
});

// ---------------------------------------------------------------------------
// Add form
// ---------------------------------------------------------------------------

test('provider picker comes from /status, hides test/stub and unregistered providers, and labels imessage as SMS / iMessage', async () => {
    const api = makeApi({ status: { enabled: true, reason: null, providers: ['imessage', 'slack', 'stub', 'test'] } });
    const pg = await boot('v1', api);
    try {
        assert.ok(await openSection(pg));
        btnIn(pg.d.getElementById('notify-toolbar'), 'add').click();
        assert.ok(await until(() => pg.d.getElementById('nf-provider')));
        const opts = Array.from(pg.d.getElementById('nf-provider').options).map((o) => o.value + '|' + o.textContent);
        assert.deepEqual(opts, ['slack|Slack', 'imessage|SMS / iMessage']);
    } finally { pg.close(); }
});

test('create: secret inputs are password + autocomplete=off, the body carries the secret once, and the DOM holds it nowhere afterwards', async () => {
    const api = makeApi();
    const pg = await boot('v1', api);
    try {
        assert.ok(await openSection(pg));
        btnIn(pg.d.getElementById('notify-toolbar'), 'add').click();
        assert.ok(await until(() => pg.d.getElementById('nf-id')));
        await pickProvider(pg, 'slack');
        pg.d.getElementById('nf-id').value = 'work-slack';
        pg.d.getElementById('nf-label').value = '  Work Slack  ';
        const sec = pg.d.getElementById('nf-s-webhookUrl');
        assert.equal(sec.type, 'password');
        assert.equal(sec.getAttribute('autocomplete'), 'off');
        assert.equal(sec.getAttribute('value'), null, 'never prefilled');
        sec.value = 'https://hooks.slack.com/services/T000/B000/' + SENTINEL;
        pg.d.getElementById('nf-save').click();
        assert.ok(await until(() => callsTo(api, 'POST', /\/connections$/).length === 1));
        const post = callsTo(api, 'POST', /\/connections$/)[0];
        assert.equal(post.body.id, 'work-slack');
        assert.equal(post.body.provider, 'slack');
        assert.equal(post.body.label, 'Work Slack');
        assert.deepEqual(post.body.params, {});
        assert.equal(post.body.secrets.webhookUrl, 'https://hooks.slack.com/services/T000/B000/' + SENTINEL);
        assert.ok(await until(() => rowFor(pg, 'work-slack')), 'list refreshed with the new connection');
        assert.ok(!pg.d.documentElement.outerHTML.includes(SENTINEL), 'secret not in the DOM markup');
        assert.ok(!Array.from(pg.d.querySelectorAll('input')).some((i) => i.value.includes(SENTINEL)), 'secret not in any input value');
        assert.ok(pg.d.getElementById('notify-form-panel').hidden, 'form closed');
        assert.match(rowFor(pg, 'work-slack').textContent, /webhookUrl: set/);
    } finally { pg.close(); }
});

test('create: a server 400 message shows inline as inert text, the form stays open, secret inputs are emptied', async () => {
    const api = makeApi({ createError: 'slack webhookUrl must be a Slack incoming-webhook URL ' + HOSTILE });
    const pg = await boot('v1', api);
    try {
        assert.ok(await openSection(pg));
        btnIn(pg.d.getElementById('notify-toolbar'), 'add').click();
        assert.ok(await until(() => pg.d.getElementById('nf-id')));
        await pickProvider(pg, 'slack');
        pg.d.getElementById('nf-id').value = 'work-slack';
        pg.d.getElementById('nf-label').value = 'Work';
        pg.d.getElementById('nf-s-webhookUrl').value = 'https://hooks.slack.com/services/T000/B000/' + SENTINEL;
        pg.d.getElementById('nf-save').click();
        assert.ok(await until(() => /incoming-webhook/.test(pg.d.getElementById('nf-errors').textContent)));
        const errs = pg.d.getElementById('nf-errors');
        assert.ok(errs.textContent.includes(HOSTILE), 'literal text');
        assert.equal(errs.querySelectorAll('img').length, 0);
        assert.equal(pg.w.__pwn, undefined);
        assert.equal(pg.d.getElementById('nf-s-webhookUrl').value, '', 'secret input emptied after the request');
        assert.ok(!pg.d.documentElement.outerHTML.includes(SENTINEL));
        assert.ok(!pg.d.getElementById('notify-form-panel').hidden, 'form stays open for a retry');
        assert.equal(pg.d.getElementById('nf-id').value, 'work-slack', 'non-secret fields kept');
        assert.equal(pg.d.getElementById('nf-save').disabled, false, 'SAVE re-enabled');
    } finally { pg.close(); }
});

test('client-side validation blocks a bad submit before any request', async () => {
    const api = makeApi();
    const pg = await boot('v1', api);
    try {
        assert.ok(await openSection(pg));
        btnIn(pg.d.getElementById('notify-toolbar'), 'add').click();
        assert.ok(await until(() => pg.d.getElementById('nf-id')));
        const errText = () => pg.d.getElementById('nf-errors').textContent;
        const submit = () => { pg.d.getElementById('nf-save').click(); };
        await pickProvider(pg, 'slack');

        // bad id + empty label + missing required secret
        pg.d.getElementById('nf-id').value = 'Bad ID';
        submit();
        assert.match(errText(), /Id must start with a lowercase letter/);
        assert.match(errText(), /Label is required/);
        assert.match(errText(), /Webhook URL is required/);

        // slack URL must be hooks.slack.com
        pg.d.getElementById('nf-id').value = 'ok-id';
        pg.d.getElementById('nf-label').value = 'L';
        pg.d.getElementById('nf-s-webhookUrl').value = 'https://evil.example.com/services/T/B/x';
        submit();
        assert.match(errText(), /Slack incoming-webhook URL/);

        // email: user without password; bad port; bad address
        await pickProvider(pg, 'email');
        assert.ok(await until(() => pg.d.getElementById('nf-p-host')));
        pg.d.getElementById('nf-id').value = 'mail';
        pg.d.getElementById('nf-label').value = 'Mail';
        pg.d.getElementById('nf-p-host').value = 'smtp.example.com';
        pg.d.getElementById('nf-p-port').value = '99999';
        pg.d.getElementById('nf-p-from').value = 'not-an-address';
        pg.d.getElementById('nf-p-to').value = 'a@example.com, b@example.com';
        pg.d.getElementById('nf-s-user').value = 'me';
        submit();
        assert.match(errText(), /Port must be a number from 1 to 65535/);
        assert.match(errText(), /From must be an email address/);
        assert.match(errText(), /user and password must be set together/);
        assert.ok(!/To must be/.test(errText()), 'a valid To list passes');

        // imessage: recipient
        await pickProvider(pg, 'imessage');
        assert.ok(await until(() => pg.d.getElementById('nf-p-recipient')));
        assert.equal(pg.d.getElementById('nf-id').value, 'mail', 'id survives a provider switch');
        pg.d.getElementById('nf-p-recipient').value = '555-1234';
        submit();
        assert.match(errText(), /Recipient must be an E\.164 number/);

        assert.equal(callsTo(api, 'POST', /\/connections$/).length, 0, 'nothing was sent');
    } finally { pg.close(); }
});

// ---------------------------------------------------------------------------
// Edit form
// ---------------------------------------------------------------------------

test('edit: provider and id are fixed, secrets are never prefilled, and a blank secret is OMITTED from the PUT body', async () => {
    const api = makeApi({
        conns: [conn({ id: 'mail', provider: 'email', label: 'Gmail', params: { host: 'smtp.example.com', port: 587, from: 'a@example.com', to: ['b@example.com', 'c@example.com'], secure: 'starttls' }, secrets: { user: 'set', pass: 'set' } })]
    });
    const pg = await boot('v1', api);
    try {
        assert.ok(await openSection(pg));
        assert.ok(await until(() => rowFor(pg, 'mail')));
        await openEdit(pg, 'mail');
        assert.equal(pg.d.getElementById('nf-id'), null, 'id is not editable');
        assert.equal(pg.d.getElementById('nf-provider'), null, 'provider is not editable');
        assert.match(pg.d.getElementById('notify-form-panel').textContent, /fixed/);
        for (const f of ['user', 'pass']) {
            const i = pg.d.getElementById('nf-s-' + f);
            assert.equal(i.type, 'password');
            assert.equal(i.value, '');
            assert.equal(i.getAttribute('value'), null);
            assert.match(i.getAttribute('placeholder'), /set — leave blank to keep/);
        }
        assert.equal(pg.d.getElementById('nf-p-to').value, 'b@example.com, c@example.com');
        pg.d.getElementById('nf-label').value = 'Gmail (renamed)';
        pg.d.getElementById('nf-save').click();
        assert.ok(await until(() => callsTo(api, 'PUT', /\/connections\/mail$/).length === 1));
        const put = callsTo(api, 'PUT', /\/connections\/mail$/)[0];
        assert.equal(put.body.label, 'Gmail (renamed)');
        assert.deepEqual(put.body.params, { host: 'smtp.example.com', port: 587, from: 'a@example.com', to: 'b@example.com, c@example.com', secure: 'starttls' });
        assert.ok(!Object.prototype.hasOwnProperty.call(put.body, 'secrets'), 'blank secrets are omitted entirely');
        assert.equal(put.body.id, undefined);
        assert.equal(put.body.provider, undefined);
        assert.ok(await until(() => /Gmail \(renamed\)/.test(rowFor(pg, 'mail').textContent)));
        assert.match(rowFor(pg, 'mail').textContent, /user: set/, 'stored secrets untouched');
    } finally { pg.close(); }
});

test('edit: a typed secret is sent alone; an explicit clear sends null; replace+clear together is refused client-side', async () => {
    const api = makeApi({ conns: [conn({ id: 'n1', provider: 'ntfy', label: 'Push', params: {}, secrets: { topic: 'set', token: 'set' } })] });
    const pg = await boot('v1', api);
    try {
        assert.ok(await openSection(pg));
        assert.ok(await until(() => rowFor(pg, 'n1')));

        // 1. typed secret only
        await openEdit(pg, 'n1');
        pg.d.getElementById('nf-s-token').value = SENTINEL;
        pg.d.getElementById('nf-save').click();
        assert.ok(await until(() => callsTo(api, 'PUT', /\/connections\/n1$/).length === 1));
        assert.deepEqual(callsTo(api, 'PUT', /\/connections\/n1$/)[0].body.secrets, { token: SENTINEL });
        assert.ok(await until(() => pg.d.getElementById('notify-form-panel').hidden));
        assert.ok(!pg.d.documentElement.outerHTML.includes(SENTINEL));

        // 2. replace + clear on the same field -> refused, nothing sent
        await openEdit(pg, 'n1');
        pg.d.getElementById('nf-s-token').value = 'x';
        pg.d.getElementById('nf-c-token').checked = true;
        pg.d.getElementById('nf-save').click();
        assert.match(pg.d.getElementById('nf-errors').textContent, /enter a new value or tick clear, not both/);
        assert.equal(callsTo(api, 'PUT', /\/connections\/n1$/).length, 1);

        // 3. explicit clear
        pg.d.getElementById('nf-s-token').value = '';
        pg.d.getElementById('nf-save').click();
        assert.ok(await until(() => callsTo(api, 'PUT', /\/connections\/n1$/).length === 2));
        assert.deepEqual(callsTo(api, 'PUT', /\/connections\/n1$/)[1].body.secrets, { token: null });
        assert.ok(await until(() => /token: not set/.test(rowFor(pg, 'n1').textContent)));
    } finally { pg.close(); }
});

test('edit: clearing a REQUIRED secret is refused client-side (topic)', async () => {
    const api = makeApi({ conns: [conn({ id: 'n1', provider: 'ntfy', label: 'Push', params: {}, secrets: { topic: 'set' } })] });
    const pg = await boot('v1', api);
    try {
        assert.ok(await openSection(pg));
        assert.ok(await until(() => rowFor(pg, 'n1')));
        await openEdit(pg, 'n1');
        pg.d.getElementById('nf-c-topic').checked = true;
        pg.d.getElementById('nf-save').click();
        assert.match(pg.d.getElementById('nf-errors').textContent, /Topic is required/);
        assert.equal(callsTo(api, 'PUT', /\/connections\/n1$/).length, 0);
    } finally { pg.close(); }
});

test('an open form is NOT rebuilt by a poll refresh (typing is never clobbered)', async () => {
    const api = makeApi({ conns: [conn()] });
    const pg = await boot('v1', api);
    try {
        assert.ok(await openSection(pg));
        assert.ok(await until(() => rowFor(pg, 'work-slack')));
        await openEdit(pg, 'work-slack');
        pg.d.getElementById('nf-label').value = 'half typed';
        pg.d.getElementById('nf-s-webhookUrl').value = 'half-typed-secret';
        const before = callsTo(api, 'GET', /\/status$/).length;
        await pg.w.LCARSNotifyConnections.refresh();
        assert.ok(callsTo(api, 'GET', /\/status$/).length > before, 'a refresh really ran');
        assert.equal(pg.d.getElementById('nf-label').value, 'half typed');
        assert.equal(pg.d.getElementById('nf-s-webhookUrl').value, 'half-typed-secret');
    } finally { pg.close(); }
});

// ---------------------------------------------------------------------------
// Test / send test / delete
// ---------------------------------------------------------------------------

test('TEST validates (send:false) and shows the result inline; a hostile error stays inert', async () => {
    const api = makeApi({ conns: [conn()], testResult: { ok: false, validated: false, sent: false, error: 'bad ' + HOSTILE } });
    const pg = await boot('v1', api);
    try {
        assert.ok(await openSection(pg));
        assert.ok(await until(() => rowFor(pg, 'work-slack')));
        btnIn(rowFor(pg, 'work-slack'), 'test').click();
        assert.ok(await until(() => callsTo(api, 'POST', /\/connections\/work-slack\/test$/).length === 1));
        assert.deepEqual(callsTo(api, 'POST', /\/connections\/work-slack\/test$/)[0].body, { send: false });
        assert.ok(await until(() => /INVALID/.test(rowFor(pg, 'work-slack').textContent)));
        const row = rowFor(pg, 'work-slack');
        assert.ok(row.textContent.includes(HOSTILE));
        assert.equal(row.querySelectorAll('img').length, 0);
        assert.equal(pg.w.__pwn, undefined);

        api.testResult = null;
        btnIn(rowFor(pg, 'work-slack'), 'test').click();
        assert.ok(await until(() => /VALID — the configuration passes/.test(rowFor(pg, 'work-slack').textContent)));
    } finally { pg.close(); }
});

test('SEND TEST asks first (naming the connection), does nothing on CANCEL, sends {send:true} on CONFIRM and refreshes last delivery', async () => {
    const api = makeApi({ conns: [conn({ label: HOSTILE })] });
    const pg = await boot('v1', api);
    try {
        assert.ok(await openSection(pg));
        assert.ok(await until(() => rowFor(pg, 'work-slack')));
        btnIn(rowFor(pg, 'work-slack'), 'send').click();
        let row = rowFor(pg, 'work-slack');
        assert.match(row.textContent, /Send a REAL test notification/);
        assert.ok(row.querySelector('.notify-confirm').textContent.includes(HOSTILE), 'confirm names the connection (as text)');
        assert.equal(row.querySelectorAll('img').length, 0);
        assert.equal(callsTo(api, 'POST', /\/test$/).length, 0, 'no request before confirm');

        btnIn(row, 'cancel').click();
        assert.equal(callsTo(api, 'POST', /\/test$/).length, 0);
        assert.ok(btnIn(rowFor(pg, 'work-slack'), 'send'), 'back to the normal buttons');

        btnIn(rowFor(pg, 'work-slack'), 'send').click();
        api.receipts = [{ id: 'r1', ts: iso(0), connectionId: 'work-slack', ok: true, error: '', type: 'test', team: 'fleet' }];
        btnIn(rowFor(pg, 'work-slack'), 'send-confirm').click();
        assert.ok(await until(() => callsTo(api, 'POST', /\/test$/).length === 1));
        assert.deepEqual(callsTo(api, 'POST', /\/test$/)[0].body, { send: true });
        assert.ok(await until(() => /TEST SENT/.test(rowFor(pg, 'work-slack').textContent)));
        assert.ok(await until(() => /DELIVERED/.test(rowFor(pg, 'work-slack').textContent) && /\(test\)/.test(rowFor(pg, 'work-slack').textContent)), 'last delivery picked up the test receipt');
    } finally { pg.close(); }
});

test('a failed test send shows SEND FAILED with the (escaped) error', async () => {
    const api = makeApi({ conns: [conn()], testResult: { ok: false, validated: true, sent: false, error: 'HTTP 410 ' + HOSTILE } });
    const pg = await boot('v1', api);
    try {
        assert.ok(await openSection(pg));
        assert.ok(await until(() => rowFor(pg, 'work-slack')));
        btnIn(rowFor(pg, 'work-slack'), 'send').click();
        btnIn(rowFor(pg, 'work-slack'), 'send-confirm').click();
        assert.ok(await until(() => /SEND FAILED/.test(rowFor(pg, 'work-slack').textContent)));
        assert.ok(rowFor(pg, 'work-slack').textContent.includes(HOSTILE));
        assert.equal(rowFor(pg, 'work-slack').querySelectorAll('img').length, 0);
    } finally { pg.close(); }
});

test('DELETE requires a confirm that names the (escaped) label; CANCEL and the first click send nothing', async () => {
    const api = makeApi({ conns: [conn({ label: HOSTILE }), conn({ id: 'other', label: 'Other' })] });
    const pg = await boot('v1', api);
    try {
        assert.ok(await openSection(pg));
        assert.ok(await until(() => rowFor(pg, 'work-slack')));
        btnIn(rowFor(pg, 'work-slack'), 'delete').click();
        let row = rowFor(pg, 'work-slack');
        assert.match(row.textContent, /Delete connection/);
        assert.ok(row.querySelector('.notify-confirm').textContent.includes(HOSTILE));
        assert.equal(row.querySelectorAll('img').length, 0);
        assert.equal(callsTo(api, 'DELETE', /./).length, 0, 'first click does not delete');

        btnIn(row, 'cancel').click();
        assert.equal(callsTo(api, 'DELETE', /./).length, 0, 'cancel does not delete');
        assert.ok(rowFor(pg, 'work-slack'));

        // a second confirm elsewhere replaces the first one
        btnIn(rowFor(pg, 'work-slack'), 'delete').click();
        btnIn(rowFor(pg, 'other'), 'delete').click();
        assert.ok(!btnIn(rowFor(pg, 'work-slack'), 'delete-confirm'), 'only one confirm open at a time');

        btnIn(rowFor(pg, 'other'), 'delete-confirm').click();
        assert.ok(await until(() => callsTo(api, 'DELETE', /./).length === 1));
        assert.match(callsTo(api, 'DELETE', /./)[0].url, /\/connections\/other$/);
        assert.ok(await until(() => !rowFor(pg, 'other')), 'row removed after the refresh');
        assert.ok(rowFor(pg, 'work-slack'), 'the other connection is untouched');
    } finally { pg.close(); }
});

// ---------------------------------------------------------------------------
// Polling
// ---------------------------------------------------------------------------

test('the poll starts on activation and stops when another section is shown', async () => {
    const api = makeApi({ conns: [conn()] });
    const pg = await boot('v1', api);
    try {
        assert.equal(pg.w.LCARSNotifyConnections.polling(), false, 'no poll while the section is hidden');
        assert.equal(callsTo(api, 'GET', /\/status$/).length, 0, 'no request while the section is hidden');
        assert.ok(await openSection(pg));
        assert.equal(pg.w.LCARSNotifyConnections.polling(), true, 'poll armed by activating the section');
        pg.d.querySelector('.sidebar-button[data-section="overview"]').click();
        assert.ok(await until(() => pg.w.LCARSNotifyConnections.polling() === false), 'poll stopped on leaving');
        const seen = api.calls.length;
        await pg.w.LCARSNotifyConnections.refresh();   // an explicit refresh is still possible, but nothing re-arms the timer
        assert.equal(pg.w.LCARSNotifyConnections.polling(), false);
        assert.ok(api.calls.length > seen);
    } finally { pg.close(); }
});

test('a failed poll after a good render keeps the last good list and flags UPDATE FAILED', async () => {
    const api = makeApi({ conns: [conn()] });
    const pg = await boot('v1', api);
    try {
        assert.ok(await openSection(pg));
        assert.ok(await until(() => rowFor(pg, 'work-slack')));
        const orig = api.handle;
        api.handle = (m, u, b) => (m === 'GET' && /\/connections$/.test(u) ? { status: 500, data: { error: 'internal_error', message: 'internal error' } } : orig(m, u, b));
        await pg.w.LCARSNotifyConnections.refresh();
        assert.ok(rowFor(pg, 'work-slack'), 'last good list kept');
        assert.match(pg.d.getElementById('notify-status').textContent, /UPDATE FAILED/);
    } finally { pg.close(); }
});
