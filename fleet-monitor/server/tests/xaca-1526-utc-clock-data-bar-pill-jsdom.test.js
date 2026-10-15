//
//  xaca-1526-utc-clock-data-bar-pill-jsdom.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1526-005 -- placement, non-interactivity, CSS and coupling tests for the UTC clock after it
 * moved from the LCARS header into the data bar (a pill immediately right of SOUND).
 *
 * Companion to xaca-1495-utc-header-clock-jsdom.test.js, which keeps the behavioural guarantees
 * (TZ independence, format parity, datetime, visually-hidden prefix, no aria-live, single interval)
 * and is unchanged: none of its tests assumed a header position.
 *
 * Markup/CSS/JS are the REAL shipped files, read as text; jsdom only parses the real HTML.
 * Every source-text extraction carries a non-vacuity guard.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const LCARS = path.join(__dirname, '..', 'public', 'lcars');
const read = (p) => {
    if (!fs.existsSync(p)) throw new Error('MISSING: ' + p);
    return fs.readFileSync(p, 'utf8');
};
const HTML = read(path.join(LCARS, 'lcars-dashboard.html'));
const CSS = read(path.join(LCARS, 'css', 'lcars-fleet.css'));
const APP = read(path.join(LCARS, 'js', 'lcars-dashboard-app.js'));
const SOUND = read(path.join(LCARS, 'js', 'lcars-sound.js'));
const CORE = read(path.join(LCARS, 'js', 'lcars-fleet-core.js'));

const doc = () => new JSDOM(HTML, { runScripts: undefined, url: 'http://localhost/lcars/lcars-dashboard.html' }).window.document;
const strip = (css) => css.replace(/\/\*[\s\S]*?\*\//g, '');
const CSS_CODE = strip(CSS);

// ---- Placement ------------------------------------------------------------------------------------------

test('placement: clock is inside .lcars-data-bar .utility-cluster, right after #sound-toggle, and last', () => {
    const d = doc();
    const clock = d.getElementById('utc-clock');
    assert.ok(clock, '#utc-clock exists');
    const cluster = d.querySelector('.lcars-data-bar .utility-cluster');
    assert.ok(cluster, 'cluster exists');
    assert.ok(cluster.contains(clock), 'clock inside the cluster');
    assert.equal(clock.parentElement, cluster, 'direct child of the cluster');
    const sound = d.getElementById('sound-toggle');
    assert.ok(sound, '#sound-toggle exists');
    assert.equal(sound.nextElementSibling, clock, 'immediately right of SOUND');
    assert.equal(cluster.lastElementChild, clock, 'last element child of the cluster');
    assert.equal(clock.tagName, 'TIME');
    assert.ok(clock.classList.contains('utc-pill'));
});

test('placement: header holds no clock; exactly one #utc-clock in the document', () => {
    const d = doc();
    const headers = d.querySelectorAll('.top-sidebar-content, .top-sidebar');
    assert.ok(headers.length >= 2, 'header containers found (non-vacuous)');
    headers.forEach((h) => {
        assert.equal(h.querySelector('#utc-clock'), null, 'no #utc-clock in ' + h.className);
        assert.equal(h.querySelector('.utc-clock'), null, 'no .utc-clock in ' + h.className);
    });
    assert.equal(d.querySelectorAll('#utc-clock').length, 1);
    assert.equal(d.querySelectorAll('.utc-clock').length, 0, 'old header class is gone from the page');
    assert.equal(d.querySelectorAll('#utc-clock-value').length, 1);
});

// ---- Non-interactive ------------------------------------------------------------------------------------

function classifierSelectors() {
    const sels = [];
    const re = /closest\(\s*'([^']+)'\s*\)/g;
    let m;
    while ((m = re.exec(SOUND))) sels.push(m[1]);
    return [...new Set(sels)];
}

test('non-interactive: no role, tabindex, data-section or handlers; not a .legend-pill', () => {
    const el = doc().getElementById('utc-clock');
    ['role', 'tabindex', 'data-section', 'onclick', 'onkeydown', 'onkeyup', 'onmousedown', 'onpointerdown', 'aria-live', 'aria-pressed'].forEach((a) => {
        assert.equal(el.hasAttribute(a), false, 'must not carry ' + a);
    });
    assert.equal(el.matches('.legend-pill'), false);
    assert.equal(el.classList.contains('legend-pill'), false);
    assert.equal(el.closest('.legend-pill'), null);
    assert.equal(el.querySelector('[role],[tabindex],[data-section],[onclick]'), null, 'no interactive descendants');
});

test('non-interactive: not matched by the fleet-core NAV_SELECTOR', () => {
    const m = CORE.match(/var NAV_SELECTOR = '([^']+)'/);
    assert.ok(m, 'NAV_SELECTOR extracted from lcars-fleet-core.js');
    const el = doc().getElementById('utc-clock');
    assert.equal(el.matches(m[1]), false);
    assert.equal(el.closest(m[1]), null);
});

test('non-interactive: no closest() selector of the lcars-sound.js click classifier matches the clock or its children', () => {
    const sels = classifierSelectors();
    assert.ok(sels.length >= 10, 'extracted ' + sels.length + ' closest() selectors (guard against vacuous pass)');
    assert.ok(sels.includes('.legend-pill') && sels.includes('#sound-toggle'), 'extraction sees known selectors');
    const d = doc();
    const targets = [d.getElementById('utc-clock'), d.getElementById('utc-clock-value'), d.querySelector('#utc-clock .visually-hidden')];
    targets.forEach((t) => assert.ok(t, 'target present'));
    // Positive control: the same probe DOES match the SOUND pill, so the loop can fail.
    assert.ok(sels.some((s) => d.getElementById('sound-toggle').closest(s)), 'control: SOUND is classified');
    targets.forEach((t) => sels.forEach((s) => {
        assert.equal(t.closest(s), null, '<' + t.tagName + ' id=' + t.id + '> must not match closest(' + s + ')');
    }));
});

test('non-interactive: not focusable (jsdom: tabIndex === -1 for <time> without tabindex)', () => {
    // LIMITATION: jsdom does not run browser focus heuristics or hit-testing. This pins the markup
    // facts that make it unfocusable (no tabindex, not a natively focusable tag), not real tab order.
    const el = doc().getElementById('utc-clock');
    assert.equal(el.tabIndex, -1);
    assert.equal(el.querySelectorAll('a,button,input,select,textarea,[tabindex]').length, 0);
});

// ---- CSS text -------------------------------------------------------------------------------------------

function ruleBody(selectorText) {
    const idx = CSS_CODE.indexOf(selectorText + ' {');
    assert.ok(idx >= 0, 'rule present: ' + selectorText);
    const end = CSS_CODE.indexOf('}', idx);
    return CSS_CODE.slice(idx, end);
}

test('css: .lcars-data-bar .utc-pill rule exists with cursor: default and no-wrap tabular numerals', () => {
    const body = ruleBody('.lcars-data-bar .utc-pill');
    assert.match(body, /cursor:\s*default\s*;/);
    assert.match(body, /font-variant-numeric:\s*tabular-nums/);
    assert.match(body, /white-space:\s*nowrap/);
    assert.match(body, /flex:\s*0 0 120px/);
});

test('css: no .utc-pill selector is combined with :hover, :active or :focus (incl. :focus-visible/-within)', () => {
    const selectorLists = CSS_CODE.split('{').map((chunk) => chunk.slice(chunk.lastIndexOf('}') + 1));
    const utc = selectorLists.filter((s) => s.includes('utc-pill'));
    assert.ok(utc.length >= 3, 'found utc-pill selector lists (non-vacuous): ' + utc.length);
    utc.forEach((s) => assert.doesNotMatch(s, /:(hover|active|focus)/, 'interactive state on: ' + s.trim()));
});

test('css: compact 953px block, 347px hide and ADMIN-aware :has() 386px hide exist', () => {
    assert.match(CSS_CODE, /@media \(max-width: 953px\)\s*\{\s*\.lcars-data-bar \.legend-pill,\s*\.lcars-data-bar \.utc-pill\s*\{/);
    assert.match(CSS_CODE, /@media \(max-width: 347px\)\s*\{\s*\.lcars-data-bar \.utc-pill\s*\{\s*display:\s*none;/);
    assert.match(CSS_CODE, /@media \(max-width: 386px\)\s*\{\s*\.lcars-data-bar \.utility-cluster:has\(\.admin-pill:not\(\[style\*="display: none"\]\)\) \.utc-pill\s*\{\s*display:\s*none;/);
});

test('css: middle tablet tier (601-953px) keeps normal text; only <=600px shrinks to 0.55rem', () => {
    const compact = CSS_CODE.match(/@media \(max-width: 953px\)\s*\{([\s\S]*?)\n\}/);
    assert.ok(compact, '953px compact block present');
    assert.doesNotMatch(compact[1], /font-size/, 'compact block must not shrink text, or tablets get 8.8px again');
    assert.match(CSS_CODE, /@media \(max-width: 600px\)\s*\{\s*\.lcars-data-bar \.legend-pill,\s*\.lcars-data-bar \.utc-pill\s*\{\s*font-size:\s*0\.55rem;/, 'phone tier owns the small text');
});

test('css: the old header .utc-clock rules are gone', () => {
    assert.doesNotMatch(CSS_CODE, /\.utc-clock\b/);
    assert.doesNotMatch(CSS_CODE, /\.top-sidebar-content \.utc-clock/);
});

// ---- Coupling pin: ADMIN inline style <-> CSS :has() ------------------------------------------------------

test('coupling: ADMIN pill inline style serializes to contain "display: none" and tracks style.display', () => {
    // The 386px CSS rule keys on [style*="display: none"]. That substring match only works while the
    // ADMIN pill is hidden via an inline style whose serialization contains exactly "display: none".
    assert.match(CSS_CODE, /\[style\*="display: none"\]/, 'CSS still depends on the substring');
    const d = doc();
    const admin = d.querySelector('.admin-pill');
    assert.ok(admin, 'ADMIN pill exists');
    assert.ok(admin.getAttribute('style').includes('display: none'), 'markup style: ' + admin.getAttribute('style'));
    admin.style.display = '';
    assert.equal((admin.getAttribute('style') || '').includes('display: none'), false, 'shown state drops the substring');
    admin.style.display = 'none';
    assert.ok(admin.getAttribute('style').includes('display: none'), 'hidden state serializes with "display: none"');
    // jsdom can evaluate the exact selector the stylesheet uses
    const sel = '.utility-cluster:has(.admin-pill:not([style*="display: none"])) .utc-pill';
    assert.equal(d.querySelector(sel), null, 'ADMIN hidden: rule does not match');
    admin.style.display = '';
    assert.ok(d.querySelector(sel), 'ADMIN shown: rule matches the clock');
});

test('coupling: dashboard app toggles ADMIN via .style.display (not hidden attr or class)', () => {
    // CSS :has(.admin-pill:not([style*="display: none"])) depends on this exact mechanism.
    // If you change how ADMIN is shown/hidden, update the 386px rule in lcars-fleet.css too.
    assert.match(APP, /adminBtn\.style\.display\s*=\s*\(CONFIG\.dashboardId === 'all'\) \? '' : 'none'/);
    const i = APP.indexOf("document.querySelector('.admin-pill')");
    assert.ok(i > 0, 'admin lookup present');
    const near = APP.slice(i, i + 400);
    assert.doesNotMatch(near, /adminBtn\.(hidden|classList|setAttribute\('hidden')/, 'no alternate hide mechanism');
});
