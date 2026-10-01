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
function setup({ modalOpen = false, hiddenModals = 3 } = {}) {
    const body = makeEl('body');
    const doc = {
        body,
        createElement: makeEl,
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
    const ctx = { document: doc, location: { reload: () => { reloaded++; } }, window: {}, console };
    const fn = new Function('document', 'location', 'window', 'console', 'refreshPaused',
        block + '\nreturn { checkAssetVersion, evaluateAssetVersion, dismissAssetBanner, ' +
        'getState: () => ({ b: assetVersionBaseline, d: assetVersionDismissed, c: assetVersionCurrent }) };');
    const api = fn(ctx.document, ctx.location, ctx.window, ctx.console, false);
    return { api, doc, body, reloaded: () => reloaded };
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
    assert.strictEqual(b.attrs.role, 'status');
    assert.strictEqual(b.attrs['aria-live'], 'polite');
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
    assert(/finish or reload before saving/.test(b.children[0].textContent));
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

test('loadBoardData calls the comparator and adds no new timer', () => {
    assert(/checkAssetVersion\(response\);/.test(src));
    const sect = src.slice(start, end);
    assert(!/setInterval|setTimeout/.test(sect), 'banner block must not add timers');
});

console.log(`\n${n} tests passed`);
