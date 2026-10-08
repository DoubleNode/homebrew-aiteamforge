//
//  xaca-1393-007-accessories-stable-selection.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1393 test-gate round 1: the ACCESSORIES attach picker must survive a poll.
 *
 * Bug: lcars2 rebuilt the cards on nearly every poll (each new UPS reading changes
 * the data signature), the <select> had no empty first option and no memory, so a
 * rebuild reset it to the FIRST machine and ATTACH then sent that one (pick
 * charlie, poll, ATTACH -> bravo). v1 lost the choice too and stopped refreshing
 * readings while the dropdown held focus.
 *
 * Boots the real pages in jsdom (v1 + lcars2), drives the real poll timer, and
 * asserts: the pick survives a changed-reading poll and ATTACH sends THAT machine;
 * ATTACH with the placeholder sends nothing; a stale pick (machine now attached)
 * falls back to the placeholder; readings refresh while the select is focused;
 * machine nicknames are rendered.
 *
 * Fail-before proof: the OLD_V1 / OLD_V2 variables (below) point a tree at a
 * pre-fix copy of its script (`git show <rev>:<path>`); the suite must go red.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const PUB = path.join(__dirname, '..', 'public');
const OLD_V1 = process.env.XACA1393_OLD_V1;
const OLD_V2 = process.env.XACA1393_OLD_V2;
const ACC = 'acc_0000000000000001';
const MID = { a: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', b: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', c: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc' };

function payload(pct) {
    const m = (id, host, nick) => ({ machine_id: id, hostname: host, nickname: nick, status: 'online', display_status: 'online',
        power_state: null, power_reason: null, session_count: 0, sessions: [], uptime_history: [], system: {} });
    return {
        fleet: { total_machines: 3, online_machines: 3, offline_machines: 0, total_sessions: 0, divisions: {},
            machines: [m(MID.a, 'host-alpha', null), m(MID.b, 'host-bravo', null), m(MID.c, 'host-charlie', 'Charlie-Nick')] },
        activityLog: [],
        accessories: [{ id: ACC, type: 'ups', name: 'UPS-One', nickname: null, display_name: 'UPS-One', data_link_machine_id: null,
            attached_machine_ids: [], state: 'ac', state_since: null, history: [],
            last_reading: { source: 'ups', percent: pct, charging: false, minutes_remaining: 40, present: true, observedAt: '2026-10-08T12:00:00.000Z' } }],
        last_update: '2026-10-08T12:00:00.000Z'
    };
}

const TREES = {
    v1: { html: 'lcars/lcars-dashboard.html', content: 'accessories-content', row: '.machine-row' },
    v2: { html: 'lcars2/lcars-all.html', content: 'accessories-list', row: '.status-row' }
};
const SEL = '.accessory-attach-select', BTN = '.accessory-attach-btn';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(fn, ms) {
    const end = Date.now() + (ms || 3000);
    while (Date.now() < end) { try { if (fn()) return true; } catch (e) { /* not yet */ } await sleep(25); }
    return false;
}

async function boot(tree, htmlOverride) {
    const T = Object.assign({}, TREES[tree], htmlOverride ? { html: htmlOverride } : {});
    const state = { data: payload(85) };
    const dom = new JSDOM(fs.readFileSync(path.join(PUB, T.html), 'utf8'),
        { url: 'http://localhost:1/' + T.html, runScripts: 'outside-only', pretendToBeVisual: true });
    const w = dom.window;
    const timers = [];
    w.setInterval = (fn) => { timers.push(fn); return timers.length; };
    w.fetch = async (u) => {
        if (/\/api\/fleet(\?|$)/.test(String(u))) return { ok: true, status: 200, json: async () => JSON.parse(JSON.stringify(state.data)), text: async () => '' };
        return { ok: false, status: 404, json: async () => ({}), text: async () => '' };
    };
    w.EventSource = function () { this.close = function () {}; };
    w.console.error = function () {}; w.console.log = function () {}; w.console.warn = function () {};
    const srcs = Array.from(w.document.querySelectorAll('script[src]')).map((s) => s.getAttribute('src')).filter((s) => !/^https?:/.test(s));
    for (const s of srcs) {
        let f = path.join(PUB, path.dirname(T.html), s.split('?')[0]);
        if (tree === 'v2' && OLD_V2 && /lcars-fleet-dashboard-app\.js$/.test(f)) f = OLD_V2;
        if (tree === 'v1' && OLD_V1 && /lcars-accessories\.js$/.test(f)) f = OLD_V1;
        try { w.eval(fs.readFileSync(f, 'utf8')); } catch (e) { /* surfaced by the assertions */ }
    }
    w.document.dispatchEvent(new w.Event('DOMContentLoaded'));
    if (!htmlOverride) assert.ok(await until(() => w.document.querySelector(T.row), 4000), tree + ': booted');
    const d = w.document;
    assert.ok(await until(() => d.getElementById(T.content).querySelector(SEL)), tree + ': picker rendered');
    // Real poll: fire every captured interval callback, then let the fetch settle.
    const poll = async (pct) => {
        state.data.accessories[0].last_reading.percent = pct;
        timers.forEach((fn) => { try { fn(); } catch (e) { /* unrelated timer */ } });
        await sleep(200);
    };
    return { w, d, T, poll, state, close() { try { w.close(); } catch (e) { /* closed */ } } };
}

for (const tree of ['v1', 'v2']) {
    test(tree + ': pick survives a changed-reading poll and ATTACH sends THAT machine', async () => {
        const pg = await boot(tree);
        try {
            const sent = [];
            pg.w.fleetApiFetch = async (url, init) => { sent.push({ url, method: init.method }); return { ok: true, status: 200, json: async () => ({}) }; };
            const root = () => pg.d.getElementById(pg.T.content);
            const s0 = root().querySelector(SEL);
            assert.equal(s0.options[0].value, '', 'empty placeholder is the first option');
            assert.equal(s0.value, '', 'nothing preselected');
            s0.value = Array.from(s0.options).find((o) => o.textContent === 'Charlie-Nick').value;
            await pg.poll(71);   // new reading => data signature changes => rebuild
            assert.match(root().textContent, /71%/, 'poll applied the new reading');
            const s = root().querySelector(SEL);
            assert.equal(s.options[s.selectedIndex].textContent, 'Charlie-Nick', 'selection survived the rebuild');
            root().querySelector(BTN).click();
            assert.ok(await until(() => sent.length === 1));
            assert.equal(sent[0].method, 'PUT');
            assert.ok(sent[0].url.endsWith('/api/accessories/' + ACC + '/machines/' + MID.c), 'attached charlie, got ' + sent[0].url);
            await sleep(250);   // let the post-write refresh settle before the window closes
        } finally { pg.close(); }
    });

    test(tree + ': ATTACH with the placeholder selected sends nothing (also after a rebuild)', async () => {
        const pg = await boot(tree);
        try {
            const sent = [];
            pg.w.fleetApiFetch = async (url) => { sent.push(url); return { ok: true, status: 200, json: async () => ({}) }; };
            const root = () => pg.d.getElementById(pg.T.content);
            root().querySelector(BTN).click();
            await pg.poll(70);
            root().querySelector(BTN).click();
            await sleep(100);
            assert.equal(sent.length, 0);
        } finally { pg.close(); }
    });

    test(tree + ': a stale pick (machine now attached elsewhere) falls back to the placeholder', async () => {
        const pg = await boot(tree);
        try {
            const root = () => pg.d.getElementById(pg.T.content);
            const s = root().querySelector(SEL);
            s.value = Array.from(s.options).find((o) => o.textContent === 'host-bravo').value;
            pg.state.data.accessories[0].attached_machine_ids = [MID.b];
            await pg.poll(59);
            const s2 = root().querySelector(SEL);
            assert.equal(s2.value, '', 'placeholder, not a silently-different machine');
            assert.equal(Array.from(s2.options).some((o) => o.textContent === 'host-bravo'), false);
        } finally { pg.close(); }
    });

    test(tree + ': machine nicknames are shown (nickname -> hostname)', async () => {
        const pg = await boot(tree);
        try {
            const labels = Array.from(pg.d.getElementById(pg.T.content).querySelector(SEL).options).map((o) => o.textContent);
            assert.ok(labels.includes('Charlie-Nick'), labels.join(','));
            assert.ok(labels.includes('host-alpha'), 'falls back to hostname');
            assert.ok(!labels.includes('host-charlie'), 'nickname wins over hostname');
            pg.state.data.accessories[0].attached_machine_ids = [MID.c];
            await pg.poll(80);
            assert.match(pg.d.getElementById(pg.T.content).querySelector('.accessory-machine-name, .accessory-attached-name').textContent, /Charlie-Nick/);
        } finally { pg.close(); }
    });
}

test('v1: readings keep refreshing while the select has focus', async () => {
    const pg = await boot('v1');
    try {
        const root = () => pg.d.getElementById(pg.T.content);
        const s = root().querySelector(SEL);
        s.focus();
        assert.equal(pg.d.activeElement, s, 'select focused');
        await pg.poll(42);
        assert.match(root().textContent, /42%/, 'focus no longer freezes UPS readings');
    } finally { pg.close(); }
});

// UX gate (WCAG 4.1.2 / 2.4.6): every attach/detach control names its accessory.
const A11Y_PAGES = [['v1', 'lcars/lcars-dashboard.html'], ['v2', 'lcars2/lcars-all.html'], ['v2', 'lcars2/lcars-index.html'],
    ['v2', 'lcars2/lcars-doublenode.html'], ['v2', 'lcars2/lcars-mainevent.html']];
for (const [tree, page] of A11Y_PAGES) {
    test('a11y: ' + page + ' attach/detach controls have names that identify the accessory', async () => {
        const pg = await boot(tree, page);
        try {
            pg.state.data.accessories[0].attached_machine_ids = [MID.c];
            await pg.poll(66);
            const root = pg.d.getElementById(pg.T.content);
            const name = (el) => (el.getAttribute('aria-label') || el.textContent || '').trim();
            const ctl = Array.from(root.querySelectorAll('select, button'));
            const kinds = { select: 0, attach: 0, detach: 0 };
            ctl.forEach((el) => {
                assert.ok(name(el).length > 0, 'non-empty name');
                assert.ok(name(el).includes('UPS-One'), 'name includes the accessory: ' + name(el));
                if (el.tagName === 'SELECT') kinds.select++;
                else if (/attach-btn/.test(el.className)) kinds.attach++;
                else { kinds.detach++; assert.ok(name(el).includes('Charlie-Nick'), 'detach names the machine: ' + name(el)); }
            });
            assert.deepEqual(kinds, { select: 1, attach: 1, detach: 1 });
        } finally { pg.close(); }
    });
}

test('v1: a double-click on DETACH sends ONE request and shows no error', async () => {
    const pg = await boot('v1');
    try {
        pg.state.data.accessories[0].attached_machine_ids = [MID.c];
        await pg.poll(66);
        const sent = [];
        let n = 0;
        pg.w.fleetApiFetch = async (url) => { sent.push(url); n++; await sleep(60); return n === 1 ? { ok: true, status: 200, json: async () => ({}) } : { ok: false, status: 404, json: async () => ({ error: 'nf' }) }; };
        const btn = pg.d.getElementById(pg.T.content).querySelector('.accessory-detach-btn');
        btn.click(); btn.click();
        await sleep(300);
        assert.equal(sent.length, 1);
        assert.equal(pg.d.getElementById(pg.T.content).querySelector('.accessory-error'), null);
    } finally { pg.close(); }
});

test('v1: shows type, CHARGING and LAST OBSERVED like lcars2', async () => {
    const pg = await boot('v1');
    try {
        pg.state.data.accessories[0].last_reading.charging = true;
        await pg.poll(50);
        const t = pg.d.getElementById(pg.T.content).textContent;
        assert.match(t, /UPS/); assert.match(t, /CHARGING/); assert.match(t, /LAST OBSERVED/);
        assert.ok(pg.d.querySelector('.accessory-detach-btn, .accessory-card') !== null);
    } finally { pg.close(); }
});
