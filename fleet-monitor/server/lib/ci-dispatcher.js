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
 * DORMANT (Requirement 3): unless env.FLEET_CI_DISPATCHER === '1' AND the GitHub App
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

const path = require('path');
const placement = require('./ci-dispatch-placement');
const policy = require('./ci-dispatch-policy');

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

const clean = (v) => (v === undefined || v === null ? '' : String(v).trim());

/** True when GitHub App credentials look configured (presence only; never read the value elsewhere). */
function hasCredentials(env) {
    const e = env || {};
    return (clean(e.GITHUB_APP_CLIENT_ID) !== '' || clean(e.GITHUB_APP_ID) !== '') && clean(e.GITHUB_APP_PRIVATE_KEY) !== '';
}

/** Why the dispatcher is dormant, or null when it may run. Never includes a secret. */
function dormantReason(env) {
    const e = env || {};
    if (e.FLEET_CI_DISPATCHER !== '1') return 'FLEET_CI_DISPATCHER is not "1"';
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

    // ---------------------------------------------------------------- events
    function evaluate(rec) {
        const cfg = store.getConfig();
        const machines = store.listMachines();
        const hostLabels = Object.keys(machines).map((id) => plc.hostLabelOf(Object.assign({ id }, machines[id]))).filter(Boolean);
        const v = pol.evaluateJob(rec, { allowlist: cfg.allowlist, poolLabel: cfg.poolLabel, hostLabels });
        if (v.accept) {
            configRejected.delete(rec.key);
            rejected.delete(rec.key); // a later re-rejection is a new decision and is audited again
            if (!tracked.has(rec.key)) tracked.set(rec.key, { rec, noCapSince: null, trackedAt: now() });
            return;
        }

        tracked.delete(rec.key);
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

    /** Watcher callback. Must never throw into the watcher. */
    function onJob(rec, change) {
        try {
            if (!rec || typeof rec.key !== 'string') return;
            if (change === 'queued' || change === 'seen') {
                if (rec.status === 'queued' && !rec.runnerName) evaluate(rec);
            } else if (change === 'pickup' || change === 'in_progress') {
                tracked.delete(rec.key);
                configRejected.delete(rec.key);
                assignments.bindJob(rec, change);
            } else if (change === 'completed') {
                tracked.delete(rec.key);
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
                unpicked.set(a.intendedJob.id, (unpicked.get(a.intendedJob.id) || 0) + 1);
            }
        }

        // Ghost backstop: retire tracked jobs that can no longer be real demand.
        for (const [key, t] of tracked) {
            const n = unpicked.get(t.rec.jobId) || 0;
            const why = n >= maxMintsPerJob ? `${n} runners expired unpicked`
                : (nowMs - t.trackedAt > maxTrackedMs ? `tracked over ${Math.round(maxTrackedMs / 3600000)} h` : null);
            if (!why) continue;
            tracked.delete(key);
            writeAudit('expire', { repo: `${t.rec.owner}/${t.rec.repo}`, jobId: t.rec.jobId, runAttempt: t.rec.runAttempt, state: 'tracked', reason: `ghost-bound: ${why}` });
            say('warn', `stopped dispatching job ${t.rec.jobId} (${why})`);
            alerts.raise('ci-dispatcher-degraded', {
                severity: 'warning',
                title: `CI dispatcher stopped dispatching a job in ${t.rec.owner}/${t.rec.repo}`,
                body: `Job "${clean(t.rec.name).slice(0, 80)}" (${t.rec.jobId}): ${why}. If the job is still queued on GitHub, check the machine agents; it will not be re-dispatched.`,
                ref: `ghost:${key}`,
            });
        }

        const jobs = [...tracked.values()].sort((a, b) => (a.rec.firstSeenAt < b.rec.firstSeenAt ? -1 : a.rec.firstSeenAt > b.rec.firstSeenAt ? 1 : 0));
        const outstanding = assignments.outstandingBySet();
        // The oldest `outstanding` jobs of a label-set are COVERED: runners already exist for them
        // (pending/delivered/started, not yet bound), so they are neither a no-capacity signal nor new demand.
        const coverage = new Map();
        for (const [raw, n] of outstanding) {
            const ck = plc.labelSetKey(String(raw).split(','));
            coverage.set(ck, (coverage.get(ck) || 0) + n);
        }
        const demand = [];   // covered + needing: what computeSupply sees
        const needing = [];  // uncovered jobs that have an eligible machine: where new mints go
        let adjusted = withReservations(base, reserved);
        for (const t of jobs) {
            const setKey = plc.labelSetKey(t.rec.labels);
            if ((coverage.get(setKey) || 0) > 0) {
                coverage.set(setKey, coverage.get(setKey) - 1);
                t.noCapSince = null; demand.push(t.rec);
                continue;
            }
            const evals = plc.evaluateMachines(machines, adjusted, t.rec, pcfg);
            if (evals.some((e) => e.eligible)) { t.noCapSince = null; demand.push(t.rec); needing.push(t.rec); continue; }
            if (t.noCapSince === null) t.noCapSince = nowMs;
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

        const supply = plc.computeSupply(demand, outstanding);
        const stats = { minted: 0, failed: 0 };
        for (const s of supply) {
            if (s.mint <= 0) continue;
            const inSet = needing.filter((j) => plc.labelSetKey(j.labels) === s.key);
            for (let i = 0; i < s.mint && i < inSet.length; i++) {
                const job = inSet[i];
                adjusted = withReservations(base, reserved);
                const ranked = plc.rankCandidates(machines, adjusted, job, pcfg);
                if (!ranked.length) break; // capacity ran out mid-tick; the next tick re-evaluates
                const id = ranked[0].id;
                const mrec = Object.assign({ id }, machines[id]);
                const labels = plc.mintLabels(job, mrec, pcfg);
                const os = plc.jobOs(job);
                if (!labels || !os) { say('warn', `skip mint for job ${job.jobId}: no valid label set`); break; }
                const r = await assignments.mint({ job, machine: id, labels, os });
                if (r && r.ok) {
                    stats.minted++; mintFailures = 0;
                    reserved.set(`${id}|${os}`, (reserved.get(`${id}|${os}`) || 0) + 1);
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
                    break; // do not hammer GitHub within one tick
                }
            }
        }
        return stats;
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
        if (why !== null) { say('log', `dispatcher dormant: ${why}`); return false; }
        started = true; stopped = false;
        if (!watcher) {
            watcher = d.createWatcher({
                allowlist: store.getConfig().allowlist,
                getAllowlist: () => store.getConfig().allowlist,
                onJob,
                log: (level, msg) => say(level === 'error' ? 'error' : level === 'warn' ? 'warn' : 'log', msg),
            });
        }
        say('log', `dispatcher ENABLED (single instance; fly machine ${clean(env.FLY_MACHINE_ID) || 'n/a'}; allowlist changes apply live)`);
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
        return [...tracked.values()].map((t) => ({
            key: t.rec.key,
            repo: `${t.rec.owner}/${t.rec.repo}`,
            jobId: t.rec.jobId,
            name: t.rec.name,
            jobClass: plc.jobClass(t.rec.name, cfg.jobClasses),
            waitingMs: Math.max(0, nowMs - Date.parse(t.rec.firstSeenAt)),
            noCapacityMs: t.noCapSince === null ? 0 : nowMs - t.noCapSince,
        }));
    }

    const status = () => ({ enabled: isEnabled(), running: started, lastTickAt, tracked: tracked.size, notPoolSkipped, configRejected: configRejected.size });

    return { start, stop, tick, isEnabled, alerts: () => alerts.list(), queue, status, onJob, onDegraded, onConfigChanged };
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
    const { createGithubClient } = require('./ci-dispatch-github');
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

    dispatcher = createDispatcher({
        env, store, assignments, alerts, audit, github, reports, now: o.now, logger,
        createWatcher: ({ allowlist, getAllowlist, onJob, log }) => createWatcher({ github, allowlist, getAllowlist, onJob, log, now: o.now }),
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
    createDispatcher, wireCiPool, hasCredentials, dormantReason,
    NO_CAPACITY_AFTER_MS, FALLBACK_DELAY_MS, MAX_MINTS_PER_JOB, MAX_TRACKED_MS, MAX_CONFIG_REJECTED,
};
