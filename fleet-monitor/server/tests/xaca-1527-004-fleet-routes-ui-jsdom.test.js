//
//  xaca-1527-004-fleet-routes-ui-jsdom.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1527-004/005: the FLEET ROUTES matrix (notice type x connection) inside the
 * Notification Connections screen. Boots the REAL shipped v1/v2 pages in jsdom against a
 * stubbed /api/notify backend (same harness shape as xaca-1405-notify-connections-jsdom).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const PUB = path.join(__dirname, '..', 'public');
const HOSTILE = '<img src=x onerror="window.__pwn=1">';
const PAGES = ['lcars/lcars-dashboard.html', 'lcars2/lcars-all.html', 'lcars2/lcars-doublenode.html', 'lcars2/lcars-index.html', 'lcars2/lcars-mainevent.html'];

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(fn, ms) {
    const end = Date.now() + (ms || 3000);
    while (Date.now() < end) { try { if (fn()) return true; } catch (e) { /* not yet */ } await sleep(15); }
    return false;
}

const conn = (id, label) => ({ id, provider: 'slack', label, params: {}, secrets: { webhookUrl: 'set' } });

function makeApi(over) {
    const api = Object.assign({
        conns: [conn('slack-a', 'Slack A'), conn('slack-b', 'Slack B')],
        types: ['machine-offline', 'machine-recovered'],
        fleet: { routes: {}, updatedAt: null },
        locked: false, getFail: false, putResult: null, calls: []
    }, over || {});
    api.handle = function (method, url, body) {
        const p = url.replace(/^\/api\/notify/, '').split('?')[0];
        if (api.locked && method === 'GET') return { status: 401, data: { error: 'unauthorized' } };
        if (method === 'GET' && p === '/status') return { status: 200, data: { enabled: true, reason: null, providers: ['slack'] } };
        if (method === 'GET' && p === '/connections') return { status: 200, data: { connections: api.conns } };
        if (method === 'GET' && p === '/receipts') return { status: 200, data: { receipts: [] } };
        if (method === 'GET' && p === '/fleet-routes') {
            if (api.getFail) return { status: 500, data: { error: 'boom', message: 'internal detail' } };
            return { status: 200, data: { routes: api.fleet.routes, updatedAt: api.fleet.updatedAt, noticeTypes: api.types } };
        }
        if (method === 'PUT' && p === '/fleet-routes') {
            if (api.putResult) return api.putResult;
            api.fleet = { routes: body.routes, updatedAt: '2026-11-10T12:00:00.000Z' };
            return { status: 200, data: api.fleet };
        }
        return { status: 404, data: {} };
    };
    return api;
}

async function boot(html, api) {
    const dom = new JSDOM(fs.readFileSync(path.join(PUB, html), 'utf8'), { url: 'http://localhost:1/' + html, runScripts: 'outside-only', pretendToBeVisual: true });
    const w = dom.window;
    w.fetch = async (u, init) => {
        const url = String(u);
        if (!/^\/api\/notify(\/|$)/.test(url)) return { ok: false, status: 404, json: async () => ({}), text: async () => '' };
        const method = String((init && init.method) || 'GET').toUpperCase();
        const body = init && typeof init.body === 'string' ? JSON.parse(init.body) : undefined;
        api.calls.push({ method, url, body });
        const out = api.handle(method, url, body);
        // api.holdNextGet: snapshot the response NOW, but deliver it only when the test releases it.
        if (method === 'GET' && /\/fleet-routes/.test(url) && api.holdNextGet) {
            const gate = api.holdNextGet; api.holdNextGet = null;
            await gate;
        }
        return { ok: out.status >= 200 && out.status < 300, status: out.status, json: async () => JSON.parse(JSON.stringify(out.data)), text: async () => '' };
    };
    w.EventSource = function () { this.close = function () {}; };
    try { w.localStorage.setItem('lcars-skip-startup', 'true'); } catch (e) { /* blocked */ }
    w.console.error = function () {}; w.console.log = function () {}; w.console.warn = function () {};
    const srcs = Array.from(w.document.querySelectorAll('script[src]')).map((s) => s.getAttribute('src')).filter((s) => !/^https?:/.test(s));
    for (const s of srcs) {
        try { w.eval(fs.readFileSync(path.join(PUB, path.dirname(html), s.split('?')[0]), 'utf8')); } catch (e) { /* page scripts we do not care about */ }
    }
    w.document.dispatchEvent(new w.Event('DOMContentLoaded'));
    w.document.querySelector('.sidebar-button[data-section="notifications"]').click();
    return { w, d: w.document, api, close() { try { w.LCARSNotifyConnections.stop(); w.close(); } catch (e) { /* closed */ } } };
}

const fr = (pg) => pg.d.getElementById('notify-fleet-routes');
const box = (pg, t, c) => Array.from(fr(pg).querySelectorAll('input[type=checkbox]')).find((i) => i.getAttribute('data-fr-type') === t && i.getAttribute('data-fr-conn') === c);
const saveBtn = (pg) => fr(pg).querySelector('button[data-act="fr-save"]');
const puts = (api) => api.calls.filter((c) => c.method === 'PUT');
const frCalls = (api) => api.calls.filter((c) => /fleet-routes/.test(c.url));
const toggle = (pg, t, c, on) => { const b = box(pg, t, c); b.checked = on; b.dispatchEvent(new pg.w.Event('change', { bubbles: true })); };

test('no admin key (401): section is gated/locked and NO fleet-routes request is sent', async () => {
    const api = makeApi({ locked: true });
    const pg = await boot(PAGES[0], api);
    try {
        assert.ok(await until(() => /LOCKED/.test(pg.d.getElementById('notify-content').textContent)));
        assert.equal(fr(pg).innerHTML, '', 'no second locked panel / UNLOCK button');
        assert.equal(fr(pg).hidden, true);
        assert.equal(fr(pg).querySelectorAll('input, button').length, 0);
        await sleep(100);
        assert.equal(frCalls(api).length, 0, 'no fleet-routes request while locked');
    } finally { pg.close(); }
});

test('renders the matrix from GET: th scope, labelled checkboxes, saved ticks checked', async () => {
    const api = makeApi({ fleet: { routes: { 'machine-offline': ['slack-b'] }, updatedAt: '2026-11-09T00:00:00.000Z' } });
    const pg = await boot(PAGES[1], api);
    try {
        assert.ok(await until(() => box(pg, 'machine-offline', 'slack-b')));
        const t = fr(pg).querySelector('table');
        assert.equal(t.querySelectorAll('thead th[scope="col"]').length, 3, 'type column + 2 connections');
        assert.equal(t.querySelectorAll('tbody th[scope="row"]').length, 2);
        assert.equal(fr(pg).querySelectorAll('input[type=checkbox]').length, 4);
        assert.equal(box(pg, 'machine-offline', 'slack-b').checked, true);
        assert.equal(box(pg, 'machine-offline', 'slack-a').checked, false);
        assert.match(box(pg, 'machine-offline', 'slack-b').closest('label').textContent, /Route machine-offline to Slack B/);
        assert.equal(saveBtn(pg).getAttribute('aria-disabled'), 'true', 'save disabled while unchanged');
    } finally { pg.close(); }
});

test('empty set (updatedAt null) is explained and still editable', async () => {
    const pg = await boot(PAGES[0], makeApi());
    try {
        assert.ok(await until(() => box(pg, 'machine-offline', 'slack-a')));
        assert.ok(fr(pg).querySelector('[data-fr="empty"]'), 'explains there are no routes yet');
        toggle(pg, 'machine-offline', 'slack-a', true);
        assert.equal(saveBtn(pg).getAttribute('aria-disabled'), 'false');
    } finally { pg.close(); }
});

test('no fleet connections: explains, renders no matrix', async () => {
    const pg = await boot(PAGES[0], makeApi({ conns: [] }));
    try {
        assert.ok(await until(() => /NO CONNECTIONS TO ROUTE TO/.test(fr(pg).textContent)), fr(pg).textContent);
        assert.equal(fr(pg).querySelectorAll('input').length, 0);
    } finally { pg.close(); }
});

test('load failure: fixed message (no server text) and RETRY recovers', async () => {
    const api = makeApi({ getFail: true });
    const pg = await boot(PAGES[0], api);
    try {
        assert.ok(await until(() => /FLEET ROUTES UNAVAILABLE/.test(fr(pg).textContent)));
        assert.ok(!/internal detail/.test(fr(pg).textContent), 'server text not echoed');
        api.getFail = false;
        fr(pg).querySelector('button[data-act="fr-retry"]').click();
        assert.ok(await until(() => box(pg, 'machine-offline', 'slack-a')));
    } finally { pg.close(); }
});

test('toggle + save sends the full set as PUT and shows updatedAt', async () => {
    const api = makeApi({ fleet: { routes: { 'machine-recovered': ['slack-a'] }, updatedAt: '2026-11-09T00:00:00.000Z' } });
    const pg = await boot(PAGES[0], api);
    try {
        assert.ok(await until(() => box(pg, 'machine-offline', 'slack-a')));
        toggle(pg, 'machine-offline', 'slack-b', true);
        toggle(pg, 'machine-offline', 'slack-a', true);
        saveBtn(pg).click();
        assert.ok(await until(() => /Saved at /.test(fr(pg).textContent)), fr(pg).textContent);
        assert.ok(!/2026-11-10T12:00:00/.test(fr(pg).textContent), 'time is human formatted, not raw ISO');
        assert.equal(puts(api).length, 1);
        assert.deepEqual(puts(api)[0].body, { routes: { 'machine-offline': ['slack-a', 'slack-b'], 'machine-recovered': ['slack-a'] } });
        assert.equal(saveBtn(pg).getAttribute('aria-disabled'), 'true', 'clean again after save');
    } finally { pg.close(); }
});

test('400 validation message is rendered as inert escaped text', async () => {
    const api = makeApi({ putResult: { status: 400, data: { error: 'invalid', message: HOSTILE + '<script>window.__pwn=2</script>' } } });
    const pg = await boot(PAGES[0], api);
    try {
        assert.ok(await until(() => box(pg, 'machine-offline', 'slack-a')));
        toggle(pg, 'machine-offline', 'slack-a', true);
        saveBtn(pg).click();
        assert.ok(await until(() => /SAVE FAILED/.test(fr(pg).textContent)));
        assert.ok(fr(pg).textContent.includes(HOSTILE), 'shown literally');
        assert.equal(fr(pg).querySelectorAll('img, script').length, 0);
        assert.equal(pg.w.__pwn, undefined);
        assert.equal(box(pg, 'machine-offline', 'slack-a').checked, true, 'draft kept so the operator can fix it');
        assert.equal(saveBtn(pg).getAttribute('aria-disabled'), 'false');
    } finally { pg.close(); }
});

test('a route to a deleted connection is kept, shown as a (deleted) column, with a notice', async () => {
    const api = makeApi({ fleet: { routes: { 'machine-offline': ['ghost-conn'] }, updatedAt: '2026-11-09T00:00:00.000Z' } });
    const pg = await boot(PAGES[0], api);
    try {
        assert.ok(await until(() => box(pg, 'machine-offline', 'ghost-conn')));
        assert.equal(box(pg, 'machine-offline', 'ghost-conn').checked, true);
        assert.match(fr(pg).textContent, /ghost-conn \(deleted\)/);
        assert.match(fr(pg).textContent, /deleted connection/);
    } finally { pg.close(); }
});

test('focus on a matrix checkbox survives refresh() and the poll rebuild', async () => {
    const api = makeApi();
    const pg = await boot(PAGES[0], api);
    try {
        assert.ok(await until(() => box(pg, 'machine-offline', 'slack-a')));
        toggle(pg, 'machine-recovered', 'slack-b', true);   // dirty draft: HTML now differs from last render
        box(pg, 'machine-recovered', 'slack-b').focus();
        assert.equal(pg.d.activeElement, box(pg, 'machine-recovered', 'slack-b'));
        await pg.w.LCARSNotifyConnections.refresh();
        await sleep(50);
        const a = pg.d.activeElement;
        assert.equal(a.getAttribute('data-fr-type'), 'machine-recovered', 'focus not dropped to BODY');
        assert.equal(a.getAttribute('data-fr-conn'), 'slack-b');
        assert.equal(a.checked, true, 'draft kept');
    } finally { pg.close(); }
});

test('keyboard SAVE keeps focus on SAVE (aria-disabled, not disabled) and announces via #notify-live', async () => {
    const api = makeApi();
    const pg = await boot(PAGES[1], api);
    try {
        assert.ok(await until(() => box(pg, 'machine-offline', 'slack-a')));
        toggle(pg, 'machine-offline', 'slack-a', true);
        saveBtn(pg).focus();
        saveBtn(pg).click();
        assert.equal(saveBtn(pg).hasAttribute('disabled'), false, 'never natively disabled');
        assert.ok(await until(() => /Saved at /.test(pg.d.getElementById('notify-fr-msg').textContent)));
        assert.equal(pg.d.activeElement, saveBtn(pg), 'focus stays on SAVE after save');
        assert.equal(saveBtn(pg).getAttribute('aria-disabled'), 'true');
        assert.match(pg.d.getElementById('notify-live').textContent, /^Saved at /);
        const n = puts(api).length;
        saveBtn(pg).click();   // aria-disabled click is a no-op
        await sleep(50);
        assert.equal(puts(api).length, n);
    } finally { pg.close(); }
});

test('failed save is announced in #notify-live', async () => {
    const api = makeApi({ putResult: { status: 400, data: { error: 'invalid', message: 'nope' } } });
    const pg = await boot(PAGES[0], api);
    try {
        assert.ok(await until(() => box(pg, 'machine-offline', 'slack-a')));
        toggle(pg, 'machine-offline', 'slack-a', true);
        saveBtn(pg).click();
        assert.ok(await until(() => /SAVE FAILED/.test(pg.d.getElementById('notify-live').textContent)));
        assert.equal(pg.d.getElementById('notify-live').textContent, pg.d.getElementById('notify-fr-msg').textContent);
    } finally { pg.close(); }
});

test('a retired notice type renders as a (retired) row and unticking it removes it from the PUT', async () => {
    const api = makeApi({ fleet: { routes: { 'old-type': ['slack-a'], 'machine-offline': ['slack-b'] }, updatedAt: '2026-11-09T00:00:00.000Z' } });
    const pg = await boot(PAGES[0], api);
    try {
        assert.ok(await until(() => box(pg, 'old-type', 'slack-a')));
        assert.match(fr(pg).textContent, /old-type\s*\(retired\)/);
        assert.match(fr(pg).textContent, /no longer offers/);
        assert.equal(box(pg, 'old-type', 'slack-a').checked, true);
        toggle(pg, 'old-type', 'slack-a', false);
        saveBtn(pg).click();
        assert.ok(await until(() => puts(api).length === 1));
        assert.deepEqual(puts(api)[0].body, { routes: { 'machine-offline': ['slack-b'] } });
        assert.ok(await until(() => !box(pg, 'old-type', 'slack-a')), 'retired row gone once clean');
    } finally { pg.close(); }
});

test('XACA-1527-013: a GET that started before a save completed cannot revert the saved set', async () => {
    const api = makeApi({ fleet: { routes: { 'machine-recovered': ['slack-a'] }, updatedAt: '2026-11-09T00:00:00.000Z' } });
    const pg = await boot(PAGES[0], api);
    try {
        assert.ok(await until(() => box(pg, 'machine-offline', 'slack-a')));
        let release; api.holdNextGet = new Promise((r) => { release = r; });
        const getsBefore = api.calls.filter((c) => c.method === 'GET' && /fleet-routes/.test(c.url)).length;
        const inflight = pg.w.LCARSNotifyConnections.refresh();   // GET snapshots the OLD set, then hangs
        assert.ok(await until(() => api.calls.filter((c) => c.method === 'GET' && /fleet-routes/.test(c.url)).length > getsBefore));
        toggle(pg, 'machine-offline', 'slack-b', true);
        saveBtn(pg).click();
        assert.ok(await until(() => /Saved at /.test(fr(pg).textContent)));
        release();                                                 // stale GET resolves AFTER the save
        await inflight; await sleep(60);
        assert.equal(box(pg, 'machine-offline', 'slack-b').checked, true, 'saved tick not reverted by the stale GET');
        assert.equal(saveBtn(pg).getAttribute('aria-disabled'), 'true');
    } finally { pg.close(); }
});

test('XACA-1527-014: DISCARD resets the draft, sends no PUT, toggles the hint, announces, keeps focus', async () => {
    const api = makeApi({ fleet: { routes: { 'machine-offline': ['slack-b'] }, updatedAt: '2026-11-09T00:00:00.000Z' } });
    const pg = await boot(PAGES[1], api);
    try {
        assert.ok(await until(() => box(pg, 'machine-offline', 'slack-b')));
        const disc = () => fr(pg).querySelector('button[data-act="fr-discard"]');
        const hint = () => pg.d.getElementById('notify-fr-dirty').textContent;
        assert.ok(disc(), 'DISCARD control exists');
        assert.equal(disc().getAttribute('aria-disabled'), 'true', 'disabled when clean');
        assert.equal(disc().hasAttribute('disabled'), false);
        assert.equal(hint(), '', 'no hint when clean');
        toggle(pg, 'machine-offline', 'slack-a', true);
        toggle(pg, 'machine-offline', 'slack-b', false);
        assert.equal(hint(), 'Unsaved changes');
        assert.equal(disc().getAttribute('aria-disabled'), 'false');
        disc().focus();
        disc().click();
        assert.equal(box(pg, 'machine-offline', 'slack-a').checked, false, 'draft reset');
        assert.equal(box(pg, 'machine-offline', 'slack-b').checked, true, 'draft reset');
        assert.equal(hint(), '');
        assert.equal(disc().getAttribute('aria-disabled'), 'true');
        assert.equal(saveBtn(pg).getAttribute('aria-disabled'), 'true');
        assert.equal(pg.d.activeElement, disc(), 'focus stays on DISCARD');
        assert.match(pg.d.getElementById('notify-live').textContent, /Discarded/);
        assert.equal(puts(api).length, 0, 'discard never PUTs');
        // clean again: polling resumes adopting server state
        api.fleet = { routes: { 'machine-recovered': ['slack-a'] }, updatedAt: '2026-11-10T01:00:00.000Z' };
        await pg.w.LCARSNotifyConnections.refresh();
        assert.ok(await until(() => box(pg, 'machine-recovered', 'slack-a') && box(pg, 'machine-recovered', 'slack-a').checked));
    } finally { pg.close(); }
});

test('CSS: narrow-width rule keeps .notify-fr-table a real table; th[scope=row] border matches td', () => {
    const css = fs.readFileSync(path.join(PUB, 'shared/css/lcars-notify-connections.css'), 'utf8');
    const m = /@media \(max-width: 720px\) \{[^}]*\.notify-fr-table[\s\S]*?\n\}/.exec(css.slice(css.indexOf('XACA-1527-004')));
    assert.ok(m, 'narrow media block for .notify-fr-table');
    assert.match(m[0], /\.notify-fr-table tr \{[^}]*display: table-row/);
    assert.match(m[0], /\.notify-fr-table td \{[^}]*display: table-cell|\.notify-fr-table th, \.notify-fr-table td \{[^}]*display: table-cell/);
    assert.match(m[0], /\.notify-fr-table thead \{[^}]*position: static/);
    assert.match(m[0], /min-width: max-content/);
    assert.match(css, /\.notify-fr-table th\[scope="row"\][^}]*border-bottom: 1px solid/);
});

test('XACA-1527-005: container on all 5 pages; ?v= cache-busters bumped and consistent', () => {
    const vers = new Set();
    for (const p of PAGES) {
        const h = fs.readFileSync(path.join(PUB, p), 'utf8');
        assert.equal((h.match(/id="notify-fleet-routes"/g) || []).length, 1, p + ': container');
        const js = /lcars-notify-connections\.js\?v=(\w+)"/.exec(h);
        const css = /lcars-notify-connections\.css\?v=(\w+)"/.exec(h);
        assert.ok(js && css, p + ': versioned assets');
        assert.equal(js[1], css[1], p + ': js and css share a version');
        vers.add(js[1]);
    }
    assert.equal(vers.size, 1, 'same version on every page: ' + [...vers]);
    assert.notEqual([...vers][0], '20261010c', 'bumped from the pre-1527 value');
});

test('CSS: XACA-1527-015/016 sticky row-header column at <=720px and a scroll cue on the wrap', () => {
    const css = fs.readFileSync(path.join(PUB, 'shared/css/lcars-notify-connections.css'), 'utf8');
    const media = css.slice(css.indexOf('XACA-1527-015'));
    assert.match(media, /th\[scope="row"\][^{]*\{[^}]*position: sticky;[^}]*left: 0;[^}]*z-index: \d+;[^}]*background: var\(--lcars-dark/);
    assert.match(css, /\.notify-fr-wrap \{[^}]*linear-gradient[^}]*local/, 'scroll-cue gradients on the wrap');
});
