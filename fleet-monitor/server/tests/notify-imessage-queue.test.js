//
//  notify-imessage-queue.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/** XACA-1402-003: queue lifecycle with a fake clock (lease, failover, attempts, TTL). */

const test = require('node:test');
const assert = require('node:assert/strict');
const { createImessageQueue, LEASE_MS, TTL_MS, SAME_MACHINE_GRACE_MS } = require('../lib/notify-imessage-queue');

const RECIP = '+15557654321';
const TEXT = '[HIGH] secret-text-marker';

function build(opts = {}) {
    const t = { now: Date.parse('2026-10-10T12:00:00Z') };
    const settled = [];
    const queue = createImessageQueue({ clock: () => t.now, onSettle: (s) => settled.push(s), ...opts });
    const add = (extra = {}) => queue.enqueue({ recipient: RECIP, text: TEXT, meta: { team: 'academy', connectionId: 'c1' }, ...extra });
    return { t, settled, queue, add };
}

test('enqueue, claim, ack ok settles delivered once', () => {
    const { queue, add, settled } = build();
    const id = add();
    const job = queue.claim('m1');
    assert.equal(job.jobId, id);
    assert.equal(job.recipient, RECIP);
    assert.equal(job.text, TEXT);
    assert.equal(job.attempt, 1);
    assert.equal(job.leaseExpiresAt, '2026-10-10T12:01:00.000Z');
    assert.equal(queue.claim('m2'), null, 'leased job is not claimable');
    assert.equal(queue.ack('m1', id, true), 'ok');
    assert.deepEqual(settled.map((s) => [s.jobId, s.stage]), [[id, 'delivered']]);
    assert.equal(queue.ack('m1', id, true), 'lease_not_held', 'second ack on a settled job');
    assert.equal(queue.pool().queued + queue.pool().leased, 0);
});

test('FIFO claim order', () => {
    const { queue, add } = build();
    const a = add(); const b = add();
    assert.equal(queue.claim('m1').jobId, a);
    assert.equal(queue.claim('m1').jobId, b);
});

test('expired lease fails over to a DIFFERENT machine first', () => {
    const { queue, add, t } = build();
    const id = add();
    queue.claim('m1');
    t.now += LEASE_MS;
    assert.equal(queue.claim('m1'), null, 'last holder is excluded during the grace');
    const second = queue.claim('m2');
    assert.equal(second.jobId, id);
    assert.equal(second.attempt, 2);
});

test('same machine may retry only after the grace', () => {
    const { queue, add, t } = build();
    const id = add();
    queue.claim('m1');
    t.now += LEASE_MS;
    assert.equal(queue.claim('m1'), null);
    t.now += SAME_MACHINE_GRACE_MS - 1;
    assert.equal(queue.claim('m1'), null);
    t.now += 1;
    assert.equal(queue.claim('m1').jobId, id);
});

test('stale ack after lease expiry is lease_not_held; foreign machine is lease_not_held', () => {
    const { queue, add, t, settled } = build();
    const id = add();
    queue.claim('m1');
    assert.equal(queue.ack('m2', id, true), 'lease_not_held', 'foreign machine');
    t.now += LEASE_MS;
    assert.equal(queue.ack('m1', id, true), 'lease_not_held', 'expired lease');
    assert.equal(settled.length, 0, 'a rejected ack settles nothing');
    assert.equal(queue.ack('m1', 'im-doesnotexist', true), 'unknown_job');
});

test('attempt cap: three expired leases end in a failed settle', () => {
    const { queue, add, t, settled } = build();
    const id = add();
    for (const m of ['m1', 'm2', 'm3']) {
        assert.equal(queue.claim(m).jobId, id);
        t.now += LEASE_MS;
    }
    queue.sweep();
    assert.deepEqual(settled.map((s) => [s.stage, s.errorType]), [['failed', 'attempts_exhausted']]);
    assert.equal(queue.claim('m4'), null);
});

test('TTL: a job nobody claims becomes failed after 10 minutes', () => {
    const { queue, add, t, settled } = build();
    add();
    t.now += TTL_MS - 1;
    queue.sweep();
    assert.equal(settled.length, 0);
    t.now += 1;
    queue.sweep();
    assert.deepEqual(settled.map((s) => [s.stage, s.errorType]), [['failed', 'ttl_expired']]);
});

test('ack ok:false retries on another machine while attempts remain, then fails with the relay errorType', () => {
    const { queue, add, settled } = build();
    const id = add();
    queue.claim('m1');
    assert.equal(queue.ack('m1', id, false, 'send_failed'), 'ok');
    assert.equal(settled.length, 0, 'not terminal yet');
    assert.equal(queue.claim('m1'), null);
    queue.claim('m2');
    queue.ack('m2', id, false, 'send_failed');
    queue.claim('m3');
    queue.ack('m3', id, false, 'send_failed');
    assert.deepEqual(settled.map((s) => [s.stage, s.errorType]), [['failed', 'send_failed']]);
});

test('relay-supplied errorType that echoes the payload is replaced', () => {
    const { queue, add, settled } = build({ maxAttempts: 1 });
    const id = add({ recipient: 'me.name@icloud.com' });
    queue.claim('m1');
    queue.ack('m1', id, false, 'me.name');
    // "me.name" is a fragment of the address: replaced, not passed through
    assert.equal(settled[0].errorType, 'Error');
});

test('settle metadata carries no recipient or text', () => {
    const { queue, add, settled } = build();
    const id = add();
    queue.claim('m1');
    queue.ack('m1', id, true);
    const s = JSON.stringify(settled);
    assert.ok(!s.includes(RECIP) && !s.includes('secret-text-marker'));
});

test('pool allowlist restricts who can claim', () => {
    const { queue, add } = build();
    add({ pool: ['m2'] });
    assert.equal(queue.claim('m1'), null);
    assert.ok(queue.claim('m2'));
});

test('pool() reports relays, counts and no payload', () => {
    const { queue, add, t } = build();
    const id = add(); add();
    queue.claim('m1');
    queue.ack('m1', id, true);
    queue.claim('m2');
    t.now += 1000;
    const p = queue.pool();
    assert.equal(p.leased, 1);
    assert.equal(p.queued, 0);
    assert.deepEqual(p.relays.map((r) => r.machineId).sort(), ['m1', 'm2']);
    assert.equal(p.relays.find((r) => r.machineId === 'm1').lastAckOk, true);
    assert.equal(p.relays.find((r) => r.machineId === 'm2').lastAckOk, null);
    assert.ok(!JSON.stringify(p).includes(RECIP) && !JSON.stringify(p).includes('secret-text-marker'));
});

test('queue bound: enqueue throws when full', () => {
    const { add } = build({ maxActive: 2 });
    add(); add();
    assert.throws(() => add(), /queue is full/);
});

test('onSettle that throws does not break the queue', () => {
    const queue = createImessageQueue({ onSettle: () => { throw new Error('boom'); } });
    const id = queue.enqueue({ recipient: RECIP, text: TEXT, meta: {} });
    queue.claim('m1');
    assert.equal(queue.ack('m1', id, true), 'ok');
});

test('waitForClaim: resolves null at the deadline, wakes on enqueue, aborts on signal', async () => {
    const queue = createImessageQueue({ waitTickMs: 20 });
    assert.equal(await queue.waitForClaim('m1', 0), null);
    const started = Date.now();
    assert.equal(await queue.waitForClaim('m1', 1), null);
    assert.ok(Date.now() - started >= 900);

    const pending = queue.waitForClaim('m1', 5);
    setTimeout(() => queue.enqueue({ recipient: RECIP, text: TEXT, meta: {} }), 30);
    const job = await pending;
    assert.ok(job && job.recipient === RECIP);

    const ac = new AbortController();
    const aborted = queue.waitForClaim('m1', 5, ac.signal);
    setTimeout(() => ac.abort(), 20);
    assert.equal(await aborted, null);
});
