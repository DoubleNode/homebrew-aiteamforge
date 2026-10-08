//
//  xaca-1393-005-accessories-jsdom.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1393-005 (Testing & Debugging): boots the REAL shipped dashboard pages
 * (v1 lcars/lcars-dashboard.html + lcars2/lcars-all.html, every local <script>
 * executed in document order) in jsdom against a stubbed fetch, and asserts
 * the ACCESSORIES section + the ON UPS BATTERY machine cards end to end:
 *
 *   - old-server payload (no accessories key, no display_status) degrades quietly
 *   - D2 precedence is RENDERED from the server's display_status, never re-derived
 *   - hostile strings (names, nicknames, hostnames, ids) never become markup
 *   - null percent / minutes / last_reading render a dash, never "0%"/NaN
 *   - attach / detach hit the right URL+method; 404 / 409 / non-JSON errors
 *     surface inline on the card
 *
 * The same assertions run against both trees through a small adapter, so the
 * two renderers cannot drift apart unnoticed.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const PUB = path.join(__dirname, '..', 'public');

const M_ONB = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';   // on_battery (yellow)
const M_OFF = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';   // offline wins over on_battery (red)
const M_AC = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';    // ac
const M_WARN = 'ffffffff-ffff-4fff-8fff-ffffffffffff';  // heartbeat-late warning, no power label
const ACC1 = 'acc_0000000000000001';
const ACC2 = 'acc_0000000000000002';
const ACC3 = 'acc_0000000000000003';

function machine(o) {
    return Object.assign({
        machine_id: 'x', hostname: 'h', nickname: null, status: 'online', display_status: 'online',
        power_state: null, power_reason: null, session_count: 0, sessions: [], uptime_history: [], system: {}
    }, o);
}

function richPayload() {
    return {
        fleet: {
            total_machines: 4, online_machines: 3, offline_machines: 1, total_sessions: 0, divisions: {},
            machines: [
                machine({ machine_id: M_ONB, hostname: 'host-onb', display_status: 'on_battery', power_state: 'on_battery',
                    power_reason: { accessory_id: ACC1, accessory_name: 'UPS-One', percent: 85, minutes_remaining: 40 } }),
                machine({ machine_id: M_OFF, hostname: 'host-off', status: 'offline', display_status: 'offline', power_state: 'on_battery' }),
                machine({ machine_id: M_AC, hostname: 'host-ac', power_state: 'ac' }),
                machine({ machine_id: M_WARN, hostname: 'host-warn', status: 'warning', display_status: 'warning' })
            ]
        },
        activityLog: [],
        accessories: [
            { id: ACC1, type: 'ups', name: 'UPS-One', nickname: null, display_name: 'UPS-One', data_link_machine_id: M_ONB,
              attached_machine_ids: [M_ONB, M_OFF], state: 'on_battery', state_since: null, history: [],
              last_reading: { source: 'ups', percent: 85, charging: false, minutes_remaining: 40, present: true, observedAt: '2026-10-08T12:00:00.000Z' } },
            { id: ACC2, type: 'ups', name: 'UPS-Two', nickname: 'Rack', display_name: 'Rack', data_link_machine_id: M_AC,
              attached_machine_ids: [M_AC], state: 'ac', state_since: null, history: [],
              last_reading: { source: 'ac', percent: 100, charging: true, minutes_remaining: null, present: true, observedAt: '2026-10-08T12:00:00.000Z' } },
            { id: ACC3, type: 'ups', name: 'UPS-Three', nickname: null, display_name: 'UPS-Three', data_link_machine_id: null,
              attached_machine_ids: [], state: 'unknown', state_since: null, history: [], last_reading: null }
        ],
        last_update: '2026-10-08T12:00:00.000Z'
    };
}

const TREES = {
    v1: {
        html: 'lcars/lcars-dashboard.html', content: 'accessories-content', row: '.machine-row', label: '.machine-power-label',
        card: '.accessory-card', name: '.accessory-name', state: '.accessory-state', err: '.accessory-error',
        detach: '.accessory-detach-btn', attachBtn: '.accessory-attach-btn', select: '.accessory-attach-select',
        link: '.accessory-link-host', host: '.machine-hostname'
    },
    v2: {
        html: 'lcars2/lcars-all.html', content: 'accessories-list', row: '.status-row', label: '.status-row-power-label',
        card: '.accessory-card', name: '.accessory-name', state: '.accessory-state-badge', err: '.accessory-error',
        detach: '.accessory-detach', attachBtn: '.accessory-attach-btn', select: '.accessory-attach-select',
        link: null, host: '.status-row-hostname'
    }
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(fn, ms) {
    const end = Date.now() + (ms || 3000);
    while (Date.now() < end) { try { if (fn()) return true; } catch (e) { /* not yet */ } await sleep(25); }
    return false;
}

async function boot(tree, payload) {
    const T = TREES[tree];
    const html = fs.readFileSync(path.join(PUB, T.html), 'utf8');
    const dom = new JSDOM(html, { url: 'http://localhost:1/' + T.html, runScripts: 'outside-only', pretendToBeVisual: true });
    const w = dom.window;
    w.fetch = async (u) => {
        if (/\/api\/fleet(\?|$)/.test(String(u))) return { ok: true, status: 200, json: async () => JSON.parse(JSON.stringify(payload)), text: async () => '' };
        return { ok: false, status: 404, json: async () => ({}), text: async () => '' };
    };
    w.EventSource = function () { this.close = function () {}; };
    w.console.error = function () {}; w.console.log = function () {}; w.console.warn = function () {};
    const errors = []; w.addEventListener('error', (e) => errors.push(e.message));
    const srcs = Array.from(w.document.querySelectorAll('script[src]')).map((s) => s.getAttribute('src')).filter((s) => !/^https?:/.test(s));
    for (const s of srcs) {
        const f = path.join(PUB, path.dirname(T.html), s.split('?')[0]);
        try { w.eval(fs.readFileSync(f, 'utf8')); } catch (e) { errors.push(s + ': ' + e.message); }
    }
    w.document.dispatchEvent(new w.Event('DOMContentLoaded'));
    const d = w.document;
    const ready = await until(() => d.querySelector(T.row), 4000);
    assert.ok(ready, tree + ': machine rows rendered (page booted)');
    return { w, d, T, errors, close() { try { w.close(); } catch (e) { /* already closed */ } } };
}

for (const tree of ['v1', 'v2']) {
    test(tree + ': old-server payload (no accessories key, no display_status) renders quietly', async () => {
        const p = richPayload(); delete p.accessories;
        p.fleet.machines.forEach((m) => { delete m.display_status; delete m.power_state; delete m.power_reason; });
        const pg = await boot(tree, p);
        try {
            assert.equal(pg.errors.length, 0, pg.errors.join('|'));
            assert.match(pg.d.getElementById(pg.T.content).textContent, /NO ACCESSORIES DETECTED/);
            const rows = Array.from(pg.d.querySelectorAll(pg.T.row));
            const byHost = {};
            rows.forEach((r) => { byHost[r.querySelector(pg.T.host).textContent] = r; });
            assert.equal(byHost['host-off'].classList.contains('offline'), true);
            assert.equal(byHost['host-warn'].classList.contains('warning'), true);
            assert.equal(byHost['host-onb'].classList.contains('online'), true);
            assert.equal(pg.d.querySelector(pg.T.label), null, 'no power label from missing data');
            assert.equal(rows.some((r) => r.classList.contains('on-battery')), false);
        } finally { pg.close(); }
    });

    // Regression (found by XACA-1393-005): v1's sections.list lacked 'accessories', so the
    // ACCESSORIES sidebar button rendered but switchSection() silently returned -- a dead button.
    test(tree + ': the ACCESSORIES sidebar section is navigable', async () => {
        const pg = await boot(tree, richPayload());
        try {
            const S = pg.w.LCARS_CORE.sections;
            assert.ok(S.list.indexOf('accessories') !== -1, 'accessories is in sections.list');
            S.switchSection('accessories', true);
            const sec = pg.d.querySelector('.lcars-section[data-section="accessories"]');
            assert.ok(sec.classList.contains('active'), 'section shown');
            assert.ok(pg.d.querySelector('.sidebar-button[data-section="accessories"]').classList.contains('active'), 'button highlighted');
            assert.equal(pg.d.querySelectorAll('.lcars-section.active').length, 1, 'exactly one section active');
        } finally { pg.close(); }
    });

    test(tree + ': 3 accessory cards + D2 precedence on machine rows', async () => {
        const pg = await boot(tree, richPayload());
        try {
            assert.equal(pg.errors.length, 0, pg.errors.join('|'));
            assert.ok(pg.d.querySelector('.sidebar-button[data-section="accessories"]'), 'sidebar entry');
            const cards = Array.from(pg.d.getElementById(pg.T.content).querySelectorAll(pg.T.card));
            assert.equal(cards.length, 3);
            const by = {};
            cards.forEach((c) => { by[c.querySelector(pg.T.name).textContent] = c; });
            const one = by['UPS-One'], two = by['Rack'], three = by['UPS-Three'];
            assert.ok(one && two && three, Object.getOwnPropertyNames(by).join(','));
            assert.match(one.querySelector(pg.T.state).textContent, /ON BATTERY/);
            assert.match(one.textContent, /85%/);
            assert.match(one.textContent, /~40 MIN/);
            assert.match(one.textContent, /host-onb/);
            assert.match(one.textContent, /host-off/);
            assert.match(two.querySelector(pg.T.state).textContent, /^AC$/);
            assert.match(two.textContent, /100%/);
            assert.match(three.querySelector(pg.T.state).textContent, /UNKNOWN/);
            assert.doesNotMatch(three.textContent, /\d%/, 'null last_reading never renders a percent');
            assert.doesNotMatch(three.textContent, /NaN|undefined|null/);
            if (pg.T.link) assert.equal(one.querySelector(pg.T.link).textContent, 'host-onb');

            const rows = {};
            pg.d.querySelectorAll(pg.T.row).forEach((r) => { rows[r.querySelector(pg.T.host).textContent] = r; });
            assert.ok(rows['host-onb'].classList.contains('on-battery'));
            assert.equal(rows['host-onb'].querySelector(pg.T.label).textContent, 'ON UPS BATTERY · 85% · ~40 MIN');
            assert.ok(rows['host-off'].classList.contains('offline'), 'offline (RED) wins over on_battery');
            assert.equal(rows['host-off'].classList.contains('on-battery'), false);
            assert.equal(rows['host-off'].querySelector(pg.T.label), null);
            assert.equal(rows['host-ac'].querySelector(pg.T.label), null);
            assert.ok(rows['host-warn'].classList.contains('warning'));
            assert.equal(rows['host-warn'].classList.contains('on-battery'), false);
            assert.equal(rows['host-warn'].querySelector(pg.T.label), null, 'heartbeat warning carries no battery label');
            assert.equal(pg.d.querySelectorAll(pg.T.label).length, 1, 'label exactly where display_status === on_battery');
        } finally { pg.close(); }
    });

    test(tree + ': hostile strings never become markup; null percent/minutes render a dash', async () => {
        const evil = '"><img src=x onerror="window.__pwn=1">';
        const p = richPayload();
        p.fleet.machines[0].hostname = evil;
        p.fleet.machines[0].nickname = evil;
        p.fleet.machines[0].power_reason = { accessory_id: evil, accessory_name: evil, percent: evil, minutes_remaining: { x: 1 } };
        p.fleet.machines[2].hostname = evil;
        p.accessories[0].name = evil; p.accessories[0].display_name = evil; p.accessories[0].nickname = evil;
        p.accessories[0].last_reading.percent = null; p.accessories[0].last_reading.minutes_remaining = null;
        p.accessories[1].last_reading.percent = 'NaN';
        const pg = await boot(tree, p);
        try {
            assert.equal(pg.errors.length, 0, pg.errors.join('|'));
            assert.equal(pg.d.querySelectorAll('img[src="x"]').length, 0, 'no injected element');
            assert.equal(pg.d.querySelectorAll('[onerror*="__pwn"]').length, 0, 'no injected handler attribute');
            const cards = pg.d.getElementById(pg.T.content).querySelectorAll(pg.T.card);
            assert.equal(cards.length, 3);
            assert.doesNotMatch(cards[0].textContent, /NaN|undefined/);
            assert.match(cards[0].textContent, /—/, 'null percent/minutes -> dash');
            const lbl = pg.d.querySelector(pg.T.label);
            assert.equal(lbl.textContent, 'ON UPS BATTERY', 'non-numeric percent/minutes omitted from the label');
            assert.doesNotMatch(cards[1].textContent, /NaN/);
        } finally { pg.close(); }
    });

    test(tree + ': attach / detach URLs + 404 / 409 / non-JSON errors surface on the card', async () => {
        const pg = await boot(tree, richPayload());
        try {
            const sent = [];
            let reply = { ok: true, status: 200, json: async () => ({ success: true }) };
            pg.w.fleetApiFetch = async (url, init) => { sent.push({ url, method: init.method }); return reply; };
            const card = (name) => Array.from(pg.d.getElementById(pg.T.content).querySelectorAll(pg.T.card))
                .find((c) => c.querySelector(pg.T.name).textContent === name);

            // attach M_WARN to UPS-One
            let c = card('UPS-One');
            const sel = c.querySelector(pg.T.select);
            const opt = Array.from(sel.options).find((o) => o.textContent === 'host-warn');
            assert.ok(opt, 'attach picker lists unattached machines');
            sel.value = opt.value;
            sel.dispatchEvent(new sel.ownerDocument.defaultView.Event('change', { bubbles: true }));
            c.querySelector(pg.T.attachBtn).click();
            assert.ok(await until(() => sent.length === 1));
            assert.equal(sent[0].method, 'PUT');
            assert.match(sent[0].url, new RegExp('/api/accessories/' + ACC1 + '/machines/' + M_WARN + '$'));

            // detach M_OFF from UPS-One
            await sleep(150);
            c = card('UPS-One');
            const btn = Array.from(c.querySelectorAll(pg.T.detach)).find((b) => b.closest('li').textContent.indexOf('host-off') !== -1);
            assert.ok(btn, 'detach button for host-off');
            btn.click();
            assert.ok(await until(() => sent.length === 2));
            assert.equal(sent[1].method, 'DELETE');
            assert.match(sent[1].url, new RegExp('/api/accessories/' + ACC1 + '/machines/' + M_OFF + '$'));

            // 404 JSON error
            await sleep(150);
            reply = { ok: false, status: 404, json: async () => ({ error: 'Accessory not found' }) };
            card('UPS-One').querySelector(pg.T.detach).click();
            assert.ok(await until(() => { const e = card('UPS-One').querySelector(pg.T.err); return e && /Accessory not found/.test(e.textContent); }), '404 text shown');

            // 409 JSON error (attach)
            await sleep(150);
            reply = { ok: false, status: 409, json: async () => ({ error: 'Too many attached machines' }) };
            c = card('Rack');
            const s2 = c.querySelector(pg.T.select);
            s2.value = Array.from(s2.options).find((o) => o.textContent === 'host-warn').value;
            s2.dispatchEvent(new s2.ownerDocument.defaultView.Event('change', { bubbles: true }));
            c.querySelector(pg.T.attachBtn).click();
            assert.ok(await until(() => { const e = card('Rack').querySelector(pg.T.err); return e && /Too many attached machines/.test(e.textContent); }), '409 text shown');
            assert.match(card('UPS-One').querySelector(pg.T.err).textContent, /Accessory not found/, 'each error stays on its own card');

            // non-JSON error body -> HTTP status
            await sleep(150);
            reply = { ok: false, status: 502, json: async () => { throw new Error('not json'); } };
            card('Rack').querySelector(pg.T.detach).click();
            assert.ok(await until(() => { const e = card('Rack').querySelector(pg.T.err); return e && /502/.test(e.textContent); }), 'HTTP status shown');
            assert.equal(pg.errors.length, 0, pg.errors.join('|'));
        } finally { pg.close(); }
    });
}
