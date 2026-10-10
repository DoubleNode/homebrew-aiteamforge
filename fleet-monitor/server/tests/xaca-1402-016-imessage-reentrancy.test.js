//
//  xaca-1402-016-imessage-reentrancy.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1402-016: re-entrant sweep() must never settle a job twice.
 *
 * requeue() wakes long-poll waiters, and a waiter's check() calls claim() ->
 * sweep(). When that happened inside an outer sweep() the nested sweep settled a
 * later job that the outer loop still held in its snapshot, so onSettle fired
 * twice (two `failed` receipts for one providerMessageId).
 *
 * Every case parks a real waitForClaim() waiter, which is the production steady
 * state (every relay is mid long-poll), and asserts exactly one onSettle per job.
 *
 * Variant 2 from the finding (nested sweep settling a later job for ttl_expired)
 * is unreachable with a constant TTL: a later job never expires before an earlier
 * one, and a leased job past its TTL settles rather than requeues, so no requeue
 * happens in the same pass. The idempotent settle() guard covers it regardless.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const { createImessageQueue } = require('../lib/notify-imessage-queue');

const RECIP = '+15557654321';

function build() {
    const t = { now: Date.parse('2026-10-10T12:00:00Z') };
    const settled = [];
    const queue = createImessageQueue({
        clock: () => t.now, maxAttempts: 2, leaseMs: 1000, ttlMs: 100000,
        sameMachineGraceMs: 1000000, waitTickMs: 5,
        onSettle: (s) => settled.push(s),
    });
    const add = (text) => queue.enqueue({ recipient: RECIP, text, meta: { team: 'academy', connectionId: 'c1' } });
    const settleCounts = () => settled.reduce((m, s) => { m[s.jobId] = (m[s.jobId] || 0) + 1; return m; }, {});
    return { t, settled, queue, add, settleCounts };
}

const CASES = [
    {
        name: '1. outer sweep requeues A, later B is attempts_exhausted (the reported repro)',
        run: async (h) => {
            const a = h.add('A'); const b = h.add('B');
            h.queue.claim('m1');                    // A attempt 1
            h.queue.claim('m2');                    // B attempt 1
            h.queue.ack('m2', b, false, 'x');       // B requeued
            h.queue.claim('m3');                    // B attempt 2 (== max)
            h.t.now += 5000;                        // both leases expired
            const parked = h.queue.waitForClaim('m9', 0.02);
            h.queue.sweep();
            await parked;
            return { expectOnce: [b], expectStage: { [b]: 'failed' }, unsettled: [a] };
        },
    },
    {
        name: '1b. three jobs exhausted in one tick behind a requeue',
        run: async (h) => {
            const a = h.add('A');
            const rest = ['B', 'C', 'D'].map((x) => h.add(x));
            h.queue.claim('m1');                                    // A attempt 1
            for (const [i, id] of rest.entries()) {
                h.queue.claim(`r${i}`);
                h.queue.ack(`r${i}`, id, false, 'x');               // requeued
                h.queue.claim(`s${i}`);                             // attempt 2 (== max)
            }
            h.t.now += 5000;
            const parked = [h.queue.waitForClaim('m8', 0.02), h.queue.waitForClaim('m9', 0.02)];
            h.queue.sweep();
            await Promise.all(parked);
            return { expectOnce: rest, unsettled: [a] };
        },
    },
    {
        name: '3. ack(ok:false) requeue wakes a parked waiter that claims it',
        run: async (h) => {
            const a = h.add('A');
            h.queue.claim('m1');
            const parked = h.queue.waitForClaim('m9', 0.5);
            assert.equal(h.queue.ack('m1', a, false, 'x'), 'ok');
            const job = await parked;
            assert.equal(job && job.jobId, a, 'the waiter received the requeued job');
            assert.equal(job.attempt, 2);
            return { expectOnce: [], unsettled: [a] };
        },
    },
    {
        name: '4. enqueue wakes a parked waiter, nothing settles',
        run: async (h) => {
            const parked = h.queue.waitForClaim('m9', 0.5);
            const a = h.add('A');
            const job = await parked;
            assert.equal(job && job.jobId, a);
            return { expectOnce: [], unsettled: [a] };
        },
    },
    {
        name: '5. a waiter re-leases the job the outer sweep just requeued',
        run: async (h) => {
            const a = h.add('A');
            h.queue.claim('m1');                    // attempt 1
            h.t.now += 5000;                        // lease expired, attempts remain
            const parked = h.queue.waitForClaim('m9', 0.5);
            h.queue.sweep();                        // requeues A, deferred wake hands it to m9
            const job = await parked;
            assert.equal(job && job.jobId, a);
            assert.equal(job.attempt, 2, 'exactly one re-lease');
            assert.equal(h.queue.pool().leased, 1);
            return { expectOnce: [], unsettled: [a] };
        },
    },
];

for (const c of CASES) {
    test(c.name, async () => {
        const h = build();
        const r = await c.run(h);
        const counts = h.settleCounts();
        for (const id of r.expectOnce) assert.equal(counts[id], 1, `job ${id} settled ${counts[id] || 0} times, expected 1`);
        for (const id of r.unsettled) assert.equal(counts[id], undefined, `job ${id} should not have settled`);
        for (const [id, stage] of Object.entries(r.expectStage || {})) {
            assert.equal(h.settled.find((s) => s.jobId === id).stage, stage);
        }
        for (const n of Object.values(counts)) assert.equal(n, 1, 'no job settles more than once');
    });
}
