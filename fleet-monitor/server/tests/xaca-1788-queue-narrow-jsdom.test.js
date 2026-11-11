//
//  xaca-1788-queue-narrow-jsdom.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1788 -- the CI queue table stacks into labelled cards below its natural width. jsdom has no layout,
 * so this pins the contract (labels per cell, single-sourced headers, container query in the CSS); the
 * rendered result is verified in a real browser (see the plan's Evidence).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const PUB = path.join(__dirname, '..', 'public');
const QUEUE_JS = path.join(PUB, 'shared', 'js', 'lcars-ci-queue.js');
const QUEUE_CSS = path.join(PUB, 'shared', 'css', 'lcars-ci-queue.css');

function renderQueue() {
    const dom = new JSDOM('<!doctype html><html><body><div id="q"></div></body></html>', { runScripts: 'outside-only', url: 'http://localhost/' });
    dom.window.eval(fs.readFileSync(QUEUE_JS, 'utf8'));
    const el = dom.window.document.getElementById('q');
    const job = (i) => ({ key: 'o/r#' + i, repo: 'r', jobId: i, name: 'job ' + i, branch: 'b', waitingMs: 60000, priority: i === 1 ? 'critical' : 'normal' });
    const body = { serverTime: '2026-11-10T22:00:00.000Z', dispatcherEnabled: true, queue: [job(1), job(2)], assignments: [],
        noCapacity: { active: false }, queueAge: [], alerts: [] };
    dom.window.LCARSCIQueue.render(body, el, { document: dom.window.document, now: Date.parse('2026-11-10T22:00:00.000Z') });
    return el;
}

test('every row cell carries a data-label equal to its column header, in order', () => {
    const el = renderQueue();
    const heads = Array.from(el.querySelectorAll('thead th')).map((t) => t.textContent);
    assert.equal(heads.length, 6);
    const rows = Array.from(el.querySelectorAll('tbody tr'));
    assert.ok(rows.length >= 2);
    rows.forEach((tr) => {
        const labels = Array.from(tr.children).map((td) => td.getAttribute('data-label'));
        assert.deepEqual(labels, heads);
    });
});

test('explicit ARIA table roles survive the display:block stacked layout', () => {
    const el = renderQueue();
    assert.equal(el.querySelector('table.ciq-table').getAttribute('role'), 'table');
    el.querySelectorAll('thead, tbody').forEach((g) => assert.equal(g.getAttribute('role'), 'rowgroup'));
    el.querySelectorAll('tr').forEach((r) => assert.equal(r.getAttribute('role'), 'row'));
    el.querySelectorAll('th').forEach((h) => assert.equal(h.getAttribute('role'), 'columnheader'));
    const tds = el.querySelectorAll('tbody td');
    assert.ok(tds.length >= 12);
    tds.forEach((d) => assert.equal(d.getAttribute('role'), 'cell'));
});

test('the header list is single-sourced: one literal array, used for th and td labels', () => {
    const src = fs.readFileSync(QUEUE_JS, 'utf8');
    assert.equal((src.match(/'Workflow \/ job'/g) || []).length, 1, 'header text must appear once');
    assert.match(src, /HEADERS\.forEach/);
    assert.match(src, /setAttribute\('data-label', HEADERS\[c\]\)/);
});

test('CSS stacks rows in a container query on the queue root, keeping thead for assistive tech', () => {
    const css = fs.readFileSync(QUEUE_CSS, 'utf8');
    assert.match(css, /\.ciq\s*\{[^}]*container-type:\s*inline-size/);
    const m = css.match(/@container[^{]*\(max-width:\s*[\d.]+em\)\s*\{([\s\S]*)\n\}/);
    assert.ok(m, 'an @container (max-width) block is required');
    const block = m[1];
    assert.match(block, /tr\.ciq-row\s*\{[^}]*display:\s*block/);
    assert.match(block, /td::before\s*\{[^}]*content:\s*attr\(data-label\)/);
    assert.match(block, /thead\s*\{[^}]*clip:\s*rect/, 'thead is visually hidden, not display:none');
    assert.ok(!/thead\s*\{[^}]*display:\s*none/.test(block));
    assert.match(block, /min-width:\s*0/);
    assert.match(block, /\.ciq-table td\s*\{[^}]*flex-wrap:\s*wrap/, "a badged Status cell wraps instead of clipping (review advisory)");
});
