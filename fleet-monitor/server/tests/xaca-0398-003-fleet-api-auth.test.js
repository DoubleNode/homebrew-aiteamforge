//
//  xaca-0398-003-fleet-api-auth.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-0398-003 — browser side: public/{lcars,lcars2}/js/fleet-api-auth.js
 * and the migration of every mutating LCARS fetch onto it.
 *
 *   1. Wiring (static): the two copies are identical; EVERY mutating fetch in
 *      public/ goes through window.fleetApiFetch (source-derived, not a
 *      hand-picked list — 21 today); every page that loads a caller loads
 *      fleet-api-auth.js first.
 *   2. apiFetch behaviour (jsdom + fake fetch): CSRF header on unsafe methods
 *      only, same-origin credentials, cross-origin passthrough, 401 -> unlock
 *      dialog -> retry once, cancel returns the original 401, no retry loop,
 *      one dialog for concurrent 401s, network failures tagged and never
 *      prompting.
 *   3. Dialog accessibility: labelled password input with
 *      autocomplete=current-password, role=dialog + aria-modal, focus moves
 *      in and is restored, Esc closes, Tab is trapped, error announced via
 *      role=alert, the token is cleared and never persisted.
 */

const { test, describe } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');

const PUBLIC_DIR = path.join(__dirname, '..', 'public');
const LCARS_COPY = path.join(PUBLIC_DIR, 'lcars', 'js', 'fleet-api-auth.js');
const LCARS2_COPY = path.join(PUBLIC_DIR, 'lcars2', 'js', 'fleet-api-auth.js');
const { createFleetApiAuth } = require(LCARS_COPY);

const TOKEN = 'test-admin-token-not-a-real-secret';

// ===========================================================================
// 1. Wiring (static)
// ===========================================================================

function walkJs(dir, out = []) {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        if (entry.name === 'vendor' || entry.name === 'node_modules') continue;
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) walkJs(full, out);
        else if (entry.name.endsWith('.js')) out.push(full);
    }
    return out;
}

/**
 * Every `method: 'POST'|'PUT'|'PATCH'|'DELETE'` literal in browser JS, paired
 * with the nearest preceding `fetch(`-family call token. The wrapper file
 * itself is excluded (its own login/logout calls are the transport).
 */
function mutatingFetchSites() {
    const sites = [];
    for (const file of walkJs(PUBLIC_DIR)) {
        if (path.basename(file) === 'fleet-api-auth.js') continue;
        const src = fs.readFileSync(file, 'utf8');
        const re = /method:\s*['"](POST|PUT|PATCH|DELETE)['"]/g;
        let m;
        while ((m = re.exec(src)) !== null) {
            const before = src.slice(Math.max(0, m.index - 600), m.index);
            const calls = [...before.matchAll(/([A-Za-z_$.]*fetch|[A-Za-z_$.]*Fetch)\s*\(/g)];
            const nearest = calls.length ? calls[calls.length - 1][1] : null;
            const line = src.slice(0, m.index).split('\n').length;
            sites.push({ file: path.relative(PUBLIC_DIR, file), line, method: m[1], call: nearest });
        }
    }
    return sites;
}

describe('wiring — every mutating browser fetch goes through fleetApiFetch', () => {
    test('lcars and lcars2 copies of fleet-api-auth.js are byte-identical', () => {
        assert.equal(fs.readFileSync(LCARS_COPY, 'utf8'), fs.readFileSync(LCARS2_COPY, 'utf8'));
    });

    const sites = mutatingFetchSites();

    test('21 mutating fetch sites found (lcars-engines 7+7, dashboards-ui 4, dashboard-app 1, credentials-ui 2)', () => {
        const byFile = {};
        for (const s of sites) byFile[s.file] = (byFile[s.file] || 0) + 1;
        assert.deepEqual(byFile, {
            'lcars/js/lcars-credentials-ui.js': 2,
            'lcars/js/lcars-dashboard-app.js': 1,
            'lcars/js/lcars-dashboards-ui.js': 4,
            'lcars/js/lcars-engines.js': 7,
            'lcars2/js/lcars-engines.js': 7,
        });
    });

    for (const s of sites) {
        test(`${s.file}:${s.line} ${s.method} uses window.fleetApiFetch`, () => {
            assert.equal(s.call, 'window.fleetApiFetch', `${s.file}:${s.line} ${s.method} goes through ${s.call}, not the admin wrapper`);
        });
    }

    const CALLER_SCRIPTS = /src="js\/(lcars-engines|lcars-dashboards-ui|lcars-dashboard-app|lcars-credentials-ui)\.js/;
    const pages = [];
    for (const sub of ['lcars', 'lcars2']) {
        for (const f of fs.readdirSync(path.join(PUBLIC_DIR, sub))) {
            if (f.endsWith('.html')) pages.push(path.join(sub, f));
        }
    }
    const callerPages = pages.filter((p) => CALLER_SCRIPTS.test(fs.readFileSync(path.join(PUBLIC_DIR, p), 'utf8')));

    test('the 5 pages that load a caller script are the ones the design lists', () => {
        assert.deepEqual(callerPages.sort(), [
            'lcars/lcars-dashboard.html',
            'lcars2/lcars-all.html',
            'lcars2/lcars-doublenode.html',
            'lcars2/lcars-index.html',
            'lcars2/lcars-mainevent.html',
        ]);
    });

    for (const p of callerPages) {
        test(`${p} loads fleet-api-auth.js exactly once, before every caller script`, () => {
            const html = fs.readFileSync(path.join(PUBLIC_DIR, p), 'utf8');
            const tags = [...html.matchAll(/<script[^>]*src="([^"]+)"/g)].map((m) => m[1]);
            const authIdx = tags.findIndex((s) => /^js\/fleet-api-auth\.js(\?|$)/.test(s));
            assert.ok(authIdx >= 0, `${p} does not load js/fleet-api-auth.js`);
            assert.equal(tags.filter((s) => /fleet-api-auth\.js/.test(s)).length, 1);
            tags.forEach((s, i) => {
                if (CALLER_SCRIPTS.test(`src="${s}`)) assert.ok(i > authIdx, `${s} loads before fleet-api-auth.js in ${p}`);
            });
        });
    }
});

// ===========================================================================
// 2 + 3. Behaviour (jsdom)
// ===========================================================================

function makeEnv() {
    const dom = new JSDOM('<!doctype html><html><head></head><body><button id="trigger">Save</button></body></html>', {
        url: 'https://fleet-monitor.test/lcars2/lcars-index.html',
    });
    const { window } = dom;
    const calls = [];
    const queue = [];
    const fakeFetch = async (url, init) => {
        calls.push({ url: String(url), init: init || {} });
        const next = queue.shift();
        if (!next) return { status: 200, ok: true, json: async () => ({}) }; // jsdom has no Response
        if (next instanceof Error) throw next;
        return next;
    };
    const respond = (status, body = {}) => queue.push({ status, ok: status >= 200 && status < 300, json: async () => body });
    const failNetwork = () => queue.push(new TypeError('Failed to fetch'));
    const client = createFleetApiAuth({ fetch: fakeFetch, document: window.document, location: window.location });
    return { dom, window, document: window.document, calls, respond, failNetwork, client };
}

const tick = () => new Promise((r) => setTimeout(r, 0));
async function waitFor(fn, label) {
    for (let i = 0; i < 100; i++) {
        const v = fn();
        if (v) return v;
        await tick();
    }
    throw new Error(`timed out waiting for ${label}`);
}

function headerOf(init, name) {
    const h = init.headers;
    if (!h) return undefined;
    if (typeof h.get === 'function') return h.get(name) === null ? undefined : h.get(name);
    return h[name];
}

function pressKey(env, key, opts = {}) {
    const ev = new env.window.KeyboardEvent('keydown', { key, bubbles: true, cancelable: true, ...opts });
    (env.document.activeElement || env.document.body).dispatchEvent(ev);
    return ev;
}

describe('apiFetch — request shaping', () => {
    test('unsafe methods get X-Fleet-CSRF: 1 and same-origin credentials; existing headers preserved', async () => {
        const env = makeEnv();
        env.respond(200);
        await env.client.apiFetch('/api/dashboards', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' });
        const { init } = env.calls[0];
        assert.equal(init.credentials, 'same-origin');
        assert.equal(headerOf(init, 'X-Fleet-CSRF'), '1');
        assert.equal(headerOf(init, 'Content-Type'), 'application/json');
    });

    for (const method of ['PUT', 'DELETE', 'PATCH', 'post']) {
        test(`${method} is treated as unsafe`, async () => {
            const env = makeEnv();
            env.respond(200);
            await env.client.apiFetch('/api/x', { method });
            assert.equal(headerOf(env.calls[0].init, 'X-Fleet-CSRF'), '1');
        });
    }

    test('GET gets no CSRF header', async () => {
        const env = makeEnv();
        env.respond(200);
        await env.client.apiFetch('/api/engines');
        assert.equal(headerOf(env.calls[0].init, 'X-Fleet-CSRF'), undefined);
    });

    test('the caller\'s init object is not mutated', async () => {
        const env = makeEnv();
        env.respond(200);
        const init = { method: 'POST', headers: { 'Content-Type': 'application/json' } };
        await env.client.apiFetch('/api/x', init);
        assert.deepEqual(init, { method: 'POST', headers: { 'Content-Type': 'application/json' } });
    });

    test('cross-origin URL passes through untouched (no CSRF header, no credentials option)', async () => {
        const env = makeEnv();
        env.respond(200);
        const init = { method: 'POST', body: '{}' };
        await env.client.apiFetch('https://elsewhere.example/api/x', init);
        assert.equal(env.calls[0].init, init);
        assert.equal(headerOf(env.calls[0].init, 'X-Fleet-CSRF'), undefined);
    });

    test('absolute same-origin URL is treated as same-origin', async () => {
        const env = makeEnv();
        env.respond(200);
        await env.client.apiFetch('https://fleet-monitor.test/api/x', { method: 'DELETE' });
        assert.equal(headerOf(env.calls[0].init, 'X-Fleet-CSRF'), '1');
    });
});

describe('apiFetch — 401 recovery via the unlock dialog', () => {
    test('401 opens the dialog; a good token logs in, the input is cleared, and the request is retried once', async () => {
        const env = makeEnv();
        env.respond(401);                 // original
        env.respond(200, { authenticated: true }); // login
        env.respond(200, { ok: true });   // retry
        const p = env.client.apiFetch('/api/dashboards/1', { method: 'PUT', body: '{"a":1}' });

        const input = await waitFor(() => env.document.getElementById('fleet-unlock-token'), 'dialog');
        input.value = TOKEN;
        env.document.querySelector('.fleet-unlock-form').requestSubmit();
        const resp = await p;

        assert.equal(resp.status, 200);
        assert.equal(env.calls.length, 3);
        const login = env.calls[1];
        assert.equal(login.url, '/api/auth/login');
        assert.equal(login.init.method, 'POST');
        assert.equal(login.init.credentials, 'same-origin');
        assert.equal(headerOf(login.init, 'X-Fleet-CSRF'), '1');
        assert.deepEqual(JSON.parse(login.init.body), { token: TOKEN });
        assert.equal(env.calls[2].url, '/api/dashboards/1');
        assert.equal(env.calls[2].init.body, '{"a":1}');
        assert.equal(env.document.getElementById('fleet-unlock-overlay'), null, 'dialog closed');
        assert.ok(!env.document.documentElement.outerHTML.includes(TOKEN), 'token left in the DOM');
        assert.equal(env.window.localStorage.length, 0);
        assert.equal(env.window.sessionStorage.length, 0);
        assert.ok(env.document.getElementById('fleet-unlock-chip'), 'unlocked chip offers lock/logout');
    });

    test('a second 401 after unlocking is returned to the caller — no loop', async () => {
        const env = makeEnv();
        env.respond(401);
        env.respond(200);
        env.respond(401);
        const p = env.client.apiFetch('/api/x', { method: 'POST' });
        const input = await waitFor(() => env.document.getElementById('fleet-unlock-token'), 'dialog');
        input.value = TOKEN;
        env.document.querySelector('.fleet-unlock-form').requestSubmit();
        const resp = await p;
        assert.equal(resp.status, 401);
        assert.equal(env.calls.length, 3);
        assert.equal(env.document.getElementById('fleet-unlock-overlay'), null);
    });

    test('Esc cancels: the original 401 is returned, focus goes back to the trigger', async () => {
        const env = makeEnv();
        const trigger = env.document.getElementById('trigger');
        trigger.focus();
        env.respond(401);
        const p = env.client.apiFetch('/api/x', { method: 'DELETE' });
        const input = await waitFor(() => env.document.getElementById('fleet-unlock-token'), 'dialog');
        assert.equal(env.document.activeElement, input, 'focus moves into the dialog');
        pressKey(env, 'Escape');
        const resp = await p;
        assert.equal(resp.status, 401);
        assert.equal(env.calls.length, 1, 'no login and no retry after cancel');
        assert.equal(env.document.getElementById('fleet-unlock-overlay'), null);
        assert.equal(env.document.activeElement, trigger, 'focus restored');
    });

    test('Cancel button behaves like Esc', async () => {
        const env = makeEnv();
        env.respond(401);
        const p = env.client.apiFetch('/api/x', { method: 'POST' });
        await waitFor(() => env.document.getElementById('fleet-unlock-token'), 'dialog');
        env.document.querySelector('.fleet-unlock-cancel').click();
        assert.equal((await p).status, 401);
    });

    test('a rejected token keeps the dialog open with an announced error, input cleared and refocused', async () => {
        const env = makeEnv();
        env.respond(401);
        env.respond(401); // login rejected
        const p = env.client.apiFetch('/api/x', { method: 'POST' });
        const input = await waitFor(() => env.document.getElementById('fleet-unlock-token'), 'dialog');
        input.value = 'test-wrong-token-not-a-real-secret';
        env.document.querySelector('.fleet-unlock-form').requestSubmit();
        const err = env.document.getElementById('fleet-unlock-error');
        await waitFor(() => err.textContent.length > 0, 'error text');
        assert.equal(err.getAttribute('role'), 'alert');
        assert.match(err.textContent, /not accepted/i);
        assert.ok(!err.textContent.includes('test-wrong-token'), 'error must not echo the token');
        assert.equal(input.value, '');
        assert.equal(env.document.activeElement, input);
        pressKey(env, 'Escape');
        assert.equal((await p).status, 401);
    });

    test('rate-limited and network login failures show distinct messages', async () => {
        const env = makeEnv();
        env.respond(401);
        env.respond(429);
        env.failNetwork();
        const p = env.client.apiFetch('/api/x', { method: 'POST' });
        const input = await waitFor(() => env.document.getElementById('fleet-unlock-token'), 'dialog');
        const err = env.document.getElementById('fleet-unlock-error');
        input.value = TOKEN;
        env.document.querySelector('.fleet-unlock-form').requestSubmit();
        await waitFor(() => /too many/i.test(err.textContent), 'rate-limit text');
        input.value = TOKEN;
        env.document.querySelector('.fleet-unlock-form').requestSubmit();
        await waitFor(() => /could not reach/i.test(err.textContent), 'network text');
        pressKey(env, 'Escape');
        await p;
    });

    test('an empty submit does not call the server', async () => {
        const env = makeEnv();
        env.respond(401);
        const p = env.client.apiFetch('/api/x', { method: 'POST' });
        await waitFor(() => env.document.getElementById('fleet-unlock-token'), 'dialog');
        env.document.querySelector('.fleet-unlock-form').requestSubmit();
        await tick();
        assert.equal(env.calls.length, 1);
        assert.match(env.document.getElementById('fleet-unlock-error').textContent, /enter the admin token/i);
        pressKey(env, 'Escape');
        await p;
    });

    test('concurrent 401s share ONE dialog, and both retry after one unlock', async () => {
        const env = makeEnv();
        env.respond(401);
        env.respond(401);
        const a = env.client.apiFetch('/api/a', { method: 'POST' });
        const b = env.client.apiFetch('/api/b', { method: 'POST' });
        const input = await waitFor(() => env.document.getElementById('fleet-unlock-token'), 'dialog');
        await tick();
        assert.equal(env.document.querySelectorAll('.fleet-unlock-overlay').length, 1);
        input.value = TOKEN;
        env.document.querySelector('.fleet-unlock-form').requestSubmit();
        const [ra, rb] = await Promise.all([a, b]);
        assert.equal(ra.status, 200);
        assert.equal(rb.status, 200);
        assert.equal(env.calls.filter((c) => c.url === '/api/auth/login').length, 1);
    });

    test('a 401 on a GET does not prompt', async () => {
        const env = makeEnv();
        env.respond(401);
        const resp = await env.client.apiFetch('/api/token-reports');
        assert.equal(resp.status, 401);
        assert.equal(env.document.getElementById('fleet-unlock-overlay'), null);
    });

    test('network failure: rethrown, tagged isNetworkFailure, no dialog', async () => {
        const env = makeEnv();
        env.failNetwork();
        await assert.rejects(env.client.apiFetch('/api/x', { method: 'POST' }), (err) => err.isNetworkFailure === true);
        assert.equal(env.document.getElementById('fleet-unlock-overlay'), null);
    });
});

describe('unlock dialog — accessibility', () => {
    test('role=dialog, aria-modal, labelled title and description, labelled password input for a password manager', async () => {
        const env = makeEnv();
        env.respond(401);
        const p = env.client.apiFetch('/api/x', { method: 'POST' });
        const input = await waitFor(() => env.document.getElementById('fleet-unlock-token'), 'dialog');
        const dialog = env.document.querySelector('[role="dialog"]');
        assert.ok(dialog);
        assert.equal(dialog.getAttribute('aria-modal'), 'true');
        const titleId = dialog.getAttribute('aria-labelledby');
        assert.ok(env.document.getElementById(titleId).textContent.trim().length > 0);
        assert.ok(env.document.getElementById(dialog.getAttribute('aria-describedby')));
        assert.equal(input.type, 'password');
        assert.equal(input.getAttribute('autocomplete'), 'current-password');
        const label = env.document.querySelector('label[for="fleet-unlock-token"]');
        assert.ok(label && label.textContent.trim().length > 0, 'input has a visible label');
        pressKey(env, 'Escape');
        await p;
    });

    test('Tab and Shift+Tab stay inside the dialog', async () => {
        const env = makeEnv();
        env.respond(401);
        const p = env.client.apiFetch('/api/x', { method: 'POST' });
        const input = await waitFor(() => env.document.getElementById('fleet-unlock-token'), 'dialog');
        const submit = env.document.querySelector('.fleet-unlock-submit');
        submit.focus();
        const fwd = pressKey(env, 'Tab');
        assert.ok(fwd.defaultPrevented);
        assert.equal(env.document.activeElement, input, 'Tab from the last control wraps to the first');
        const back = pressKey(env, 'Tab', { shiftKey: true });
        assert.ok(back.defaultPrevented);
        assert.equal(env.document.activeElement, submit, 'Shift+Tab from the first control wraps to the last');
        pressKey(env, 'Escape');
        await p;
    });

    test('the page source never reads or writes web storage', () => {
        const src = fs.readFileSync(LCARS_COPY, 'utf8');
        // Usage, not mentions: the doc comment explains the rule in prose.
        assert.ok(!/\b(localStorage|sessionStorage)\s*[.[]|\bindexedDB\s*\.|document\.cookie/.test(src));
    });
});

describe('logout and session state', () => {
    test('logout POSTs with the CSRF header and removes the chip', async () => {
        const env = makeEnv();
        env.respond(200, { gate: 'closed', authenticated: true, expiresAt: Date.now() + 1000 });
        await env.client.refreshStatus();
        assert.ok(env.document.getElementById('fleet-unlock-chip'));
        env.respond(204);
        await env.client.logout();
        const call = env.calls[env.calls.length - 1];
        assert.equal(call.url, '/api/auth/logout');
        assert.equal(headerOf(call.init, 'X-Fleet-CSRF'), '1');
        assert.equal(env.document.getElementById('fleet-unlock-chip'), null);
    });

    test('no chip when the gate is open or the session is not authenticated (kiosk screens stay clean)', async () => {
        const env = makeEnv();
        env.respond(200, { gate: 'open', authenticated: false, expiresAt: null });
        await env.client.refreshStatus();
        assert.equal(env.document.getElementById('fleet-unlock-chip'), null);
        env.respond(200, { gate: 'closed', authenticated: false, expiresAt: null });
        await env.client.refreshStatus();
        assert.equal(env.document.getElementById('fleet-unlock-chip'), null);
    });
});

// ===========================================================================
// 4. XACA-0398-017 — WCAG AA contrast of every dialog text/background pair,
//    resolved against BOTH shipped theme files (not the JS fallbacks: the
//    real tokens always win, which is how #cc4444 slipped through).
// ===========================================================================

const THEME_FILES = {
    lcars: path.join(PUBLIC_DIR, 'lcars', 'css', 'lcars-fleet-theme.css'),
    lcars2: path.join(PUBLIC_DIR, 'lcars2', 'css', 'lcars-fleet-theme.css'),
};

function declsOf(block) {
    const out = {};
    const clean = block.replace(/\/\*[\s\S]*?\*\//g, '');
    for (const part of clean.split(';')) {
        const i = part.indexOf(':');
        if (i < 0) continue;
        out[part.slice(0, i).trim()] = part.slice(i + 1).trim();
    }
    return out;
}

/**
 * Theme variable contexts: the base top-level :root, plus base overlaid with
 * each `@media (...) { :root {...} }` override (high-contrast, mobile), so a
 * media-query retune of a token the dialog uses is checked too.
 */
function themeContexts(file) {
    const css = fs.readFileSync(file, 'utf8').replace(/\/\*[\s\S]*?\*\//g, '');
    const baseMatch = css.match(/(^|\})\s*:root\s*\{([^}]*)\}/);
    assert.ok(baseMatch, `no top-level :root block in ${file}`);
    const base = declsOf(baseMatch[2]);
    const contexts = [{ name: 'base', vars: base }];
    const re = /@media\s*([^{]+)\{\s*:root\s*\{([^}]*)\}/g;
    let m;
    while ((m = re.exec(css)) !== null) {
        contexts.push({ name: `@media ${m[1].trim()}`, vars: { ...base, ...declsOf(m[2]) } });
    }
    return contexts;
}

function resolveVar(value, vars, depth = 0) {
    assert.ok(depth < 10, `var() cycle resolving ${value}`);
    const m = value.match(/^var\(\s*(--[\w-]+)\s*(?:,\s*(.+))?\)$/);
    if (!m) return value.trim();
    if (vars[m[1]] !== undefined) return resolveVar(vars[m[1]], vars, depth + 1);
    assert.ok(m[2] !== undefined, `${m[1]} undefined in theme and has no fallback`);
    return resolveVar(m[2].trim(), vars, depth + 1);
}

function hexToRgb(hex) {
    let h = hex.replace('#', '');
    if (h.length === 3) h = h.split('').map((c) => c + c).join('');
    assert.match(h, /^[0-9a-fA-F]{6}$/, `not an opaque hex colour: ${hex}`);
    return [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16));
}

// WCAG 2.x relative luminance / contrast ratio.
function luminance([r, g, b]) {
    const lin = (c) => { c /= 255; return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); };
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
}
function contrast(a, b) {
    const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
    return (hi + 0.05) / (lo + 0.05);
}

function dialogRules() {
    const env = makeEnv();
    env.client.unlock(); // injects the style element; left open, env discarded
    const css = env.document.getElementById('fleet-unlock-styles').textContent;
    const rules = {};
    const re = /([^{}]+)\{([^{}]*)\}/g;
    let m;
    while ((m = re.exec(css)) !== null) {
        const decls = declsOf(m[2]);
        for (const sel of m[1].split(',').map((s) => s.trim())) {
            rules[sel] = { ...(rules[sel] || {}), ...decls };
        }
    }
    return rules;
}

describe('unlock dialog — WCAG AA text contrast against the shipped themes (XACA-0398-017)', () => {
    const rules = dialogRules();
    const bgOf = (sel) => rules[sel] && (rules[sel].background || rules[sel]['background-color']);
    // [label, text-colour selector, background selector]
    const PAIRS = [
        ['title on header', '.fleet-unlock-title', '.fleet-unlock-header'],
        ['lead paragraph', '.fleet-unlock-lead', '.fleet-unlock-box'],
        ['field label', '.fleet-unlock-label', '.fleet-unlock-box'],
        ['input value text', '.fleet-unlock-input', '.fleet-unlock-input'],
        ['footer note', '.fleet-unlock-note', '.fleet-unlock-box'],
        ['error/status text', '.fleet-unlock-error', '.fleet-unlock-box'],
        ['cancel button', '.fleet-unlock-btn', '.fleet-unlock-cancel'],
        ['unlock button', '.fleet-unlock-btn', '.fleet-unlock-submit'],
        ['unlock button (hover)', '.fleet-unlock-btn', '.fleet-unlock-submit:hover'],
        ['chip label', '.fleet-unlock-chip', '.fleet-unlock-chip'],
    ];

    test('every pair has a colour and a background rule to check', () => {
        for (const [label, fg, bg] of PAIRS) {
            assert.ok(rules[fg] && rules[fg].color, `${label}: no color on ${fg}`);
            assert.ok(bgOf(bg), `${label}: no background on ${bg}`);
        }
    });

    for (const [skin, file] of Object.entries(THEME_FILES)) {
        for (const ctx of themeContexts(file)) {
            for (const [label, fg, bg] of PAIRS) {
                test(`${skin} ${ctx.name}: ${label} >= 4.5:1`, () => {
                    const fgHex = resolveVar(rules[fg].color, ctx.vars);
                    const bgHex = resolveVar(bgOf(bg), ctx.vars);
                    const ratio = contrast(hexToRgb(fgHex), hexToRgb(bgHex));
                    assert.ok(ratio >= 4.5, `${skin} ${ctx.name} ${label}: ${fgHex} on ${bgHex} = ${ratio.toFixed(2)}:1 (< 4.5:1)`);
                });
            }
        }
    }

    test('sanity: the formula reproduces the gate measurement (#cc4444 on #0d0d1a = 4.11:1)', () => {
        assert.equal(contrast(hexToRgb('#cc4444'), hexToRgb('#0d0d1a')).toFixed(2), '4.11');
    });
});

// ===========================================================================
// 4b. XACA-0398-020 — the dialog buttons and the lock chip have a hit area of
//     at least 44x44px (they measured ~30px and 25px tall). Both skins run the
//     same bytes (see the byte-identity test above), so one copy covers both.
// ===========================================================================

describe('unlock dialog + chip — 44px minimum touch target (XACA-0398-020)', () => {
    const rules = dialogRules();
    const px = (v) => {
        const m = /^(\d+(?:\.\d+)?)px$/.exec(String(v || '').trim());
        return m ? Number(m[1]) : NaN;
    };
    for (const sel of ['.fleet-unlock-btn', '.fleet-unlock-chip']) {
        test(`${sel} declares min-height and min-width >= 44px with border-box sizing`, () => {
            const r = rules[sel] || {};
            assert.ok(px(r['min-height']) >= 44, `${sel} min-height is ${r['min-height']}`);
            assert.ok(px(r['min-width']) >= 44, `${sel} min-width is ${r['min-width']}`);
            assert.equal(r['box-sizing'], 'border-box', `${sel} must size the min-height as the full hit box`);
        });
    }
});

// ===========================================================================
// 5. XACA-0398-018 — background is inert + aria-hidden while the modal is
//    open, and restored to its ORIGINAL state on every close path.
// ===========================================================================

describe('unlock dialog — background inert while open (XACA-0398-018)', () => {
    function addBackground(env) {
        const main = env.document.createElement('main');
        main.id = 'dash';
        main.textContent = 'dashboard content';
        env.document.body.appendChild(main);
        const pre = env.document.createElement('div');
        pre.id = 'already-hidden';
        pre.setAttribute('aria-hidden', 'true'); // must stay hidden after close
        env.document.body.appendChild(pre);
        return { trigger: env.document.getElementById('trigger'), main, pre };
    }

    function assertHidden(env, bg) {
        for (const n of [bg.trigger, bg.main, bg.pre]) {
            assert.ok(n.hasAttribute('inert'), `#${n.id} not inert while dialog open`);
            assert.equal(n.getAttribute('aria-hidden'), 'true', `#${n.id} not aria-hidden while dialog open`);
        }
        const overlay = env.document.getElementById('fleet-unlock-overlay');
        assert.ok(!overlay.hasAttribute('inert'), 'the overlay itself must not be inert');
        assert.ok(!overlay.hasAttribute('aria-hidden'), 'the overlay itself must not be aria-hidden');
    }

    function assertRestored(bg) {
        for (const n of [bg.trigger, bg.main]) {
            assert.ok(!n.hasAttribute('inert'), `#${n.id} still inert after close`);
            assert.ok(!n.hasAttribute('aria-hidden'), `#${n.id} still aria-hidden after close`);
        }
        assert.ok(!bg.pre.hasAttribute('inert'), 'pre-hidden node gained inert');
        assert.equal(bg.pre.getAttribute('aria-hidden'), 'true', 'pre-existing aria-hidden was not preserved');
    }

    const CLOSE_PATHS = {
        Esc: (env) => pressKey(env, 'Escape'),
        Cancel: (env) => env.document.querySelector('.fleet-unlock-cancel').click(),
    };
    for (const [name, doClose] of Object.entries(CLOSE_PATHS)) {
        test(`${name}: hidden while open, restored after`, async () => {
            const env = makeEnv();
            const bg = addBackground(env);
            env.respond(401);
            const p = env.client.apiFetch('/api/x', { method: 'POST' });
            await waitFor(() => env.document.getElementById('fleet-unlock-token'), 'dialog');
            assertHidden(env, bg);
            doClose(env);
            await p;
            assertRestored(bg);
        });
    }

    test('success: hidden while open, restored after (and focus returns to the trigger)', async () => {
        const env = makeEnv();
        const bg = addBackground(env);
        bg.trigger.focus();
        env.respond(401);
        env.respond(200);
        env.respond(200);
        const p = env.client.apiFetch('/api/x', { method: 'POST' });
        const input = await waitFor(() => env.document.getElementById('fleet-unlock-token'), 'dialog');
        assertHidden(env, bg);
        input.value = TOKEN;
        env.document.querySelector('.fleet-unlock-form').requestSubmit();
        await p;
        assertRestored(bg);
        assert.equal(env.document.activeElement, bg.trigger);
    });

    test('a retry that re-opens the dialog hides again, then restores cleanly', async () => {
        const env = makeEnv();
        const bg = addBackground(env);
        env.respond(401);
        const p1 = env.client.apiFetch('/api/x', { method: 'POST' });
        await waitFor(() => env.document.getElementById('fleet-unlock-token'), 'dialog 1');
        pressKey(env, 'Escape');
        await p1;
        assertRestored(bg);
        env.respond(401);
        const p2 = env.client.apiFetch('/api/x', { method: 'POST' });
        await waitFor(() => env.document.getElementById('fleet-unlock-token'), 'dialog 2');
        assertHidden(env, bg);
        env.document.querySelector('.fleet-unlock-cancel').click();
        await p2;
        assertRestored(bg);
    });
});

// ===========================================================================
// 6. XACA-0398-019 — a 403 from /api/auth/login (CSRF rejection) gets its own
//    "reload" message, not the generic retry one; a 5xx keeps the generic one.
// ===========================================================================

describe('unlock dialog — 403 CSRF rejection message (XACA-0398-019)', () => {
    async function outcomeText(status) {
        const env = makeEnv();
        env.respond(401);
        env.respond(status);
        env.client.apiFetch('/api/x', { method: 'POST' });
        const input = await waitFor(() => env.document.getElementById('fleet-unlock-token'), 'dialog');
        input.value = TOKEN;
        env.document.querySelector('.fleet-unlock-form').requestSubmit();
        const err = env.document.getElementById('fleet-unlock-error');
        await waitFor(() => err.textContent, `error text for ${status}`);
        assert.ok(env.document.getElementById('fleet-unlock-overlay'), 'dialog stays open');
        return err.textContent;
    }

    test('403 says to reload the page', async () => {
        const text = await outcomeText(403);
        assert.equal(text, 'Could not verify this page — reload and try again.');
    });

    test('500 still shows the generic retry message, distinct from 403', async () => {
        const text = await outcomeText(500);
        assert.equal(text, 'Unlock failed. Try again.');
        assert.notEqual(text, await outcomeText(403));
    });
});
