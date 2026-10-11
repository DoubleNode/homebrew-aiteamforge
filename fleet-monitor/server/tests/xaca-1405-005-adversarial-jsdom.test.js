//
//  xaca-1405-005-adversarial-jsdom.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1405-005 adversarial pass over the NOTIFICATIONS section. Boots the real v1 and v2
 * dashboard pages in jsdom against a stub /api/notify backend (same approach as
 * xaca-1405-notify-connections-jsdom.test.js) and attacks what that suite does not:
 *
 *   - a refresh already in flight when a write lands must not resurrect pre-write data
 *   - a failed EDIT must say the typed secret was cleared (silent loss reads as "stored")
 *   - secrets: gone from the DOM after cancel / failure / network error, never in console output
 *   - hostile server data in every receipt / param field is inert; no link is ever produced
 *   - double submit / double confirm send exactly one request
 *   - poll timers: at most one live, none after leaving the section
 *   - last delivery edge cases (same providerMessageId across connections, newer accepted stub)
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
const ALL_PROVIDERS = ['email', 'imessage', 'ntfy', 'pushover', 'slack', 'teams'];
const TREES = { v1: 'lcars/lcars-dashboard.html', v2: 'lcars2/lcars-all.html' };

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(fn, ms) {
    const end = Date.now() + (ms || 3000);
    while (Date.now() < end) { try { if (fn()) return true; } catch (e) { /* not yet */ } await sleep(15); }
    return false;
}
const iso = (minsAgo) => new Date(Date.now() - minsAgo * 60000).toISOString();
const conn = (over) => Object.assign({ id: 'work-slack', provider: 'slack', label: 'Work Slack', params: {}, secrets: { webhookUrl: 'set' } }, over);

function makeApi(over) {
    const api = Object.assign({
        status: { enabled: true, reason: null, providers: ALL_PROVIDERS },
        conns: [], receipts: [], calls: [], putError: null, networkDown: false, gate: null
    }, over || {});
    api.handle = function (method, url, body) {
        const p = url.replace(/^\/api\/notify/, '').split('?')[0];
        const r = (status, data) => ({ status, data });
        if (method === 'GET' && p === '/status') return r(200, api.status);
        if (method === 'GET' && p === '/connections') return r(200, { connections: api.conns });
        if (method === 'GET' && p === '/receipts') return r(200, { receipts: api.receipts });
        if (method === 'POST' && /^\/connections\/[^/]+\/test$/.test(p)) return r(200, { ok: true, validated: true, sent: !!(body && body.send) });
        if (method === 'POST' && p === '/connections') {
            const c = { id: body.id, provider: body.provider, label: body.label, params: body.params, secrets: {} };
            Object.keys(body.secrets || {}).forEach((k) => { c.secrets[k] = 'set'; });
            api.conns.push(c);
            return r(201, c);
        }
        let m = /^\/connections\/([^/]+)$/.exec(p);
        if (method === 'PUT' && m) {
            if (api.putError) return r(400, { error: 'invalid', message: api.putError });
            const c = api.conns.find((x) => x.id === decodeURIComponent(m[1]));
            return c ? r(200, c) : r(404, { error: 'not_found', message: 'connection not found' });
        }
        if (method === 'DELETE' && m) {
            const i = api.conns.findIndex((x) => x.id === decodeURIComponent(m[1]));
            if (i < 0) return r(404, { error: 'not_found', message: 'connection not found' });
            api.conns.splice(i, 1);
            return r(200, { deleted: m[1] });
        }
        return r(404, {});
    };
    return api;
}

async function boot(tree, api) {
    const html = fs.readFileSync(path.join(PUB, TREES[tree]), 'utf8');
    const dom = new JSDOM(html, { url: 'http://localhost:1/' + TREES[tree], runScripts: 'outside-only', pretendToBeVisual: true });
    const w = dom.window;
    const logged = [];
    const liveTimers = new Set();
    const realSet = w.setInterval.bind(w);
    const realClear = w.clearInterval.bind(w);
    w.setInterval = function (fn, ms) { const id = realSet(fn, ms); if (ms === 15000) liveTimers.add(id); return id; };
    w.clearInterval = function (id) { liveTimers.delete(id); return realClear(id); };
    w.fetch = async (u, init) => {
        const url = String(u);
        if (!/^\/api\/notify(\/|$)/.test(url)) return { ok: false, status: 404, json: async () => ({}) };
        const method = String((init && init.method) || 'GET').toUpperCase();
        const body = init && typeof init.body === 'string' ? JSON.parse(init.body) : undefined;
        api.calls.push({ method, url, body });
        if (api.networkDown && method !== 'GET') throw new TypeError('network down');
        const out = api.handle(method, url, body);
        const snap = JSON.stringify(out.data);               // the response is fixed at request time
        if (api.gate && method === 'GET' && /\/connections$/.test(url)) { const g = api.gate; api.gate = null; await g; }
        return { ok: out.status >= 200 && out.status < 300, status: out.status, json: async () => JSON.parse(snap) };
    };
    w.EventSource = function () { this.close = function () {}; };
    try { w.localStorage.setItem('lcars-skip-startup', 'true'); } catch (e) { /* blocked */ }
    ['error', 'log', 'warn', 'info', 'debug'].forEach((k) => { w.console[k] = (...a) => logged.push(a.map(String).join(' ')); });
    const src = Array.from(w.document.querySelectorAll('script[src]')).map((s) => s.getAttribute('src')).filter((s) => !/^https?:/.test(s));
    for (const s of src) {
        try { w.eval(fs.readFileSync(path.join(PUB, path.dirname(TREES[tree]), s.split('?')[0]), 'utf8')); } catch (e) { logged.push(s + ': ' + e.message); }
    }
    w.document.dispatchEvent(new w.Event('DOMContentLoaded'));
    return { w, d: w.document, api, logged, liveTimers, close() { try { w.LCARSNotifyConnections.stop(); w.close(); } catch (e) { /* closed */ } } };
}

const clickSidebar = (pg, section) => pg.d.querySelector('.sidebar-button[data-section="' + section + '"]').click();
const openSection = async (pg) => { clickSidebar(pg, 'notifications'); return until(() => pg.d.querySelector('#notify-content tr[data-id], #notify-content .empty-state-text:not(:empty)') && !/LOADING/.test(pg.d.getElementById('notify-content').textContent)); };
const rowFor = (pg, id) => Array.from(pg.d.querySelectorAll('#notify-content tr[data-id]')).find((r) => r.getAttribute('data-id') === id);
const btnIn = (root, act) => root.querySelector('button[data-act="' + act + '"]');
const callsTo = (api, method, re) => api.calls.filter((c) => c.method === method && re.test(c.url));
const submit = (pg) => pg.d.querySelector('#notify-form-panel form').dispatchEvent(new pg.w.Event('submit', { bubbles: true, cancelable: true }));

test('a refresh already in flight when a DELETE lands cannot resurrect the deleted row', async () => {
    const api = makeApi({ conns: [conn({ id: 'doomed', label: 'Doomed' }), conn({ id: 'keep', label: 'Keep' })] });
    const pg = await boot('v1', api);
    try {
        assert.ok(await openSection(pg));
        assert.ok(await until(() => rowFor(pg, 'doomed')));
        let release;
        api.gate = new Promise((res) => { release = res; });
        const poll = pg.w.LCARSNotifyConnections.refresh();      // reads the list NOW (still includes "doomed"), answer withheld
        assert.ok(await until(() => callsTo(api, 'GET', /\/connections$/).length >= 2));
        btnIn(rowFor(pg, 'doomed'), 'delete').click();
        btnIn(rowFor(pg, 'doomed'), 'delete-confirm').click();
        assert.ok(await until(() => callsTo(api, 'DELETE', /./).length === 1));
        const readsBefore = callsTo(api, 'GET', /\/connections$/).length;
        release();
        await poll;
        assert.ok(await until(() => callsTo(api, 'GET', /\/connections$/).length > readsBefore), 'a fresh read was issued after the delete');
        assert.ok(await until(() => !rowFor(pg, 'doomed')), 'the deleted row is gone');
        await sleep(150);
        assert.ok(!rowFor(pg, 'doomed'), 'and stays gone');
        assert.ok(rowFor(pg, 'keep'));
    } finally { pg.close(); }
});

test('a failed EDIT that discarded a typed secret says so', async () => {
    const api = makeApi({ conns: [conn()], putError: 'label rejected' });
    const pg = await boot('v1', api);
    try {
        assert.ok(await openSection(pg));
        assert.ok(await until(() => rowFor(pg, 'work-slack')));
        btnIn(rowFor(pg, 'work-slack'), 'edit').click();
        assert.ok(await until(() => pg.d.getElementById('nf-label')));
        pg.d.getElementById('nf-s-webhookUrl').value = 'https://hooks.slack.com/services/T000/B000/' + SENTINEL;
        submit(pg);
        assert.ok(await until(() => /label rejected/.test(pg.d.getElementById('nf-errors').textContent)));
        assert.equal(pg.d.getElementById('nf-s-webhookUrl').value, '', 'the input was emptied');
        assert.match(pg.d.getElementById('nf-errors').textContent, /Secret fields were cleared/, 'the operator is told');
        assert.ok(!pg.d.documentElement.outerHTML.includes(SENTINEL));
    } finally { pg.close(); }
});

test('a failed EDIT with no typed secret does not claim a secret was cleared', async () => {
    const api = makeApi({ conns: [conn()], putError: 'label rejected' });
    const pg = await boot('v1', api);
    try {
        assert.ok(await openSection(pg));
        assert.ok(await until(() => rowFor(pg, 'work-slack')));
        btnIn(rowFor(pg, 'work-slack'), 'edit').click();
        assert.ok(await until(() => pg.d.getElementById('nf-label')));
        submit(pg);
        assert.ok(await until(() => /label rejected/.test(pg.d.getElementById('nf-errors').textContent)));
        assert.ok(!/Secret fields were cleared/.test(pg.d.getElementById('nf-errors').textContent));
    } finally { pg.close(); }
});

for (const tree of ['v1', 'v2']) {
    test(tree + ': secrets vanish on cancel and on a network failure, and never reach console output', async () => {
        const api = makeApi({ networkDown: true });
        const pg = await boot(tree, api);
        try {
            assert.ok(await openSection(pg));
            btnIn(pg.d.getElementById('notify-toolbar'), 'add').click();
            assert.ok(await until(() => pg.d.getElementById('nf-id')));
            const prov = pg.d.getElementById('nf-provider');
            prov.value = 'slack';
            prov.dispatchEvent(new pg.w.Event('change', { bubbles: true }));
            pg.d.getElementById('nf-id').value = 'work-slack';
            pg.d.getElementById('nf-label').value = 'Work';
            const url = 'https://hooks.slack.com/services/T000/B000/' + SENTINEL;
            pg.d.getElementById('nf-s-webhookUrl').value = url;
            submit(pg);
            assert.ok(await until(() => /could not reach the server/.test(pg.d.getElementById('nf-errors').textContent)));
            assert.equal(pg.d.getElementById('nf-s-webhookUrl').value, '');
            // type again, then walk away without submitting
            pg.d.getElementById('nf-s-webhookUrl').value = url;
            btnIn(pg.d.getElementById('notify-form-panel'), 'form-cancel').click();
            assert.equal(pg.d.getElementById('notify-form-panel').innerHTML, '', 'cancel tears the form (and its inputs) down');
            assert.ok(!pg.d.documentElement.outerHTML.includes(SENTINEL), 'no secret anywhere in the DOM');
            assert.ok(!pg.logged.join('\n').includes(SENTINEL), 'no secret in console output');
        } finally { pg.close(); }
    });
}

test('hostile server data in every receipt / param field is inert and never becomes a link', async () => {
    const evil = 'javascript:window.__pwn=1//' + HOSTILE;
    const api = makeApi({
        conns: [conn({ id: 'x', label: 'X', params: { 'k"><b>': evil, url: evil, list: [evil, HOSTILE] }, secrets: { webhookUrl: evil } })],
        receipts: [{ id: 'r', ts: HOSTILE, connectionId: 'x', ok: false, error: evil, suppressed: undefined, type: HOSTILE, team: HOSTILE, provider: HOSTILE }]
    });
    const pg = await boot('v1', api);
    try {
        assert.ok(await openSection(pg));
        assert.ok(await until(() => rowFor(pg, 'x')));
        const row = rowFor(pg, 'x');
        assert.equal(row.querySelectorAll('a, img, b, script, [onerror]').length, 0);
        assert.equal(pg.w.__pwn, undefined);
        assert.ok(row.textContent.includes('javascript:window.__pwn=1'), 'shown as literal text');
        assert.ok(!/webhookUrl: javascript/.test(row.textContent), 'a secret slot renders only the fixed words');
        // a hostile suppressed reason (not in the server's list) is still text
        api.receipts = [{ id: 'r2', ts: iso(1), connectionId: 'x', ok: false, error: '', suppressed: HOSTILE, type: 't', team: 't' }];
        await pg.w.LCARSNotifyConnections.refresh();
        assert.equal(rowFor(pg, 'x').querySelectorAll('img').length, 0);
        assert.ok(rowFor(pg, 'x').textContent.includes(HOSTILE));
        assert.equal(pg.w.__pwn, undefined);
    } finally { pg.close(); }
});

test('a connection id carrying quotes cannot break out of data-id, and its buttons still address it', async () => {
    const id = 'a" onmouseover="window.__pwn=1" x="';
    const api = makeApi({ conns: [conn({ id, label: 'Quote' })] });
    const pg = await boot('v1', api);
    try {
        assert.ok(await openSection(pg));
        assert.ok(await until(() => rowFor(pg, id)));
        const row = rowFor(pg, id);
        assert.equal(row.querySelectorAll('[onmouseover]').length, 0);
        assert.equal(btnIn(row, 'test').getAttribute('data-id'), id);
        btnIn(row, 'test').click();
        assert.ok(await until(() => callsTo(api, 'POST', /\/test$/).length === 1));
        assert.ok(callsTo(api, 'POST', /\/test$/)[0].url.includes(encodeURIComponent(id)), 'the id is URL-encoded in the path');
        assert.ok(await until(() => /VALID — the configuration passes/.test(rowFor(pg, id).textContent)), 'result lands before the window closes');
    } finally { pg.close(); }
});

test('double submit of the add form and double CONFIRM SEND each issue exactly one request', async () => {
    const api = makeApi({ conns: [conn()] });
    const pg = await boot('v1', api);
    try {
        assert.ok(await openSection(pg));
        assert.ok(await until(() => rowFor(pg, 'work-slack')));
        btnIn(pg.d.getElementById('notify-toolbar'), 'add').click();
        assert.ok(await until(() => pg.d.getElementById('nf-id')));
        const prov = pg.d.getElementById('nf-provider');
        prov.value = 'slack';
        prov.dispatchEvent(new pg.w.Event('change', { bubbles: true }));
        pg.d.getElementById('nf-id').value = 'second';
        pg.d.getElementById('nf-label').value = 'Second';
        pg.d.getElementById('nf-s-webhookUrl').value = 'https://hooks.slack.com/services/T000/B000/abc';
        submit(pg); submit(pg);
        assert.ok(await until(() => callsTo(api, 'POST', /\/connections$/).length >= 1));
        await sleep(100);
        assert.equal(callsTo(api, 'POST', /\/connections$/).length, 1, 'one create');

        btnIn(rowFor(pg, 'work-slack'), 'send').click();
        const confirmBtn = btnIn(rowFor(pg, 'work-slack'), 'send-confirm');
        confirmBtn.click(); confirmBtn.click();
        assert.ok(await until(() => callsTo(api, 'POST', /\/test$/).length >= 1));
        await sleep(100);
        assert.equal(callsTo(api, 'POST', /\/test$/).length, 1, 'one test send');
    } finally { pg.close(); }
});

test('poll timers: at most one live, none left after leaving the section, re-entry re-arms exactly one', async () => {
    const api = makeApi({ conns: [conn()] });
    const pg = await boot('v1', api);
    try {
        assert.equal(pg.liveTimers.size, 0, 'no timer while hidden');
        for (let i = 0; i < 3; i++) {
            clickSidebar(pg, 'notifications');
            assert.ok(await until(() => pg.liveTimers.size === 1), 'exactly one timer while visible (pass ' + i + ')');
            clickSidebar(pg, 'overview');
            assert.ok(await until(() => pg.liveTimers.size === 0), 'no timer after leaving (pass ' + i + ')');
        }
        pg.w.document.dispatchEvent(new pg.w.CustomEvent('lcars:sectionChange', { detail: { section: 'notifications' } }));
        pg.w.document.dispatchEvent(new pg.w.CustomEvent('lcars:sectionChange', { detail: { section: 'notifications' } }));
        assert.equal(pg.liveTimers.size, 1, 'a repeated activation replaces, never stacks');
        await sleep(150);                                  // let the in-flight reads settle before the window closes
    } finally { pg.close(); }
});

test('last delivery: a settled receipt of ANOTHER connection with the same providerMessageId is not borrowed; a newer accepted stub beats an older settled one', async () => {
    const api = makeApi({
        conns: [conn({ id: 'a', label: 'A', provider: 'imessage', params: { recipient: '+15551234567' }, secrets: {} }),
            conn({ id: 'b', label: 'B', provider: 'imessage', params: { recipient: '+15551234568' }, secrets: {} })],
        receipts: [
            { id: '1', ts: iso(3), connectionId: 'a', ok: true, error: '', stage: 'accepted', providerMessageId: 'pm-1', type: 'x', team: 't' },
            { id: '2', ts: iso(2), connectionId: 'b', ok: true, error: '', stage: 'delivered', providerMessageId: 'pm-1', type: 'x', team: 't' },
            { id: '3', ts: iso(60), connectionId: 'b', ok: true, error: '', stage: 'delivered', providerMessageId: 'pm-0', type: 'x', team: 't' },
            { id: '4', ts: iso(1), connectionId: 'b', ok: true, error: '', stage: 'accepted', providerMessageId: 'pm-2', type: 'x', team: 't' }
        ]
    });
    const pg = await boot('v1', api);
    try {
        assert.ok(await openSection(pg));
        assert.ok(await until(() => rowFor(pg, 'a') && rowFor(pg, 'b')));
        assert.match(rowFor(pg, 'a').textContent, /ACCEPTED, AWAITING RELAY/, 'a stays unsettled: b delivered a different send');
        assert.match(rowFor(pg, 'b').textContent, /ACCEPTED, AWAITING RELAY/, 'b newest send (pm-2) is still unsettled');
    } finally { pg.close(); }
});
