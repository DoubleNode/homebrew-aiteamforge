//
//  xaca-1704-004-refusing-card-jsdom.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1704-004 -- the CI pool machine card shows REFUSING (with reasons and measured-vs-limit) when the admin
 * state is enabled but eligibility.eligible === false. Loads the REAL lcars-ci-pool.js.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const PUBLIC_ROOT = path.join(__dirname, '..', 'public');
const POOL_JS = path.join(PUBLIC_ROOT, 'shared', 'js', 'lcars-ci-pool.js');
const POOL_CSS = path.join(PUBLIC_ROOT, 'shared', 'css', 'lcars-ci-pool.css');

function mkMachine(over) {
    return Object.assign({ state: 'enabled', enabled: true, paused: false, capability: 'jit' }, over || {});
}
function render(machines) {
    if (!fs.existsSync(POOL_JS)) throw new Error('MISSING IMPLEMENTATION: ' + POOL_JS);
    const dom = new JSDOM('<!doctype html><html><body><div id="p"></div></body></html>', { runScripts: 'outside-only', url: 'http://localhost/' });
    dom.window.eval(fs.readFileSync(POOL_JS, 'utf8'));
    const el = dom.window.document.getElementById('p');
    dom.window.LCARSCIPool.render({ serverTime: '2026-11-09T10:00:00.000Z', machines, assignments: [] }, el, { document: dom.window.document, fetch: async () => ({ ok: true, status: 200, json: async () => ({}) }) });
    return { el, card: (id) => el.querySelector('[data-cicd-pool-machine-card="' + id + '"]') };
}
const txt = (n) => (n.textContent || '').replace(/\s+/g, ' ').trim();

const REFUSING = {
    eligible: false, reasons: ['swap-high', 'load-high'],
    checks: [
        { reason: 'swap-high', measured: 5 * 1073741824, limit: 2 * 1073741824 },
        { reason: 'load-high', measured: { load1PerCpu: 2.5, load5PerCpu: 1.234 }, limit: 2 },
    ],
    os: { macOS: { eligible: false, reasons: ['swap-high'] }, Linux: { eligible: true, reasons: [] } },
};

test('enabled + eligible:false renders REFUSING badge, reasons and measured vs limit', () => {
    const env = render({ m1mini: mkMachine({ eligibility: REFUSING }) });
    const c = env.card('m1mini');
    assert.equal(c.getAttribute('data-cicd-pool-refusing'), 'true');
    assert.match(txt(c.querySelector('.cicd-pool-badge')), /REFUSING/);
    assert.doesNotMatch(txt(c.querySelector('.cicd-pool-badge')), /ENABLED/);
    // XACA-1704-016: ONE line per reason: plain text, measured vs limit, then the code in parentheses.
    const rs = c.querySelectorAll('[data-cicd-pool-refusal-reason]');
    assert.equal(rs.length, 2, 'two reasons => two lines, no second list repeating them');
    assert.equal(c.querySelectorAll('[data-cicd-pool-refusal-check]').length, 2);
    assert.equal(c.querySelector('[data-cicd-pool-refusal-checks]'), null);
    assert.equal(txt(c.querySelector('[data-cicd-pool-refusal-reason="swap-high"]')), 'swap use too high: 5.0 GiB vs limit 2.0 GiB (swap-high)');
    assert.equal(txt(c.querySelector('[data-cicd-pool-refusal-reason="load-high"]')), 'load too high: 1m 2.50/CPU, 5m 1.23/CPU vs limit 2.00/CPU (load-high)');
    assert.equal(c.querySelector('[data-cicd-pool-refusal-reason="swap-high"]').getAttribute('data-cicd-pool-refusal-check'), 'swap-high');
    // Each reason appears exactly once on the card (it used to be listed twice: reason+code, then measured-vs-limit).
    assert.equal((txt(c.querySelector('[data-cicd-pool-refusal-reasons]')).match(/swap-high/g) || []).length, 1);
    assert.match(txt(c.querySelector('[data-cicd-pool-refusal-os]')), /macOS refusing · Linux ok/);
    // The refusal is in the always-visible header, not the collapsed details.
    assert.ok(!c.querySelector('[data-cicd-pool-details]').contains(c.querySelector('[data-cicd-pool-refusal]')));
});

test('unit formatting: MiB, pct, ms to s/min, bytes per hour, load5 omitted when null, pressure level', () => {
    const env = render({ a: mkMachine({ eligibility: { eligible: false, reasons: ['x'], checks: [
        { reason: 'swap-high', measured: 512 * 1048576, limit: 256 * 1048576 },
        { reason: 'mem-free-low', measured: 4.5, limit: 10 },
        { reason: 'stale-poll', measured: 45000, limit: 30000 },
        { reason: 'stale-poll', measured: 600000, limit: 120000 },
        { reason: 'swap-growing', measured: 2 * 1073741824, limit: 1073741824 },
        { reason: 'mem-pressure', measured: 'critical', limit: 'warn' },
        { reason: 'load-high', measured: { load1PerCpu: 3, load5PerCpu: null }, limit: 2 },
    ] } }) });
    const t = Array.from(env.card('a').querySelectorAll('[data-cicd-pool-refusal-check]')).map(txt);
    assert.match(t[0], /512 MiB vs limit 256 MiB/);
    assert.match(t[1], /4\.5% vs limit 10%/);
    assert.match(t[2], /45\.0 s vs limit 30\.0 s/);
    assert.match(t[3], /10\.0 min vs limit 2\.0 min/);
    assert.match(t[4], /2\.0 GiB\/h vs limit 1\.0 GiB\/h/);
    assert.match(t[5], /critical vs limit warn/);
    assert.match(t[6], /1m 3\.00\/CPU vs limit 2\.00\/CPU/);
    assert.doesNotMatch(t[6], /5m/);
});

test('XACA-1704-016: a reason with no check shows text plus code; an unknown reason shows the raw code; orphan checks still show', () => {
    const env = render({ m: mkMachine({ eligibility: { eligible: false, reasons: ['no-report', 'brand-new-reason'],
        checks: [{ reason: 'mem-free-low', measured: 4.5, limit: 10 }] } }) });
    const c = env.card('m');
    assert.equal(txt(c.querySelector('[data-cicd-pool-refusal-reason="no-report"]')), 'no health report (no-report)');
    assert.equal(c.querySelector('[data-cicd-pool-refusal-reason="no-report"]').hasAttribute('data-cicd-pool-refusal-check'), false);
    assert.equal(txt(c.querySelector('[data-cicd-pool-refusal-reason="brand-new-reason"]')), 'brand-new-reason');
    assert.equal(txt(c.querySelector('[data-cicd-pool-refusal-check="mem-free-low"]')), 'free memory too low: 4.5% vs limit 10% (mem-free-low)');
});

test('XACA-1704-017: swap-growing line is per hour on BOTH sides (server normalises measured)', () => {
    const env = render({ m: mkMachine({ eligibility: { eligible: false, reasons: ['swap-growing'],
        checks: [{ reason: 'swap-growing', measured: 6 * 1073741824, limit: 1073741824 }] } }) });
    assert.equal(txt(env.card('m').querySelector('[data-cicd-pool-refusal-reason="swap-growing"]')),
        'swap growing too fast: 6.0 GiB/h vs limit 1.0 GiB/h (swap-growing)');
});

test('not-enabled, paused and eligible machines keep their presentation (no double label)', () => {
    const el = { eligible: false, reasons: ['not-enabled'], checks: [] };
    const env = render({
        off: mkMachine({ state: 'disabled', enabled: false, eligibility: el }),
        pz: mkMachine({ state: 'paused', paused: true, eligibility: { eligible: false, reasons: ['paused'] } }),
        ok: mkMachine({ eligibility: { eligible: true, reasons: [], checks: [] } }),
    });
    ['off', 'pz', 'ok'].forEach((id) => {
        assert.equal(env.card(id).querySelector('[data-cicd-pool-refusal]'), null, id);
        assert.equal(env.card(id).hasAttribute('data-cicd-pool-refusing'), false, id);
        assert.doesNotMatch(txt(env.card(id).querySelector('.cicd-pool-badge')), /REFUSING/, id);
    });
    assert.match(txt(env.card('ok').querySelector('.cicd-pool-badge')), /ENABLED/);
});

test('back-compat: no eligibility field renders exactly as before', () => {
    const withField = render({ m: mkMachine({ eligibility: { eligible: true, reasons: [], checks: [] } }) });
    const without = render({ m: mkMachine() });
    assert.equal(without.card('m').innerHTML, withField.card('m').innerHTML);
    assert.match(txt(without.card('m').querySelector('.cicd-pool-badge')), /ENABLED/);
    assert.equal(without.card('m').querySelector('[data-cicd-pool-refusal]'), null);
});

test('refusing flag clears on re-render when the machine becomes eligible', () => {
    const dom = new JSDOM('<!doctype html><body><div id="p"></div></body>', { runScripts: 'outside-only', url: 'http://localhost/' });
    dom.window.eval(fs.readFileSync(POOL_JS, 'utf8'));
    const el = dom.window.document.getElementById('p');
    const go = (e) => dom.window.LCARSCIPool.render({ serverTime: '2026-11-09T10:00:00.000Z', machines: { m: mkMachine({ eligibility: e }) } }, el, { document: dom.window.document });
    go(REFUSING);
    assert.equal(el.querySelector('[data-cicd-pool-machine-card]').getAttribute('data-cicd-pool-refusing'), 'true');
    go({ eligible: true, reasons: [], checks: [] });
    const c = el.querySelector('[data-cicd-pool-machine-card]');
    assert.equal(c.hasAttribute('data-cicd-pool-refusing'), false);
    assert.equal(c.querySelector('[data-cicd-pool-refusal]'), null);
});

test('XSS: hostile reason / check strings are inert text', () => {
    const evil = '<img src=x onerror="window.__pwned=1">';
    const env = render({ m: mkMachine({ eligibility: { eligible: false, reasons: [evil], checks: [{ reason: evil, measured: evil, limit: '"><script>1</script>' }] } }) });
    const c = env.card('m');
    assert.equal(c.querySelector('img'), null);
    assert.equal(c.querySelector('script'), null);
    assert.ok(txt(c.querySelector('[data-cicd-pool-refusal]')).includes(evil));
    assert.equal(env.el.ownerDocument.defaultView.__pwned, undefined);
});

test('XSS: a quote-bearing reason cannot break out of the data-* attributes (no injected attribute/handler)', () => {
    const evil = '" onmouseover="window.__pwned=1" x="';
    const env = render({ m: mkMachine({ eligibility: { eligible: false, reasons: [evil], checks: [{ reason: evil, measured: 1, limit: 1 }] } }) });
    const c = env.card('m');
    const all = Array.from(c.querySelectorAll('*'));
    all.forEach((n) => Array.from(n.attributes).forEach((a) => assert.ok(!/^on/i.test(a.name), 'injected attribute ' + a.name)));
    assert.equal(c.querySelector('[data-cicd-pool-refusal-reason]').getAttribute('data-cicd-pool-refusal-reason'), evil);
    assert.equal(c.querySelector('[data-cicd-pool-refusal-check]').getAttribute('data-cicd-pool-refusal-check'), evil);
});

test('malformed eligibility never throws and only eligible === false counts', () => {
    ['x', 5, [], { eligible: 'false' }, { eligible: null }].forEach((e) => {
        const env = render({ m: mkMachine({ eligibility: e }) });
        assert.equal(env.card('m').hasAttribute('data-cicd-pool-refusing'), false, JSON.stringify(e));
    });
    const env = render({ m: mkMachine({ eligibility: { eligible: false } }) });
    assert.match(txt(env.card('m').querySelector('.cicd-pool-badge')), /REFUSING/);
});

test('stylesheet styles the refusing card with tokens only (no raw hex)', () => {
    const css = fs.readFileSync(POOL_CSS, 'utf8');
    assert.match(css, /\[data-cicd-pool-refusing="true"\]/);
    const block = css.slice(css.indexOf('XACA-1704-004')).replace(/\/\*[\s\S]*?\*\//g, '');
    assert.ok(!/#[0-9a-fA-F]{3,8}\b/.test(block));
});
