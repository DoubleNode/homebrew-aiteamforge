//
//  notify-imessage-relay-routes.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1402-003: claim/ack/pool routes, the severity gate, accepted/delivered
 * receipts and the no-leak guarantees, through the REAL wireNotifyHub composition.
 */

const { test, describe, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const express = require('express');
const request = require('supertest');

const FLEET = 'fleet-' + crypto.randomBytes(8).toString('hex');
const SAVED = { a: process.env.FLEET_ADMIN_TOKEN, f: process.env.FLEET_AUTH_TOKEN };
process.env.FLEET_AUTH_TOKEN = FLEET;
delete process.env.FLEET_ADMIN_TOKEN;

const { wireNotifyHub } = require('../lib/notify-routes');
const { createImessageQueue, LEASE_MS } = require('../lib/notify-imessage-queue');
const { registerImessageRelayRoutes, createDeliveryReceiptSink } = require('../lib/notify-imessage-routes');
const { createReceiptLog } = require('../lib/notify-receipts');

const RECIP = '+15559876543';
const TITLE = 'TITLE-marker-' + crypto.randomBytes(5).toString('hex');
const BODY = 'BODY-marker-' + crypto.randomBytes(5).toString('hex');
const KEY = crypto.randomBytes(32).toString('hex');

let dir, n = 0;
before(() => { dir = fs.mkdtempSync(path.join(os.tmpdir(), 'imessage-routes-test-')); });
after(() => {
    fs.rmSync(dir, { recursive: true, force: true });
    if (SAVED.a !== undefined) process.env.FLEET_ADMIN_TOKEN = SAVED.a;
    if (SAVED.f === undefined) delete process.env.FLEET_AUTH_TOKEN; else process.env.FLEET_AUTH_TOKEN = SAVED.f;
});

const silent = { log() {}, error(...a) { silent.errors.push(a.join(' ')); }, errors: [] };

function build(connParams = {}) {
    const id = ++n;
    const t = { now: Date.parse('2026-10-10T12:00:00Z') };
    const clock = () => t.now;
    const receiptsFile = path.join(dir, `r-${id}.jsonl`);
    // Same sink wireNotifyHub builds by default, but on a fake-clock queue.
    const receipts = createReceiptLog({ file: receiptsFile, clock });
    const queue = createImessageQueue({ clock, onSettle: createDeliveryReceiptSink(receipts, silent) });
    const app = express();
    app.use(express.json());
    const hub = wireNotifyHub(app, {
        isRegisteredTeam: (x) => x === 'academy',
        logger: silent,
        storeOpts: { file: path.join(dir, `s-${id}.json`), key: KEY },
        receiptOpts: { file: receiptsFile, clock },
        imessageQueue: queue,
        imessageSweepMs: 3600 * 1000,
    });
    hub.store.createConnection({ id: 'im-main', provider: 'imessage', label: 'Phone', params: { recipient: RECIP, ...connParams }, secrets: {} });
    hub.store.setTeamRoutes('academy', { config: { $schema: 'release-notify/v2', version: 2, routes: { 'pr-merged': ['im-main'] } } });
    return { app, queue, t, receiptsFile, hub };
}

const auth = (r) => r.set('x-api-key', FLEET);
const claim = (ctx, body = { machineId: 'm1', waitSeconds: 0 }) => auth(request(ctx.app).post('/api/notify/imessage/claim')).send(body);
const ack = (ctx, body) => auth(request(ctx.app).post('/api/notify/imessage/ack')).send(body);
const notify = (ctx, over = {}) => auth(request(ctx.app).post('/api/notify'))
    .send({ team: 'academy', type: 'pr-merged', title: TITLE, body: BODY, ref: 'PR-1', severity: 'high', ...over });
const receiptLines = (ctx) => fs.readFileSync(ctx.receiptsFile, 'utf8').trim().split('\n').filter(Boolean).map((l) => JSON.parse(l));

describe('claim', () => {
    test('204 with an empty body when nothing is claimable', async () => {
        const ctx = build();
        const r = await claim(ctx);
        assert.equal(r.status, 204);
        assert.equal(r.text, '');
    });

    test('200 returns the pinned shape', async () => {
        const ctx = build();
        const sent = await notify(ctx);
        const jobId = sent.body.receipts[0].providerMessageId;
        const r = await claim(ctx);
        assert.equal(r.status, 200);
        assert.deepEqual(Object.keys(r.body).sort(), ['attempt', 'jobId', 'leaseExpiresAt', 'recipient', 'text']);
        assert.equal(r.body.jobId, jobId);
        assert.equal(r.body.recipient, RECIP);
        assert.equal(r.body.text, `[HIGH] ${TITLE}\n${BODY}`);
        assert.equal(r.body.attempt, 1);
        assert.equal(r.body.leaseExpiresAt, new Date(ctx.t.now + LEASE_MS).toISOString());
    });

    test('long-poll returns the job as soon as one is enqueued', async () => {
        const ctx = build();
        const pending = claim(ctx, { machineId: 'm1', waitSeconds: 5 }).then((r) => r);
        await new Promise((res) => setTimeout(res, 100));
        await notify(ctx);
        const r = await pending;
        assert.equal(r.status, 200);
        assert.equal(r.body.recipient, RECIP);
    });

    test('400 on bad bodies, without echoing them', async () => {
        const ctx = build();
        for (const b of [{}, { machineId: 5 }, { machineId: '' }, { machineId: 'has space' }, { machineId: 'm1', waitSeconds: 26 },
            { machineId: 'm1', waitSeconds: -1 }, { machineId: 'm1', waitSeconds: 1.5 }, { machineId: 'm1', waitSeconds: '3' }, []]) {
            const r = await claim(ctx, b);
            assert.equal(r.status, 400, JSON.stringify(b));
            assert.ok(!r.text.includes('has space'));
        }
    });
});

describe('ack', () => {
    async function leased(ctx) {
        const sent = await notify(ctx);
        const c = await claim(ctx);
        return { jobId: c.body.jobId, accepted: sent.body.receipts[0] };
    }

    test('ok ack returns {ok:true} and appends the delivered receipt with the same providerMessageId', async () => {
        const ctx = build();
        const { jobId } = await leased(ctx);
        const r = await ack(ctx, { machineId: 'm1', jobId, ok: true });
        assert.equal(r.status, 200);
        assert.deepEqual(r.body, { ok: true });
        const mine = receiptLines(ctx).filter((x) => x.providerMessageId === jobId);
        assert.deepEqual(mine.map((x) => [x.stage, x.ok]), [['accepted', true], ['delivered', true]]);
        assert.equal(mine[1].provider, 'imessage');
        assert.equal(mine[1].connectionId, 'im-main');
        assert.equal(mine[1].team, 'academy');
    });

    test('409 lease_not_held for a foreign machine and for an expired lease', async () => {
        const ctx = build();
        const { jobId } = await leased(ctx);
        let r = await ack(ctx, { machineId: 'other', jobId, ok: true });
        assert.equal(r.status, 409);
        assert.deepEqual(r.body, { error: 'lease_not_held' });
        ctx.t.now += LEASE_MS;
        r = await ack(ctx, { machineId: 'm1', jobId, ok: true });
        assert.equal(r.status, 409);
    });

    test('404 unknown_job', async () => {
        const ctx = build();
        const r = await ack(ctx, { machineId: 'm1', jobId: 'im-0000000000000000', ok: true });
        assert.equal(r.status, 404);
        assert.deepEqual(r.body, { error: 'unknown_job' });
    });

    test('400 on bad bodies', async () => {
        const ctx = build();
        const good = { machineId: 'm1', jobId: 'im-1', ok: true };
        for (const b of [{}, { ...good, machineId: undefined }, { ...good, jobId: undefined }, { ...good, jobId: '' }, { ...good, ok: 'yes' },
            { ...good, ok: undefined }, { ...good, errorType: 'has space' }, { ...good, errorType: 'x'.repeat(65) }, { ...good, errorType: 5 }]) {
            assert.equal((await ack(ctx, b)).status, 400, JSON.stringify(b));
        }
    });

    test('failover end to end: lease expires, a different machine delivers', async () => {
        const ctx = build();
        const { jobId } = await leased(ctx);
        ctx.t.now += LEASE_MS;
        assert.equal((await claim(ctx, { machineId: 'm1', waitSeconds: 0 })).status, 204, 'last holder excluded');
        const r2 = await claim(ctx, { machineId: 'm2', waitSeconds: 0 });
        assert.equal(r2.status, 200);
        assert.equal(r2.body.jobId, jobId);
        assert.equal(r2.body.attempt, 2);
        assert.equal((await ack(ctx, { machineId: 'm2', jobId, ok: true })).status, 200);
    });

    test('TTL expiry produces a failed delivery receipt', async () => {
        const ctx = build();
        const sent = await notify(ctx);
        const jobId = sent.body.receipts[0].providerMessageId;
        ctx.t.now += 10 * 60 * 1000;
        ctx.queue.sweep();
        const failed = receiptLines(ctx).filter((x) => x.providerMessageId === jobId && x.stage === 'failed');
        assert.equal(failed.length, 1);
        assert.equal(failed[0].ok, false);
        assert.equal(failed[0].error, 'imessage delivery failed (ttl_expired)');
    });

    test('attempt cap produces a failed delivery receipt', async () => {
        const ctx = build();
        const sent = await notify(ctx);
        const jobId = sent.body.receipts[0].providerMessageId;
        for (const m of ['m1', 'm2', 'm3']) {
            assert.equal((await claim(ctx, { machineId: m, waitSeconds: 0 })).status, 200);
            ctx.t.now += LEASE_MS;
        }
        ctx.queue.sweep();
        const failed = receiptLines(ctx).filter((x) => x.providerMessageId === jobId && x.stage === 'failed');
        assert.equal(failed.length, 1);
        assert.equal(failed[0].error, 'imessage delivery failed (attempts_exhausted)');
    });

    // TTL vs lease (review round 1, BLOCKING): the TTL bounds QUEUED time only. A job
    // leased before the TTL settles on its ack / lease expiry, not at the TTL.
    // Offsets are ms after enqueue; TTL = 600000, lease = 60000.
    const TTL = 10 * 60 * 1000;
    const TTL_CASES = [
        { name: 'control: claim well inside the TTL, ack ok', claimAt: 1000, then: 2000, ackOk: true, status: 200, stage: 'delivered' },
        { name: '(a) claim in the last lease-length, ack ok after the TTL', claimAt: TTL - 1000, then: TTL + 5000, ackOk: true, status: 200, stage: 'delivered' },
        { name: '(b) same, relay acks failure: its real errorType wins over ttl_expired', claimAt: TTL - 1000, then: TTL + 5000, ackOk: false, errorType: 'not_authorized', status: 200, stage: 'failed', error: 'imessage delivery failed (not_authorized)' },
        { name: '(c) claim inside the TTL, ack after the TTL but inside the lease', claimAt: TTL - 30000, then: TTL + 20000, ackOk: true, status: 200, stage: 'delivered' },
        { name: '(d) claim near the TTL, lease expires past the TTL, no ack: ttl_expired', claimAt: TTL - 1000, then: TTL - 1000 + LEASE_MS, ackOk: null, stage: 'failed', error: 'imessage delivery failed (ttl_expired)' },
    ];
    for (const c of TTL_CASES) {
        test('TTL x lease: ' + c.name, async () => {
            const ctx = build();
            const t0 = ctx.t.now;
            const sent = await notify(ctx);
            const jobId = sent.body.receipts[0].providerMessageId;
            ctx.t.now = t0 + c.claimAt;
            assert.equal((await claim(ctx)).status, 200);
            ctx.t.now = t0 + c.then;
            if (c.ackOk === null) {
                ctx.queue.sweep();
                // The late ack must now be refused; the receipt already says failed.
                assert.equal((await ack(ctx, { machineId: 'm1', jobId, ok: true })).status, 409);
            } else {
                const body = { machineId: 'm1', jobId, ok: c.ackOk };
                if (c.errorType) body.errorType = c.errorType;
                const r = await ack(ctx, body);
                assert.equal(r.status, c.status);
            }
            const settled = receiptLines(ctx).filter((x) => x.providerMessageId === jobId && x.stage !== 'accepted');
            assert.equal(settled.length, 1, 'exactly one settling receipt');
            assert.equal(settled[0].stage, c.stage);
            if (c.error) assert.equal(settled[0].error, c.error);
        });
    }

    test('TTL x lease: ack failure past the TTL never requeues the job', async () => {
        const ctx = build();
        const t0 = ctx.t.now;
        await notify(ctx);
        ctx.t.now = t0 + TTL - 1000;
        const c = await claim(ctx);
        ctx.t.now = t0 + TTL + 1000;
        assert.equal((await ack(ctx, { machineId: 'm1', jobId: c.body.jobId, ok: false, errorType: 'x_fail' })).status, 200);
        assert.equal(ctx.queue.size(), 0);
        assert.equal((await claim(ctx, { machineId: 'm2', waitSeconds: 0 })).status, 204);
    });
});

describe('pool', () => {
    test('reports relays and counts, no recipient or text', async () => {
        const ctx = build();
        await notify(ctx);
        await claim(ctx);
        const r = await auth(request(ctx.app).get('/api/notify/imessage/pool'));
        assert.equal(r.status, 200);
        assert.equal(r.body.leased, 1);
        assert.equal(r.body.queued, 0);
        assert.deepEqual(Object.keys(r.body.relays[0]).sort(), ['lastAckOk', 'lastClaimAt', 'machineId']);
        assert.ok(!r.text.includes(RECIP) && !r.text.includes(BODY) && !r.text.includes(TITLE));
    });
});

describe('severity gate through the dispatcher', () => {
    test('default gate: info/warning are suppressed with severity-gate and never reach the queue', async () => {
        const ctx = build();
        for (const sev of ['info', 'warning']) {
            const r = await notify(ctx, { severity: sev, ref: `PR-${sev}` });
            assert.equal(r.status, 200);
            assert.equal(r.body.suppressed, 1);
            assert.equal(r.body.receipts[0].suppressed, 'severity-gate');
            assert.equal(r.body.receipts[0].ok, false);
            assert.equal(r.body.receipts[0].providerMessageId, undefined);
        }
        assert.equal(ctx.queue.pool().queued, 0);
        const persisted = receiptLines(ctx);
        assert.equal(persisted.length, 2, 'gated notices still leave receipts');
        assert.ok(persisted.every((x) => x.suppressed === 'severity-gate'));
    });

    test('high and critical pass; the initial receipt is stage accepted', async () => {
        const ctx = build();
        for (const sev of ['high', 'critical']) {
            const r = await notify(ctx, { severity: sev, ref: `PR-${sev}` });
            assert.equal(r.body.delivered, 1);
            assert.equal(r.body.receipts[0].stage, 'accepted');
            assert.match(r.body.receipts[0].providerMessageId, /^im-/);
        }
        assert.equal(ctx.queue.pool().queued, 2);
    });

    test('connection minSeverity overrides the default', async () => {
        const ctx = build({ minSeverity: 'warning' });
        assert.equal((await notify(ctx, { severity: 'info', ref: 'a' })).body.suppressed, 1);
        assert.equal((await notify(ctx, { severity: 'warning', ref: 'b' })).body.delivered, 1);
        const crit = build({ minSeverity: 'critical' });
        assert.equal((await notify(crit, { severity: 'high' })).body.suppressed, 1);
    });

    test('a gated notice does not record dedupe', async () => {
        const ctx = build();
        await notify(ctx, { severity: 'info', ref: 'same' });
        const r = await notify(ctx, { severity: 'high', ref: 'same' });
        assert.equal(r.body.delivered, 1);
    });
});

describe('auth (FLEET_AUTH_TOKEN set)', () => {
    test('all three routes answer 401 without the key and with a wrong key', async () => {
        const ctx = build();
        const calls = [
            (s) => request(ctx.app).post('/api/notify/imessage/claim').send({ machineId: 'm1', waitSeconds: 0 }).set(s),
            (s) => request(ctx.app).post('/api/notify/imessage/ack').send({ machineId: 'm1', jobId: 'im-1', ok: true }).set(s),
            (s) => request(ctx.app).get('/api/notify/imessage/pool').set(s),
        ];
        for (const call of calls) {
            assert.equal((await call({})).status, 401);
            assert.equal((await call({ 'x-api-key': 'wrong' })).status, 401);
        }
    });

    test('Bearer token is accepted', async () => {
        const ctx = build();
        const r = await request(ctx.app).get('/api/notify/imessage/pool').set('Authorization', `Bearer ${FLEET}`);
        assert.equal(r.status, 200);
    });
});

describe('no leaks (epic D5)', () => {
    test('recipient, title and body never reach receipts, hub results, logs or error bodies', async () => {
        const ctx = build();
        const outputs = [];
        const sent = await notify(ctx);
        outputs.push(sent.text);
        const jobId = sent.body.receipts[0].providerMessageId;
        outputs.push((await notify(ctx, { severity: 'info', ref: 'g' })).text);               // gated
        const c = await claim(ctx);
        outputs.push((await ack(ctx, { machineId: 'other', jobId, ok: true })).text);          // 409
        outputs.push((await ack(ctx, { machineId: 'm1', jobId: 'im-ffffffffffffffff', ok: true })).text); // 404
        const echo = RECIP.replace('+', '');
        outputs.push((await ack(ctx, { machineId: 'm1', jobId, ok: false, errorType: echo })).text);
        outputs.push((await auth(request(ctx.app).get('/api/notify/imessage/pool'))).text);
        // fail the job terminally, with an errorType that echoes the recipient digits
        for (const m of ['m2', 'm3']) {
            const j = await claim(ctx, { machineId: m, waitSeconds: 0 });
            if (j.status === 200) await ack(ctx, { machineId: m, jobId: j.body.jobId, ok: false, errorType: echo });
        }
        outputs.push((await auth(request(ctx.app).get('/api/notify/receipts'))).text);
        outputs.push(fs.readFileSync(ctx.receiptsFile, 'utf8'));
        outputs.push(silent.errors.join('\n'));
        assert.equal(c.body.recipient, RECIP, 'sanity: the claim itself carries the payload');
        for (const o of outputs) {
            for (const s of [RECIP, echo, TITLE, BODY]) assert.ok(!o.includes(s), `leaked ${s.slice(0, 12)}`);
        }
        const failed = receiptLines(ctx).filter((x) => x.stage === 'failed');
        assert.equal(failed.length, 1);
        assert.equal(failed[0].error, 'imessage delivery failed (Error)');
    });

    test('a receipt write failure on settle is logged by type only and does not break ack', () => {
        const failing = { newReceipt: (x) => x, append() { throw new Error(`disk full ${RECIP} ${BODY}`); } };
        const log = { error(...a) { log.lines.push(a.join(' ')); }, lines: [] };
        const queue = createImessageQueue({ onSettle: createDeliveryReceiptSink(failing, log) });
        const id = queue.enqueue({ recipient: RECIP, text: BODY, meta: {} });
        queue.claim('m1');
        assert.equal(queue.ack('m1', id, true), 'ok');
        assert.equal(log.lines.length, 1);
        assert.ok(!log.lines[0].includes(RECIP) && !log.lines[0].includes(BODY));
    });
});

describe('wiring', () => {
    test('registerImessageRelayRoutes requires a queue', () => {
        assert.throws(() => registerImessageRelayRoutes(express(), {}), TypeError);
    });

    test('wireNotifyHub without an injected queue still works (default sink + registry)', async () => {
        const id = ++n;
        const app = express();
        app.use(express.json());
        const hub = wireNotifyHub(app, {
            isRegisteredTeam: () => true, logger: silent,
            storeOpts: { file: path.join(dir, `sd-${id}.json`), key: KEY },
            receiptOpts: { file: path.join(dir, `d-${id}.jsonl`) },
        });
        assert.ok(hub.registry.has('imessage'));
        assert.ok(hub.imessageQueue);
        const r = await auth(request(app).post('/api/notify/imessage/claim')).send({ machineId: 'm1', waitSeconds: 0 });
        assert.equal(r.status, 204);
    });

    test('server.js mounts the hub, which mounts the imessage routes', () => {
        const src = fs.readFileSync(path.join(__dirname, '..', 'server.js'), 'utf8');
        assert.match(src, /wireNotifyHub\(app,/);
        const hub = fs.readFileSync(path.join(__dirname, '..', 'lib', 'notify-routes.js'), 'utf8');
        assert.match(hub, /registerImessageRelayRoutes\(app, \{ queue: imessageQueue \}\)/);
    });
});
