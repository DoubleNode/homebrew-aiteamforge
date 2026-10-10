//
//  notify-imessage-queue.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * In-memory iMessage job queue (XACA-1402-003, EPIC-0068 item 4/8).
 *
 * Fleet Monitor runs on Linux and cannot drive Messages.app, so the imessage
 * provider ENQUEUES and consumer-Mac relays CLAIM, send, and ACK.
 *
 * MEMORY ONLY. The recipient and message text live in this process's heap and
 * nowhere else: no file, no log line, no receipt, no error string (epic D5).
 * An FM restart therefore loses queued jobs. That loss is accepted and
 * documented rather than papered over: a job already reported as "accepted"
 * has a receipt on disk, but no job ids are persisted, so no failed delivery
 * receipt can be written for it after a restart.
 *
 * LIFECYCLE
 *   queued --claim--> leased --ack ok--------------------------> done
 *                       |  \--ack !ok / lease expiry--> queued (attempts < max)
 *                       |                          \--> failed (attempts == max)
 *   queued|leased --ttl--> failed
 *  - lease 60 s, max 3 attempts (counted at claim), TTL 10 min from enqueue.
 *  - FAILOVER: after a lease expires (or a relay acks failure) the last holder
 *    is excluded for sameMachineGraceMs (default 25 s = one long-poll cycle),
 *    so a different machine wins the job if any is polling. After the grace the
 *    same machine may take it, so a one-machine pool still retries.
 *  - AT-LEAST-ONCE. A relay that sends and dies before acking gets its lease
 *    expired, and another machine may resend. A duplicate is acceptable.
 *
 * Settling (done or failed) calls opts.onSettle once with metadata only
 * ({jobId, meta, stage, errorType}); never the recipient or text. The job's
 * recipient and text are dropped from memory at that moment.
 */

const crypto = require('crypto');

const LEASE_MS = 60 * 1000;
const TTL_MS = 10 * 60 * 1000;
const MAX_ATTEMPTS = 3;
const SAME_MACHINE_GRACE_MS = 25 * 1000;
const MAX_ACTIVE = 500;
const MAX_RELAYS = 64;
const MAX_TOMBSTONES = 1000;
const TOMBSTONE_MS = 60 * 60 * 1000;
const WAIT_TICK_MS = 1000;
const MAX_WAIT_S = 25;

const MACHINE_ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const ERROR_TYPE_RE = /^[A-Za-z0-9_.-]{1,64}$/;

class ImessageQueueFullError extends Error {
    constructor() { super('imessage queue is full'); this.name = 'ImessageQueueFullError'; }
}

function createImessageQueue(opts = {}) {
    const clock = opts.clock || (() => Date.now());
    const now = () => +new Date(clock());
    const num = (v, d) => (Number.isFinite(v) && v > 0 ? v : d);
    const leaseMs = num(opts.leaseMs, LEASE_MS);
    const ttlMs = num(opts.ttlMs, TTL_MS);
    const maxAttempts = Number.isInteger(opts.maxAttempts) && opts.maxAttempts > 0 ? opts.maxAttempts : MAX_ATTEMPTS;
    const graceMs = Number.isFinite(opts.sameMachineGraceMs) && opts.sameMachineGraceMs >= 0
        ? opts.sameMachineGraceMs : SAME_MACHINE_GRACE_MS;
    const maxActive = num(opts.maxActive, MAX_ACTIVE);
    const onSettle = typeof opts.onSettle === 'function' ? opts.onSettle : null;
    const tickMs = num(opts.waitTickMs, WAIT_TICK_MS);

    const active = new Map();      // jobId -> job (insertion order = FIFO)
    const tombstones = new Map();  // jobId -> settledAt ms (no payload)
    const relays = new Map();      // machineId -> {lastClaimAt, lastAckOk}
    const waiters = new Set();     // wake callbacks for long-polling claims

    function wake() { for (const w of [...waiters]) w(); }

    function safeErrorType(job, t) {
        if (typeof t !== 'string' || !ERROR_TYPE_RE.test(t)) return 'Error';
        // A relay-supplied label must not carry the payload back out.
        if (job.recipient && (t.includes(job.recipient) || (t.length >= 4 && job.recipient.includes(t)))) return 'Error';
        if (job.text && t.length >= 4 && job.text.includes(t)) return 'Error';
        return t;
    }

    function settle(job, stage, errorType) {
        const out = { jobId: job.id, meta: job.meta, stage };
        if (stage === 'failed') out.errorType = safeErrorType(job, errorType);
        active.delete(job.id);
        tombstones.set(job.id, now());
        job.recipient = null; job.text = null; job.pool = null; // drop the payload
        if (onSettle) { try { onSettle(out); } catch (_) { /* a sink failure must not break the queue */ } }
    }

    function requeue(job, holder) {
        job.state = 'queued';
        job.lastHolder = holder;
        job.requeuedAt = now();
        job.leaseMachine = null;
        job.leaseExpiresAt = 0;
        wake();
    }

    function sweep() {
        const t = now();
        for (const job of [...active.values()]) {
            if (t >= job.expiresAt) { settle(job, 'failed', 'ttl_expired'); continue; }
            if (job.state === 'leased' && t >= job.leaseExpiresAt) {
                if (job.attempt >= maxAttempts) settle(job, 'failed', 'attempts_exhausted');
                else requeue(job, job.leaseMachine);
            }
        }
        for (const [id, at] of tombstones) {
            // Map order is settle order, so stop at the first one that is still fresh.
            if (t - at > TOMBSTONE_MS || tombstones.size > MAX_TOMBSTONES) tombstones.delete(id);
            else break;
        }
    }

    function touchRelay(machineId) {
        let r = relays.get(machineId);
        if (!r) {
            if (relays.size >= MAX_RELAYS) relays.delete(relays.keys().next().value);
            r = { lastClaimAt: null, lastAckOk: null };
            relays.set(machineId, r);
        }
        return r;
    }

    function enqueue({ recipient, text, pool, meta }) {
        sweep();
        if (active.size >= maxActive) throw new ImessageQueueFullError();
        const t = now();
        const id = 'im-' + crypto.randomBytes(8).toString('hex');
        active.set(id, {
            id, recipient, text, pool: Array.isArray(pool) && pool.length ? [...pool] : null,
            meta: { ...(meta || {}) },
            createdAt: t, expiresAt: t + ttlMs, attempt: 0, state: 'queued',
            leaseMachine: null, leaseExpiresAt: 0, lastHolder: null, requeuedAt: 0,
        });
        wake();
        return id;
    }

    /** Synchronous claim attempt. Returns the claim payload or null. */
    function claim(machineId) {
        sweep();
        const t = now();
        touchRelay(machineId).lastClaimAt = new Date(t).toISOString();
        for (const job of active.values()) {
            if (job.state !== 'queued') continue;
            if (job.pool && !job.pool.includes(machineId)) continue;
            if (job.lastHolder === machineId && t - job.requeuedAt < graceMs) continue;
            job.state = 'leased';
            job.attempt += 1;
            job.leaseMachine = machineId;
            job.leaseExpiresAt = t + leaseMs;
            return {
                jobId: job.id, recipient: job.recipient, text: job.text,
                attempt: job.attempt, leaseExpiresAt: new Date(job.leaseExpiresAt).toISOString(),
            };
        }
        return null;
    }

    /**
     * Long-poll claim. Real timers (the injected clock only drives job logic).
     * Re-checks on every enqueue/requeue wake and every tick, so lease expiry
     * and the failover grace are noticed without an external sweeper.
     */
    function waitForClaim(machineId, waitSeconds, signal) {
        const secs = Math.min(Math.max(Number.isFinite(waitSeconds) ? waitSeconds : 0, 0), MAX_WAIT_S);
        const deadline = Date.now() + secs * 1000;
        return new Promise((resolve) => {
            let timer = null;
            let done = false;
            const finish = (v) => {
                if (done) return;
                done = true;
                clearTimeout(timer);
                waiters.delete(check);
                if (signal) signal.removeEventListener('abort', onAbort);
                resolve(v);
            };
            const onAbort = () => finish(null);
            function check() {
                if (done) return;
                if (signal && signal.aborted) return finish(null);
                const job = claim(machineId);
                if (job) return finish(job);
                const left = deadline - Date.now();
                if (left <= 0) return finish(null);
                clearTimeout(timer);
                timer = setTimeout(check, Math.min(tickMs, left));
            }
            waiters.add(check);
            if (signal) signal.addEventListener('abort', onAbort, { once: true });
            check();
        });
    }

    /** @returns {'ok'|'lease_not_held'|'unknown_job'} */
    function ack(machineId, jobId, ok, errorType) {
        sweep();
        const job = active.get(jobId);
        if (!job) return tombstones.has(jobId) ? 'lease_not_held' : 'unknown_job';
        if (job.state !== 'leased' || job.leaseMachine !== machineId) return 'lease_not_held';
        touchRelay(machineId).lastAckOk = ok === true;
        if (ok === true) settle(job, 'delivered');
        else if (job.attempt >= maxAttempts) settle(job, 'failed', errorType);
        else requeue(job, machineId);
        return 'ok';
    }

    function pool() {
        sweep();
        let queued = 0;
        let leased = 0;
        for (const j of active.values()) { if (j.state === 'leased') leased++; else queued++; }
        return {
            relays: [...relays].map(([machineId, r]) => ({ machineId, lastClaimAt: r.lastClaimAt, lastAckOk: r.lastAckOk })),
            queued, leased,
        };
    }

    return { enqueue, claim, waitForClaim, ack, sweep, pool, size: () => active.size };
}

module.exports = {
    createImessageQueue, ImessageQueueFullError,
    MACHINE_ID_RE, ERROR_TYPE_RE, LEASE_MS, TTL_MS, MAX_ATTEMPTS, SAME_MACHINE_GRACE_MS, MAX_WAIT_S,
};
