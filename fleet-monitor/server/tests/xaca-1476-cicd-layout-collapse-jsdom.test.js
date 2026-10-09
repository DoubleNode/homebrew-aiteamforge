//
//  xaca-1476-cicd-layout-collapse-jsdom.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1476-006 -- jsdom tests for the CI/CD screen reorder (#cicd-summary mount)
 * and the collapsible CI pool machine cards.
 *
 * Loads the REAL shipped lcars-cicd.js, lcars-ci-pool.js and lcars-ci-queue.js, and the
 * REAL CI/CD section markup sliced out of lcars-dashboard.html. Asserts on stable
 * data-cicd-* hooks and aria attributes, never presentation classes.
 *
 * Vacuous-green guard: any missing implementation file FAILS (loadJs throws).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const PUBLIC_ROOT = path.join(__dirname, '..', 'public');
const POOL_JS = path.join(PUBLIC_ROOT, 'shared', 'js', 'lcars-ci-pool.js');
const QUEUE_JS = path.join(PUBLIC_ROOT, 'shared', 'js', 'lcars-ci-queue.js');
const CICD_JS = path.join(PUBLIC_ROOT, 'lcars', 'js', 'lcars-cicd.js');
const DASHBOARD_HTML = path.join(PUBLIC_ROOT, 'lcars', 'lcars-dashboard.html');
const FIXTURE_DIR = path.join(__dirname, 'fixtures');

const CLOSED = '▸', OPEN = '▾';

function loadJs(p) {
    if (!fs.existsSync(p)) throw new Error('MISSING IMPLEMENTATION: ' + p);
    return fs.readFileSync(p, 'utf8');
}
function poolFixture(name, mutate) {
    const d = JSON.parse(fs.readFileSync(path.join(FIXTURE_DIR, 'xaca-1444-ci-pool-' + name + '.json'), 'utf8'));
    if (mutate) mutate(d);
    return d;
}
function runnersFixture(name) {
    return JSON.parse(fs.readFileSync(path.join(FIXTURE_DIR, 'xaca-1388-ci-runners-' + name + '.json'), 'utf8'));
}

// The real CI/CD section markup from the dashboard (summary, pool, queue, content mounts).
function dashboardSectionHtml() {
    const html = fs.readFileSync(DASHBOARD_HTML, 'utf8');
    const m = /<div class="lcars-section" data-section="cicd">[\s\S]*?<!-- End CI\/CD section -->/.exec(html);
    assert.ok(m, 'CI/CD section markup found in lcars-dashboard.html');
    return m[0];
}

// ---- pool-only window (card behaviour) -------------------------------------
function setupPool(body) {
    const dom = new JSDOM('<!doctype html><html><body><div id="cicd-pool"></div></body></html>',
        { runScripts: 'outside-only', url: 'http://localhost/' });
    dom.window.eval(loadJs(POOL_JS));
    const env = { window: dom.window, document: dom.window.document, api: dom.window.LCARSCIPool,
        el: dom.window.document.getElementById('cicd-pool') };
    env.opts = { document: env.document, fetch: async () => ({ ok: true, status: 200, json: async () => ({}) }) };
    env.render = (b) => env.api.render(b, env.el, env.opts);
    env.render(body || poolFixture('mixed'));
    return env;
}
const card = (env, id) => Array.from(env.el.querySelectorAll('[data-cicd-pool-machine-card]'))
    .find((c) => c.getAttribute('data-cicd-pool-machine-card') === id) || null;
const toggle = (env, id) => card(env, id).querySelector('[data-cicd-pool-toggle]');
const details = (env, id) => card(env, id).querySelector('[data-cicd-pool-details]');
const glyph = (env, id) => toggle(env, id).querySelector('[data-cicd-pool-chev]').textContent;
function press(env, el, keyName, extra) {
    const ev = new env.window.KeyboardEvent('keydown', Object.assign({ key: keyName, bubbles: true, cancelable: true }, extra || {}));
    el.dispatchEvent(ev);
    return ev;
}
function expanded(env, id) { return toggle(env, id).getAttribute('aria-expanded'); }

// ---- full dashboard window (order + failure states) ------------------------
function setupDashboard(fetchImpl) {
    const dom = new JSDOM('<!doctype html><html><body>' + dashboardSectionHtml() + '</body></html>',
        { runScripts: 'outside-only', url: 'http://localhost/' });
    const w = dom.window;
    w.fetch = async (u, i) => fetchImpl(u, i);
    w.eval(loadJs(POOL_JS));
    w.eval(loadJs(QUEUE_JS));
    w.eval(loadJs(CICD_JS));
    const d = w.document;
    return { window: w, document: d, api: w.LCARSCICD,
        summary: d.getElementById('cicd-summary'), pool: d.getElementById('cicd-pool'),
        queue: d.getElementById('cicd-queue'), content: d.getElementById('cicd-content') };
}
const okJson = (data) => ({ ok: true, status: 200, json: async () => data });
const status = (s) => ({ ok: false, status: s, json: async () => ({}) });

// =============================================================================

test('guard: all implementation files exist and the dashboard section parses', () => {
    [POOL_JS, QUEUE_JS, CICD_JS, DASHBOARD_HTML].forEach((p) => assert.ok(fs.existsSync(p), p));
    assert.ok(dashboardSectionHtml().includes('id="cicd-summary"'));
});

test('DOM order: summary, pool, queue, runner states, recent jobs (rendered nodes, compareDocumentPosition)', async () => {
    const env = setupDashboard(async (u) => {
        if (u === '/api/ci-pool') return okJson(poolFixture('mixed'));
        if (u === '/api/ci-runners') return okJson(runnersFixture('healthy'));
        return status(404);
    });
    await env.api.refresh();
    const nodes = {
        summary: env.summary.querySelector('[data-cicd-summary]'),
        pool: env.pool.querySelector('[data-cicd-pool-root]'),
        queue: env.queue.firstElementChild,
        states: env.content.querySelector('[data-cicd-machine]'),
        jobs: env.content.querySelector('[data-cicd-job]')
    };
    Object.entries(nodes).forEach(([k, n]) => assert.ok(n, k + ' block rendered'));
    const FOLLOWING = env.window.Node.DOCUMENT_POSITION_FOLLOWING;
    const order = ['summary', 'pool', 'queue', 'states', 'jobs'];
    for (let i = 0; i < order.length - 1; i++) {
        const a = nodes[order[i]], b = nodes[order[i + 1]];
        assert.ok(a.compareDocumentPosition(b) & FOLLOWING, order[i] + ' must precede ' + order[i + 1]);
    }
    assert.ok(env.summary.contains(nodes.summary) && !env.content.contains(nodes.summary), 'summary lives only in #cicd-summary');
});

test('pool cards are collapsed by default: aria-expanded=false, details hidden, right glyph, aria-controls resolves', () => {
    const env = setupPool();
    const cards = env.el.querySelectorAll('[data-cicd-pool-machine-card]');
    assert.equal(cards.length, 6);
    cards.forEach((c) => {
        const id = c.getAttribute('data-cicd-pool-machine-card');
        const t = toggle(env, id), d = details(env, id);
        assert.equal(t.getAttribute('aria-expanded'), 'false', id);
        assert.equal(t.tagName, 'BUTTON', 'native button (Enter/Space for free)');
        assert.equal(t.getAttribute('type'), 'button');
        assert.equal(t.hasAttribute('role'), false, 'no ARIA role needed on a native button');
        assert.ok(d.hasAttribute('hidden'), id + ' details hidden');
        assert.equal(env.document.getElementById(t.getAttribute('aria-controls')), d, id + ' aria-controls -> details');
        assert.equal(glyph(env, id), CLOSED);
        assert.equal(env.api.isExpanded(id), false);
    });
});

test('toggle: click expands and collapses; aria-expanded, glyph, hidden and isExpanded all follow', () => {
    const env = setupPool();
    toggle(env, 'm4mini').click();
    assert.equal(expanded(env, 'm4mini'), 'true');
    assert.equal(glyph(env, 'm4mini'), OPEN);
    assert.equal(details(env, 'm4mini').hasAttribute('hidden'), false);
    assert.equal(env.api.isExpanded('m4mini'), true);
    assert.equal(expanded(env, 'm1mini'), 'false', 'other cards unaffected');
    toggle(env, 'm4mini').click();
    assert.equal(expanded(env, 'm4mini'), 'false');
    assert.equal(glyph(env, 'm4mini'), CLOSED);
    assert.ok(details(env, 'm4mini').hasAttribute('hidden'));
    assert.equal(env.api.isExpanded('m4mini'), false);
});

test('toggle: a click on the badge inside the header toggles (delegated closest())', () => {
    const env = setupPool();
    toggle(env, 'm4mini').querySelector('.cicd-pool-badge').click();
    assert.equal(expanded(env, 'm4mini'), 'true');
});

test('toggle: a native <button type=button> inside the h4.cicd-pool-name (APG disclosure); .click() toggles it', () => {
    const env = setupPool();
    ['m4mini', 'm1mini'].forEach((id) => {
        const t = toggle(env, id);
        assert.equal(t.tagName, 'BUTTON');
        assert.equal(t.getAttribute('type'), 'button');
        const h = t.closest('h4.cicd-pool-name');
        assert.ok(h, id + ' toggle sits inside the h4');
        assert.equal(h.parentElement.classList.contains('cicd-pool-header'), true);
        assert.match(h.textContent, new RegExp(id), 'heading text contains the machine name');
    });
    toggle(env, 'm4mini').click();
    assert.equal(expanded(env, 'm4mini'), 'true');
    toggle(env, 'm4mini').click();
    assert.equal(expanded(env, 'm4mini'), 'false');
    assert.equal(glyph(env, 'm4mini'), CLOSED);
});

test('machine names stay in the heading outline and name their card (li aria-labelledby -> h4 with the name)', () => {
    const env = setupPool();
    const heads = Array.from(env.el.querySelectorAll('h4')).map((h) => h.textContent);
    ['m4mini', 'm1mini'].forEach((id) => {
        assert.ok(heads.some((t) => t.indexOf(id) >= 0), id + ' is in a heading-role element');
        const li = card(env, id);
        const target = env.document.getElementById(li.getAttribute('aria-labelledby'));
        assert.ok(target, id + ' aria-labelledby resolves');
        assert.equal(target.tagName, 'H4');
        assert.ok(target.textContent.indexOf(id) >= 0, 'accessible name contains the machine name');
    });
});

test('toggle: the h4 holds only the button; Enter/Space handling is native (no custom keydown branch prevents it)', () => {
    const env = setupPool();
    const ev = press(env, toggle(env, 'm4mini'), 'Enter');
    assert.equal(ev.defaultPrevented, false, 'the page leaves Enter/Space to the native button');
    assert.equal(expanded(env, 'm4mini'), 'false', 'keydown alone does not toggle; the browser synthesizes the click');
});

test('toggle: Enter on a control INSIDE the details does not toggle the card or get prevented', () => {
    const env = setupPool();
    toggle(env, 'm4mini').click();
    const pause = card(env, 'm4mini').querySelector('[data-cicd-pool-action="pause"]');
    const ev = press(env, pause, 'Enter');
    assert.equal(expanded(env, 'm4mini'), 'true', 'still expanded');
    assert.equal(ev.defaultPrevented, false, 'button keeps its native key behaviour');
});

test('survives a re-render that CHANGES the card signature (state/capacity change)', () => {
    const env = setupPool();
    toggle(env, 'm4mini').click();
    const before = card(env, 'm4mini');
    env.render(poolFixture('mixed', (d) => { d.machines.m4mini.capacity.load1 = 7.77; }));
    assert.equal(card(env, 'm4mini'), before, 'same <li>; its contents were rewritten');
    assert.equal(expanded(env, 'm4mini'), 'true', 'still expanded after capacity change');
    assert.equal(details(env, 'm4mini').hasAttribute('hidden'), false);
    assert.equal(glyph(env, 'm4mini'), OPEN);
    assert.match(details(env, 'm4mini').textContent, /7\.77/, 'the new capacity actually rendered (rewrite happened)');
    env.render(poolFixture('mixed', (d) => { d.machines.m4mini.state = 'paused'; d.machines.m4mini.paused = true; }));
    assert.equal(card(env, 'm4mini').getAttribute('data-cicd-pool-state'), 'paused');
    assert.equal(expanded(env, 'm4mini'), 'true', 'still expanded after state change');
    assert.equal(env.api.isExpanded('m4mini'), true);
    assert.equal(expanded(env, 'm1mini'), 'false', 'collapsed siblings stay collapsed');
});

test('survives an UNCHANGED poll (same nodes, still expanded; collapsed stays collapsed)', () => {
    const env = setupPool();
    toggle(env, 'm4mini').click();
    const t = toggle(env, 'm4mini');
    env.render(poolFixture('mixed'));
    env.render(poolFixture('mixed', (d) => { d.serverTime = new Date(Date.parse(d.serverTime) + 5000).toISOString(); }));
    assert.equal(toggle(env, 'm4mini'), t, 'no rebuild on an age-only change');
    assert.equal(expanded(env, 'm4mini'), 'true');
    assert.equal(details(env, 'm4mini').hasAttribute('hidden'), false);
    assert.equal(expanded(env, 'm1mini'), 'false');
});

test('collapse survives a signature change too (a collapsed card is not re-opened by a rewrite)', () => {
    const env = setupPool();
    toggle(env, 'm4mini').click();
    toggle(env, 'm4mini').click();
    env.render(poolFixture('mixed', (d) => { d.machines.m4mini.capacity.load1 = 9.1; }));
    assert.equal(expanded(env, 'm4mini'), 'false');
    assert.ok(details(env, 'm4mini').hasAttribute('hidden'));
});

test('remove and reappear: the machine returns collapsed, with no crash and no stale state', () => {
    const env = setupPool();
    toggle(env, 'm4mini').click();
    toggle(env, 'm1mini').click();
    env.render(poolFixture('mixed', (d) => { delete d.machines.m4mini; }));
    assert.equal(card(env, 'm4mini'), null, 'card removed');
    assert.equal(env.api.isExpanded('m4mini'), false, 'expand state pruned on removal');
    assert.equal(env.api.isExpanded('m1mini'), true, 'remaining machine keeps its state');
    assert.doesNotThrow(() => env.render(poolFixture('mixed')));
    assert.ok(card(env, 'm4mini'), 'card reappears');
    assert.equal(expanded(env, 'm4mini'), 'false', 'reappears collapsed');
    assert.ok(details(env, 'm4mini').hasAttribute('hidden'));
    assert.equal(glyph(env, 'm4mini'), CLOSED);
    assert.equal(expanded(env, 'm1mini'), 'true');
});

test('focus restore: a control inside an expanded card keeps focus across a signature-changing re-render', () => {
    const env = setupPool();
    toggle(env, 'm4mini').click();
    const pause = card(env, 'm4mini').querySelector('[data-cicd-pool-action="pause"]');
    pause.focus();
    assert.equal(env.document.activeElement, pause);
    env.render(poolFixture('mixed', (d) => { d.machines.m4mini.capacity.load1 = 4.44; }));
    const now = env.document.activeElement;
    assert.equal(pause.isConnected, false, 'the control was rebuilt (precondition)');
    assert.notEqual(now, pause);
    assert.equal(now.getAttribute('data-cicd-pool-action'), 'pause');
    assert.equal(now.getAttribute('data-cicd-pool-machine'), 'm4mini');
    assert.equal(expanded(env, 'm4mini'), 'true');
});

test('focus restore: focus on the toggle itself survives a signature-changing re-render', () => {
    const env = setupPool();
    const t = toggle(env, 'm4mini');
    t.focus();
    assert.equal(env.document.activeElement, t);
    env.render(poolFixture('mixed', (d) => { d.machines.m4mini.capacity.load1 = 5.55; }));
    assert.equal(t.isConnected, false, 'the header was rebuilt (precondition)');
    const now = env.document.activeElement;
    assert.equal(now, toggle(env, 'm4mini'), 'focus is on the NEW toggle');
    assert.equal(now.getAttribute('data-cicd-pool-toggle'), 'm4mini');
});

test('focus restore: expanded + focused toggle survives a signature change and still toggles', () => {
    const env = setupPool();
    toggle(env, 'm4mini').click();
    toggle(env, 'm4mini').focus();
    env.render(poolFixture('mixed', (d) => { d.machines.m4mini.capacity.load5 = 6.66; }));
    assert.equal(env.document.activeElement, toggle(env, 'm4mini'));
    env.document.activeElement.click();   // native button: Enter/Space become a click in a real browser
    assert.equal(expanded(env, 'm4mini'), 'false');
});

test('inert while the Pause dialog is open: the toggle click does nothing, then works after close', () => {
    const env = setupPool();
    toggle(env, 'm4mini').click();   // expand so Pause is reachable
    card(env, 'm4mini').querySelector('[data-cicd-pool-action="pause"]').click();
    assert.ok(env.el.querySelector('[role="dialog"]'), 'dialog opened');
    toggle(env, 'm1mini').click();
    toggle(env, 'm4mini').click();
    assert.equal(expanded(env, 'm1mini'), 'false', 'collapsed card did not open');
    assert.equal(expanded(env, 'm4mini'), 'true', 'expanded card did not collapse');
    assert.equal(env.api.isExpanded('m1mini'), false);
    env.el.querySelector('[data-cicd-pool-dlg="cancel"]').click();
    assert.equal(env.el.querySelector('[role="dialog"]'), null, 'dialog closed');
    toggle(env, 'm1mini').click();
    assert.equal(expanded(env, 'm1mini'), 'true', 'toggle works again once the dialog is closed');
});

// ---- failure states of the summary mount -----------------------------------

test('failure after good data: summary slot is marked data-cicd-stale="true" and UPDATE FAILED shows', async () => {
    let mode = 'ok';
    const env = setupDashboard(async (u) => {
        if (u !== '/api/ci-runners') return status(404);
        return mode === 'ok' ? okJson(runnersFixture('healthy')) : status(500);
    });
    await env.api.refresh();
    const slot = () => env.summary.querySelector('[data-cicd-slot="summary"]');
    assert.equal(slot().hasAttribute('data-cicd-stale'), false, 'fresh data is not stale');
    mode = 'fail';
    await env.api.refresh();
    assert.equal(slot().getAttribute('data-cicd-stale'), 'true');
    assert.ok(env.summary.querySelector('[data-cicd-update-failed]'), 'UPDATE FAILED badge in the summary mount');
    assert.match(env.summary.textContent, /UPDATE FAILED/);
    assert.match(slot().textContent.replace(/,/g, ''), /208/, 'last good numbers kept');
    assert.ok(env.content.querySelector('[data-cicd-machine]'), 'last good runner states kept');
    mode = 'ok';
    await env.api.refresh();
    assert.equal(slot().hasAttribute('data-cicd-stale'), false, 'recovery clears the stale flag');
    assert.equal(env.summary.querySelector('[data-cicd-update-failed]'), null);
});

test('never-loaded failure: summary shows dashes, not numbers, plus UPDATE FAILED', async () => {
    const env = setupDashboard(async () => status(500));
    await env.api.refresh();
    const tiles = env.summary.querySelectorAll('[data-cicd-summary]');
    assert.ok(tiles.length >= 2, 'summary tiles rendered');
    tiles.forEach((t) => {
        assert.ok(t.textContent.includes('—'), 'dash in ' + t.getAttribute('data-cicd-summary'));
        assert.ok(!/\d/.test(t.textContent), 'no digits in ' + t.getAttribute('data-cicd-summary') + ': ' + t.textContent);
    });
    assert.match(env.summary.textContent, /UPDATE FAILED/);
    assert.equal(env.summary.querySelector('[data-cicd-slot="summary"]').hasAttribute('data-cicd-stale'), false);
    assert.ok(env.content.querySelector('.empty-state'), 'content shows the unavailable empty state');
});

test('404 clears #cicd-summary entirely and shows the not-available state in content', async () => {
    let mode = 'ok';
    const env = setupDashboard(async (u) => {
        if (u !== '/api/ci-runners') return status(404);
        return mode === 'ok' ? okJson(runnersFixture('healthy')) : status(404);
    });
    await env.api.refresh();
    assert.ok(env.summary.children.length > 0, 'precondition: summary populated');
    mode = 'gone';
    await env.api.refresh();
    assert.equal(env.summary.innerHTML, '', '#cicd-summary cleared');
    assert.ok(env.content.querySelector('[data-cicd-unavailable]'));
});

test('022: machine ids equal to Object.prototype names are removed when gone and come back collapsed', () => {
    const mk = (ids) => poolFixture('mixed', (d) => {
        const base = d.machines.m4mini;
        d.machines = { m4mini: base };
        ids.forEach((i) => { d.machines[i] = JSON.parse(JSON.stringify(base)); });
    });
    const env = setupPool(mk(['toString', 'constructor']));
    ['toString', 'constructor'].forEach((id) => {
        assert.ok(card(env, id), id + ' rendered');
        toggle(env, id).click();
        assert.equal(expanded(env, id), 'true');
    });
    env.render(mk([]));
    ['toString', 'constructor'].forEach((id) => {
        assert.equal(card(env, id), null, id + ' removed from the DOM');
        assert.equal(env.api.isExpanded(id), false, id + ' expand state pruned');
    });
    env.render(mk(['toString', 'constructor']));
    ['toString', 'constructor'].forEach((id) => {
        assert.equal(expanded(env, id), 'false', id + ' returns collapsed');
    });
});
