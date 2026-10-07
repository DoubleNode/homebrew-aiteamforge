//
//  ci-runners-routes.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * CI runner telemetry (XACA-1387-003).
 *
 *   POST /api/ci-runners-push  (ciTelemetryKey: per-host `fct_` key, XACA-1422)
 *        NOT the fleet tier: the fleet token is rejected here, and a key only
 *        works when body.machine is the machine it was minted for.
 *        Push payload: fleet-monitor/docs/DATA_SCHEMA.md § "CI Runner Telemetry".
 *   GET  /api/ci-runners       (open, like /api/fleet)
 *        Response: fleet-monitor/docs/CI-RUNNERS-API-CONTRACT.md (v1, normative --
 *        authored by the consumer, XACA-1388). buildContractResponse() is the
 *        ONLY place that shape is produced (XACA-1387-012/016).
 *
 * Validation is split on purpose: top-level problems reject the whole push
 * (400, nothing stored); one bad jobs[] record is DROPPED and reported in
 * jobsRejected[] so a single malformed job can never freeze host/runner state.
 * Stored records are built by ALLOWLIST copy -- an unknown field is never
 * persisted and never served back.
 *
 * Persistence: in-memory Map keyed by machine, flushed to data/ci-runners.json
 * by save() (server.js calls it on its periodic save + shutdown) with a
 * temp+rename write. A missing/corrupt file is logged and the store starts
 * empty; it never crashes boot. load() re-validates every stored record with
 * the push validators and drops (and logs) what fails (XACA-1387-015).
 *
 * Cycle/today totals (XACA-1387-020, design XACA-1427): the job list above is
 * capped at MAX_JOBS_PER_MACHINE, so totals are NOT summed from it. Every
 * accepted job is counted once into a persisted per-machine, per-UTC-day
 * rollup (data/ci-runner-rollups.json, see createRollupStore). Each day keeps
 * a ledger of the job ids it counted, so a re-sent window, a restart, or a
 * re-send of a job already evicted from the list can never count twice.
 */

const fs   = require('fs');
const path = require('path');

const { requireCiTelemetryKey } = require('./ci-pool-routes');

const SCHEMA_VERSION = 1;          // push payload + store file
const CONTRACT_SCHEMA_VERSION = 1; // GET /api/ci-runners response
const MAX_BODY_BYTES = 64 * 1024;
const MAX_RUNNERS = 16;
const MAX_JOBS_PER_PUSH = 50;
const MAX_JOBS_PER_MACHINE = 500;
const MAX_MACHINES = 64;           // XACA-1387-014
const MAX_LABELS = 32;
const STALE_THRESHOLD_MS = 180 * 1000;   // same value as OFFLINE_THRESHOLD_MS in server.js
const OFFLINE_THRESHOLD_MS = 600 * 1000; // contract offlineAfterSeconds
const DEFAULT_JOBS_LIMIT = 50;
const MAX_JOBS_LIMIT = 500;
const MAX_MINUTES = 7200;
const MAX_DURATION_SECONDS = 432000; // 5 days: GitHub's self-hosted job ceiling
// Hosted-equivalent billing multipliers (XACA-1190). An unknown OS counts at
// the Linux rate: a lower bound, never an inflated "minutes saved" claim.
const OS_MULTIPLIER = { Linux: 1, macOS: 10 };

// Rollups (XACA-1387-020). See createRollupStore() for the rules.
const ROLLUP_SCHEMA_VERSION = 1;
const ROLLUP_FILE_NAME = 'ci-runner-rollups.json';
const ROLLUP_RETAIN_MONTHS = 13;  // current UTC calendar month + the 12 before it
const LEDGER_DAYS = 35;           // > 31: every day of the current cycle keeps its id ledger
const MAX_IDS_PER_DAY = 3000;     // per machine per day; beyond it jobs are NOT counted (see recordJob)
const FUTURE_DAY_TOLERANCE = 1;   // days: reporter clock skew allowed past the server's today
const DAY_MS = 86400 * 1000;
const DAY_RE = /^\d{4}-\d{2}-\d{2}$/;

const MACHINE_ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const HOSTNAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$/;
const RUNNER_NAME_RE = /^[A-Za-z0-9._-]+$/;
const JOB_ID_RE = /^[A-Za-z0-9._:-]+$/;
const REPO_RE = /^[A-Za-z0-9-]{1,39}\/[A-Za-z0-9._-]{1,100}$/;
const RUN_URL_RE = /^https:\/\/github\.com\/[A-Za-z0-9-]{1,39}\/[A-Za-z0-9._-]{1,100}\/actions\/runs\/[0-9]+(\/attempts\/[0-9]+)?(\/job\/[0-9]+)?$/;
// Same family as RUN_URL_RE, but the /job/<digits> segment is mandatory.
const JOB_URL_RE = /^https:\/\/github\.com\/[A-Za-z0-9-]{1,39}\/[A-Za-z0-9._-]{1,100}\/actions\/runs\/[0-9]+(\/attempts\/[0-9]+)?\/job\/[0-9]+$/;
const ISO_UTC_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/;
// eslint-disable-next-line no-control-regex
const CONTROL_RE = /[\x00-\x1f\x7f]/;

const SERVICE_STATES = ['up', 'down', 'unknown'];
const VM_STATES = ['running', 'stopped', 'broken', 'unknown'];
const RESULTS = ['success', 'failure', 'cancelled', 'unknown'];
const RUNNER_OSES = ['Linux', 'macOS'];

class ValidationError extends Error {
    constructor(field, message) {
        super(message || `invalid field: ${field}`);
        this.field = field;
    }
}

/** A NEW machine arrived while the store is full of live machines (XACA-1387-014). */
class CapacityError extends Error {}

const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const isInt0 = (v) => Number.isInteger(v) && v >= 0;
const absent = (v) => v === undefined || v === null;

function cleanStr(v, max) {
    return typeof v === 'string' && v.length > 0 && v.length <= max && !CONTROL_RE.test(v);
}

function isIsoUtc(v) {
    return typeof v === 'string' && v.length <= 40 && ISO_UTC_RE.test(v) && !Number.isNaN(Date.parse(v));
}

// ---------------------------------------------------------------------------
// Validators. Each returns an allowlist-copied record or throws ValidationError.
// The same validators rebuild records on load() (XACA-1387-015).
// ---------------------------------------------------------------------------

/** Optional string field: undefined/null -> null; otherwise must be clean. */
function optStr(v, max, field) {
    if (absent(v)) return null;
    if (!cleanStr(v, max)) throw new ValidationError(field, `bad ${field.split('.').pop()}`);
    return v;
}

/** Job ref / completed-job base fields shared by currentJob and jobs[]. */
function copyJobCommon(j, where) {
    if (!isObj(j)) throw new ValidationError(where, `${where} must be an object`);
    if (!cleanStr(j.id, 128) || !JOB_ID_RE.test(j.id)) throw new ValidationError(`${where}.id`, 'bad id');
    if (!cleanStr(j.workflow, 128)) throw new ValidationError(`${where}.workflow`, 'bad workflow');
    if (!cleanStr(j.jobName, 128)) throw new ValidationError(`${where}.jobName`, 'bad jobName');
    if (!cleanStr(j.repo, 140) || !REPO_RE.test(j.repo)) throw new ValidationError(`${where}.repo`, 'bad repo');
    if (j.runUrl !== null && !(typeof j.runUrl === 'string' && j.runUrl.length <= 300 && RUN_URL_RE.test(j.runUrl))) {
        throw new ValidationError(`${where}.runUrl`, 'bad runUrl');
    }
    if (!isIsoUtc(j.startedAt)) throw new ValidationError(`${where}.startedAt`, 'bad startedAt');
    // Optional (XACA-1387-016): older reporters omit them; absent is stored as null.
    const branch = optStr(j.branch, 255, `${where}.branch`);
    const event = optStr(j.event, 64, `${where}.event`);
    let jobUrl = null;
    if (!absent(j.jobUrl)) {
        if (!(typeof j.jobUrl === 'string' && j.jobUrl.length <= 300 && JOB_URL_RE.test(j.jobUrl))) {
            throw new ValidationError(`${where}.jobUrl`, 'bad jobUrl');
        }
        jobUrl = j.jobUrl;
    }
    return {
        id: j.id, workflow: j.workflow, jobName: j.jobName, repo: j.repo, runUrl: j.runUrl,
        startedAt: j.startedAt, branch, event, jobUrl,
    };
}

/** A completed jobs[] record. Throws ValidationError (caller drops + reports it). */
function validateJob(j) {
    const out = copyJobCommon(j, 'job');
    if (!cleanStr(j.runner, 64) || !RUNNER_NAME_RE.test(j.runner)) throw new ValidationError('job.runner', 'bad runner');
    if (!isIsoUtc(j.endedAt)) throw new ValidationError('job.endedAt', 'bad endedAt');
    if (Date.parse(j.endedAt) < Date.parse(j.startedAt)) throw new ValidationError('job.endedAt', 'endedAt before startedAt');
    if (!RESULTS.includes(j.result)) throw new ValidationError('job.result', 'bad result');
    if (typeof j.minutes !== 'number' || !Number.isFinite(j.minutes) || j.minutes < 0 || j.minutes > MAX_MINUTES) {
        throw new ValidationError('job.minutes', 'bad minutes');
    }
    let durationSeconds = null;
    if (!absent(j.durationSeconds)) {
        if (!isInt0(j.durationSeconds) || j.durationSeconds > MAX_DURATION_SECONDS) {
            throw new ValidationError('job.durationSeconds', 'bad durationSeconds');
        }
        durationSeconds = j.durationSeconds;
    }
    return { ...out, runner: j.runner, endedAt: j.endedAt, result: j.result, minutes: j.minutes, durationSeconds };
}

function validateRunner(r, i) {
    const where = `runners[${i}]`;
    if (!isObj(r)) throw new ValidationError(where, 'runner must be an object');
    if (!cleanStr(r.name, 64) || !RUNNER_NAME_RE.test(r.name)) throw new ValidationError(`${where}.name`, 'bad name');
    if (!SERVICE_STATES.includes(r.serviceState)) throw new ValidationError(`${where}.serviceState`, 'bad serviceState');
    if (!Array.isArray(r.labels) || r.labels.length > MAX_LABELS) throw new ValidationError(`${where}.labels`, 'bad labels');
    for (const l of r.labels) {
        if (!cleanStr(l, 64)) throw new ValidationError(`${where}.labels`, 'bad label');
    }
    if (!absent(r.os) && !RUNNER_OSES.includes(r.os)) throw new ValidationError(`${where}.os`, 'bad os');
    if (!absent(r.busy) && typeof r.busy !== 'boolean') throw new ValidationError(`${where}.busy`, 'bad busy');
    let currentJob = null;
    // currentJob stays REQUIRED (null = idle); only the new fields are optional.
    if (r.currentJob !== null) currentJob = copyJobCommon(r.currentJob, `${where}.currentJob`);
    return {
        name: r.name, serviceState: r.serviceState, labels: r.labels.slice(), currentJob,
        os: absent(r.os) ? null : r.os, busy: absent(r.busy) ? null : r.busy,
    };
}

function validateHost(h) {
    if (!isObj(h)) throw new ValidationError('host', 'host must be an object');
    if (!isInt0(h.uptimeSeconds)) throw new ValidationError('host.uptimeSeconds', 'bad uptimeSeconds');
    const out = { uptimeSeconds: h.uptimeSeconds };
    if (h.disk !== undefined) {
        const d = h.disk;
        if (!isObj(d) || !cleanStr(d.path, 256) || !isInt0(d.totalBytes) || !isInt0(d.freeBytes)) {
            throw new ValidationError('host.disk', 'bad disk');
        }
        out.disk = { path: d.path, totalBytes: d.totalBytes, freeBytes: d.freeBytes };
    }
    if (!absent(h.hostname)) {
        if (typeof h.hostname !== 'string' || !HOSTNAME_RE.test(h.hostname)) {
            throw new ValidationError('host.hostname', 'bad hostname');
        }
        out.hostname = h.hostname;
    }
    return out;
}

function validateVm(v) {
    if (v === null) return null;
    if (!isObj(v) || !cleanStr(v.name, 64) || !VM_STATES.includes(v.state)) throw new ValidationError('vm', 'bad vm');
    return { name: v.name, state: v.state };
}

/**
 * Validate a whole push. Returns { machine, record, jobs, jobsRejected } where
 * record holds the replaceable fields and jobs the validated job records.
 * Throws ValidationError for any top-level problem.
 */
function validatePush(body) {
    if (!isObj(body)) throw new ValidationError('body', 'body must be a JSON object');
    if (body.schema_version !== SCHEMA_VERSION) throw new ValidationError('schema_version', `schema_version must be ${SCHEMA_VERSION}`);
    if (typeof body.machine !== 'string' || !MACHINE_ID_RE.test(body.machine)) throw new ValidationError('machine', 'bad machine id');
    if (!isIsoUtc(body.reportedAt)) throw new ValidationError('reportedAt', 'bad reportedAt');
    if (!cleanStr(body.reporterVersion, 32)) throw new ValidationError('reporterVersion', 'bad reporterVersion');
    const host = validateHost(body.host);
    if (!('vm' in body)) throw new ValidationError('vm', 'vm is required (null when the host has no VM)');
    const vm = validateVm(body.vm);
    if (!Array.isArray(body.runners)) throw new ValidationError('runners', 'runners must be an array');
    if (body.runners.length > MAX_RUNNERS) throw new ValidationError('runners', `at most ${MAX_RUNNERS} runners`);
    const runners = body.runners.map(validateRunner);
    const names = new Set();
    for (const r of runners) {
        if (names.has(r.name)) throw new ValidationError('runners', `duplicate runner name ${r.name}`);
        names.add(r.name);
    }
    if (!Array.isArray(body.jobs)) throw new ValidationError('jobs', 'jobs must be an array');
    if (body.jobs.length > MAX_JOBS_PER_PUSH) throw new ValidationError('jobs', `at most ${MAX_JOBS_PER_PUSH} jobs`);

    const jobs = [];
    const jobsRejected = [];
    for (const j of body.jobs) {
        try { jobs.push(validateJob(j)); }
        catch (e) {
            if (!(e instanceof ValidationError)) throw e;
            const id = isObj(j) && typeof j.id === 'string' && j.id.length <= 128 && !CONTROL_RE.test(j.id) ? j.id : null;
            jobsRejected.push({ id, reason: e.message });
        }
    }
    return {
        machine: body.machine,
        record: { reportedAt: body.reportedAt, reporterVersion: body.reporterVersion, host, vm, runners },
        jobs,
        jobsRejected,
    };
}

// ---------------------------------------------------------------------------
// OS resolution (contract runners[].os / recentJobs[].os)
// ---------------------------------------------------------------------------

/** Derive "Linux" | "macOS" | null from labels, then the runner name. */
function deriveOs(name, labels) {
    for (const l of Array.isArray(labels) ? labels : []) {
        const v = String(l).toLowerCase();
        if (v === 'linux') return 'Linux';
        if (v === 'macos' || v === 'osx') return 'macOS';
    }
    const n = typeof name === 'string' ? name.toLowerCase() : '';
    if (/(^|[^a-z])linux([^a-z]|$)/.test(n)) return 'Linux';
    if (/(^|[^a-z])(macos|osx|mac)([^a-z]|$)/.test(n)) return 'macOS';
    return null;
}

function runnerOs(r) {
    return r && RUNNER_OSES.includes(r.os) ? r.os : deriveOs(r && r.name, r && r.labels);
}

// ---------------------------------------------------------------------------
// Load-time record rebuild (XACA-1387-015)
// ---------------------------------------------------------------------------

/**
 * Rebuild one stored machine record through the push validators. Returns
 * { rec, droppedRunners, droppedJobs } or null when the machine itself is
 * unusable. Never throws.
 */
function rebuildStoredRecord(id, raw) {
    if (!isObj(raw) || !MACHINE_ID_RE.test(id)) return null;
    if (!isIsoUtc(raw.receivedAt) || !isIsoUtc(raw.reportedAt) || !cleanStr(raw.reporterVersion, 32)) return null;
    if (!Array.isArray(raw.runners) || !Array.isArray(raw.jobs)) return null;
    let host; let vm;
    try {
        host = validateHost(raw.host);
        vm = validateVm(raw.vm === undefined ? null : raw.vm);
    } catch (e) {
        if (e instanceof ValidationError) return null;
        throw e;
    }
    let droppedRunners = 0;
    const runners = [];
    const names = new Set();
    raw.runners.slice(0, MAX_RUNNERS).forEach((r, i) => {
        try {
            const v = validateRunner(r, i);
            if (names.has(v.name)) { droppedRunners++; return; }
            names.add(v.name);
            runners.push(v);
        } catch (e) {
            if (!(e instanceof ValidationError)) throw e;
            droppedRunners++;
        }
    });
    droppedRunners += Math.max(0, raw.runners.length - MAX_RUNNERS);
    let droppedJobs = 0;
    const jobs = [];
    const seen = new Set();
    for (const j of raw.jobs) {
        try {
            const v = validateJob(j);
            if (seen.has(v.id) || !isIsoUtc(j.firstSeenAt)) { droppedJobs++; continue; }
            seen.add(v.id);
            jobs.push({ ...v, os: RUNNER_OSES.includes(j.os) ? j.os : null, firstSeenAt: j.firstSeenAt });
        } catch (e) {
            if (!(e instanceof ValidationError)) throw e;
            droppedJobs++;
        }
    }
    jobs.sort((a, b) => Date.parse(b.endedAt) - Date.parse(a.endedAt));
    droppedJobs += Math.max(0, jobs.length - MAX_JOBS_PER_MACHINE);
    return {
        rec: {
            machine: id, receivedAt: raw.receivedAt, reportedAt: raw.reportedAt, reporterVersion: raw.reporterVersion,
            host, vm, runners, jobs: jobs.slice(0, MAX_JOBS_PER_MACHINE),
        },
        droppedRunners,
        droppedJobs,
    };
}

// ---------------------------------------------------------------------------
// Contract projection (XACA-1387-012/016) -- pure; no clock, no I/O.
// ---------------------------------------------------------------------------

const VM_STATUS = { running: 'Running', stopped: 'Stopped', broken: 'Broken', unknown: 'Unknown' };
const SERVICE = { up: 'online', down: 'offline', unknown: 'unknown' };

function utcDay(ms) { return new Date(ms).toISOString().slice(0, 10); }

function durationOf(j) {
    if (isInt0(j.durationSeconds)) return j.durationSeconds;
    return Math.max(0, Math.round((Date.parse(j.endedAt) - Date.parse(j.startedAt)) / 1000));
}

/** GitHub per-job billing rounding. */
function billedMinutes(durationSeconds) { return Math.ceil(durationSeconds / 60); }

/**
 * THE one place a job's billed minutes, OS and hosted-equivalent minutes are
 * computed -- used by both recentJobs[] (contractJob) and the rollups, so the
 * list and the totals cannot drift. OS: the job's own os (resolved at
 * receipt), else the runner's current OS, else derived from the runner name,
 * else null (counted at x1: a lower bound, never an inflated claim).
 */
function jobAccounting(j, osByRunner) {
    const durationSeconds = durationOf(j);
    const minutes = billedMinutes(durationSeconds);
    const os = RUNNER_OSES.includes(j.os) ? j.os : ((osByRunner && osByRunner.get(j.runner)) || deriveOs(j.runner, null));
    return {
        durationSeconds,
        minutes,
        os,
        hostedEquivalentMinutes: minutes * (OS_MULTIPLIER[os] || 1),
        day: utcDay(Date.parse(j.endedAt)), // contract finishedAt == stored endedAt
    };
}

/**
 * Split a stored runUrl into the contract's run link + job link. Our push
 * runUrl may already point at a job (".../runs/N/job/M"); the contract's runUrl
 * is the run and jobUrl the job. An explicit pushed jobUrl wins.
 */
function splitUrls(j) {
    const m = typeof j.runUrl === 'string' ? /^(.*)\/job\/[0-9]+$/.exec(j.runUrl) : null;
    return {
        runUrl: m ? m[1] : (j.runUrl === undefined ? null : j.runUrl),
        jobUrl: j.jobUrl || (m ? j.runUrl : null),
    };
}

function contractCurrentJob(cj) {
    if (!cj) return null;
    const urls = splitUrls(cj);
    return {
        // id: string (runner logs carry a GUID). Contract amendment, XACA-1387.
        id: cj.id, workflow: cj.workflow, job: cj.jobName, repo: cj.repo,
        branch: cj.branch === undefined ? null : cj.branch,
        startedAt: cj.startedAt, runUrl: urls.runUrl, jobUrl: urls.jobUrl,
    };
}

function contractJob(j, osByRunner) {
    const { durationSeconds, minutes, os } = jobAccounting(j, osByRunner);
    const urls = splitUrls(j);
    return {
        id: j.id,
        runner: j.runner,
        os,
        workflow: j.workflow,
        job: j.jobName,
        repo: j.repo,
        branch: j.branch === undefined ? null : j.branch,
        event: j.event === undefined ? null : j.event,
        startedAt: j.startedAt,
        finishedAt: j.endedAt,
        durationSeconds,
        minutes,
        result: j.result,
        runUrl: urls.runUrl,
        jobUrl: urls.jobUrl,
    };
}

/**
 * Build the GET /api/ci-runners v1 response (CI-RUNNERS-API-CONTRACT.md).
 *
 * records : stored machine records (any order)
 * now     : Date -- the server clock; generatedAt and the UTC day/month
 *           windows key off it. Staleness itself is derived by the UI from
 *           generatedAt - lastReportAt (contract rule 1); the server does not
 *           pre-judge it and does not drop stale machines from anything.
 *
 * summary / runners[].today / cycle: from the per-day rollups
 * (opts.rollups, a createRollupStore()), so they count EVERY job the machine
 * ever pushed in the window -- not only the MAX_JOBS_PER_MACHINE still in the
 * list, and not only the jobsLimit returned (XACA-1387-020). Nothing is
 * excluded for staleness -- the fixtures carry identical summaries across
 * healthy/stale/offline. null when no machine has ever reported (empty
 * fixture), so the UI shows "—", not a false 0.
 *
 * Without opts.rollups (pure callers/tests) an ephemeral rollup is built from
 * the records' stored jobs through the SAME recordJob() path, so the two can
 * never disagree on how a job is counted. The store always passes its own.
 */
function buildContractResponse(records, now, { jobsLimit = DEFAULT_JOBS_LIMIT, rollups = null } = {}) {
    const nowMs = now.getTime();
    const today = utcDay(nowMs);
    const month = today.slice(0, 7);
    const d = new Date(nowMs);
    const cycleEnd = utcDay(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 0));
    const summary = {
        today: { jobs: 0, minutes: 0, hostedEquivalentMinutes: 0 },
        cycle: { jobs: 0, minutes: 0, hostedEquivalentMinutes: 0, start: `${month}-01`, end: cycleEnd },
    };
    let ru = rollups;
    if (!ru) {
        ru = createRollupStore(null);
        ru.backfill(records, nowMs);
    }

    const machines = [...records].sort((a, b) => (a.machine < b.machine ? -1 : a.machine > b.machine ? 1 : 0)).map((rec) => {
        const osByRunner = new Map(rec.runners.map((r) => [r.name, runnerOs(r)]));
        const projected = rec.jobs.map((j) => contractJob(j, osByRunner));
        const t = ru.totals(rec.machine, today, month);
        for (const k of ['today', 'cycle']) {
            summary[k].jobs += t[k].jobs;
            summary[k].minutes += t[k].minutes;
            summary[k].hostedEquivalentMinutes += t[k].hostedEquivalentMinutes;
        }
        const runnerWindow = (w, name) => {
            const x = t[w].runners.get(name);
            return x ? { jobs: x.jobs, minutes: x.minutes } : { jobs: 0, minutes: 0 };
        };
        const disk = rec.host && rec.host.disk ? { freeBytes: rec.host.disk.freeBytes, totalBytes: rec.host.disk.totalBytes } : null;
        return {
            machine: rec.machine,
            hostname: rec.host && rec.host.hostname ? rec.host.hostname : null,
            lastReportAt: rec.receivedAt,
            uptimeSeconds: rec.host && isInt0(rec.host.uptimeSeconds) ? rec.host.uptimeSeconds : null,
            vm: rec.vm ? { name: rec.vm.name, status: VM_STATUS[rec.vm.state] || 'Unknown', uptimeSeconds: null } : null,
            disk,
            runners: rec.runners.map((r) => ({
                name: r.name,
                os: osByRunner.get(r.name),
                labels: r.labels.slice(),
                service: SERVICE[r.serviceState] || 'unknown',
                busy: typeof r.busy === 'boolean' ? r.busy : r.currentJob != null,
                uptimeSeconds: null,
                currentJob: contractCurrentJob(r.currentJob),
                today: runnerWindow('today', r.name),
                cycle: runnerWindow('cycle', r.name),
            })),
            recentJobs: projected.slice(0, jobsLimit),
        };
    });

    return {
        schemaVersion: CONTRACT_SCHEMA_VERSION,
        generatedAt: now.toISOString(),
        staleAfterSeconds: STALE_THRESHOLD_MS / 1000,
        offlineAfterSeconds: OFFLINE_THRESHOLD_MS / 1000,
        // Needs server-side GitHub API access to read the XACA-1386 repo
        // variables; out of scope. null = "not reported" (contract rule 3).
        fallback: null,
        summary: machines.length ? summary : null,
        machines,
    };
}

// ---------------------------------------------------------------------------
// Persistence helpers
// ---------------------------------------------------------------------------

/**
 * Remove crash-orphaned "<file>.tmp-*" left by an interrupted atomic write
 * (XACA-1387-017). The pattern must keep matching .gitignore and BOTH
 * sync-tap.sh exclusion lists.
 */
function sweepTempFiles(file) {
    const dir = path.dirname(file);
    const prefix = `${path.basename(file)}.tmp-`;
    let names;
    try { names = fs.readdirSync(dir); } catch { return; }
    for (const n of names) {
        if (!n.startsWith(prefix)) continue;
        try {
            fs.unlinkSync(path.join(dir, n));
            console.log(`[CI-RUNNERS] removed orphaned temp file ${n}`);
        } catch (error) {
            console.error(`[CI-RUNNERS] could not remove orphaned temp file ${n}:`, error.message);
        }
    }
}

/** temp + rename; the temp name is "<file>.tmp-<pid>" (see sweepTempFiles). */
function writeJsonAtomic(file, obj) {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    const tmp = `${file}.tmp-${process.pid}`;
    fs.writeFileSync(tmp, JSON.stringify(obj, null, 2));
    fs.renameSync(tmp, file);
}

// ---------------------------------------------------------------------------
// Rollups (XACA-1387-020, design XACA-1427)
// ---------------------------------------------------------------------------

/**
 * Persisted per-machine, per-UTC-day totals -- the source of summary.today /
 * cycle and runners[].today / cycle.
 *
 *   machine -> 'YYYY-MM-DD' (UTC day of endedAt == contract finishedAt) ->
 *     { jobs, minutes, hostedEquivalentMinutes, runners: {name: {jobs, minutes}},
 *       ids: [job ids counted in this day] | null (sealed), truncated: bool }
 *
 * EXACTLY ONCE. A job id is counted at most once per machine, ever (within
 * the ledger window), independent of the capped job list:
 *   - the machine-wide id index (rebuilt from the per-day ids on load) is
 *     checked first, so a re-sent rolling window, a restart, and a re-send of
 *     an id the job list already EVICTED are all duplicates;
 *   - FIRST WRITE WINS: an id re-sent with a different endedAt stays counted
 *     in the day it was first counted in (the job list dedupes the same way);
 *   - a LATE arrival (pushed days after it finished) is counted in its own day.
 *
 * BOUNDS (every one fails toward UNDER-counting, never double counting --
 * the reporter re-sends its window every push, so "count it anyway" would
 * inflate the total on every push):
 *   - ids live with their day bucket. Days older than LEDGER_DAYS are SEALED:
 *     their ids are dropped and their totals frozen; a job whose day is older
 *     than LEDGER_DAYS is not counted (it cannot be deduped, and it cannot
 *     touch the current cycle anyway).
 *   - at most MAX_IDS_PER_DAY ids per machine per day. Past that the day is
 *     marked truncated, logged once, and further NEW ids that day are not
 *     counted. Worst case held: 64 machines x 36 days x 3000 ids.
 *   - a day more than FUTURE_DAY_TOLERANCE past the server's today is not
 *     counted (a skewed/hostile clock cannot mint unbounded buckets).
 *   - buckets are kept for ROLLUP_RETAIN_MONTHS calendar months (the current
 *     one + the 12 before), then pruned.
 *   - an evicted machine's rollups are dropped with it (dropMachine).
 *
 * file === null -> in-memory only (pure buildContractResponse callers).
 */
function createRollupStore(file, { maxIdsPerDay = MAX_IDS_PER_DAY } = {}) {
    const machines = new Map(); // machine -> Map(day -> bucket)
    const index = new Map();    // machine -> Map(id -> day), every unsealed id

    function bounds(nowMs) {
        const d = new Date(nowMs);
        return {
            keepFromMonth: utcDay(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() - (ROLLUP_RETAIN_MONTHS - 1), 1)).slice(0, 7),
            ledgerFromDay: utcDay(nowMs - LEDGER_DAYS * DAY_MS),
            maxDay: utcDay(nowMs + FUTURE_DAY_TOLERANCE * DAY_MS),
        };
    }

    const newBucket = () => ({
        jobs: 0, minutes: 0, hostedEquivalentMinutes: 0, runners: new Map(), ids: new Set(), truncated: false,
    });

    function idxFor(machine) {
        let m = index.get(machine);
        if (!m) { m = new Map(); index.set(machine, m); }
        return m;
    }

    /**
     * Count one job. Returns 'counted' | 'duplicate' | 'sealed' | 'future' |
     * 'truncated'. Only 'counted' changes anything.
     */
    function recordJob(machine, job, osByRunner, nowMs) {
        const a = jobAccounting(job, osByRunner);
        const b = bounds(nowMs);
        if (a.day < b.ledgerFromDay) return 'sealed';
        if (a.day > b.maxDay) return 'future';
        const idx = index.get(machine);
        if (idx && idx.has(job.id)) return 'duplicate';
        let days = machines.get(machine);
        if (!days) { days = new Map(); machines.set(machine, days); }
        let bucket = days.get(a.day);
        if (!bucket) { bucket = newBucket(); days.set(a.day, bucket); }
        if (bucket.ids === null) return 'sealed';
        if (bucket.ids.size >= maxIdsPerDay) {
            if (!bucket.truncated) {
                bucket.truncated = true;
                console.error(`[CI-RUNNERS] rollup ${machine} ${a.day}: ${maxIdsPerDay} job ids reached; further jobs that day are NOT counted (totals are a lower bound)`);
            }
            return 'truncated';
        }
        bucket.ids.add(job.id);
        idxFor(machine).set(job.id, a.day);
        bucket.jobs++;
        bucket.minutes += a.minutes;
        bucket.hostedEquivalentMinutes += a.hostedEquivalentMinutes;
        const r = bucket.runners.get(job.runner) || { jobs: 0, minutes: 0 };
        r.jobs++; r.minutes += a.minutes;
        bucket.runners.set(job.runner, r);
        return 'counted';
    }

    /**
     * Count every stored job of every record (first deploy, a lost/corrupt
     * rollup file, or a crash between the two saves). Idempotent through the
     * ledger, so it runs on every load. Returns the number newly counted.
     */
    function backfill(records, nowMs) {
        let n = 0;
        for (const rec of records) {
            const osByRunner = new Map((rec.runners || []).map((r) => [r.name, runnerOs(r)]));
            for (const j of rec.jobs || []) {
                if (recordJob(rec.machine, j, osByRunner, nowMs) === 'counted') n++;
            }
        }
        return n;
    }

    function forgetIds(machine, bucket) {
        const idx = index.get(machine);
        if (!idx || !bucket.ids) return;
        for (const id of bucket.ids) idx.delete(id);
    }

    /** Seal days past the ledger window; drop days past retention. */
    function prune(nowMs, only = null) {
        const b = bounds(nowMs);
        for (const [machine, days] of machines) {
            if (only !== null && machine !== only) continue;
            for (const [day, bucket] of days) {
                if (day.slice(0, 7) < b.keepFromMonth) {
                    forgetIds(machine, bucket);
                    days.delete(day);
                } else if (day < b.ledgerFromDay && bucket.ids !== null) {
                    forgetIds(machine, bucket);
                    bucket.ids = null;
                }
            }
            if (days.size === 0) { machines.delete(machine); index.delete(machine); }
        }
    }

    function dropMachine(machine) {
        machines.delete(machine);
        index.delete(machine);
    }

    /**
     * Keep at most MAX_MACHINES machines: machines in `keep` (the job store)
     * always stay; orphans (e.g. a stored machine record dropped as malformed)
     * are dropped oldest-newest-day first. Orphans under the cap are kept so a
     * machine that reports again gets its totals back; they age out by prune().
     */
    function capMachines(keep) {
        if (machines.size <= MAX_MACHINES) return;
        const newest = (days) => [...days.keys()].sort().pop() || '';
        const orphans = [...machines.entries()].filter(([m]) => !keep.has(m))
            .sort((x, y) => (newest(x[1]) < newest(y[1]) ? -1 : 1));
        for (const [m] of orphans) {
            if (machines.size <= MAX_MACHINES) break;
            dropMachine(m);
            console.error(`[CI-RUNNERS] rollup machine cap ${MAX_MACHINES}: dropped orphan rollups for '${m}'`);
        }
    }

    /** { today, cycle } each { jobs, minutes, hostedEquivalentMinutes, runners: Map } */
    function totals(machine, today, month) {
        const z = () => ({ jobs: 0, minutes: 0, hostedEquivalentMinutes: 0, runners: new Map() });
        const out = { today: z(), cycle: z() };
        const add = (t, bucket) => {
            t.jobs += bucket.jobs; t.minutes += bucket.minutes; t.hostedEquivalentMinutes += bucket.hostedEquivalentMinutes;
            for (const [name, r] of bucket.runners) {
                const x = t.runners.get(name) || { jobs: 0, minutes: 0 };
                x.jobs += r.jobs; x.minutes += r.minutes;
                t.runners.set(name, x);
            }
        };
        for (const [day, bucket] of machines.get(machine) || []) {
            if (day.slice(0, 7) !== month) continue;
            add(out.cycle, bucket);
            if (day === today) add(out.today, bucket);
        }
        return out;
    }

    /** One stored bucket -> in-memory bucket, or null (logged by caller). */
    function rebuildBucket(day, raw, b, maxIds) {
        if (!DAY_RE.test(day) || Number.isNaN(Date.parse(`${day}T00:00:00Z`)) || utcDay(Date.parse(`${day}T00:00:00Z`)) !== day) return null;
        if (!isObj(raw) || !isInt0(raw.jobs) || !isInt0(raw.minutes) || !isInt0(raw.hostedEquivalentMinutes)) return null;
        // multipliers are 1 or 10, so hosted is bracketed by minutes
        if (raw.hostedEquivalentMinutes < raw.minutes || raw.hostedEquivalentMinutes > raw.minutes * 10) return null;
        if (typeof raw.truncated !== 'boolean' || !isObj(raw.runners)) return null;
        const runners = new Map();
        let rj = 0;
        for (const [name, r] of Object.entries(raw.runners)) {
            if (!cleanStr(name, 64) || !RUNNER_NAME_RE.test(name) || !isObj(r) || !isInt0(r.jobs) || !isInt0(r.minutes)) return null;
            runners.set(name, { jobs: r.jobs, minutes: r.minutes });
            rj += r.jobs;
        }
        if (rj !== raw.jobs) return null;
        let ids = null;
        if (raw.ids === null) {
            // only a day outside the ledger window may be sealed
            if (day >= b.ledgerFromDay) return null;
        } else {
            if (!Array.isArray(raw.ids) || raw.ids.length !== raw.jobs || raw.ids.length > maxIds) return null;
            ids = new Set();
            for (const id of raw.ids) {
                if (!cleanStr(id, 128) || !JOB_ID_RE.test(id) || ids.has(id)) return null;
                ids.add(id);
            }
        }
        return { jobs: raw.jobs, minutes: raw.minutes, hostedEquivalentMinutes: raw.hostedEquivalentMinutes, runners, ids, truncated: raw.truncated };
    }

    /**
     * Load + validate. Missing file -> empty. A file of the wrong shape / bad
     * JSON -> empty, logged. A single malformed bucket (or one whose ids
     * collide with another day's) is dropped, logged. Never throws. The
     * caller then backfill()s from the stored jobs, which re-counts whatever
     * the job list still holds -- so a corrupt rollup file degrades to the
     * job-list totals, never to a 500.
     */
    function load(nowMs) {
        machines.clear(); index.clear();
        if (!file) return;
        sweepTempFiles(file);
        let data;
        try {
            if (!fs.existsSync(file)) {
                console.log('No CI runner rollups file found, rebuilding from stored jobs');
                return;
            }
            data = JSON.parse(fs.readFileSync(file, 'utf8'));
        } catch (error) {
            console.error('Error loading CI runner rollups (rebuilding from stored jobs):', error.message);
            return;
        }
        if (!isObj(data) || data.schema_version !== ROLLUP_SCHEMA_VERSION || !isObj(data.machines)) {
            console.error('CI runner rollups file has unexpected shape, rebuilding from stored jobs');
            return;
        }
        const b = bounds(nowMs);
        for (const [machine, rawDays] of Object.entries(data.machines)) {
            if (!MACHINE_ID_RE.test(machine) || !isObj(rawDays)) {
                console.error(`[CI-RUNNERS] dropped malformed rollups for machine '${MACHINE_ID_RE.test(machine) ? machine : '<bad id>'}'`);
                continue;
            }
            const days = new Map();
            const idx = new Map();
            let dropped = 0;
            for (const day of Object.keys(rawDays).sort()) {
                const bucket = rebuildBucket(day, rawDays[day], b, maxIdsPerDay);
                if (!bucket || (bucket.ids && [...bucket.ids].some((id) => idx.has(id)))) { dropped++; continue; }
                if (bucket.ids) for (const id of bucket.ids) idx.set(id, day);
                days.set(day, bucket);
            }
            if (dropped) console.error(`[CI-RUNNERS] rollups '${machine}': dropped ${dropped} malformed day bucket(s)`);
            if (days.size) { machines.set(machine, days); index.set(machine, idx); }
        }
    }

    function toJSON() {
        const out = {};
        for (const [machine, days] of machines) {
            const o = {};
            for (const day of [...days.keys()].sort()) {
                const bk = days.get(day);
                o[day] = {
                    jobs: bk.jobs, minutes: bk.minutes, hostedEquivalentMinutes: bk.hostedEquivalentMinutes,
                    runners: Object.fromEntries([...bk.runners].map(([n, r]) => [n, { jobs: r.jobs, minutes: r.minutes }])),
                    ids: bk.ids === null ? null : [...bk.ids],
                    truncated: bk.truncated,
                };
            }
            out[machine] = o;
        }
        return { schema_version: ROLLUP_SCHEMA_VERSION, machines: out };
    }

    function save() {
        if (!file) return;
        try { writeJsonAtomic(file, toJSON()); }
        catch (error) { console.error('Error saving CI runner rollups:', error.message); }
    }

    return { load, save, recordJob, backfill, prune, dropMachine, capMachines, totals, toJSON, machines, file };
}

// ---------------------------------------------------------------------------
// Store
// ---------------------------------------------------------------------------

/**
 * opts.rollupFile : default "<dir of file>/ci-runner-rollups.json"
 * opts.clock      : () => Date, default the real clock (tests inject one)
 */
function createCiRunnerStore(file, { rollupFile, clock = () => new Date() } = {}) {
    const machines = new Map();
    const rollups = createRollupStore(rollupFile || path.join(path.dirname(file), ROLLUP_FILE_NAME));

    /** Job list + rollups. The rollups are reconciled against the job list. */
    function load() {
        loadJobs();
        const nowMs = clock().getTime();
        rollups.load(nowMs);
        const n = rollups.backfill(machines.values(), nowMs);
        if (n) console.log(`[CI-RUNNERS] rollups: counted ${n} stored job(s) not yet in the rollup ledger`);
        rollups.prune(nowMs);
        rollups.capMachines(new Set(machines.keys()));
    }

    function loadJobs() {
        sweepTempFiles(file);
        try {
            if (!fs.existsSync(file)) {
                console.log('No CI runners file found, starting fresh');
                return;
            }
            const data = JSON.parse(fs.readFileSync(file, 'utf8'));
            if (!isObj(data) || data.schema_version !== SCHEMA_VERSION || !isObj(data.machines)) {
                console.error('CI runners file has unexpected shape, starting empty');
                return;
            }
            const kept = [];
            for (const [id, raw] of Object.entries(data.machines)) {
                const out = rebuildStoredRecord(id, raw);
                if (!out) {
                    console.error(`[CI-RUNNERS] dropped malformed stored machine '${MACHINE_ID_RE.test(id) ? id : '<bad id>'}'`);
                    continue;
                }
                if (out.droppedRunners || out.droppedJobs) {
                    console.error(`[CI-RUNNERS] machine '${id}': dropped ${out.droppedRunners} malformed runner(s), ${out.droppedJobs} job(s)`);
                }
                kept.push(out.rec);
            }
            // Same cap as live pushes: keep the most recently heard-from.
            kept.sort((a, b) => Date.parse(b.receivedAt) - Date.parse(a.receivedAt));
            if (kept.length > MAX_MACHINES) {
                console.error(`[CI-RUNNERS] store holds ${kept.length} machines; keeping the ${MAX_MACHINES} most recent`);
            }
            for (const rec of kept.slice(0, MAX_MACHINES)) machines.set(rec.machine, rec);
            console.log(`Loaded CI runner state for ${machines.size} machine(s)`);
        } catch (error) {
            machines.clear();
            console.error('Error loading CI runners (starting empty):', error.message);
        }
    }

    /**
     * Writes BOTH files (server.js's periodic save + SIGTERM/SIGINT call this
     * one function). Independent try blocks: one failing never skips the
     * other. Either crash order is safe: rollups behind the job list are
     * re-counted by load()'s backfill; rollups ahead only hold extra ledger
     * ids, which make a re-send a duplicate.
     */
    function save() {
        try {
            // Temp name must keep matching the .gitignore / sync-tap.sh exclusion
            // "ci-runners.json.tmp-*" and the load() sweep (XACA-1387-017).
            writeJsonAtomic(file, { schema_version: SCHEMA_VERSION, machines: Object.fromEntries(machines) });
        } catch (error) {
            console.error('Error saving CI runners:', error.message);
        }
        rollups.prune(clock().getTime());
        rollups.save();
    }

    /**
     * Make room for a NEW machine (XACA-1387-014). Policy: evict the machine
     * with the oldest receivedAt ONLY if it is already OFFLINE (no push for
     * > offlineAfterSeconds); otherwise refuse the newcomer.
     *
     * Why refuse instead of evicting a live machine: the cap exists to bound
     * what a FLEET-key holder (or a reporter bug minting ids) can make us hold.
     * Evict-oldest-always would let that same flood push real, reporting
     * runners out of the dashboard every cycle. Refusing keeps every live
     * machine visible and makes the flood the thing that fails, loudly (507).
     * OFFLINE rather than STALE: a STALE machine is one missed push from
     * recovering and the UI still renders it as current.
     */
    function makeRoomFor(machine, nowMs) {
        if (machines.has(machine) || machines.size < MAX_MACHINES) return;
        let oldest = null;
        for (const rec of machines.values()) {
            if (!oldest || Date.parse(rec.receivedAt) < Date.parse(oldest.receivedAt)) oldest = rec;
        }
        if (oldest && nowMs - Date.parse(oldest.receivedAt) > OFFLINE_THRESHOLD_MS) {
            machines.delete(oldest.machine);
            // Its rollups go too: the cap bounds rollup memory the same way,
            // and an evicted machine is no longer served. If it reports again
            // it starts from zero, and its re-sent jobs are counted afresh --
            // not double: the old counts are gone with it.
            rollups.dropMachine(oldest.machine);
            console.log(`[CI-RUNNERS] machine cap ${MAX_MACHINES}: evicted offline machine '${oldest.machine}' (and its rollups) for '${machine}'`);
            return;
        }
        throw new CapacityError(`machine cap reached (${MAX_MACHINES} machines, none offline); not storing new machine '${machine}'`);
    }

    /**
     * Apply a validated push. Returns { receivedAt, jobsAccepted, jobsDuplicate }.
     * Throws CapacityError when a new machine cannot be admitted (nothing stored).
     */
    function applyPush(parsed, now = clock()) {
        const nowMs = now.getTime();
        makeRoomFor(parsed.machine, nowMs);
        const receivedAt = now.toISOString();
        const prev = machines.get(parsed.machine);
        const jobs = prev ? prev.jobs.slice() : [];
        const known = new Map(jobs.map((j) => [j.id, j]));
        const osByRunner = new Map(parsed.record.runners.map((r) => [r.name, runnerOs(r)]));
        let jobsAccepted = 0;
        let jobsDuplicate = 0;
        const rollup = { counted: 0, duplicate: 0, sealed: 0, future: 0, truncated: 0 };
        for (const j of parsed.jobs) {
            let stored = known.get(j.id);
            if (stored) {
                jobsDuplicate++;
            } else {
                // os is resolved at receipt: the runner list it came from is replaced next push.
                stored = { ...j, os: osByRunner.get(j.runner) || deriveOs(j.runner, null), firstSeenAt: receivedAt };
                known.set(j.id, stored);
                jobs.push(stored);
                jobsAccepted++;
            }
            // Always offer the STORED (first-written) version to the rollup;
            // its own id ledger -- not the capped job list -- decides whether
            // it is counted (an id evicted from the list is still a duplicate).
            rollup[rollups.recordJob(parsed.machine, stored, osByRunner, nowMs)]++;
        }
        rollups.prune(nowMs, parsed.machine);
        jobs.sort((a, b) => Date.parse(b.endedAt) - Date.parse(a.endedAt));
        machines.set(parsed.machine, {
            machine: parsed.machine,
            receivedAt,
            ...parsed.record,
            jobs: jobs.slice(0, MAX_JOBS_PER_MACHINE),
        });
        return { receivedAt, jobsAccepted, jobsDuplicate, rollup };
    }

    /** The GET /api/ci-runners contract response. */
    function snapshot({ jobsLimit = DEFAULT_JOBS_LIMIT, now = clock() } = {}) {
        return buildContractResponse([...machines.values()], now, { jobsLimit, rollups });
    }

    return { load, save, applyPush, snapshot, machines, rollups };
}

function parseJobsLimit(raw) {
    if (typeof raw !== 'string' || !/^\d+$/.test(raw)) return DEFAULT_JOBS_LIMIT;
    return Math.min(parseInt(raw, 10), MAX_JOBS_LIMIT);
}

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------

/**
 * Mount the routes. opts.file overrides the store path (tests); otherwise
 * FLEET_CI_RUNNERS_FILE, otherwise data/ci-runners.json. The rollups live
 * next to it (data/ci-runner-rollups.json) unless opts.rollupFile is given.
 * Returns the store so server.js can call save() -- which writes BOTH files --
 * on its periodic timer and on shutdown.
 */
function registerCiRunnersRoutes(app, opts = {}) {
    const file = opts.file || process.env.FLEET_CI_RUNNERS_FILE || path.join(__dirname, '..', 'data', 'ci-runners.json');
    const store = createCiRunnerStore(file, { rollupFile: opts.rollupFile, clock: opts.clock });
    store.load();

    // XACA-1422: opts.poolStore is the CI pool store holding the per-host telemetry key hashes.
    // Without it the gate rejects every push; it never falls back to the fleet token.
    const ciTelemetryKey = requireCiTelemetryKey(opts.poolStore);

    app.post('/api/ci-runners-push', ciTelemetryKey, (req, res) => {
        try {
            // The global express.json limit is 10 MB; the 64 KiB cap lives here.
            const size = Buffer.byteLength(JSON.stringify(req.body === undefined ? null : req.body), 'utf8');
            if (size > MAX_BODY_BYTES) {
                return res.status(413).json({ error: `payload too large (max ${MAX_BODY_BYTES} bytes)` });
            }
            let parsed;
            try { parsed = validatePush(req.body); }
            catch (e) {
                if (e instanceof ValidationError) return res.status(400).json({ error: e.message, field: e.field });
                throw e;
            }
            let result;
            try { result = store.applyPush(parsed); }
            catch (e) {
                if (e instanceof CapacityError) {
                    console.error(`[CI-RUNNERS] ${e.message}`);
                    return res.status(507).json({ error: e.message, field: 'machine' });
                }
                throw e;
            }
            console.log(`[CI-RUNNERS] push from '${parsed.machine}': +${result.jobsAccepted} jobs, ${result.jobsDuplicate} dup, ${parsed.jobsRejected.length} rejected`);
            const ru = result.rollup;
            if (ru.future || ru.truncated) {
                // sealed is routine (an old job still in the reporter's window); these two are not.
                console.error(`[CI-RUNNERS] push from '${parsed.machine}': rollup did NOT count ${ru.future} future-dated, ${ru.truncated} over-cap job(s)`);
            }
            return res.status(200).json({
                success: true,
                machine: parsed.machine,
                receivedAt: result.receivedAt,
                jobsAccepted: result.jobsAccepted,
                jobsDuplicate: result.jobsDuplicate,
                jobsRejected: parsed.jobsRejected,
            });
        } catch (error) {
            console.error('Error processing ci-runners push:', error);
            return res.status(500).json({ error: 'Internal server error' });
        }
    });

    app.get('/api/ci-runners', (req, res) => {
        try {
            res.json(store.snapshot({ jobsLimit: parseJobsLimit(req.query.jobs) }));
        } catch (error) {
            console.error('Error serving ci-runners:', error);
            res.status(500).json({ error: 'Internal server error' });
        }
    });

    return store;
}

module.exports = {
    registerCiRunnersRoutes,
    createCiRunnerStore,
    createRollupStore,
    buildContractResponse,
    jobAccounting,
    rebuildStoredRecord,
    validatePush,
    validateJob,
    deriveOs,
    ValidationError,
    CapacityError,
    parseJobsLimit,
    MAX_BODY_BYTES,
    MAX_MACHINES,
    MAX_JOBS_PER_MACHINE,
    MAX_JOBS_PER_PUSH,
    MAX_IDS_PER_DAY,
    LEDGER_DAYS,
    ROLLUP_RETAIN_MONTHS,
    ROLLUP_FILE_NAME,
    STALE_THRESHOLD_MS,
    OFFLINE_THRESHOLD_MS,
};
