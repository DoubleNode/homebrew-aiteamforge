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
