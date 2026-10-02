//
//  xaca-1388-005-cicd-section-jsdom.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1388 subitem 005 -- jsdom render tests for the LCARS "CI/CD" section.
 *
 * Loads the REAL shipped public/lcars/js/lcars-cicd.js (never a paraphrase)
 * into a jsdom window and drives window.LCARSCICD against the four canonical
 * fixtures of the /api/ci-runners contract
 * (kanban/plans/XACA-1388/XACA-1388_ci_runners_contract.md):
 * tests/fixtures/xaca-1388-ci-runners-{empty,healthy,stale,offline}.json.
 *
 * Asserts on the stable data-cicd-* hooks, never presentation classes.
 *
 * Vacuous-green guard: if lcars-cicd.js is missing this suite FAILS (the first
 * test asserts existence, and loadImpl() throws) -- it never skips.
 *
 * Coverage: (1) pure status derivation incl. priority, strict ">" boundaries
 * and server-clock-only; (2-5) render empty/healthy/stale/offline incl. XSS
 * and URL allow-listing; (6) refresh() 404 / 5xx / network; (7) dashboard
 * wiring smoke against the real lcars-dashboard.html.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const PUBLIC_ROOT = path.join(__dirname, '..', 'public');
const CICD_JS = path.join(PUBLIC_ROOT, 'lcars', 'js', 'lcars-cicd.js');
const DASHBOARD_HTML = path.join(PUBLIC_ROOT, 'lcars', 'lcars-dashboard.html');
const FIXTURE_DIR = path.join(__dirname, 'fixtures');

function fixture(name) {
    return JSON.parse(fs.readFileSync(path.join(FIXTURE_DIR, 'xaca-1388-ci-runners-' + name + '.json'), 'utf8'));
}

// Fresh jsdom window with the real implementation loaded. Throws (=> test
// FAILS) when the implementation file is missing.
function loadImpl() {
    if (!fs.existsSync(CICD_JS)) {
        throw new Error('MISSING IMPLEMENTATION: ' + CICD_JS);
    }
    const dom = new JSDOM('<!doctype html><html><body><div id="cicd-content"></div></body></html>',
        { runScripts: 'outside-only', url: 'http://localhost/' });
    dom.window.eval(fs.readFileSync(CICD_JS, 'utf8'));
    const api = dom.window.LCARSCICD;
    assert.ok(api, 'window.LCARSCICD must be exposed');
    return { dom, window: dom.window, document: dom.window.document, api, el: dom.window.document.getElementById('cicd-content') };
}

function renderFixture(name) {
    const env = loadImpl();
    env.api.render(fixture(name), env.el);
    return env;
}

function machineCard(env, name) { return env.el.querySelector('[data-cicd-machine="' + name + '"]'); }
function normText(node) { return (node.textContent || '').replace(/\s+/g, ' ').trim(); }
function squash(node) { return normText(node).replace(/,/g, ''); }
function offsetIso(generatedAt, seconds) {
    return new Date(Date.parse(generatedAt) - seconds * 1000).toISOString();
}
function mkMachine(over) {
    return Object.assign({
        machine: 'm', lastReportAt: '2026-10-02T16:59:30Z',
        vm: { name: 'v', status: 'Running', uptimeSeconds: 1 },
        runners: [{ name: 'r', os: 'Linux', service: 'online', busy: false, currentJob: null }],
        recentJobs: []
    }, over || {});
}

// ---- 0. vacuous-green guard ------------------------------------------------
test('guard: lcars-cicd.js exists and exposes the documented API', () => {
    assert.ok(fs.existsSync(CICD_JS), 'lcars-cicd.js must exist (suite must FAIL, not skip, without it)');
    const { api } = loadImpl();
    ['deriveMachineStatus', 'deriveRunnerStatus', 'render', 'renderUnavailable', 'refresh'].forEach(function (fn) {
        assert.equal(typeof api[fn], 'function', 'LCARSCICD.' + fn + ' must be a function');
    });
});

// ---- 1. pure status derivation --------------------------------------------
test('deriveMachineStatus: all four statuses from the fixtures', () => {
    const { api } = loadImpl();
    const derive = (name, mutate) => {
        const d = fixture(name);
        if (mutate) mutate(d);
        return api.deriveMachineStatus(d.machines[0], d.generatedAt, d.staleAfterSeconds, d.offlineAfterSeconds);
    };
    assert.equal(derive('healthy'), 'ONLINE');
    assert.equal(derive('stale'), 'STALE');
    assert.equal(derive('offline'), 'OFFLINE');
    assert.equal(derive('healthy', d => { d.machines[0].runners[1].service = 'offline'; }), 'DEGRADED');
    assert.equal(derive('healthy', d => { d.machines[0].runners[1].service = 'unknown'; }), 'DEGRADED');
    assert.equal(derive('healthy', d => { d.machines[0].vm.status = 'Stopped'; }), 'DEGRADED');
});

test('deriveMachineStatus: priority -- stale fixture has an offline runner but reads STALE', () => {
    const { api } = loadImpl();
    const d = fixture('stale');
    assert.ok(d.machines[0].runners.some(r => r.service === 'offline'), 'fixture precondition');
    assert.equal(api.deriveMachineStatus(d.machines[0], d.generatedAt, d.staleAfterSeconds, d.offlineAfterSeconds), 'STALE');
    // and an offline-aged machine with degraded runners is OFFLINE, not STALE/DEGRADED
    const o = fixture('offline');
    o.machines[0].runners[1].service = 'offline';
    assert.equal(api.deriveMachineStatus(o.machines[0], o.generatedAt, o.staleAfterSeconds, o.offlineAfterSeconds), 'OFFLINE');
});

test('deriveMachineStatus: boundaries are strictly greater-than', () => {
    const { api } = loadImpl();
    const gen = '2026-10-02T17:00:00Z';
    const at = (age) => api.deriveMachineStatus(mkMachine({ lastReportAt: offsetIso(gen, age) }), gen, 180, 600);
    assert.equal(at(0), 'ONLINE');
    assert.equal(at(180), 'ONLINE', 'age == staleAfterSeconds is NOT stale');
    assert.equal(at(181), 'STALE');
    assert.equal(at(600), 'STALE', 'age == offlineAfterSeconds is NOT offline');
    assert.equal(at(601), 'OFFLINE');
});

test('deriveMachineStatus: uses server timestamps only, never Date.now()', () => {
    const env = loadImpl();
    const realNow = Date.now;
    const far = Date.parse('2099-01-01T00:00:00Z');
    Date.now = () => far;
    env.window.Date.now = () => far;
    try {
        const d = fixture('healthy');
        assert.equal(env.api.deriveMachineStatus(d.machines[0], d.generatedAt, d.staleAfterSeconds, d.offlineAfterSeconds), 'ONLINE');
        env.api.render(d, env.el);
        assert.equal(machineCard(env, 'm1mini').getAttribute('data-cicd-status'), 'ONLINE');
    } finally {
        Date.now = realNow;
    }
});

test('deriveRunnerStatus: OFFLINE / UNKNOWN / BUSY / IDLE', () => {
    const { api } = loadImpl();
    assert.equal(api.deriveRunnerStatus({ service: 'offline', busy: false }), 'OFFLINE');
    assert.equal(api.deriveRunnerStatus({ service: 'unknown', busy: false }), 'UNKNOWN');
    assert.equal(api.deriveRunnerStatus({ service: 'online', busy: true }), 'BUSY');
    assert.equal(api.deriveRunnerStatus({ service: 'online', busy: false }), 'IDLE');
    assert.equal(api.deriveRunnerStatus({ service: 'offline', busy: true }), 'OFFLINE', 'service state outranks busy');
});

// ---- 2. empty --------------------------------------------------------------
test('render empty: empty state, no machine cards, summary dash, fallback UNKNOWN', () => {
    const env = renderFixture('empty');
    assert.ok(env.el.querySelector('[data-cicd-empty]'), 'empty state present');
    assert.equal(env.el.querySelectorAll('[data-cicd-machine]').length, 0);
    ['today', 'cycle'].forEach(function (k) {
        const tile = env.el.querySelector('[data-cicd-summary="' + k + '"]');
        assert.ok(tile, 'summary tile ' + k);
        assert.ok(normText(tile).includes('—'), k + ' tile shows em dash for null summary');
        assert.ok(!/\b0\b/.test(normText(tile).replace(/today|cycle/gi, '')), k + ' tile never shows 0 for null');
    });
    ['linux', 'macos'].forEach(function (k) {
        const f = env.el.querySelector('[data-cicd-fallback="' + k + '"]');
        assert.ok(f, 'fallback ' + k);
        assert.equal(f.getAttribute('data-cicd-state'), 'UNKNOWN');
    });
    assert.equal(env.el.querySelector('[data-cicd-unavailable]'), null);
});

// ---- 3. healthy ------------------------------------------------------------
test('render healthy: machine ONLINE with visible status text', () => {
    const env = renderFixture('healthy');
    assert.equal(env.el.querySelectorAll('[data-cicd-machine]').length, 1);
    const card = machineCard(env, 'm1mini');
    assert.equal(card.getAttribute('data-cicd-status'), 'ONLINE');
    assert.ok(/ONLINE/i.test(normText(card)), 'status is visible text, not colour only');
    assert.equal(env.el.querySelector('[data-cicd-empty]'), null);
});

test('render healthy: three runner rows with correct statuses, current-job link, null uptime dash', () => {
    const env = renderFixture('healthy');
    assert.equal(env.el.querySelectorAll('[data-cicd-runner]').length, 3);
    const l1 = env.el.querySelector('[data-cicd-runner="m1mini-linux-1"]');
    const l2 = env.el.querySelector('[data-cicd-runner="m1mini-linux-2"]');
    const m1 = env.el.querySelector('[data-cicd-runner="m1mini-macos-1"]');
    assert.equal(l1.getAttribute('data-cicd-status'), 'BUSY');
    assert.equal(l2.getAttribute('data-cicd-status'), 'IDLE');
    assert.equal(m1.getAttribute('data-cicd-status'), 'IDLE');
    assert.ok(/BUSY/i.test(normText(l1)) && /IDLE/i.test(normText(l2)), 'runner status visible as text');
    assert.ok(normText(l1).includes('shell-suite'), 'busy runner shows current workflow');
    const link = l1.querySelector('a[href^="https://github.com/"]');
    assert.ok(link, 'current job rendered as github link');
    assert.equal(link.getAttribute('target'), '_blank');
    assert.ok(/noopener/.test(link.getAttribute('rel')) && /noreferrer/.test(link.getAttribute('rel')));
    assert.ok(normText(m1).includes('—'), 'null uptime renders em dash');
});

test('render healthy: fallback indicators and summary numbers', () => {
    const env = renderFixture('healthy');
    assert.equal(env.el.querySelector('[data-cicd-fallback="linux"]').getAttribute('data-cicd-state'), 'SELF-HOSTED');
    assert.equal(env.el.querySelector('[data-cicd-fallback="macos"]').getAttribute('data-cicd-state'), 'HOSTED');
    const today = squash(env.el.querySelector('[data-cicd-summary="today"]'));
    const cycle = squash(env.el.querySelector('[data-cicd-summary="cycle"]'));
    ['42', '118', '208'].forEach(n => assert.ok(today.includes(n), 'today has ' + n + ': ' + today));
    ['611', '1740', '2950'].forEach(n => assert.ok(cycle.includes(n), 'cycle has ' + n + ': ' + cycle));
});

test('render healthy: recent jobs in a real table with scoped headers and safe links', () => {
    const env = renderFixture('healthy');
    const table = env.el.querySelector('table');
    assert.ok(table, 'recent jobs is a <table>');
    assert.ok(table.querySelector('thead'), 'has thead');
    const ths = table.querySelectorAll('th[scope="col"]');
    assert.ok(ths.length >= 3, 'column headers use th scope=col');
    const rows = env.el.querySelectorAll('[data-cicd-job]');
    assert.equal(rows.length, 3);
    ['51234560001', '51234560002', '51234560003'].forEach(id => {
        const row = env.el.querySelector('[data-cicd-job="' + id + '"]');
        assert.ok(row, 'job row ' + id);
        const a = row.querySelector('a[href^="https://github.com/"]');
        assert.ok(a, 'github link in row ' + id);
        assert.equal(a.getAttribute('target'), '_blank');
        const rel = a.getAttribute('rel') || '';
        assert.ok(/noopener/.test(rel) && /noreferrer/.test(rel), 'rel has noopener noreferrer');
    });
});

// ---- 4. stale + XSS --------------------------------------------------------
test('render stale: machine STALE', () => {
    const env = renderFixture('stale');
    assert.equal(machineCard(env, 'm1mini').getAttribute('data-cicd-status'), 'STALE');
    assert.ok(/STALE/i.test(normText(machineCard(env, 'm1mini'))));
});

test('render stale: XSS payloads are escaped, not parsed into elements', () => {
    const env = renderFixture('stale');
    assert.equal(env.el.querySelectorAll('img').length, 0, 'no <img> from branch payload');
    assert.equal(env.el.querySelectorAll('script').length, 0, 'no <script> from workflow payload');
    assert.equal(env.el.querySelectorAll('[onerror]').length, 0, 'no onerror attribute');
    const text = env.el.textContent;
    assert.ok(text.includes('<img src=x onerror=alert(1)>'), 'branch payload shown as literal text');
    assert.ok(text.includes('<script>alert("wf")</script>'), 'workflow payload shown as literal text');
});

test('render stale: javascript: and non-github URLs are never rendered as links', () => {
    const env = renderFixture('stale');
    env.el.querySelectorAll('a[href]').forEach(a => {
        const href = a.getAttribute('href');
        assert.ok(href.startsWith('https://github.com/'), 'only github https links allowed, found: ' + href);
    });
    assert.equal(env.el.querySelectorAll('a[href^="javascript:"]').length, 0);
    assert.equal(env.el.querySelectorAll('a[href*="evil.example"]').length, 0);
    const bad = env.el.querySelector('[data-cicd-job="51234560002"]');
    assert.ok(bad, 'row with hostile URLs still renders');
    assert.equal(bad.querySelectorAll('a[href]').length, 0, 'no links at all for the hostile row');
});

// ---- 5. offline ------------------------------------------------------------
test('render offline: machine OFFLINE, runner rows still render, linux fallback HOSTED', () => {
    const env = renderFixture('offline');
    assert.equal(machineCard(env, 'm1mini').getAttribute('data-cicd-status'), 'OFFLINE');
    assert.ok(/OFFLINE/i.test(normText(machineCard(env, 'm1mini'))), 'OFFLINE shown as text');
    assert.equal(env.el.querySelectorAll('[data-cicd-runner]').length, 3, 'runner rows rendered as last known');
    assert.equal(env.el.querySelector('[data-cicd-fallback="linux"]').getAttribute('data-cicd-state'), 'HOSTED');
    assert.equal(env.el.querySelector('[data-cicd-fallback="macos"]').getAttribute('data-cicd-state'), 'HOSTED');
});

// ---- 6. refresh() ----------------------------------------------------------
function jsonResponse(status, body) {
    return Promise.resolve({ ok: status >= 200 && status < 300, status, json: () => Promise.resolve(body), text: () => Promise.resolve(JSON.stringify(body)) });
}

test('refresh: 404 shows the unavailable state without throwing', async () => {
    const env = loadImpl();
    const urls = [];
    env.window.fetch = (u) => { urls.push(String(u)); return jsonResponse(404, {}); };
    await env.api.refresh();
    assert.ok(urls.some(u => u.includes('/api/ci-runners')), 'fetched /api/ci-runners: ' + urls.join(','));
    assert.ok(env.el.querySelector('[data-cicd-unavailable]'), 'unavailable state shown');
    assert.equal(env.el.querySelectorAll('[data-cicd-machine]').length, 0);
});

test('refresh: 200 renders machines into #cicd-content', async () => {
    const env = loadImpl();
    env.window.fetch = () => jsonResponse(200, fixture('healthy'));
    await env.api.refresh();
    assert.equal(machineCard(env, 'm1mini').getAttribute('data-cicd-status'), 'ONLINE');
    assert.equal(env.el.querySelector('[data-cicd-update-failed]'), null);
});

test('refresh: 5xx after a good render keeps machine cards and shows update-failed', async () => {
    const env = loadImpl();
    env.window.fetch = () => jsonResponse(200, fixture('healthy'));
    await env.api.refresh();
    env.window.fetch = () => jsonResponse(500, {});
    await env.api.refresh();
    assert.ok(machineCard(env, 'm1mini'), 'last good render preserved');
    assert.ok(env.el.querySelector('[data-cicd-update-failed]'), 'UPDATE FAILED badge shown');
    assert.ok(/UPDATE FAILED/i.test(env.el.textContent));
    // recovery clears the badge
    env.window.fetch = () => jsonResponse(200, fixture('healthy'));
    await env.api.refresh();
    assert.equal(env.el.querySelector('[data-cicd-update-failed]'), null, 'badge cleared on success');
});

test('refresh: network rejection never throws and keeps last render', async () => {
    const env = loadImpl();
    env.window.fetch = () => jsonResponse(200, fixture('healthy'));
    await env.api.refresh();
    env.window.fetch = () => Promise.reject(new TypeError('network down'));
    await assert.doesNotReject(() => Promise.resolve(env.api.refresh()));
    assert.ok(machineCard(env, 'm1mini'), 'last good render preserved');
    assert.ok(env.el.querySelector('[data-cicd-update-failed]'));
});

test('refresh: network rejection with no prior render still does not throw', async () => {
    const env = loadImpl();
    env.window.fetch = () => Promise.reject(new TypeError('network down'));
    await assert.doesNotReject(() => Promise.resolve(env.api.refresh()));
});

test('renderUnavailable: shows the unavailable state', () => {
    const env = loadImpl();
    env.api.renderUnavailable(env.el);
    assert.ok(env.el.querySelector('[data-cicd-unavailable]'));
});

// ---- 7. dashboard wiring smoke --------------------------------------------
test('dashboard wiring: sidebar button, section with #cicd-content, script tag', () => {
    const doc = new JSDOM(fs.readFileSync(DASHBOARD_HTML, 'utf8')).window.document;
    assert.ok(doc.querySelector('.sidebar-button[data-section="cicd"]'), 'sidebar button');
    const section = doc.querySelector('.lcars-section[data-section="cicd"]');
    assert.ok(section, 'section');
    assert.ok(section.querySelector('#cicd-content'), '#cicd-content inside section');
    assert.ok(doc.querySelector('script[src*="lcars-cicd.js"]'), 'lcars-cicd.js script tag');
});

// ---- 8. tightened (subitem 006) --------------------------------------------
test('render offline: EVERY runner row is last-known and keeps its last-known status (BUSY stays BUSY)', () => {
    const env = renderFixture('offline');
    const rows = env.el.querySelectorAll('[data-cicd-runner]');
    assert.equal(rows.length, 3);
    rows.forEach(function (row) {
        assert.equal(row.getAttribute('data-cicd-last-known'), 'true', 'row ' + row.getAttribute('data-cicd-runner') + ' must be last-known');
    });
    assert.equal(env.el.querySelector('[data-cicd-runner="m1mini-linux-1"]').getAttribute('data-cicd-status'), 'BUSY',
        'offline machine keeps the runner last-known BUSY status');
});

test('render healthy/stale: rows on ONLINE and STALE machines carry NO last-known marker', () => {
    ['healthy', 'stale'].forEach(function (name) {
        const env = renderFixture(name);
        assert.ok(env.el.querySelectorAll('[data-cicd-runner]').length > 0, name + ' has runner rows');
        assert.equal(env.el.querySelectorAll('[data-cicd-last-known]').length, 0, name + ': no data-cicd-last-known');
    });
});

test('refresh: UPDATE FAILED badge shows last-good time, and hostile generatedAt text cannot inject markup', async () => {
    const env = loadImpl();
    env.window.fetch = () => jsonResponse(200, fixture('healthy'));
    await env.api.refresh();
    env.window.fetch = () => jsonResponse(500, {});
    await env.api.refresh();
    const badge = env.el.querySelector('[data-cicd-slot="status"]');
    assert.ok(/last good: 17:00:00 UTC/.test(normText(badge)), 'last-good time shown: ' + normText(badge));

    // hostile generatedAt as the last good payload: extra text must stay inert
    const env2 = loadImpl();
    const hostile = fixture('healthy');
    hostile.generatedAt = '<img src=x onerror=alert(1)>';
    env2.api.render(hostile, env2.el);
    env2.window.fetch = () => jsonResponse(500, {});
    await env2.api.refresh();
    assert.ok(env2.el.querySelector('[data-cicd-update-failed]'));
    assert.equal(env2.el.querySelectorAll('img').length, 0, 'no <img> injected via badge text');
    assert.equal(env2.el.querySelectorAll('[onerror]').length, 0);
});

test('refresh: payload with missing/invalid schemaVersion is a failed fetch (last good kept + badge)', async () => {
    for (const bad of [undefined, null, 0, 'one', -1]) {
        const env = loadImpl();
        env.window.fetch = () => jsonResponse(200, fixture('healthy'));
        await env.api.refresh();
        const p = fixture('stale');
        if (bad === undefined) delete p.schemaVersion; else p.schemaVersion = bad;
        env.window.fetch = () => jsonResponse(200, p);
        await env.api.refresh();
        assert.equal(machineCard(env, 'm1mini').getAttribute('data-cicd-status'), 'ONLINE',
            'schemaVersion=' + String(bad) + ': last good (healthy) render kept, not replaced by stale payload');
        assert.ok(env.el.querySelector('[data-cicd-update-failed]'), 'badge shown for schemaVersion=' + String(bad));
    }
});

test('refresh: schemaVersion missing with NO prior render shows CI DATA UNAVAILABLE, no machines', async () => {
    const env = loadImpl();
    const p = fixture('healthy');
    delete p.schemaVersion;
    env.window.fetch = () => jsonResponse(200, p);
    await env.api.refresh();
    assert.equal(env.el.querySelectorAll('[data-cicd-machine]').length, 0);
    assert.ok(/CI DATA UNAVAILABLE/.test(env.el.textContent));
});

test('refresh: schemaVersion 2 payload still renders (forward compatible)', async () => {
    const env = loadImpl();
    const p = fixture('healthy');
    p.schemaVersion = 2;
    p.someFutureField = { x: 1 };
    env.window.fetch = () => jsonResponse(200, p);
    await env.api.refresh();
    assert.equal(machineCard(env, 'm1mini').getAttribute('data-cicd-status'), 'ONLINE');
    assert.equal(env.el.querySelector('[data-cicd-update-failed]'), null);
});

// ---- 9. round-1 gate findings (XACA-1388-012..018) --------------------------
const DASH_CSS = path.join(PUBLIC_ROOT, 'lcars', 'css', 'lcars-dashboards.css');
const THEME_CSS = path.join(PUBLIC_ROOT, 'lcars', 'css', 'lcars-fleet-theme.css');
const REPO_ROOT = path.join(__dirname, '..', '..', '..');

function busyJob(over) {
    return Object.assign({ id: 1, workflow: 'wf', job: 'jb', branch: 'b', startedAt: '2026-10-02T16:50:00Z',
        runUrl: 'https://github.com/o/r/actions/runs/1', jobUrl: 'https://github.com/o/r/actions/runs/1/job/2' }, over || {});
}

// 012: the runbook the empty state points at must really exist.
test('empty state: referenced runbook path exists in the repo (XACA-1388-012)', () => {
    const env = renderFixture('empty');
    const text = normText(env.el.querySelector('[data-cicd-empty]'));
    const refs = text.match(/docs\/[A-Za-z0-9_.\-]+\.md/g) || [];
    assert.ok(refs.length >= 1, 'empty state names a docs/*.md runbook: ' + text);
    refs.forEach(function (ref) {
        assert.ok(fs.existsSync(path.join(REPO_ROOT, ref)), 'referenced doc must exist: ' + ref);
    });
    assert.ok(!/CI_RUNNERS\.md/.test(text), 'stale pointer must be gone');
});

// 013: missing/unparseable generatedAt
test('deriveMachineStatus: unparseable generatedAt or lastReportAt is UNKNOWN, never OFFLINE (XACA-1388-013)', () => {
    const { api } = loadImpl();
    const gen = '2026-10-02T17:00:00Z';
    assert.equal(api.deriveMachineStatus(mkMachine(), undefined, 180, 600), 'UNKNOWN');
    assert.equal(api.deriveMachineStatus(mkMachine(), 'garbage', 180, 600), 'UNKNOWN');
    assert.equal(api.deriveMachineStatus(mkMachine({ lastReportAt: null }), gen, 180, 600), 'UNKNOWN');
    assert.equal(api.deriveMachineStatus(mkMachine({ lastReportAt: 'nope' }), gen, 180, 600), 'UNKNOWN');
});

test('render: machine with unparseable lastReportAt shows neutral UNKNOWN, not red OFFLINE (XACA-1388-013)', () => {
    const env = loadImpl();
    const d = fixture('healthy');
    d.machines[0].lastReportAt = 'not-a-date';
    env.api.render(d, env.el);
    const card = machineCard(env, 'm1mini');
    assert.equal(card.getAttribute('data-cicd-status'), 'UNKNOWN');
    assert.ok(/UNKNOWN/.test(normText(card)));
    assert.equal(card.querySelectorAll('.status-badge.offline').length, 0, 'no red OFFLINE badge');
    assert.equal(card.querySelectorAll('[data-cicd-last-known]').length, 0, 'rows are not dimmed as last-known');
});

test('refresh: payload with missing/unparseable generatedAt is a failed fetch (last good kept + badge) (XACA-1388-013)', async () => {
    for (const bad of [undefined, null, '', 'garbage', 12345]) {
        const env = loadImpl();
        env.window.fetch = () => jsonResponse(200, fixture('healthy'));
        await env.api.refresh();
        const p = fixture('stale');
        if (bad === undefined) delete p.generatedAt; else p.generatedAt = bad;
        env.window.fetch = () => jsonResponse(200, p);
        await env.api.refresh();
        assert.equal(machineCard(env, 'm1mini').getAttribute('data-cicd-status'), 'ONLINE', 'last good kept for ' + String(bad));
        assert.ok(env.el.querySelector('[data-cicd-update-failed]'), 'badge for generatedAt=' + String(bad));
    }
});

test('refresh: missing generatedAt with NO prior render shows CI DATA UNAVAILABLE, no machines (XACA-1388-013)', async () => {
    const env = loadImpl();
    const p = fixture('healthy');
    delete p.generatedAt;
    env.window.fetch = () => jsonResponse(200, p);
    await env.api.refresh();
    assert.equal(env.el.querySelectorAll('[data-cicd-machine]').length, 0);
    assert.ok(/CI DATA UNAVAILABLE/.test(env.el.textContent));
});

// 014: offline elapsed anchored to lastReportAt
test('render offline: last-known BUSY elapsed is anchored to lastReportAt, not generatedAt (XACA-1388-014)', () => {
    const env = loadImpl();
    const d = fixture('offline');
    // positive case: job started 100s before the machine's last report
    d.machines[0].runners[0].currentJob.startedAt = offsetIso(d.machines[0].lastReportAt, 100);
    env.api.render(d, env.el);
    const row = env.el.querySelector('[data-cicd-runner="m1mini-linux-1"]');
    assert.ok(/1m 40s/.test(normText(row)), 'elapsed = lastReportAt - startedAt: ' + normText(row));
    // and it does not grow when generatedAt moves on
    d.generatedAt = '2026-10-03T17:00:00Z';
    env.api.render(d, env.el);
    assert.ok(/1m 40s/.test(normText(env.el.querySelector('[data-cicd-runner="m1mini-linux-1"]'))), 'unchanged a day later');
});

test('render offline: startedAt after lastReportAt (shipped fixture) renders an em dash, never a negative/huge elapsed (XACA-1388-014)', () => {
    const d = fixture('offline');
    assert.ok(Date.parse(d.machines[0].runners[0].currentJob.startedAt) > Date.parse(d.machines[0].lastReportAt), 'fixture precondition');
    const env = renderFixture('offline');
    const job = env.el.querySelector('[data-cicd-runner="m1mini-linux-1"] .cicd-runner-job');
    assert.ok(job.querySelector('.cicd-val .cicd-null'), 'elapsed is the em dash');
    assert.ok(!/(^|\s)-\d/.test(normText(job)), 'no negative duration');
});

test('render healthy: BUSY elapsed on an ONLINE machine still uses generatedAt (XACA-1388-014)', () => {
    const env = renderFixture('healthy');
    const row = env.el.querySelector('[data-cicd-status="BUSY"]');
    assert.ok(row && row.querySelector('.cicd-val') && !row.querySelector('.cicd-val .cicd-null'), 'healthy busy row has a real elapsed');
});

// 015: degraded wording
test('degradedReasons wording: offline vs unknown runner (XACA-1388-015)', () => {
    const noteOf = (svc) => {
        const env = loadImpl();
        const d = fixture('healthy');
        d.machines[0].runners[1].service = svc;
        env.api.render(d, env.el);
        const card = machineCard(env, 'm1mini');
        assert.equal(card.getAttribute('data-cicd-status'), 'DEGRADED');
        return normText(card.querySelector('.cicd-stale-note'));
    };
    assert.equal(noteOf('offline'), 'runner offline');
    assert.equal(noteOf('unknown'), 'runner status unknown');
    assert.equal(noteOf(null), 'runner status unknown');
    // both present -> both reasons, each once
    const env = loadImpl();
    const d = fixture('healthy');
    d.machines[0].runners[0].service = 'offline';
    d.machines[0].runners[1].service = 'unknown';
    d.machines[0].runners[2].service = 'offline';
    env.api.render(d, env.el);
    assert.equal(normText(machineCard(env, 'm1mini').querySelector('.cicd-stale-note')), 'runner offline, runner status unknown');
});

// 016: focus keys
test('focus keys: same runner name on two machines gets distinct keys and focus survives re-render (XACA-1388-016)', () => {
    const env = loadImpl();
    const mk = (machine) => mkMachine({ machine, runners: [{ name: 'runner-1', os: 'Linux', service: 'online', busy: true, currentJob: busyJob() }] });
    const d = { schemaVersion: 1, generatedAt: '2026-10-02T17:00:00Z', machines: [mk('alpha'), mk('beta')] };
    env.api.render(d, env.el);
    const keys = Array.from(env.el.querySelectorAll('.cicd-runner-job [data-cicd-focus]')).map(n => n.getAttribute('data-cicd-focus'));
    assert.equal(keys.length, 2);
    assert.equal(new Set(keys).size, 2, 'keys are unique across machines: ' + keys.join(','));
    assert.ok(keys.every(k => /alpha|beta/.test(k)), 'machine is part of the key');
    const second = env.el.querySelectorAll('.cicd-runner-job a')[1];
    second.focus();
    assert.equal(env.document.activeElement, second);
    env.api.render(d, env.el);
    const active = env.document.activeElement;
    assert.equal(active.getAttribute('data-cicd-focus'), keys[1]);
    assert.equal(active.closest('[data-cicd-machine]').getAttribute('data-cicd-machine'), 'beta', 'focus stays on beta, not alpha');
});

test('focus keys: id-less jobs fall back to row index, never "job:undefined" (XACA-1388-016)', () => {
    const env = loadImpl();
    const mkJob = (t) => { const j = busyJob({ startedAt: t, runUrl: 'https://github.com/o/r/actions/runs/9' }); delete j.id; delete j.jobUrl; return j; };
    const d = { schemaVersion: 1, generatedAt: '2026-10-02T17:00:00Z',
        machines: [mkMachine({ recentJobs: [mkJob('2026-10-02T16:00:00Z'), mkJob('2026-10-02T16:10:00Z')] })] };
    env.api.render(d, env.el);
    const links = env.el.querySelectorAll('.cicd-jobs a[data-cicd-focus]');
    assert.equal(links.length, 2);
    const keys = Array.from(links).map(n => n.getAttribute('data-cicd-focus'));
    assert.ok(keys.every(k => !/undefined/.test(k)), 'no undefined key: ' + keys.join(','));
    assert.equal(new Set(keys).size, 2, 'keys unique');
    links[1].focus();
    env.api.render(d, env.el);
    assert.equal(env.document.activeElement.getAttribute('data-cicd-focus'), keys[1], 'focus restored to the second id-less job');
});

// Minimal CSS reader: flat list of {sel:[...], decls:{}, media:string|null}; one @media level is walked.
function cssRules(text) {
    text = text.replace(/\/\*[\s\S]*?\*\//g, '');
    const out = [];
    (function walk(src, media) {
        let i = 0;
        while (i < src.length) {
            const o = src.indexOf('{', i);
            if (o < 0) break;
            const head = src.slice(i, o).trim();
            let depth = 1, j = o + 1;
            while (j < src.length && depth) { if (src[j] === '{') depth++; else if (src[j] === '}') depth--; j++; }
            const body = src.slice(o + 1, j - 1);
            if (/^@media/.test(head)) walk(body, head);
            else if (!/^@/.test(head)) {
                const decls = {};
                body.split(';').forEach(function (d) {
                    const k = d.indexOf(':');
                    if (k > 0) decls[d.slice(0, k).trim()] = d.slice(k + 1).trim();
                });
                out.push({ sel: head.split(',').map(s => s.trim().replace(/\s+/g, ' ')), decls, media });
            }
            i = j;
        }
    })(text, null);
    return out;
}

// 018: narrow viewport labels + a11y header
test('narrow viewport: cells carry data-label, header row stays in the a11y tree (XACA-1388-018)', () => {
    const env = renderFixture('healthy');
    const rows = env.el.querySelectorAll('[data-cicd-runner]');
    assert.ok(rows.length > 0);
    rows.forEach(function (row) {
        const labels = Array.from(row.querySelectorAll('[role="cell"]')).map(c => c.getAttribute('data-label'));
        assert.deepEqual(labels, ['RUNNER', 'OS', 'STATUS', 'UPTIME', 'CURRENT JOB / ELAPSED']);
    });
    assert.equal(env.el.querySelectorAll('[role="columnheader"]').length, 5);

    const rules = cssRules(fs.readFileSync(DASH_CSS, 'utf8'));
    const narrow = rules.filter(r => r.media && /max-width:\s*600px/.test(r.media));
    const head = narrow.filter(r => r.sel.includes('.cicd-runner-head'));
    assert.ok(head.length > 0, 'narrow rule for the header row exists');
    head.forEach(r => assert.notEqual(r.decls.display, 'none', 'header row must not be display:none'));
    assert.ok(head.some(r => r.decls.position === 'absolute' && r.decls.clip), 'visually hidden via the sr-only pattern');
    const lbl = narrow.find(r => r.sel.some(s => /\.cicd-runner \[data-label\]::before/.test(s)));
    assert.ok(lbl && /attr\(data-label\)/.test(lbl.decls.content), 'inline label via ::before attr(data-label)');
    rules.filter(r => r.sel.some(s => /cicd-runner-head|columnheader/.test(s))).forEach(r => assert.notEqual(r.decls.display, 'none'));
});

// 017: table-driven WCAG contrast of the dimmed OFFLINE-machine runner row ---
function hexToRgb(h) {
    const m = /^#([0-9a-f]{6})$/i.exec(h);
    if (!m) throw new Error('not a #rrggbb colour: ' + h);
    return [0, 2, 4].map(i => parseInt(m[1].slice(i, i + 2), 16));
}
function relLum(rgb) {
    const [r, g, b] = rgb.map(v => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); });
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}
function contrast(a, b) {
    const [hi, lo] = [relLum(a), relLum(b)].sort((x, y) => y - x);
    return (hi + 0.05) / (lo + 0.05);
}
function mix(fg, bg, a) { return fg.map((v, i) => a * v + (1 - a) * bg[i]); }

// Resolve `prop` for an ordered list of selectors (later entry = higher cascade
// priority); within one selector the last matching declaration in the file wins.
function resolveProp(rules, selectors, prop) {
    let val = null;
    selectors.forEach(function (sel) {
        rules.filter(r => !r.media && r.sel.includes(sel) && r.decls[prop] !== undefined).forEach(r => { val = r.decls[prop]; });
    });
    if (val === null) throw new Error('no ' + prop + ' for ' + selectors.join(' | '));
    return val;
}
function resolveColor(val, tokens) {
    let m;
    while ((m = /^var\((--[\w-]+)\)$/.exec(val))) {
        if (!(m[1] in tokens)) throw new Error('unknown token ' + m[1]);
        val = tokens[m[1]];
    }
    return hexToRgb(val);
}

// Variant table: [name, fg selectors (cascade order), bg selectors or null (= row bg), bg prop].
const DIMMED_VARIANTS = [
    ['OFFLINE badge',            ['.status-badge', '.status-badge.offline'], ['.status-badge.offline'], 'background'],
    ['IDLE badge',               ['.status-badge', '.status-badge.idle'],    ['.status-badge.idle'], 'background'],
    ['BUSY badge',               ['.status-badge', '.status-badge.online'],  ['.status-badge.online'], 'background'],
    ['name/OS/uptime text',      ['.cicd-runner', '.cicd-runner.dimmed'],    null],
    ['.cicd-sub (last known)',   ['.cicd-sub', '.cicd-runner.dimmed .cicd-sub'], null],
    ['.cicd-null em dash',       ['.cicd-null', '.cicd-runner.dimmed .cicd-null'], null],
    ['.cicd-val elapsed',        ['.cicd-val', '.cicd-runner.dimmed .cicd-val'], null],
    ['LOG link',                 ['.cicd-link'], null],
    ['narrow inline label',      ['.cicd-runner [data-label]::before'], null]
];

function dimmedRowContrast(dashCss, themeCss) {
    const theme = cssRules(themeCss);
    const tokens = {};
    theme.filter(r => !r.media && r.sel.includes(':root')).forEach(r => Object.assign(tokens, r.decls));
    // The ::before label rule lives inside the narrow @media; treat it as unconditional here.
    const flat = cssRules(dashCss).map(r => Object.assign({}, r, { media: r.media && /max-width:\s*600px/.test(r.media) ? null : r.media }));
    const all = theme.concat(flat);
    const dimRule = flat.filter(r => r.sel.includes('.cicd-runner.dimmed') && r.decls.opacity !== undefined).pop();
    const op = dimRule ? parseFloat(dimRule.decls.opacity) : 1;
    const card = resolveColor(resolveProp(all, ['.cicd-machine'], 'background'), tokens);
    const rowBg = resolveColor(resolveProp(all, ['.cicd-runner'], 'background'), tokens);
    return DIMMED_VARIANTS.map(function (v) {
        const fg = resolveColor(resolveProp(all, v[1], 'color'), tokens);
        const bg = v[2] ? resolveColor(resolveProp(all, v[2], v[3]), tokens) : rowBg;
        // Group opacity composites glyph pixels AND background pixels with what is behind the row.
        const ratio = contrast(mix(fg, card, op), mix(bg, card, op));
        return { name: v[0], ratio, pass: ratio >= 4.5 };
    });
}

test('contrast math sanity: black/white 21:1, identical 1:1', () => {
    assert.ok(Math.abs(contrast([0, 0, 0], [255, 255, 255]) - 21) < 1e-9);
    assert.ok(Math.abs(contrast([10, 20, 30], [10, 20, 30]) - 1) < 1e-9);
});

test('dimmed OFFLINE-machine runner row: every text variant is >= 4.5:1 (WCAG 1.4.3) (XACA-1388-017)', () => {
    const results = dimmedRowContrast(fs.readFileSync(DASH_CSS, 'utf8'), fs.readFileSync(THEME_CSS, 'utf8'));
    assert.equal(results.length, DIMMED_VARIANTS.length);
    results.forEach(r => assert.ok(r.pass, r.name + ' = ' + r.ratio.toFixed(2) + ':1 (< 4.5)'));
    console.log('CONTRAST ' + results.map(r => r.name + '=' + r.ratio.toFixed(2)).join(' | '));
});

test('dimmed row contrast checker NEGATIVE CONTROL: reintroducing opacity:0.65 fails the OFFLINE and IDLE badges (XACA-1388-017)', () => {
    const css = fs.readFileSync(DASH_CSS, 'utf8') + '\n.cicd-runner.dimmed { opacity: 0.65; }\n';
    const results = dimmedRowContrast(css, fs.readFileSync(THEME_CSS, 'utf8'));
    const by = Object.fromEntries(results.map(r => [r.name, r]));
    assert.equal(by['OFFLINE badge'].pass, false, 'OFFLINE badge must fail under opacity: ' + by['OFFLINE badge'].ratio.toFixed(2));
    assert.ok(Math.abs(by['OFFLINE badge'].ratio - 3.74) < 0.1, 'matches the measured 3.74:1: ' + by['OFFLINE badge'].ratio.toFixed(2));
    assert.equal(by['IDLE badge'].pass, false);
    assert.ok(results.some(r => !r.pass));
});

test('dimmed row contrast checker NEGATIVE CONTROL: a known low-contrast colour token fails (XACA-1388-017)', () => {
    const css = fs.readFileSync(DASH_CSS, 'utf8') + '\n.cicd-runner.dimmed { color: var(--lcars-dark); }\n';
    const results = dimmedRowContrast(css, fs.readFileSync(THEME_CSS, 'utf8'));
    assert.equal(results.find(r => r.name === 'name/OS/uptime text').pass, false);
});

test('dimmed rows: no group opacity anywhere on .cicd-runner (XACA-1388-017)', () => {
    cssRules(fs.readFileSync(DASH_CSS, 'utf8')).filter(r => r.sel.some(s => /^\.cicd-runner(\.dimmed)?$/.test(s)))
        .forEach(r => assert.equal(r.decls.opacity, undefined, 'opacity on ' + r.sel.join(',')));
});

test('not-reported dash: no aria-label on role-less elements; meaning carried by sr-only text (XACA-1388-020)', () => {
    const env = renderFixture('empty');
    const nulls = env.el.querySelectorAll('.cicd-null');
    assert.ok(nulls.length > 0, 'empty fixture renders at least one not-reported dash');
    nulls.forEach(n => {
        assert.equal(n.hasAttribute('aria-label'), false, 'role-less .cicd-null must not carry aria-label');
        assert.equal(n.querySelector('[aria-hidden="true"]').textContent, '—');
        assert.equal(n.querySelector('.cicd-sr-only').textContent, 'not reported');
    });
    env.el.querySelectorAll('span[aria-label]:not([role])').forEach(s =>
        assert.fail('role-less span with aria-label: ' + s.outerHTML));
});
