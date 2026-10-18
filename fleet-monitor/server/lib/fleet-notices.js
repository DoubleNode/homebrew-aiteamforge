//
//  fleet-notices.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Fleet-originated notices (XACA-1407-003, EPIC-0068 Phase 5).
 *
 *   emitFleetNotice({type, severity, title, body, ref}) -> Promise<result>
 *
 * The single-object contract consumed by lib/ci-dispatch-alerts.js (which resolves it via
 * require('./fleet-notices') or globalThis.emitFleetNotice; this module is reached by the
 * require path, nothing is placed on globalThis).
 *
 * Flow: sanitise -> catalog check -> dispatcher.dispatchFleet (fleet-level route set, receipts
 * with team 'fleet'). Guarantees:
 *   - NEVER throws and never returns a rejecting promise: every failure is logged (error TYPE
 *     only, no values) and resolved as {routed:false|ok:false, reason}. Callers may ignore it.
 *   - No fleet route for the type -> a log line, no send, no receipt (the default state of a
 *     fresh install; a receipt per unrouted notice would be noise).
 *   - A type that is NOT in the bundled notice-type catalog is a configuration defect, not a
 *     quiet miss: it is logged AND an ok:false receipt (team 'fleet', error 'unknown notice
 *     type') is written so it shows in GET /api/notify/receipts. The catalog is deliberately not
 *     extended for the ci-dispatcher alert types (the Python side pins its size and the tap
 *     mirrors it), so those alerts are visible in receipts but not routable until the catalog
 *     grows them. ci-runner-disk-low (XACA-1537-004) IS in the catalog and routes normally.
 *   - Before configure() (hub not wired) it logs and resolves {routed:false, reason:'not-configured'}.
 */

const TYPE_RE = /^[a-z][a-z0-9-]{0,31}$/;
const SEVERITIES = ['info', 'warning', 'high', 'critical'];
const MAX_TITLE = 200;
const MAX_BODY = 1000;
const MAX_REF = 128;

function clean(v, max) {
    // eslint-disable-next-line no-control-regex
    return String(v === undefined || v === null ? '' : v).replace(/[\u0000-\u001f\u007f]/g, ' ').trim().slice(0, max);
}

/** Receipt/route-safe ref: [A-Za-z0-9._:/#-], starting alphanumeric, or undefined. */
function cleanRef(v) {
    if (v === undefined || v === null || v === '') return undefined;
    const r = String(v).replace(/[^A-Za-z0-9._:/#-]/g, '-').slice(0, MAX_REF);
    return /^[A-Za-z0-9]/.test(r) ? r : undefined;
}

/** ` -- title -- body` (scrubbed, bounded) so a log-only outcome still tells the operator WHAT happened. */
function detail(n) {
    try {
        const o = n && typeof n === 'object' ? n : {};
        const t = clean(o.title, MAX_TITLE);
        const b = clean(o.body, MAX_BODY);
        return `${t ? ` -- ${t}` : ''}${b ? ` -- ${b}` : ''}`;
    } catch (_) { return ''; }
}

function errType(e) { return (e && e.name) || (e && e.constructor && e.constructor.name) || 'Error'; }

/**
 * @param {object} deps
 * @param {{dispatchFleet: Function}} deps.dispatcher
 * @param {{catalogTypeIds: Function}} deps.store
 * @param {{newReceipt: Function, append: Function}} [deps.receipts]
 * @param {{log?: Function, warn?: Function}} [deps.logger]
 */
function createFleetNotices(deps) {
    const { dispatcher, store, receipts } = deps || {};
    const logger = (deps && deps.logger) || console;
    const log = (m) => { try { (logger.log || console.log).call(logger, m); } catch (_) { /* never throw */ } };
    const warn = (m) => { try { (logger.warn || logger.log || console.warn).call(logger, m); } catch (_) { /* never throw */ } };

    async function emitFleetNotice(input) {
        try {
            const n = input && typeof input === 'object' ? input : {};
            const type = typeof n.type === 'string' ? n.type : '';
            if (!TYPE_RE.test(type)) {
                warn('[FLEET-NOTICE] dropped: invalid notice type');
                return { ok: false, routed: false, reason: 'invalid-type' };
            }
            const severity = SEVERITIES.includes(n.severity) ? n.severity : undefined;
            const ref = cleanRef(n.ref);
            const notice = {
                type, title: clean(n.title, MAX_TITLE) || type, body: clean(n.body, MAX_BODY),
            };
            if (severity) notice.severity = severity;
            if (ref !== undefined) notice.ref = ref;

            let known = false;
            try { known = store.catalogTypeIds().includes(type); } catch (_) { known = false; }
            if (!known) {
                warn(`[FLEET-NOTICE] ${type}${ref ? ` (${ref})` : ''}: unknown notice type (not in catalog); not routable${detail(notice)}`);
                if (receipts) {
                    try {
                        const f = { team: 'fleet', type, severity: severity || 'warning', ok: false, error: 'unknown notice type' };
                        if (ref !== undefined) f.ref = ref;
                        receipts.append(receipts.newReceipt(f));
                    } catch (e) { warn(`[FLEET-NOTICE] receipt write failed (${errType(e)})`); }
                }
                return { ok: false, routed: false, reason: 'unknown-type' };
            }

            const out = await dispatcher.dispatchFleet(notice);
            if (!out || typeof out !== 'object') {
                warn(`[FLEET-NOTICE] ${type}: dispatcher returned no result`);
                return { ok: false, routed: false, reason: 'emit-failed' };
            }
            if (!out || out.routed !== true) {
                log(`[FLEET-NOTICE] ${type}${ref ? ` (${ref})` : ''}: no fleet route; not sent${detail(notice)}`);
            } else {
                log(`[FLEET-NOTICE] ${type}${ref ? ` (${ref})` : ''}: delivered=${out.delivered} failed=${out.failed} suppressed=${out.suppressed}`);
            }
            return out;
        } catch (e) {
            // dispatchFleet can throw receipt_write_failed (with a result) or anything unexpected.
            warn(`[FLEET-NOTICE] emit failed (${errType(e)}${e && e.code ? `/${String(e.code).slice(0, 40)}` : ''})`);
            return { ok: false, routed: false, reason: 'emit-failed' };
        }
    }
    return { emitFleetNotice };
}

// ----- process-wide instance (what ci-dispatch-alerts and server.js reach via require) -----
let current = null;

function configure(deps) {
    current = createFleetNotices(deps);
    return current;
}

function emitFleetNotice(input) {
    if (!current) {
        try { console.warn('[FLEET-NOTICE] hub not wired yet; notice not sent' + detail(input)); } catch (_) { /* never throw */ }
        return Promise.resolve({ ok: false, routed: false, reason: 'not-configured' });
    }
    return current.emitFleetNotice(input);
}

module.exports = { createFleetNotices, configure, emitFleetNotice, _reset: () => { current = null; } };
