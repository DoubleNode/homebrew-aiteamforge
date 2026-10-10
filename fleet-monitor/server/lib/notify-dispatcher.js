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
 * POLICY ORDER (final): no-route short-circuit -> quiet hours (notice-level:
 * every routed connection gets a suppressed receipt, no provider call) -> per
 * connection: dedupe check -> resolve connection -> provider lookup -> severity
 * gate (XACA-1402) -> rate limit -> send with timeout (aborted via AbortSignal
 * on timeout).
 * Resolution and provider lookup come BEFORE the rate limiter so an unknown
 * connection/provider never spends a slot; the severity gate comes before it
 * too, so a gated notice never spends one either.
 * SEVERITY GATE (XACA-1402): connection.params.minSeverity (else the provider's
 * defaultMinSeverity, if it declares one) is a floor; a notice ranking below it
 * gets a suppressed 'severity-gate' receipt and no provider call.
 * ASYNC DELIVERY: a provider with `asyncDelivery: true` (imessage) reports only
 * acceptance, so its send receipt carries stage 'accepted'; the provider's queue
 * appends the delivered/failed receipt later with the same providerMessageId.
 * DEDUPE IS PER CONNECTION (key team|type|ref|connectionId): a connection that
 * already delivered inside the window is suppressed, one that failed is tried
 * again. dedupe.record() runs only for a connection whose send succeeded.
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
    SEVERITIES, DEFAULT_DEDUPE_WINDOW_SECONDS, isValidSeverity, severityRank,
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

function withTimeout(promise, ms, controller) {
    let timer;
    const timeout = new Promise((resolve) => {
        timer = setTimeout(() => {
            resolve({ ok: false, error: 'send timed out' });
            try { controller.abort(); } catch (_) { /* abort listeners must not break the dispatcher */ }
        }, ms);
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
        const q = quietHoursDecision(severity, config.quietHours, clock());
        if (q.warning) warnings.push(q.warning);
        if (q.suppress) {
            list = ids.map((id) => make(id, { ok: false, error: '', suppressed: 'quiet-hours' }));
        } else {
            const message = { team, type, title, body, ref, severity };
            const dd = { team, type, ref, window };
            list = await Promise.all(ids.map((id) => deliver(id, message, make, dd)));
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

    async function deliver(id, message, make, dd) {
        if (dedupe.check(dd.team, dd.type, dd.ref, dd.window, id).duplicate) {
            return make(id, { ok: false, error: '', suppressed: 'dedupe' });
        }

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

        const provider = registry.get(pname);
        const params = isPlainObject(connection.params) ? connection.params : {};
        const floor = isValidSeverity(params.minSeverity) ? params.minSeverity
            : (isValidSeverity(provider.defaultMinSeverity) ? provider.defaultMinSeverity : null);
        if (floor !== null && severityRank(message.severity) < severityRank(floor)) {
            return make(id, { ok: false, error: '', suppressed: 'severity-gate', provider: pname });
        }

        const rl = rateLimiter.take(id);
        if (!rl.allowed) return make(id, { ok: false, error: '', suppressed: 'rate-limit' });

        const controller = new AbortController();
        const out = await withTimeout(
            attemptSend(provider, connection, message, controller.signal), sendTimeoutMs, controller);
        if (out.ok === true) dedupe.record(dd.team, dd.type, dd.ref, dd.window, id);
        // A provider's error text may echo this connection's own secret or destination: scrub, then bound.
        const error = out.ok === true ? '' : scrubText(out.error, sensitiveValues(connection), MAX_ERROR_TEXT);
        const fields = { ok: out.ok === true, error, provider: pname };
        if (out.providerMessageId) fields.providerMessageId = out.providerMessageId;
        if (out.ok === true && provider.asyncDelivery === true) fields.stage = 'accepted';
        return make(id, fields);
    }

    return { dispatch };
}

module.exports = { createNotifyDispatcher, NotifyDispatchError, resolveSeverity, SEVERITIES, DEFAULT_SEND_TIMEOUT_MS };
