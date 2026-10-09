//
//  xaca-1479-ci-queue-priority-badge-jsdom.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/** XACA-1479-007 -- priority badge on CI queue rows (public/shared/js/lcars-ci-queue.js). Loads the REAL module. */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const QUEUE_JS = path.join(__dirname, '..', 'public', 'shared', 'js', 'lcars-ci-queue.js');
const QUEUE_CSS = path.join(__dirname, '..', 'public', 'shared', 'css', 'lcars-ci-queue.css');

function loadImpl() {
    assert.ok(fs.existsSync(QUEUE_JS), 'lcars-ci-queue.js missing');
    const dom = new JSDOM('<!doctype html><html><body><div id="q"></div></body></html>', { runScripts: 'outside-only', url: 'http://localhost/' });
    dom.window.eval(fs.readFileSync(QUEUE_JS, 'utf8'));
    const el = dom.window.document.getElementById('q');
    return { el, render: (body) => dom.window.LCARSCIQueue.render(body, el, { document: dom.window.document, now: Date.parse('2026-10-07T18:02:10.000Z') }) };
}
const job = (id, over) => Object.assign({ key: 'o/r#' + id + '#1', repo: 'o/r', jobId: id, name: 'unit-' + id, waitingMs: 1000, noCapacityMs: 0, noEligibleMachine: false }, over || {});
const body = (queue) => ({ serverTime: '2026-10-07T18:02:10.000Z', dispatcherEnabled: true, queue, assignments: [], noCapacity: { active: false }, queueAge: [], alerts: [] });
const statusCell = (env, id) => env.el.querySelector('tr[data-ciq-job="o/r#' + id + '"] td:nth-child(4)');

test('CRITICAL and HIGH render glyph + text + accessible name; NORMAL/absent/unknown render none', () => {
    const env = loadImpl();
    env.render(body([job(1, { priority: 'critical' }), job(2, { priority: 'high' }), job(3, { priority: 'normal' }), job(4), job(5, { priority: 'urgent' }), job(6, { priority: 9 })]));
    const crit = statusCell(env, 1).querySelector('.ciq-prio');
    assert.ok(crit && crit.getAttribute('data-ciq-priority') === 'critical');
    assert.match(crit.textContent, /▲▲/);
    assert.match(crit.textContent, /CRITICAL/);
    assert.equal(crit.querySelector('.ciq-prio-glyph').getAttribute('aria-hidden'), 'true');
    assert.match(crit.querySelector('.ciq-sr').textContent, /priority/);
    const high = statusCell(env, 2).querySelector('.ciq-prio');
    assert.match(high.textContent, /▲ ?HIGH/);
    assert.ok(!/▲▲/.test(high.textContent));
    for (const id of [3, 4, 5, 6]) assert.equal(statusCell(env, id).querySelector('.ciq-prio'), null, 'row ' + id);
    assert.match(statusCell(env, 3).textContent, /^queued$/);
});

test('badge appears, changes and clears in place across re-renders (row node reused)', () => {
    const env = loadImpl();
    env.render(body([job(1)]));
    const tr = env.el.querySelector('tbody tr');
    env.render(body([job(1, { priority: 'high' })]));
    assert.match(statusCell(env, 1).textContent, /HIGH/);
    env.render(body([job(1, { priority: 'critical' })]));
    assert.equal(statusCell(env, 1).querySelectorAll('.ciq-prio').length, 1);
    assert.match(statusCell(env, 1).textContent, /CRITICAL/);
    env.render(body([job(1, { priority: 'normal' })]));
    assert.equal(statusCell(env, 1).querySelector('.ciq-prio'), null);
    assert.equal(env.el.querySelector('tbody tr'), tr);
});

test('hostile text in job name / repo / priority is never interpreted as HTML', () => {
    const env = loadImpl();
    const evil = '<img src=x onerror=alert(1)><b>x</b>';
    env.render(body([job(1, { priority: 'critical', name: evil, branch: evil }), job(2, { priority: evil })]));
    assert.equal(env.el.querySelectorAll('img, b').length, 0);
    assert.ok(env.el.textContent.includes(evil));
    assert.equal(statusCell(env, 2).querySelector('.ciq-prio'), null);
});

test('badge CSS uses tokens only', () => {
    const css = fs.readFileSync(QUEUE_CSS, 'utf8').replace(/\/\*[\s\S]*?\*\//g, '');
    assert.match(css, /\.ciq-prio-critical/);
    assert.ok(!/#[0-9a-fA-F]{3,8}\b|rgb\(|hsl\(/.test(css));
});
