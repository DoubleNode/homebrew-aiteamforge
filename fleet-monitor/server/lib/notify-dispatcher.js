//
//  notify-dispatcher.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Notification dispatcher (XACA-1400-003, EPIC-0068 D1/D2/D6).
 *
 * dispatch(notice) resolves  type -> routes -> connections  for a team and
 * makes ONE send attempt per connection, writing ONE receipt per connection.
 * Failure is never silent and never retried invisibly.
 *
 * SEVERITY. kanban-hooks/release_notify_routing.py takes no caller severity
 * (override > catalog default). The hub additionally lets a caller pin one:
 *   caller `severity` (valid) > config.severityOverrides[type] > catalog defaultSeverity.
 * An invalid caller severity is a 400, never silently replaced.
 *
 * POLICY ORDER: no-route short-circuit -> dedupe -> quiet hours (both are
 * notice-level: every routed connection gets a suppressed receipt, no provider
 * call) -> per connection: rate limit -> resolve -> provider lookup -> send
 * with timeout. dedupe.record() runs only if >= 1 connection delivered.
 *
 * LEAKS. Receipts are allowlisted by notify-receipts; the result envelope is
 * built here from receipts + counters only. Title, body, params, secrets and
 * destinations never appear in either. Error strings are fixed phrases or the
 * provider layer's already-sanitised messages.
 *
 * RECEIPT WRITE FAILURE is never swallowed: all receipts are still attempted,
 * then NotifyDispatchError('receipt_write_failed', 500) is thrown carrying the
 * computed `result` so the route can still tell the caller what happened.
 */

const { attemptSend } = require('./notify-providers');
const { createReceiptLog } = require('./notify-receipts');
const {
    SEVERITIES, DEFAULT_DEDUPE_WINDOW_SECONDS, isValidSeverity,
    quietHoursDecision, createDedupeTracker, createRateLimiter,
} = require('./notify-policies');
const { NotifyCryptoError } = require('./notify-store');
const { scrubText, sensitiveValues } = require('./notify-scrub');

const DEFAULT_SEND_TIMEOUT_MS = 10000;
const MAX_ERROR_TEXT = 200;

class NotifyDispatchError extends Error {
    constructor(message, code, status, result) {
        super(message);
        this.name = 'NotifyDispatchError';
        this.code = code;
        this.status = status;
        if (result !== undefined) this.result = result;
    }
}

const isPlainObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

function resolveSeverity(callerSeverity, config, catalog, type) {
    if (callerSeverity !== undefined) {
        if (!isValidSeverity(callerSeverity)) throw new NotifyDispatchError('invalid severity', 'invalid', 400);
        return callerSeverity;
    }
    const override = isPlainObject(config.severityOverrides) ? config.severityOverrides[type] : undefined;
    if (isValidSeverity(override)) return override;
    const def = catalog[type] && catalog[type].defaultSeverity;
    return isValidSeverity(def) ? def : 'info';
}

function withTimeout(promise, ms) {
    let timer;
    const timeout = new Promise((resolve) => {
        timer = setTimeout(() => resolve({ ok: false, error: 'send timed out' }), ms);
    });
    return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

function createNotifyDispatcher(opts = {}) {
    const { store, registry, receipts } = opts;
    const clock = opts.clock || (() => new Date());
    const dedupe = opts.dedupe || createDedupeTracker({ clock });
    const rateLimiter = opts.rateLimiter || createRateLimiter({ clock });
    const sendTimeoutMs = Number.isFinite(opts.sendTimeoutMs) && opts.sendTimeoutMs > 0
        ? opts.sendTimeoutMs : DEFAULT_SEND_TIMEOUT_MS;

    async function dispatch(notice) {
        const { team, type, title, body, ref } = notice;

        const rec = store.getTeamRoutes(team);
        if (!rec) throw new NotifyDispatchError('no routes pushed for team', 'not_found', 404);
        const { config, catalog } = rec;
        if (!isPlainObject(catalog) || !Object.prototype.hasOwnProperty.call(catalog, type)) {
            throw new NotifyDispatchError('unknown notice type', 'invalid', 400);
        }
        const severity = resolveSeverity(notice.severity, config, catalog, type);

        const routeMap = isPlainObject(config.routes) ? config.routes : {};
        const ids = Object.prototype.hasOwnProperty.call(routeMap, type) && Array.isArray(routeMap[type])
            ? routeMap[type] : null;
        if (ids === null || ids.length === 0) {
            return {
                ok: false, routed: false, reason: ids === null ? 'no-route' : 'route-nowhere',
                team, type, severity, delivered: 0, failed: 0, suppressed: 0, receipts: [], warnings: [],
            };
        }

        const base = { team, type, severity };
        if (ref !== undefined) base.ref = ref;
        const warnings = [];
        const make = (id, fields) => receipts.newReceipt({ ...base, connectionId: id, ...fields });
        const window = config.dedupeWindow === undefined ? DEFAULT_DEDUPE_WINDOW_SECONDS : config.dedupeWindow;

        let list;
        const noticeSuppressed = (reason) => ids.map((id) => make(id, { ok: false, error: '', suppressed: reason }));

        if (dedupe.check(team, type, ref, window).duplicate) {
            list = noticeSuppressed('dedupe');
        } else {
            const q = quietHoursDecision(severity, config.quietHours, clock());
            if (q.warning) warnings.push(q.warning);
            list = q.suppress ? noticeSuppressed('quiet-hours') : null;
        }

        if (list === null) {
            const message = { team, type, title, body, ref, severity };
            list = await Promise.all(ids.map((id) => deliver(id, message, make)));
            if (list.some((r) => r.ok)) dedupe.record(team, type, ref, window);
        }

        const delivered = list.filter((r) => r.ok).length;
        const suppressed = list.filter((r) => r.suppressed).length;
        const result = {
            ok: delivered > 0, routed: true, team, type, severity,
            delivered, failed: list.length - delivered - suppressed, suppressed,
            receipts: list, warnings,
        };

        let writeFailed = false;
        for (const r of list) {
            try { receipts.append(r); } catch (_) { writeFailed = true; }
        }
        if (writeFailed) {
            throw new NotifyDispatchError('receipt write failed', 'receipt_write_failed', 500, result);
        }
        return result;
    }

    async function deliver(id, message, make) {
        const rl = rateLimiter.take(id);
        if (!rl.allowed) return make(id, { ok: false, error: '', suppressed: 'rate-limit' });

        let connection;
        try {
            connection = store.resolveConnection(id);
        } catch (e) {
            return make(id, {
                ok: false,
                error: e instanceof NotifyCryptoError ? 'connection secrets unreadable' : 'connection lookup failed',
            });
        }
        if (!connection) return make(id, { ok: false, error: 'unknown connection' });

        const pname = connection.provider;
        if (!registry.has(pname)) return make(id, { ok: false, error: 'unknown provider', provider: pname });

        const out = await withTimeout(attemptSend(registry.get(pname), connection, message), sendTimeoutMs);
        // A provider's error text may echo this connection's own secret or destination: scrub, then bound.
        const error = out.ok === true ? '' : scrubText(out.error, sensitiveValues(connection), MAX_ERROR_TEXT);
        const fields = { ok: out.ok === true, error, provider: pname };
        if (out.providerMessageId) fields.providerMessageId = out.providerMessageId;
        return make(id, fields);
    }

    return { dispatch };
}

module.exports = { createNotifyDispatcher, NotifyDispatchError, resolveSeverity, SEVERITIES, DEFAULT_SEND_TIMEOUT_MS };
