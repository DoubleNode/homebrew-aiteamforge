#!/usr/bin/env node
//
//  test-xaca-1376-asset-banner.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
//
// XACA-1376: stale-asset banner state machine in lcars-ui/js/lcars.js.
// Extracts the STALE-ASSET BANNER block from the real source (so the test cannot
// drift from the shipped code) and runs it against a tiny DOM stub.
// Run: node lcars-ui/tests/test-xaca-1376-asset-banner.js

const fs = require('fs');
const path = require('path');
const assert = require('assert');

const src = fs.readFileSync(path.join(__dirname, '..', 'js', 'lcars.js'), 'utf8');
const start = src.indexOf('// STALE-ASSET BANNER (XACA-1376)');
const end = src.indexOf('// DATA LOADING', start);
assert(start > 0 && end > start, 'banner block not found in lcars.js');
const block = src.slice(start, end);

// ── minimal DOM stub ──
function makeEl(tag) {
    return {
        tag, children: [], hidden: false, className: '', textContent: '', attrs: {}, handlers: {},
        classes: new Set(),
        setAttribute(k, v) { this.attrs[k] = v; },
        appendChild(c) { this.children.push(c); return c; },
        addEventListener(ev, fn) { this.handlers[ev] = fn; },
        classList: null,
        querySelector(sel) { return this.children.find(c => '.' + c.className.split(' ')[0] === sel) || null; },
    };
}
// Modal stubs mirror the real page: many modals are ALWAYS in the DOM, hidden
// (getClientRects() empty); only an open one is rendered.
const modalStub = rendered => ({ getClientRects: () => (rendered ? [{}] : []) });
function setup({ modalOpen = false, hiddenModals = 3, meta = null, confirmResult = true } = {}) {
    const body = makeEl('body');
    body.classList = { toggle: (c, on) => (on ? body.classes.add(c) : body.classes.delete(c)) };
    const rootVars = {};
    const doc = {
        body,
        documentElement: { style: { setProperty: (k, v) => { rootVars[k] = v; } } },
        createElement: makeEl,
        querySelector: sel => (meta !== null && sel === 'meta[name="lcars-asset-version"]'
            ? { getAttribute: () => meta } : null),
        getElementById: id => body.children.find(c => c.id === id) || null,
        querySelectorAll: () => {
            const els = Array.from({ length: hiddenModals }, () => modalStub(false));
            if (modalOpen) els.push(modalStub(true));
            return els;
        },
    };
    const mk = doc.createElement;
    doc.createElement = tag => {
        const el = mk(tag);
        el.classList = { toggle: (c, on) => (on ? el.classes.add(c) : el.classes.delete(c)) };
        return el;
    };
    let reloaded = 0;
    const confirms = [];
    const ctx = { document: doc, location: { reload: () => { reloaded++; } }, window: {}, console,
        confirm: msg => { confirms.push(msg); return confirmResult; } };
    const fn = new Function('document', 'location', 'window', 'console', 'confirm', 'refreshPaused',
        block + '\nreturn { checkAssetVersion, evaluateAssetVersion, dismissAssetBanner, ' +
        'setModal: on => { refreshPaused = on; }, ' +
        'getState: () => ({ b: assetVersionBaseline, d: assetVersionDismissed, c: assetVersionCurrent }) };');
    const api = fn(ctx.document, ctx.location, ctx.window, ctx.console, ctx.confirm, false);
    return { api, doc, body, rootVars, reloaded: () => reloaded, confirms };
}
const resp = v => ({ headers: { get: () => v } });
const banner = t => t.doc.getElementById('lcars-asset-banner');

let n = 0;
function test(name, fn) { fn(); n++; console.log('ok - ' + name); }

test('missing / empty header never alarms and never sets a baseline', () => {
    const t = setup();
    t.api.checkAssetVersion(resp(null));
    t.api.checkAssetVersion(resp(''));
    t.api.checkAssetVersion({});
    assert.strictEqual(banner(t), null);
    assert.strictEqual(t.api.getState().b, null);
});

test('first value becomes baseline; same value later is silent', () => {
    const t = setup();
    t.api.checkAssetVersion(resp('aaa'));
    t.api.checkAssetVersion(resp('aaa'));
    assert.strictEqual(banner(t), null);
    assert.strictEqual(t.api.getState().b, 'aaa');
});

test('null boot value then a later value is adopted as baseline, not alarmed', () => {
    const t = setup();
    t.api.checkAssetVersion(resp(null));
    t.api.checkAssetVersion(resp('bbb'));
    assert.strictEqual(banner(t), null);
    assert.strictEqual(t.api.getState().b, 'bbb');
});

test('mismatch shows an accessible, non-modal banner with Reload + Dismiss', () => {
    const t = setup();
    t.api.checkAssetVersion(resp('aaa'));
    t.api.checkAssetVersion(resp('bbb'));
    const b = banner(t);
    assert(b && !b.hidden);
    // XACA-1376-022: the bar is a labelled region; announcements go through
    // the boot-time live region (see the live-region tests below).
    assert.strictEqual(b.attrs.role, 'region');
    assert.strictEqual(b.attrs['aria-label'], 'LCARS update notice');
    assert.strictEqual(b.attrs['aria-live'], undefined, 'bar must not be a second live region');
    const btns = b.children.filter(c => c.tag === 'button');
    assert.deepStrictEqual(btns.map(x => x.textContent), ['Reload', 'Dismiss']);
    assert(btns.every(x => x.attrs.type === undefined && x.type === 'button'));
    assert(/reload to get the latest version/.test(b.children[0].textContent));
    btns[0].handlers.click();
    assert.strictEqual(t.reloaded(), 1);
});

test('dismiss suppresses until the fingerprint changes again', () => {
    const t = setup();
    t.api.checkAssetVersion(resp('aaa'));
    t.api.checkAssetVersion(resp('bbb'));
    t.api.dismissAssetBanner();
    assert(banner(t).hidden);
    t.api.checkAssetVersion(resp('bbb'));
    assert(banner(t).hidden, 'same mismatching value stays dismissed');
    t.api.checkAssetVersion(resp('ccc'));
    assert(!banner(t).hidden, 'a new fingerprint re-arms the banner');
});

test('returning to the baseline hides the banner', () => {
    const t = setup();
    t.api.checkAssetVersion(resp('aaa'));
    t.api.checkAssetVersion(resp('bbb'));
    t.api.checkAssetVersion(resp('aaa'));
    assert(banner(t).hidden);
});

test('stronger wording when a modal is open', () => {
    const t = setup({ modalOpen: true });
    t.api.checkAssetVersion(resp('aaa'));
    t.api.checkAssetVersion(resp('bbb'));
    const b = banner(t);
    assert(/may send outdated requests\. Reload before saving \(unsaved changes will be lost\)\./.test(b.children[0].textContent));
    assert(b.classes.has('lcars-asset-banner-warn'));
});

test('hidden modals always present in the DOM do NOT trigger the stronger wording', () => {
    // Regression (XACA-1376-005 live test): presence-only check was always true.
    const t = setup({ modalOpen: false, hiddenModals: 20 });
    t.api.checkAssetVersion(resp('aaa'));
    t.api.checkAssetVersion(resp('bbb'));
    const b = banner(t);
    assert(/reload to get the latest version/.test(b.children[0].textContent));
    assert(!b.classes.has('lcars-asset-banner-warn'));
});

test('a throwing response object never propagates', () => {
    const t = setup();
    t.api.checkAssetVersion({ headers: { get() { throw new Error('x'); } } });
});

test('loadBoardData calls the comparator INSIDE its own body and adds no new timer', () => {
    const fStart = src.indexOf('async function loadBoardData()');
    const fEnd = src.indexOf('\nfunction loadEmbeddedData', fStart);
    assert(fStart > 0 && fEnd > fStart, 'loadBoardData body not found');
    const body = src.slice(fStart, fEnd);
    assert(/checkAssetVersion\(response\);/.test(body), 'comparator must be called inside loadBoardData');
    assert.strictEqual(src.slice(start, end).match(/setInterval|setTimeout/), null, 'banner block must not add timers');
});

test('boot meta is the baseline: a first response that differs SHOWS the banner (cached-tab case)', () => {
    const t = setup({ meta: 'old111' });
    t.api.checkAssetVersion(resp('new222'));
    assert.strictEqual(t.api.getState().b, 'old111');
    assert(banner(t) && !banner(t).hidden, 'cached tab must warn on its very first response');
});

test('boot meta equal to the first response stays silent', () => {
    const t = setup({ meta: 'same' });
    t.api.checkAssetVersion(resp('same'));
    assert.strictEqual(banner(t), null);
    assert.strictEqual(t.api.getState().b, 'same');
});

test('no meta (old server) keeps the first-response baseline behaviour', () => {
    const t = setup({ meta: null });
    t.api.checkAssetVersion(resp('aaa'));
    t.api.checkAssetVersion(resp('bbb'));
    assert.strictEqual(t.api.getState().b, 'aaa');
    assert(banner(t) && !banner(t).hidden);
});

test('meta present but header missing never alarms', () => {
    const t = setup({ meta: 'old111' });
    t.api.checkAssetVersion(resp(null));
    assert.strictEqual(banner(t), null);
});

test('empty meta content is ignored (falls back to first response)', () => {
    const t = setup({ meta: '  ' });
    t.api.checkAssetVersion(resp('aaa'));
    assert.strictEqual(t.api.getState().b, 'aaa');
    assert.strictEqual(banner(t), null);
});

test('Reload in normal mode reloads directly with NO confirm', () => {
    const t = setup();
    t.api.checkAssetVersion(resp('aaa'));
    t.api.checkAssetVersion(resp('bbb'));
    banner(t).children[1].handlers.click();
    assert.strictEqual(t.confirms.length, 0);
    assert.strictEqual(t.reloaded(), 1);
});

test('Reload in warn mode asks first; cancel keeps the page, OK reloads', () => {
    const no = setup({ modalOpen: true, confirmResult: false });
    no.api.checkAssetVersion(resp('aaa'));
    no.api.checkAssetVersion(resp('bbb'));
    banner(no).children[1].handlers.click();
    assert.deepStrictEqual(no.confirms, ['Reload now? Unsaved changes in the open dialog will be lost.']);
    assert.strictEqual(no.reloaded(), 0, 'declined confirm must not reload');
    const yes = setup({ modalOpen: true, confirmResult: true });
    yes.api.checkAssetVersion(resp('aaa'));
    yes.api.checkAssetVersion(resp('bbb'));
    banner(yes).children[1].handlers.click();
    assert.strictEqual(yes.confirms.length, 1);
    assert.strictEqual(yes.reloaded(), 1);
});

test('warn mode reserves the bar height above open modals; normal mode and hide clear it (XACA-1376-020)', () => {
    const OFFSET = 'lcars-asset-banner-warn-active';
    // normal mode: no modal open -> no offset
    const n1 = setup();
    n1.api.checkAssetVersion(resp('aaa'));
    n1.api.checkAssetVersion(resp('bbb'));
    assert(!n1.body.classes.has(OFFSET), 'normal mode must not shift modals');
    // warn mode: offset on, height var published (stub has no layout -> 56px fallback)
    const w = setup({ modalOpen: true });
    w.api.checkAssetVersion(resp('aaa'));
    w.api.checkAssetVersion(resp('bbb'));
    assert(w.body.classes.has(OFFSET), 'warn mode must push modals below the bar');
    assert.strictEqual(w.rootVars['--lcars-asset-banner-h'], '56px');
    // returning to baseline hides the bar -> offset cleared
    w.api.checkAssetVersion(resp('aaa'));
    assert(!w.body.classes.has(OFFSET), 'hidden bar must release the modal offset');
    // dismiss also clears it
    const d = setup({ modalOpen: true });
    d.api.checkAssetVersion(resp('aaa'));
    d.api.checkAssetVersion(resp('bbb'));
    d.api.dismissAssetBanner();
    assert(!d.body.classes.has(OFFSET), 'dismiss must release the modal offset');
});

test('CSS reserves the bar height on BOTH modal containers and not twice on the nested release dialog', () => {
    const css = fs.readFileSync(path.join(__dirname, '..', 'css', 'lcars.css'), 'utf8');
    assert(/body\.lcars-asset-banner-warn-active \.lcars-modal,\s*body\.lcars-asset-banner-warn-active \.lcars-modal-overlay,\s*body\.lcars-asset-banner-warn-active \.activity-timeline-modal \{[^}]*padding-top: calc\(var\(--lcars-asset-banner-h/.test(css),
        'warn-mode reserve must cover .lcars-modal, .lcars-modal-overlay AND the activity side panel (XACA-1376-021)');
    assert(/body\.lcars-asset-banner-warn-active \.lcars-modal-overlay \.lcars-modal \{\s*padding-top: 0;/.test(css));
});

const live = t => t.doc.getElementById('lcars-asset-banner-live');

test('an EMPTY live region exists at boot, before any mismatch (XACA-1376-022)', () => {
    const t = setup();
    const l = live(t);
    assert(l, 'live region must be created when lcars.js loads');
    assert.strictEqual(l.attrs.role, 'status');
    assert.strictEqual(l.attrs['aria-live'], 'polite');
    assert.strictEqual(l.className, 'sr-only');
    assert.strictEqual(l.textContent, '');
    assert.strictEqual(banner(t), null, 'the visual bar is still built lazily');
});

test('live region: filled on show, cleared on hide, re-announced on re-show, updated on mode switch', () => {
    const t = setup();
    t.api.checkAssetVersion(resp('aaa'));
    assert.strictEqual(live(t).textContent, '', 'no announcement without a mismatch');
    t.api.checkAssetVersion(resp('bbb'));
    assert(/reload to get the latest version/.test(live(t).textContent), 'show must announce');
    t.api.checkAssetVersion(resp('aaa'));
    assert.strictEqual(live(t).textContent, '', 'hide must clear so the next show is a change');
    t.api.checkAssetVersion(resp('ccc'));
    assert(/reload to get the latest version/.test(live(t).textContent), 're-show must announce again');
    t.api.setModal(true);
    t.api.checkAssetVersion(resp('ccc'));
    assert(/outdated requests/.test(live(t).textContent), 'warn-mode switch must change the announced text');
    t.api.dismissAssetBanner();
    assert.strictEqual(live(t).textContent, '', 'dismiss must clear');
});

test('warn vs normal mode is recomputed on every check, not only on pause/resume', () => {
    const t = setup();
    t.api.checkAssetVersion(resp('aaa'));
    t.api.checkAssetVersion(resp('bbb'));
    assert(!banner(t).classes.has('lcars-asset-banner-warn'));
    t.api.setModal(true);                      // modal opens WITHOUT pauseAutoRefresh hook firing the refresh
    t.api.checkAssetVersion(resp('bbb'));      // next poll, same mismatching value
    assert(banner(t).classes.has('lcars-asset-banner-warn'));
    assert(/Reload before saving/.test(banner(t).children[0].textContent));
    t.api.setModal(false);
    t.api.checkAssetVersion(resp('bbb'));
    assert(!banner(t).classes.has('lcars-asset-banner-warn'));
});

console.log(`\n${n} tests passed`);
