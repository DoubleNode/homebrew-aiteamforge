//
//  xaca-1495-utc-header-clock-jsdom.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1495-004 -- jsdom tests for the live UTC clock in the Fleet Monitor LCARS header.
 *
 * Loads the REAL lcars-dashboard.html markup and the REAL lcars-dashboard-app.js, then runs the
 * app's real DOMContentLoaded handler. Only the environment is faked (Date + timers inside the
 * jsdom realm, fetch); no production logic is reimplemented here.
 *
 * TZ independence: changing TZ at runtime in node is unreliable, so the TZ tests spawn this very
 * file as a child process with TZ set at process start, and the child asserts
 * getTimezoneOffset() really is non-zero before checking that the clock still shows UTC.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { JSDOM } = require('jsdom');

const PUBLIC_ROOT = path.join(__dirname, '..', 'public');
const APP_JS = path.join(PUBLIC_ROOT, 'lcars', 'js', 'lcars-dashboard-app.js');
const CICD_JS = path.join(PUBLIC_ROOT, 'lcars', 'js', 'lcars-cicd.js');
const DASHBOARD_HTML = path.join(PUBLIC_ROOT, 'lcars', 'lcars-dashboard.html');

const TZ_CHILD = process['env'].XACA1495_TZ_CHILD || '';
const EXPECTED_OFFSETS = { 'America/Los_Angeles': [420, 480], 'Asia/Kolkata': [-330] };

function read(p) {
    if (!fs.existsSync(p)) throw new Error('MISSING IMPLEMENTATION: ' + p);
    return fs.readFileSync(p, 'utf8');
}

// Boots the real dashboard page with a controllable clock. Resolves once the real init handler resolves.
async function boot(startIso) {
    const dom = new JSDOM(read(DASHBOARD_HTML), { runScripts: 'outside-only', url: 'http://localhost/lcars/lcars-dashboard.html' });
    const w = dom.window;
    let handler = null;
    const origAdd = w.document.addEventListener.bind(w.document);
    w.document.addEventListener = (type, fn, o) => {
        if (type === 'DOMContentLoaded') { handler = fn; return; }
        return origAdd(type, fn, o);
    };
    // Environment fakes, installed INSIDE the jsdom realm (environment only, no app logic).
    w.eval(`(function () {
        var Real = Date;
        var state = { now: 0, intervals: [], nextId: 1 };
        window.__fake = state;
        window.Date = class extends Real {
            constructor(...a) { if (a.length === 0) super(state.now); else super(...a); }
            static now() { return state.now; }
        };
        window.setInterval = function (fn, ms) { var id = state.nextId++; state.intervals.push({ id: id, fn: fn, ms: ms, next: state.now + ms }); return id; };
        window.clearInterval = function (id) { state.intervals = state.intervals.filter(function (i) { return i.id !== id; }); };
        window.setTimeout = function () { return 0; };
        window.clearTimeout = function () {};
    })();`);
    const fake = w.__fake;
    fake.now = Date.parse(startIso);
    w.fetch = async () => ({ ok: true, status: 200, json: async () => ({ fleet: { divisions: {}, machines: [] }, teams: {} }) });
    w.eval(read(APP_JS));
    assert.ok(handler, 'app registered a DOMContentLoaded handler');
    await handler.call(w);
    const d = w.document;
    return {
        window: w, document: d, fake,
        clock: d.getElementById('utc-clock'), value: d.getElementById('utc-clock-value'), stardate: d.getElementById('stardate'),
        // Advance the fake clock by ms, firing each due interval once per elapsed period.
        advance(ms) {
            const end = fake.now + ms;
            for (;;) {
                const due = fake.intervals.filter((i) => i.next <= end).sort((a, b) => a.next - b.next)[0];
                if (!due) break;
                fake.now = due.next;
                due.next += due.ms;
                due.fn();
            }
            fake.now = end;
        }
    };
}
const wantText = (ms) => new Date(ms).toISOString().slice(11, 19) + ' UTC';

// ---- Core behaviour (runs in the parent AND in every TZ child) --------------

if (TZ_CHILD) {
    test('child: process really runs in the requested non-UTC timezone', () => {
        const off = new Date(Date.UTC(2026, 9, 11, 12, 0, 0)).getTimezoneOffset();
        assert.ok(EXPECTED_OFFSETS[TZ_CHILD].includes(off), TZ_CHILD + ' offset=' + off);
        assert.notEqual(off, 0);
    });
}

test('init renders UTC text matching HH:MM:SS UTC and equal to the faked system time', async () => {
    const env = await boot('2026-10-11T13:45:07.250Z');
    assert.match(env.value.textContent, /^\d{2}:\d{2}:\d{2} UTC$/);
    assert.equal(env.value.textContent, '13:45:07 UTC');
    assert.equal(env.value.textContent, wantText(env.fake.now));
});

test('advancing 1000 ms advances the clock by exactly one second; minute, hour and day rollover', async () => {
    const env = await boot('2026-10-11T13:45:57.000Z');
    const seen = [env.value.textContent];
    for (let i = 0; i < 4; i++) { env.advance(1000); seen.push(env.value.textContent); }
    assert.deepEqual(seen, ['13:45:57 UTC', '13:45:58 UTC', '13:45:59 UTC', '13:46:00 UTC', '13:46:01 UTC']);
    const env2 = await boot('2026-10-11T13:59:59.000Z');
    env2.advance(1000);
    assert.equal(env2.value.textContent, '14:00:00 UTC');
    const env3 = await boot('2026-10-11T23:59:59.000Z');
    env3.advance(1000);
    assert.equal(env3.value.textContent, '00:00:00 UTC', 'day rollover');
});

// ---- Structural tests (run in the parent AND in every TZ child) -------------------------------------------

test('#utc-clock is not inside .stardate and #stardate keeps only the stardate value after ticks', async () => {
    const env = await boot('2026-10-11T13:45:07.000Z');
    assert.ok(env.clock, '#utc-clock exists');
    assert.equal(env.clock.closest('.stardate'), null);
    assert.equal(env.stardate.contains(env.clock), false);
    env.advance(5000);
    assert.equal(env.stardate.children.length, 0, 'stardate has no child elements');
    assert.match(env.stardate.textContent, /^\d+(\.\d+)?$/, 'stardate holds only a number: ' + env.stardate.textContent);
    assert.ok(!/UTC|:/.test(env.stardate.textContent));
});

test('exactly one 1000 ms interval drives the clock, and it is the same tick that drives the stardate', async () => {
    const env = await boot('2026-10-11T13:45:07.000Z');
    const ticks = env.fake.intervals.filter((i) => i.ms === 1000);
    assert.ok(ticks.length >= 1);
    // Other, unrelated 1000 ms timers exist in init (e.g. the "Last:" seen timer), so scope honestly:
    // run each 1000 ms callback in isolation and see which ones touch the clock / stardate.
    const touching = { clock: [], stardate: [] };
    ticks.forEach((t, idx) => {
        env.value.textContent = 'x'; env.stardate.textContent = 'x';
        env.fake.now += 3000;
        t.fn();
        if (env.value.textContent !== 'x') touching.clock.push(idx);
        if (env.stardate.textContent !== 'x') touching.stardate.push(idx);
    });
    assert.equal(touching.clock.length, 1, 'exactly one 1000 ms interval updates #utc-clock');
    assert.deepEqual(touching.clock, touching.stardate, 'the clock shares the stardate tick (no extra header timer)');
    // No interval of any other period touches the clock.
    env.fake.intervals.filter((i) => i.ms !== 1000).forEach((i) => {
        env.value.textContent = 'x';
        try { i.fn(); } catch (e) { /* unrelated timers may need network state; irrelevant here */ }
        assert.equal(env.value.textContent, 'x', 'non-1000ms interval ' + i.ms + ' must not touch the clock');
    });
});

test('#utc-clock has valid ISO datetime, accessible name, and no aria-live', async () => {
    const env = await boot('2026-10-11T13:45:07.250Z');
    assert.equal(env.clock.tagName, 'TIME');
    const dt = env.clock.getAttribute('datetime');
    assert.ok(dt, 'datetime attribute present');
    assert.match(dt, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);
    assert.equal(new Date(dt).toISOString(), dt);
    assert.equal(dt, '2026-10-11T13:45:07.250Z');
    env.advance(1000);
    assert.equal(env.clock.getAttribute('datetime'), '2026-10-11T13:45:08.250Z', 'datetime tracks the tick');
    assert.equal(env.clock.hasAttribute('aria-label'), false, 'no static aria-label (it would replace the live text as the accessible name)');
    assert.equal(env.clock.hasAttribute('aria-labelledby'), false);
    const prefix = env.clock.querySelector('.visually-hidden');
    assert.ok(prefix, 'hidden prefix present');
    assert.equal(prefix.textContent, 'UTC time: ');
    assert.equal(env.clock.textContent, 'UTC time: 13:45:08 UTC', 'accessible content = prefix + live time');
    for (let i = 0; i < 3; i++) env.advance(1000);
    assert.equal(env.clock.querySelector('.visually-hidden'), prefix, 'hidden prefix survives ticks (not clobbered)');
    assert.equal(env.clock.textContent, 'UTC time: 13:45:11 UTC');
    assert.equal(env.clock.hasAttribute('aria-live'), false, 'no aria-live (would announce every second)');
    assert.equal(env.clock.closest('[aria-live]'), null, 'no aria-live ancestor');
    assert.notEqual(env.clock.getAttribute('role'), 'timer');
});

test('format parity: header clock and CI/CD tab utcClock() use the same UTC derivation (source-text pin)', () => {
    const app = read(APP_JS), cicd = read(CICD_JS);
    assert.match(cicd, /new Date\([^)]*\)\.toISOString\(\)\.slice\(11,\s*19\)\s*\+\s*' UTC'/, 'CI/CD utcClock derivation');
    const start = app.indexOf('function updateUtcClock');
    assert.ok(start > 0, 'updateUtcClock present');
    const end = app.indexOf('\n    }\n', start); // function body only: up to its closing brace
    assert.ok(end > start, 'updateUtcClock body delimited');
    const body = app.slice(start, end);
    assert.match(body, /new Date\(\)\.toISOString\(\)/, 'header clock uses toISOString');
    assert.match(body, /\.slice\(11,\s*19\)\s*\+\s*' UTC'/, 'header clock uses the same slice(11, 19) + " UTC"');
    assert.ok(!/toLocale(Time)?String|getHours|getUTCHours/.test(body), 'no locale/local-time formatting in updateUtcClock');
});

// ---- TZ independence (parent only: children get TZ at process start) --------

if (!TZ_CHILD) {
    for (const tz of Object.keys(EXPECTED_OFFSETS)) {
        test('TZ independence: clock shows UTC under TZ=' + tz + ' (child process, offset verified)', () => {
            const childEnv = Object.assign({}, process['env'], { TZ: tz, XACA1495_TZ_CHILD: tz });
            delete childEnv.NODE_TEST_CONTEXT; // let the child run its own tests instead of treating itself as nested
            const r = spawnSync(process.execPath, ['--test-reporter=tap', __filename], { env: childEnv, encoding: 'utf8' });
            const out = (r.stdout || '') + (r.stderr || '');
            assert.equal(r.status, 0, 'child failed:\n' + out);
            assert.match(out, /child: process really runs in the requested non-UTC timezone/, 'child offset probe ran');
            assert.match(out, /# pass 7\b/, 'child ran probe + the 6 behavioural tests');
            assert.match(out, /# fail 0/);
        });
    }
}
