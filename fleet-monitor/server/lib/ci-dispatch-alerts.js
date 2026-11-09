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
 * whose labels are ambiguous, deduped per repo), ci-queue-age (high) and ci-capacity-restored
 * (info). All six are in the notice-type catalog (XACA-1763-004; before that every notify
 * receipt was ok:false "unknown notice type" and nobody was paged).
 *
 * INCIDENT ALERTS (XACA-1763-004). ci-no-capacity (ref class:<cls>) and ci-queue-age (ref
 * queue:<setKey>) describe a CONDITION that persists, not an event: the 2026-11-06 stall re-paged
 * every 15 min per ref for ~45 min. They use raiseIncident()/sweepIncidents() instead of raise():
 *   - the incident OPENS on the first raiseIncident() for type+ref: exactly one page;
 *   - every later raiseIncident() while open is silent (still true, nothing new to say);
 *   - sweepIncidents() runs once per tick with the refs still active. A ref that is no longer
 *     active starts a CLEAR timer; only after it has stayed clear for clearMs does ONE
 *     ci-capacity-restored (info, same ref) fire and the incident close. A ref that turns active
 *     again before then just cancels the timer (flapping inside the window is one incident, no
 *     re-page). After the close a genuinely new stall pages again.
 *   - State is in memory: a dispatcher RESTART in the middle of a stall forgets the open incident
 *     and pages ONCE more, which is acceptable (the operator wants to know it is still down).
 *   - DELIVERY (XACA-1763-013): an incident only counts as PAGED once the emitter's result says it
 *     was delivered (emitFleetNotice resolves {ok:true,...} when at least one connection accepted
 *     it; {ok:false, routed:false, reason} for no route / unknown type / emit failure). While an
 *     incident is open but unpaged (ok:false, rejected, threw, or no emitter) the page is retried
 *     on the dedupeMs (15 min) cadence until one delivers; after that it is silent. Recovery is
 *     announced only for an incident that was actually paged: an unpaged incident that clears
 *     closes silently (never announce the recovery of something nobody was told about). The
 *     emitter's Promise is handled without awaiting (raiseIncident stays synchronous); each
 *     incident is its own object, so a late-resolving page for an incident that has since closed
 *     or reopened is ignored (identity doubles as a generation counter).
 * Other types keep the per-type+ref 15 minute dedupe of raise().
 *
 * Alert text must never carry secrets: callers pass reasons/counters only; text is
 * control-stripped and length-capped here as a last line of defence.
 */

const DEDUPE_MS = 15 * 60 * 1000;
const CLEAR_MS = 5 * 60 * 1000;   // incident clear-hysteresis default; the dispatcher passes INCIDENT_CLEAR_MS
const RECOVERY_TYPE = 'ci-capacity-restored';
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
 * @param {number}   [opts.clearMs]           incident clear-hysteresis (how long a ref must stay inactive before recovery fires)
 * @param {number}   [opts.ringSize]
 */
function createAlerts(opts) {
    const o = opts || {};
    const now = typeof o.now === 'function' ? o.now : Date.now;
    const log = o.logger || console;
    const getEmitter = typeof o.getEmitter === 'function' ? o.getEmitter : defaultEmitterLookup;
    const dedupeMs = Number.isFinite(o.dedupeMs) ? o.dedupeMs : DEDUPE_MS;
    const ringSize = Number.isInteger(o.ringSize) && o.ringSize > 0 ? o.ringSize : RING_SIZE;

    const clearMs = Number.isFinite(o.clearMs) && o.clearMs >= 0 ? o.clearMs : CLEAR_MS;

    const ring = [];
    const incidents = new Map();   // "type|ref" -> {type, ref, clearSince: epoch ms | null}
    const lastRaised = new Map(); // "type|ref" -> epoch ms

    function logLine(msg) {
        const fn = log.warn || log.log;
        if (typeof fn === 'function') { try { fn.call(log, msg); } catch (_) { /* logging never throws */ } }
    }

    /**
     * @returns {{raised: boolean, deduped?: boolean, via?: 'fleet-notice'|'log'}}
     */
    function raise(type, payload, ropts) {
        const res = send(type, payload, ropts);
        if (!('delivery' in res)) return res;
        const pub = Object.assign({}, res);
        delete pub.delivery;   // internal: only incidents track delivery; raise()'s public shape is unchanged
        return pub;
    }

    /** raise() plus `delivery` (boolean | Promise<boolean>) on a raised result. */
    function send(type, payload, ropts) {
        const p = payload || {};
        const force = !!(ropts && ropts.force);   // incident open/recovery manage their own dedupe
        const t = clean(type, 64);
        if (!/^[a-z][a-z0-9-]{0,63}$/.test(t)) return { raised: false, error: 'bad-type' };
        const ref = clean(p.ref, MAX_REF);
        const nowMs = now();
        const dk = `${t}|${ref}`;
        const prev = lastRaised.get(dk);
        if (!force && prev !== undefined && nowMs - prev < dedupeMs) return { raised: false, deduped: true };
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

        // delivery: boolean (synchronous emitter result) or Promise<boolean> (never rejects); true only
        // for an emitter result with ok === true.
        let delivery = false;
        const emit = (() => { try { return getEmitter(); } catch (_) { return null; } })();
        if (typeof emit === 'function') {
            try {
                const out = emit({ type: entry.type, severity: entry.severity, title: entry.title, body: entry.body, ref: entry.ref });
                entry.via = 'fleet-notice';
                const judge = (r) => {
                    if (r && r.ok === true) return true;
                    if (ropts && ropts.logUndelivered) logLine(`[CI-DISPATCH] ${entry.type} (${entry.ref}) page NOT delivered (${clean(r && r.reason, 60) || 'no result'})`);
                    return false;
                };
                delivery = out && typeof out.then === 'function'
                    ? Promise.resolve(out).then(judge, (e) => {
                        if (ropts && ropts.logUndelivered) logLine(`[CI-DISPATCH] ${entry.type} (${entry.ref}) page NOT delivered (emitter rejected: ${clean(e && e.message, 120)})`);
                        return false;
                    })
                    : judge(out);
            } catch (e) {
                logLine(`[CI-DISPATCH] alert emitter failed (${clean(e && e.message, 120)}); falling back to log`);
            }
        }
        if (entry.via === 'log') {
            logLine(`[CI-DISPATCH] ALERT ${entry.type} (${entry.severity}) ${entry.title}${entry.body ? ' -- ' + entry.body : ''}`);
        }
        ring.push(entry);
        while (ring.length > ringSize) ring.shift();
        return { raised: true, via: entry.via, delivery };
    }

    /**
     * Call every tick while the condition holds. First call for type+ref opens the incident and pages once.
     * @returns {{raised: boolean, deduped?: boolean, opened?: boolean, via?: string}}
     */
    function raiseIncident(type, payload) {
        const t = clean(type, 64);
        const ref = clean((payload || {}).ref, MAX_REF);
        const k = `${t}|${ref}`;
        const open = incidents.get(k);
        if (open) {
            open.clearSince = null;
            // Paged: silent. Unpaged: retry on the dedupe cadence until a page is delivered.
            if (open.paged || now() - open.lastAttemptAt < dedupeMs) return { raised: false, deduped: true };
            return page(open, payload, { retried: true });
        }
        const inc = { type: t, ref, clearSince: null, paged: false, lastAttemptAt: now() };
        const res = page(inc, payload, {});
        if (res.raised) incidents.set(k, inc);
        return Object.assign({ opened: !!res.raised }, res);
    }

    function page(inc, payload, extra) {
        inc.lastAttemptAt = now();
        const res = send(inc.type, payload, { force: true, logUndelivered: true });
        if (res.raised) {
            // Only THIS incident object is marked: a late result for one that closed/reopened is a no-op.
            if (res.delivery === true) inc.paged = true;
            else if (res.delivery && typeof res.delivery.then === 'function') res.delivery.then((ok) => { if (ok) inc.paged = true; });
        }
        const out = Object.assign({}, extra, res);
        delete out.delivery;
        return out;
    }

    /**
     * Close open incidents of `type` SILENTLY (no recovery notice). For when the condition can no
     * longer be observed (dispatcher in shadow/dormant, the job's pinned host left live): "no
     * longer stalled" there is absence of evidence, and announcing recovery would be false.
     * @param {string} type
     * @param {Array<string>|Set<string>} [refs] only these refs; omitted = every incident of the type
     * @returns {string[]} refs closed
     */
    function closeIncidents(type, refs) {
        const t = clean(type, 64);
        const only = refs === undefined || refs === null ? null : new Set([...refs].map((r) => clean(r, MAX_REF)));
        const closed = [];
        for (const [k, inc] of [...incidents]) {
            if (inc.type !== t || (only && !only.has(inc.ref))) continue;
            incidents.delete(k);
            closed.push(inc.ref);
        }
        return closed;
    }

    /**
     * Call once per tick per incident type with the refs that are STILL active this tick.
     * Emits one recovery per incident that has stayed inactive for clearMs.
     * @param {string} type
     * @param {Set<string>|Array<string>} activeRefs
     * @param {(ref: string) => {title?: string, body?: string}} [describe]
     * @returns {string[]} refs recovered this call
     */
    function sweepIncidents(type, activeRefs, describe) {
        const t = clean(type, 64);
        const active = new Set([...(activeRefs || [])].map((r) => clean(r, MAX_REF)));
        const nowMs = now();
        const recovered = [];
        for (const [k, inc] of [...incidents]) {
            if (inc.type !== t) continue;
            if (active.has(inc.ref)) { inc.clearSince = null; continue; }
            if (inc.clearSince === null) inc.clearSince = nowMs;
            if (nowMs - inc.clearSince < clearMs) continue;
            if (!inc.paged) { incidents.delete(k); recovered.push(inc.ref); continue; }   // never announce an unpaged incident's recovery
            const d = (typeof describe === 'function' ? describe(inc.ref) : null) || {};
            raise(RECOVERY_TYPE, {
                severity: 'info',
                title: d.title || `CI ${t === 'ci-queue-age' ? 'queue age' : 'capacity'} recovered (${inc.ref})`,
                body: d.body || `The ${t} incident for ${inc.ref} has cleared.`,
                ref: inc.ref,
            }, { force: true });
            incidents.delete(k);
            recovered.push(inc.ref);
        }
        return recovered;
    }

    /** Open incidents, copies (for status/diagnostics). */
    const openIncidents = () => [...incidents.values()].map((i) => Object.assign({}, i));

    /** Newest first, copies. */
    const list = () => ring.slice().reverse().map((e) => Object.assign({}, e));

    return { raise, raiseIncident, sweepIncidents, closeIncidents, openIncidents, list, RING_SIZE: ringSize };
}

module.exports = { createAlerts, DEDUPE_MS, CLEAR_MS, RECOVERY_TYPE, RING_SIZE, SEVERITIES };
