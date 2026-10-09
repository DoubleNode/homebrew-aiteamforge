//
//  ci-dispatcher.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Fleet CI Pool dispatcher orchestrator (XACA-1441-007; plan D3-D10, Requirements 3/10/11,
 * spike amendments A2/A3/A6).
 *
 * One tick =
 *   1. assignments.sweep()        expire stale assignments, DELETE owed registrations
 *   2. watcher.runCycle()         poll GitHub; job events arrive through onJob()
 *   3. decide()                   no-capacity detection, per-label-set supply, mint
 * and the NEXT tick is scheduled with the delay the watcher asked for (15 s busy / 60 s
 * idle / rate-limit resume), via a self-rescheduling timer so ticks never overlap.
 *
 * MODES (XACA-1445-011): FLEET_CI_DISPATCHER = "1" (live) | "shadow" (decide + record, NEVER
 * mint) | anything else (dormant; an unknown value is logged and never treated as live). A
 * pool machine record may also carry mode:'shadow'|'live' (absent = live, EXCEPT for a job accepted only via
 * its static host label with no pool label, XACA-1445-014: that mints solely on an explicit 'live' host): a host in shadow is
 * decided for but never minted on, which is the per-host rollback (plan R1). Minting and demand rank over
 * LIVE hosts only (XACA-1445-015); the decision record keeps the all-host choice. Every newly seen
 * queued job gets ONE decision record appended to the JSONL file named by FLEET_CI_SHADOW_LOG
 * (or opts.shadowLogPath), in shadow and live alike, so the two are comparable. See
 * fleet-monitor/docs/CI-POOL-API-CONTRACT.md for the record contract.
 *
 * DORMANT (Requirement 3): unless env.FLEET_CI_DISPATCHER is "1" or "shadow" AND the GitHub App
 * credentials are configured, start() creates no watcher, schedules no timer and makes no
 * GitHub call; tick() is a no-op. isEnabled() is what the agent poll reports as `enabled`.
 *
 * LABEL KEYS: supply and outstanding supply are keyed ONLY by placement.labelSetKey()
 * (lowercased/trimmed/deduped/sorted, comma-joined), which is also what
 * assignments.outstandingBySet() uses. policy.evaluateJob() has its own lowercase
 * `canonical` helper but only for yes/no comparisons, never as a key, so a job labelled
 * `Linux` and one labelled `linux` are one set end to end.
 *
 * SLOTS: a pending/delivered assignment has not started its listener yet, so the agent's
 * report still shows its slot as idle. Before ranking, those slots (plus mints made earlier in
 * the same tick) are marked `reserved` on a COPY of the report, so one idle slot is never
 * promised twice. `started` assignments are not reserved: the agent already reports them busy.
 *
 * Secrets: this module never sees a JIT config (assignments.mint keeps it) and never logs
 * anything but ids, counts and reason codes.
 */

const fs = require('fs');
const path = require('path');
const placement = require('./ci-dispatch-placement');
const policy = require('./ci-dispatch-policy');
const derive = require('./ci-pool-derive');

const NO_CAPACITY_AFTER_MS = 120 * 1000;
const FALLBACK_DELAY_MS = 60 * 1000;
const TICK_FAIL_ALERT_AFTER = 3;
const MINT_FAIL_ALERT_AFTER = 3;
// Backstop against ghost demand (XACA-1441 PR #1083 review): a tracked job whose runners keep
// expiring unpicked, or that has been tracked longer than GitHub keeps a job queued, stops being
// demand. The watcher's `vanished` completions are the primary fix; these bound whatever is left.
// XACA-1441-033: the count is runners minted FOR the job that EXPIRED WITHOUT EVER BINDING a job,
// not mints made. Under label contention GitHub may hand job A's runner to job B; that runner did
// pick work up, so it says nothing about whether job A is a ghost. (Name kept: it is the same cap.)
const MAX_MINTS_PER_JOB = 5;
const MAX_TRACKED_MS = 24 * 60 * 60 * 1000;
// XACA-1441-029: still-queued jobs rejected for a reason a config PUT can change are remembered
// (bounded) so onConfigChanged() can re-evaluate them. Fork reasons are never in this set: a fork
// job is never made acceptable by editing config.
const CONFIG_DEPENDENT_REASONS = Object.freeze(['not-allowlisted', 'label:unknown', 'label:not-pool', 'label:ambiguous']);
const MAX_CONFIG_REJECTED = 500;
// XACA-1445-011: decision-record dedup memory (job ids) and how much of the log tail is read at
// first use to re-prime it after a restart, so a restart does not re-record still-queued jobs.
const MAX_DECIDED_IDS = 20000;
const SHADOW_LOG_PRIME_BYTES = 512 * 1024;
const DEFAULT_SHADOW_LOG_NAME = 'ci-shadow-decisions.jsonl';

// XACA-1479-006: dispatch priority. Only these two values outrank normal; anything else (missing,
// 'normal', unknown, a non-string) ranks as normal -- the dispatcher never promotes on bad data.
const PRIORITY_RANK = Object.freeze({ critical: 0, high: 1 });
const NORMAL_RANK = 2;
function priorityRank(rec) {
    const p = rec && rec.priority;
    return typeof p === 'string' && Object.prototype.hasOwnProperty.call(PRIORITY_RANK, p) ? PRIORITY_RANK[p] : NORMAL_RANK;
}

/**
 * XACA-1479-006: per label set, the surge window for its priority job(s). Pure.
 * @param {object[]} demandFifo  job records in demand (covered + needing), oldest first
 * @param {Set}      coveredKeys job keys that already have an outstanding runner
 * @param {Function} setKeyOf    labels -> label-set key
 * @returns {Map<string, {priority, target, forJobId, forKey, windowKeys:Set, uncoveredInWindow:number}>}
 *   target = 1-based FIFO position of the NEWEST priority job in the set (it plus every job ahead of it);
 *   windowKeys = the UNCOVERED jobs inside that window (the ones a surge must mint for);
 *   priority = the highest priority present in the window. Sets with no priority job are absent.
 */
function surgePlan(demandFifo, coveredKeys, setKeyOf) {
    const bySet = new Map();
    for (const rec of demandFifo) {
        const sk = setKeyOf(rec.labels);
        if (sk === null) continue;
        if (!bySet.has(sk)) bySet.set(sk, []);
        bySet.get(sk).push(rec);
    }
    const out = new Map();
    for (const [sk, recs] of bySet) {
        let last = -1;
        let best = NORMAL_RANK;
        recs.forEach((r, i) => { const rk = priorityRank(r); if (rk < NORMAL_RANK) { last = i; if (rk < best) best = rk; } });
        if (last < 0) continue;
        const windowKeys = new Set();
        for (let i = 0; i <= last; i++) if (!coveredKeys.has(recs[i].key)) windowKeys.add(recs[i].key);
        out.set(sk, {
            priority: best === PRIORITY_RANK.critical ? 'critical' : 'high',
            target: last + 1, forJobId: recs[last].jobId, forKey: recs[last].key,
            windowKeys, uncoveredInWindow: windowKeys.size,
        });
    }
    return out;
}

const clean = (v) => (v === undefined || v === null ? '' : String(v).trim());
/** Display string from untrusted data: string only, control chars -> space, capped, else null. */
function capStr(v, max) {
    if (typeof v !== 'string') return null;
    const t = v.replace(/[\u0000-\u001f\u007f]/g, ' ').trim();
    return t === '' ? null : t.slice(0, max);
}

/** True when GitHub App credentials look configured (presence only; never read the value elsewhere). */
function hasCredentials(env) {
    const e = env || {};
    return (clean(e.GITHUB_APP_CLIENT_ID) !== '' || clean(e.GITHUB_APP_ID) !== '') && clean(e.GITHUB_APP_PRIVATE_KEY) !== '';
}

/**
 * XACA-1445-011: the global dispatcher mode from FLEET_CI_DISPATCHER.
 *   "1"      -> live    (backwards compatible)
 *   "shadow" -> shadow  (decide + record, never mint)
 *   unset / "" / "0" -> dormant;  anything else -> dormant AND `unknown:true` (fail closed, logged).
 */
function globalMode(env) {
    const raw = clean((env || {}).FLEET_CI_DISPATCHER);
    if (raw === '1') return { mode: 'live', unknown: false, raw };
    if (raw.toLowerCase() === 'shadow') return { mode: 'shadow', unknown: false, raw };
    return { mode: 'dormant', unknown: !(raw === '' || raw === '0'), raw };
}

/** Why the dispatcher is dormant, or null when it may run. Never includes a secret. */
function dormantReason(env) {
    const e = env || {};
    const g = globalMode(e);
    if (g.unknown) return `FLEET_CI_DISPATCHER has unknown mode "${g.raw.slice(0, 20)}" (expected "1" or "shadow"); staying dormant`;
    if (g.mode === 'dormant') return 'FLEET_CI_DISPATCHER is not "1" or "shadow"';
    if (!hasCredentials(e)) return 'GitHub App credentials are not configured (need GITHUB_APP_CLIENT_ID or GITHUB_APP_ID, and GITHUB_APP_PRIVATE_KEY)';
    return null;
}

/**
 * @param {object} deps
 * @param {object}   deps.env          process.env-like (only FLEET_CI_DISPATCHER, creds presence, FLY_MACHINE_ID are read)
 * @param {object}   deps.store        ci-pool-store
 * @param {object}   deps.assignments  ci-dispatch-assignments
 * @param {object}   deps.alerts       ci-dispatch-alerts
 * @param {object}   [deps.audit]      {append}
 * @param {object}   [deps.github]     only checked for presence; the dispatcher itself makes no direct GitHub call
 * @param {object}   [deps.watcher]    {runCycle(), stop?()}   (tests)
 * @param {Function} [deps.createWatcher] ({allowlist, getAllowlist, onJob, log}) => watcher   (production: built at start(); getAllowlist is read every cycle)
 * @param {object}   [deps.policy]     defaults to ci-dispatch-policy
 * @param {object}   [deps.placement]  defaults to ci-dispatch-placement
 * @param {Map}      [deps.reports]    machine -> report; shared with the routes
 * @param {number}   [deps.maxMintsPerJob]  ghost backstop: runners that expired unpicked for one job (default MAX_MINTS_PER_JOB)
 * @param {number}   [deps.maxTrackedMs]    ghost backstop (default MAX_TRACKED_MS)
 * @param {string}   [deps.shadowLogPath] decision-record file (env FLEET_CI_SHADOW_LOG wins); none = no records written
 * @param {Function} [deps.now]
 * @param {Function} [deps.setTimer]   (fn, ms) => handle
 * @param {Function} [deps.clearTimer]
 * @param {object}   [deps.logger]
 */
function createDispatcher(deps) {
    const d = deps || {};
    const env = d.env || {};
    const store = d.store;
    const assignments = d.assignments;
    const alerts = d.alerts;
    if (!store || !assignments || !alerts) throw new TypeError('createDispatcher: store, assignments and alerts are required');
    if (!d.watcher && typeof d.createWatcher !== 'function') throw new TypeError('createDispatcher: watcher or createWatcher is required');
    const pol = d.policy || policy;
    const plc = d.placement || placement;
    const audit = d.audit || null;
    const reports = d.reports || new Map();
    const now = typeof d.now === 'function' ? d.now : Date.now;
    const setTimer = d.setTimer || ((fn, ms) => { const h = setTimeout(fn, ms); if (h && h.unref) h.unref(); return h; });
    const clearTimer = d.clearTimer || clearTimeout;
    const log = d.logger || console;
    const maxMintsPerJob = Number.isInteger(d.maxMintsPerJob) && d.maxMintsPerJob > 0 ? d.maxMintsPerJob : MAX_MINTS_PER_JOB;
    const maxTrackedMs = Number.isFinite(d.maxTrackedMs) && d.maxTrackedMs > 0 ? d.maxTrackedMs : MAX_TRACKED_MS;

    const say = (level, msg) => {
        const fn = log[level] || log.log;
        if (typeof fn === 'function') { try { fn.call(log, `[CI-DISPATCH] ${msg}`); } catch (_) { /* logging never throws */ } }
    };
    const writeAudit = (event, fields) => {
        if (!audit || typeof audit.append !== 'function') return;
        try { audit.append(event, fields); } catch (_) { /* audit never throws into the loop */ }
    };

    let watcher = d.watcher || null;
    let timer = null;
    let started = false;
    let stopped = false;
    let ticking = null;
    let tickFailures = 0;
    let mintFailures = 0;
    let lastTickAt = null;
    let notPoolSkipped = 0;

    /** key -> {rec, noCapSince|null, trackedAt}: policy-accepted, still-queued, unbound jobs. */
    const tracked = new Map();
    /** key -> rec: still-queued jobs rejected for a config-dependent reason (bounded; insertion order = age). */
    const configRejected = new Map();
    /** keys already audited as rejected (one row per job, not per tick). */
    const rejected = new Set();

    const isEnabled = () => dormantReason(env) === null;
    /** 'dormant' | 'shadow' | 'live' from the global switch (read live, so tests/operators can flip env). */
    const effectiveMode = () => (isEnabled() ? globalMode(env).mode : 'dormant');
    /**
     * Effective mode for ONE host. Anything but a global 'live' AND a host mode of absent/'live' is
     * 'shadow' (never mints): an unknown per-host value fails closed to shadow, never to live.
     */
    const machineMode = (m, viaHostLabel) => {
        if (effectiveMode() !== 'live') return 'shadow';
        const v = m && m.mode;
        // XACA-1445-014: a job accepted ONLY through its host label (no pool label) is served by the
        // persistent runners today; it may mint solely where mode:'live' is set EXPLICITLY (absent = shadow).
        if (viaHostLabel === true) return v === 'live' ? 'live' : 'shadow';
        return v === undefined || v === 'live' ? 'live' : 'shadow';
    };
    /** The pool machine a static-label job is pinned to (its host label), or null. */
    const pinnedMachineOf = (rec, machines) => {
        const jl = plc.normalizeLabels(rec.labels) || [];
        const id = Object.keys(machines).find((k) => jl.includes(plc.hostLabelOf(Object.assign({ id: k }, machines[k]))));
        return id === undefined ? null : machines[id];
    };

    // ------------------------------------------------------- decision records
    /** job ids already recorded (insertion order = age), primed from the log tail once. */
    const decided = new Set();
    let decidedPrimed = false;
    let decisionsRecorded = 0;
    let decisionWriteFailures = 0;
    const shadowLogFile = () => clean(env.FLEET_CI_SHADOW_LOG) || clean(d.shadowLogPath) || null;

    function markDecided(id) {
        decided.add(id);
        while (decided.size > MAX_DECIDED_IDS) decided.delete(decided.values().next().value);
    }

    /** Best effort: re-learn recorded job ids from the log tail so a restart does not duplicate them. */
    function primeDecided(file) {
        decidedPrimed = true;
        let fd = null;
        try {
            fd = fs.openSync(file, 'r');
            const size = fs.fstatSync(fd).size;
            const len = Math.min(size, SHADOW_LOG_PRIME_BYTES);
            if (len <= 0) return;
            const buf = Buffer.alloc(len);
            fs.readSync(fd, buf, 0, len, size - len);
            const lines = buf.toString('utf8').split('\n');
            if (size > len) lines.shift(); // first line may be cut off
            for (const ln of lines) {
                if (!ln) continue;
                try { const o = JSON.parse(ln); if (Number.isInteger(o.job_id)) markDecided(o.job_id); } catch (_) { /* partial/foreign line */ }
            }
        } catch (_) { /* no log yet is the normal case */ } finally {
            if (fd !== null) { try { fs.closeSync(fd); } catch (_) { /* nothing */ } }
        }
    }

    const pcfgFor = (cfg) => ({ now: now(), thresholds: cfg.thresholds, jobClasses: cfg.jobClasses, poolLabel: cfg.poolLabel });

    const OFFLINE_REASONS = ['no-report', 'stale-poll', 'no-last-poll', 'poll-in-future', 'no-clock'];
    /** Per-host snapshot the decision was made from (D2 contract). Never carries a secret. */
    function capacityOf(machines, adjusted, evals, rec) {
        const out = {};
        const osName = plc.jobOs(rec);
        for (const e of evals) {
            const m = machines[e.id] || {};
            const r = adjusted[e.id];
            const slotList = r && Array.isArray(r.slots) ? r.slots : [];
            out[e.id] = {
                online: !e.reasons.some((x) => OFFLINE_REASONS.includes(x)),
                enabled: m.enabled === true,
                paused: m.paused !== false,
                free_slots: slotList.filter((sl) => sl && sl.state === 'idle' && (osName === null || sl.os === osName)).length,
                reason: e.reasons.length ? e.reasons.join(',') : null,
            };
        }
        return out;
    }

    /** First eligible host -> placed/pinned; otherwise host-paused (a pinned host is paused) or no-capacity. */
    function decisionFrom(rec, evals, machines) {
        const jl = plc.normalizeLabels(rec.labels) || [];
        const hostLabel = (id) => plc.hostLabelOf(Object.assign({ id }, machines[id]));
        const top = evals.find((e) => e.eligible);
        if (top) {
            const hl = hostLabel(top.id);
            return { host: top.id, reason: hl && jl.includes(hl) ? `pinned:${top.id}` : 'placed' };
        }
        for (const e of evals) {
            const hl = hostLabel(e.id);
            if (hl && jl.includes(hl) && e.reasons.includes('paused')) return { host: null, reason: 'host-paused' };
        }
        return { host: null, reason: 'no-capacity' };
    }

    /** Append one record, once per job id. Never throws; a write error is logged, not raised. */
    function appendDecision(rec, decision, capacity, mode) {
        try {
            if (!Number.isInteger(rec.jobId) || effectiveMode() === 'dormant') return;
            const file = shadowLogFile();
            if (!file) return;
            if (!decidedPrimed) primeDecided(file);
            if (decided.has(rec.jobId)) return;
            markDecided(rec.jobId);
            const line = JSON.stringify({
                ts: new Date(now()).toISOString(),
                job_id: rec.jobId,
                run_id: Number.isInteger(rec.runId) ? rec.runId : 0,
                labels: Array.isArray(rec.labels) ? rec.labels.map((l) => String(l)) : [],
                mode,
                decision: { host: decision.host, reason: decision.reason },
                capacity,
            }) + '\n';
            try {
                fs.mkdirSync(path.dirname(file), { recursive: true });
                fs.appendFileSync(file, line, { mode: 0o600 });   // single write of line + "\n"
                decisionsRecorded++;
            } catch (e) {
                decisionWriteFailures++;
                if (decisionWriteFailures === 1 || decisionWriteFailures % 50 === 0) {
                    say('error', `decision record not written (${clean((e && e.code) || (e && e.message)).slice(0, 80)}); ${decisionWriteFailures} failure(s)`);
                }
            }
        } catch (e) {
            say('error', `decision record failed (${clean(e && e.message).slice(0, 120)})`);
        }
    }

    /** A job policy refused: record host:null + the policy reason (once per job id). */
    function recordRejected(rec, reason) {
        try {
            if (!shadowLogFile() || effectiveMode() === 'dormant') return;
            const cfg = store.getConfig();
            const machines = store.listMachines();
            const base = reportsObject();
            const evals = plc.evaluateMachines(machines, base, rec, pcfgFor(cfg));
            appendDecision(rec, { host: null, reason: reason === 'label:not-pool' ? 'not-pool' : reason }, capacityOf(machines, base, evals, rec), effectiveMode());
        } catch (e) {
            say('error', `decision record failed (${clean(e && e.message).slice(0, 120)})`);
        }
    }

    /**
     * A policy-accepted job: record the placement decision exactly as live would make it, against
     * the capacity left after earlier decisions in this tick (`decRes`, a copy of the reservations).
     */
    function recordPlacement(rec, machines, base, decRes, pcfg, covered, viaHostLabel) {
        try {
            if (!shadowLogFile() || decided.has(rec.jobId) || effectiveMode() === 'dormant') return;
            const adjusted = withReservations(base, decRes);
            const evals = plc.evaluateMachines(machines, adjusted, rec, pcfg);
            const decision = decisionFrom(rec, evals, machines);
            const mode = decision.host ? machineMode(machines[decision.host], viaHostLabel)
                : (viaHostLabel === true ? machineMode(pinnedMachineOf(rec, machines), true) : effectiveMode());
            appendDecision(rec, decision, capacityOf(machines, adjusted, evals, rec), mode);
            const osName = plc.jobOs(rec);
            if (decision.host && osName && !covered) decRes.set(`${decision.host}|${osName}`, (decRes.get(`${decision.host}|${osName}`) || 0) + 1);
        } catch (e) {
            say('error', `decision record failed (${clean(e && e.message).slice(0, 120)})`);
        }
    }

    // ---------------------------------------------------------------- events
    function evaluate(rec) {
        const cfg = store.getConfig();
        const machines = store.listMachines();
        const hostLabels = Object.keys(machines).map((id) => plc.hostLabelOf(Object.assign({ id }, machines[id]))).filter(Boolean);
        const v = pol.evaluateJob(rec, { allowlist: cfg.allowlist, poolLabel: cfg.poolLabel, hostLabels });
        if (v.accept) {
            configRejected.delete(rec.key);
            rejected.delete(rec.key); // a later re-rejection is a new decision and is audited again
            const viaHostLabel = v.viaHostLabel === true;
            const existing = tracked.get(rec.key);
            if (existing) existing.viaHostLabel = viaHostLabel;   // a config change can flip the acceptance path
            else tracked.set(rec.key, { rec, noCapSince: null, trackedAt: now(), viaHostLabel });
            return;
        }

        tracked.delete(rec.key);
        recordRejected(rec, v.reason);
        if (CONFIG_DEPENDENT_REASONS.includes(v.reason)) {
            configRejected.delete(rec.key); // refresh its age
            configRejected.set(rec.key, rec);
            while (configRejected.size > MAX_CONFIG_REJECTED) configRejected.delete(configRejected.keys().next().value);
        } else {
            configRejected.delete(rec.key);
        }
        if (v.reason === 'label:not-pool') { if (!rejected.has(rec.key)) { rejected.add(rec.key); notPoolSkipped++; } return; } // not addressed to the pool: not ours, not audit noise (counted once per job)
        if (!rejected.has(rec.key)) {
            rejected.add(rec.key);
            writeAudit('reject', {
                repo: `${rec.owner}/${rec.repo}`, jobId: rec.jobId, runAttempt: rec.runAttempt, runId: rec.runId,
                jobName: rec.name, runEvent: rec.run && rec.run.event, reason: v.reason,
            });
        }
        if (v.alert) {
            alerts.raise('ci-fork-job-on-pool', {
                severity: 'warning',
                title: `Fork-origin job targets the CI pool label in ${rec.owner}/${rec.repo}`,
                body: `A job that comes from, or cannot be proven not to come from, a fork carries the pool label and was rejected (${v.reason}). This is a workflow misconfiguration: pool runners must never take fork code, and workflow_run jobs cannot target the pool.`,
                ref: `${rec.owner}/${rec.repo}`,
            });
        }
        if (v.reason === 'label:ambiguous') {
            // XACA-1441-031: a pool job no single runner can satisfy. A misconfiguration to fix in the
            // workflow, not a capacity outage: it never reaches the no-capacity timer.
            alerts.raise('ci-job-misconfigured', {
                severity: 'warning',
                title: `CI pool job has ambiguous runner labels in ${rec.owner}/${rec.repo}`,
                body: `Job "${clean(rec.name).slice(0, 80)}" targets the pool but must carry exactly one OS label (Linux or macOS) and at most one host label. Its labels: ${rec.labels.map((l) => clean(l).slice(0, 40)).join(', ').slice(0, 300)}. It will not be dispatched until the workflow is fixed.`,
                ref: `${rec.owner}/${rec.repo}`,
            });
        }
    }

    /**
     * XACA-1441-029: the operator changed the allowlist, pool label or a host label. Re-run policy on
     * every remembered config-rejected job (one that now passes becomes tracked demand) and on every
     * tracked job (one that no longer passes, e.g. its repo was removed, stops being dispatched).
     * Never throws. Fork-rejected jobs are not remembered, so they can never be promoted here.
     * @returns {{promoted:number, dropped:number}}
     */
    function onConfigChanged() {
        const out = { promoted: 0, dropped: 0 };
        try {
            for (const rec of [...configRejected.values()]) {
                evaluate(rec);
                if (tracked.has(rec.key)) out.promoted++;
            }
            for (const t of [...tracked.values()]) {
                evaluate(t.rec);
                if (!tracked.has(t.rec.key)) out.dropped++;
            }
        } catch (e) {
            say('error', `onConfigChanged failed (${clean(e && e.message).slice(0, 120)})`);
        }
        if (out.promoted || out.dropped) say('log', `config change: ${out.promoted} job(s) now eligible, ${out.dropped} no longer eligible`);
        return out;
    }

    /**
     * XACA-1444 PR #1101 r1: pool jobs a runner has picked up (JIT or PERSISTENT), until they complete.
     * The queue view's running rows came only from JIT assignments, so a job taken by a persistent runner
     * vanished the moment it left `tracked`. Bounded; oldest evicted first.
     */
    const running = new Map();   // job key -> {rec, since}
    const MAX_RUNNING = 500;
    function policyAccepts(rec) {
        const cfg = store.getConfig();
        const machines = store.listMachines();
        const hostLabels = Object.keys(machines).map((id) => plc.hostLabelOf(Object.assign({ id }, machines[id]))).filter(Boolean);
        return pol.evaluateJob(rec, { allowlist: cfg.allowlist, poolLabel: cfg.poolLabel, hostLabels }).accept === true;
    }

    /** Watcher callback. Must never throw into the watcher. */
    function onJob(rec, change) {
        try {
            if (!rec || typeof rec.key !== 'string') return;
            if (change === 'queued' || change === 'seen') {
                if (rec.status === 'queued' && !rec.runnerName) evaluate(rec);
            } else if (change === 'pickup' || change === 'in_progress') {
                const wasPool = tracked.has(rec.key) || running.has(rec.key);
                tracked.delete(rec.key);
                configRejected.delete(rec.key);
                assignments.bindJob(rec, change);
                if (wasPool || policyAccepts(rec)) {
                    const prior = running.get(rec.key);
                    running.delete(rec.key);
                    running.set(rec.key, { rec, since: prior ? prior.since : now() });
                    while (running.size > MAX_RUNNING) running.delete(running.keys().next().value);
                }
            } else if (change === 'priority') {
                // XACA-1479-005: TTL refresh of a still-queued job's resolved priority.
                const t = tracked.get(rec.key);
                if (t) t.rec.priority = rec.priority;
                const c = configRejected.get(rec.key);
                if (c) c.priority = rec.priority;
            } else if (change === 'completed') {
                tracked.delete(rec.key);
                running.delete(rec.key);
                configRejected.delete(rec.key);
                rejected.delete(rec.key);
            }
        } catch (e) {
            say('error', `onJob failed (${clean(e && e.message).slice(0, 120)})`);
        }
    }

    function onDegraded(info) {
        const i = info || {};
        alerts.raise('ci-dispatcher-degraded', {
            severity: 'warning',
            title: 'CI dispatcher suspended polling: GitHub rate limit nearly exhausted',
            body: `remaining=${i.remaining} limit=${i.limit} resetAt=${i.resetAt ? new Date(i.resetAt).toISOString() : 'unknown'}. Polling resumes at reset.`,
            ref: 'github-rate-limit',
        });
    }

    // ---------------------------------------------------------------- decide
    function reportsObject() {
        const o = {};
        for (const [id, r] of reports) o[id] = r;
        return o;
    }

    /** Copy of the reports with `reserved` idle slots flipped to state 'reserved'. */
    function withReservations(base, reserved) {
        const out = {};
        for (const id of Object.keys(base)) {
            const r = base[id];
            const slots = r && Array.isArray(r.slots) ? r.slots : null;
            if (!slots) { out[id] = r; continue; }
            const left = { Linux: reserved.get(`${id}|Linux`) || 0, macOS: reserved.get(`${id}|macOS`) || 0 };
            out[id] = Object.assign({}, r, {
                slots: slots.map((s) => {
                    if (s && s.state === 'idle' && left[s.os] > 0) { left[s.os]--; return Object.assign({}, s, { state: 'reserved' }); }
                    return s;
                }),
            });
        }
        return out;
    }

    function reasonsText(evals) {
        if (!evals.length) return 'no machines registered';
        return evals.map((e) => `${e.id}: ${e.reasons.join(',') || 'eligible'}`).join('; ');
    }

    async function decide() {
        const cfg = store.getConfig();
        const machines = store.listMachines();
        const nowMs = now();
        const pcfg = { now: nowMs, thresholds: cfg.thresholds, jobClasses: cfg.jobClasses, poolLabel: cfg.poolLabel };
        const base = reportsObject();

        // Slots promised to runners whose listener has not started yet.
        const reserved = new Map();
        // XACA-1441-033: per job id, runners minted FOR it that ended without ever binding a job.
        // A runner that bound a different job (label contention) did work, so it is not counted;
        // a restart-expiry says nothing about the job either.
        const unpicked = new Map();
        for (const a of assignments.snapshot()) {
            if (a.state === 'pending' || a.state === 'delivered') {
                const k = `${a.machine}|${a.os}`;
                reserved.set(k, (reserved.get(k) || 0) + 1);
            }
            if ((a.state === 'expired' || a.state === 'cancelled' || a.state === 'failed') && !a.boundJob &&
                a.reason !== 'restart' && a.intendedJob && a.intendedJob.id !== null) {
                if (!unpicked.has(a.intendedJob.id)) unpicked.set(a.intendedJob.id, []);
                unpicked.get(a.intendedJob.id).push(a.id);
            }
        }

        // Ghost backstop: retire tracked jobs that can no longer be real demand.
        // The unpicked runners are ACCUMULATED on the tracked entry (by assignment id), not re-derived
        // from the snapshot each tick: terminal assignment records are pruned (24 h / 500), so under
        // churn a snapshot-only count could fall back below the bound and never retire a ghost
        // (PR #1086 review advisory).
        for (const [key, t] of tracked) {
            if (!t.unpickedIds) t.unpickedIds = new Set();
            for (const id of unpicked.get(t.rec.jobId) || []) t.unpickedIds.add(id);
            const n = t.unpickedIds.size;
            const why = n >= maxMintsPerJob ? `${n} runners expired unpicked`
                : (nowMs - t.trackedAt > maxTrackedMs ? `tracked over ${Math.round(maxTrackedMs / 3600000)} h` : null);
            if (!why) continue;
            tracked.delete(key);
            writeAudit('expire', { repo: `${t.rec.owner}/${t.rec.repo}`, jobId: t.rec.jobId, runAttempt: t.rec.runAttempt, state: 'tracked', reason: `ghost-bound: ${why}` });
            say('warn', `stopped dispatching job ${t.rec.jobId} (${why})`);
            // XACA-1445-017: a host-label-only job on a non-live host was never being dispatched (the
            // persistent runners serve it), so dropping it is not a degradation: no alert.
            if (t.viaHostLabel === true && machineMode(pinnedMachineOf(t.rec, machines), true) !== 'live') continue;
            alerts.raise('ci-dispatcher-degraded', {
                severity: 'warning',
                title: `CI dispatcher stopped dispatching a job in ${t.rec.owner}/${t.rec.repo}`,
                body: `Job "${clean(t.rec.name).slice(0, 80)}" (${t.rec.jobId}): ${why}. If the job is still queued on GitHub, check the machine agents; it will not be re-dispatched.`,
                ref: `ghost:${key}`,
            });
        }

        const byFifo = (a, b) => (a.rec.firstSeenAt < b.rec.firstSeenAt ? -1 : a.rec.firstSeenAt > b.rec.firstSeenAt ? 1 : 0);
        const fifo = [...tracked.values()].sort(byFifo);
        // XACA-1479-006: dispatch order is priority rank (critical > high > normal; missing/unknown =
        // normal), then the existing firstSeenAt FIFO. Array#sort is stable, so an all-normal queue keeps
        // exactly the pre-1479 order.
        const jobs = fifo.slice().sort((a, b) => (priorityRank(a.rec) - priorityRank(b.rec)) || byFifo(a, b));
        const outstanding = assignments.outstandingBySet();
        // The oldest `outstanding` jobs of a label-set are COVERED: runners already exist for them
        // (pending/delivered/started, not yet bound), so they are neither a no-capacity signal nor new demand.
        const coverage = new Map();
        for (const [raw, n] of outstanding) {
            const ck = plc.labelSetKey(String(raw).split(','));
            coverage.set(ck, (coverage.get(ck) || 0) + n);
        }
        // XACA-1479-006: coverage is attributed in FIFO order (those runners were minted for the OLDER
        // jobs), not in priority order. A newly-arrived priority job is therefore uncovered and gets a
        // runner of its own this tick, first in the mint loop, while the count of covered jobs per set
        // is unchanged from before.
        const coveredKeys = new Set();
        {
            const left = new Map(coverage);
            for (const t of fifo) {
                const sk = plc.labelSetKey(t.rec.labels);
                if ((left.get(sk) || 0) > 0) { left.set(sk, left.get(sk) - 1); coveredKeys.add(t.rec.key); }
            }
        }
        const globalShadow = effectiveMode() !== 'live';
        const decRes = new Map(reserved);   // reservations as the decision records see them (shadow decisions consume capacity too)
        const demand = [];   // covered + needing: what computeSupply sees
        const needing = [];  // uncovered jobs that have an eligible machine: where new mints go
        let adjusted = withReservations(base, reserved);
        for (const t of jobs) {
            const setKey = plc.labelSetKey(t.rec.labels);
            const isCovered = coveredKeys.has(t.rec.key);
            recordPlacement(t.rec, machines, base, decRes, pcfg, isCovered, t.viaHostLabel === true);
            if (isCovered) {
                t.noCapSince = null; demand.push(t.rec);
                continue;
            }
            const evals = plc.evaluateMachines(machines, adjusted, t.rec, pcfg);
            const via = t.viaHostLabel === true;
            // A job accepted ONLY through its static host label whose pinned host is not explicitly live
            // is the designed exception (014): recorded above, NOT demand, NO alert (the persistent
            // runners serve it).
            if (via && machineMode(pinnedMachineOf(t.rec, machines), true) !== 'live') { t.noCapSince = null; continue; }
            // Placement for minting/demand considers LIVE hosts only (XACA-1445-015): a shadow host that
            // ranks first must not strand a job a live host could take. The decision RECORD above still
            // uses the all-host ranking (that is the shadow comparison).
            const top = evals.find((e) => e.eligible && machineMode(machines[e.id], via) === 'live');
            if (top) { t.noCapSince = null; demand.push(t.rec); needing.push(t.rec); continue; }
            if (t.noCapSince === null) t.noCapSince = nowMs;
            if (globalShadow) continue;   // shadow raises no operational alerts: the persistent runners still serve the job
            const waited = nowMs - t.noCapSince;
            if (waited >= NO_CAPACITY_AFTER_MS) {
                const cls = plc.jobClass(t.rec.name, cfg.jobClasses);
                const res = alerts.raise('ci-no-capacity', {
                    severity: 'high',
                    title: `No CI pool capacity for ${cls} jobs (${t.rec.owner}/${t.rec.repo})`,
                    body: `Job "${clean(t.rec.name).slice(0, 80)}" has waited ${Math.round(waited / 1000)}s with no eligible machine. ${reasonsText(evals)}`,
                    ref: `class:${cls}`,
                });
                if (res.raised) {
                    writeAudit('alert', { repo: `${t.rec.owner}/${t.rec.repo}`, jobId: t.rec.jobId, runAttempt: t.rec.runAttempt, jobName: t.rec.name, jobClass: cls, waitedMs: waited, reason: 'ci-no-capacity' });
                }
            }
        }

        // XACA-1444-011: queue-AGE alert. Independent of the no-capacity path above, because that path
        // only fires when NO machine is eligible; on 2026-10-07 44 jobs sat ~32 min on `fleet-pool,m1mini`
        // while one JIT runner was busy and two persistent runners idled, so "capacity" existed and
        // nothing fired. Fires in shadow too: queue wait is a fact about GitHub, not about our mints.
        raiseQueueAgeAlerts(nowMs);

        const supply = plc.computeSupply(demand, outstanding);
        // XACA-1479-006 SURGE. For a label set holding a priority job P, target = P's 1-based position in
        // the set's FIFO order (every job GitHub would likely hand a runner to first, plus P), taking the
        // NEWEST priority job when there are several. The set's mint budget is raised to cover every
        // UNCOVERED job inside that window (covered ones already have a runner). Capacity is NOT raised:
        // each mint below still needs a free, unreserved, live slot from rankCandidates, so a short cap
        // mints up to the cap and stops. Nothing running is cancelled or preempted.
        // NOTE (measured by mutation, 2026-10-09): with today's computeSupply (mint = queued - outstanding,
        // queued counting every demand job) the floor never binds -- the baseline already budgets one
        // runner per uncovered job. It is kept as an explicit invariant so a future per-set mint limit
        // cannot silently shrink a priority window. What surge changes in practice is WHICH runner goes
        // first (priority order, across sets), coverage attribution (FIFO, so P gets its own runner) and
        // the 'surge' audit trail.
        const inDemand = new Set(demand);
        const surge = surgePlan(fifo.filter((t) => inDemand.has(t.rec)).map((t) => t.rec), coveredKeys, plc.labelSetKey);
        const budget = new Map();
        for (const s of supply) budget.set(s.key, s.mint);
        for (const [sk, sg] of surge) budget.set(sk, Math.max(budget.get(sk) || 0, sg.uncoveredInWindow));
        const stats = { minted: 0, failed: 0, surged: 0 };
        const stoppedSets = new Set();   // a set whose mint loop stopped this tick (no capacity / bad labels / mint failure)
        // Mint in dispatch order (priority, then FIFO) ACROSS sets, so a priority set is not starved of a
        // shared host's slots by an alphabetically earlier normal set.
        for (const job of needing) {
            const sk = plc.labelSetKey(job.labels);
            if (stoppedSets.has(sk) || !((budget.get(sk) || 0) > 0)) continue;
            {
                adjusted = withReservations(base, reserved);
                const jobVia = !!(tracked.get(job.key) && tracked.get(job.key).viaHostLabel);
                const ranked = plc.rankCandidates(machines, adjusted, job, pcfg).filter((r) => machineMode(machines[r.id], jobVia) === 'live');
                if (!ranked.length) { stoppedSets.add(sk); continue; } // capacity ran out mid-tick; the next tick re-evaluates
                const id = ranked[0].id;
                if (machineMode(machines[id], jobVia) !== 'live') continue;   // last line of defence: shadow never mints
                const mrec = Object.assign({ id }, machines[id]);
                const labels = plc.mintLabels(job, mrec, pcfg);
                const os = plc.jobOs(job);
                if (!labels || !os) { say('warn', `skip mint for job ${job.jobId}: no valid label set`); stoppedSets.add(sk); continue; }
                const r = await assignments.mint({ job, machine: id, labels, os });
                if (r && r.ok) {
                    stats.minted++; mintFailures = 0;
                    budget.set(sk, budget.get(sk) - 1);
                    reserved.set(`${id}|${os}`, (reserved.get(`${id}|${os}`) || 0) + 1);
                    const sg = surge.get(sk);
                    if (sg && sg.windowKeys.has(job.key)) {
                        stats.surged++;
                        writeAudit('surge', {
                            repo: `${job.owner}/${job.repo}`, jobId: job.jobId, runAttempt: job.runAttempt, runId: job.runId,
                            machine: id, runnerId: r.assignment && r.assignment.runnerId, labelSet: sk,
                            priority: sg.priority, ahead: sg.target - 1, target: sg.target, forJobId: sg.forJobId,
                            reason: job.key === sg.forKey ? 'surge:priority-job' : 'surge:job-ahead',
                        });
                    }
                } else {
                    stats.failed++; mintFailures++;
                    if (mintFailures >= MINT_FAIL_ALERT_AFTER) {
                        alerts.raise('ci-dispatcher-degraded', {
                            severity: 'warning',
                            title: 'CI dispatcher cannot mint runners',
                            body: `${mintFailures} consecutive mint failures (last: ${clean(r && (r.code || r.reason)).slice(0, 60) || 'unknown'}). Check the GitHub App permissions and installation.`,
                            ref: 'mint-failures',
                        });
                    }
                    stoppedSets.add(sk); continue; // do not hammer GitHub within one tick (this set stops, as before)
                }
            }
        }
        return stats;
    }

    // ------------------------------------------------------- queue age (XACA-1444-011)
    const queueAgeThresholdMs = () => derive.queueAgeThresholdMs(env);
    /** Pool machine id whose host label the job's labels name, or null. */
    function hostOfLabels(labels) {
        const jl = plc.normalizeLabels(labels) || [];
        const machines = store.listMachines();
        const id = Object.keys(machines).find((k) => jl.includes(plc.hostLabelOf(Object.assign({ id: k }, machines[k]))));
        return id === undefined ? null : id;
    }
    function queueAgeView(nowMs) {
        if (!isEnabled()) return [];   // dormant: nothing is polled, so a stray tracked job is not a real queue
        const jobs = [...tracked.values()].map((t) => t.rec);
        return derive.computeQueueAge(jobs, nowMs, queueAgeThresholdMs(), hostOfLabels, plc.labelSetKey);
    }
    /** Label-set keys currently over threshold, so a clear is logged once on the way out. */
    const queueAlerting = new Set();
    function raiseQueueAgeAlerts(nowMs) {
        const over = new Map(queueAgeView(nowMs).filter((g) => g.overThreshold).map((g) => [g.labels, g]));
        for (const [setKey, g] of over) {
            const res = alerts.raise('ci-queue-age', {
                severity: 'high',
                title: `CI jobs queued ${Math.round(g.oldestWaitSec / 60)} min on ${g.labels}`,
                body: `${g.depth} job(s) queued on ${g.labels}${g.host ? ` (host ${g.host})` : ''}; oldest has waited ${g.oldestWaitSec}s (threshold ${Math.round(queueAgeThresholdMs() / 1000)}s). Runners may be busy, mis-labelled or offline; check the CI/CD tab.`,
                ref: `queue:${setKey}`,
            });
            if (res.raised) writeAudit('alert', { machine: g.host, waitedMs: g.oldestWaitSec * 1000, reason: 'ci-queue-age' });
            queueAlerting.add(setKey);
        }
        for (const setKey of [...queueAlerting]) {
            if (!over.has(setKey)) { queueAlerting.delete(setKey); say('log', `queue-age alert cleared for ${setKey}`); }
        }
    }
    const queueAge = () => queueAgeView(now());
    /**
     * noCapSince only counts once it is alertable: live mode and waited >= NO_CAPACITY_AFTER_MS. In
     * shadow the persistent runners still serve the job, so a bare "no live host" is not an outage.
     */
    /** The ONE gate for "no machine can take this job": live mode and waited >= NO_CAPACITY_AFTER_MS.
     *  Used by noCapacity() AND queue()[].noEligibleMachine so the server summary and the per-job flag cannot disagree. */
    function alertableNoCapSince(t, nowMs, live) {
        return live && t.noCapSince !== null && nowMs - t.noCapSince >= NO_CAPACITY_AFTER_MS ? t.noCapSince : null;
    }
    function noCapacity() {
        const nowMs = now();
        if (!isEnabled()) return derive.computeNoCapacity([], [], 0, plc.labelSetKey);
        const live = effectiveMode() === 'live';
        const jobs = [...tracked.values()].map((t) => ({
            rec: t.rec,
            noCapSince: alertableNoCapSince(t, nowMs, live),
        }));
        return derive.computeNoCapacity(jobs, queueAgeView(nowMs), queueAgeThresholdMs(), plc.labelSetKey);
    }

    // ------------------------------------------------------------------ tick
    /** One full cycle. Resolves to the delay (ms) until the next one, or null when dormant. Never throws. */
    function tick() {
        if (ticking) return ticking;
        if (!isEnabled() || stopped) return Promise.resolve(null);
        ticking = (async () => {
            let delay = FALLBACK_DELAY_MS;
            try {
                try { await assignments.sweep(); } catch (e) { say('warn', `sweep failed (${clean(e && e.message).slice(0, 120)})`); }
                const d2 = await watcher.runCycle();
                if (Number.isFinite(d2) && d2 > 0) delay = d2;
                await decide();
                lastTickAt = new Date(now()).toISOString();
                tickFailures = 0;
            } catch (e) {
                tickFailures++;
                say('error', `tick failed (${clean(e && e.message).slice(0, 120)})`);
                if (tickFailures >= TICK_FAIL_ALERT_AFTER) {
                    alerts.raise('ci-dispatcher-degraded', {
                        severity: 'warning',
                        title: 'CI dispatcher loop is failing',
                        body: `${tickFailures} consecutive tick failures; see the server log.`,
                        ref: 'tick-failed',
                    });
                }
            } finally { ticking = null; }
            return delay;
        })();
        return ticking;
    }

    function schedule(ms) {
        if (!started || stopped) return;
        timer = setTimer(async () => {
            timer = null;
            const delay = await tick();
            schedule(delay === null ? FALLBACK_DELAY_MS : delay);
        }, ms);
    }

    function start() {
        if (started) return true;
        const why = dormantReason(env);
        if (why !== null) { say(globalMode(env).unknown ? 'warn' : 'log', `dispatcher dormant: ${why}`); return false; }
        started = true; stopped = false;
        if (!watcher) {
            watcher = d.createWatcher({
                allowlist: store.getConfig().allowlist,
                getAllowlist: () => store.getConfig().allowlist,
                onJob,
                log: (level, msg) => say(level === 'error' ? 'error' : level === 'warn' ? 'warn' : 'log', msg),
            });
        }
        say('log', `dispatcher ENABLED in ${effectiveMode().toUpperCase()} mode${effectiveMode() === 'shadow' ? ' (decides and records, mints nothing)' : ''} (single instance; fly machine ${clean(env.FLY_MACHINE_ID) || 'n/a'}; allowlist changes apply live)`);
        schedule(0);
        return true;
    }

    function stop() {
        stopped = true; started = false;
        if (timer !== null) { clearTimer(timer); timer = null; }
        if (watcher && typeof watcher.stop === 'function') { try { watcher.stop(); } catch (_) { /* best effort */ } }
    }

    // ----------------------------------------------------------------- views
    function queue() {
        const cfg = store.getConfig();
        const nowMs = now();
        // XACA-1444: the machine an outstanding (non-terminal) assignment is held for / bound to this job.
        const live = assignments.snapshot().filter((a) => !['completed', 'failed', 'expired', 'cancelled', 'lost'].includes(a.state));
        const machineFor = (rec) => {
            const repo = `${rec.owner}/${rec.repo}`.toLowerCase();
            const hit = live.find((a) => String(a.repo).toLowerCase() === repo &&
                ((a.boundJob ? a.boundJob.id : (a.intendedJob ? a.intendedJob.id : null)) === rec.jobId));
            return hit ? hit.machine : null;
        };
        const liveMode = effectiveMode() === 'live';
        return [...tracked.values()].map((t) => ({
            key: t.rec.key,
            repo: `${t.rec.owner}/${t.rec.repo}`,
            jobId: t.rec.jobId,
            name: t.rec.name,
            jobClass: plc.jobClass(t.rec.name, cfg.jobClasses),
            waitingMs: Math.max(0, nowMs - Date.parse(t.rec.firstSeenAt)),
            noCapacityMs: t.noCapSince === null ? 0 : nowMs - t.noCapSince,
            // XACA-1444 PR #1101 r1 (additive): true only when noCapacity() would count this job as having no
            // eligible machine (live mode AND >= NO_CAPACITY_AFTER_MS). Clients must use THIS, not noCapacityMs
            // (raw and ungated: set in shadow mode and from the first tick).
            noEligibleMachine: alertableNoCapSince(t, nowMs, liveMode) !== null,
            branch: t.rec.branch || null,
            workflow: t.rec.workflow || null,
            url: t.rec.url || null,
            labels: Array.isArray(t.rec.labels) ? t.rec.labels.slice() : [],
            status: t.rec.status || 'queued',
            runnerName: t.rec.runnerName || null,
            machine: machineFor(t.rec),
            // XACA-1479-007 (additive): dispatch priority, always one of critical|high|normal (missing/unknown -> normal).
            priority: ['critical', 'high'][priorityRank(t.rec)] || 'normal',
        }));
    }

    /**
     * XACA-1444 PR #1101 r1 (additive): jobs a runner has picked up and not yet completed, from the watcher's
     * own records, so jobs taken by PERSISTENT runners show as running too. `machine` is resolved from a
     * non-terminal assignment with the same runner name, else from a runner name that starts with a pool
     * machine id / host label followed by "-"; otherwise null (the UI then shows the runner name).
     * The queue view dedupes against assignments[] by repo#jobId, so a JIT job never appears twice.
     */
    function runningJobs() {
        if (!isEnabled()) return [];
        const nowMs = now();
        const machines = store.listMachines();
        const prefixes = Object.keys(machines).map((id) => [id, [id.toLowerCase(), plc.hostLabelOf(Object.assign({ id }, machines[id]))].filter(Boolean)]);
        const snap = assignments.snapshot();
        const out = [];
        for (const [jobKey, r] of [...running.entries()]) {
            if (nowMs - r.since > MAX_TRACKED_MS) { running.delete(jobKey); continue; }
            const rec = r.rec;
            const runnerName = capStr(rec.runnerName, 200);
            const repo = `${rec.owner}/${rec.repo}`;
            let machine = null;
            if (runnerName) {
                const a = snap.find((x) => x.runnerName === runnerName && String(x.repo).toLowerCase() === repo.toLowerCase());
                if (a && typeof a.machine === 'string') machine = a.machine;
                else {
                    const low = runnerName.toLowerCase();
                    const hit = prefixes.find(([, ps]) => ps.some((p) => low.startsWith(`${p}-`)));
                    if (hit) machine = hit[0];
                }
            }
            out.push({
                key: rec.key, repo, jobId: rec.jobId, name: capStr(rec.name, 200),
                branch: rec.branch || null, workflow: rec.workflow || null, url: rec.url || null,
                runnerName, machine,
                startedAt: rec.inProgressAt || new Date(r.since).toISOString(),
                status: 'running',
            });
        }
        return out;
    }

    const status = () => ({ enabled: isEnabled(), mode: effectiveMode(), decisionsRecorded, running: started, lastTickAt, tracked: tracked.size, notPoolSkipped, configRejected: configRejected.size });

    return { start, stop, tick, isEnabled, alerts: () => alerts.list(), queue, running: runningJobs, queueAge, noCapacity, queueAgeThresholdSec: () => Math.round(queueAgeThresholdMs() / 1000), status, onJob, onDegraded, onConfigChanged };
}

// ============================================================================
// server.js composition
// ============================================================================

/**
 * Build the whole CI pool stack and mount its routes. Called once from server.js.
 * Constructing it makes NO GitHub call and starts NO timer: the routes answer
 * `enabled:false` and nothing runs until dispatcher.start() finds FLEET_CI_DISPATCHER=1
 * and App credentials.
 *
 * @param {object} app
 * @param {object} opts
 * @param {string}   opts.dataDir   directory for ci-pool.json / ci-dispatch-state.json / ci-dispatch-audit.jsonl
 * @param {object}   [opts.env]     defaults to process.env
 * @param {object}   [opts.logger]
 * @param {Function} [opts.fetch]   GitHub transport (tests)
 * @param {Function} [opts.now]
 * @returns {{store, assignments, dispatcher, audit, alerts, reports, save: Function, start: Function, stop: Function}}
 */
function wireCiPool(app, opts) {
    const o = opts || {};
    if (!o.dataDir) throw new TypeError('wireCiPool: dataDir is required');
    const env = o.env || process.env;
    const logger = o.logger || console;
    const { createPoolStore } = require('./ci-pool-store');
    const { createAudit } = require('./ci-dispatch-audit');
    const { createAssignments } = require('./ci-dispatch-assignments');
    const { createGithubClient, createPriorityResolver } = require('./ci-dispatch-github');
    const { createWatcher } = require('./ci-dispatch-watcher');
    const { createAlerts } = require('./ci-dispatch-alerts');
    const { registerCiPoolRoutes } = require('./ci-pool-routes');

    const store = createPoolStore({ file: path.join(o.dataDir, 'ci-pool.json'), logger });
    const loaded = store.load();
    if (!loaded.ok) logger.error(`[CI-DISPATCH] ci-pool.json not loaded: ${loaded.error}`);
    const audit = createAudit({ path: path.join(o.dataDir, 'ci-dispatch-audit.jsonl'), keep: 2 });
    const alerts = createAlerts({ now: o.now, logger });
    const reports = new Map();

    let dispatcher = null;
    const github = createGithubClient({
        config: env, fetch: o.fetch, now: o.now,
        onDegraded: (info) => { if (dispatcher) dispatcher.onDegraded(info); },
    });
    const assignments = createAssignments({ file: path.join(o.dataDir, 'ci-dispatch-state.json'), github, audit, now: o.now, logger });
    const a = assignments.load();
    if (a && a.ok === false) logger.error(`[CI-DISPATCH] ci-dispatch-state.json not loaded: ${a.error}`);

    // XACA-1445-011: decision records default to <dataDir>/ci-shadow-decisions.jsonl (env FLEET_CI_SHADOW_LOG wins).
    dispatcher = createDispatcher({
        shadowLogPath: path.join(o.dataDir, 'ci-shadow-decisions.jsonl'),
        env, store, assignments, alerts, audit, github, reports, now: o.now, logger,
        createWatcher: ({ allowlist, getAllowlist, onJob, log }) => {
            // XACA-1479-005: branch -> open-PR ci-priority label, cached, failing toward NORMAL.
            const priority = createPriorityResolver({ github, audit, log, now: o.now });
            return createWatcher({ github, allowlist, getAllowlist, onJob, log, now: o.now, resolvePriority: priority.resolve });
        },
    });
    registerCiPoolRoutes(app, { store, assignments, dispatcher, audit, reports, now: o.now, logger });

    return {
        store, assignments, dispatcher, audit, alerts, reports,
        save: () => store.save(),
        start: () => dispatcher.start(),
        stop: () => dispatcher.stop(),
    };
}

module.exports = {
    createDispatcher, wireCiPool, hasCredentials, dormantReason, globalMode, priorityRank, surgePlan,
    NO_CAPACITY_AFTER_MS, FALLBACK_DELAY_MS, MAX_MINTS_PER_JOB, MAX_TRACKED_MS, MAX_CONFIG_REJECTED,
};
