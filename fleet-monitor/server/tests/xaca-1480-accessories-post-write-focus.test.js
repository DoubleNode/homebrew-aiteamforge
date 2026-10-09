//
//  xaca-1480-accessories-post-write-focus.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//
'use strict';
/**
 * XACA-1480-003: post-write focus restore decides at REFRESH time, not from the
 * pre-write hadFocus snapshot alone (v1 lcars-accessories.js refreshAfterWrite and
 * lcars2 lcars-fleet-dashboard-app.js accessoryMutate).
 *
 * Boots the real pages in jsdom and holds the write's fleetApiFetch promise pending
 * so focus can be moved while the write is in flight.
 *
 *   a) focus moved OUTSIDE the container mid-write -> left where the operator put it
 *   b) focus lost to <body> mid-write            -> card is refocused
 *   c) focus on a control inside the container   -> card is refocused
 *   d) fallbacks: DETACH-only card (no picker), the card itself, and a FAILED write
 *
 * Fail-before proof: (a) and the failed-write variant go red when the one-line
 * `hadFocus && (...)` gate is reverted to `if (hadFocus)` in either file.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const PUB = path.join(__dirname, '..', 'public');
const ACC = 'acc_0000000000000001';
const ACC2 = 'acc_0000000000000002';
const MID = { a: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', b: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', c: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc' };
const TREES = {
    v1: { html: 'lcars/lcars-dashboard.html', content: 'accessories-content', row: '.machine-row', detach: '.accessory-detach-btn' },
    v2: { html: 'lcars2/lcars-all.html', content: 'accessories-list', row: '.status-row', detach: '.accessory-detach' }
};
const SEL = '.accessory-attach-select', BTN = '.accessory-attach-btn';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(fn, ms) {
    const end = Date.now() + (ms || 3000);
    while (Date.now() < end) { try { if (fn()) return true; } catch (e) { /* not yet */ } await sleep(25); }
    return false;
}

function payload() {
    const m = (id, host) => ({ machine_id: id, hostname: host, nickname: null, status: 'online', display_status: 'online',
        power_state: null, power_reason: null, session_count: 0, sessions: [], uptime_history: [], system: {} });
    return {
        fleet: { total_machines: 3, online_machines: 3, offline_machines: 0, total_sessions: 0, divisions: {},
            machines: [m(MID.a, 'host-alpha'), m(MID.b, 'host-bravo'), m(MID.c, 'host-charlie')] },
        activityLog: [],
        accessories: [[ACC, 'UPS-One'], [ACC2, 'UPS-Two']].map((p) => ({ id: p[0], type: 'ups', name: p[1], nickname: null, display_name: p[1],
            data_link_machine_id: null, attached_machine_ids: [], state: 'ac', state_since: null, history: [],
            last_reading: { source: 'ups', percent: 85, charging: false, minutes_remaining: 40, present: true, observedAt: '2026-10-08T12:00:00.000Z' } })),
        last_update: '2026-10-08T12:00:00.000Z'
    };
}

async function boot(tree) {
    const T = TREES[tree];
    const state = { data: payload() };
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
        try { w.eval(fs.readFileSync(path.join(PUB, path.dirname(T.html), s.split('?')[0]), 'utf8')); } catch (e) { /* surfaced by the assertions */ }
    }
    w.document.dispatchEvent(new w.Event('DOMContentLoaded'));
    const d = w.document;
    assert.ok(await until(() => d.querySelector(T.row), 4000), tree + ': booted');
    assert.ok(await until(() => d.getElementById(T.content).querySelector(SEL)), tree + ': picker rendered');
    const root = () => d.getElementById(T.content);
    const poll = async (pct) => {
        state.data.accessories[0].last_reading.percent = pct;
        timers.forEach((fn) => { try { fn(); } catch (e) { /* unrelated timer */ } });
        await until(() => (root().textContent || '').includes(pct + '%'), 4000);
        await sleep(50);
    };
    return { w, d, T, state, poll, root, close() { try { w.close(); } catch (e) { /* closed */ } } };
}

const card = (pg, i) => Array.from(pg.root().querySelectorAll('.accessory-card'))[i];
const live = (pg) => pg.root().parentNode.querySelector('.accessory-sr-only[aria-live="polite"]');

/**
 * Hold the write pending. Returns { sent, release(ok) }. On release the server state
 * is updated (success only) and the fetch resolves, which starts the post-write refresh.
 */
function pendWrite(pg, onSuccess) {
    const sent = [];
    let go;
    const gate = new Promise((r) => { go = r; });
    pg.w.fleetApiFetch = async (url, init) => {
        sent.push({ url: String(url), method: init.method });
        const ok = await gate;
        if (ok) onSuccess();
        return ok ? { ok: true, status: 200, json: async () => ({}) }
            : { ok: false, status: 500, json: async () => ({ error: 'boom' }) };
    };
    return { sent, release(ok) { go(ok !== false); } };
}
const settled = async (pg, ok) => {
    if (ok) assert.ok(await until(() => /Detached|Attached/.test((live(pg) || {}).textContent || '')), 'write refresh + announcement done');
    else assert.ok(await until(() => pg.root().querySelector('.accessory-error')), 'error shown');
    await sleep(150);   // let any trailing continuation of the refresh run
};
const outsideButton = (pg) => { const b = pg.d.createElement('button'); b.id = 'outside'; pg.d.body.appendChild(b); return b; };

for (const tree of ['v1', 'v2']) {
    const tag = tree + ': ';

    async function detachScenario(pg, opts) {
        pg.state.data.accessories[0].attached_machine_ids = (opts && opts.attached) || [MID.a];
        if (opts && opts.machines) pg.state.data.fleet.machines = opts.machines;
        await pg.poll(90);
        assert.ok(await until(() => card(pg, 0) && card(pg, 0).querySelector(pg.T.detach)), 'DETACH rendered');
        const pend = pendWrite(pg, () => { pg.state.data.accessories[0].attached_machine_ids = []; });
        const btn = card(pg, 0).querySelector(pg.T.detach);
        btn.focus();
        assert.equal(pg.d.activeElement, btn, 'DETACH focused pre-write');
        btn.click();
        assert.ok(await until(() => pend.sent.length === 1), 'write sent');
        return pend;
    }

    test(tag + '(a) DETACH: focus moved OUTSIDE the container mid-write stays where the operator put it', async () => {
        const pg = await boot(tree);
        try {
            const pend = await detachScenario(pg);
            const outside = outsideButton(pg); outside.focus();
            assert.equal(pg.d.activeElement, outside);
            pend.release(true);
            await settled(pg, true);
            assert.equal(pg.d.activeElement, outside, 'focus not yanked back to the accessory card');
        } finally { pg.close(); }
    });

    test(tag + '(a) ATTACH: focus moved OUTSIDE the container mid-write stays where the operator put it', async () => {
        const pg = await boot(tree);
        try {
            const s = card(pg, 0).querySelector(SEL);
            s.value = Array.from(s.options).find((o) => o.textContent === 'host-bravo').value;
            s.dispatchEvent(new pg.w.Event('change', { bubbles: true }));
            const pend = pendWrite(pg, () => { pg.state.data.accessories[0].attached_machine_ids = [MID.b]; });
            const btn = card(pg, 0).querySelector(BTN);
            btn.focus();
            assert.equal(pg.d.activeElement, btn);
            btn.click();
            assert.ok(await until(() => pend.sent.length === 1));
            const outside = outsideButton(pg); outside.focus();
            pend.release(true);
            await settled(pg, true);
            assert.equal(pg.d.activeElement, outside, 'focus not yanked back');
        } finally { pg.close(); }
    });

    test(tag + '(b) focus lost to <body> mid-write: the card is refocused', async () => {
        const pg = await boot(tree);
        try {
            const pend = await detachScenario(pg);
            // jsdom refuses to blur a disabled control (v1 locks it during the write); the
            // real-browser equivalent is the disabled control dropping focus to <body>.
            const a = pg.d.activeElement; a.disabled = false; a.blur();
            assert.equal(pg.d.activeElement, pg.d.body, 'focus is on body while the write is pending');
            pend.release(true);
            await settled(pg, true);
            assert.equal(pg.d.activeElement, card(pg, 0).querySelector(SEL), 'refocused the card\'s picker');
        } finally { pg.close(); }
    });

    test(tag + '(c) focus still inside the container (sibling card) at refresh: the written card is refocused', async () => {
        const pg = await boot(tree);
        try {
            const pend = await detachScenario(pg);
            const other = card(pg, 1);
            other.setAttribute('tabindex', '-1');
            other.focus();
            assert.equal(pg.d.activeElement, other, 'sibling card focused mid-write');
            pend.release(true);
            await settled(pg, true);
            assert.equal(pg.root().contains(pg.d.activeElement), true, 'focus still inside the container');
            assert.equal(pg.d.activeElement, card(pg, 0).querySelector(SEL), 'refocused the written card\'s picker');
        } finally { pg.close(); }
    });

    // --- (d) fallback targets --------------------------------------------------
    test(tag + '(d) DETACH-only card (no picker): focus falls back to the first DETACH', async () => {
        const pg = await boot(tree);
        try {
            // all three machines attached => no unattached machine => no picker
            const pend = await detachScenario(pg, { attached: [MID.a, MID.b, MID.c] });
            assert.equal(card(pg, 0).querySelector(SEL), null, 'precondition: no picker');
            pend.release(false);   // FAILED write keeps the card picker-less
            await settled(pg, false);
            assert.equal(card(pg, 0).querySelector(SEL), null, 'still no picker');
            assert.equal(pg.d.activeElement, card(pg, 0).querySelector(pg.T.detach), 'first DETACH focused');
        } finally { pg.close(); }
    });

    test(tag + '(d) card itself (tabindex=-1) is the fallback when no picker and no DETACH remain', async () => {
        const pg = await boot(tree);
        try {
            // fleet has no machines; the accessory still lists a (raw-id) attached one
            const pend = await detachScenario(pg, { attached: ['ghost-machine-id'], machines: [] });
            assert.equal(card(pg, 0).querySelector(SEL), null, 'precondition: no picker');
            pend.release(true);   // DETACH succeeds => nothing left to focus but the card
            await settled(pg, true);
            const c0 = card(pg, 0);
            assert.equal(c0.querySelector(pg.T.detach), null);
            assert.equal(c0.querySelector(SEL), null);
            assert.equal(pg.d.activeElement, c0, 'card focused');
            assert.equal(c0.getAttribute('tabindex'), '-1');
        } finally { pg.close(); }
    });

    test(tag + '(d) card-fallback focus survives a later poll rebuild', async () => {
        const pg = await boot(tree);
        try {
            const pend = await detachScenario(pg, { attached: ['ghost-machine-id'], machines: [] });
            pend.release(true);
            await settled(pg, true);
            const before = card(pg, 0);
            assert.equal(pg.d.activeElement, before, 'precondition: card focused');
            await pg.poll(63);   // new reading => cards rebuilt
            assert.notEqual(card(pg, 0), before, 'precondition: the card really was rebuilt');
            assert.equal(pg.d.activeElement, card(pg, 0), 'focus followed the rebuilt card, not <body>');
            assert.equal(card(pg, 0).getAttribute('tabindex'), '-1');
        } finally { pg.close(); }
    });

    test(tag + '(d) FAILED write with focus on the card: refocused on the picker, error shown, no announcement', async () => {
        const pg = await boot(tree);
        try {
            const pend = await detachScenario(pg);
            pend.release(false);
            await settled(pg, false);
            assert.match(pg.root().querySelector('.accessory-error').textContent, /boom/);
            assert.equal(pg.d.activeElement, card(pg, 0).querySelector(SEL), 'picker focused after the failed write');
            assert.equal(/Detached|Attached/.test((live(pg) || {}).textContent || ''), false, 'failure is not announced as success');
        } finally { pg.close(); }
    });

    test(tag + '(d) FAILED write with focus moved OUTSIDE: not yanked back', async () => {
        const pg = await boot(tree);
        try {
            const pend = await detachScenario(pg);
            const outside = outsideButton(pg); outside.focus();
            pend.release(false);
            await settled(pg, false);
            assert.equal(pg.d.activeElement, outside, 'focus left alone after a failed write');
        } finally { pg.close(); }
    });
}
