//
//  ci-dispatch-placement.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * CI dispatcher placement rules (XACA-1441-004, plan D4/D5/D6, amendments A2/A3).
 *
 * PURE functions: no I/O, no clock reads (callers pass `now`), no GitHub calls.
 *
 *  - jobClass()       job name -> 'long' | 'short' via the pool's jobClasses table.
 *  - isEligible()     D4 eligibility; ANY missing/invalid input -> ineligible
 *                     (fail closed), with a reason per failed rule.
 *  - rankCandidates() eligible machines ordered by: host preference matching the
 *                     job class, then largest memReclaimableBytes, then id.
 *                     Preference only ORDERS; nothing waits for a preferred host.
 *  - labelSetKey() / computeSupply()   D5: mint per label-set,
 *                     mint = max(0, eligibleQueued(S) - outstandingIdle(S)).
 *  - mintLabels()     A3: a JIT runner carries ONLY the labels passed at mint,
 *                     so always mint the full set.
 *
 * Shapes (see the plan's "Inter-module job record" and Contract §C3):
 *   job      {labels:[...], name, ...}
 *   machine  a ci-pool-store machine record, plus `id` where noted
 *   report   {receivedAt: <epoch ms | ISO>, capacity:{...C3}, slots:[{os,state,...}]}
 */

const { DEFAULT_THRESHOLDS, DEFAULT_JOB_CLASSES } = require('./ci-pool-store');

const DEFAULT_POOL_LABEL = 'fleet-pool';
const OS_LABELS = ['Linux', 'macOS'];

const has = (o, k) => o !== null && typeof o === 'object' && Object.prototype.hasOwnProperty.call(o, k);
const isNum = (v) => typeof v === 'number' && Number.isFinite(v);

// ------------------------------------------------------------------- labels

/** Lowercased/trimmed/deduped/sorted labels, or null when `labels` is not an array of non-empty strings. */
function normalizeLabels(labels) {
    if (!Array.isArray(labels)) return null;
    const out = new Set();
    for (const l of labels) {
        if (typeof l !== 'string' || l.trim() === '') return null;
        out.add(l.trim().toLowerCase());
    }
    return [...out].sort();
}

/** Canonical key for a label-set (GitHub label matching is case-insensitive). null for invalid input. */
function labelSetKey(labels) {
    const n = normalizeLabels(labels);
    return n === null ? null : n.join(',');
}

/** The single OS label ('Linux' | 'macOS') a job asks for, or null if none/ambiguous. */
function jobOs(job) {
    const n = job && normalizeLabels(job.labels);
    if (!n) return null;
    const found = OS_LABELS.filter((o) => n.includes(o.toLowerCase()));
    return found.length === 1 ? found[0] : null;
}

// ---------------------------------------------------------------- job class

/** 'long' when the job name maps to long in `jobClasses`; everything else (unknown, bad input) is 'short'. */
function jobClass(jobName, jobClasses) {
    const table = jobClasses && typeof jobClasses === 'object' ? jobClasses : DEFAULT_JOB_CLASSES;
    if (typeof jobName !== 'string' || !has(table, jobName)) return 'short';
    return table[jobName] === 'long' ? 'long' : 'short';
}

// -------------------------------------------------------------- eligibility

/** Effective thresholds: defaults < config thresholds < per-machine overrides. */
function effectiveThresholds(thresholds, machine) {
    return Object.assign({}, DEFAULT_THRESHOLDS, thresholds || {}, (machine && machine.thresholds) || {});
}

function toMs(v) {
    if (isNum(v)) return v;
    if (typeof v === 'string') { const t = Date.parse(v); return Number.isNaN(t) ? null : t; }
    return null;
}

/** Host label a runner minted on this machine carries: machine.hostLabel, else the lowercased id. */
function hostLabelOf(machine) {
    if (!machine) return null;
    if (typeof machine.hostLabel === 'string' && machine.hostLabel) return machine.hostLabel.toLowerCase();
    return typeof machine.id === 'string' && machine.id ? machine.id.toLowerCase() : null;
}

/**
 * D4 eligibility. Never throws; every missing/invalid input yields a reason.
 *
 * @param machine  pool record (+ optional id/hostLabel): enabled, paused, thresholds
 * @param report   {receivedAt, capacity, slots}
 * @param job      {labels}
 * @param opts     {now (epoch ms, required), thresholds (config thresholds), poolLabel}
 * @returns {{eligible: boolean, reasons: string[]}}
 */
function isEligible(machine, report, job, opts) {
    const reasons = [];
    const o = opts || {};
    const th = effectiveThresholds(o.thresholds, machine);

    if (!machine || typeof machine !== 'object') return { eligible: false, reasons: ['no-machine-record'] };
    if (machine.enabled !== true) reasons.push('not-enabled');
    if (machine.paused !== false) reasons.push('paused');   // anything but an explicit false pauses (fail closed)

    const os = jobOs(job);
    if (os === null) reasons.push('job-os-unknown');

    // Host-targeting label: a job may only carry labels the full mint set would carry.
    const jl = job && normalizeLabels(job.labels);
    const host = hostLabelOf(machine);
    if (jl && os) {
        const known = new Set(['self-hosted', os.toLowerCase(), 'arm64', String(o.poolLabel || DEFAULT_POOL_LABEL).toLowerCase()]);
        const extra = jl.filter((l) => !known.has(l));
        if (extra.length && (host === null || extra.some((l) => l !== host))) reasons.push('label-mismatch');
    }

    if (!report || typeof report !== 'object' || !report.capacity || typeof report.capacity !== 'object') {
        reasons.push('no-report');
        return { eligible: false, reasons };
    }
    const c = report.capacity;

    // Freshness
    const polled = toMs(report.receivedAt);
    if (!isNum(o.now)) reasons.push('no-clock');
    else if (polled === null) reasons.push('no-last-poll');
    else if (o.now - polled > th.pollStaleMs) reasons.push('stale-poll');
    else if (polled - o.now > th.pollStaleMs) reasons.push('poll-in-future');

    // Idle slot for the job's OS
    if (os !== null) {
        const slots = Array.isArray(report.slots) ? report.slots : null;
        if (!slots) reasons.push('no-slots');
        else if (!slots.some((s) => s && s.os === os && s.state === 'idle')) reasons.push('no-idle-slot');
    }

    // Headroom. memReclaimable gates macOS jobs only (the Linux VM's memory is already allocated).
    if (os === 'macOS') {
        if (!isNum(c.memReclaimableBytes)) reasons.push('mem-reclaimable-missing');
        else if (c.memReclaimableBytes < th.memReclaimableBytes) reasons.push('mem-reclaimable-low');
    }
    if (!isNum(c.swapUsedBytes)) reasons.push('swap-missing');
    else if (!(c.swapUsedBytes < th.swapUsedBytes)) reasons.push('swap-high');

    if (!isNum(c.memFreePct)) reasons.push('mem-free-missing');
    else if (c.memFreePct < th.memFreePct) reasons.push('mem-free-low');

    if (!isNum(c.load1) || !isNum(c.ncpu) || c.ncpu <= 0) reasons.push('load-missing');
    else if (!(c.load1 / c.ncpu < th.loadPerCpu)) reasons.push('load-high');

    if (os === 'Linux' && c.vmState !== 'running') reasons.push('vm-not-running');

    return { eligible: reasons.length === 0, reasons };
}

// ------------------------------------------------------------------ ranking

/**
 * Evaluate every machine for a job and return all verdicts, eligible ones in
 * placement order first. Pure and deterministic.
 *
 * @param machines {Object<string, machineRecord>} keyed by machine id
 * @param reports  {Object<string, report>}        keyed by machine id
 * @param cfg      {now, thresholds, jobClasses, poolLabel}
 * @returns {{id, eligible, reasons, preferred, memReclaimableBytes}[]}
 */
function evaluateMachines(machines, reports, job, cfg) {
    const c = cfg || {};
    const cls = jobClass(job && job.name, c.jobClasses);
    const rows = Object.keys(machines || {}).map((id) => {
        const m = Object.assign({ id }, machines[id]);
        const r = reports && has(reports, id) ? reports[id] : null;
        const v = isEligible(m, r, job, { now: c.now, thresholds: c.thresholds, poolLabel: c.poolLabel });
        const mem = r && r.capacity && isNum(r.capacity.memReclaimableBytes) ? r.capacity.memReclaimableBytes : 0;
        return { id, eligible: v.eligible, reasons: v.reasons, preferred: m.prefers === cls, memReclaimableBytes: mem };
    });
    rows.sort((a, b) =>
        (b.eligible - a.eligible) ||
        (b.preferred - a.preferred) ||
        (b.memReclaimableBytes - a.memReclaimableBytes) ||
        (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
    return rows;
}

/** Eligible machines only, in placement order. The first element is the placement. */
function rankCandidates(machines, reports, job, cfg) {
    return evaluateMachines(machines, reports, job, cfg).filter((r) => r.eligible);
}

// ------------------------------------------------------------------- supply

/**
 * D5/A2: per label-set S, mint = max(0, queued(S) - outstandingIdle(S)).
 *
 * @param queuedEligibleJobs  jobs already accepted by policy and with an eligible machine
 * @param outstandingIdleBySet {Object|Map} labelSetKey -> count of assignments not yet bound to a job
 * @returns {{key, labels, queued, outstanding, mint}[]} sorted by key; sets with neither demand nor supply are omitted
 */
function computeSupply(queuedEligibleJobs, outstandingIdleBySet) {
    const sets = new Map();
    for (const job of Array.isArray(queuedEligibleJobs) ? queuedEligibleJobs : []) {
        const labels = job && normalizeLabels(job.labels);
        if (!labels) continue;                       // invalid job: no demand
        const key = labels.join(',');
        const s = sets.get(key) || { key, labels, queued: 0, outstanding: 0, mint: 0 };
        s.queued += 1;
        sets.set(key, s);
    }
    const entries = outstandingIdleBySet instanceof Map
        ? [...outstandingIdleBySet.entries()]
        : Object.entries(outstandingIdleBySet || {});
    for (const [rawKey, n] of entries) {
        if (!isNum(n) || n <= 0) continue;
        const key = labelSetKey(String(rawKey).split(','));
        if (key === null) continue;
        const s = sets.get(key) || { key, labels: key.split(','), queued: 0, outstanding: 0, mint: 0 };
        s.outstanding += Math.floor(n);
        sets.set(key, s);
    }
    for (const s of sets.values()) s.mint = Math.max(0, s.queued - s.outstanding);
    return [...sets.values()].sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));
}

// -------------------------------------------------------------------- mint

/**
 * A3: the full label set to pass to generate-jitconfig:
 * self-hosted, <OS>, ARM64, <poolLabel>, <host label>.
 * Returns null (do not mint) if the job's OS is unknown, its labels are not a
 * subset of that set, or the machine has no usable host label.
 */
function mintLabels(job, machine, cfg) {
    const os = jobOs(job);
    const host = hostLabelOf(machine);
    const pool = (cfg && typeof cfg.poolLabel === 'string' && cfg.poolLabel) || DEFAULT_POOL_LABEL;
    if (os === null || host === null) return null;
    const full = ['self-hosted', os, 'ARM64', pool, host];
    const fullKeys = new Set(full.map((l) => l.toLowerCase()));
    const jl = normalizeLabels(job.labels);
    if (!jl.every((l) => fullKeys.has(l))) return null;
    return full;
}

module.exports = {
    DEFAULT_POOL_LABEL,
    normalizeLabels, labelSetKey, jobOs, jobClass, effectiveThresholds, hostLabelOf,
    isEligible, evaluateMachines, rankCandidates, computeSupply, mintLabels,
};
