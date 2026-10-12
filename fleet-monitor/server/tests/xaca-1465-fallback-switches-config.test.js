//
//  xaca-1465-fallback-switches-config.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1465-003 -- operator-editable fallback-switch list: store + admin routes.
 * Real store in temp dirs, real auth middleware with fake env tokens. NO network.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const { test, describe, after } = require('node:test');
const assert = require('node:assert/strict');
const request = require('./helpers/loopback-request');
const express = require('express');

const FLEET = 'xaca1465-fake-fleet-token-aaaaaaaa';
const ADMIN = 'xaca1465-fake-admin-token-bbbbbbbb';
const SAVED = { a: process.env.FLEET_AUTH_TOKEN, b: process.env.FLEET_ADMIN_TOKEN };
process.env.FLEET_AUTH_TOKEN = FLEET;
process.env.FLEET_ADMIN_TOKEN = ADMIN;

const S = require('../lib/ci-pool-store');
const { createAssignments } = require('../lib/ci-dispatch-assignments');
const { registerCiPoolRoutes } = require('../lib/ci-pool-routes');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca1465-003-'));
after(() => {
    fs.rmSync(TMP, { recursive: true, force: true });
    for (const [k, v] of [['FLEET_AUTH_TOKEN', SAVED.a], ['FLEET_ADMIN_TOKEN', SAVED.b]]) {
        if (v === undefined) delete process.env[k]; else process.env[k] = v;
    }
});

let seq = 0;
const quiet = { error() {}, warn() {} };
function tmpStore() {
    const dir = path.join(TMP, `s${++seq}`);
    const file = path.join(dir, 'data', 'ci-pool.json');
    const store = S.createPoolStore({ file, logger: quiet });
    store.load();
    return { dir, file, store };
}

const sw = (over = {}) => Object.assign({ owner: 'MainEventEntertainment', repo: 'MainEventApp-Android', variable: 'CI_RUNNER', label: 'ANDROID' }, over);
const DEV3 = ['CI_LINUX_RUNNER', 'CI_MACOS_RUNNER', 'CI_LINUX_RUNNER_HEAVY'];

describe('store: defaults and persistence', () => {
    test('unset -> dev-team defaults, as a defensive copy; the constant is deep-frozen', () => {
        const { store } = tmpStore();
        const d = store.getFallbackSwitches();
        assert.deepEqual(d.map((e) => e.variable), DEV3);
        assert.deepEqual(d.map((e) => e.label), ['LINUX', 'MACOS', 'LINUX HEAVY']);
        assert.ok(d.every((e) => e.owner === 'DoubleNode' && e.repo === 'dev-team'));
        d[0].variable = 'MUTATED'; d.push({});
        assert.deepEqual(store.getFallbackSwitches().map((e) => e.variable), DEV3);
        assert.ok(Object.isFrozen(S.DEFAULT_FALLBACK_SWITCHES) && S.DEFAULT_FALLBACK_SWITCHES.every(Object.isFrozen));
        assert.deepEqual(S.validatePool(S.defaultPool()), []);
    });

    test('round trip: persisted, survives reload, returns copies', () => {
        const { store, file } = tmpStore();
        assert.deepEqual(store.setFallbackSwitches([sw(), sw({ variable: 'CI_X', label: 'X' })]), { ok: true });
        const again = S.createPoolStore({ file, logger: quiet });
        assert.deepEqual(again.load(), { ok: true });
        assert.deepEqual(again.getFallbackSwitches(), [sw(), sw({ variable: 'CI_X', label: 'X' })]);
        const got = again.getFallbackSwitches(); got[0].label = 'Z';
        assert.equal(again.getFallbackSwitches()[0].label, 'ANDROID');
    });

    test('the caller-owned input object is not retained', () => {
        const { store } = tmpStore();
        const input = [sw()];
        store.setFallbackSwitches(input);
        input[0].label = 'CHANGED';
        assert.equal(store.getFallbackSwitches()[0].label, 'ANDROID');
    });

    test('explicit [] is allowed, persists, and is distinct from unset', () => {
        const { store, file } = tmpStore();
        assert.equal(store.setFallbackSwitches([]).ok, true);
        assert.deepEqual(store.getFallbackSwitches(), []);
        const again = S.createPoolStore({ file, logger: quiet });
        again.load();
        assert.deepEqual(again.getFallbackSwitches(), []);
    });

    test('null clears back to defaults (and removes the key from the file)', () => {
        const { store, file } = tmpStore();
        store.setFallbackSwitches([]);
        assert.equal(store.setFallbackSwitches(null).ok, true);
        assert.deepEqual(store.getFallbackSwitches().map((e) => e.variable), DEV3);
        assert.equal('fallbackSwitches' in JSON.parse(fs.readFileSync(file, 'utf8')), false);
    });

    test('a pool file written before this field existed still loads and reads defaults', () => {
        const { store, file } = tmpStore();
        store.upsertMachine('m4mini', { enabled: true });
        assert.equal('fallbackSwitches' in JSON.parse(fs.readFileSync(file, 'utf8')), false);
        const again = S.createPoolStore({ file, logger: quiet });
        assert.deepEqual(again.load(), { ok: true });
        assert.equal(again.getFallbackSwitches().length, 3);
        assert.equal(again.getMachine('m4mini').enabled, true);
    });

    test('a hand-edited file with a bad switch list is moved aside, not half-trusted', () => {
        const { store, file } = tmpStore();
        store.setFallbackSwitches([sw()]);
        const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
        raw.fallbackSwitches[0].variable = '1bad';
        fs.writeFileSync(file, JSON.stringify(raw));
        const again = S.createPoolStore({ file, logger: quiet });
        assert.equal(again.load().ok, false);
        assert.equal(again.getFallbackSwitches().length, 3);
    });

    test('a failed write rolls the in-memory list back', () => {
        const { store, file } = tmpStore();
        store.setFallbackSwitches([sw()]);
        fs.rmSync(path.dirname(file), { recursive: true, force: true });
        fs.writeFileSync(path.dirname(file), 'a file where the dir should be');
        const r = store.setFallbackSwitches([sw({ label: 'NEW' })]);
        assert.equal(r.ok, false);
        assert.match(r.error, /^write failed/);
        assert.equal(store.getFallbackSwitches()[0].label, 'ANDROID');
    });
});

describe('store: validation rejections (no state change)', () => {
    const noOwner = sw(); delete noOwner.owner;
    const cases = [
        ['not an array', { owner: 'a' }, /must be an array/],
        ['undefined', undefined, /must be an array/],
        ['entry not an object', ['x'], /must be an object/],
        ['unknown field', [sw({ extra: 1 })], /unknown field "extra"/],
        ['missing owner', [noOwner], /owner/],
        ['owner leading hyphen', [sw({ owner: '-bad' })], /owner/],
        ['owner too long (40)', [sw({ owner: 'a'.repeat(40) })], /owner/],
        ['owner with slash', [sw({ owner: 'a/b' })], /owner/],
        ['owner not a string', [sw({ owner: 5 })], /owner/],
        ['repo empty', [sw({ repo: '' })], /repo/],
        ['repo with slash', [sw({ repo: 'a/b' })], /repo/],
        ['repo too long (101)', [sw({ repo: 'r'.repeat(101) })], /repo/],
        ['variable leading digit', [sw({ variable: '1X' })], /variable/],
        ['variable with hyphen', [sw({ variable: 'A-B' })], /variable/],
        ['variable too long (256)', [sw({ variable: 'V'.repeat(256) })], /variable/],
        ['label empty', [sw({ label: '' })], /label/],
        ['label whitespace only', [sw({ label: '   ' })], /label/],
        ['label untrimmed', [sw({ label: ' X' })], /label/],
        ['label too long (33)', [sw({ label: 'L'.repeat(33) })], /label/],
        ['label control char', [sw({ label: 'A\nB' })], /label/],
        ['label non-ASCII', [sw({ label: 'café' })], /label/],
        ['label not a string', [sw({ label: 7 })], /label/],
    ];
    for (const [name, input, re] of cases) {
        test(name, () => {
            const { store, file } = tmpStore();
            store.setFallbackSwitches([sw({ label: 'KEEP' })]);
            const before = fs.readFileSync(file, 'utf8');
            const r = store.setFallbackSwitches(input);
            assert.equal(r.ok, false);
            assert.match(r.error, re);
            assert.equal(store.getFallbackSwitches()[0].label, 'KEEP');
            assert.equal(fs.readFileSync(file, 'utf8'), before);
        });
    }

    test('boundary values are accepted: 39-char owner, 100-char repo, 255-char variable, 32-char label', () => {
        const { store } = tmpStore();
        const r = store.setFallbackSwitches([{ owner: 'a'.repeat(39), repo: 'r'.repeat(100), variable: 'V'.repeat(255), label: 'L'.repeat(32) }]);
        assert.deepEqual(r, { ok: true });
    });

    test('21 entries rejected, 20 accepted', () => {
        const { store } = tmpStore();
        const mk = (n) => Array.from({ length: n }, (_, i) => sw({ variable: `V${i}` }));
        assert.match(store.setFallbackSwitches(mk(21)).error, /at most 20/);
        assert.equal(store.setFallbackSwitches(mk(20)).ok, true);
    });

    test('duplicate (owner, repo, variable) is rejected case-insensitively; a different label does not make it unique', () => {
        const { store } = tmpStore();
        const r = store.setFallbackSwitches([sw(), sw({ owner: 'mainevententertainment', variable: 'ci_runner', label: 'OTHER' })]);
        assert.equal(r.ok, false);
        assert.match(r.error, /duplicate/);
        assert.equal(store.setFallbackSwitches([sw(), sw({ repo: 'Other' })]).ok, true);
        assert.equal(store.setFallbackSwitches([sw(), sw({ variable: 'CI_OTHER' })]).ok, true);
    });
});

describe('routes: /api/ci-pool/fallback-switches (admin tier)', () => {
    function setup(opts = {}) {
        const { dir, store } = tmpStore();
        const assignments = createAssignments({ file: path.join(dir, 'state.json'), github: { async generateJitConfig() { throw new Error('no network'); }, async deleteRunner() { throw new Error('no network'); } }, now: () => Date.now(), logger: quiet });
        const calls = [];
        const app = express();
        app.use(express.json());
        registerCiPoolRoutes(app, Object.assign({
            store, assignments, logger: quiet, onFallbackSwitchesChanged: (l) => calls.push(l),
        }, opts));
        return { app, store, calls };
    }
    const withTok = (r, tok) => (tok ? r.set('Authorization', `Bearer ${tok}`) : r);
    const URL = '/api/ci-pool/fallback-switches';

    test('GET and PUT: no key, fleet key and garbage are 401; nothing changes, no callback', async () => {
        const s = setup();
        for (const tok of [null, FLEET, 'nope']) {
            assert.equal((await withTok(request(s.app).get(URL), tok)).status, 401, `GET ${tok}`);
            assert.equal((await withTok(request(s.app).put(URL), tok).send({ switches: [] })).status, 401, `PUT ${tok}`);
        }
        assert.equal(s.store.getFallbackSwitches().length, 3);
        assert.equal(s.calls.length, 0);
    });

    test('GET returns the defaults when unset', async () => {
        const s = setup();
        const r = await withTok(request(s.app).get(URL), ADMIN);
        assert.equal(r.status, 200);
        assert.equal(r.body.schemaVersion, 1);
        assert.deepEqual(r.body.switches.map((e) => e.variable), DEV3);
    });

    test('PUT valid: 200, persisted, GET reflects it, callback fires once with the new list, audited', async () => {
        const rows = [];
        const s = setup({ audit: { append: (e, f) => rows.push([e, f]) } });
        const list = [sw()];
        const r = await withTok(request(s.app).put(URL), ADMIN).send({ switches: list });
        assert.equal(r.status, 200);
        assert.deepEqual(r.body, { success: true, switches: list });
        assert.deepEqual(s.store.getFallbackSwitches(), list);
        assert.deepEqual((await withTok(request(s.app).get(URL), ADMIN)).body.switches, list);
        assert.deepEqual(s.calls, [list]);
        assert.deepEqual(rows, [['fallback-switches', { by: 'operator', state: 'set', reason: 'count=1' }]]);
    });

    test('PUT {switches:[]} is allowed and means read nothing; callback fires', async () => {
        const s = setup();
        const r = await withTok(request(s.app).put(URL), ADMIN).send({ switches: [] });
        assert.equal(r.status, 200);
        assert.deepEqual(s.store.getFallbackSwitches(), []);
        assert.deepEqual(s.calls, [[]]);
    });

    test('PUT {switches:null} resets to defaults and fires the callback', async () => {
        const s = setup();
        await withTok(request(s.app).put(URL), ADMIN).send({ switches: [] });
        const r = await withTok(request(s.app).put(URL), ADMIN).send({ switches: null });
        assert.equal(r.status, 200);
        assert.equal(r.body.switches.length, 3);
        assert.equal(s.calls.length, 2);
    });

    test('PUT invalid -> 400, state unchanged, callback NOT fired, no audit row', async () => {
        const rows = [];
        const s = setup({ audit: { append: (e, f) => rows.push([e, f]) } });
        await withTok(request(s.app).put(URL), ADMIN).send({ switches: [sw({ label: 'KEEP' })] });
        s.calls.length = 0; rows.length = 0;
        const bodies = [
            { switches: [sw({ variable: '1bad' })] },
            { switches: [sw(), sw()] },
            { switches: 'x' },
            { switches: [sw({ extra: true })] },
            {},
            { switches: [], extra: 1 },
            [1],
        ];
        for (const b of bodies) {
            const r = await withTok(request(s.app).put(URL), ADMIN).send(b);
            assert.equal(r.status, 400, JSON.stringify(b));
            assert.equal(typeof r.body.error, 'string');
        }
        assert.equal(s.store.getFallbackSwitches()[0].label, 'KEEP');
        assert.equal(s.calls.length, 0);
        assert.equal(rows.length, 0);
    });

    test('a throwing callback is logged and does not fail the request; an absent callback is a no-op', async () => {
        const errs = [];
        const s = setup({ onFallbackSwitchesChanged: () => { throw new Error('boom'); }, logger: { error: (...a) => errs.push(a.join(' ')), warn() {} } });
        const r = await withTok(request(s.app).put(URL), ADMIN).send({ switches: [sw()] });
        assert.equal(r.status, 200);
        assert.ok(errs.some((e) => /onFallbackSwitchesChanged failed/.test(e)));
        const s2 = setup({ onFallbackSwitchesChanged: undefined });
        assert.equal((await withTok(request(s2.app).put(URL), ADMIN).send({ switches: [] })).status, 200);
    });
});
