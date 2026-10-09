//
//  xaca-1400-008-review-round1.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * PR #1120 review round 1 + test-gate advisories:
 *  1. one timezone validator shared by the push route and quiet hours
 *  2. dedupe is per connection
 *  3. send timeout aborts the provider's AbortSignal; rate slot not spent on unknown connection
 *  4. PUT connection after NOTIFY_STORE_KEY change: full resupply works, partial is 409
 *  5. header/order statement (checked via behaviour: quiet hours beat dedupe receipts)
 */

const { test, describe } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');

const teamRoutes = require('../lib/notify-team-routes');
const policies = require('../lib/notify-policies');
const { createNotifyDispatcher } = require('../lib/notify-dispatcher');
const { createReceiptLog } = require('../lib/notify-receipts');
const { createProviderRegistry, createTestProvider } = require('../lib/notify-providers');
const { createNotifyStore, NotifySecretsUnreadableError } = require('../lib/notify-store');

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ------------------------------------------------------------------ 1. timezone
describe('timezone: push validator and send-time quiet hours agree', () => {
    const canonical = teamRoutes.loadCanonicalCatalog();
    const CASES = [
        ['America/Chicago', true],
        ['UTC', true],
        ['US/Central', true], // Python available_timezones() includes the alias
        ['america/chicago', false],
        ['utc', false],
        ['AMERICA/CHICAGO', false],
        ['+05:00', false],
        ['-08:00', false],
        ['Not/AZone', false],
        ['garbage', false],
        ['', false],
        ['A'.repeat(65), false],
    ];
    for (const [zone, ok] of CASES) {
        test(`${JSON.stringify(zone.slice(0, 20))} -> ${ok ? 'accepted' : 'refused'} at BOTH`, () => {
            const quietHours = { start: '10:00', end: '20:00', timezone: zone };
            const push = teamRoutes.validateTeamPush({
                config: { $schema: 'release-notify/v2', version: 2, routes: {}, quietHours },
            }, canonical);
            const d = policies.quietHoursDecision('info', quietHours, new Date('2026-03-01T15:00:00Z'));
            const sendHonours = d.warning !== 'invalid-timezone';
            assert.equal(push.ok, ok, `push: ${JSON.stringify(push.errors)}`);
            assert.equal(sendHonours, ok, 'send-time disagrees with push');
            assert.equal(push.ok, sendHonours);
            assert.equal(policies.isValidTimeZone(zone), ok);
        });
    }
});

// ------------------------------------------------------- dispatcher test harness
function harness(over = {}) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca1400-008-'));
    const clockState = { now: new Date('2026-03-01T15:00:00Z') };
    const clock = () => clockState.now;
    const provider = createTestProvider();
    const registry = createProviderRegistry();
    registry.register('test', provider);
    const conns = { 'conn-a': true, 'conn-b': true, ...(over.conns || {}) };
    const config = { routes: { 'pr-merged': ['conn-a', 'conn-b'] }, ...(over.config || {}) };
    const catalog = { 'pr-merged': { defaultSeverity: 'info' } };
    const store = {
        getTeamRoutes: () => ({ config, catalog }),
        resolveConnection: (id) => (conns[id] ? { id, provider: 'test', secrets: { token: 'tok-secret-value' }, params: {} } : null),
    };
    const receipts = createReceiptLog({ file: path.join(dir, 'r.jsonl'), clock });
    const rateLimiter = over.rateLimiter || policies.createRateLimiter({ clock });
    const dispatcher = createNotifyDispatcher({ store, registry, receipts, clock, rateLimiter, sendTimeoutMs: over.sendTimeoutMs || 200 });
    const notice = { team: 'academy', type: 'pr-merged', title: 't', body: 'b', ref: 'PR-1' };
    return { dispatcher, provider, notice, clockState, rateLimiter, dir };
}

// ------------------------------------------------------------ 2. per-connection dedupe
describe('dedupe is per connection', () => {
    test('connection that failed is retried; the one that delivered is suppressed', async () => {
        const h = harness();
        h.provider.failNext(1); // first send (conn-a) fails
        const r1 = await h.dispatcher.dispatch(h.notice);
        assert.equal(r1.delivered, 1);
        assert.equal(r1.failed, 1);
        const failedId = r1.receipts.find((x) => !x.ok).connectionId;
        const okId = r1.receipts.find((x) => x.ok).connectionId;
        h.provider.calls.length = 0;
        const r2 = await h.dispatcher.dispatch(h.notice);
        assert.deepEqual(h.provider.calls.map((c) => c.connectionId), [failedId], 'only the failed connection is attempted again');
        const sup = r2.receipts.find((x) => x.connectionId === okId);
        assert.equal(sup.suppressed, 'dedupe');
        assert.equal(sup.ok, false);
        assert.equal(r2.receipts.find((x) => x.connectionId === failedId).ok, true);
        assert.equal(r2.delivered, 1);
        assert.equal(r2.suppressed, 1);
        // third time: both have delivered -> both suppressed
        const r3 = await h.dispatcher.dispatch(h.notice);
        assert.equal(r3.suppressed, 2);
    });

    test('tracker keys include the connection id and stay Python-compatible without it', () => {
        const d = policies.createDedupeTracker();
        assert.equal(d.check('t', 'x', 'r', 300).key, 't|x|r');
        assert.equal(d.check('t', 'x', 'r', 300, 'conn-a').key, 't|x|r|conn-a');
        d.record('t', 'x', 'r', 300, 'conn-a');
        assert.equal(d.check('t', 'x', 'r', 300, 'conn-a').duplicate, true);
        assert.equal(d.check('t', 'x', 'r', 300, 'conn-b').duplicate, false);
    });

    test('quiet hours (notice-level) win over dedupe: receipts say quiet-hours', async () => {
        const h = harness({ config: { routes: { 'pr-merged': ['conn-a'] }, quietHours: { start: '10:00', end: '20:00', timezone: 'UTC' } } });
        const crit = await h.dispatcher.dispatch({ ...h.notice, severity: 'critical' });
        assert.equal(crit.delivered, 1);
        const r = await h.dispatcher.dispatch({ ...h.notice, severity: 'info' });
        assert.equal(r.receipts[0].suppressed, 'quiet-hours');
    });
});

// ------------------------------------------------------------------ 3. abort signal
describe('timeout aborts the send', () => {
    test('hung test-provider send is aborted; receipt says send timed out; nothing changes later', async () => {
        const h = harness({ sendTimeoutMs: 30, config: { routes: { 'pr-merged': ['conn-a'] } } });
        h.provider.holdSends(true);
        const r = await h.dispatcher.dispatch(h.notice);
        assert.equal(r.receipts[0].error, 'send timed out');
        assert.equal(r.receipts[0].ok, false);
        assert.equal(r.delivered, 0);
        assert.equal(h.provider.calls[0].aborted, true, 'signal was aborted');
        const lines = fs.readFileSync(path.join(h.dir, 'r.jsonl'), 'utf8').trim().split('\n').length;
        await sleep(60);
        assert.equal(fs.readFileSync(path.join(h.dir, 'r.jsonl'), 'utf8').trim().split('\n').length, lines);
        // timed-out connection opened no dedupe window
        h.provider.holdSends(false);
        assert.equal((await h.dispatcher.dispatch(h.notice)).delivered, 1);
    });

    test('providers receive { signal } as the third argument', async () => {
        const h = harness();
        let seen;
        const orig = h.provider.send;
        h.provider.send = async (c, m, ctx) => { seen = ctx; return orig(c, m, ctx); };
        await h.dispatcher.dispatch(h.notice);
        assert.ok(seen && typeof seen.signal.aborted === 'boolean');
        assert.equal(seen.signal.aborted, false);
    });

    test('unknown connection does not spend a rate-limit slot', async () => {
        const rateLimiter = policies.createRateLimiter({ limit: 1 });
        const h = harness({ rateLimiter, conns: { 'conn-a': false }, config: { routes: { 'pr-merged': ['conn-a'] } } });
        for (let i = 0; i < 3; i += 1) {
            const r = await h.dispatcher.dispatch(h.notice);
            assert.equal(r.receipts[0].error, 'unknown connection', `attempt ${i}`);
        }
        assert.equal(rateLimiter.size(), 0, 'no bucket created for an unresolvable connection');
    });
});

// ------------------------------------------------- 4. key rotation on PUT connection
describe('PUT connection after NOTIFY_STORE_KEY change', () => {
    const stub = {
        name: 'stub', paramFields: [], secretFields: ['token', 'extra'],
        validate() {},
    };
    const registry = { has: (n) => n === 'stub', get: () => stub, names: () => ['stub'] };
    const keyA = crypto.randomBytes(32).toString('hex');
    const keyB = crypto.randomBytes(32).toString('hex');

    function rotated() {
        const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca1400-008-key-'));
        const file = path.join(dir, 's.json');
        const a = createNotifyStore({ file, key: keyA, registry });
        a.createConnection({ id: 'c1', provider: 'stub', label: 'c1', secrets: { token: 'OLD-token-AAA', extra: 'OLD-extra-AAA' } });
        return createNotifyStore({ file, key: keyB, registry });
    }

    test('patch supplying every stored secret succeeds without decrypting the old ones', () => {
        const b = rotated();
        const view = b.updateConnection('c1', { secrets: { token: 'NEW-token-BBB', extra: 'NEW-extra-BBB' } });
        assert.ok(view);
        const r = b.resolveConnection('c1');
        assert.equal(r.secrets.token, 'NEW-token-BBB');
        assert.equal(r.secrets.extra, 'NEW-extra-BBB');
    });

    test('clearing one and replacing the other also succeeds', () => {
        const b = rotated();
        b.updateConnection('c1', { secrets: { token: 'NEW-token-BBB', extra: null } });
        const r = b.resolveConnection('c1');
        assert.equal(r.secrets.token, 'NEW-token-BBB');
        assert.equal(r.secrets.extra, undefined);
    });

    test('partial patch that must keep an unreadable secret is a clear 409, no values echoed', () => {
        const b = rotated();
        let err;
        try { b.updateConnection('c1', { label: 'renamed', secrets: { token: 'NEW-token-BBB' } }); } catch (e) { err = e; }
        assert.ok(err instanceof NotifySecretsUnreadableError);
        assert.equal(err.status, 409);
        assert.equal(err.code, 'secrets_unreadable');
        for (const s of ['OLD-token-AAA', 'OLD-extra-AAA', 'NEW-token-BBB']) assert.ok(!err.message.includes(s));
        assert.match(err.message, /resupply/);
        // label-only patch also needs the old secrets for validation -> 409, not 500
        assert.throws(() => b.updateConnection('c1', { label: 'x' }), (e) => e.status === 409);
    });
});
