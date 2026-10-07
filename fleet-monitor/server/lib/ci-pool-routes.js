//
//  ci-pool-routes.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Fleet CI Pool routes (XACA-1441-005). Normative contract:
 * fleet-monitor/docs/CI-POOL-API-CONTRACT.md (C1-C8).
 *
 *   POST /api/ci-pool/agent/poll              per-host key   capacity in, assignments out
 *   POST /api/ci-pool/assignments/:id/state   per-host key   lifecycle transition (must own :id)
 *   GET  /api/ci-pool                         open, REDACTED (same posture as GET /api/ci-runners)
 *   PUT  /api/ci-pool/machines/:machine       admin          enabled, paused(+reason), prefers, thresholds
 *   PUT  /api/ci-pool/config                  admin          allowlist, poolLabel, jobClasses, thresholds
 *   POST   /api/ci-pool/machines/:machine/key            admin   mint the agent key (fcp_), shown ONCE
 *   DELETE /api/ci-pool/machines/:machine/key            admin   revoke it
 *   POST   /api/ci-pool/machines/:machine/telemetry-key  admin   mint the telemetry key (fct_), shown ONCE
 *   DELETE /api/ci-pool/machines/:machine/telemetry-key  admin   revoke it
 *
 * Agent auth (C1): ONLY a per-host key (`fcp_<43 base64url>`) verified against the
 * pool store's sha256 hashes. The fleet key, admin key and telemetry key are all
 * 401 here. The matched machine becomes req.ciMachine and is the ONLY machine an
 * agent route ever acts on; neither the URL nor the body picks it.
 * Issuance (XACA-1422-012): the four admin routes above mint and revoke the two per-host
 * credentials. Only sha256 is stored; the plaintext exists in the one mint response.
 *
 * Telemetry auth (XACA-1422): requireCiTelemetryKey() gates POST /api/ci-runners-push (that
 * route lives in ci-runners-routes.js). It accepts ONLY a per-host `fct_` key and ONLY when
 * body.machine is the machine the key belongs to (403 otherwise). It is exported from here
 * so both credential kinds are verified in one place with one shape.
 *
 * DORMANT (Requirement 3): with the dispatcher not enabled the poll answers
 * `enabled:false` with no assignments and slows the agent to 60 s. No route in
 * this file ever calls GitHub (the poll path only touches memory).
 *
 * SECRETS (Requirement 7/11): the only response that can contain a jitConfig is
 * the owning machine's poll. Operator views are built from explicit allowlists.
 */

const crypto = require('crypto');
const { requireAdminKey } = require('./auth-middleware');
const { MACHINE_ID_RE } = require('./ci-pool-store');
const { ID_RE } = require('./ci-dispatch-assignments');

const SCHEMA_VERSION = 1;
const MAX_POLL_BYTES = 16 * 1024;
const MAX_STATE_BYTES = 2 * 1024;
const POLL_AFTER_SECONDS = 10;
const POLL_AFTER_DORMANT_SECONDS = 60;

const HOST_KEY_RE = /^fcp_[A-Za-z0-9_-]{43}$/;
const TELEMETRY_KEY_RE = /^fct_[A-Za-z0-9_-]{43}$/;
const BEARER_RE = /^[Bb][Ee][Aa][Rr][Ee][Rr][ \t]+(.+)$/;
const AGENT_VERSION_RE = /^[0-9A-Za-z._+-]{1,32}$/;
const SLOT_ID_RE = /^a_[A-Za-z0-9-]{1,64}$/;
const SLOT_STATES = ['idle', 'starting', 'busy', 'cleaning', 'broken'];
const VM_STATES = ['running', 'stopped', 'broken', 'unknown', 'none'];
const OS_VALUES = ['Linux', 'macOS'];
const REPORT_STATES = ['started', 'completed', 'failed', 'cancelled'];
const MAX_SLOTS = 32;

// Same byte-identical body as auth-middleware's UNAUTHORIZED_BODY (contract §4: no reason leaks).
const UNAUTHORIZED_BODY = { error: 'Unauthorized', code: 'unauthorized' };
// Valid telemetry key, but body.machine is not the machine it was minted for.
const FORBIDDEN_BODY = { error: 'Forbidden', code: 'forbidden' };

class PollValidationError extends Error {
    constructor(message, extra) {
        super(message);
        this.name = 'PollValidationError';
        this.extra = extra || {};
    }
}

const has = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
const isPlainObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const isNum = (v) => typeof v === 'number' && Number.isFinite(v);
const bad = (m) => { throw new PollValidationError(m); };

function noUnknown(obj, allowed, where) {
    for (const k of Object.keys(obj)) if (!allowed.includes(k)) bad(`${where}: unknown field "${k}"`);
}

// ----------------------------------------------------------------- C3 poll

/** field -> [required, kind, min, max]. kind: 'num' | 'int'. */
const CAPACITY_SPEC = {
    memTotalBytes:       [true,  'int', 0, 2 ** 50],
    memReclaimableBytes: [true,  'int', 0, 2 ** 50],
    memFreePct:          [true,  'num', 0, 100],
    swapUsedBytes:       [true,  'int', 0, 2 ** 50],
    swapTotalBytes:      [false, 'int', 0, 2 ** 50],
    load1:               [true,  'num', 0, 100000],
    load5:               [false, 'num', 0, 100000],
    load15:              [false, 'num', 0, 100000],
    ncpu:                [true,  'int', 1, 4096],
    teamSessions:        [false, 'int', 0, 100000],
    vmState:             [true,  'enum', VM_STATES],
};

/** Allowlist-copy (validatePush style): returns a fresh object holding only known, valid fields. */
function validatePoll(body) {
    if (!isPlainObject(body)) bad('body must be a JSON object');
    noUnknown(body, ['schemaVersion', 'agentVersion', 'capacity', 'slots'], 'poll');
    if (body.schemaVersion !== SCHEMA_VERSION) {
        throw new PollValidationError('unsupported schemaVersion', { expected: SCHEMA_VERSION });
    }
    if (typeof body.agentVersion !== 'string' || !AGENT_VERSION_RE.test(body.agentVersion)) bad('agentVersion: must be a version string');
    if (!isPlainObject(body.capacity)) bad('capacity: must be an object');
    noUnknown(body.capacity, Object.keys(CAPACITY_SPEC), 'capacity');
    const capacity = {};
    for (const [name, spec] of Object.entries(CAPACITY_SPEC)) {
        const [required, kind, a, b] = spec;
        if (!has(body.capacity, name)) { if (required) bad(`capacity.${name}: required`); continue; }
        const v = body.capacity[name];
        if (kind === 'enum') {
            if (!a.includes(v)) bad(`capacity.${name}: must be one of ${a.join('|')}`);
        } else if (!isNum(v) || v < a || v > b || (kind === 'int' && !Number.isInteger(v))) {
            bad(`capacity.${name}: must be a ${kind === 'int' ? 'integer' : 'number'} in [${a}, ${b}]`);
        }
        capacity[name] = v;
    }
    if (!Array.isArray(body.slots) || body.slots.length > MAX_SLOTS) bad(`slots: must be an array of at most ${MAX_SLOTS}`);
    const seen = new Set();
    const slots = body.slots.map((s, i) => {
        const where = `slots[${i}]`;
        if (!isPlainObject(s)) bad(`${where}: must be an object`);
        noUnknown(s, ['os', 'index', 'state', 'assignmentId'], where);
        if (!OS_VALUES.includes(s.os)) bad(`${where}.os: must be Linux|macOS`);
        if (!Number.isInteger(s.index) || s.index < 1 || s.index > 64) bad(`${where}.index: must be an integer 1-64`);
        if (!SLOT_STATES.includes(s.state)) bad(`${where}.state: must be one of ${SLOT_STATES.join('|')}`);
        if (s.assignmentId !== null && (typeof s.assignmentId !== 'string' || !SLOT_ID_RE.test(s.assignmentId))) {
            bad(`${where}.assignmentId: must be null or an assignment id`);
        }
        const k = `${s.os}#${s.index}`;
        if (seen.has(k)) bad(`${where}: duplicate slot ${k}`);
        seen.add(k);
        return { os: s.os, index: s.index, state: s.state, assignmentId: s.assignmentId };
    });
    return { agentVersion: body.agentVersion, capacity, slots };
}

/** Assignment state report body. Allowlist-copy; unknown field -> error. */
function validateStateReport(body) {
    if (!isPlainObject(body)) bad('body must be a JSON object');
    noUnknown(body, ['state', 'exitCode', 'reason'], 'report');
    if (!REPORT_STATES.includes(body.state)) bad(`state: must be one of ${REPORT_STATES.join('|')}`);
    const out = { state: body.state };
    if (has(body, 'exitCode')) {
        if (!Number.isInteger(body.exitCode) || body.exitCode < -255 || body.exitCode > 255) bad('exitCode: must be an integer in [-255, 255]');
        out.exitCode = body.exitCode;
    }
    if (has(body, 'reason')) {
        if (typeof body.reason !== 'string' || body.reason.length > 200) bad('reason: must be a string of at most 200 characters');
        out.reason = body.reason;
    }
    return out;
}

// ------------------------------------------------------------------- auth

/** The bearer token iff it is well-formed for `re`; null otherwise (missing, wrong scheme, wrong shape). */
function presentedKey(req, re) {
    const header = req.get ? req.get('authorization') : (req.headers && req.headers.authorization);
    if (!header) return null;
    const m = BEARER_RE.exec(String(header));
    if (!m) return null;
    const token = m[1].trim();
    return re.test(token) ? token : null;
}

const presentedHostKey = (req) => presentedKey(req, HOST_KEY_RE);

/** New credential: `<prefix>` + 43 base64url chars from 32 random bytes. */
const mintKey = (prefix) => prefix + crypto.randomBytes(32).toString('base64url');

/**
 * Per-host key middleware (C1). Accepts ONLY `Bearer fcp_<43 base64url>` whose sha256
 * matches some machine's stored keyHash. Every machine is compared (no early exit) so
 * the position of the matching record is not visible in timing. Rejection is the same
 * byte-identical 401 for every reason, including "this is the fleet key".
 */
function requireCiHostKey(store) {
    return function ciHostKey(req, res, next) {
        const key = presentedHostKey(req);
        let matched = null;
        if (key) {
            for (const id of Object.keys(store.listMachines())) {
                if (store.verifyHostSecret(id, key) && matched === null) matched = id;
            }
        }
        if (matched === null) return res.status(401).set('WWW-Authenticate', 'Bearer').json(UNAUTHORIZED_BODY);
        req.ciMachine = matched;
        return next();
    };
}

/**
 * Telemetry-key middleware for POST /api/ci-runners-push (XACA-1422). Accepts ONLY
 * `Bearer fct_<43 base64url>` whose sha256 matches some machine's telemetryKeyHash; the fleet
 * token, admin token and agent (`fcp_`) key are all 401 (no fallback). Every machine is compared
 * (no early exit). The matched machine must equal body.machine, else 403: a key holder can
 * only write its own host's record. With no store this FAILS CLOSED (401 for everything).
 * Sets req.ciTelemetryMachine.
 */
function requireCiTelemetryKey(store) {
    return function ciTelemetryKey(req, res, next) {
        const presented = store ? presentedKey(req, TELEMETRY_KEY_RE) : null;
        let matched = null;
        if (presented) {
            for (const id of Object.keys(store.listMachines())) {
                if (store.verifyTelemetrySecret(id, presented) && matched === null) matched = id;
            }
        }
        if (matched === null) return res.status(401).set('WWW-Authenticate', 'Bearer').json(UNAUTHORIZED_BODY);
        const claimed = req.body && typeof req.body === 'object' ? req.body.machine : undefined;
        if (claimed !== matched) return res.status(403).json(FORBIDDEN_BODY);
        req.ciTelemetryMachine = matched;
        return next();
    };
}

// ------------------------------------------------------------------ views

function bodySize(body) {
    return Buffer.byteLength(JSON.stringify(body === undefined ? null : body), 'utf8');
}

const iso = (ms) => (Number.isFinite(ms) ? new Date(ms).toISOString() : null);

/**
 * @param {object} app
 * @param {object} deps
 * @param {object}   deps.store        ci-pool-store
 * @param {object}   deps.assignments  ci-dispatch-assignments
 * @param {object}   [deps.dispatcher] {isEnabled(), alerts?(), queue?()}; absent => FLEET_CI_DISPATCHER==='1'
 * @param {object}   [deps.audit]      {append}
 * @param {Function} [deps.now]        () => epoch ms
 * @param {Map}      [deps.reports]    machine -> {receivedAt, capacity, slots, agentVersion}; shared with the dispatcher
 * @param {Function} [deps.hostAuth]   middleware override (tests only: proves the auth matrix catches a weaker gate)
 * @param {object}   [deps.logger]
 *
 * Gate names are load-bearing: tests/xaca-0398-003-admin-tier.test.js reads the middleware
 * identifier from each `app.METHOD('/api…', <ident>` call. Operator routes use requireAdminKey
 * directly; agent routes use `ciHostKey` (per-host key tier, registered in that test).
 * @returns {{reports: Map}}
 */
function registerCiPoolRoutes(app, deps) {
    const d = deps || {};
    const store = d.store;
    const assignments = d.assignments;
    if (!store || !assignments) throw new TypeError('registerCiPoolRoutes: store and assignments are required');
    const clock = typeof d.now === 'function' ? d.now : Date.now;
    const reports = d.reports || new Map();
    const log = d.logger || console;
    const ciHostKey = d.hostAuth || requireCiHostKey(store);

    function dispatcherOn() {
        if (d.dispatcher && typeof d.dispatcher.isEnabled === 'function') return d.dispatcher.isEnabled() === true;
        return process.env.FLEET_CI_DISPATCHER === '1';
    }

    function audit(event, fields) {
        if (d.audit && typeof d.audit.append === 'function') {
            try { d.audit.append(event, fields); } catch (_) { /* never fails a request */ }
        }
    }

    // ------------------------------------------------------------ agent poll
    app.post('/api/ci-pool/agent/poll', ciHostKey, (req, res) => {
        try {
            if (bodySize(req.body) > MAX_POLL_BYTES) {
                return res.status(413).json({ error: `payload too large (max ${MAX_POLL_BYTES} bytes)` });
            }
            let parsed;
            try { parsed = validatePoll(req.body); } catch (e) {
                if (e instanceof PollValidationError) return res.status(400).json(Object.assign({ error: e.message }, e.extra));
                throw e;
            }
            const machineId = req.ciMachine;
            const now = clock();
            reports.set(machineId, { receivedAt: now, capacity: parsed.capacity, slots: parsed.slots, agentVersion: parsed.agentVersion });

            const on = dispatcherOn();
            const m = store.getMachine(machineId);
            const enabled = on && !!m && m.enabled === true;
            const paused = !m || m.paused !== false;
            const out = {
                schemaVersion: SCHEMA_VERSION,
                serverTime: iso(now),
                enabled,
                paused,
                pauseReason: m && m.paused === true ? m.pauseReason : null,
                pollAfterSeconds: on ? POLL_AFTER_SECONDS : POLL_AFTER_DORMANT_SECONDS,
                assignments: [],
                // cancel[] is a stop instruction for an idle listener, so it is sent even when paused/disabled.
                cancel: assignments.cancelListFor(machineId, now),
            };
            if (enabled && !paused) out.assignments = assignments.takeForMachine(machineId, now);
            return res.status(200).json(out);
        } catch (error) {
            log.error('[CI-POOL] error processing agent poll:', error && error.message);
            return res.status(500).json({ error: 'Internal server error' });
        }
    });

    // ---------------------------------------------------------- state report
    app.post('/api/ci-pool/assignments/:id/state', ciHostKey, (req, res) => {
        try {
            const id = req.params.id;
            // Ownership BEFORE body validation: another machine's id must look exactly like an unknown one.
            const notFound = () => res.status(404).json({ error: 'Not found' });
            if (!ID_RE.test(id)) return notFound();
            const owner = assignments.get(id);
            if (!owner || owner.machine !== req.ciMachine) return notFound();
            if (bodySize(req.body) > MAX_STATE_BYTES) return res.status(413).json({ error: `payload too large (max ${MAX_STATE_BYTES} bytes)` });
            let parsed;
            try { parsed = validateStateReport(req.body); } catch (e) {
                if (e instanceof PollValidationError) return res.status(400).json({ error: e.message });
                throw e;
            }
            const r = assignments.report(id, req.ciMachine, parsed);
            if (r.status === 'notfound') return notFound();
            if (r.status === 'conflict') return res.status(409).json({ error: 'illegal transition', id, state: r.state });
            return res.status(200).json({ id, state: r.state });
        } catch (error) {
            log.error('[CI-POOL] error processing assignment state:', error && error.message);
            return res.status(500).json({ error: 'Internal server error' });
        }
    });

    // --------------------------------------------------------- operator view
    app.get('/api/ci-pool', (req, res) => {
        try {
            const cfg = store.getConfig();
            const machines = {};
            const stored = store.listMachines();
            for (const id of Object.keys(stored)) {
                const m = stored[id];
                const r = reports.get(id) || null;
                // Explicit allowlist: keyHash and every secret-bearing field stay out by construction.
                machines[id] = {
                    enabled: m.enabled, paused: m.paused, pausedBy: m.pausedBy, pausedAt: m.pausedAt,
                    pauseReason: m.pauseReason, prefers: m.prefers, thresholds: m.thresholds,
                    hasKey: m.keyHash !== null,
                    hasTelemetryKey: m.telemetryKeyHash !== null,
                    lastPollAt: r ? iso(r.receivedAt) : null,
                    agentVersion: r ? r.agentVersion : null,
                    capacity: r ? r.capacity : null,
                    slots: r ? r.slots : null,
                };
            }
            const out = {
                schemaVersion: SCHEMA_VERSION,
                serverTime: iso(clock()),
                dispatcherEnabled: dispatcherOn(),
                config: { allowlist: cfg.allowlist, poolLabel: cfg.poolLabel, jobClasses: cfg.jobClasses, thresholds: cfg.thresholds },
                machines,
                assignments: assignments.snapshot(),
                alerts: d.dispatcher && typeof d.dispatcher.alerts === 'function' ? d.dispatcher.alerts() : [],
                queue: d.dispatcher && typeof d.dispatcher.queue === 'function' ? d.dispatcher.queue() : [],
            };
            res.json(out);
        } catch (error) {
            log.error('[CI-POOL] error serving ci-pool:', error && error.message);
            res.status(500).json({ error: 'Internal server error' });
        }
    });

    // -------------------------------------------------------- operator writes
    function storeFailure(res, result) {
        if (typeof result.error === 'string' && result.error.startsWith('write failed')) {
            log.error(`[CI-POOL] ${result.error}`);
            return res.status(500).json({ error: 'Internal server error' });
        }
        return res.status(400).json({ error: result.error });
    }

    app.put('/api/ci-pool/machines/:machine', requireAdminKey, (req, res) => {
        try {
            const id = req.params.machine;
            if (!MACHINE_ID_RE.test(id)) return res.status(400).json({ error: 'bad machine id' });
            const body = req.body;
            if (!isPlainObject(body)) return res.status(400).json({ error: 'body must be a JSON object' });
            const allowed = ['enabled', 'paused', 'reason', 'prefers', 'thresholds'];
            const extra = Object.keys(body).filter((k) => !allowed.includes(k));
            if (extra.length) return res.status(400).json({ error: `unknown field "${extra[0]}"` });
            const patch = {};
            for (const k of allowed) {
                if (!has(body, k)) continue;
                patch[k === 'reason' ? 'pauseReason' : k] = body[k];
            }
            const before = store.getMachine(id);
            const result = store.upsertMachine(id, patch, { by: 'operator', now: clock() });
            if (!result.ok) return storeFailure(res, result);
            const after = store.getMachine(id);
            if (has(patch, 'paused') && (!before || before.paused !== after.paused)) {
                audit('pause', { machine: id, paused: after.paused, by: 'operator', reason: after.pauseReason });
            }
            const m = after;
            return res.status(200).json({
                success: true, machine: id,
                record: { enabled: m.enabled, paused: m.paused, pausedBy: m.pausedBy, pausedAt: m.pausedAt, pauseReason: m.pauseReason, prefers: m.prefers, thresholds: m.thresholds, hasKey: m.keyHash !== null, hasTelemetryKey: m.telemetryKeyHash !== null },
            });
        } catch (error) {
            log.error('[CI-POOL] error updating machine:', error && error.message);
            return res.status(500).json({ error: 'Internal server error' });
        }
    });

    app.put('/api/ci-pool/config', requireAdminKey, (req, res) => {
        try {
            if (!isPlainObject(req.body)) return res.status(400).json({ error: 'body must be a JSON object' });
            const result = store.updateConfig(req.body);
            if (!result.ok) return storeFailure(res, result);
            return res.status(200).json({ success: true, config: store.getConfig() });
        } catch (error) {
            log.error('[CI-POOL] error updating config:', error && error.message);
            return res.status(500).json({ error: 'Internal server error' });
        }
    });

    // ------------------------------------------- per-host credential mint / revoke (XACA-1422-012)
    // kind: 'agent' (fcp_, keyHash) | 'telemetry' (fct_, telemetryKeyHash). Handlers are shared; the
    // four registrations below stay literal so the admin-tier route inventory can read them.
    const KINDS = {
        agent:     { prefix: 'fcp_', set: (id, k) => store.setHostSecret(id, k),      clear: (id) => store.clearHostSecret(id) },
        telemetry: { prefix: 'fct_', set: (id, k) => store.setTelemetrySecret(id, k), clear: (id) => store.clearTelemetrySecret(id) },
    };

    function mintHandler(kind) {
        return (req, res) => {
            try {
                const id = req.params.machine;
                if (!MACHINE_ID_RE.test(id)) return res.status(400).json({ error: 'bad machine id' });
                if (!store.getMachine(id)) return res.status(404).json({ error: 'unknown machine' });
                const minted = mintKey(KINDS[kind].prefix);
                const result = KINDS[kind].set(id, minted);
                if (!result.ok) return storeFailure(res, result);
                audit('key-mint', { machine: id, keyKind: kind, by: 'operator' }); // never the credential
                res.set('Cache-Control', 'no-store');
                return res.status(200).json({ machine: id, key: minted });
            } catch (error) {
                log.error('[CI-POOL] error minting key:', error && error.message);
                return res.status(500).json({ error: 'Internal server error' });
            }
        };
    }

    function revokeHandler(kind) {
        return (req, res) => {
            try {
                const id = req.params.machine;
                if (!MACHINE_ID_RE.test(id)) return res.status(400).json({ error: 'bad machine id' });
                if (!store.getMachine(id)) return res.status(404).json({ error: 'unknown machine' });
                const result = KINDS[kind].clear(id);
                if (!result.ok) return storeFailure(res, result);
                audit('key-revoke', { machine: id, keyKind: kind, by: 'operator' });
                res.set('Cache-Control', 'no-store');
                return res.status(200).json({ success: true, machine: id });
            } catch (error) {
                log.error('[CI-POOL] error revoking key:', error && error.message);
                return res.status(500).json({ error: 'Internal server error' });
            }
        };
    }

    app.post('/api/ci-pool/machines/:machine/key', requireAdminKey, mintHandler('agent'));
    app.delete('/api/ci-pool/machines/:machine/key', requireAdminKey, revokeHandler('agent'));
    app.post('/api/ci-pool/machines/:machine/telemetry-key', requireAdminKey, mintHandler('telemetry'));
    app.delete('/api/ci-pool/machines/:machine/telemetry-key', requireAdminKey, revokeHandler('telemetry'));

    return { reports };
}

module.exports = {
    registerCiPoolRoutes, requireCiHostKey, requireCiTelemetryKey, validatePoll, validateStateReport, PollValidationError,
    SCHEMA_VERSION, MAX_POLL_BYTES, MAX_STATE_BYTES, POLL_AFTER_SECONDS, POLL_AFTER_DORMANT_SECONDS,
    HOST_KEY_RE, TELEMETRY_KEY_RE,
};
