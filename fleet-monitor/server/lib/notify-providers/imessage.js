//
//  imessage.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * iMessage notify provider (XACA-1402-002, EPIC-0068 item 4/8).
 *
 * Fleet Monitor (Linux, Fly.io) cannot drive Messages.app. send() therefore
 * ENQUEUES a job on the in-memory sender-pool queue (lib/notify-imessage-queue.js)
 * and returns {providerMessageId: jobId} at once; a consumer-Mac relay claims
 * the job, sends it, and acks. It never waits for delivery (the dispatcher's
 * send timeout is 10 s).
 *
 * params:  recipient   E.164 phone (^\+[1-9]\d{7,14}$) or an email-shaped Apple ID
 *          minSeverity one of the hub SEVERITIES; default `high` (D6). The
 *                      dispatcher's severity gate reads it (generic, any provider).
 *          pool        optional array (<= 32) of machine ids preferred to send;
 *                      default is any claiming machine. A ROUTING PREFERENCE,
 *                      NOT an authorization control: machineId is self-asserted
 *                      on claim, so any holder of the fleet key can claim as any
 *                      pool member (and so read the recipient and text of jobs
 *                      routed to it). The fleet key is the only access boundary.
 * secrets: none.
 *
 * `asyncDelivery: true` tells the dispatcher the initial receipt means
 * "accepted for relay" (stage: accepted); the queue appends the delivery
 * receipt later with the same providerMessageId. Dedupe still records at
 * acceptance, a known approximation: a notice whose relay delivery later
 * fails is still deduped inside the window.
 *
 * Error messages are fixed text. The recipient and message never appear in
 * an error, a receipt or a log line (D5).
 */

const { NotifyConfigError, NotifySendError } = require('./index');
const { createImessageQueue, ImessageQueueFullError, MACHINE_ID_RE } = require('../notify-imessage-queue');
const { SEVERITIES, isValidSeverity } = require('../notify-policies');

const E164_RE = /^\+[1-9]\d{7,14}$/;
const APPLE_ID_RE = /^[A-Za-z0-9._%+'-]{1,64}@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,24}$/;
const MAX_RECIPIENT = 254;
const MAX_POOL = 32;
const MAX_TEXT = 1000;
const DEFAULT_MIN_SEVERITY = 'high';

function trunc(s, max) {
    const chars = Array.from(s);
    return chars.length <= max ? s : chars.slice(0, max - 1).join('') + '…';
}

function paramsOf(connection) {
    const p = connection && connection.params;
    return p && typeof p === 'object' ? p : {};
}

function recipientOk(r) {
    return typeof r === 'string' && r === r.trim() && r.length <= MAX_RECIPIENT && (E164_RE.test(r) || APPLE_ID_RE.test(r));
}

/** [SEVERITY] title, newline, body; capped at 1000 characters. */
function formatText(message) {
    const m = message || {};
    const sev = isValidSeverity(m.severity) ? m.severity : 'info';
    const title = typeof m.title === 'string' ? m.title.trim() : '';
    const body = typeof m.body === 'string' ? m.body.trim() : '';
    const head = `[${sev.toUpperCase()}] ${title || '(no title)'}`;
    return trunc(body ? `${head}\n${body}` : head, MAX_TEXT);
}

/** @param {{queue?: object}} [opts] inject the queue (tests use a fresh one + fake clock). */
function createImessageProvider({ queue } = {}) {
    const q = queue || createImessageQueue();
    function validate(connection) {
        const p = paramsOf(connection);
        if (!recipientOk(p.recipient)) throw new NotifyConfigError('imessage param recipient must be an E.164 number or an Apple ID email');
        const ms = p.minSeverity;
        if (ms !== undefined && ms !== null && ms !== '' && !isValidSeverity(ms)) {
            throw new NotifyConfigError(`imessage param minSeverity must be one of ${SEVERITIES.join(', ')}`);
        }
        const pool = p.pool;
        if (pool !== undefined && pool !== null) {
            if (!Array.isArray(pool) || pool.length > MAX_POOL
                || !pool.every((id) => typeof id === 'string' && MACHINE_ID_RE.test(id))) {
                throw new NotifyConfigError(`imessage param pool must be an array of up to ${MAX_POOL} machine ids`);
            }
        }
    }
    return {
        name: 'imessage',
        paramFields: ['recipient', 'minSeverity', 'pool'],
        secretFields: [],
        asyncDelivery: true,
        defaultMinSeverity: DEFAULT_MIN_SEVERITY,
        queue: q,
        validate,
        async send(connection, message) {
            validate(connection);
            const p = paramsOf(connection);
            const m = message || {};
            const meta = { connectionId: connection.id };
            for (const k of ['team', 'type', 'ref', 'severity']) if (typeof m[k] === 'string' && m[k]) meta[k] = m[k];
            try {
                const jobId = q.enqueue({ recipient: p.recipient, text: formatText(m), pool: p.pool, meta });
                return { providerMessageId: jobId };
            } catch (err) {
                if (err instanceof ImessageQueueFullError) throw new NotifySendError('imessage queue is full');
                throw new NotifySendError('imessage enqueue failed');
            }
        },
    };
}

module.exports = { createImessageProvider, formatText, E164_RE, APPLE_ID_RE, MAX_TEXT, MAX_POOL, DEFAULT_MIN_SEVERITY };
