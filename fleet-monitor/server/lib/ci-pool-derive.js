//
//  ci-pool-derive.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Pure derivations behind the Fleet Monitor CI/CD tab (XACA-1444-001, XACA-1444-011).
 * No I/O, no clock reads: every function takes `nowMs`. Everything here is a READ MODEL; the
 * stored `machines[m].enabled` / `.paused` fields stay the only truth the dispatcher reads (C7).
 *
 * ---------------------------------------------------------------- machine state
 * deriveMachineState(machine, report, ctx) -> { state, reason }
 *
 *   state ∈ disabled | enabled | draining | paused | resuming | unknown
 *
 * Inputs: machine = stored record {enabled, paused, thresholds}; report = last agent poll
 * {receivedAt, slots[], pauseMarker?} or null; ctx = {nowMs, pollStaleMs}.
 * "busy" slots are those whose state is busy|starting|cleaning (a job or its teardown is in flight).
 * "online" slots are idle|busy|starting|cleaning (broken is not online).
 * "fresh" = report exists AND nowMs - receivedAt <= pollStaleMs.
 *
 * Rules, first match wins:
 *   1. enabled !== true                                  -> disabled   (paused is irrelevant when disabled)
 *   2. paused === true (a pause was requested):
 *        a. no report, or report not fresh               -> unknown    (cannot tell whether it drained)
 *        b. pauseMarker === 'corrupt'                    -> unknown
 *        c. busy slots > 0                               -> draining   (jobs still running)
 *        d. pauseMarker 'draining'                       -> draining
 *        e. pauseMarker 'absent' | 'resuming'            -> draining   (host has not confirmed the pause yet)
 *        f. otherwise (marker 'paused', or no marker from an older agent, and zero busy slots)
 *                                                        -> paused
 *   3. paused !== true (accepting work is requested):
 *        a. no report ever                               -> unknown    (reason no-report)
 *        b. report not fresh (poll lapsed)               -> unknown    (reason stale-poll)
 *        c. pauseMarker 'corrupt'                        -> unknown
 *        d. pauseMarker 'resuming'                       -> resuming   (the host itself says a resume is under way)
 *        e. pauseMarker 'paused'|'draining'              -> unknown    (reason marker-paused|marker-draining: the host
 *                                                                       still shows a pause the server no longer asks for)
 *        f. no online slot (empty or all broken)         -> unknown    (reason no-online-slots)
 *        g. otherwise                                    -> enabled
 *
 * `resuming` therefore means a resume is ACTUALLY in progress (rule 3d). An enabled, unpaused machine that
 * has merely gone quiet, lost its slots or kept a stale marker is `unknown` (with a stateReason), never
 * `resuming` (XACA-1444 PR #1101 round 1). The UI offers Pause for every enabled, unpaused machine whatever
 * its derived state: controls follow the raw flags, not this read model.
 *
 * capability: what the host's agent REPORTED about itself ('dormant' | 'enabled'). Nothing reports
 * it today, so it is 'unknown' until an agent sends poll.capability; it is never inferred.
 *
 * ---------------------------------------------------------------- queue age
 * computeQueueAge(jobs, nowMs, thresholdMs, hostOf) groups still-queued jobs by label-set (and the
 * pool host their labels name) and reports depth + the oldest wait per group.
 *
 * ---------------------------------------------------------------- no-capacity
 * computeNoCapacity(tracked, queueAge, thresholdMs, keyOf): active when ANY queued job has no eligible machine
 * (noCapSince set) OR ANY queue-age group is over its threshold. The second clause is the
 * 2026-10-07 miss: the pool had busy/idle runners so "no eligible machine" never held, yet 44 jobs
 * waited ~32 min.
 */

const MACHINE_STATES = Object.freeze(['disabled', 'enabled', 'draining', 'paused', 'resuming', 'unknown']);
const CAPABILITIES = Object.freeze(['dormant', 'enabled', 'unknown']);
const BUSY_SLOT_STATES = Object.freeze(['busy', 'starting', 'cleaning']);
const ONLINE_SLOT_STATES = Object.freeze(['idle', 'busy', 'starting', 'cleaning']);

/** Queue-age alert threshold: constant default, env FLEET_CI_QUEUE_AGE_ALERT_SEC overrides.
 *  Deliberately NOT in ci-pool.json thresholds: that validator requires every key on every
 *  persisted file (requireAll), so adding one would move aside existing pools on upgrade. */
const DEFAULT_QUEUE_AGE_ALERT_SEC = 15 * 60;

function queueAgeThresholdMs(env) {
    const raw = env ? Number(env.FLEET_CI_QUEUE_AGE_ALERT_SEC) : NaN;
    const sec = Number.isFinite(raw) && raw >= 30 && raw <= 7 * 24 * 3600 ? raw : DEFAULT_QUEUE_AGE_ALERT_SEC;
    return Math.round(sec * 1000);
}

const isArr = Array.isArray;

function slotCounts(report) {
    const slots = report && isArr(report.slots) ? report.slots : [];
    let busy = 0; let online = 0;
    for (const s of slots) {
        if (!s) continue;
        if (BUSY_SLOT_STATES.includes(s.state)) busy++;
        if (ONLINE_SLOT_STATES.includes(s.state)) online++;
    }
    return { busy, online };
}

function deriveMachineState(machine, report, ctx) {
    const c = ctx || {};
    const nowMs = c.nowMs;
    const staleMs = Number.isFinite(c.pollStaleMs) ? c.pollStaleMs : 30000;
    if (!machine || machine.enabled !== true) return { state: 'disabled', reason: 'not-enabled' };
    const have = !!report && Number.isFinite(report.receivedAt);
    const fresh = have && Number.isFinite(nowMs) && nowMs - report.receivedAt <= staleMs;
    const marker = report ? report.pauseMarker : undefined;
    const { busy, online } = slotCounts(report);

    if (machine.paused === true) {
        if (!have) return { state: 'unknown', reason: 'paused-no-report' };
        if (!fresh) return { state: 'unknown', reason: 'paused-poll-stale' };
        if (marker === 'corrupt') return { state: 'unknown', reason: 'pause-marker-corrupt' };
        if (busy > 0) return { state: 'draining', reason: 'busy-slots' };
        if (marker === 'draining') return { state: 'draining', reason: 'marker-draining' };
        if (marker === 'absent' || marker === 'resuming') return { state: 'draining', reason: 'marker-not-confirming' };
        return { state: 'paused', reason: marker === 'paused' ? 'marker-confirms' : 'drained' };
    }

    if (!have) return { state: 'unknown', reason: 'no-report' };
    if (!fresh) return { state: 'unknown', reason: 'stale-poll' };
    if (marker === 'corrupt') return { state: 'unknown', reason: 'pause-marker-corrupt' };
    if (marker === 'resuming') return { state: 'resuming', reason: 'marker-resuming' };
    if (marker === 'paused' || marker === 'draining') return { state: 'unknown', reason: `marker-${marker}` };
    if (online === 0) return { state: 'unknown', reason: 'no-online-slots' };
    return { state: 'enabled', reason: 'accepting' };
}

function deriveCapability(report) {
    const v = report ? report.capability : undefined;
    return v === 'dormant' || v === 'enabled' ? v : 'unknown';
}

const iso = (ms) => (Number.isFinite(ms) ? new Date(ms).toISOString() : null);

/** Epoch ms a job entered the queue: GitHub's created_at when parsable (survives a server restart), else firstSeenAt. */
function queuedSinceMs(rec) {
    for (const f of ['createdAt', 'firstSeenAt']) {
        const t = rec && typeof rec[f] === 'string' ? Date.parse(rec[f]) : NaN;
        if (Number.isFinite(t)) return t;
    }
    return NaN;
}

/**
 * @param {Array<{labels: string[], rec?: object}>|Array<object>} jobs   queued job records (rec shape: labels, createdAt, firstSeenAt)
 * @param {number} nowMs
 * @param {number} thresholdMs
 * @param {(labels: string[]) => string|null} hostOf  pool machine id named by the labels, or null
 * @param {(labels: string[]) => string|null} keyOf    canonical label-set key
 * @returns {Array<{labels: string, host: string|null, depth: number, oldestQueuedAt: string|null, oldestWaitSec: number|null, overThreshold: boolean}>}
 *          sorted oldest wait first
 */
function computeQueueAge(jobs, nowMs, thresholdMs, hostOf, keyOf) {
    const groups = new Map();
    for (const rec of jobs || []) {
        const key = keyOf(rec.labels);
        if (key === null) continue;
        const since = queuedSinceMs(rec);
        let g = groups.get(key);
        if (!g) { g = { labels: key, host: hostOf(rec.labels), depth: 0, oldest: NaN }; groups.set(key, g); }
        g.depth++;
        if (Number.isFinite(since) && !(g.oldest <= since)) g.oldest = since;
    }
    return [...groups.values()].map((g) => {
        const known = Number.isFinite(g.oldest);
        const waitMs = known ? Math.max(0, nowMs - g.oldest) : null;
        return {
            labels: g.labels, host: g.host, depth: g.depth,
            oldestQueuedAt: known ? iso(g.oldest) : null,
            oldestWaitSec: known ? Math.floor(waitMs / 1000) : null,
            overThreshold: known && waitMs >= thresholdMs,
        };
    }).sort((a, b) => (b.oldestWaitSec === null ? -1 : b.oldestWaitSec) - (a.oldestWaitSec === null ? -1 : a.oldestWaitSec));
}

/**
 * since = earliest of: a job's noCapSince, or (for age-starved groups) the moment that group's oldest
 * job crossed the threshold. queuedCount counts only the jobs that are starved by either clause.
 * @param {Array<{rec: object, noCapSince: number|null}>} tracked
 * @param {Array} queueAge   output of computeQueueAge
 * @param {number} thresholdMs
 * @param {Function} keyOf
 */
function computeNoCapacity(tracked, queueAge, thresholdMs, keyOf) {
    const starved = new Set((queueAge || []).filter((g) => g.overThreshold).map((g) => g.labels));
    let count = 0; let oldest = NaN; let since = NaN;
    const earliest = (cur, t) => (Number.isFinite(t) && !(cur <= t) ? t : cur);
    for (const t of tracked || []) {
        const noCap = Number.isFinite(t.noCapSince);
        if (!noCap && !starved.has(keyOf(t.rec.labels))) continue;
        count++;
        oldest = earliest(oldest, queuedSinceMs(t.rec));
        if (noCap) since = earliest(since, t.noCapSince);
    }
    for (const g of queueAge || []) {
        if (g.overThreshold && g.oldestQueuedAt !== null) since = earliest(since, Date.parse(g.oldestQueuedAt) + thresholdMs);
    }
    return count === 0
        ? { active: false, since: null, queuedCount: 0, oldestQueuedAt: null }
        : { active: true, since: iso(since), queuedCount: count, oldestQueuedAt: iso(oldest) };
}

module.exports = {
    MACHINE_STATES, CAPABILITIES, DEFAULT_QUEUE_AGE_ALERT_SEC,
    deriveMachineState, deriveCapability, queueAgeThresholdMs, computeQueueAge, computeNoCapacity, queuedSinceMs,
};
