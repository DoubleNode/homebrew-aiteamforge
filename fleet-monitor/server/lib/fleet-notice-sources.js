//
//  fleet-notice-sources.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Fleet-originated notice sources (XACA-1407-002/-003, EPIC-0068 Phase 5).
 *
 * Pure state machines that turn Fleet Monitor state observations into typed notices. They own
 * NO I/O: each takes an injected `emit(notice)` (fleet-notices.emitFleetNotice in production,
 * a recorder in tests) and an injectable clock, and never throws to the caller (server.js calls
 * them from the 30 s status tick and from request handlers).
 *
 * MACHINE TRACKER (machine-offline / machine-recovered)
 *   Fed the CURRENT status of a machine on every observation -- every 30 s tick for every
 *   machine, plus the /api/status heartbeat (which flips a machine to online without going
 *   through the tick). The tracker, not the caller, detects transitions, so re-observing the
 *   same status never re-emits.
 *   - up = status 'online' | 'warning'; down = 'offline'. warning<->online is NOT a transition.
 *   - up -> down  : machine-offline (critical).  down -> up : machine-recovered (info), but only
 *                   if the offline was announced (see flap damping).
 *   - STARTUP: the first observation of a machine is a BASELINE and emits nothing. A machine
 *     that is already stale when the server boots (the first tick flips it to offline) therefore
 *     produces no burst of offline notices. A machine baselined as down is treated as
 *     already-announced, so its eventual recovery IS announced.
 *   - FLAP DAMPING (flapWindowMs, default 5 min): after a recovery, a new offline inside the
 *     window is suppressed (and so is its matching recovery) -- the operator already holds a
 *     "recovered" and a machine bouncing around the 180 s offline threshold would otherwise send
 *     an offline/recovered pair every few minutes. A suppressed offline is not lost: if the machine
 *     is STILL down flapWindowMs after it went down, the offline notice is emitted then
 *     (reported on a later observation, i.e. the next tick). The window slides: each recovery
 *     restarts it, so a machine that keeps bouncing yields one pair, then silence until it has
 *     been stable for the window. The hub's own dedupe (type+ref) is a second, independent layer.
 *   - FM-STALL GUARD (XACA-1407-010): if Fleet Monitor's own host sleeps or its event loop stalls,
 *     the next status sweep sees EVERY machine's last_seen as stale and would flip them all to
 *     offline at once, then a recovered wave when their heartbeats resume. The caller calls
 *     beginSweep() at the top of each status sweep; when the gap since the previous sweep exceeds
 *     stallThresholdMs (default 90 s = 3 x the 30 s tick; sweeps also run from request handlers so
 *     the gap can only be shorter than the tick, never longer, unless the process really stalled),
 *     the tracker logs ONE line and opens a grace period of stallGraceMs (default = the offline
 *     threshold, 180 s, i.e. long enough for every healthy reporter to heartbeat again). Edges INTO
 *     offline during the grace are held, not announced. Once the grace has elapsed, a machine that
 *     is STILL offline gets exactly one machine-offline (a genuine outage is delayed, never lost);
 *     a machine that heartbeats first recovers quietly (its offline was never announced, so no
 *     recovered either). Machines already announced offline before the stall are unaffected.
 *     The FIRST sweep after boot has no previous sweep and is never a stall (XACA-1407-011).
 *
 * ACCESSORY TRACKER (accessory-on-battery / accessory-restored)
 *   Fed registry transitions (from, to) per accessory.
 *   - to 'on_battery'  -> accessory-on-battery (high), unless the previous on-battery was already
 *                         announced and no 'ac' has been seen since (unknown flaps do not repeat it).
 *   - to 'ac' after on_battery (directly, or via 'unknown') -> accessory-restored (info).
 *   - 'unknown' (stale reading / no data) NEVER notifies by itself: it means "cannot tell", not
 *     "power is fine" or "power is lost". An on_battery -> unknown -> ac path still announces
 *     the restore; an ac -> unknown -> ac path announces nothing.
 *   - Announce state is in memory: after a server restart an accessory that was already on battery
 *     is not re-announced, but its on_battery -> ac restore still is (from === 'on_battery').
 */

const FLAP_WINDOW_MS = 5 * 60 * 1000;
const STALL_THRESHOLD_MS = 90 * 1000;      // 3 x the 30 s status tick
const DEFAULT_STALL_GRACE_MS = 180 * 1000; // = server.js OFFLINE_THRESHOLD_MS

function safeEmit(emit, logger, notice) {
    try {
        const r = emit(notice);
        // emitFleetNotice is async but never rejects; guard anyway so a custom emitter cannot leak.
        if (r && typeof r.catch === 'function') r.catch(() => {});
    } catch (e) {
        try { (logger && logger.warn ? logger.warn : console.warn)(`[FLEET-NOTICE] source emit failed (${String(e && e.name || 'Error')})`); } catch (_) { /* never throw */ }
    }
}

function clean(v, max) {
    // eslint-disable-next-line no-control-regex
    return String(v === undefined || v === null ? '' : v).replace(/[\u0000-\u001f\u007f]/g, ' ').trim().slice(0, max);
}

function humanDuration(ms) {
    const s = Math.max(0, Math.floor(ms / 1000));
    if (s < 60) return `${s}s`;
    const m = Math.floor(s / 60);
    if (m < 60) return `${m}m`;
    const h = Math.floor(m / 60);
    return h < 48 ? `${h}h ${m % 60}m` : `${Math.floor(h / 24)}d`;
}

/**
 * @param {object} o
 * @param {Function} o.emit                    (notice) => any
 * @param {Function} [o.now]                   () => epoch ms
 * @param {number}   [o.flapWindowMs]
 * @param {number}   [o.offlineThresholdMs]    notice text; also the default stall grace
 * @param {number}   [o.stallThresholdMs]      sweep gap that counts as an FM stall (default 90 s)
 * @param {number}   [o.stallGraceMs]          hold period after a stall (default offlineThresholdMs, else 180 s)
 * @param {object}   [o.logger]                {warn?, log?}
 */
function createMachineNoticeTracker(o = {}) {
    if (typeof o.emit !== 'function') throw new TypeError('createMachineNoticeTracker: emit is required');
    const now = typeof o.now === 'function' ? o.now : Date.now;
    const flapMs = Number.isFinite(o.flapWindowMs) && o.flapWindowMs >= 0 ? o.flapWindowMs : FLAP_WINDOW_MS;
    const logger = o.logger || console;
    const entries = new Map();
    const stallMs = Number.isFinite(o.stallThresholdMs) && o.stallThresholdMs > 0 ? o.stallThresholdMs : STALL_THRESHOLD_MS;
    const graceMs = Number.isFinite(o.stallGraceMs) && o.stallGraceMs >= 0 ? o.stallGraceMs
        : (Number.isFinite(o.offlineThresholdMs) && o.offlineThresholdMs > 0 ? o.offlineThresholdMs : DEFAULT_STALL_GRACE_MS);
    let lastSweepAt = null;  // null until the first sweep (boot): never a stall
    let holdUntil = 0;       // edges into offline before this instant are held (stall grace)

    /**
     * Call once at the top of every status sweep (before observe()). Returns true when this
     * sweep follows an FM stall. Never throws.
     */
    function beginSweep() {
        const t = now();
        const gap = lastSweepAt === null ? 0 : t - lastSweepAt;
        lastSweepAt = t;
        if (gap > stallMs) {
            holdUntil = t + graceMs;
            try { (logger.warn || logger.log || console.warn).call(logger, `[FLEET-NOTICE] status sweep gap ${Math.round(gap / 1000)}s > ${Math.round(stallMs / 1000)}s: Fleet Monitor stalled; offline notices held ${Math.round(graceMs / 1000)}s`); } catch (_) { /* never throw */ }
            return true;
        }
        return false;
    }

    function offlineNotice(id, info) {
        const label = clean(info.label || id, 100);
        const lastSeen = info.lastSeen ? clean(info.lastSeen, 40) : null;
        const thr = Number.isFinite(o.offlineThresholdMs) ? ` (offline threshold ${Math.round(o.offlineThresholdMs / 1000)}s)` : '';
        return {
            type: 'machine-offline', severity: 'critical',
            title: `Machine offline: ${label}`,
            body: `${label} stopped reporting${thr}.${lastSeen ? ` Last seen ${lastSeen}.` : ''}`,
            ref: clean(id, 128),
        };
    }

    /**
     * @param {string} id          stable machine key
     * @param {string} status      'online' | 'warning' | 'offline' (anything else is ignored)
     * @param {{label?:string,lastSeen?:string}} [info]  lastSeen = the machine's last heartbeat BEFORE this observation (ISO string)
     * @returns {string|null} what happened: baseline | offline | suppressed-offline | escalated-offline | recovered | recovered-quiet | null
     */
    function observe(id, status, info = {}) {
        if (typeof id !== 'string' || id === '') return null;
        if (status !== 'online' && status !== 'warning' && status !== 'offline') return null;
        const t = now();
        const up = status !== 'offline';
        const e = entries.get(id);
        if (!e) {
            entries.set(id, { up, announced: !up, lastRecoveredAt: null, downSince: up ? null : t, held: false });
            return 'baseline';
        }
        if (e.up && !up) {
            e.up = false;
            e.downSince = t;
            if (t < holdUntil) {
                // Fleet Monitor itself stalled: this "offline" may be FM's own absence. Hold it.
                e.announced = false;
                e.held = true;
                return 'held-offline';
            }
            e.held = false;
            if (e.lastRecoveredAt !== null && t - e.lastRecoveredAt < flapMs) {
                e.announced = false;
                return 'suppressed-offline';
            }
            e.announced = true;
            const n = offlineNotice(id, info);
            safeEmit(o.emit, logger, n);
            return 'offline';
        }
        if (!e.up && up) {
            const wasAnnounced = e.announced;
            // Downtime = now - the machine's last heartbeat BEFORE this one (info.lastSeen). The tracker's
            // own downSince is only when FM noticed (boot baseline, stall hold, escalation), so it is a
            // FALLBACK for a missing, unparseable or future lastSeen (XACA-1407-012).
            const seenMs = typeof info.lastSeen === 'string' ? Date.parse(info.lastSeen) : NaN;
            const downFor = Number.isFinite(seenMs) && seenMs <= t ? t - seenMs
                : (e.downSince === null ? 0 : t - e.downSince);
            e.up = true;
            e.announced = false;
            e.held = false;
            e.downSince = null;
            e.lastRecoveredAt = t;
            if (!wasAnnounced) return 'recovered-quiet';
            const label = clean(info.label || id, 100);
            safeEmit(o.emit, logger, {
                type: 'machine-recovered', severity: 'info',
                title: `Machine recovered: ${label}`,
                body: `${label} is reporting again${downFor > 0 ? ` after ${humanDuration(downFor)} offline` : ''}.`,
                ref: clean(id, 128),
            });
            return 'recovered';
        }
        if (!e.up && !e.announced && e.held) {
            // Compare against the LIVE hold, so a second stall during the grace re-opens it.
            if (t < holdUntil) return null;
            e.announced = true;
            e.held = false;
            safeEmit(o.emit, logger, offlineNotice(id, info));
            return 'escalated-offline';
        }
        if (!e.up && !e.announced && e.downSince !== null && t - e.downSince >= flapMs) {
            e.announced = true;
            const n = offlineNotice(id, info);
            safeEmit(o.emit, logger, n);
            return 'escalated-offline';
        }
        return null;
    }

    return { observe, beginSweep, forget: (id) => entries.delete(id), _size: () => entries.size, flapWindowMs: flapMs };
}

/**
 * @param {object} o
 * @param {Function} o.emit
 * @param {object}   [o.logger]
 */
function createAccessoryNoticeTracker(o = {}) {
    if (typeof o.emit !== 'function') throw new TypeError('createAccessoryNoticeTracker: emit is required');
    const logger = o.logger || console;
    const announced = new Set(); // accessory ids whose on-battery was announced and not yet restored

    /**
     * @param {{id:string,name?:string,nickname?:string|null}} rec
     * @param {string} from
     * @param {string} to
     * @returns {string|null} on-battery | restored | null
     */
    function transition(rec, from, to) {
        if (!rec || typeof rec.id !== 'string') return null;
        const label = clean(rec.nickname || rec.name || rec.id, 100);
        const ref = clean(`acc:${rec.id}`, 128);
        if (to === 'on_battery') {
            if (announced.has(rec.id)) return null; // unknown flap while still on battery: already told
            announced.add(rec.id);
            safeEmit(o.emit, logger, {
                type: 'accessory-on-battery', severity: 'high',
                title: `On battery: ${label}`,
                body: `${label} switched to battery power.`,
                ref,
            });
            return 'on-battery';
        }
        if (to === 'ac' && (from === 'on_battery' || announced.has(rec.id))) {
            announced.delete(rec.id);
            safeEmit(o.emit, logger, {
                type: 'accessory-restored', severity: 'info',
                title: `Power restored: ${label}`,
                body: `${label} is back on mains power.`,
                ref,
            });
            return 'restored';
        }
        // 'unknown' never notifies. If we leave on_battery for unknown, remember it was on battery.
        if (from === 'on_battery' && to === 'unknown') announced.add(rec.id);
        return null;
    }

    return { transition, _announced: () => new Set(announced) };
}

module.exports = { createMachineNoticeTracker, createAccessoryNoticeTracker, FLAP_WINDOW_MS, STALL_THRESHOLD_MS, humanDuration };
