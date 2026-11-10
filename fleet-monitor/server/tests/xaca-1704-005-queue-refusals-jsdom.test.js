//
//  xaca-1704-005-queue-refusals-jsdom.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1704-005 -- queue banner names each refused host and its reasons (aggregated over queue items).
 * Loads the REAL lcars-ci-queue.js.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const POOL_JS = path.join(__dirname, '..', 'public', 'shared', 'js', 'lcars-ci-pool.js');
const QUEUE_JS = path.join(__dirname, '..', 'public', 'shared', 'js', 'lcars-ci-queue.js');
const DASHBOARD_HTML = path.join(__dirname, '..', 'public', 'lcars', 'lcars-dashboard.html');

function render(body, opts) {
    if (!fs.existsSync(QUEUE_JS)) throw new Error('MISSING IMPLEMENTATION: ' + QUEUE_JS);
    const dom = new JSDOM('<!doctype html><body><div id="q"></div></body>', { runScripts: 'outside-only', url: 'http://localhost/' });
    if (!opts || opts.pool !== false) dom.window.eval(fs.readFileSync(POOL_JS, 'utf8'));   // dashboard loads pool.js first
    dom.window.eval(fs.readFileSync(QUEUE_JS, 'utf8'));
    const el = dom.window.document.getElementById('q');
    dom.window.LCARSCIQueue.render(body, el, { document: dom.window.document, now: Date.parse('2026-11-09T10:00:00.000Z') });
    return el;
}
function job(id, over) {
    return Object.assign({ key: 'o/r#' + id + '#1', repo: 'o/r', jobId: id, name: 'j' + id, jobClass: 'short', waitingMs: 3000000, noCapacityMs: 0, noEligibleMachine: true }, over || {});
}
function body(queue) {
    return { serverTime: '2026-11-09T10:00:00.000Z', dispatcherEnabled: true, queue, assignments: [],
        noCapacity: { active: true, since: '2026-11-09T09:20:00.000Z', queuedCount: queue.length, oldestQueuedAt: null }, queueAge: [], alerts: [] };
}
const refusals = (el) => el.querySelector('[data-ciq-refusals]');
const txt = (n) => n.textContent.replace(/\s+/g, ' ').trim();

test('names each refused host and its reasons, deduped across jobs', () => {
    const el = render(body([
        job(1, { refusals: { m1mini: ['swap-high'], m4mini: ['label-mismatch', 'swap-high'] } }),
        job(2, { refusals: { m1mini: ['swap-high', 'no-idle-slot'] } }),
    ]));
    const r = refusals(el);
    assert.equal(r.hidden, false);
    // XACA-1704-015: plain text first, code in parentheses; reasons the card has no text for stay as the raw code.
    assert.equal(txt(r), 'Refused: m1mini (swap use too high (swap-high), no-idle-slot); m4mini (label-mismatch, swap use too high (swap-high))');
    assert.equal(r.getAttribute('aria-live'), 'off');
    // The headline is untouched and the existing detail line still carries the counts.
    assert.match(txt(el.querySelector('[data-ciq-headline]')), /no CI machine can take them/);
    assert.match(txt(el.querySelector('[data-ciq-detail]')), /2 queued/);
});

test('bounded display: first 4 hosts then "+K more"; reasons capped too', () => {
    const many = {};
    ['a', 'b', 'c', 'd', 'e', 'f'].forEach((h) => { many[h] = ['r1']; });
    many.a = ['r1', 'r2', 'r3', 'r4', 'r5', 'r6'];
    const t = txt(refusals(render(body([job(1, { refusals: many })]))));
    assert.match(t, /^Refused: a \(r1, r2, r3, r4, \+2 more\); b \(r1\); c \(r1\); d \(r1\); \+2 more$/);
    // Bound also holds with known (longer) labels.
    const known = {};
    ['a', 'b', 'c', 'd', 'e'].forEach((h) => { known[h] = ['swap-high', 'paused', 'load-high', 'no-report', 'stale-poll']; });
    const tk = txt(refusals(render(body([job(1, { refusals: known })]))));
    assert.match(tk, /^Refused: a \(swap use too high \(swap-high\), paused \(paused\), load too high \(load-high\), no health report \(no-report\), \+1 more\);/);
    assert.ok(tk.endsWith('; +1 more') && !tk.includes('e ('));
    assert.ok(!t.includes('e (') && !t.includes('f ('));
});

test('no refusals (absent, empty, malformed) => today\'s text, element hidden', () => {
    [undefined, {}, null, [], 'x', { m: 'swap-high' }, { m: [] }].forEach((rf) => {
        const el = render(body([job(1, rf === undefined ? {} : { refusals: rf })]));
        assert.equal(refusals(el).hidden, true, JSON.stringify(rf));
        assert.equal(txt(refusals(el)), '');
        assert.match(txt(el.querySelector('[data-ciq-headline]')), /no CI machine can take them/);
    });
});

test('hidden again once refusals disappear on a later render', () => {
    const dom = new JSDOM('<!doctype html><body><div id="q"></div></body>', { runScripts: 'outside-only', url: 'http://localhost/' });
    dom.window.eval(fs.readFileSync(QUEUE_JS, 'utf8'));
    const el = dom.window.document.getElementById('q');
    const go = (q) => dom.window.LCARSCIQueue.render(body(q), el, { document: dom.window.document, now: Date.parse('2026-11-09T10:00:00.000Z') });
    go([job(1, { refusals: { m1mini: ['swap-high'] } })]);
    assert.equal(refusals(el).hidden, false);
    go([job(1)]);
    assert.equal(refusals(el).hidden, true);
    assert.equal(txt(refusals(el)), '');
});

test('XSS: hostile host and reason strings are inert text', () => {
    const evil = '<img src=x onerror="window.__pwned=1">';
    const el = render(body([job(1, { refusals: { [evil]: [evil] } })]));
    assert.equal(el.querySelector('img'), null);
    assert.ok(txt(refusals(el)).includes(evil));
    assert.equal(el.ownerDocument.defaultView.__pwned, undefined);
});

test('XACA-1704-015: without pool.js the banner falls back to raw codes; the table is shared, not duplicated', () => {
    const el = render(body([job(1, { refusals: { m1mini: ['swap-high'] } })]), { pool: false });
    assert.equal(txt(refusals(el)), 'Refused: m1mini (swap-high)');
    assert.ok(!/swap use too high/.test(fs.readFileSync(QUEUE_JS, 'utf8')), 'queue.js must not carry its own copy of the reason text');
});

test('dashboard cache-busters were bumped for the changed assets', () => {
    const html = fs.readFileSync(DASHBOARD_HTML, 'utf8');
    ['lcars-ci-pool.css', 'lcars-ci-queue.css', 'lcars-ci-pool.js', 'lcars-ci-queue.js'].forEach((f) => {
        assert.match(html, new RegExp(f.replace('.', '\\.') + '\\?v=20261109b'), f);
    });
});
