//
//  ci-pool-store.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * CI pool store (XACA-1441-004, plan D4/D8, Contract §C7).
 *
 * Persists data/ci-pool.json: dispatcher config (allowlist, poolLabel,
 * jobClasses, thresholds) and one record per machine (enabled, paused + who/
 * when/why, host preference, threshold overrides, host-credential hash).
 *
 *  - DORMANT BY DEFAULT: a machine with no record is not enabled; a new record
 *    is `enabled:false`; an empty allowlist admits no repo.
 *  - FAIL CLOSED: unknown fields and bad types are rejected, never coerced or
 *    dropped. A corrupt file on load is moved aside (".corrupt-<ts>") and the
 *    store starts from dormant defaults; it never crashes boot.
 *  - `machines[m].paused` is the ONLY pause field the dispatcher reads (§C7).
 *  - NO PLAINTEXT CREDENTIALS: per-host secrets (minted by the operator routes,
 *    XACA-1422-012) are stored only as sha256 hex and compared with
 *    crypto.timingSafeEqual. Each machine has TWO independent hashes: `keyHash`
 *    (pool agent credential, `fcp_`) and `telemetryKeyHash` (CI telemetry
 *    credential, `fct_`, XACA-1422). A file written before XACA-1422 has no
 *    `telemetryKeyHash`; load() reads that one missing field as null.
 *  - Every mutation validates the whole candidate, writes atomically
 *    (temp + rename) and rolls the in-memory state back if the write fails.
 */

const fs     = require('fs');
const path   = require('path');
const crypto = require('crypto');

const SCHEMA_VERSION = 1;
const GIB = 1024 * 1024 * 1024;

const MACHINE_ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const REPO_RE = /^[A-Za-z0-9-]{1,39}\/[A-Za-z0-9._-]{1,100}$/;
const LABEL_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const JOB_NAME_RE = /^[^\u0000-\u001f]{1,200}$/;
const HASH_RE = /^[0-9a-f]{64}$/;
const MAX_MACHINES = 64;
const MAX_ALLOWLIST = 256;
const MAX_JOB_CLASSES = 256;
const MAX_REASON = 500;
const JOB_CLASS_VALUES = ['long', 'short'];

/** Threshold name -> [min, max, integer?]. Inclusive bounds. */
const THRESHOLD_BOUNDS = {
    memReclaimableBytes: [0, 1024 * GIB, true],
    swapUsedBytes:       [0, 1024 * GIB, true],
    memFreePct:          [0, 100, false],
    loadPerCpu:          [0, 64, false],
    pollStaleMs:         [1000, 600000, true],
};

const DEFAULT_THRESHOLDS = Object.freeze({
    memReclaimableBytes: 1.5 * GIB,   // macOS job needs >= 1.5 GiB (XACA-1436)
    swapUsedBytes: Math.round(2.8 * GIB), // gate is swapUsed < this
    memFreePct: 35,                   // gate is memFreePct >= this
    loadPerCpu: 0.75,                 // gate is load1/ncpu < this
    pollStaleMs: 30000,               // gate is now - lastPoll <= this
});

const DEFAULT_JOB_CLASSES = Object.freeze({
    'shell-suite': 'long', 'bats': 'long', 'pytest-suite': 'long',
});

const CONFIG_FIELDS = ['allowlist', 'poolLabel', 'jobClasses', 'thresholds'];
const MACHINE_FIELDS = ['enabled', 'paused', 'pausedBy', 'pausedAt', 'pauseReason',
                        'prefers', 'thresholds', 'keyHash', 'telemetryKeyHash'];
const TOP_FIELDS = ['schemaVersion', 'config', 'machines'];

const has = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
const isPlainObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const clone = (o) => JSON.parse(JSON.stringify(o));

function defaultConfig() {
    return {
        allowlist: [],
        poolLabel: 'fleet-pool',
        jobClasses: Object.assign({}, DEFAULT_JOB_CLASSES),
        thresholds: Object.assign({}, DEFAULT_THRESHOLDS),
    };
}

function defaultMachine() {
    return {
        enabled: false, paused: false, pausedBy: null, pausedAt: null,
        pauseReason: null, prefers: null, thresholds: {}, keyHash: null,
        telemetryKeyHash: null,
    };
}

function defaultPool() {
    return { schemaVersion: SCHEMA_VERSION, config: defaultConfig(), machines: {} };
}

/** sha256 hex of a host secret. Throws on empty / non-string input. */
function hashSecret(secret) {
    if (typeof secret !== 'string' || secret.length === 0) throw new TypeError('secret must be a non-empty string');
    return crypto.createHash('sha256').update(secret, 'utf8').digest('hex');
}

// ---------------------------------------------------------------- validation
// Each validator returns an array of problem strings (empty = valid).

function unknownFields(obj, allowed, where) {
    return Object.keys(obj).filter((k) => !allowed.includes(k)).map((k) => `${where}: unknown field "${k}"`);
}

function validateThresholds(t, where, requireAll) {
    if (!isPlainObject(t)) return [`${where}: must be an object`];
    const errs = unknownFields(t, Object.keys(THRESHOLD_BOUNDS), where);
    for (const [name, [min, max, int]] of Object.entries(THRESHOLD_BOUNDS)) {
        if (!has(t, name)) {
            if (requireAll) errs.push(`${where}.${name}: required`);
            continue;
        }
        const v = t[name];
        if (typeof v !== 'number' || !Number.isFinite(v) || v < min || v > max || (int && !Number.isInteger(v))) {
            errs.push(`${where}.${name}: must be a ${int ? 'integer' : 'number'} in [${min}, ${max}]`);
        }
    }
    return errs;
}

function validateConfig(c) {
    if (!isPlainObject(c)) return ['config: must be an object'];
    const errs = unknownFields(c, CONFIG_FIELDS, 'config');
    for (const f of CONFIG_FIELDS) if (!has(c, f)) errs.push(`config.${f}: required`);
    if (errs.length) return errs;

    if (!Array.isArray(c.allowlist) || c.allowlist.length > MAX_ALLOWLIST ||
        !c.allowlist.every((r) => typeof r === 'string' && REPO_RE.test(r))) {
        errs.push('config.allowlist: must be an array of "owner/repo" strings');
    } else if (new Set(c.allowlist.map((r) => r.toLowerCase())).size !== c.allowlist.length) {
        errs.push('config.allowlist: duplicate entry');
    }
    if (typeof c.poolLabel !== 'string' || !LABEL_RE.test(c.poolLabel)) {
        errs.push('config.poolLabel: must be a label string');
    }
    if (!isPlainObject(c.jobClasses)) {
        errs.push('config.jobClasses: must be an object');
    } else {
        const names = Object.keys(c.jobClasses);
        if (names.length > MAX_JOB_CLASSES) errs.push('config.jobClasses: too many entries');
        for (const n of names) {
            if (!JOB_NAME_RE.test(n)) errs.push(`config.jobClasses: bad job name "${n}"`);
            if (!JOB_CLASS_VALUES.includes(c.jobClasses[n])) errs.push(`config.jobClasses["${n}"]: must be long|short`);
        }
    }
    errs.push(...validateThresholds(c.thresholds, 'config.thresholds', true));
    return errs;
}

function validateMachine(m, id) {
    const where = `machines["${id}"]`;
    if (!MACHINE_ID_RE.test(id)) return [`${where}: bad machine id`];
    if (!isPlainObject(m)) return [`${where}: must be an object`];
    const errs = unknownFields(m, MACHINE_FIELDS, where);
    for (const f of MACHINE_FIELDS) if (!has(m, f)) errs.push(`${where}.${f}: required`);
    if (errs.length) return errs;

    if (typeof m.enabled !== 'boolean') errs.push(`${where}.enabled: must be boolean`);
    if (typeof m.paused !== 'boolean') errs.push(`${where}.paused: must be boolean`);
    for (const f of ['pausedBy', 'pauseReason']) {
        if (m[f] !== null && (typeof m[f] !== 'string' || m[f].length > MAX_REASON)) {
            errs.push(`${where}.${f}: must be null or a string (max ${MAX_REASON})`);
        }
    }
    if (m.pausedAt !== null && (typeof m.pausedAt !== 'string' || Number.isNaN(Date.parse(m.pausedAt)))) {
        errs.push(`${where}.pausedAt: must be null or an ISO timestamp`);
    }
    if (m.prefers !== null && !JOB_CLASS_VALUES.includes(m.prefers)) {
        errs.push(`${where}.prefers: must be null, "long" or "short"`);
    }
    errs.push(...validateThresholds(m.thresholds, `${where}.thresholds`, false));
    if (m.keyHash !== null && (typeof m.keyHash !== 'string' || !HASH_RE.test(m.keyHash))) {
        errs.push(`${where}.keyHash: must be null or 64 lowercase hex chars (sha256)`);
    }
    if (m.telemetryKeyHash !== null && (typeof m.telemetryKeyHash !== 'string' || !HASH_RE.test(m.telemetryKeyHash))) {
        errs.push(`${where}.telemetryKeyHash: must be null or 64 lowercase hex chars (sha256)`);
    }
    return errs;
}

function validatePool(p) {
    if (!isPlainObject(p)) return ['pool: must be an object'];
    const errs = unknownFields(p, TOP_FIELDS, 'pool');
    if (p.schemaVersion !== SCHEMA_VERSION) errs.push(`pool.schemaVersion: must be ${SCHEMA_VERSION}`);
    errs.push(...validateConfig(p.config));
    if (!isPlainObject(p.machines)) {
        errs.push('pool.machines: must be an object');
    } else {
        const ids = Object.keys(p.machines);
        if (ids.length > MAX_MACHINES) errs.push('pool.machines: too many machines');
        for (const id of ids) errs.push(...validateMachine(p.machines[id], id));
    }
    return errs;
}

/**
 * XACA-1422: a ci-pool.json written before the telemetry credential existed has no
 * `telemetryKeyHash`. Read that one missing field as null so an upgrade does not move a
 * valid file aside and wipe every machine's config. Nothing else is defaulted: any other
 * missing or unknown field still fails validation.
 */
function upgradeLegacy(parsed) {
    if (!isPlainObject(parsed) || !isPlainObject(parsed.machines)) return;
    for (const m of Object.values(parsed.machines)) {
        if (isPlainObject(m) && !has(m, 'telemetryKeyHash')) m.telemetryKeyHash = null;
    }
}

// --------------------------------------------------------------- persistence

/** temp + rename (same idiom as ci-runners-routes.js). */
function writeAtomic(file, obj) {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    const tmp = `${file}.tmp-${process.pid}`;
    try {
        fs.writeFileSync(tmp, JSON.stringify(obj, null, 2), { mode: 0o600 });
        fs.renameSync(tmp, file);
    } catch (e) {
        try { fs.unlinkSync(tmp); } catch (_) { /* nothing to clean */ }
        throw e;
    }
}

/**
 * @param {{file: string, logger?: {error?: Function}}} opts
 */
function createPoolStore(opts) {
    if (!opts || typeof opts.file !== 'string' || !opts.file) throw new TypeError('createPoolStore: file is required');
    const file = opts.file;
    const log = opts.logger || console;
    let pool = defaultPool();

    function commit(candidate) {
        const errs = validatePool(candidate);
        if (errs.length) return { ok: false, error: errs.join('; ') };
        const previous = pool;
        pool = candidate;
        try {
            writeAtomic(file, pool);
        } catch (e) {
            pool = previous;
            return { ok: false, error: `write failed: ${e.message}` };
        }
        return { ok: true };
    }

    /** Never throws. Missing file = dormant defaults. Corrupt/invalid = moved aside + defaults. */
    function load() {
        let raw;
        try {
            raw = fs.readFileSync(file, 'utf8');
        } catch (e) {
            pool = defaultPool();
            if (e.code === 'ENOENT') return { ok: true, fresh: true };
            if (log.error) log.error(`[CI-POOL] cannot read ${file}: ${e.message}`);
            return { ok: false, error: e.message };
        }
        let parsed;
        let errs;
        try { parsed = JSON.parse(raw); upgradeLegacy(parsed); errs = validatePool(parsed); } catch (e) { errs = [`not valid JSON: ${e.message}`]; }
        if (errs.length) {
            const aside = `${file}.corrupt-${Date.now()}`;
            try { fs.renameSync(file, aside); } catch (_) { /* best effort */ }
            if (log.error) log.error(`[CI-POOL] ${file} rejected (${errs[0]}); moved aside, starting dormant`);
            pool = defaultPool();
            return { ok: false, error: errs.join('; '), movedTo: aside };
        }
        pool = parsed;
        return { ok: true };
    }

    function save() {
        try { writeAtomic(file, pool); return { ok: true }; } catch (e) { return { ok: false, error: e.message }; }
    }

    const getConfig = () => clone(pool.config);
    const listMachines = () => clone(pool.machines);
    const getMachine = (id) => (typeof id === 'string' && has(pool.machines, id) ? clone(pool.machines[id]) : null);

    /** Replace any subset of config fields; the merged result must validate. */
    function updateConfig(patch) {
        if (!isPlainObject(patch)) return { ok: false, error: 'patch must be an object' };
        const bad = unknownFields(patch, CONFIG_FIELDS, 'config');
        if (bad.length) return { ok: false, error: bad.join('; ') };
        const next = clone(pool);
        for (const f of Object.keys(patch)) next.config[f] = clone(patch[f]);
        return commit(next);
    }

    /**
     * Create or update a machine. Patchable: enabled, paused, pauseReason,
     * prefers, thresholds. pausedBy/pausedAt are server-set from `meta.by` /
     * `meta.now` when `paused` flips (never client-supplied); un-pausing clears
     * all three. The credential hash is set only via setHostSecret().
     */
    function upsertMachine(id, patch, meta) {
        if (typeof id !== 'string' || !MACHINE_ID_RE.test(id)) return { ok: false, error: 'bad machine id' };
        if (!isPlainObject(patch)) return { ok: false, error: 'patch must be an object' };
        const patchable = ['enabled', 'paused', 'pauseReason', 'prefers', 'thresholds'];
        const bad = unknownFields(patch, patchable, 'machine patch');
        if (bad.length) return { ok: false, error: bad.join('; ') };

        const next = clone(pool);
        const exists = has(next.machines, id);
        if (!exists && Object.keys(next.machines).length >= MAX_MACHINES) return { ok: false, error: 'too many machines' };
        const m = exists ? next.machines[id] : defaultMachine();
        const wasPaused = m.paused;
        for (const f of Object.keys(patch)) m[f] = clone(patch[f]);
        if (m.paused === true && wasPaused !== true) {
            const by = meta && meta.by;
            const now = meta && Number.isFinite(meta.now) ? meta.now : Date.now();
            m.pausedBy = typeof by === 'string' ? by.slice(0, MAX_REASON) : null;
            m.pausedAt = new Date(now).toISOString();
        } else if (m.paused === false) {
            m.pausedBy = null; m.pausedAt = null; m.pauseReason = null;
        }
        next.machines[id] = m;
        return commit(next);
    }

    /** Store only sha256(secret). The plaintext is never retained. */
    function setHostSecret(id, secret) {
        if (!getMachine(id)) return { ok: false, error: 'unknown machine' };
        let h;
        try { h = hashSecret(secret); } catch (e) { return { ok: false, error: e.message }; }
        const next = clone(pool);
        next.machines[id].keyHash = h;
        return commit(next);
    }

    function clearHostSecret(id) {
        if (!getMachine(id)) return { ok: false, error: 'unknown machine' };
        const next = clone(pool);
        next.machines[id].keyHash = null;
        return commit(next);
    }

    /** Constant-time compare of sha256(candidate) with the stored hash. Unknown machine / none stored / bad input -> false. */
    function verifyHostSecret(id, secret) {
        return verifyHash(id, 'keyHash', secret);
    }

    function verifyHash(id, field, secret) {
        const m = getMachine(id);
        if (!m || !m[field] || typeof secret !== 'string' || secret.length === 0) return false;
        const a = Buffer.from(hashSecret(secret), 'hex');
        const b = Buffer.from(m[field], 'hex');
        return a.length === b.length && crypto.timingSafeEqual(a, b);
    }

    /** CI telemetry credential (`fct_`, XACA-1422): same contract as the host-secret trio, independent hash. */
    function setTelemetrySecret(id, secret) {
        if (!getMachine(id)) return { ok: false, error: 'unknown machine' };
        let h;
        try { h = hashSecret(secret); } catch (e) { return { ok: false, error: e.message }; }
        const next = clone(pool);
        next.machines[id].telemetryKeyHash = h;
        return commit(next);
    }

    function clearTelemetrySecret(id) {
        if (!getMachine(id)) return { ok: false, error: 'unknown machine' };
        const next = clone(pool);
        next.machines[id].telemetryKeyHash = null;
        return commit(next);
    }

    function verifyTelemetrySecret(id, secret) {
        return verifyHash(id, 'telemetryKeyHash', secret);
    }

    return {
        load, save, getConfig, updateConfig, listMachines, getMachine, upsertMachine,
        setHostSecret, clearHostSecret, verifyHostSecret,
        setTelemetrySecret, clearTelemetrySecret, verifyTelemetrySecret, file,
    };
}

module.exports = {
    SCHEMA_VERSION, GIB, DEFAULT_THRESHOLDS, DEFAULT_JOB_CLASSES, THRESHOLD_BOUNDS,
    MACHINE_ID_RE, REPO_RE,
    defaultPool, defaultConfig, defaultMachine, validatePool, validateConfig, validateMachine,
    hashSecret, createPoolStore,
};
