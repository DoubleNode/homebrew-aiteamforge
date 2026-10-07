//
//  ci-dispatch-alerts.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * CI dispatcher alert shim (XACA-1441-007, plan D9, Requirement 10).
 *
 * raise(type, {severity, title, body, ref}):
 *   - If an `emitFleetNotice` function is resolvable (XACA-1400 / EPIC-0068 will export it
 *     for in-server callers) it is called; otherwise the alert is logged as
 *     `[CI-DISPATCH] ALERT ...` (the stub path).
 *   - EITHER WAY the alert is dedupe-gated locally per type+ref for 15 minutes and kept in
 *     an in-memory ring of 50 (exposed through GET /api/ci-pool), so behaviour is identical
 *     before and after XACA-1400 lands.
 *   - A throwing emitter never propagates: the alert falls back to the log path.
 *
 * Types in use: ci-no-capacity (high), ci-dispatcher-degraded (warning),
 * ci-fork-job-on-pool (warning), ci-job-misconfigured (warning; XACA-1441-031: a pool job
 * whose labels are ambiguous, deduped per repo). All but ci-fork-job-on-pool must be added
 * to the XACA-1399 notice-type catalog (noted on that dependency, not done here).
 *
 * Alert text must never carry secrets: callers pass reasons/counters only; text is
 * control-stripped and length-capped here as a last line of defence.
 */

const DEDUPE_MS = 15 * 60 * 1000;
const RING_SIZE = 50;
const MAX_TITLE = 200;
const MAX_BODY = 1000;
const MAX_REF = 200;
const SEVERITIES = Object.freeze(['info', 'warning', 'high', 'critical']);

function clean(v, max) {
    // eslint-disable-next-line no-control-regex
    return String(v === undefined || v === null ? '' : v).replace(/[\u0000-\u001f\u007f]/g, ' ').trim().slice(0, max);
}

/** Default resolver: a global, then an optional lib/fleet-notices module. Returns a function or null. */
function defaultEmitterLookup() {
    if (typeof globalThis.emitFleetNotice === 'function') return globalThis.emitFleetNotice;
    try {
        const m = require('./fleet-notices');
        if (m && typeof m.emitFleetNotice === 'function') return m.emitFleetNotice;
    } catch (_) { /* module not present yet: stub path */ }
    return null;
}

/**
 * @param {object} [opts]
 * @param {Function} [opts.now]               () => epoch ms
 * @param {object}   [opts.logger]            {warn?, log?}
 * @param {Function} [opts.getEmitter]        () => emitFleetNotice function | null (resolved per raise)
 * @param {number}   [opts.dedupeMs]
 * @param {number}   [opts.ringSize]
 */
function createAlerts(opts) {
    const o = opts || {};
    const now = typeof o.now === 'function' ? o.now : Date.now;
    const log = o.logger || console;
    const getEmitter = typeof o.getEmitter === 'function' ? o.getEmitter : defaultEmitterLookup;
    const dedupeMs = Number.isFinite(o.dedupeMs) ? o.dedupeMs : DEDUPE_MS;
    const ringSize = Number.isInteger(o.ringSize) && o.ringSize > 0 ? o.ringSize : RING_SIZE;

    const ring = [];
    const lastRaised = new Map(); // "type|ref" -> epoch ms

    function logLine(msg) {
        const fn = log.warn || log.log;
        if (typeof fn === 'function') { try { fn.call(log, msg); } catch (_) { /* logging never throws */ } }
    }

    /**
     * @returns {{raised: boolean, deduped?: boolean, via?: 'fleet-notice'|'log'}}
     */
    function raise(type, payload) {
        const p = payload || {};
        const t = clean(type, 64);
        if (!/^[a-z][a-z0-9-]{0,63}$/.test(t)) return { raised: false, error: 'bad-type' };
        const ref = clean(p.ref, MAX_REF);
        const nowMs = now();
        const dk = `${t}|${ref}`;
        const prev = lastRaised.get(dk);
        if (prev !== undefined && nowMs - prev < dedupeMs) return { raised: false, deduped: true };
        lastRaised.set(dk, nowMs);
        for (const [k, at] of lastRaised) if (nowMs - at >= dedupeMs) lastRaised.delete(k);

        const entry = {
            ts: new Date(nowMs).toISOString(),
            type: t,
            severity: SEVERITIES.includes(p.severity) ? p.severity : 'warning',
            title: clean(p.title, MAX_TITLE),
            body: clean(p.body, MAX_BODY),
            ref,
            via: 'log',
        };

        const emit = (() => { try { return getEmitter(); } catch (_) { return null; } })();
        if (typeof emit === 'function') {
            try {
                emit({ type: entry.type, severity: entry.severity, title: entry.title, body: entry.body, ref: entry.ref });
                entry.via = 'fleet-notice';
            } catch (e) {
                logLine(`[CI-DISPATCH] alert emitter failed (${clean(e && e.message, 120)}); falling back to log`);
            }
        }
        if (entry.via === 'log') {
            logLine(`[CI-DISPATCH] ALERT ${entry.type} (${entry.severity}) ${entry.title}${entry.body ? ' -- ' + entry.body : ''}`);
        }
        ring.push(entry);
        while (ring.length > ringSize) ring.shift();
        return { raised: true, via: entry.via };
    }

    /** Newest first, copies. */
    const list = () => ring.slice().reverse().map((e) => Object.assign({}, e));

    return { raise, list, RING_SIZE: ringSize };
}

module.exports = { createAlerts, DEDUPE_MS, RING_SIZE, SEVERITIES };
