//
//  FROZEN COPY of lib/ci-dispatch-placement.js at 029d5fb31 (XACA-1704-001 parity oracle; do not edit)
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
 *  - repo binding (XACA-1459): machine.repos = non-empty ["owner/repo", ...] BINDS a machine. A bound
 *                     machine serves ONLY those repos; a repo bound to ANY machine places ONLY on
 *                     machines bound to it. A machine with no binding keeps serving every unbound repo.
 *                     A malformed binding makes the machine ineligible for everything.
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

const { DEFAULT_THRESHOLDS, DEFAULT_JOB_CLASSES, REPO_RE, validateRepos } = require('../../lib/ci-pool-store');

const DEFAULT_POOL_LABEL = 'fleet-pool';
const OS_LABELS = ['Linux', 'macOS'];
/** Eligibility reasons caused by repo binding (audited by the dispatcher). */
const BINDING_REASONS = Object.freeze(['binding-malformed', 'repo-not-bound', 'repo-reserved']);

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

// ------------------------------------------------------------- repo binding

/** Lowercased "owner/repo" for a job, or null when the job does not carry a valid owner and repo. */
function repoSlug(job) {
    if (!job || typeof job.owner !== 'string' || typeof job.repo !== 'string') return null;
    const slug = `${job.owner}/${job.repo}`;
    return REPO_RE.test(slug) ? slug.toLowerCase() : null;
}

/** Lowercased binding of a machine: {state:'unbound'} | {state:'bound', repos:Set} | {state:'malformed'}. */
function bindingOf(machine) {
    const v = machine && Object.prototype.hasOwnProperty.call(machine, 'repos') ? machine.repos : null;
    if (v === null || v === undefined) return { state: 'unbound' };
    if (validateRepos(v, 'repos').length > 0) return { state: 'malformed' };   // the store's own rule: one definition
    return { state: 'bound', repos: new Set(v.map((r) => r.toLowerCase())) };
}

/** Every repo (lowercased) bound on at least one machine with a WELL-FORMED binding. */
function boundRepoSet(machines) {
    const out = new Set();
    for (const id of Object.keys(machines || {})) {
        const b = bindingOf(machines[id]);
        if (b.state === 'bound') for (const r of b.repos) out.add(r);
    }
    return out;
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
 * @param opts     {now (epoch ms, required), thresholds (config thresholds), poolLabel,
 *                  boundRepos (Set of lowercased "owner/repo" bound on any machine; see boundRepoSet)}
 * @returns {{eligible: boolean, reasons: string[]}}
 */
function isEligible(machine, report, job, opts) {
    const reasons = [];
    const o = opts || {};
    const th = effectiveThresholds(o.thresholds, machine);

    if (!machine || typeof machine !== 'object') return { eligible: false, reasons: ['no-machine-record'] };
    if (machine.enabled !== true) reasons.push('not-enabled');
    if (machine.paused !== false) reasons.push('paused');   // anything but an explicit false pauses (fail closed)

    // XACA-1459 repo binding. Reasons: binding-malformed | repo-not-bound | repo-reserved.
    const binding = bindingOf(machine);
    const slug = repoSlug(job);
    if (binding.state === 'malformed') reasons.push('binding-malformed');
    else if (binding.state === 'bound') {
        if (slug === null || !binding.repos.has(slug)) reasons.push('repo-not-bound');   // no repo identity => refuse
    } else if (slug !== null && o.boundRepos instanceof Set && o.boundRepos.has(slug)) {
        reasons.push('repo-reserved');   // this repo is bound to other machines; an unbound machine must not take it
    }

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
    // Swap (XACA-1708-003). macOS swap-used is a sticky high-water mark, so an ABSOLUTE gate trips forever on
    // a long-running host regardless of real pressure (m1mini 2026-10-31: 3.6 GiB swap, 55% free, 7.6h queued).
    // Agents that report memPressureLevel are gated on pressure + swap GROWTH instead; absolute swapUsedBytes
    // is informational for them. swapUsedBytes stays a REQUIRED report field (routes enforce it), so its absence
    // is still 'swap-missing' for everyone: a report without it is a broken agent, fail closed.
    if (!isNum(c.swapUsedBytes)) reasons.push('swap-missing');
    if (c.memPressureLevel === undefined) {
        // LEGACY agent (no memPressureLevel field at all): the original absolute gate, unchanged, so an old
        // agent is never less gated than before this change.
        if (isNum(c.swapUsedBytes) && !(c.swapUsedBytes < th.swapUsedBytes)) reasons.push('swap-high');
    } else {
        // Present-but-unusable (null, string, NaN, < 1) must not read as "normal": fail closed.
        if (!isNum(c.memPressureLevel) || c.memPressureLevel < 1) reasons.push('mem-pressure-malformed');
        else if (c.memPressureLevel >= th.memPressureLevel) reasons.push('mem-pressure');

        // Swap growth: both fields are absent until the agent's window is half-filled (=> no verdict, not a
        // refusal). One without the other, or a bad value, is malformed => refuse.
        const g = c.swapGrowthBytes, w = c.swapGrowthWindowSec;
        if (g !== undefined || w !== undefined) {
            if (!isNum(g) || !isNum(w) || w <= 0) reasons.push('swap-growth-malformed');
            else if ((g * 3600) / w > th.swapGrowthBytesPerHour) reasons.push('swap-growing');
        }
    }

    if (!isNum(c.memFreePct)) reasons.push('mem-free-missing');
    else if (c.memFreePct < th.memFreePct) reasons.push('mem-free-low');

    if (!isNum(c.load1) || !isNum(c.ncpu) || c.ncpu <= 0) reasons.push('load-missing');
    else if (c.load5 === undefined) {
        // LEGACY agent (no load5 field at all): the original load1-only gate, unchanged, so an old agent is
        // never less gated than before XACA-1763.
        if (!(c.load1 / c.ncpu < th.loadPerCpu)) reasons.push('load-high');
    } else if (!isNum(c.load5) || c.load5 < 0) {
        // Present-but-unusable (null, string, NaN, negative) must not read as "calm": fail closed.
        reasons.push('load-malformed');
    } else if (c.load1 / c.ncpu >= th.loadPerCpu && c.load5 / c.ncpu >= th.loadPerCpu) {
        // Sustained load (XACA-1763): refuse only when BOTH the 1- and 5-minute averages are over the line.
        // A load1 spike with a calm load5 (co-tenant Claude sessions on m4mini) is transient, not saturation.
        reasons.push('load-high');
    }

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
    const boundRepos = boundRepoSet(machines);
    const rows = Object.keys(machines || {}).map((id) => {
        const m = Object.assign({ id }, machines[id]);
        const r = reports && has(reports, id) ? reports[id] : null;
        const v = isEligible(m, r, job, { now: c.now, thresholds: c.thresholds, poolLabel: c.poolLabel, boundRepos });
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
    repoSlug, bindingOf, boundRepoSet, BINDING_REASONS,
    normalizeLabels, labelSetKey, jobOs, jobClass, effectiveThresholds, hostLabelOf,
    isEligible, evaluateMachines, rankCandidates, computeSupply, mintLabels,
};
