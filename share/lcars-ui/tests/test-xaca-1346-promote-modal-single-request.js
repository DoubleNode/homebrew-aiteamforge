#!/usr/bin/env node
//
//  test-xaca-1346-promote-modal-single-request.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright (c) 2026 DoubleNode.com. All rights reserved.
//

/**
 * XACA-1346-039/042: release stage state is RELEASE-LEVEL, so the PROMOTE modal's
 * `executePromotion()` must send exactly ONE POST per user action, no matter how many
 * platforms are ticked. It used to loop one `{platform}` POST per platform, and every POST
 * advanced the whole release (N platforms = N stages).
 *
 * Also covers the refusal display (XACA-1346-041/044): a 409 gate refusal carries `reasons[]`
 * (and `error`); the modal must show those, not "HTTP 409".
 *
 * lcars.js is a big browser file with top-level DOM calls, so, like the sibling suites, this
 * slices `executePromotion` out between two textual anchors and evaluates only that. A missing
 * anchor FAILS loudly.
 *
 * Run: node lcars-ui/tests/test-xaca-1346-promote-modal-single-request.js
 */

'use strict';

const fs = require('fs');
const path = require('path');
const assert = require('assert');
const vm = require('vm');

const source = fs.readFileSync(path.join(__dirname, '..', 'js', 'lcars.js'), 'utf8');
const START = 'async function executePromotion() {';
const END = '/**\n * Display promotion results\n */';
const s = source.indexOf(START);
const e = source.indexOf(END);
if (s === -1 || e === -1 || e <= s) {
    console.error('FAIL: could not locate executePromotion / displayPromotionResults anchors in lcars.js');
    process.exit(1);
}
const slice = source.slice(s, e);

let failures = 0;
function ok(name) { console.log('ok - ' + name); }
async function test(name, fn) {
    try { await fn(); ok(name); } catch (err) {
        failures += 1;
        console.error('FAIL: ' + name + ': ' + (err && err.message));
    }
}

function makeSandbox(selected, responder) {
    const calls = [];
    const shown = [];
    const el = { textContent: '', style: {} };
    const sandbox = {
        promoteModalState: { releaseId: 'REL-1', selectedPlatforms: selected, promotionResults: [] },
        document: { getElementById: () => el },
        apiUrl: (p) => p,
        apiFetch: async (url, opts) => { calls.push({ url, opts }); return responder(calls.length); },
        displayPromotionResults: (r) => shown.push(r),
        setTimeout: (fn) => fn(),
        JSON, Array, Promise,
    };
    vm.createContext(sandbox);
    vm.runInContext(slice + '\nthis.executePromotion = executePromotion;', sandbox);
    return { sandbox, calls, shown };
}

const okResp = (body) => ({ ok: true, status: 200, json: async () => body });
const errResp = (status, body) => ({ ok: false, status, json: async () => body });

(async () => {
    for (const n of [1, 2, 3]) {
        await test('one POST for ' + n + ' selected platform(s)', async () => {
            const plats = ['ios', 'android', 'firebase'].slice(0, n);
            const { sandbox, calls } = makeSandbox(plats, () => okResp({ previousEnvironment: 'QA', newEnvironment: 'ALPHA' }));
            await sandbox.executePromotion();
            assert.strictEqual(calls.length, 1, 'expected exactly one request, got ' + calls.length);
            assert.strictEqual(calls[0].url, '/api/releases/REL-1/promote');
            assert.strictEqual(calls[0].opts.method, 'POST');
        });
    }

    await test('body is release-level: no platform key, no per-platform target', async () => {
        const { sandbox, calls } = makeSandbox(['ios', 'android'], () => okResp({}));
        await sandbox.executePromotion();
        const body = JSON.parse(calls[0].opts.body);
        assert.ok(!('platform' in body), 'body must not carry `platform`');
        assert.ok(!('targetEnvironment' in body), 'body must not carry legacy targetEnvironment');
        assert.strictEqual(body.confirmDeploy, false);
        assert.strictEqual(typeof body.actor, 'string');
    });

    await test('a 409 refusal shows the gate reasons, not HTTP 409', async () => {
        const { sandbox, shown } = makeSandbox(['ios'], () => errResp(409, {
            allowed: false, reasons: ['QA: expected test t2 missing', 'QA: t3 FAIL'], error: 'QA: expected test t2 missing (+1 more)' }));
        await sandbox.executePromotion();
        assert.strictEqual(shown.length, 1);
        const r = shown[0][0];
        assert.strictEqual(r.success, false);
        assert.ok(r.error.includes('t2 missing') && r.error.includes('t3 FAIL'), r.error);
        assert.ok(!r.error.includes('HTTP 409'));
    });

    await test('falls back to `error`, then to HTTP status', async () => {
        let { sandbox, shown } = makeSandbox(['ios'], () => errResp(400, { error: 'target required' }));
        await sandbox.executePromotion();
        assert.strictEqual(shown[0][0].error, 'target required');
        ({ sandbox, shown } = makeSandbox(['ios'], () => errResp(500, {})));
        await sandbox.executePromotion();
        assert.strictEqual(shown[0][0].error, 'HTTP 500');
    });

    await test('a network failure is reported once, not per platform', async () => {
        const { sandbox, shown, calls } = makeSandbox(['ios', 'android'], () => { throw new Error('boom'); });
        await sandbox.executePromotion();
        assert.strictEqual(calls.length, 1);
        assert.strictEqual(shown[0].length, 1);
        assert.strictEqual(shown[0][0].error, 'boom');
    });

    await test('success result carries previous/new stage from the response', async () => {
        const { sandbox, shown } = makeSandbox(['ios'], () => okResp({ from: 'QA', to: 'ALPHA' }));
        await sandbox.executePromotion();
        assert.strictEqual(shown[0][0].previousEnvironment, 'QA');
        assert.strictEqual(shown[0][0].newEnvironment, 'ALPHA');
    });

    if (failures) { process.exit(1); }
})();
