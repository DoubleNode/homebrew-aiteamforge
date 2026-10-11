//
//  xaca-1465-adversarial.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1465-006 -- adversarial probes for the fallback reader, the ?refresh=1 route and the
 * pills. NO network: fake github / recording fetch stub; the clock is injected.
 */

const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { test, describe, after } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const express = require('express');
const { JSDOM } = require('jsdom');

const { createGithubClient } = require('../lib/ci-dispatch-github');
const { createFallbackReader } = require('../lib/ci-fallback-reader');
const { createPoolStore } = require('../lib/ci-pool-store');
const { registerCiRunnersRoutes } = require('../lib/ci-runners-routes');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca1465-006-'));
after(() => fs.rmSync(TMP, { recursive: true, force: true }));

const DN = (variable, label) => ({ owner: 'DoubleNode', repo: 'dev-team', variable, label });
const settle = () => new Promise((r) => setImmediate(r));

function reader(handler, { switches = [DN('CI_LINUX_RUNNER', 'LINUX')], logs = [] } = {}) {
    let t = Date.parse('2026-10-10T12:00:00Z');
    let list = switches;
    const timers = [];
    const calls = [];
    const github = { async getRepoVariable(o, r, n, opt = {}) { calls.push({ n, etag: opt.etag }); return handler(n, calls.length, opt); } };
    const rd = createFallbackReader({
        github, store: { getFallbackSwitches: () => list.map((s) => ({ ...s })) }, now: () => t,
        logger: { warn: (m) => logs.push(m) }, intervalMs: 300000, minRefreshIntervalMs: 30000,
        setTimer: (fn, ms) => { const h = { fn, ms, cleared: false }; timers.push(h); return h; },
        clearTimer: (h) => { h.cleared = true; },
    });
    return { rd, calls, timers, logs, setList: (l) => { list = l; }, advance: (ms) => { t += ms; } };
}

describe('hostile variable values', () => {
    test('a 1 MB array value: armed, snapshot stays small and `value` stays valid JSON', async () => {
        const big = JSON.stringify(['self-hosted', 'x'.repeat(1024 * 1024)]);
        const h = reader(() => ({ found: true, value: big, etag: null }));
        await h.rd.start();
        const s = h.rd.snapshot();
        assert.equal(s.switches[0].armed, true);
        assert.ok(JSON.stringify(s).length < 2000, 'snapshot is bounded');
        // v1 contract: value is the runner-label JSON -- a truncated string is not JSON.
        assert.doesNotThrow(() => JSON.parse(s.linux.value), 'linux.value parses');
        assert.ok(s.linux.value.length <= 200);
        h.rd.stop();
    });

    test('many long labels: `value` is still parseable JSON that includes self-hosted', async () => {
        const labels = ['self-hosted'].concat(Array.from({ length: 12 }, (_, i) => `label-${i}-${'y'.repeat(60)}`));
        const h = reader(() => ({ found: true, value: JSON.stringify(labels), etag: null }));
        await h.rd.start();
        const v = JSON.parse(h.rd.snapshot().linux.value);
        assert.ok(Array.isArray(v) && v.includes('self-hosted'));
        h.rd.stop();
    });

    test('a 1 MB non-JSON value: UNKNOWN with a fixed reason; the value is echoed nowhere', async () => {
        const junk = '<script>alert(1)</script>'.repeat(40000);
        const h = reader(() => ({ found: true, value: junk, etag: null }));
        await h.rd.start();
        const s = h.rd.snapshot();
        assert.equal(s.switches[0].armed, null);
        const blob = JSON.stringify(s) + h.logs.join('\n');
        assert.ok(!blob.includes('script'));
        assert.ok(blob.length < 2000);
        h.rd.stop();
    });

    test('control characters and HTML in labels are stripped from the legacy value', async () => {
        const h = reader(() => ({ found: true, value: JSON.stringify(['self-hosted', 'a\u0000b\u001fc\u007fd<img onerror=x>']), etag: null }));
        await h.rd.start();
        const v = h.rd.snapshot().linux.value;
        assert.ok(!/[\u0000-\u001f\u007f]/.test(v));
        h.rd.stop();
    });

    test('200 with value missing / null / number => fixed BAD_RESPONSE reason via the real client', async () => {
        const { privateKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048,
            publicKeyEncoding: { type: 'spki', format: 'pem' }, privateKeyEncoding: { type: 'pkcs8', format: 'pem' } });
        for (const body of [{ name: 'X' }, { name: 'X', value: null }, { name: 'X', value: 7 }]) {
            const fetchStub = async (url) => {
                const u = new URL(url);
                const R = (status, b) => ({ status, headers: { get: () => null }, json: async () => b });
                if (/\/installation$/.test(u.pathname)) return R(200, { id: 1 });
                if (/\/access_tokens$/.test(u.pathname)) return R(201, { token: 'ghs_x', expires_at: new Date(Date.now() + 3600e3).toISOString() });
                return R(200, body);
            };
            const github = createGithubClient({ config: { GITHUB_APP_ID: '1', GITHUB_APP_PRIVATE_KEY: privateKey }, fetch: fetchStub });
            const rd = createFallbackReader({ github, store: { getFallbackSwitches: () => [DN('CI_LINUX_RUNNER', 'LINUX')] }, logger: { warn() {} } });
            await rd.start();
            const sw = rd.snapshot().switches[0];
            assert.equal(sw.armed, null);
            assert.equal(sw.reason, 'GitHub returned a malformed response');
            rd.stop();
        }
    });
});

describe('reader state machine probes', () => {
    test('a 304 with NO stored etag never marks a never-read switch as checked', async () => {
        const h = reader(() => ({ notModified: true, etag: null }));
        await h.rd.start();
        const sw = h.rd.snapshot().switches[0];
        assert.equal(sw.armed, null);
        assert.equal(sw.checkedAt, null, 'a bogus 304 is not a confirmation of anything');
        h.rd.stop();
    });

    test('a 304 for a switch that has no stored etag (was 404) does not bump checkedAt', async () => {
        let n = 0;
        const h = reader(() => (++n === 1 ? { found: false } : { notModified: true, etag: null }));
        await h.rd.start();
        const first = h.rd.snapshot().switches[0].checkedAt;
        assert.ok(first);
        h.advance(60000);
        await h.rd.refreshNow();
        const sw = h.rd.snapshot().switches[0];
        assert.equal(sw.armed, false);
        assert.equal(sw.checkedAt, first, 'unsolicited 304 left the age alone');
        h.rd.stop();
    });

    test('switch removed mid-read: the late result does not resurrect it', async () => {
        let release; const gate = new Promise((r) => { release = r; });
        const h = reader(async () => { await gate; return { found: true, value: '["self-hosted"]', etag: 'e' }; });
        const p = h.rd.start();
        await settle();
        h.setList([]);
        const c = h.rd.onSwitchesChanged();
        release();
        await Promise.all([p, c]);
        assert.deepEqual(h.rd.snapshot().switches, []);
        assert.equal(h.rd.snapshot().linux, null);
        h.rd.stop();
    });

    test('stop() during the first in-flight read, late resolution: no timer is armed', async () => {
        let release; const gate = new Promise((r) => { release = r; });
        const h = reader(async () => { await gate; return { found: true, value: '["self-hosted"]', etag: null }; });
        const p = h.rd.start();
        await settle();
        h.rd.stop();
        release();
        await p;
        await settle(); await settle();
        assert.equal(h.timers.filter((t) => !t.cleared).length, 0, 'no live timer after stop');
    });

    test('stop() during a TICK read, late resolution: no timer is re-armed', async () => {
        let n = 0; let release; const gate = new Promise((r) => { release = r; });
        const h = reader(async () => { if (++n > 1) await gate; return { found: true, value: '["self-hosted"]', etag: null }; });
        await h.rd.start(); await settle();
        const t = h.timers[h.timers.length - 1];
        const armed = h.timers.length;
        const tickP = t.fn();                       // the timer FIRED: it is spent, not live
        await settle();
        h.rd.stop();
        release();
        await tickP;
        await settle();
        assert.equal(h.timers.length, armed, 'no new timer armed after stop');
    });

    test('a synchronously throwing github client never rejects start/refreshNow/onSwitchesChanged', async () => {
        const bad = { getRepoVariable() { throw new Error('sync boom ghs_SECRET'); } };
        const logs = [];
        const rd = createFallbackReader({ github: bad, store: { getFallbackSwitches: () => [DN('CI_LINUX_RUNNER', 'L')] }, logger: { warn: (m) => logs.push(m) }, minRefreshIntervalMs: 0 });
        await rd.start();
        await rd.refreshNow();
        await rd.onSwitchesChanged();
        assert.equal(rd.snapshot().switches[0].armed, null);
        assert.ok(!(JSON.stringify(rd.snapshot()) + logs.join('')).includes('ghs_SECRET'));
        rd.stop();
    });

    test('a throwing store.getFallbackSwitches degrades to an empty list', async () => {
        const rd = createFallbackReader({ github: { getRepoVariable: async () => ({ found: false }) }, store: { getFallbackSwitches() { throw new Error('x'); } }, logger: { warn() {} } });
        await rd.start();
        assert.deepEqual(rd.snapshot().switches, []);
        rd.stop();
    });
});

describe('secret hygiene', () => {
    const TOKEN = 'ghs_LEAKSENTINEL1465tokenAAAA';
    const JWT = 'eyJhbGciOiJSUzI1NiJ9.LEAKSENTINEL1465jwt.sig';
    const KEY_MARK = 'LEAKSENTINEL1465PRIVATEKEY';

    test('errors carrying token/JWT/key text never reach snapshot, logs or the HTTP body', async () => {
        const logs = [];
        const h = reader(() => { const e = new Error(`${TOKEN} ${JWT} -----BEGIN PRIVATE KEY-----${KEY_MARK}`); e.status = 500; throw e; }, { logs });
        await h.rd.start();
        const dir = fs.mkdtempSync(path.join(TMP, 'leak-'));
        const store = createPoolStore({ file: path.join(dir, 'p.json'), logger: { log() {}, warn() {}, error() {} } });
        store.load();
        const app = express();
        registerCiRunnersRoutes(app, { file: path.join(dir, 'r.json'), poolStore: store, fallbackReader: h.rd });
        const r = await request(app).get('/api/ci-runners?refresh=1');
        const blob = JSON.stringify(h.rd.snapshot()) + logs.join('\n') + JSON.stringify(r.body) + JSON.stringify(r.headers);
        for (const s of [TOKEN, JWT, KEY_MARK, 'PRIVATE KEY']) assert.ok(!blob.includes(s), `leaked ${s}`);
        h.rd.stop();
    });

    test('real client: a 500 body echoing the token is not surfaced anywhere', async () => {
        const { privateKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048,
            publicKeyEncoding: { type: 'spki', format: 'pem' }, privateKeyEncoding: { type: 'pkcs8', format: 'pem' } });
        const R = (status, b) => ({ status, headers: { get: () => null }, json: async () => b });
        const fetchStub = async (url) => {
            const u = new URL(url);
            if (/\/installation$/.test(u.pathname)) return R(200, { id: 1 });
            if (/\/access_tokens$/.test(u.pathname)) return R(201, { token: TOKEN, expires_at: new Date(Date.now() + 3600e3).toISOString() });
            return R(500, { message: `bad ${TOKEN}` });
        };
        const github = createGithubClient({ config: { GITHUB_APP_ID: '1', GITHUB_APP_PRIVATE_KEY: privateKey }, fetch: fetchStub });
        const logs = [];
        const rd = createFallbackReader({ github, store: { getFallbackSwitches: () => [DN('CI_LINUX_RUNNER', 'L')] }, logger: { warn: (m) => logs.push(m) } });
        await rd.start();
        const blob = JSON.stringify(rd.snapshot()) + logs.join('\n');
        assert.ok(!blob.includes(TOKEN) && !blob.includes(privateKey.slice(40, 80)));
        assert.equal(rd.snapshot().switches[0].error, 'GitHub returned HTTP 500');
        rd.stop();
    });
});

describe('route probes', () => {
    function mountRoute(readerObj) {
        const dir = fs.mkdtempSync(path.join(TMP, 'route-'));
        const store = createPoolStore({ file: path.join(dir, 'p.json'), logger: { log() {}, warn() {}, error() {} } });
        store.load();
        const app = express();
        registerCiRunnersRoutes(app, { file: path.join(dir, 'r.json'), poolStore: store, fallbackReader: readerObj });
        return app;
    }

    test('100 concurrent ?refresh=1 => ONE read cycle (3 switches => 3 GitHub variable calls)', async () => {
        const h = reader(async () => { await settle(); return { found: true, value: '["self-hosted"]', etag: null }; },
            { switches: [DN('CI_LINUX_RUNNER', 'A'), DN('CI_MACOS_RUNNER', 'B'), DN('CI_LINUX_RUNNER_HEAVY', 'C')] });
        // ONE listening server: request(app) would open 100 ephemeral listeners and time out under load.
        const app = await new Promise((resolve) => { const srv = mountRoute(h.rd).listen(0, '127.0.0.1', () => resolve(srv)); });
        const rs = await Promise.all(Array.from({ length: 100 }, () => request(app).get('/api/ci-runners?refresh=1')));
        assert.ok(rs.every((r) => r.status === 200));
        assert.ok(h.calls.length <= 3, `GitHub calls: ${h.calls.length}`);
        const again = await request(app).get('/api/ci-runners?refresh=1');
        app.close();
        assert.equal(again.body.refresh.throttled, true);
        assert.ok(h.calls.length <= 3);
        h.rd.stop();
    });

    test('a reader whose refreshNow throws synchronously still answers 200 with no detail', async () => {
        const app = mountRoute({ refreshNow() { throw new Error('sync ghs_SECRET'); }, snapshot: () => null });
        const r = await request(app).get('/api/ci-runners?refresh=1');
        assert.equal(r.status, 200);
        assert.deepEqual(r.body.refresh, { ran: false });
        assert.ok(!JSON.stringify(r.body).includes('ghs_SECRET'));
    });

    test('a reader whose snapshot() throws yields a 500 without detail (not a hang)', async () => {
        const app = mountRoute({ refreshNow: async () => ({ ran: true }), snapshot() { throw new Error('snap ghs_SECRET'); } });
        const r = await request(app).get('/api/ci-runners');
        assert.equal(r.status, 500);
        assert.ok(!JSON.stringify(r.body).includes('ghs_SECRET'));
    });
});

describe('pill rendering: long / unicode labels', () => {
    const CICD_JS = path.join(__dirname, '..', 'public', 'lcars', 'js', 'lcars-cicd.js');
    const FIXTURE = path.join(__dirname, 'fixtures', 'xaca-1388-ci-runners-healthy.json');
    test('a 32-char unicode label renders as text, escaped, with the state kept', () => {
        const label = 'テスト\u{1F680}<b>x</b>&"\''.padEnd(32, 'é').slice(0, 32);
        const dom = new JSDOM('<!doctype html><body><div id="cicd-content"></div></body>', { runScripts: 'outside-only', url: 'http://localhost/' });
        dom.window.eval(fs.readFileSync(CICD_JS, 'utf8'));
        const data = JSON.parse(fs.readFileSync(FIXTURE, 'utf8'));
        data.fallback = { linux: null, macos: null, checkedAt: null, switches: [
            { owner: 'DoubleNode', repo: 'dev-team', variable: 'CI_X', label, armed: true, reason: null, error: 'HTTP 502', checkedAt: null }] };
        const el = dom.window.document.getElementById('cicd-content');
        dom.window.LCARSCICD.render(data, el);
        assert.equal(el.querySelector('[data-cicd-slot="pills"] b'), null, 'no injected element');
        const pill = el.querySelector('[data-cicd-slot="pills"] .cicd-pill');
        assert.ok(pill.textContent.includes('<b>x</b>'));
        assert.equal(pill.getAttribute('data-cicd-state'), 'SELF-HOSTED');
        assert.match(pill.getAttribute('title'), /last read failed: HTTP 502/);
    });
});
