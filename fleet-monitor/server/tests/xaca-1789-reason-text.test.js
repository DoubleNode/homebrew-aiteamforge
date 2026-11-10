//
//  xaca-1789-reason-text.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1789 -- every refusal reason code ci-dispatch-placement.js can emit has plain text in LCARSCIPool.REASON_TEXT,
 * the table is frozen, and a text equal to its code renders without a redundant "(code)" suffix on card and banner.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const PUBLIC_JS = path.join(__dirname, '..', 'public', 'shared', 'js');
const POOL_JS = path.join(PUBLIC_JS, 'lcars-ci-pool.js');
const QUEUE_JS = path.join(PUBLIC_JS, 'lcars-ci-queue.js');
const PLACEMENT_JS = path.join(__dirname, '..', 'lib', 'ci-dispatch-placement.js');

function loadPool() {
    const dom = new JSDOM('<!doctype html><html><body><div id="p"></div><div id="q"></div></body></html>', { runScripts: 'outside-only', url: 'http://localhost/' });
    dom.window.eval(fs.readFileSync(POOL_JS, 'utf8'));
    dom.window.eval(fs.readFileSync(QUEUE_JS, 'utf8'));
    return dom;
}
const txt = (n) => (n.textContent || '').replace(/\s+/g, ' ').trim();

/** Reason literals placement can emit: .push('code'), return/ternary arrays ['code'], and reasons-only first-arg pushes. */
function emittedCodes() {
    const src = fs.readFileSync(PLACEMENT_JS, 'utf8');
    const out = new Set();
    for (const m of src.matchAll(/\.push\(\s*'([a-z][a-z0-9-]*)'\s*\)/g)) out.add(m[1]);
    for (const m of src.matchAll(/reasons\s*:\s*\[\s*'([a-z][a-z0-9-]*)'\s*\]/g)) out.add(m[1]);
    // `chk('swap-high', ...)` repeats codes already pushed; labels are never pushed, so no exclusion list is needed.
    return Array.from(out).sort();
}

test('enumeration: every reason code placement can emit has non-empty text in REASON_TEXT', () => {
    const codes = emittedCodes();
    assert.ok(codes.length >= 20, 'anti-vacuous: extracted only ' + codes.length + ' codes: ' + codes.join(','));
    for (const known of ['swap-high', 'label-mismatch', 'paused', 'no-idle-slot', 'vm-not-running']) assert.ok(codes.includes(known), 'extractor missed ' + known);
    const T = loadPool().window.LCARSCIPool.REASON_TEXT;
    const missing = codes.filter((c) => !Object.prototype.hasOwnProperty.call(T, c) || typeof T[c] !== 'string' || T[c].trim() === '');
    assert.deepEqual(missing, [], 'reason codes with no plain text: ' + missing.join(', '));
});

test('REASON_TEXT is frozen: a write, add or delete cannot change it', () => {
    const T = loadPool().window.LCARSCIPool.REASON_TEXT;
    assert.equal(Object.isFrozen(T), true);
    const before = T['swap-high'];
    try { T['swap-high'] = 'hijacked'; } catch (_) { /* strict-mode TypeError is acceptable */ }
    try { T['brand-new'] = 'x'; } catch (_) { /* ditto */ }
    try { delete T.paused; } catch (_) { /* ditto */ }
    assert.equal(T['swap-high'], before);
    assert.equal(Object.prototype.hasOwnProperty.call(T, 'brand-new'), false);
    assert.equal(T.paused, 'paused');
});

test('card: paused renders without "(paused)"; swap-high and label-mismatch keep their code suffix', () => {
    const dom = loadPool();
    const el = dom.window.document.getElementById('p');
    const machine = { state: 'enabled', enabled: true, paused: false, capability: 'jit',
        eligibility: { eligible: false, reasons: ['paused', 'swap-high', 'label-mismatch'], checks: [] } };
    dom.window.LCARSCIPool.render({ serverTime: '2026-11-09T10:00:00.000Z', machines: { m: machine }, assignments: [] }, el,
        { document: dom.window.document, fetch: async () => ({ ok: true, status: 200, json: async () => ({}) }) });
    const line = (r) => txt(el.querySelector('[data-cicd-pool-refusal-reason="' + r + '"]'));
    assert.equal(line('paused'), 'paused');
    assert.equal(line('swap-high'), 'swap use too high (swap-high)');
    assert.equal(line('label-mismatch'), 'job pinned to another host (label-mismatch)');
});

test('banner: paused renders without "(paused)"; swap-high and label-mismatch keep their code suffix', () => {
    const dom = loadPool();
    const el = dom.window.document.getElementById('q');
    const queue = [{ key: 'o/r#1#1', repo: 'o/r', jobId: 1, name: 'j1', jobClass: 'short', waitingMs: 3000000, noCapacityMs: 0, noEligibleMachine: true,
        refusals: { m1: ['paused', 'swap-high', 'label-mismatch'] } }];
    dom.window.LCARSCIQueue.render({ serverTime: '2026-11-09T10:00:00.000Z', dispatcherEnabled: true, queue, assignments: [],
        noCapacity: { active: true, since: '2026-11-09T09:20:00.000Z', queuedCount: 1, oldestQueuedAt: null }, queueAge: [], alerts: [] },
        el, { document: dom.window.document, now: Date.parse('2026-11-09T10:00:00.000Z') });
    assert.equal(txt(el.querySelector('[data-ciq-refusals]')),
        'Refused: m1: paused, swap use too high (swap-high), job pinned to another host (label-mismatch)');
});

// ---- XACA-1789-011..014: banner delimiter, suffix rule, text tweaks ----------------------------------------
test('011: banner uses a colon host delimiter, so no parenthesis nests inside another', () => {
    const dom = loadPool();
    const el = dom.window.document.getElementById('q');
    const queue = [{ key: 'o/r#1#1', repo: 'o/r', jobId: 1, name: 'j1', jobClass: 'short', waitingMs: 3000000, noCapacityMs: 0, noEligibleMachine: true,
        refusals: { m1mini: ['mem-pressure', 'paused'], m4mini: ['not-enabled'] } }];
    dom.window.LCARSCIQueue.render({ serverTime: '2026-11-09T10:00:00.000Z', dispatcherEnabled: true, queue, assignments: [],
        noCapacity: { active: true, since: '2026-11-09T09:20:00.000Z', queuedCount: 1, oldestQueuedAt: null }, queueAge: [], alerts: [] },
        el, { document: dom.window.document, now: Date.parse('2026-11-09T10:00:00.000Z') });
    const t = txt(el.querySelector('[data-ciq-refusals]'));
    assert.equal(t, 'Refused: m1mini: memory pressure high (mem-pressure), paused; m4mini: not enabled');
    assert.ok(!/\([^)]*\(/.test(t), 'no nested parentheses: ' + t);
});

test('012: (code) suffix is suppressed when text is the code with hyphens as spaces (case-insensitive); exact equality still covered', () => {
    const P = loadPool().window.LCARSCIPool;
    assert.equal(P.textIsCode('not enabled', 'not-enabled'), true);
    assert.equal(P.textIsCode('VM not running', 'vm-not-running'), true);
    assert.equal(P.textIsCode('paused', 'paused'), true);
    assert.equal(P.textIsCode('swap use too high', 'swap-high'), false);
    const dom = loadPool();
    const el = dom.window.document.getElementById('p');
    const machine = { state: 'enabled', enabled: true, paused: false, capability: 'jit',
        eligibility: { eligible: false, reasons: ['not-enabled', 'no-idle-slot', 'vm-not-running', 'no-report'], checks: [] } };
    dom.window.LCARSCIPool.render({ serverTime: '2026-11-09T10:00:00.000Z', machines: { m: machine }, assignments: [] }, el,
        { document: dom.window.document, fetch: async () => ({ ok: true, status: 200, json: async () => ({}) }) });
    const line = (r) => txt(el.querySelector('[data-cicd-pool-refusal-reason="' + r + '"]'));
    assert.equal(line('not-enabled'), 'not enabled');
    assert.equal(line('no-idle-slot'), 'no idle slot');
    assert.equal(line('vm-not-running'), 'VM not running');
    assert.equal(line('no-report'), 'no health report (no-report)');
});

test('013/014: reason text tweaks', () => {
    const T = loadPool().window.LCARSCIPool.REASON_TEXT;
    assert.equal(T['mem-pressure'], 'memory pressure high');
    assert.equal(T['no-idle-slot'], 'no idle slot');   // slots may be busy, starting or cleaning: "all slots busy" would be wrong
    assert.equal(T['no-slots'], 'no slots reported');
    assert.equal(T['no-last-poll'], 'poll time missing');
    assert.equal(T['label-mismatch'], 'job pinned to another host');
});

// ---- XACA-1789-015: every reason push in placement must be a single-quoted literal or a known spread ------------
test('015: placement emits reason codes only as single-quoted literals (or allowlisted spreads), so the enumeration cannot be bypassed', () => {
    const src = fs.readFileSync(PLACEMENT_JS, 'utf8');
    const ARRAYS = '(?:reasons|h|admin|headroom|freshness|noReport|st\\.admin|st\\.noReport|st\\.freshness|st\\.headroom)';
    const SPREADS = new Set(['...gate.admin', '...gate.noReport', '...gate.freshness', '...gate.headroom']);
    let seen = 0;
    const bad = [];
    for (const m of src.matchAll(new RegExp('(?:^|[^\\w.])' + ARRAYS + '\\.push\\(([^;\\n]*?)\\)\\s*(?:;|\\n|\\}|$)', 'g'))) {
        seen++;
        const arg = m[1].trim();
        if (/^'[a-z][a-z0-9-]*'$/.test(arg) || SPREADS.has(arg)) continue;
        bad.push(m[0].trim());
    }
    assert.ok(seen >= 25, 'anti-vacuous: scanned only ' + seen + ' reason pushes');
    assert.deepEqual(bad, [], 'non-literal reason pushes (add text + extend the extractor or the allowlist): ' + bad.join(' | '));
    // st.checks pushes carry objects, not codes: not in ARRAYS by construction.
    assert.ok(!/\.checks\.push\(\s*'/.test(src));
});

test('017: banner uses the shared LCARSCIPool.textIsCode (one rule for card and banner)', () => {
    const P = loadPool().window.LCARSCIPool;
    assert.equal(P.textIsCode('no-report', 'no-report'), true, 'exact hyphenated equality');
    const src = fs.readFileSync(QUEUE_JS, 'utf8');
    assert.match(src, /pool\.textIsCode\(/, 'queue.js calls the shared helper');
    assert.ok(!/replace\(\/-\/g/.test(src), 'queue.js carries no copy of the hyphen rule');
});
