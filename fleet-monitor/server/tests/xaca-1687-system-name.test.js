//
//  xaca-1687-system-name.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1687-007: reporter-supplied machine.system_name.
 *
 *   - POST /api/status stores a sanitized system_name; a report WITHOUT the
 *     key keeps the stored one; an empty value clears it; nickname is never
 *     touched by either.
 *   - Label precedence everywhere: nickname || system_name || hostname.
 *   - MACHINES cards (v1 createMachineItem + lcars2 core) render the system
 *     name as primary with hostname secondary, escaped, and are byte-
 *     identical to the pre-XACA-1687 markup when system_name is absent.
 *
 * server.js cannot be require()d (app.listen() at import), so route tests run
 * against tests/helpers/app-factory.js's mirror. The DRIFT GUARD group below
 * proves the mirrored sanitizer + ingest rule are identical to server.js,
 * and statically pins the server's label expressions.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { JSDOM } = require('jsdom');
const request = require('./helpers/loopback-request');
const { createApp, helpers } = require('./helpers/app-factory.js');
const { extractBlock, normalizeBody } = require('./helpers/mirror-drift');
const { CREATE_MACHINE_ITEM_EXPORT_PROPERTY } = require('./helpers/lcars-client-dom-stub');

const GUID = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeee1687';
const SERVER_JS = fs.readFileSync(path.join(__dirname, '..', 'server.js'), 'utf8');
const FACTORY_JS = fs.readFileSync(path.join(__dirname, 'helpers', 'app-factory.js'), 'utf8');
const PUBLIC_ROOT = path.join(__dirname, '..', 'public');

function report(app, machineExtra) {
    return request(app).post('/api/status').send({
        machine: Object.assign({ machine_id: GUID, hostname: 'ai-sol.local', ip: '10.0.0.9', os: 'macOS' }, machineExtra),
        sessions: []
    });
}

async function listEntry(app) {
    const res = await request(app).get('/api/machines/list');
    assert.equal(res.status, 200);
    return res.body.machines.find((m) => m.machine_id === GUID);
}

async function fleetEntry(app) {
    const res = await request(app).get('/api/fleet');
    assert.equal(res.status, 200);
    return res.body.fleet.machines.find((m) => m.machine_id === GUID);
}

// ── ingest ───────────────────────────────────────────────────────────────

test('POST /api/status stores system_name and exposes it on /api/fleet and /api/machines/list', async () => {
    const machines = new Map();
    const { app } = createApp({ machines });
    assert.equal((await report(app, { system_name: 'Sol' })).status, 200);
    assert.equal(machines.get(GUID).system_name, 'Sol');
    assert.equal((await fleetEntry(app)).system_name, 'Sol');
    const entry = await listEntry(app);
    assert.equal(entry.system_name, 'Sol');
    assert.equal(entry.display_name, 'Sol');
});

test('old reporter (no system_name key) -> system_name null, label falls back to hostname', async () => {
    const machines = new Map();
    const { app } = createApp({ machines });
    await report(app, {});
    assert.equal(machines.get(GUID).system_name, null);
    assert.equal((await fleetEntry(app)).system_name, null);
    assert.equal((await listEntry(app)).display_name, 'ai-sol.local');
});

test('report WITHOUT system_name keeps stored system_name and nickname', async () => {
    const machines = new Map();
    const { app } = createApp({ machines });
    await report(app, { system_name: 'Sol' });
    await request(app).put('/api/machine/' + GUID + '/nickname').send({ nickname: 'Bridge' });
    await report(app, {});
    assert.equal(machines.get(GUID).nickname, 'Bridge');
    assert.equal(machines.get(GUID).system_name, 'Sol');
});

test('empty system_name clears system_name but never the nickname', async () => {
    const machines = new Map();
    const { app } = createApp({ machines });
    await report(app, { system_name: 'Sol' });
    await request(app).put('/api/machine/' + GUID + '/nickname').send({ nickname: 'Bridge' });
    await report(app, { system_name: '' });
    assert.equal(machines.get(GUID).system_name, null);
    assert.equal(machines.get(GUID).nickname, 'Bridge');
});

test('non-string system_name (number/object/null) is treated as cleared, never stored', async () => {
    for (const bad of [42, { a: 1 }, null, ['x']]) {
        const machines = new Map();
        const { app } = createApp({ machines });
        await report(app, { system_name: 'Sol' });
        assert.equal((await report(app, { system_name: bad })).status, 200);
        assert.equal(machines.get(GUID).system_name, null, JSON.stringify(bad));
    }
});

// ── precedence ───────────────────────────────────────────────────────────

test('precedence: nickname set -> nickname; cleared -> system_name; no system_name -> hostname', async () => {
    const machines = new Map();
    const { app } = createApp({ machines });
    await report(app, { system_name: 'Sol' });
    await request(app).put('/api/machine/' + GUID + '/nickname').send({ nickname: 'Bridge' });
    assert.equal((await listEntry(app)).display_name, 'Bridge');
    await request(app).put('/api/machine/' + GUID + '/nickname').send({ nickname: '' });
    assert.equal((await listEntry(app)).display_name, 'Sol');
    await report(app, { system_name: '' });
    assert.equal((await listEntry(app)).display_name, 'ai-sol.local');
});

// ── sanitizer ────────────────────────────────────────────────────────────

test('sanitizeSystemName: trims, strips C0/C1 control chars, caps at 64', () => {
    const s = helpers.sanitizeSystemName;
    assert.equal(s('  Sol  '), 'Sol');
    assert.equal(s('So\u0000l\n\t\r\u001b[31m\u007f\u0085'), 'Sol[31m');
    assert.equal(s('x'.repeat(200)).length, 64);
    assert.equal(s('   '), null);
    assert.equal(s('\u0001\u0002'), null);
    assert.equal(s(''), null);
    assert.equal(s(undefined), null);
    assert.equal(s(7), null);
    // cap then re-trim: no trailing space left behind by the cut
    assert.equal(s('a'.repeat(63) + ' b'), 'a'.repeat(63));
    // markup is NOT the sanitizer's job (that is escapeHtml at render) -- kept verbatim
    assert.equal(s('<script>alert(1)</script>'), '<script>alert(1)</script>');
});

test('overlong / control-char system_name is sanitized at ingest', async () => {
    const machines = new Map();
    const { app } = createApp({ machines });
    await report(app, { system_name: '\u0007Sol\u0000' + 'y'.repeat(100) });
    const stored = machines.get(GUID).system_name;
    assert.equal(stored.length, 64);
    assert.ok(stored.startsWith('Soly'));
    assert.ok(!/[\u0000-\u001F\u007F-\u009F]/.test(stored));
});

// ── drift guard: server.js <-> app-factory.js ────────────────────────────

test('DRIFT GUARD: sanitizeSystemName body identical in server.js and app-factory.js', () => {
    const a = normalizeBody(extractBlock(SERVER_JS, /function sanitizeSystemName\(/));
    const b = normalizeBody(extractBlock(FACTORY_JS, /function sanitizeSystemName\(/));
    assert.ok(a.includes('SYSTEM_NAME_MAX'), 'extracted something real');
    assert.equal(a, b);
    assert.match(SERVER_JS, /^const SYSTEM_NAME_MAX = 64;$/m);
    assert.match(FACTORY_JS, /^const SYSTEM_NAME_MAX = 64;$/m);
});

test('DRIFT GUARD: POST /api/status system_name ingest rule identical', () => {
    const re = /const systemName = [^;]+;/;
    const a = SERVER_JS.match(re);
    const b = FACTORY_JS.match(re);
    assert.ok(a && b, 'both files carry the ingest statement');
    const norm = (s) => s.replace(/\s+/g, ' ');
    assert.equal(norm(a[0]), norm(b[0]));
    assert.match(a[0], /hasOwnProperty\.call\(machine, 'system_name'\)/);
});

test('DRIFT GUARD (static): server.js label sites use nickname || system_name || hostname', () => {
    assert.ok(SERVER_JS.includes('label: data.nickname || data.system_name || data.hostname || hostname,'));
    assert.ok(SERVER_JS.includes('label: existingNickname || systemName || machine.hostname,'));
    assert.ok(SERVER_JS.includes('display_name: m.nickname || m.system_name || m.hostname,'));
    assert.ok(SERVER_JS.includes('system_name: m.system_name || null,'));
    assert.ok(!/nickname \|\| [a-zA-Z.]*hostname/.test(SERVER_JS), 'no label site skips system_name');
});

test('UI (static): no remaining nickname || hostname shortcut in LCARS label code', () => {
    const files = [
        'lcars/js/lcars-dashboard-app.js',
        'lcars/js/lcars-accessories.js',
        'lcars/js/lcars-analytics-fleet.js',
        'lcars/js/lcars-dashboards-ui.js',
        'lcars2/js/lcars-fleet-dashboard-app.js'
    ];
    for (const rel of files) {
        const src = fs.readFileSync(path.join(PUBLIC_ROOT, rel), 'utf8');
        assert.ok(!/nickname \|\| [a-zA-Z]+\.hostname/.test(src), rel + ' still skips system_name');
        assert.ok(src.includes('system_name'), rel + ' references system_name');
    }
});

// ── card rendering (jsdom) ───────────────────────────────────────────────

async function setupApp(relPath) {
    const dom = new JSDOM('<!doctype html><html><body><div id="machine-status-list"></div></body></html>', {
        url: 'http://lcars-test.local/' + relPath,
        runScripts: 'outside-only',
        pretendToBeVisual: true
    });
    const window = dom.window;
    await new Promise((resolve) => {
        if (window.document.readyState === 'complete') { resolve(); return; }
        window.addEventListener('load', () => resolve(), { once: true });
    });
    const ctx = dom.getInternalVMContext();
    // lcars2 module expects its per-org config first (same as sibling suites).
    const cfg = path.join(PUBLIC_ROOT, 'lcars2/js/lcars-academy-config.js');
    if (relPath.startsWith('lcars2/') && fs.existsSync(cfg)) vm.runInContext(fs.readFileSync(cfg, 'utf8'), ctx);
    vm.runInContext(fs.readFileSync(path.join(PUBLIC_ROOT, 'lcars2/js/lcars-fleet-core.js'), 'utf8'), ctx);
    const src = fs.readFileSync(path.join(PUBLIC_ROOT, relPath), 'utf8');
    const idx = src.lastIndexOf('})();');
    if (idx === -1) throw new Error('closing IIFE not found in ' + relPath);
    const patched = src.slice(0, idx) +
        '\n    window.__lcarsTestExports = { ' + CREATE_MACHINE_ITEM_EXPORT_PROPERTY + ' };\n' + src.slice(idx);
    vm.runInContext(patched, ctx, { filename: relPath });
    return { window, mod: window.__lcarsTestExports };
}

function machine(extra) {
    return Object.assign({ machine_id: GUID, hostname: 'ai-sol.local', status: 'online', session_count: 2 }, extra);
}

function asRoot(node, window) {
    const wrap = window.document.createElement('div');
    wrap.appendChild(node);
    return wrap;
}

const CARD_TARGETS = [
    { label: 'v1 lcars-dashboard-app', rel: 'lcars/js/lcars-dashboard-app.js', primary: '.machine-hostname', secondary: '.machine-hostname-secondary' },
    { label: 'lcars2 core status-row', rel: 'lcars2/js/lcars-fleet-dashboard-app.js', primary: '.status-row-hostname', secondary: '.status-row-hostname-secondary' }
];

for (const t of CARD_TARGETS) {
    test(t.label + ': system name primary, hostname secondary', async () => {
        const { window, mod } = await setupApp(t.rel);
        const root = asRoot(mod.createMachineItem(machine({ system_name: 'Sol' })), window);
        const primary = root.querySelector(t.primary);
        const secondary = root.querySelector(t.secondary);
        assert.ok(primary && secondary);
        assert.equal(primary.firstChild.nodeValue, 'Sol');
        assert.equal(secondary.textContent, 'ai-sol.local');
    });

    test(t.label + ': no system_name -> hostname only, no secondary span (pre-XACA-1687 markup)', async () => {
        const { window, mod } = await setupApp(t.rel);
        const root = asRoot(mod.createMachineItem(machine({})), window);
        assert.equal(root.querySelector(t.primary).innerHTML, 'ai-sol.local');
        assert.equal(root.querySelector(t.secondary), null);
        const same = asRoot(mod.createMachineItem(machine({ system_name: 'ai-sol.local' })), window);
        assert.equal(same.querySelector(t.secondary), null, 'identical names render once');
        // 026: same rule as statusline/tmux -- names differing only by case render once.
        const cased = asRoot(mod.createMachineItem(machine({ system_name: 'AI-Sol.Local' })), window);
        assert.equal(cased.querySelector(t.secondary), null, 'case-only difference renders once');
        assert.equal(cased.querySelector(t.primary).innerHTML, 'ai-sol.local', 'falls back to the plain hostname markup');
    });

    test(t.label + ': (022) screen readers hear a separator between system name and hostname', async () => {
        const { window, mod } = await setupApp(t.rel);
        const root = asRoot(mod.createMachineItem(machine({ system_name: 'Sol' })), window);
        const primary = root.querySelector(t.primary);
        // textContent is what the accessibility tree reads: never "Solai-sol.local".
        assert.equal(primary.textContent.replace(/\s+/g, ' ').trim(), 'Sol \u00b7 ai-sol.local');
        const sep = primary.querySelector('.visually-hidden');
        assert.ok(sep, 'separator is a visually-hidden span');
        assert.equal(sep.textContent.trim(), '\u00b7');
        assert.equal(sep.nextElementSibling && sep.nextElementSibling.matches(t.secondary), true,
            'separator sits immediately before the secondary hostname');
        const plain = asRoot(mod.createMachineItem(machine({})), window);
        assert.equal(plain.querySelector('.visually-hidden'), null, 'no separator without a system name');
    });

    test(t.label + ': XSS -- <script> in system_name/hostname renders as text', async () => {
        const { window, mod } = await setupApp(t.rel);
        const evil = '<script>window.__pwned=1</script><img src=x onerror="window.__pwned=2">';
        const root = asRoot(mod.createMachineItem(machine({ system_name: evil, hostname: '<b>h</b>' })), window);
        assert.equal(root.querySelector('script'), null);
        assert.equal(root.querySelector('img'), null);
        assert.equal(root.querySelector('b'), null);
        assert.equal(root.querySelector(t.primary).firstChild.nodeValue, evil);
        assert.equal(root.querySelector(t.secondary).textContent, '<b>h</b>');
        assert.equal(window.__pwned, undefined);
    });
}

// ── XACA-1687 gate round 1 (PR #1376) ────────────────────────────────────

test('sanitizeSystemName: strips invisible bidi / zero-width format chars (label spoofing)', () => {
    const s = helpers.sanitizeSystemName;
    // RLO-reversed and zero-width-padded variants must collapse to the plain text
    assert.equal(s('‮Sol‬'), 'Sol');
    assert.equal(s('S​o‍l﻿'), 'Sol');
    assert.equal(s('⁦Vulcan⁩‎‏؜'), 'Vulcan');
    assert.equal(s('⁠⁡⁢⁣⁤'), null);
    // ordinary non-ASCII names survive
    assert.equal(s("Qo'noS"), "Qo'noS");
    assert.equal(s('Rio Grande'), 'Rio Grande');
});

test('sanitizeSystemName: 64-cap counts code points and never splits a surrogate pair', () => {
    const s = helpers.sanitizeSystemName;
    const out = s('a'.repeat(63) + '\u{1F596}' + 'zzz'); // 🖖 is a surrogate pair
    assert.equal(Array.from(out).length, 64);
    assert.ok(out.endsWith('\u{1F596}'), 'emoji kept whole at the cut');
    assert.ok(!/[\uD800-\uDBFF]$/.test(out), 'no dangling high surrogate');
});

test('UX GUARD (016): every self-coloured class in the v1 machine-row header has an offline override', () => {
    const js = fs.readFileSync(path.join(__dirname, '..', 'public', 'lcars', 'js', 'lcars-dashboard-app.js'), 'utf8');
    const css = fs.readFileSync(path.join(__dirname, '..', 'public', 'lcars', 'css', 'lcars-fleet-theme.css'), 'utf8');
    // Markup that ends up inside .machine-row-header: the header block itself,
    // the hostnameHtml it embeds, and displayStatus.labelHtml.
    const start = js.indexOf('\'<div class="machine-row-header">\'');
    assert.ok(start > 0, 'header markup located');
    const header = js.slice(start, js.indexOf("'</div>'", start));
    const hostStmt = (js.match(/const hostnameHtml = [\s\S]*?;\n/) || [''])[0];
    const labelHtml = (js.match(/labelHtml: '[^\n]*/g) || []).join('\n');
    assert.ok(hostStmt.includes('machine-hostname-secondary'), 'hostnameHtml carries the secondary span');
    const classes = new Set();
    for (const m of (header + hostStmt + labelHtml).matchAll(/class="([a-z][\w-]*)/g)) classes.add(m[1]);
    assert.ok(classes.size >= 4, 'found the header classes: ' + [...classes].join(','));
    // Classes that can never render on an offline card. machine-power-label:
    // machineDisplayStatus() gives offline precedence over on_battery and returns
    // labelHtml '' for offline, so the label only ever sits on a dark row.
    const NEVER_OFFLINE = new Set(['machine-power-label']);
    assert.match(js, /cls = okCls\(raw\) \|\| okCls\(machine\.status\) \|\| 'offline';\s*return \{ cls: cls, labelHtml: '' \}/,
        'exemption premise: the offline path renders no power label');
    const offenders = [];
    for (const cls of classes) {
        if (NEVER_OFFLINE.has(cls)) continue;
        // base rule for exactly this class that sets its own text colour
        const base = new RegExp('(^|\\n)\\.' + cls + '\\s*\\{[^}]*\\bcolor\\s*:', 'm');
        if (!base.test(css)) continue;
        const override = new RegExp('\\.machine-row\\.offline\\s+\\.' + cls + '\\b[^{]*\\{[^}]*\\bcolor\\s*:|\\.machine-row\\.offline\\s+\\.' + cls + '\\s*,');
        if (!override.test(css)) offenders.push(cls);
    }
    assert.deepEqual(offenders, [], 'classes rendered on the alert-red offline card with no black-text override');
});

test('UX (022): .visually-hidden is defined (never display:none) in the stylesheet each card UI loads', () => {
    for (const rel of ['lcars/css/lcars-fleet.css', 'lcars2/css/lcars-fleet.css']) {
        const css = fs.readFileSync(path.join(PUBLIC_ROOT, rel), 'utf8');
        const rule = (css.match(/(^|\n)\.visually-hidden\s*\{([^}]*)\}/) || [])[2];
        assert.ok(rule, rel + ' defines .visually-hidden');
        assert.match(rule, /clip\s*:\s*rect\(0,\s*0,\s*0,\s*0\)/, rel + ': clipped, still in the a11y tree');
        assert.doesNotMatch(rule, /display\s*:\s*none|visibility\s*:\s*hidden/, rel + ': must stay readable');
    }
    for (const html of ['lcars/lcars-dashboard.html', 'lcars2/lcars-doublenode.html']) {
        const src = fs.readFileSync(path.join(PUBLIC_ROOT, html), 'utf8');
        assert.match(src, /href="css\/lcars-fleet\.css/, html + ' loads lcars-fleet.css');
    }
});
