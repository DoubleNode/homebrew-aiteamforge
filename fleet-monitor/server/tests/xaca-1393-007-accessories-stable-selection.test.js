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
const ACC2 = 'acc_0000000000000002';
const MID = { a: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', b: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', c: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc' };

function payload(pct, n) {
    const m = (id, host, nick) => ({ machine_id: id, hostname: host, nickname: nick, status: 'online', display_status: 'online',
        power_state: null, power_reason: null, session_count: 0, sessions: [], uptime_history: [], system: {} });
    return {
        fleet: { total_machines: 3, online_machines: 3, offline_machines: 0, total_sessions: 0, divisions: {},
            machines: [m(MID.a, 'host-alpha', null), m(MID.b, 'host-bravo', null), m(MID.c, 'host-charlie', 'Charlie-Nick')] },
        activityLog: [],
        accessories: [[ACC, 'UPS-One'], [ACC2, 'UPS-Two']].slice(0, n || 1).map((p) => ({ id: p[0], type: 'ups', name: p[1], nickname: null, display_name: p[1], data_link_machine_id: null,
            attached_machine_ids: [], state: 'ac', state_since: null, history: [],
            last_reading: { source: 'ups', percent: pct, charging: false, minutes_remaining: 40, present: true, observedAt: '2026-10-08T12:00:00.000Z' } })),
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

async function boot(tree, htmlOverride, nAcc) {
    const T = Object.assign({}, TREES[tree], htmlOverride ? { html: htmlOverride } : {});
    const state = { data: payload(85, nAcc) };
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
        // XACA-1480-010: a fixed sleep let the poll's fetch resolve LATE under full-suite
        // load, so its re-render landed after the test had started its next step (and
        // after it had put focus somewhere). Wait for the poll's own reading to be
        // painted -- the re-render is synchronous, so focus restore has run by then.
        await until(() => (d.getElementById(T.content).textContent || '').includes(pct + '%'), 4000);
        await sleep(50);
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
            s0.dispatchEvent(new s0.ownerDocument.defaultView.Event('change', { bubbles: true }));
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
            s.dispatchEvent(new s.ownerDocument.defaultView.Event('change', { bubbles: true }));
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

// ---------------------------------------------------------------------------
// Round 2 (review): the stable-selection class over ALL 5 pages, table-driven.
// Rows: (a) changed-reading poll, (b) picker focused during the rebuild,
// (c) TWO accessories: a write on card B, then ATTACH on card A must send card
// A's own pick (never machine[0], never card B's machine), (d) placeholder.
// ---------------------------------------------------------------------------
const PAGES = A11Y_PAGES.map((p) => ({ tree: p[0], page: p[1] }));
const labelOpt = (sel, label) => Array.from(sel.options).find((o) => o.textContent === label);
const cards = (pg) => Array.from(pg.d.getElementById(pg.T.content).querySelectorAll('.accessory-card'));
const stubFetch = (pg, sent, onWrite) => {
    pg.w.fleetApiFetch = async (url, init) => {
        sent.push({ url: String(url), method: init.method });
        if (onWrite) onWrite(String(url), init.method);
        return { ok: true, status: 200, json: async () => ({}) };
    };
};

for (const { tree, page } of PAGES) {
    const tag = page + ': ';

    test(tag + '(a) changed-reading poll keeps the pick; ATTACH sends it', async () => {
        const pg = await boot(tree, page, 2);
        try {
            const sent = []; stubFetch(pg, sent);
            const sA = cards(pg)[0].querySelector(SEL);
            sA.value = labelOpt(sA, 'Charlie-Nick').value;
            sA.dispatchEvent(new sA.ownerDocument.defaultView.Event('change', { bubbles: true }));
            await pg.poll(71);
            assert.match(pg.d.getElementById(pg.T.content).textContent, /71%/);
            const sA2 = cards(pg)[0].querySelector(SEL);
            assert.equal(sA2.options[sA2.selectedIndex].textContent, 'Charlie-Nick');
            cards(pg)[0].querySelector(BTN).click();
            assert.ok(await until(() => sent.length === 1));
            assert.ok(sent[0].url.endsWith('/api/accessories/' + ACC + '/machines/' + MID.c), sent[0].url);
            await sleep(250);
        } finally { pg.close(); }
    });

    test(tag + '(b) picker focused during the rebuild keeps the pick', async () => {
        const pg = await boot(tree, page, 2);
        try {
            const sent = []; stubFetch(pg, sent);
            const sA = cards(pg)[0].querySelector(SEL);
            sA.value = labelOpt(sA, 'host-bravo').value;
            sA.dispatchEvent(new sA.ownerDocument.defaultView.Event('change', { bubbles: true }));
            sA.focus();
            assert.equal(pg.d.activeElement, sA);
            await pg.poll(64);
            const sA2 = cards(pg)[0].querySelector(SEL);
            assert.equal(sA2.options[sA2.selectedIndex].textContent, 'host-bravo');
            cards(pg)[0].querySelector(BTN).click();
            assert.ok(await until(() => sent.length === 1));
            assert.ok(sent[0].url.endsWith('/machines/' + MID.b), sent[0].url);
            await sleep(250);
        } finally { pg.close(); }
    });

    test(tag + '(c) write on card B, poll, then ATTACH on card A sends A\'s own pick', async () => {
        const pg = await boot(tree, page, 2);
        try {
            pg.state.data.accessories[1].attached_machine_ids = [MID.a];
            await pg.poll(80);
            await until(() => cards(pg).length === 2 && cards(pg)[1].querySelector('.accessory-detach, .accessory-detach-btn'));
            const sent = [];
            stubFetch(pg, sent, (url, method) => {
                if (method === 'DELETE') pg.state.data.accessories[1].attached_machine_ids = [];
            });
            const sA = cards(pg)[0].querySelector(SEL);
            sA.value = labelOpt(sA, 'Charlie-Nick').value;
            sA.dispatchEvent(new sA.ownerDocument.defaultView.Event('change', { bubbles: true }));
            sA.focus();
            cards(pg)[1].querySelector('.accessory-detach, .accessory-detach-btn').click();   // write on card B
            assert.ok(await until(() => sent.length === 1));
            await sleep(400);                      // post-write refresh settles
            await pg.poll(55);                     // then a changed-reading poll
            const sA2 = cards(pg)[0].querySelector(SEL);
            assert.equal(sA2.options[sA2.selectedIndex].textContent, 'Charlie-Nick', 'card A pick survived card B write + poll');
            cards(pg)[0].querySelector(BTN).click();
            assert.ok(await until(() => sent.length === 2));
            assert.equal(sent[0].method, 'DELETE');
            assert.ok(sent[0].url.includes('/' + ACC2 + '/machines/' + MID.a), sent[0].url);
            assert.equal(sent[1].method, 'PUT');
            assert.ok(sent[1].url.endsWith('/api/accessories/' + ACC + '/machines/' + MID.c), 'card A -> charlie, got ' + sent[1].url);
            await sleep(250);
            assert.equal(sent.filter((x) => x.method === 'PUT').length, 1, 'exactly one PUT, none for another machine');
        } finally { pg.close(); }
    });

    test(tag + '(d) placeholder selected: ATTACH sends nothing, before and after a poll', async () => {
        const pg = await boot(tree, page, 2);
        try {
            const sent = []; stubFetch(pg, sent);
            cards(pg)[0].querySelector(BTN).click();
            await pg.poll(61);
            assert.equal(cards(pg)[0].querySelector(SEL).value, '');
            cards(pg)[0].querySelector(BTN).click();
            await sleep(100);
            assert.equal(sent.length, 0);
        } finally { pg.close(); }
    });

    test(tag + '(e) picked machine leaves the fleet: falls back to the placeholder, ATTACH sends nothing', async () => {
        const pg = await boot(tree, page, 2);
        try {
            const sent = []; stubFetch(pg, sent);
            const sA = cards(pg)[0].querySelector(SEL);
            sA.value = labelOpt(sA, 'Charlie-Nick').value;
            sA.dispatchEvent(new sA.ownerDocument.defaultView.Event('change', { bubbles: true }));
            pg.state.data.fleet.machines = pg.state.data.fleet.machines.filter((m) => m.machine_id !== MID.c);
            await pg.poll(58);
            const sA2 = cards(pg)[0].querySelector(SEL);
            assert.equal(sA2.value, '', 'placeholder, not a silently-different machine');
            assert.equal(labelOpt(sA2, 'Charlie-Nick'), undefined, 'departed machine no longer offered');
            cards(pg)[0].querySelector(BTN).click();
            await sleep(100);
            assert.equal(sent.length, 0);
        } finally { pg.close(); }
    });

    test(tag + '(f) machines array reverses between polls: pick survives by machine id', async () => {
        const pg = await boot(tree, page, 2);
        try {
            const sent = []; stubFetch(pg, sent);
            const sA = cards(pg)[0].querySelector(SEL);
            sA.value = labelOpt(sA, 'host-bravo').value;
            sA.dispatchEvent(new sA.ownerDocument.defaultView.Event('change', { bubbles: true }));
            pg.state.data.fleet.machines.reverse();
            await pg.poll(57);
            const sA2 = cards(pg)[0].querySelector(SEL);
            assert.equal(sA2.options[sA2.selectedIndex].textContent, 'host-bravo', 'followed the id, not the position');
            cards(pg)[0].querySelector(BTN).click();
            assert.ok(await until(() => sent.length === 1));
            assert.ok(sent[0].url.endsWith('/api/accessories/' + ACC + '/machines/' + MID.b), sent[0].url);
            await sleep(250);
        } finally { pg.close(); }
    });

    test(tag + 'ATTACH is disabled until a real machine is picked (XACA-1393-021)', async () => {
        const pg = await boot(tree, page, 2);
        try {
            const btn = () => cards(pg)[0].querySelector(BTN);
            const sel = () => cards(pg)[0].querySelector(SEL);
            const change = (el) => el.dispatchEvent(new pg.w.Event('change', { bubbles: true }));
            assert.equal(btn().disabled, true, 'placeholder selected => ATTACH disabled');
            sel().value = sel().options[1].value; change(sel());
            assert.equal(btn().disabled, false, 'real pick => ATTACH enabled');
            await pg.poll(55);
            assert.equal(btn().disabled, false, 'restored pick survives a rebuild enabled');
            sel().value = ''; change(sel());
            assert.equal(btn().disabled, true, 'back to placeholder => disabled again');
            await pg.poll(54);
            assert.equal(btn().disabled, true, 'no pick => still disabled after a rebuild');
        } finally { pg.close(); }
    });

    // Advisory: keyboard focus is restored to the same control after a rebuild.
    test(tag + 'focus is restored to select / ATTACH / the same DETACH after a rebuild', async () => {
        const pg = await boot(tree, page, 2);
        try {
            pg.state.data.accessories[0].attached_machine_ids = [MID.a, MID.b];
            await pg.poll(90);
            // ATTACH is disabled (unfocusable) until a machine is picked.
            const pick = cards(pg)[0].querySelector(SEL);
            pick.value = pick.options[1].value;
            pick.dispatchEvent(new pg.w.Event('change', { bubbles: true }));
            const detachSel = '.accessory-detach, .accessory-detach-btn';
            const name = (el) => el.getAttribute('aria-label') || '';
            const focusCases = [
                ['select', () => cards(pg)[0].querySelector(SEL), (el) => /Machine to attach to UPS-One/.test(name(el))],
                ['attach', () => cards(pg)[0].querySelector(BTN), (el) => /Attach selected machine to UPS-One/.test(name(el))],
                ['detach b', () => cards(pg)[0].querySelectorAll(detachSel)[1], (el) => /Detach host-bravo from UPS-One/.test(name(el))]
            ];
            let pct = 40;
            for (const [what, find, ok] of focusCases) {
                const before = find();
                before.focus();
                assert.equal(pg.d.activeElement, before, what + ' focused');
                await pg.poll(pct--);
                await until(() => pg.d.activeElement !== before && pg.d.activeElement !== pg.d.body);
                const now = pg.d.activeElement;
                assert.notEqual(now, pg.d.body, what + ': focus not dropped to body');
                assert.notEqual(now, before, what + ': the control really was rebuilt');
                assert.ok(ok(now), what + ': focus on the equivalent control, got ' + name(now));
            }
        } finally { pg.close(); }
    });

    // Round 4 (UX advisory, WCAG 2.4.3): after a write the focus must land on the
    // card (picker, else first DETACH, else the card), never on <body>, and the
    // outcome is announced through a polite live region that survives rebuilds.
    const live = (pg) => pg.d.getElementById(pg.T.content).parentNode.querySelector('.accessory-sr-only[aria-live="polite"]');
    const inCard0 = (pg, el) => cards(pg)[0] && cards(pg)[0].contains(el);

    test(tag + 'DETACH: focus stays on the card (not body) and the result is announced', async () => {
        const pg = await boot(tree, page, 2);
        try {
            pg.state.data.accessories[0].attached_machine_ids = [MID.a];
            await pg.poll(90);
            const sent = [];
            stubFetch(pg, sent, (url, method) => { if (method === 'DELETE') pg.state.data.accessories[0].attached_machine_ids = []; });
            assert.ok(await until(() => cards(pg)[0] && cards(pg)[0].querySelector('.accessory-detach, .accessory-detach-btn')), 'DETACH rendered');
            const btn = cards(pg)[0].querySelector('.accessory-detach, .accessory-detach-btn');
            btn.focus();
            assert.equal(pg.d.activeElement, btn);
            btn.click();
            assert.ok(await until(() => sent.length === 1));
            assert.ok(await until(() => /Detached .* from UPS-One/.test((live(pg) || {}).textContent || '')), 'live region announced');
            assert.ok(await until(() => cards(pg)[0] && pg.d.activeElement === cards(pg)[0].querySelector(SEL)), 'focus settles on the card select');
            const now = pg.d.activeElement;
            assert.notEqual(now, pg.d.body, 'focus not dropped to body');
            assert.equal(now, cards(pg)[0].querySelector(SEL), 'focus on the card\'s machine select');
            assert.match(live(pg).textContent, /Detached host-alpha from UPS-One/);
            assert.equal(pg.d.getElementById(pg.T.content).contains(live(pg)), false, 'live region is outside the rebuilt list');
        } finally { pg.close(); }
    });

    test(tag + 'ATTACH after picking: focus stays on the card (not body) and the result is announced', async () => {
        const pg = await boot(tree, page, 2);
        try {
            const sent = [];
            stubFetch(pg, sent, (url, method) => { if (method === 'PUT') pg.state.data.accessories[0].attached_machine_ids = [MID.c]; });
            const sA = cards(pg)[0].querySelector(SEL);
            sA.value = labelOpt(sA, 'Charlie-Nick').value;
            sA.dispatchEvent(new pg.w.Event('change', { bubbles: true }));   // ATTACH is disabled until picked
            const btn = cards(pg)[0].querySelector(BTN);
            assert.equal(btn.disabled, false);
            btn.focus();
            assert.equal(pg.d.activeElement, btn);
            btn.click();
            assert.ok(await until(() => sent.length === 1));
            assert.ok(await until(() => /Attached .* to UPS-One/.test((live(pg) || {}).textContent || '')), 'live region announced');
            assert.ok(await until(() => cards(pg)[0] && pg.d.activeElement === cards(pg)[0].querySelector(SEL)), 'focus settles on the card select');
            const now = pg.d.activeElement;
            assert.notEqual(now, pg.d.body, 'focus not dropped to body');
            assert.equal(now, cards(pg)[0].querySelector(SEL), 'focus on the card\'s machine select');
            assert.match(live(pg).textContent, /Attached Charlie-Nick to UPS-One/);
        } finally { pg.close(); }
    });

    test(tag + 'write while focus is elsewhere does not steal focus', async () => {
        const pg = await boot(tree, page, 2);
        try {
            pg.state.data.accessories[0].attached_machine_ids = [MID.a];
            await pg.poll(90);
            const sent = [];
            stubFetch(pg, sent, (url, method) => { if (method === 'DELETE') pg.state.data.accessories[0].attached_machine_ids = []; });
            assert.ok(await until(() => cards(pg)[0] && cards(pg)[0].querySelector('.accessory-detach, .accessory-detach-btn')), 'DETACH rendered');
            const outside = pg.d.createElement('button'); pg.d.body.appendChild(outside); outside.focus();
            cards(pg)[0].querySelector('.accessory-detach, .accessory-detach-btn').click();
            assert.ok(await until(() => /Detached/.test((live(pg) || {}).textContent || '')));
            assert.equal(pg.d.activeElement, outside, 'focus left alone');
            assert.equal(inCard0(pg, pg.d.activeElement), false);
        } finally { pg.close(); }
    });
}
