//
//  ci-dispatch-assignments.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Assignment state machine + JIT hand-off for the CI dispatcher
 * (XACA-1441-005; plan Requirements 7/8/11, D5/D8, Contract C4/C5, spike A2/A4).
 *
 *   pending --(served in a poll)--> delivered --(agent: started)--> started
 *     --(watcher sees job.runner_name)--> running --(agent: completed|failed)--> terminal
 *   timeouts: pending 60 s -> expired | delivered 120 s -> expired
 *             started 300 s unbound -> cancelled | running 375 min -> lost
 *
 * SECRETS (Requirement 7/11):
 *   - The encoded JIT config lives ONLY in the `configs` Map. It is never a field
 *     of an assignment record, so it cannot reach the state file, a view, the
 *     audit log or a log line. takeForMachine() deletes it BEFORE returning it, so
 *     delivery is at-most-once: recovery is always a re-mint, never a re-delivery.
 *   - The state file (data/ci-dispatch-state.json) holds non-secret metadata only,
 *     built by an explicit field allowlist (persistable()).
 *   - After a restart the configs are gone by design: every non-terminal record is
 *     marked `expired` and its registration is DELETEd from GitHub.
 *
 * GITHUB CALLS happen only in mint() and sweep(). The agent poll path
 * (takeForMachine / cancelListFor / report) never calls GitHub, so a poll can
 * never be slowed or amplified by GitHub, and dormant mode is trivially call-free.
 *
 * Cleanup (A4): a minted-but-unstarted registration persists and a started-but-idle
 * listener never exits, so expired / cancelled / lost assignments get their
 * registration DELETEd (422 = runner busy: retried next sweep, never forced) and
 * the owning agent is told to kill the listener via `cancel[]` (cancelListFor).
 *
 * Everything with a side effect is injectable: now, fs, github, audit, ids.
 */

const realFs = require('fs');
const nodePath = require('path');
const crypto = require('crypto');
const { labelSetKey } = require('./ci-dispatch-placement');

const SCHEMA_VERSION = 1;
const MINUTE = 60 * 1000;

const STATES = Object.freeze(['pending', 'delivered', 'started', 'running',
    'completed', 'failed', 'expired', 'cancelled', 'lost']);
const TERMINAL = new Set(['completed', 'failed', 'expired', 'cancelled', 'lost']);

const DEFAULT_TIMEOUTS = Object.freeze({
    pendingMs: 60 * 1000,             // C5: pending -> expired
    deliveredMs: 120 * 1000,          // C5: delivered -> expired (also the agent's startBy)
    boundMs: 300 * 1000,              // C5: started with no job bound -> cancelled
    runningMs: 375 * MINUTE,          // C5: 360-min ceiling (XACA-1424) + 15
    cancelRetainMs: 15 * MINUTE,      // how long cancel[] keeps naming an un-acked kill
    retainTerminalMs: 24 * 60 * MINUTE,
    maxTerminal: 500,
    maxCleanupAttempts: 20,
});

const ID_RE = /^a_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const REPO_RE = /^[A-Za-z0-9-]{1,39}\/[A-Za-z0-9._-]{1,100}$/;
const OS_VALUES = ['Linux', 'macOS'];
const MAX_REASON = 200;

const PERSISTED_FIELDS = ['id', 'machine', 'os', 'repo', 'runnerId', 'runnerName', 'labels',
    'labelSet', 'state', 'intendedJob', 'boundJob', 'createdAt', 'deliveredAt', 'startedAt',
    'boundAt', 'endedAt', 'startBy', 'reason', 'exitCode', 'cleanup', 'cleanupAttempts',
    'killNeeded', 'killAcked'];

const isInt = (v) => Number.isInteger(v);
const isStr = (v) => typeof v === 'string';
const iso = (ms) => (Number.isFinite(ms) ? new Date(ms).toISOString() : null);

/** Agent-supplied free text: control characters stripped, length-capped. */
function cleanReason(v) {
    if (!isStr(v)) return null;
    // eslint-disable-next-line no-control-regex
    const t = v.replace(/[\u0000-\u001f\u007f]/g, ' ').trim().slice(0, MAX_REASON);
    return t === '' ? null : t;
}

function sanitizeJob(j) {
    if (!j || typeof j !== 'object') return null;
    return {
        id: isInt(j.id) ? j.id : null,
        name: isStr(j.name) ? j.name.slice(0, 200) : null,
        runId: isInt(j.runId) ? j.runId : null,
    };
}

/** Explicit allowlist: nothing outside PERSISTED_FIELDS can reach the state file. */
function persistable(rec) {
    const o = {};
    for (const f of PERSISTED_FIELDS) o[f] = rec[f] === undefined ? null : rec[f];
    return o;
}

/** Redacted external view (GET /api/ci-pool). No config, no runner id, no free text. */
function view(rec) {
    return {
        id: rec.id, machine: rec.machine, os: rec.os, repo: rec.repo,
        runnerName: rec.runnerName, labels: rec.labels.slice(), state: rec.state,
        intendedJob: rec.intendedJob ? Object.assign({}, rec.intendedJob) : null,
        boundJob: rec.boundJob ? Object.assign({}, rec.boundJob) : null,
        createdAt: iso(rec.createdAt), deliveredAt: iso(rec.deliveredAt),
        startedAt: iso(rec.startedAt), boundAt: iso(rec.boundAt), endedAt: iso(rec.endedAt),
        reason: rec.reason,
    };
}

function validRecord(r) {
    return r && typeof r === 'object' && isStr(r.id) && ID_RE.test(r.id) &&
        STATES.includes(r.state) && isStr(r.machine) && r.machine !== '' &&
        isStr(r.repo) && REPO_RE.test(r.repo) && OS_VALUES.includes(r.os) &&
        isInt(r.runnerId) && r.runnerId > 0 && isStr(r.runnerName) &&
        Array.isArray(r.labels) && r.labels.every(isStr) && isInt(r.createdAt);
}

/**
 * @param {object} opts
 * @param {string}   opts.file      state file (data/ci-dispatch-state.json)
 * @param {object}   opts.github    {generateJitConfig, deleteRunner} (ci-dispatch-github client)
 * @param {object}   [opts.audit]   {append(event, fields)} (ci-dispatch-audit)
 * @param {Function} [opts.now]     () => epoch ms
 * @param {object}   [opts.fs]      fs-like
 * @param {Function} [opts.randomUUID]
 * @param {Function} [opts.randomHex] (nBytes) => hex
 * @param {object}   [opts.logger]  {error, warn}; messages never contain secrets
 * @param {object}   [opts.timeouts] overrides for DEFAULT_TIMEOUTS
 */
function createAssignments(opts) {
    const o = opts || {};
    if (!isStr(o.file) || !o.file) throw new TypeError('createAssignments: file is required');
    if (!o.github || typeof o.github.generateJitConfig !== 'function' || typeof o.github.deleteRunner !== 'function') {
        throw new TypeError('createAssignments: github client with generateJitConfig/deleteRunner is required');
    }
    const file = o.file;
    const github = o.github;
    const auditSink = o.audit || null;
    const clock = typeof o.now === 'function' ? o.now : Date.now;
    const fs = o.fs || realFs;
    const randomUUID = o.randomUUID || (() => crypto.randomUUID());
    const randomHex = o.randomHex || ((n) => crypto.randomBytes(n).toString('hex'));
    const log = o.logger || console;
    const T = Object.assign({}, DEFAULT_TIMEOUTS, o.timeouts || {});

    /** id -> record (non-secret). */
    const records = new Map();
    /** id -> encoded JIT config. THE ONLY place a config exists. */
    const configs = new Map();
    let sweeping = null;

    // ------------------------------------------------------------- plumbing
    function audit(event, fields) {
        if (!auditSink) return;
        try { auditSink.append(event, fields); } catch (_) { /* audit never throws into the machine */ }
    }

    function auditFields(rec, extra) {
        return Object.assign({
            id: rec.id, repo: rec.repo, jobId: rec.boundJob ? rec.boundJob.id : (rec.intendedJob ? rec.intendedJob.id : null),
            runnerName: rec.runnerName, runnerId: rec.runnerId, machine: rec.machine, state: rec.state,
        }, extra || {});
    }

    function persist() {
        try {
            fs.mkdirSync(nodePath.dirname(file), { recursive: true });
            const tmp = `${file}.tmp-${process.pid}`;
            const body = { schemaVersion: SCHEMA_VERSION, savedAt: iso(clock()), assignments: [...records.values()].map(persistable) };
            try {
                fs.writeFileSync(tmp, JSON.stringify(body, null, 2), { mode: 0o600 });
                fs.renameSync(tmp, file);
            } catch (e) {
                try { fs.unlinkSync(tmp); } catch (_) { /* nothing to clean */ }
                throw e;
            }
            return true;
        } catch (e) {
            if (log.error) log.error(`[CI-DISPATCH] cannot persist assignment state: ${e.message}`);
            return false;
        }
    }

    function prune(now) {
        const terminal = [...records.values()].filter((r) => TERMINAL.has(r.state) && r.cleanup !== 'needed')
            .sort((a, b) => (a.endedAt || 0) - (b.endedAt || 0));
        let drop = terminal.filter((r) => now - (r.endedAt || 0) > T.retainTerminalMs);
        const rest = terminal.filter((r) => !drop.includes(r));
        if (rest.length > T.maxTerminal) drop = drop.concat(rest.slice(0, rest.length - T.maxTerminal));
        for (const r of drop) records.delete(r.id);
    }

    /** Move a record to `to`, stamping times and auditing. Caller persists. */
    function move(rec, to, now, extra) {
        const from = rec.state;
        rec.state = to;
        const x = extra || {};
        if (to === 'delivered') rec.deliveredAt = now;
        if (to === 'started') rec.startedAt = now;
        if (to === 'running') rec.boundAt = now;
        if (TERMINAL.has(to)) rec.endedAt = now;
        if (x.reason !== undefined) rec.reason = x.reason;
        if (x.exitCode !== undefined) rec.exitCode = x.exitCode;
        if (TERMINAL.has(to)) configs.delete(rec.id);
        if (x.timeout) {
            audit('expire', auditFields(rec, { reason: x.reason }));
        } else {
            audit('state', auditFields(rec, { from, to, reason: x.reason === undefined ? rec.reason : x.reason }));
        }
    }

    // ----------------------------------------------------------------- load
    /**
     * Restore metadata after a restart. Every non-terminal record is marked expired
     * (its config is gone by design) and queued for registration DELETE.
     * Never throws. A corrupt file is moved aside.
     */
    function load() {
        let raw;
        try { raw = fs.readFileSync(file, 'utf8'); } catch (e) {
            if (e.code === 'ENOENT') return { ok: true, fresh: true, expired: 0 };
            if (log.error) log.error(`[CI-DISPATCH] cannot read assignment state: ${e.message}`);
            return { ok: false, error: e.message, expired: 0 };
        }
        let parsed;
        try { parsed = JSON.parse(raw); } catch (e) { parsed = null; }
        if (!parsed || parsed.schemaVersion !== SCHEMA_VERSION || !Array.isArray(parsed.assignments)) {
            try { fs.renameSync(file, `${file}.corrupt-${clock()}`); } catch (_) { /* best effort */ }
            if (log.error) log.error('[CI-DISPATCH] assignment state file rejected; moved aside (orphans, if any, need a manual runner sweep)');
            return { ok: false, error: 'corrupt state file', expired: 0 };
        }
        const now = clock();
        let expired = 0;
        records.clear();
        configs.clear();
        for (const r of parsed.assignments) {
            if (!validRecord(r)) continue;
            const rec = {};
            for (const f of PERSISTED_FIELDS) rec[f] = r[f] === undefined ? null : r[f];
            if (!TERMINAL.has(rec.state)) {
                const prior = rec.state;
                rec.killNeeded = prior === 'delivered' || prior === 'started';
                rec.killAcked = false;
                rec.cleanup = 'needed';
                rec.cleanupAttempts = 0;
                records.set(rec.id, rec);
                move(rec, 'expired', now, { reason: 'restart', timeout: true });
                expired++;
            } else {
                rec.cleanupAttempts = isInt(rec.cleanupAttempts) ? rec.cleanupAttempts : 0;
                rec.cleanup = ['none', 'needed', 'done', 'failed'].includes(rec.cleanup) ? rec.cleanup : 'none';
                records.set(rec.id, rec);
            }
        }
        persist();
        return { ok: true, expired };
    }

    // ----------------------------------------------------------------- mint
    /**
     * Mint a one-job JIT runner for `machine` and hold its config in memory.
     * @param {{job: object, machine: string, labels: string[], os: string}} p
     * @returns {Promise<{ok:true, assignment:object}|{ok:false, reason:string}>}
     */
    async function mint(p) {
        const job = p && p.job;
        const machine = p && p.machine;
        const labels = p && p.labels;
        const os = p && p.os;
        if (!job || !isStr(job.owner) || !isStr(job.repo) || !isInt(job.jobId) ||
            !isStr(machine) || !machine || !Array.isArray(labels) || labels.length === 0 ||
            !labels.every(isStr) || !OS_VALUES.includes(os)) {
            return { ok: false, reason: 'bad-args' };
        }
        const repoFull = `${job.owner}/${job.repo}`;
        if (!REPO_RE.test(repoFull)) return { ok: false, reason: 'bad-repo' };
        const slug = machine.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 24) || 'host';
        const runnerName = `fcp-${slug}-${randomHex(4)}`;
        const intended = sanitizeJob({ id: job.jobId, name: job.name, runId: job.runId });
        let res;
        try {
            res = await github.generateJitConfig({ owner: job.owner, repo: job.repo, name: runnerName, labels });
        } catch (e) {
            // GithubError messages are fixed strings (no body/token); only the code/status is used.
            const code = (e && e.code) ? String(e.code) : 'error';
            audit('assign', { repo: repoFull, jobId: job.jobId, runnerName, machine, state: 'mint-failed', reason: `mint-failed:${code}${e && e.status ? ':' + e.status : ''}`, runId: job.runId, jobName: job.name });
            return { ok: false, reason: 'mint-failed', code };
        }
        // No await between here and persist(): the crash window for an unrecorded registration is a few ms.
        const now = clock();
        const rec = {
            id: `a_${randomUUID()}`, machine, os, repo: repoFull,
            runnerId: res.runnerId, runnerName, labels: labels.slice(),
            labelSet: labelSetKey(job.labels) || labelSetKey(labels),
            state: 'pending', intendedJob: intended, boundJob: null,
            createdAt: now, deliveredAt: null, startedAt: null, boundAt: null, endedAt: null,
            startBy: null, reason: null, exitCode: null,
            cleanup: 'none', cleanupAttempts: 0, killNeeded: false, killAcked: false,
        };
        records.set(rec.id, rec);
        configs.set(rec.id, res.encodedJitConfig);
        persist();
        audit('assign', auditFields(rec, { runId: intended.runId, jobName: intended.name, labelSet: rec.labelSet }));
        return { ok: true, assignment: view(rec) };
    }

    // ------------------------------------------------------------ expiry
    /** Apply every timeout. Synchronous, no GitHub call. Returns the number of transitions. */
    function expireDue(nowArg) {
        const now = Number.isFinite(nowArg) ? nowArg : clock();
        let n = 0;
        for (const rec of records.values()) {
            let to = null, killNeeded = false, why = null;
            if (rec.state === 'pending' && now - rec.createdAt >= T.pendingMs) { to = 'expired'; why = 'timeout:pending'; }
            else if (rec.state === 'delivered' && now - rec.deliveredAt >= T.deliveredMs) { to = 'expired'; why = 'timeout:delivered'; killNeeded = true; }
            else if (rec.state === 'started' && now - rec.startedAt >= T.boundMs) { to = 'cancelled'; why = 'timeout:no-job-bound'; killNeeded = true; }
            else if (rec.state === 'running' && now - rec.boundAt >= T.runningMs) { to = 'lost'; why = 'timeout:running'; }
            if (!to) continue;
            rec.killNeeded = killNeeded;
            rec.killAcked = false;
            rec.cleanup = 'needed';
            rec.cleanupAttempts = 0;
            move(rec, to, now, { reason: why, timeout: true });
            n++;
        }
        if (n) persist();
        return n;
    }

    // ------------------------------------------------------------ delivery
    /**
     * Hand every pending assignment of `machine` to the poll that is being answered.
     * The JIT config is DELETED from memory before this returns: at-most-once.
     * @returns {object[]} C4 assignment objects (the only place a jitConfig is ever exposed)
     */
    function takeForMachine(machine, nowArg) {
        const now = Number.isFinite(nowArg) ? nowArg : clock();
        expireDue(now);
        const out = [];
        for (const rec of records.values()) {
            if (rec.machine !== machine || rec.state !== 'pending') continue;
            const cfg = configs.get(rec.id);
            configs.delete(rec.id);                       // drop first: nothing can deliver it twice
            if (typeof cfg !== 'string') {                // config lost (should not happen): never serve an empty one
                rec.killNeeded = false; rec.killAcked = false; rec.cleanup = 'needed'; rec.cleanupAttempts = 0;
                move(rec, 'expired', now, { reason: 'config-missing', timeout: true });
                continue;
            }
            rec.startBy = now + T.deliveredMs;
            move(rec, 'delivered', now);
            out.push({
                id: rec.id, os: rec.os, runnerName: rec.runnerName, labels: rec.labels.slice(),
                repo: rec.repo, intendedJob: rec.intendedJob ? Object.assign({}, rec.intendedJob) : null,
                jitConfig: cfg, startBy: iso(rec.startBy), jobBindTimeoutSeconds: Math.round(T.boundMs / 1000),
            });
        }
        if (out.length) persist();
        return out;
    }

    /** A4: assignments whose listener the agent must kill (not yet acknowledged). */
    function cancelListFor(machine, nowArg) {
        const now = Number.isFinite(nowArg) ? nowArg : clock();
        const ids = [];
        for (const rec of records.values()) {
            if (rec.machine === machine && (rec.state === 'expired' || rec.state === 'cancelled') &&
                rec.killNeeded && !rec.killAcked && now - rec.endedAt < T.cancelRetainMs) ids.push(rec.id);
        }
        return ids;
    }

    // ------------------------------------------------------- agent reports
    /**
     * Agent lifecycle report (C5). Ownership is checked first so another machine's
     * id is indistinguishable from an unknown one.
     * @returns {{status:'ok'|'notfound'|'conflict', state?:string, changed?:boolean}}
     */
    function report(id, machine, body) {
        const rec = isStr(id) ? records.get(id) : undefined;
        if (!rec || rec.machine !== machine) return { status: 'notfound' };
        const to = body && body.state;
        const cur = rec.state;
        const now = clock();
        const extra = {};
        if (body && body.reason !== undefined) extra.reason = cleanReason(body.reason);
        if (body && isInt(body.exitCode)) extra.exitCode = body.exitCode;
        const ok = (changed) => ({ status: 'ok', state: rec.state, changed });
        const conflict = () => ({ status: 'conflict', state: cur });

        if (to === 'started') {
            if (cur === 'started' || cur === 'running') return ok(false);   // running = benign race with the watcher
            if (cur !== 'delivered') return conflict();
            move(rec, 'started', now, extra);
            persist();
            return ok(true);
        }
        if (to === 'completed' || to === 'failed') {
            if (cur === to) return ok(false);
            const legal = to === 'completed' ? (cur === 'started' || cur === 'running')
                : (cur === 'delivered' || cur === 'started' || cur === 'running');
            if (legal) {
                // XACA-1441-026: an agent `failed` report with reason `runner-lost` means the listener died
                // (VM reboot, SIGTERM). Its registration must be DELETEd even when a job WAS bound: per
                // GitHub's documentation an ephemeral self-hosted runner that stops connecting is only
                // auto-removed after about 1 day, so a lost JIT runner's registration would linger.
                // DOCUMENTATION-SOURCED, not measured by our spike. A 422 (runner still busy) retries on the
                // next sweep and is never forced; a 404 counts as success; attempts are capped.
                const runnerLost = to === 'failed' && extra.reason === 'runner-lost';
                if ((!rec.boundJob || runnerLost) && rec.cleanup === 'none') { rec.cleanup = 'needed'; rec.cleanupAttempts = 0; }
                move(rec, to, now, extra);
                persist();
                return ok(true);
            }
            if (cur === 'expired' || cur === 'lost') {                  // late truth beats our presumption
                move(rec, to, now, extra);
                persist();
                return ok(true);
            }
            return conflict();
        }
        if (to === 'cancelled') {
            if (cur === 'cancelled' || cur === 'expired') {             // acknowledgement of cancel[]
                const changed = !rec.killAcked;
                rec.killAcked = true;
                if (changed) { audit('state', auditFields(rec, { from: cur, to: cur, reason: 'kill-acked' })); persist(); }
                return ok(changed);
            }
            if (cur === 'delivered' || cur === 'started') {
                rec.killNeeded = false;
                rec.cleanup = 'needed'; rec.cleanupAttempts = 0;
                move(rec, 'cancelled', now, extra);
                persist();
                return ok(true);
            }
            return conflict();                                           // the agent never cancels a running job
        }
        return conflict();
    }

    // -------------------------------------------------------- job binding
    /**
     * Watcher event hook (A2). Bind by runner_name only, after GitHub reports pickup.
     * Writes a `wrong-job-pickup` audit row when the bound job is not the intended one.
     * @returns {object|null} the bound assignment view, or null when nothing matched
     */
    function bindJob(rec, change) {
        if (!rec || !isStr(rec.runnerName) || rec.runnerName === '') return null;
        if (change !== 'pickup' && change !== 'in_progress') return null;
        const repoFull = `${rec.owner}/${rec.repo}`.toLowerCase();
        let hit = null;
        for (const a of records.values()) {
            if (a.runnerName === rec.runnerName && a.repo.toLowerCase() === repoFull) { hit = a; break; }
        }
        if (!hit || hit.boundJob || (hit.state !== 'delivered' && hit.state !== 'started')) return null;
        hit.boundJob = sanitizeJob({ id: rec.jobId, name: rec.name, runId: rec.runId });
        const wrong = !hit.intendedJob || hit.intendedJob.id !== hit.boundJob.id;
        move(hit, 'running', clock());
        if (wrong) {
            audit('wrong-job-pickup', auditFields(hit, {
                reason: `intended:${hit.intendedJob ? hit.intendedJob.id : 'none'} bound:${hit.boundJob.id}`,
            }));
        }
        persist();
        return view(hit);
    }

    // -------------------------------------------------------------- sweep
    async function cleanupOne(rec) {
        rec.cleanupAttempts += 1;
        const [owner, repo] = rec.repo.split('/');
        try {
            const r = await github.deleteRunner({ owner, repo, runnerId: rec.runnerId });
            rec.cleanup = 'done';
            audit('deregister', auditFields(rec, { ok: true, httpStatus: r && r.alreadyGone ? 404 : 204, reason: rec.reason }));
            return 'deleted';
        } catch (e) {
            const status = e && e.status;
            const busy = status === 422;
            if (rec.cleanupAttempts >= T.maxCleanupAttempts) {
                rec.cleanup = 'failed';
                audit('deregister', auditFields(rec, { ok: false, httpStatus: isInt(status) ? status : null, reason: 'giving-up' }));
                return 'failed';
            }
            if (rec.cleanupAttempts === 1) {
                audit('deregister', auditFields(rec, { ok: false, httpStatus: isInt(status) ? status : null, reason: busy ? 'busy-retry' : 'retry' }));
            }
            return 'retry';
        }
    }

    /**
     * Apply timeouts, then DELETE every registration owed (never forced: 422 retries).
     * Called by the dispatcher at the start of each tick. Re-entrant calls share one run.
     */
    function sweep() {
        if (sweeping) return sweeping;
        const run = (async () => {
            const now = clock();
            const expired = expireDue(now);
            const stats = { expired, deleted: 0, retry: 0, failed: 0 };
            for (const rec of [...records.values()]) {
                if (!TERMINAL.has(rec.state) || rec.cleanup !== 'needed') continue;
                const r = await cleanupOne(rec);
                stats[r === 'deleted' ? 'deleted' : r === 'failed' ? 'failed' : 'retry']++;
            }
            prune(now);
            persist();
            return stats;
        })();
        // Clear the guard only after `run` is stored and has settled. A `finally` inside the async
        // body runs synchronously when a sweep has nothing to await, i.e. BEFORE the outer
        // assignment, which left `sweeping` pinned to the first result forever (XACA-1441-007).
        sweeping = run;
        const clear = () => { if (sweeping === run) sweeping = null; };
        run.then(clear, clear);
        return run;
    }

    // -------------------------------------------------------------- reads
    /** D5: assignments minted but not yet bound to a job, counted per demand label-set. */
    function outstandingBySet() {
        const m = new Map();
        for (const rec of records.values()) {
            if (rec.state === 'pending' || rec.state === 'delivered' || rec.state === 'started') {
                m.set(rec.labelSet, (m.get(rec.labelSet) || 0) + 1);
            }
        }
        return m;
    }

    const get = (id) => (records.has(id) ? view(records.get(id)) : null);
    const snapshot = () => [...records.values()].map(view).sort((a, b) => (a.createdAt < b.createdAt ? 1 : a.createdAt > b.createdAt ? -1 : 0));

    return {
        load, mint, takeForMachine, cancelListFor, report, bindJob, expireDue, sweep,
        outstandingBySet, get, snapshot, file,
        /** test/diagnostic: whether a config is still held in memory (never returns the value). */
        holdsConfig: (id) => configs.has(id),
    };
}

module.exports = {
    createAssignments, STATES, TERMINAL, DEFAULT_TIMEOUTS, SCHEMA_VERSION, ID_RE, PERSISTED_FIELDS,
    cleanReason, persistable, view,
};
