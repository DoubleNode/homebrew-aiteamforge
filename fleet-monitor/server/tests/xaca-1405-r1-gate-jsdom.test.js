//
//  xaca-1405-r1-gate-jsdom.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1405 gate round 1 (PR #1130). Boots the REAL v1 and v2 dashboard pages in jsdom against a
 * stubbed /api/notify backend (same harness as xaca-1405-notify-connections-jsdom.test.js) and pins:
 *
 *   016  editing a connection whose provider the UI has no table for (server-registered `test`,
 *        a future provider) is a label-only edit: no throw, PUT body is exactly {label}
 *   011  WCAG 2.5.3 Label-in-Name: every button's aria-label starts with its visible words
 *   012  per-field errors: aria-invalid + aria-describedby, summary kept, focus on first invalid
 *   013  a DIRTY form is never silently discarded by EDIT-elsewhere / + ADD CONNECTION
 *   014  after a delete, focus lands on the next row (else previous, else + ADD CONNECTION)
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

const submit = (pg) => pg.d.getElementById('nf-save').click();
const setVal = (pg, id, v) => { pg.d.getElementById(id).value = v; };
const errsOf = (pg) => pg.d.getElementById('nf-errors').textContent;
const rowsReady = (pg, n) => until(() => pg.d.querySelectorAll('#notify-content tr[data-id]').length === n);
const withProviders = (extra) => ALL_PROVIDERS.concat(extra || []);

// ---------------------------------------------------------------------------
// 016: unknown provider edit
// ---------------------------------------------------------------------------

for (const tree of ['v1', 'v2']) {
    for (const prov of ['test', 'future-x']) {
        test('016 ' + tree + ': provider ' + prov + ' (no UI table): EDIT opens label-only, SAVE sends {label}, blank label shows an error, nothing throws', async () => {
            const api = makeApi({
                status: { enabled: true, reason: null, providers: withProviders(['future-x']) },
                conns: [conn({ id: 'odd', provider: prov, label: 'Odd one', params: { k: 'v' }, secrets: {} })]
            });
            const pg = await boot(tree, api);
            try {
                assert.ok(await openSection(pg));
                assert.ok(await rowsReady(pg, 1));
                await openEdit(pg, 'odd');
                const panel = pg.d.getElementById('notify-form-panel');
                assert.match(panel.textContent, /not editable here/);
                assert.ok(panel.textContent.includes(prov), 'names the provider');
                assert.equal(panel.querySelectorAll('input[type="password"]').length, 0, 'no secret inputs invented');
                assert.equal(pg.d.getElementById('nf-label').value, 'Odd one');

                // blank label: visible error, no request
                setVal(pg, 'nf-label', '   ');
                submit(pg);
                assert.match(errsOf(pg), /Label is required/);
                assert.equal(pg.d.getElementById('nf-label').getAttribute('aria-invalid'), 'true');
                assert.equal(callsTo(api, 'PUT', /./).length, 0);

                // valid label: PUT {label} only
                setVal(pg, 'nf-label', '  Renamed odd  ');
                submit(pg);
                assert.ok(await until(() => callsTo(api, 'PUT', /./).length === 1), 'a PUT was sent');
                assert.deepEqual(callsTo(api, 'PUT', /./)[0].body, { label: 'Renamed odd' });
                assert.match(callsTo(api, 'PUT', /./)[0].url, /\/connections\/odd$/);
                assert.ok(await until(() => !pg.d.getElementById('nf-label')), 'form closed after save');
                assert.ok(await until(() => /Renamed odd/.test(rowFor(pg, 'odd').textContent)));
                assert.deepEqual(pg.errors, [], 'no window error: ' + pg.errors.join('|'));

                // the create picker still excludes providers the UI cannot build
                pg.d.querySelector('#notify-toolbar [data-act="add"]').click();
                const opts = Array.from(pg.d.getElementById('nf-provider').options).map((o) => o.value);
                assert.ok(!opts.includes('test') && !opts.includes('future-x') && !opts.includes('stub'), 'picker: ' + opts.join(','));
                assert.ok(opts.includes('slack'));
            } finally { pg.close(); }
        });
    }
}

// ---------------------------------------------------------------------------
// 011: WCAG 2.5.3 Label-in-Name
// ---------------------------------------------------------------------------

// Decision: the leading "+" of "+ ADD CONNECTION" is a decorative glyph, not a word, so it is stripped
// (any leading run of non-alphanumerics) before comparing; every other character must match.
const visibleName = (b) => b.textContent.replace(/\s+/g, ' ').trim().replace(/^[^A-Za-z0-9]+/, '').toLowerCase();

function auditButtons(pg, seen) {
    const all = pg.d.querySelectorAll('#notify-toolbar button, #notify-content button, #notify-form-panel button');
    const bad = [];
    all.forEach((b) => {
        const act = b.getAttribute('data-act') || (b.type === 'submit' ? 'save' : 'unknown');
        seen.add(act);
        const vis = visibleName(b);
        assert.ok(vis, 'every button has visible text (' + act + ')');
        const aria = b.getAttribute('aria-label');
        if (aria && !aria.trim().toLowerCase().startsWith(vis)) bad.push(act + ': visible "' + vis + '" vs aria-label "' + aria + '"');
    });
    assert.deepEqual(bad, [], 'Label-in-Name violations');
    return all.length;
}

for (const tree of ['v1', 'v2']) {
    test('011 ' + tree + ': every button aria-label starts with its visible text, across every rendered button kind', async () => {
        const api = makeApi({ conns: [conn({ id: 'a', label: 'Alpha' }), conn({ id: 'b', label: 'Bravo' })] });
        const pg = await boot(tree, api);
        const seen = new Set();
        try {
            assert.ok(await openSection(pg));
            assert.ok(await rowsReady(pg, 2));
            // rows + toolbar
            assert.ok(auditButtons(pg, seen) >= 9);
            // delete-confirm (+ cancel)
            btnIn(rowFor(pg, 'a'), 'delete').click();
            auditButtons(pg, seen);
            btnIn(rowFor(pg, 'a'), 'cancel').click();
            // send-confirm (+ cancel)
            btnIn(rowFor(pg, 'b'), 'send').click();
            auditButtons(pg, seen);
            btnIn(rowFor(pg, 'b'), 'cancel').click();
            // open form (SAVE, CANCEL) then the dirty-form prompt (DISCARD, KEEP EDITING)
            await openEdit(pg, 'a');
            auditButtons(pg, seen);
            setVal(pg, 'nf-label', 'Alpha changed');
            btnIn(rowFor(pg, 'b'), 'edit').click();
            assert.ok(pg.d.getElementById('nf-discard'));
            auditButtons(pg, seen);
            assert.equal(pg.errors.length, 0, pg.errors.join('|'));
        } finally { pg.close(); }

        const locked = await boot(tree, makeApi({ locked: true }));
        try {
            assert.ok(await openSection(locked));
            assert.ok(await until(() => btnIn(locked.d.getElementById('notify-content'), 'unlock')));
            auditButtons(locked, seen);
        } finally { locked.close(); }

        const expected = ['edit', 'test', 'send', 'delete', 'delete-confirm', 'send-confirm', 'cancel', 'add', 'unlock', 'form-cancel', 'save', 'discard-confirm', 'discard-cancel'];
        assert.deepEqual(expected.filter((k) => !seen.has(k)), [], 'the audit visited every button kind (not vacuous)');
    });

    test('011 ' + tree + ': the validate button reads VALIDATE (not the ambiguous TEST) and the named labels are exact', async () => {
        const api = makeApi({ conns: [conn({ id: 'a', label: 'Alpha' })] });
        const pg = await boot(tree, api);
        try {
            assert.ok(await openSection(pg));
            assert.ok(await rowsReady(pg, 1));
            const row = rowFor(pg, 'a');
            assert.equal(btnIn(row, 'test').textContent, 'VALIDATE');
            assert.equal(btnIn(row, 'test').getAttribute('aria-label'), 'Validate: Alpha');
            assert.equal(btnIn(row, 'send').getAttribute('aria-label'), 'Send test: Alpha');
            assert.equal(pg.d.querySelector('#notify-toolbar [data-act="add"]').getAttribute('aria-label'), 'Add connection');
            btnIn(row, 'send').click();
            assert.equal(btnIn(rowFor(pg, 'a'), 'send-confirm').getAttribute('aria-label'), 'Confirm send: Alpha');
        } finally { pg.close(); }
    });
}

// ---------------------------------------------------------------------------
// 012: per-field validation
// ---------------------------------------------------------------------------

for (const tree of ['v1', 'v2']) {
    test('012 ' + tree + ': failed submit marks each bad field aria-invalid + aria-describedby, keeps the summary, focuses the first invalid field, and re-validation clears the marks', async () => {
        const pg = await boot(tree, makeApi());
        try {
            assert.ok(await openSection(pg));
            pg.d.querySelector('#notify-toolbar [data-act="add"]').click();
            assert.ok(await until(() => pg.d.getElementById('nf-provider')));
            await pickProvider(pg, 'email');
            submit(pg);
            const invalid = () => Array.from(pg.d.querySelectorAll('#notify-form-panel [aria-invalid="true"]')).map((e) => e.id);
            assert.deepEqual(invalid(), ['nf-id', 'nf-label', 'nf-p-host', 'nf-p-from', 'nf-p-to']);
            for (const id of invalid()) {
                const el = pg.d.getElementById(id);
                const msg = pg.d.getElementById(el.getAttribute('aria-describedby'));
                assert.ok(msg, id + ' describedby target exists');
                assert.ok(msg.textContent.length > 5);
                assert.equal(msg.children.length, 0, 'message is plain text');
                assert.ok(pg.d.getElementById('nf-errors').textContent.includes(msg.textContent), 'summary still carries the message');
            }
            assert.equal(pg.d.activeElement.id, 'nf-id', 'focus on the first invalid field');
            assert.equal(callsTo(pg.api, 'POST', /./).length, 0);

            setVal(pg, 'nf-id', 'mail-1');
            submit(pg);
            assert.deepEqual(invalid(), ['nf-label', 'nf-p-host', 'nf-p-from', 'nf-p-to'], 'fixed field is cleared');
            assert.equal(pg.d.getElementById('nf-id').hasAttribute('aria-describedby'), false);
            assert.equal(pg.d.getElementById('nf-id-err'), null, 'stale message element removed');
            assert.equal(pg.d.activeElement.id, 'nf-label');
            assert.equal(pg.d.querySelectorAll('.notify-field-error').length, 4);
            assert.deepEqual(pg.errors, []);
        } finally { pg.close(); }
    });
}

// ---------------------------------------------------------------------------
// 013: dirty-form guard
// ---------------------------------------------------------------------------

for (const tree of ['v1', 'v2']) {
    test('013 ' + tree + ': a clean form is replaced without a prompt; a dirty one asks, KEEP EDITING keeps input, DISCARD proceeds', async () => {
        const api = makeApi({ conns: [conn({ id: 'a', label: 'Alpha' }), conn({ id: 'b', label: 'Bravo' })] });
        const pg = await boot(tree, api);
        try {
            assert.ok(await openSection(pg));
            assert.ok(await rowsReady(pg, 2));
            // clean -> no prompt
            await openEdit(pg, 'a');
            btnIn(rowFor(pg, 'b'), 'edit').click();
            assert.equal(pg.d.getElementById('nf-discard'), null, 'clean form replaced silently');
            assert.equal(pg.d.getElementById('nf-label').value, 'Bravo');

            // dirty -> prompt, nothing lost
            setVal(pg, 'nf-label', 'Bravo edited');
            btnIn(rowFor(pg, 'a'), 'edit').click();
            const box = pg.d.getElementById('nf-discard');
            assert.ok(box, 'prompt shown');
            assert.match(box.textContent, /Discard unsaved changes\?/);
            assert.equal(pg.d.getElementById('nf-label').value, 'Bravo edited', 'input still there');
            assert.equal(pg.d.activeElement.getAttribute('data-act'), 'discard-cancel');

            btnIn(pg.d.getElementById('notify-form-panel'), 'discard-cancel').click();
            assert.equal(pg.d.getElementById('nf-discard'), null);
            assert.equal(pg.d.getElementById('nf-label').value, 'Bravo edited');

            btnIn(rowFor(pg, 'a'), 'edit').click();
            btnIn(pg.d.getElementById('notify-form-panel'), 'discard-confirm').click();
            assert.equal(pg.d.getElementById('nf-discard'), null);
            assert.equal(pg.d.getElementById('nf-label').value, 'Alpha', 'switched to the other connection');
            assert.equal(callsTo(api, 'PUT', /./).length, 0);
            assert.deepEqual(pg.errors, []);
        } finally { pg.close(); }
    });

    test('013 ' + tree + ': + ADD CONNECTION over a dirty form prompts (DISCARD opens the create form); over a clean create form it does not', async () => {
        const api = makeApi({ conns: [conn({ id: 'a', label: 'Alpha' })] });
        const pg = await boot(tree, api);
        try {
            assert.ok(await openSection(pg));
            assert.ok(await rowsReady(pg, 1));
            const add = () => pg.d.querySelector('#notify-toolbar [data-act="add"]');
            add().click();
            assert.ok(pg.d.getElementById('nf-id'));
            add().click();
            assert.equal(pg.d.getElementById('nf-discard'), null, 'clean create form: no prompt');

            setVal(pg, 'nf-id', 'half-typed');
            add().click();
            assert.ok(pg.d.getElementById('nf-discard'), 'dirty create form: prompt');
            assert.equal(pg.d.getElementById('nf-id').value, 'half-typed');
            btnIn(pg.d.getElementById('notify-form-panel'), 'discard-confirm').click();
            assert.equal(pg.d.getElementById('nf-id').value, '', 'fresh create form');
            assert.equal(pg.d.getElementById('nf-discard'), null);
        } finally { pg.close(); }
    });

    test('013 ' + tree + ': a typed secret counts as dirty', async () => {
        const api = makeApi({ conns: [conn({ id: 'a', label: 'Alpha' }), conn({ id: 'b', label: 'Bravo' })] });
        const pg = await boot(tree, api);
        try {
            assert.ok(await openSection(pg));
            assert.ok(await rowsReady(pg, 2));
            await openEdit(pg, 'a');
            setVal(pg, 'nf-s-webhookUrl', 'https://hooks.slack.com/services/T/B/' + SENTINEL);
            btnIn(rowFor(pg, 'b'), 'edit').click();
            assert.ok(pg.d.getElementById('nf-discard'), 'secret typed => prompt');
            assert.equal(pg.d.getElementById('nf-s-webhookUrl').value.includes(SENTINEL), true, 'still typed while the question is open');
            btnIn(pg.d.getElementById('notify-form-panel'), 'discard-confirm').click();
            assert.ok(!pg.d.documentElement.outerHTML.includes(SENTINEL), 'secret gone from the DOM after DISCARD');
        } finally { pg.close(); }
    });
}

// ---------------------------------------------------------------------------
// 014: focus after delete
// ---------------------------------------------------------------------------

async function deleteRow(pg, id) {
    const b = btnIn(rowFor(pg, id), 'delete');
    b.focus();
    b.click();
    const c = btnIn(rowFor(pg, id), 'delete-confirm');
    c.focus();
    c.click();
    assert.ok(await until(() => !rowFor(pg, id)), 'row removed');
    await sleep(120);   // the follow-up refresh re-renders; focus must survive it
}
const focusDesc = (pg) => { const a = pg.d.activeElement; const r = a && a.closest ? a.closest('tr[data-id]') : null; return (r ? r.getAttribute('data-id') : '') + '/' + (a ? a.getAttribute('data-act') : ''); };

for (const tree of ['v1', 'v2']) {
    test('014 ' + tree + ': after a delete focus moves to the next row, else the previous row, else + ADD CONNECTION', async () => {
        const api = makeApi({ conns: [conn({ id: 'a', label: 'A' }), conn({ id: 'b', label: 'B' }), conn({ id: 'c', label: 'C' })] });
        const pg = await boot(tree, api);
        try {
            assert.ok(await openSection(pg));
            assert.ok(await rowsReady(pg, 3));
            await deleteRow(pg, 'b');
            assert.equal(focusDesc(pg), 'c/edit', 'middle delete -> next row first button');
            await deleteRow(pg, 'c');
            assert.equal(focusDesc(pg), 'a/edit', 'last-row delete -> previous row first button');
            await deleteRow(pg, 'a');
            assert.ok(await until(() => /NO CONNECTIONS/.test(pg.d.getElementById('notify-content').textContent)));
            await sleep(120);
            assert.equal(pg.d.activeElement.getAttribute('data-act'), 'add', 'empty list -> + ADD CONNECTION');
            assert.deepEqual(pg.errors, []);
        } finally { pg.close(); }
    });
}
