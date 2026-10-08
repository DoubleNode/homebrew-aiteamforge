//
//  xaca-1444-ci-pool-ui-jsdom.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1444-002 -- jsdom tests for the CI pool machine cards + controls.
 *
 * Loads the REAL shipped public/shared/js/lcars-ci-pool.js (never a paraphrase)
 * and drives window.LCARSCIPool.render against the wave-1 fixtures
 * tests/fixtures/xaca-1444-ci-pool-{mixed,draining,no-capacity}.json.
 * Asserts on stable data-cicd-pool-* hooks, never presentation classes.
 *
 * Vacuous-green guard: a missing implementation file FAILS (loadImpl throws),
 * it never skips.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const PUBLIC_ROOT = path.join(__dirname, '..', 'public');
const POOL_JS = path.join(PUBLIC_ROOT, 'shared', 'js', 'lcars-ci-pool.js');
const POOL_CSS = path.join(PUBLIC_ROOT, 'shared', 'css', 'lcars-ci-pool.css');
const CICD_JS = path.join(PUBLIC_ROOT, 'lcars', 'js', 'lcars-cicd.js');
const DASHBOARD_HTML = path.join(PUBLIC_ROOT, 'lcars', 'lcars-dashboard.html');
const FIXTURE_DIR = path.join(__dirname, 'fixtures');

function fixture(name, mutate) {
    const d = JSON.parse(fs.readFileSync(path.join(FIXTURE_DIR, 'xaca-1444-ci-pool-' + name + '.json'), 'utf8'));
    if (mutate) mutate(d);
    return d;
}

function loadImpl() {
    if (!fs.existsSync(POOL_JS)) throw new Error('MISSING IMPLEMENTATION: ' + POOL_JS);
    const dom = new JSDOM('<!doctype html><html><body><div id="cicd-pool"></div></body></html>',
        { runScripts: 'outside-only', url: 'http://localhost/' });
    dom.window.eval(fs.readFileSync(POOL_JS, 'utf8'));
    const api = dom.window.LCARSCIPool;
    assert.ok(api && typeof api.render === 'function', 'window.LCARSCIPool.render must be exposed');
    return { dom, window: dom.window, document: dom.window.document, api, el: dom.window.document.getElementById('cicd-pool') };
}

function mkFetch(responses) {
    const calls = [];
    const queue = (responses || []).slice();
    const f = async function(url, init) {
        calls.push({ url, init, body: init && init.body ? JSON.parse(init.body) : null });
        const r = queue.length ? queue.shift() : { status: 200, data: { ok: true } };
        return { ok: r.status >= 200 && r.status < 300, status: r.status, json: async () => r.data };
    };
    f.calls = calls;
    return f;
}

async function settle() { for (let i = 0; i < 6; i++) await new Promise((r) => setTimeout(r, 0)); }
function card(env, id) {
    return Array.from(env.el.querySelectorAll('[data-cicd-pool-machine-card]'))
        .find((c) => c.getAttribute('data-cicd-pool-machine-card') === id) || null;
}
function btn(env, id, action) { return card(env, id).querySelector('[data-cicd-pool-action="' + action + '"]'); }
function dialog(env) { return env.el.querySelector('[role="dialog"]'); }
function setup(body, fetchImpl) {
    const env = loadImpl();
    env.fetch = fetchImpl || mkFetch();
    env.opts = { fetch: env.fetch, document: env.document };
    env.body = body;
    env.api.render(body, env.el, env.opts);
    return env;
}

test('guard: lcars-ci-pool.js exists and exposes render()', () => {
    assert.ok(fs.existsSync(POOL_JS), 'lcars-ci-pool.js must exist (suite must FAIL, not skip)');
    loadImpl();
});

test('all six states render with text badge + glyph, from the mixed fixture', () => {
    const env = setup(fixture('mixed'));
    const expected = { m4mini: 'enabled', m1mini: 'draining', m1pro: 'paused', m3pro: 'resuming', m2mini: 'disabled', m5mini: 'unknown' };
    Object.entries(expected).forEach(([id, state]) => {
        const c = card(env, id);
        assert.ok(c, id + ' card present');
        assert.equal(c.getAttribute('data-cicd-pool-state'), state);
        const badge = c.querySelector('[data-cicd-pool-state]:not(li)') ;
        assert.ok(badge, id + ' badge');
        assert.equal(badge.getAttribute('data-cicd-pool-state'), state);
        assert.ok(badge.textContent.toUpperCase().includes(state.toUpperCase()), 'badge carries the state as TEXT');
        assert.ok(badge.querySelector('[aria-hidden="true"]'), 'glyph is decorative (aria-hidden)');
    });
    assert.equal(env.el.querySelector('ul[data-cicd-pool-list]').children.length, 6);
    assert.equal(env.el.querySelector('section').getAttribute('aria-labelledby'), 'cicd-pool-heading');
    assert.equal(env.el.querySelector('[role="status"]').getAttribute('aria-live'), 'polite');
});

test('the draining and no-capacity fixtures render too', () => {
    const d = setup(fixture('draining'));
    assert.equal(card(d, 'm4mini').getAttribute('data-cicd-pool-state'), 'draining');
    assert.equal(card(d, 'm1mini').getAttribute('data-cicd-pool-state'), 'enabled');
    const n = setup(fixture('no-capacity'));
    assert.equal(card(n, 'm2mini').getAttribute('data-cicd-pool-state'), 'disabled');
});

test('capacity renders as text with units; null/absent renders an em dash, never 0', () => {
    const env = setup(fixture('mixed'));
    const t = card(env, 'm4mini').querySelector('[data-cicd-pool-capacity]').textContent;
    assert.match(t, /Reclaimable memory\s*3\.8\s*GiB/);
    assert.match(t, /Swap used \/ total/);
    assert.match(t, /1 busy \/ 1 idle/);
    assert.match(t, /10 CPUs/);
    const nullCard = card(env, 'm2mini');
    const dashes = nullCard.querySelectorAll('[aria-label="not reported"]');
    assert.ok(dashes.length >= 5, 'every missing capacity field is an aria-labelled dash');
    Array.from(dashes).forEach((d) => assert.equal(d.textContent, '—'));
    const nt = nullCard.querySelector('[data-cicd-pool-capacity]').textContent;
    assert.ok(!/(^|\s)0(\s|$)/.test(nt) && !/0\.0/.test(nt), 'null capacity never shows a zero: ' + nt);
    const partial = fixture('mixed', (d) => { d.machines.m4mini.capacity.swapUsedBytes = null; delete d.machines.m4mini.capacity.load1; });
    const p = setup(partial);
    const pdash = card(p, 'm4mini').querySelectorAll('[aria-label="not reported"]');
    assert.ok(pdash.length >= 2);
});

test('hostile machine names / reasons are inert text', () => {
    const body = fixture('mixed', (d) => {
        const m = d.machines.m4mini;
        d.machines['<img src=x onerror=alert(1)>'] = Object.assign({}, m, {
            paused: true, state: 'paused', pauseReason: '"><script>window.pwned=1</script>', pausedBy: '<b onclick=x()>op</b>',
            stateReason: '<svg onload=x()>'
        });
    });
    const env = setup(body);
    assert.equal(env.el.querySelectorAll('img, script, svg, b').length, 0);
    assert.equal(env.el.querySelectorAll('[onerror],[onclick],[onload]').length, 0);
    assert.ok(env.el.textContent.includes('<img src=x onerror=alert(1)>'));
    assert.equal(env.window.pwned, undefined);
    // Controls still address the hostile id correctly (attribute round-trips).
    const hostile = card(env, '<img src=x onerror=alert(1)>');
    assert.ok(hostile, 'card found by raw id');
});

test('dormant Enable is aria-disabled, focusable, described, and clicking never fetches', async () => {
    const f = mkFetch();
    const body = fixture('mixed', (d) => { d.machines.m2mini.capability = 'dormant'; });
    const env = setup(body, f);
    const b = btn(env, 'm2mini', 'enable');
    assert.equal(b.tagName, 'BUTTON');
    assert.equal(b.getAttribute('aria-disabled'), 'true');
    assert.equal(b.hasAttribute('disabled'), false);
    const why = env.document.getElementById(b.getAttribute('aria-describedby'));
    assert.ok(why && why.textContent.includes('dormant'), 'describedby resolves to visible reason text');
    b.focus();
    assert.equal(env.document.activeElement, b, 'aria-disabled control stays focusable');
    const cmd = card(env, 'm2mini').querySelector('[data-cicd-pool-command]');
    assert.equal(cmd.textContent, 'aiteamforge ci enable');
    assert.ok(card(env, 'm2mini').querySelector('[data-cicd-pool-copy]'));
    b.click();
    await settle();
    assert.equal(f.calls.length, 0, 'click guard blocks the aria-disabled control');
    assert.equal(dialog(env), null);
});

test('non-dormant Enable (unknown capability does not block) and Resume send the right bodies', async () => {
    const f = mkFetch();
    const env = setup(fixture('mixed'), f);
    const en = btn(env, 'm2mini', 'enable');
    assert.equal(en.hasAttribute('aria-disabled'), false, 'unknown capability does not block enrolment');
    en.click();
    await settle();
    assert.equal(f.calls.length, 1);
    assert.equal(f.calls[0].url, '/api/ci-pool/machines/m2mini');
    assert.equal(f.calls[0].init.method, 'PUT');
    assert.deepEqual(f.calls[0].body, { enabled: true });
    btn(env, 'm1mini', 'resume').click();
    await settle();
    assert.deepEqual(f.calls[1].body, { paused: false });
    // resuming: the control exists but is aria-disabled with a reason
    const r = btn(env, 'm3pro', 'resume');
    assert.equal(r.getAttribute('aria-disabled'), 'true');
    r.click();
    await settle();
    assert.equal(f.calls.length, 2);
});

test('Pause: confirm dialog copy, posts exactly once with the right body, announces, emits changed', async () => {
    const f = mkFetch();
    const env = setup(fixture('mixed'), f);
    let changed = 0;
    env.el.addEventListener('cicd-pool:changed', () => { changed++; });
    btn(env, 'm4mini', 'pause').click();
    const d = dialog(env);
    assert.ok(d, 'role=dialog opens');
    assert.equal(d.getAttribute('aria-modal'), 'true');
    assert.ok(d.textContent.includes('Jobs in progress finish; none are cancelled.'));
    assert.equal(f.calls.length, 0, 'opening the dialog sends nothing');
    d.querySelector('[data-cicd-pool-reason-input]').value = 'disk cleanup';
    d.querySelector('[data-cicd-pool-dlg="confirm"]').click();
    d.querySelector('[data-cicd-pool-dlg="confirm"]') && d.querySelector('[data-cicd-pool-dlg="confirm"]').click();
    await settle();
    assert.equal(f.calls.length, 1, 'double click posts once');
    assert.equal(f.calls[0].url, '/api/ci-pool/machines/m4mini');
    assert.deepEqual(f.calls[0].body, { paused: true, reason: 'disk cleanup' });
    assert.equal(dialog(env), null, 'dialog closes on success');
    assert.match(env.el.querySelector('[role="status"]').textContent, /m4mini: pause applied/);
    assert.equal(changed, 1);
});

test('409 wouldStrand requires a second confirmation, then re-PUTs with confirm:true', async () => {
    const f = mkFetch([{ status: 409, data: { wouldStrand: true, machine: 'm1mini', action: 'pause', error: 'last' } }, { status: 200, data: {} }]);
    const env = setup(fixture('draining'), f);
    btn(env, 'm1mini', 'pause').click();
    dialog(env).querySelector('[data-cicd-pool-dlg="confirm"]').click();
    await settle();
    assert.equal(f.calls.length, 1);
    assert.deepEqual(f.calls[0].body, { paused: true });
    const d = dialog(env);
    assert.ok(d, 'dialog stays open for the second confirmation');
    assert.match(d.textContent, /last available machine/);
    assert.match(d.textContent, /billing-blocked/);
    assert.equal(f.calls.length, 1, 'no second PUT until the operator confirms');
    assert.ok(d.contains(env.document.activeElement), 'focus stays inside the dialog');
    d.querySelector('[data-cicd-pool-dlg="strand"]').click();
    await settle();
    assert.equal(f.calls.length, 2);
    assert.deepEqual(f.calls[1].body, { paused: true, confirm: true });
    assert.equal(dialog(env), null);
});

test('declining the second confirmation sends nothing more', async () => {
    const f = mkFetch([{ status: 409, data: { wouldStrand: true } }]);
    const env = setup(fixture('draining'), f);
    btn(env, 'm1mini', 'pause').click();
    dialog(env).querySelector('[data-cicd-pool-dlg="confirm"]').click();
    await settle();
    dialog(env).querySelector('[data-cicd-pool-dlg="cancel"]').click();
    await settle();
    assert.equal(f.calls.length, 1);
    assert.equal(dialog(env), null);
});

test('dialog: focus moves in, Escape closes, focus returns to the invoker', async () => {
    const env = setup(fixture('mixed'));
    const inv = btn(env, 'm4mini', 'pause');
    inv.focus();
    inv.click();
    const d = dialog(env);
    assert.ok(d.contains(env.document.activeElement), 'focus moved into the dialog');
    d.querySelector('[data-cicd-pool-dlg="cancel"]').dispatchEvent(
        new env.window.KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
    assert.equal(dialog(env), null, 'Escape closes');
    assert.equal(env.document.activeElement, btn(env, 'm4mini', 'pause'), 'focus returned to the invoker');
});

test('failures and 401 are announced; nothing throws', async () => {
    const f = mkFetch([{ status: 401, data: { error: 'unauthorized' } }, { status: 500, data: { error: 'boom' } }]);
    const env = setup(fixture('mixed'), f);
    btn(env, 'm2mini', 'enable').click();
    await settle();
    assert.match(env.el.querySelector('[role="status"]').textContent, /admin unlock/);
    btn(env, 'm2mini', 'enable').click();
    await settle();
    assert.match(env.el.querySelector('[role="status"]').textContent, /failed \(HTTP 500\)/);
    const rej = setup(fixture('mixed'), async () => { throw new Error('net down'); });
    btn(rej, 'm2mini', 'enable').click();
    await settle();
    assert.match(rej.el.querySelector('[role="status"]').textContent, /net down/);
});

test('repeated render is idempotent: same nodes, no duplicates, focus and dialog preserved', () => {
    const env = setup(fixture('mixed'));
    const before = card(env, 'm4mini');
    env.api.render(fixture('mixed'), env.el, env.opts);
    assert.equal(card(env, 'm4mini'), before, 'unchanged card node is untouched');
    assert.equal(env.el.querySelectorAll('[data-cicd-pool-machine-card]').length, 6);
    assert.equal(env.el.querySelectorAll('[data-cicd-pool-root]').length, 1);
    const b = btn(env, 'm4mini', 'pause');
    b.focus();
    const changed = fixture('mixed', (d) => { d.machines.m4mini.capacity.load1 = 3.3; });
    env.api.render(changed, env.el, env.opts);
    const active = env.document.activeElement;
    assert.equal(active.getAttribute('data-cicd-pool-action'), 'pause');
    assert.equal(active.getAttribute('data-cicd-pool-machine'), 'm4mini', 'focus survives a card re-render');
    assert.match(card(env, 'm4mini').textContent, /3\.3/);
    btn(env, 'm4mini', 'pause').click();
    env.api.render(changed, env.el, env.opts);
    assert.ok(dialog(env), 'an open dialog survives a refresh');
    // machine removed => card removed
    env.api.render(fixture('draining'), env.el, env.opts);
    assert.equal(env.el.querySelectorAll('[data-cicd-pool-machine-card]').length, 2);
});

test('null / missing / malformed poolBody renders nothing and hides the container', () => {
    const env = setup(fixture('mixed'));
    [null, undefined, {}, { machines: 'x' }].forEach((b) => {
        env.api.render(b, env.el, env.opts);
        assert.equal(env.el.innerHTML, '');
        assert.equal(env.el.hidden, true);
        env.api.render(fixture('mixed'), env.el, env.opts);
        assert.equal(env.el.hidden, false);
    });
});

test('css: tokens only, no raw hex, no looping animation, reduced-motion respected, focus-visible', () => {
    assert.ok(fs.existsSync(POOL_CSS), 'lcars-ci-pool.css must exist');
    const css = fs.readFileSync(POOL_CSS, 'utf8').replace(/\/\*[\s\S]*?\*\//g, '');
    assert.ok(!/#[0-9a-fA-F]{3,8}\b/.test(css), 'no raw hex');
    assert.ok(!/@keyframes|infinite/.test(css), 'no looping animation');
    assert.match(css, /prefers-reduced-motion/);
    assert.match(css, /:focus-visible/);
});

test('wiring: dashboard has both containers in order plus asset tags; cicd.js polls /api/ci-pool', () => {
    const html = fs.readFileSync(DASHBOARD_HTML, 'utf8');
    const iPool = html.indexOf('id="cicd-pool"'), iQueue = html.indexOf('id="cicd-queue"'), iContent = html.indexOf('id="cicd-content"');
    assert.ok(iPool > 0 && iQueue > iPool && iContent > iQueue, 'pool, queue, then runners content');
    ['shared/css/lcars-ci-pool.css', 'shared/css/lcars-ci-queue.css', 'shared/js/lcars-ci-pool.js', 'shared/js/lcars-ci-queue.js']
        .forEach((a) => assert.match(html, new RegExp(a.replace(/[./]/g, '\\$&') + '\\?v=\\d{8}[a-z]'), a));
    assert.match(fs.readFileSync(CICD_JS, 'utf8'), /\/api\/ci-pool/);
});

test('cicd.js refresh() feeds both modules, hides on 404, and refreshes after a write', async () => {
    const dom = new JSDOM('<!doctype html><html><body><div class="lcars-section active" data-section="cicd">' +
        '<div id="cicd-pool"></div><div id="cicd-queue"></div><div id="cicd-content"></div></div></body></html>',
    { runScripts: 'outside-only', url: 'http://localhost/' });
    const w = dom.window;
    const seen = { pool: 0, queue: 0 };
    w.LCARSCIPool = { render(b, el) { seen.pool++; el.hidden = false; el.textContent = 'pool'; } };
    w.LCARSCIQueue = { render(b, el) { seen.queue++; el.hidden = false; el.textContent = 'queue'; } };
    const urls = [];
    let poolStatus = 200;
    w.fetch = async (u) => {
        urls.push(u);
        if (u === '/api/ci-pool') return { ok: poolStatus === 200, status: poolStatus, json: async () => fixture('mixed') };
        return { ok: false, status: 404, json: async () => ({}) };
    };
    w.eval(fs.readFileSync(CICD_JS, 'utf8'));
    await settle();
    assert.ok(urls.includes('/api/ci-pool'));
    assert.deepEqual(seen, { pool: 1, queue: 1 });
    poolStatus = 404;
    await w.LCARSCICD.refresh();
    assert.equal(w.document.getElementById('cicd-pool').hidden, true);
    assert.equal(w.document.getElementById('cicd-pool').innerHTML, '');
    assert.equal(w.document.getElementById('cicd-queue').hidden, true);
    const n = urls.length;
    w.document.getElementById('cicd-pool').dispatchEvent(new w.CustomEvent('cicd-pool:changed', { bubbles: true }));
    await settle();
    assert.ok(urls.length > n, 'a successful write triggers an immediate refresh');
});

// XACA-1444-005 checklist gap: "an old payload (pre-XACA-1444, no state/capability/noCapacity/queueAge) renders as before".
test('legacy v1 body (no derived fields) renders every machine without throwing; a missing state is never shown as healthy', () => {
    const legacy = fixture('mixed', (d) => {
        for (const k of ['noCapacity', 'queueAge', 'queueAgeThresholdSec']) delete d[k];
        for (const m of Object.values(d.machines)) { delete m.state; delete m.stateReason; delete m.capability; }
    });
    const env = setup(legacy);
    const cards = env.el.querySelectorAll('[data-cicd-pool-machine-card]');
    assert.equal(cards.length, Object.keys(legacy.machines).length, 'one card per machine');
    Array.from(cards).forEach((c) => {
        assert.notEqual(c.getAttribute('data-cicd-pool-state'), 'enabled', 'a missing state is not rendered as healthy');
    });
});
