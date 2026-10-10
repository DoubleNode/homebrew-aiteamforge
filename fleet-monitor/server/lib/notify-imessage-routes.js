//
//  notify-imessage-routes.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * iMessage sender-pool relay routes (XACA-1402-003), mounted like
 * lib/msg-relay-routes.js: registerImessageRelayRoutes(app, deps).
 *
 *   POST /api/notify/imessage/claim  {machineId, waitSeconds?}  long-poll
 *        200 {jobId, recipient, text, attempt, leaseExpiresAt} | 204 | 400
 *   POST /api/notify/imessage/ack    {machineId, jobId, ok, errorType?}
 *        200 {ok:true} | 400 | 404 {error:'unknown_job'} | 409 {error:'lease_not_held'}
 *   GET  /api/notify/imessage/pool   {relays:[{machineId,lastClaimAt,lastAckOk}], queued, leased}
 *
 * AUTH: the shared checkApiKey() guard (fleet tier), same posture as the kb-msg
 * relay. The claim response is the ONE place a recipient and text leave FM, and
 * only to an authenticated relay. No error body, log line or receipt carries
 * either; request bodies are never echoed.
 */

const { checkApiKey } = require('./auth-middleware');
const { MACHINE_ID_RE, ERROR_TYPE_RE, MAX_WAIT_S } = require('./notify-imessage-queue');

const isPlainObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const bad = (res, message) => res.status(400).json({ error: 'invalid', message });

/**
 * Receipt sink for queue.onSettle: appends the delivery receipt (same
 * providerMessageId as the accepted one). A write failure is logged by error
 * TYPE only; it must never break the queue or the ack.
 */
function createDeliveryReceiptSink(receipts, logger = console) {
    return function onSettle({ jobId, meta, stage, errorType }) {
        const ok = stage === 'delivered';
        try {
            receipts.append(receipts.newReceipt({
                ...meta, provider: 'imessage', providerMessageId: jobId, stage, ok,
                error: ok ? '' : `imessage delivery failed (${errorType || 'Error'})`,
            }));
        } catch (err) {
            const t = (err && err.constructor && err.constructor.name) || 'Error';
            logger.error(`[NOTIFY] imessage delivery receipt write failed (${t})`);
        }
    };
}

function validMachineId(v) { return typeof v === 'string' && MACHINE_ID_RE.test(v); }

/**
 * @param {import('express').Application|import('express').Router} app
 * @param {{queue: object}} deps
 */
function registerImessageRelayRoutes(app, { queue }) {
    if (!queue || typeof queue.waitForClaim !== 'function') throw new TypeError('registerImessageRelayRoutes: queue is required');

    app.post('/api/notify/imessage/claim', async (req, res) => {
        if (!checkApiKey(req, res)) return;
        const b = req.body;
        if (!isPlainObject(b) || !validMachineId(b.machineId)) return bad(res, 'machineId is required');
        let wait = MAX_WAIT_S;
        if (b.waitSeconds !== undefined) {
            if (!Number.isInteger(b.waitSeconds) || b.waitSeconds < 0 || b.waitSeconds > MAX_WAIT_S) {
                return bad(res, `waitSeconds must be an integer 0-${MAX_WAIT_S}`);
            }
            wait = b.waitSeconds;
        }
        const ac = new AbortController();
        res.on('close', () => ac.abort());
        try {
            const job = await queue.waitForClaim(b.machineId, wait, ac.signal);
            if (res.writableEnded || res.destroyed) return undefined;
            if (!job) return res.status(204).end();
            return res.json(job);
        } catch (_) {
            return res.status(500).json({ error: 'internal_error', message: 'internal error' });
        }
    });

    app.post('/api/notify/imessage/ack', (req, res) => {
        if (!checkApiKey(req, res)) return;
        const b = req.body;
        if (!isPlainObject(b) || !validMachineId(b.machineId)) return bad(res, 'machineId is required');
        if (typeof b.jobId !== 'string' || b.jobId.length === 0 || b.jobId.length > 128) return bad(res, 'jobId is required');
        if (typeof b.ok !== 'boolean') return bad(res, 'ok must be a boolean');
        if (b.errorType !== undefined && (typeof b.errorType !== 'string' || !ERROR_TYPE_RE.test(b.errorType))) {
            return bad(res, 'errorType is invalid');
        }
        let r;
        try { r = queue.ack(b.machineId, b.jobId, b.ok, b.errorType); } catch (_) {
            return res.status(500).json({ error: 'internal_error', message: 'internal error' });
        }
        if (r === 'ok') return res.json({ ok: true });
        if (r === 'lease_not_held') return res.status(409).json({ error: 'lease_not_held' });
        return res.status(404).json({ error: 'unknown_job' });
    });

    app.get('/api/notify/imessage/pool', (req, res) => {
        if (!checkApiKey(req, res)) return;
        res.json(queue.pool());
    });
}

module.exports = { registerImessageRelayRoutes, createDeliveryReceiptSink };
