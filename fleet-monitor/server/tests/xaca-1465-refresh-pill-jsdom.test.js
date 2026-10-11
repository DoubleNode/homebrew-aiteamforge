//
//  xaca-1465-refresh-pill-jsdom.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1465-013 -- top-bar REFRESH pill (jsdom).
 *
 * Loads the REAL lcars-dashboard.html, the REAL lcars-cicd.js and the REAL
 * lcars-dashboard-app.js. Intervals are replaced by a deterministic fake clock
 * (the app's setInterval resolves from the jsdom window), fetch is a URL-counting stub.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { JSDOM } = require('jsdom');

const PUBLIC = path.join(__dirname, '..', 'public');
const read = (rel) => fs.readFileSync(path.join(PUBLIC, rel), 'utf8');
const HEALTHY = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', 'xaca-1388-ci-runners-healthy.json'), 'utf8'));

const tick = () => new Promise((r) => setImmediate(r));
async function settle(n) { for (let i = 0; i < (n || 8); i++) await tick(); }

async function setup(opts) {
    opts = opts || {};
    const dom = new JSDOM(read('lcars/lcars-dashboard.html'), {
        url: 'http://lcars-test.local/lcars/lcars-dashboard.html',
        runScripts: 'outside-only',
        pretendToBeVisual: true
    });
    const window = dom.window;
    const document = window.document;
    await new Promise((resolve) => {
        if (document.readyState === 'complete') return resolve();
        window.addEventListener('load', () => resolve(), { once: true });
    });

    // ---- fake interval clock ------------------------------------------------
    const clock = { now: 0, seq: 0, timers: new Map() };
    window.setInterval = (fn, ms) => { const id = ++clock.seq; clock.timers.set(id, { fn, ms, next: clock.now + ms }); return id; };
    window.clearInterval = (id) => { clock.timers.delete(id); };
    clock.activeAt = (ms) => Array.from(clock.timers.values()).filter((t) => t.ms === ms).length;
    clock.advance = async (ms) => {
        const end = clock.now + ms;
        for (;;) {
            let due = null;
            for (const t of clock.timers.values()) if (t.next <= end && (!due || t.next < due.next)) due = t;
            if (!due) break;
            clock.now = due.next; due.next += due.ms;
            due.fn();
            await settle(4);
        }
        clock.now = end;
    };

    // ---- fake setTimeout (confirmation timer) -------------------------------
    const timeouts = [];
    window.setTimeout = (fn, ms) => { timeouts.push({ fn, ms, live: true }); return timeouts.length; };
    window.clearTimeout = (id) => { if (timeouts[id - 1]) timeouts[id - 1].live = false; };

    // ---- fetch stub ---------------------------------------------------------
    const calls = [];
    const ctl = { fleetGate: null, fleetReject: false, ciGate: null, ciFail: false, ciBody: () => Object.assign({}, HEALTHY) };
    window.fetch = (url) => {
        const u = String(url);
        calls.push(u);
        const json = (body, ok) => Promise.resolve({ ok: ok !== false, status: ok === false ? 500 : 200, statusText: '', json: () => Promise.resolve(body) });
        if (u.startsWith('/api/fleet') || u.indexOf('/api/fleet') === 0 || /\/api\/fleet$/.test(u)) {
            const go = () => (ctl.fleetReject ? Promise.reject(new Error('boom')) : json({ divisions: {}, machines: [], summary: {} }));
            return ctl.fleetGate ? ctl.fleetGate.then(go) : go();
        }
        if (u.indexOf('/api/ci-runners') !== -1) {
            const go = () => (ctl.ciFail ? json({}, false) : json(ctl.ciBody()));
            return ctl.ciGate ? ctl.ciGate.then(go) : go();
        }
        return json({}, false);
    };

    // minimal LCARS_CORE (the real core is unrelated to what is under test) that RECORDS
    // any call to the animating sections.refresh().
    const ctx = dom.getInternalVMContext();
    window.__animatingRefreshCalls = 0;
    vm.runInContext(`window.LCARS_CORE = { init: function(){}, sections: { active: 'overview',
        refresh: function(){ window.__animatingRefreshCalls++; } } };`, ctx);
    vm.runInContext(read('lcars/js/lcars-cicd.js'), ctx, { filename: 'lcars-cicd.js' });
    vm.runInContext(read('lcars/js/lcars-dashboard-app.js'), ctx, { filename: 'lcars-dashboard-app.js' });
    document.dispatchEvent(new window.Event('DOMContentLoaded'));
    await settle(20);

    if (opts.section) window.LCARS_CORE.sections.active = opts.section;
    const countBy = (pred) => calls.filter(pred).length;
    return {
        window, document, clock, calls, ctl, countBy, timeouts,
        pill: document.getElementById('fleet-refresh-pill'),
        fleetCalls: () => countBy((u) => /\/api\/fleet$/.test(u)),
        ciCalls: () => calls.filter((u) => u.indexOf('/api/ci-runners') !== -1),
        reset: () => { calls.length = 0; }
    };
}

const key = (env, k) => new env.window.KeyboardEvent('keydown', { key: k, bubbles: true, cancelable: true });

// ---- DOM placement ---------------------------------------------------------
test('pill is in .lcars-data-bar BEFORE .mode-bar-spacer; sidebar untouched', async () => {
    const env = await setup();
    const bar = env.document.querySelector('.lcars-data-bar');
    assert.ok(env.pill, '#fleet-refresh-pill exists');
    assert.equal(env.pill.parentElement, bar, 'direct child of the data bar');
    const spacer = bar.querySelector('.mode-bar-spacer');
    assert.ok(env.pill.compareDocumentPosition(spacer) & env.window.Node.DOCUMENT_POSITION_FOLLOWING, 'pill precedes the spacer');
    assert.equal(env.pill.getAttribute('role'), 'button');
    assert.equal(env.pill.getAttribute('tabindex'), '0');
    assert.equal(env.pill.getAttribute('aria-label'), 'Refresh now');
    assert.match(env.pill.textContent, /REFRESH/);
    const sidebar = env.document.querySelector('.lcars-sidebar, .sidebar, [class*="sidebar"]');
    assert.ok(sidebar, 'sidebar located');
    assert.ok(!/REFRESH/i.test(sidebar.textContent), 'no REFRESH text in the sidebar');
    assert.equal(sidebar.querySelector('#fleet-refresh-pill'), null);
});

// ---- activation paths ------------------------------------------------------
for (const how of ['click', 'Enter', 'Space']) {
    test('activation via ' + how + ': exactly one /api/fleet; other section => no ?refresh=1', async () => {
        const env = await setup({ section: 'overview' });
        env.reset();
        if (how === 'click') env.pill.click();
        else {
            const ev = key(env, how === 'Space' ? ' ' : 'Enter');
            env.pill.dispatchEvent(ev);
            assert.equal(ev.defaultPrevented, true, 'default prevented (no page scroll on Space)');
        }
        await settle();
        assert.equal(env.fleetCalls(), 1);
        assert.equal(env.ciCalls().length, 0, 'CI/CD not active => no ci-runners call');
        assert.equal(env.calls.filter((u) => u.indexOf('refresh=1') !== -1).length, 0);
        assert.equal(env.window.__animatingRefreshCalls, 0, 'animating sections.refresh() never called');
    });

    test('activation via ' + how + ' on CI/CD: one /api/fleet + one /api/ci-runners?refresh=1', async () => {
        const env = await setup({ section: 'cicd' });
        env.reset();
        if (how === 'click') env.pill.click();
        else env.pill.dispatchEvent(key(env, how === 'Space' ? ' ' : 'Enter'));
        await settle();
        assert.equal(env.fleetCalls(), 1);
        assert.deepEqual(env.ciCalls(), ['/api/ci-runners?refresh=1']);
    });
}

test('other keys do nothing', async () => {
    const env = await setup();
    env.reset();
    env.pill.dispatchEvent(key(env, 'a'));
    await settle();
    assert.equal(env.fleetCalls(), 0);
});

// ---- in-flight guard + aria -----------------------------------------------
test('double activation while in flight => one request; aria-busy set then cleared', async () => {
    const env = await setup();
    let release;
    env.ctl.fleetGate = new Promise((r) => { release = r; });
    env.reset();
    env.pill.click();
    await settle(2);
    assert.equal(env.pill.getAttribute('aria-busy'), 'true');
    assert.equal(env.pill.getAttribute('aria-disabled'), 'true');
    env.pill.click();
    env.pill.dispatchEvent(key(env, 'Enter'));
    await settle(2);
    assert.equal(env.fleetCalls(), 1, 'no second /api/fleet while in flight');
    release();
    await settle();
    assert.equal(env.pill.hasAttribute('aria-busy'), false);
    assert.equal(env.pill.hasAttribute('aria-disabled'), false);
    env.pill.click();
    await settle();
    assert.equal(env.fleetCalls(), 2, 'usable again after settle');
});

test('rejected fetch still clears aria-busy/aria-disabled', async () => {
    const env = await setup();
    env.ctl.fleetReject = true;
    env.reset();
    env.pill.click();
    await settle();
    assert.equal(env.fleetCalls(), 1);
    assert.equal(env.pill.hasAttribute('aria-busy'), false);
    assert.equal(env.pill.hasAttribute('aria-disabled'), false);
});

// ---- CI/CD scroll / focus / animation ---------------------------------------
test('manual refresh on CI/CD keeps jobs scroll, focus and the section `active` class', async () => {
    const env = await setup({ section: 'cicd' });
    const section = env.document.querySelector('.lcars-section[data-section="cicd"]');
    section.classList.add('active');
    env.pill.click();           // first run renders the table
    await settle();
    const wrap = env.document.querySelector('.cicd-jobs-wrap');
    assert.ok(wrap, 'jobs wrap rendered');
    wrap.scrollTop = 37; wrap.scrollLeft = 11;
    // Unconditional: the jobs wrap is a real focusable region (tabindex=0, data-cicd-focus).
    const focusable = env.document.querySelector('#cicd-content [data-cicd-focus="jobs-wrap"]');
    assert.ok(focusable, 'fixture renders a focusable CI/CD element (test must not be vacuous)');
    focusable.focus();
    assert.equal(env.document.activeElement, focusable, 'precondition: focus took');
    const before = env.document.activeElement;
    let removed = 0;
    const mo = new env.window.MutationObserver((recs) => recs.forEach((r) => {
        if (r.attributeName === 'class' && !section.classList.contains('active')) removed++;
    }));
    mo.observe(section, { attributes: true });
    env.pill.click();
    await settle();
    await settle();
    mo.disconnect();
    assert.equal(env.document.querySelector('.cicd-jobs-wrap').scrollTop, 37);
    assert.equal(env.document.querySelector('.cicd-jobs-wrap').scrollLeft, 11);
    assert.equal(env.document.activeElement.getAttribute('data-cicd-focus'), before.getAttribute('data-cicd-focus'));
    assert.equal(env.document.activeElement.getAttribute('data-cicd-focus'), 'jobs-wrap', 'focus still on the jobs wrap');
    assert.equal(removed, 0, '`active` never removed');
    assert.ok(section.classList.contains('active'));
    assert.equal(env.window.__animatingRefreshCalls, 0);
});

// ---- timers ---------------------------------------------------------------
test('after a manual refresh the next automatic tick is a FULL interval later; one interval only', async () => {
    const env = await setup();
    assert.equal(env.clock.activeAt(60000), 1);
    await env.clock.advance(50000);
    env.reset();
    env.pill.click();
    await settle();
    assert.equal(env.fleetCalls(), 1);
    assert.equal(env.clock.activeAt(60000), 1, 'exactly one 60 s interval after restart');
    env.reset();
    await env.clock.advance(59000);
    assert.equal(env.fleetCalls(), 0, 'old schedule (t=60 s) did not fire');
    await env.clock.advance(1500);
    assert.equal(env.fleetCalls(), 1, 'fires a full interval after the manual run');
});

test('automatic 60 s tick on CI/CD does NOT add ?refresh=1', async () => {
    const env = await setup({ section: 'cicd' });
    env.reset();
    await env.clock.advance(60000);
    assert.equal(env.fleetCalls(), 1);
    assert.deepEqual(env.ciCalls(), ['/api/ci-runners']);
});

// ---- throttled note ---------------------------------------------------------
test('throttled response shows the note, escaped as text', async () => {
    const env = await setup({ section: 'cicd' });
    env.ctl.ciBody = () => Object.assign({}, HEALTHY, { refresh: { ran: false, throttled: true, retryAfterSec: 12 } });
    env.pill.click();
    await settle();
    const note = env.document.querySelector('[data-cicd-slot="refresh-note"]');
    assert.ok(note);
    assert.match(note.textContent, /switch re-read throttled \(retry in 12s\)/);
    // hostile retryAfterSec never becomes markup
    env.ctl.ciBody = () => Object.assign({}, HEALTHY, { refresh: { throttled: true, retryAfterSec: '<img src=x onerror=alert(1)>' } });
    env.pill.click();
    await settle();
    assert.equal(env.document.querySelector('#cicd-content img'), null);
    assert.doesNotMatch(env.document.querySelector('[data-cicd-slot="refresh-note"]').textContent, /<img/);
    // an unforced refresh clears the note
    env.ctl.ciBody = () => Object.assign({}, HEALTHY);
    await env.clock.advance(60000);
    await settle();
    assert.equal(env.document.querySelector('[data-cicd-slot="refresh-note"]').textContent, '');
});

// ---- XACA-1465-014: forced refresh during an in-flight auto refresh ----------
test('REFRESH during an in-flight AUTO refresh chains exactly one ?refresh=1 afterwards, with the note', async () => {
    const env = await setup({ section: 'cicd' });
    await settle();
    let release;
    env.ctl.ciGate = new Promise((r) => { release = r; });
    env.reset();
    await env.clock.advance(60000);          // auto tick -> unforced ci-runners now in flight
    assert.deepEqual(env.ciCalls(), ['/api/ci-runners']);
    env.ctl.ciBody = () => Object.assign({}, HEALTHY, { refresh: { ran: true, throttled: false } });
    env.pill.click();
    await settle();
    // second CI/CD forced request while the chained one is still pending must join it
    env.window.LCARSCICD.refresh({ force: true });
    env.window.LCARSCICD.refresh({ force: true });
    await settle();
    assert.deepEqual(env.ciCalls(), ['/api/ci-runners'], 'nothing forced sent yet');
    env.ctl.ciGate = null;
    release();
    await settle(20);
    assert.deepEqual(env.ciCalls(), ['/api/ci-runners', '/api/ci-runners?refresh=1'], 'exactly one chained forced call');
    assert.match(env.document.querySelector('[data-cicd-slot="refresh-note"]').textContent, /switches re-read/);
});

// ---- XACA-1465-020 ------------------------------------------------------------
test('pill shows REFRESHED then reverts after 1.5 s; aria-label stays stable', async () => {
    const env = await setup();
    env.pill.click();
    await settle();
    assert.equal(env.pill.textContent, 'REFRESHED');
    assert.equal(env.pill.getAttribute('aria-label'), 'Refresh now');
    const t = env.timeouts.filter((x) => x.live && x.ms === 1500);
    assert.equal(t.length, 1);
    t[0].fn();
    assert.equal(env.pill.textContent, 'REFRESH');
});

test('failed refresh shows REFRESH FAILED; a click during confirmation starts a new refresh and cancels it', async () => {
    const env = await setup();
    env.ctl.fleetReject = true;
    env.pill.click();
    await settle();
    assert.equal(env.pill.textContent, 'REFRESH FAILED');
    env.ctl.fleetReject = false;
    env.reset();
    env.pill.click();
    assert.equal(env.pill.textContent, 'REFRESH', 'confirmation cancelled on new click');
    assert.equal(env.timeouts.filter((x) => x.live).length, 0, 'old confirmation timer cleared');
    await settle();
    assert.equal(env.fleetCalls(), 1);
    assert.equal(env.pill.textContent, 'REFRESHED');
});

test('refresh-note is cleared when a later forced fetch fails', async () => {
    const env = await setup({ section: 'cicd' });
    env.ctl.ciBody = () => Object.assign({}, HEALTHY, { refresh: { ran: true } });
    env.pill.click();
    await settle();
    assert.match(env.document.querySelector('[data-cicd-slot="refresh-note"]').textContent, /switches re-read/);
    env.ctl.ciFail = true;
    env.pill.click();
    await settle();
    assert.equal(env.document.querySelector('[data-cicd-slot="refresh-note"]').textContent, '');
});
