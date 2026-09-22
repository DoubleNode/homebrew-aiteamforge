//
//  token-reports-routes.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Fleet token telemetry — weekly aggregate store (XACA-1300-003).
 *
 * Each machine's fleet-reporter.sh runs scripts/kb-token-report and POSTs the
 * resulting weekly record here. Design (normative):
 * kanban/plans/XACA-1300/XACA-1300-001_schema.md §6 (record + idempotency) and
 * §7 (fail-closed).
 *
 * THIS STORE IS THE SYSTEM OF RECORD. Claude Code keeps transcripts for 30
 * days, so a week older than ~4 weeks can never be regenerated on any machine.
 * Records are therefore never expired, never rolled up in place, and never
 * overwritten by something worse:
 *
 *   - Key: (machine_id, week). schema_version must be 1 (the only version the
 *     reader understands; a bump must add a reader here, not be accepted blind).
 *   - A re-send REPLACES the stored record (re-run = replace, design §6), or is
 *     reported "unchanged" when byte-identical — so retries are idempotent.
 *   - A stored `final:true` record is NEVER replaced by `final:false`, nor by a
 *     record whose coverage.complete is false (design §6, last bullet).
 *   - A record generated EARLIER than the stored one is refused (out-of-order
 *     delivery must not roll a week back).
 *   - Refusals are 409 with a machine-readable `reason`; the reporter treats
 *     409 as "the server already holds better data", not as a retryable error.
 *
 * STORAGE: one JSON file per (machine, week) under data/token-reports/
 * (the Fly volume mounted at /app/data), written temp+rename so a crash never
 * leaves a torn record. One file per week keeps each write small no matter how
 * many years of history accumulate. Override the root with
 * FLEET_TOKEN_REPORTS_DIR (tests point it at a temp dir).
 *
 * READ: GET /api/token-reports?week=YYYY-Www returns one entry per known
 * machine. A machine with no stored record for that week is
 * `status:"missing"` with `record:null` — NEVER a zero. "Known" is the union
 * of machines that have ever sent a token report and the fleet's live machine
 * roster (passed in by server.js), each entry labelled with where it came from.
 * GET /api/token-reports (no week) returns the history index: every stored
 * (machine, week) with its final/complete flags, no rows.
 *
 * CORRUPT FILES (XACA-1300-020): ?week= opens only that week's file per
 * machine (the roster comes from directory/file NAMES), so a torn record in
 * another week cannot fail it. A torn file for the requested week is reported
 * as status:"unreadable" (counted in summary.unreadable and listed in
 * unreadable_machines) — never "missing", never zero, never in the totals.
 * The index lists such a file with error:"unreadable" rather than failing.
 *
 * DEFAULT-OAUTH LABELLING: kb-token-report labels a session billed to the
 * machine's own OAuth login as account `default-oauth`, plus the login's hash
 * (coverage.default_oauth_account_hash). Which account that login IS comes from
 * config/token-oauth-accounts.json (FLEET_TOKEN_OAUTH_MAP overrides), applied
 * here at read time and never written back into the stored record. Outcomes:
 * the stated account (with its provenance), or `default-oauth:unmapped` (no
 * statement), `default-oauth:login-changed` (the record's login hash is not
 * the one the statement was made about) or `default-oauth:conflict` (one login
 * hash stated as two different accounts). Never a guess.
 *
 * HEADLESS ROUTE (historical): until XACA-1300-014, gate and scheduled
 * sessions wrote no session-account-map row, so kb-token-report files them
 * under `unattributed:not_in_map`. Their billing route is not the default login
 * by construction: kb-run-* pipe into cc(), which falls through to plain
 * `claude` outside a team window and inherits whatever auth token the launching
 * process carried. Account totals show those rows as
 * `unattributed:headless_route_unknown`, never folded into default-oauth or any
 * account. Once 014 ships, headless sessions carry map rows, attribute through
 * the normal path, and stop matching this rule on their own.
 *
 * AUTH (XACA-1300-003, corrected same-day): POST and both GETs are gated by
 * requireApiKey. The payload itself carries no secret, credential, ciphertext
 * or message content (the reporter only ever ships aggregates), but user
 * decision 2026-09-22 overrides the original "read routes are ungated like
 * /api/fleet, /api/kanban-stats" posture for THIS store specifically: the
 * per-machine token/account rollup is sensitive enough (account nicknames,
 * per-ticket spend, headless-route attribution) that it should not be
 * servable to an unauthenticated caller merely because other, coarser fleet
 * read routes are open. When FLEET_AUTH_TOKEN is unset the gate is open
 * (contract §7, unchanged) — matching every other requireApiKey route.
 */

const fs   = require('fs');
const path = require('path');

const { requireApiKey } = require('./auth-middleware');

const SUPPORTED_SCHEMA_VERSION = 1;
const RECORD_TYPE = 'kb-token-report.weekly';
const WEEK_RE = /^(\d{4})-W(\d{2})$/;
const MACHINE_ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const MAX_HOSTNAME_LEN = 255;
const CORE_FIELDS = ['input', 'output', 'cache_creation', 'cache_read'];

function storeRoot() {
    return process.env.FLEET_TOKEN_REPORTS_DIR
        || path.join(__dirname, '..', 'data', 'token-reports');
}

// ---------------------------------------------------------------------------
// ISO week helpers (UTC — the record's own convention)
// ---------------------------------------------------------------------------

function isoWeekOf(date) {
    const d = new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate()));
    const dow = d.getUTCDay() || 7;          // Mon=1..Sun=7
    d.setUTCDate(d.getUTCDate() + 4 - dow);  // Thursday of this ISO week
    const yearStart = new Date(Date.UTC(d.getUTCFullYear(), 0, 1));
    const week = Math.ceil(((d - yearStart) / 86400000 + 1) / 7);
    return `${d.getUTCFullYear()}-W${String(week).padStart(2, '0')}`;
}

/** The most recent ISO week that has fully closed at `now`. */
function lastCompletedWeek(now = new Date()) {
    return isoWeekOf(new Date(now.getTime() - 7 * 86400000));
}

// ---------------------------------------------------------------------------
// Validation — reject anything the rollup could misread. Never coerce.
// ---------------------------------------------------------------------------

function isNonNegInt(v) {
    return Number.isInteger(v) && v >= 0;
}

function tokensError(tokens, where) {
    if (!tokens || typeof tokens !== 'object') return `${where}.tokens must be an object`;
    for (const f of CORE_FIELDS.concat('total')) {
        if (!isNonNegInt(tokens[f])) return `${where}.tokens.${f} must be a non-negative integer`;
    }
    const sum = CORE_FIELDS.reduce((acc, f) => acc + tokens[f], 0);
    if (sum !== tokens.total) return `${where}.tokens.total (${tokens.total}) != sum of the four fields (${sum})`;
    return null;
}

/**
 * Validate the POST envelope { machine_id, hostname, record }.
 * Returns { status, error } on failure, or null when valid.
 */
function validateSubmission(body) {
    const { machine_id, hostname, record } = body || {};
    if (typeof machine_id !== 'string' || !MACHINE_ID_RE.test(machine_id)) {
        return { status: 400, error: 'machine_id is required (1-128 chars of [A-Za-z0-9._-])' };
    }
    if (typeof hostname !== 'string' || !hostname || hostname.length > MAX_HOSTNAME_LEN) {
        return { status: 400, error: `hostname is required (string, max ${MAX_HOSTNAME_LEN} chars)` };
    }
    if (!record || typeof record !== 'object' || Array.isArray(record)) {
        return { status: 400, error: 'record is required (object)' };
    }
    if (record.schema_version !== SUPPORTED_SCHEMA_VERSION) {
        return { status: 422, error: `unsupported schema_version ${JSON.stringify(record.schema_version)} (this server reads ${SUPPORTED_SCHEMA_VERSION})` };
    }
    if (record.record_type !== RECORD_TYPE) {
        return { status: 400, error: `record_type must be "${RECORD_TYPE}"` };
    }
    if (typeof record.week !== 'string' || !WEEK_RE.test(record.week)) {
        return { status: 400, error: 'record.week must match YYYY-Www' };
    }
    if (record.machine !== hostname) {
        // The reporter passes --machine "$HOSTNAME"; a mismatch means the record
        // was produced for a different machine than the one submitting it.
        return { status: 400, error: 'record.machine does not match the submitting hostname' };
    }
    if (typeof record.final !== 'boolean') {
        return { status: 400, error: 'record.final must be a boolean' };
    }
    if (typeof record.generated_at !== 'string' || Number.isNaN(Date.parse(record.generated_at))) {
        return { status: 400, error: 'record.generated_at must be an ISO timestamp' };
    }
    const cov = record.coverage;
    if (!cov || typeof cov !== 'object' || typeof cov.complete !== 'boolean') {
        return { status: 400, error: 'record.coverage.complete must be a boolean' };
    }
    if (!Array.isArray(record.rows)) {
        return { status: 400, error: 'record.rows must be an array (an empty week is [], never absent)' };
    }
    for (let i = 0; i < record.rows.length; i++) {
        const err = tokensError(record.rows[i] && record.rows[i].tokens, `rows[${i}]`);
        if (err) return { status: 400, error: err };
    }
    const items = record.tickets && record.tickets.items;
    if (Array.isArray(items)) {
        for (let i = 0; i < items.length; i++) {
            const err = tokensError(items[i] && items[i].tokens, `tickets.items[${i}]`);
            if (err) return { status: 400, error: err };
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Store — one file per (machine, week), atomic temp+rename
// ---------------------------------------------------------------------------

function entryPath(machineId, week) {
    // Both components are validated against strict regexes before reaching
    // here, so neither can contain a path separator or "..".
    return path.join(storeRoot(), machineId, `${week}.json`);
}

/** Returns the stored entry, null when absent. Throws on an unreadable file:
 *  a corrupt stored record must surface, never read as "missing". */
function readEntry(machineId, week) {
    const p = entryPath(machineId, week);
    let raw;
    try {
        raw = fs.readFileSync(p, 'utf8');
    } catch (e) {
        if (e.code === 'ENOENT') return null;
        throw e;
    }
    return JSON.parse(raw);
}

function writeEntry(machineId, week, entry) {
    const p = entryPath(machineId, week);
    fs.mkdirSync(path.dirname(p), { recursive: true });
    const tmp = `${p}.tmp.${process.pid}.${Date.now()}`;
    fs.writeFileSync(tmp, JSON.stringify(entry, null, 2));
    fs.renameSync(tmp, p);
}

/** Decide what an incoming record does to the stored one (design §6). */
function decide(stored, record) {
    if (!stored) return { action: 'stored' };
    const prev = stored.record;
    if (JSON.stringify(prev) === JSON.stringify(record)) return { action: 'unchanged' };
    if (prev.final === true && record.final !== true) {
        return { refuse: 'final_not_replaceable_by_partial' };
    }
    if (prev.final === true && record.coverage.complete !== true) {
        return { refuse: 'final_not_replaceable_by_incomplete' };
    }
    if (Date.parse(record.generated_at) < Date.parse(prev.generated_at)) {
        return { refuse: 'older_than_stored' };
    }
    return { action: 'replaced' };
}

/** Validated machine-id directory names in the store ([] when it does not exist yet). */
function storedMachineIds() {
    try {
        return fs.readdirSync(storeRoot(), { withFileTypes: true })
            .filter(d => d.isDirectory() && MACHINE_ID_RE.test(d.name)).map(d => d.name);
    } catch (e) {
        if (e.code === 'ENOENT') return [];
        throw e;
    }
}

/** Week names stored for one machine, by FILENAME only (no file is opened),
 *  ascending. Skips *.tmp.* leftovers. */
function storedWeeks(machineId) {
    const out = [];
    for (const f of fs.readdirSync(path.join(storeRoot(), machineId))) {
        const m = /^(\d{4}-W\d{2})\.json$/.exec(f);
        if (m) out.push(m[1]);
    }
    return out.sort();
}

/** readEntry that turns an unreadable/corrupt file into a per-file marker
 *  (XACA-1300-020): one torn record must not blind every other week, and it is
 *  never read as missing or zero either. */
function readEntrySafe(machineId, week) {
    try {
        return { entry: readEntry(machineId, week) };
    } catch (e) {
        return { error: 'unreadable', detail: String(e.message).slice(0, 200) };
    }
}

/** Every stored (machine, week) entry, without rows. A corrupt file is listed
 *  with error:"unreadable" instead of failing the whole index. */
function listIndex() {
    const out = [];
    for (const id of storedMachineIds()) {
        for (const week of storedWeeks(id)) {
            const { entry, error, detail } = readEntrySafe(id, week);
            if (error) { out.push({ machine_id: id, week, error, detail }); continue; }
            out.push({
                machine_id: id,
                hostname: entry.hostname,
                week,
                final: entry.record.final,
                complete: entry.record.coverage.complete,
                generated_at: entry.record.generated_at,
                stored_at: entry.stored_at,
            });
        }
    }
    out.sort((a, b) => (a.machine_id + a.week).localeCompare(b.machine_id + b.week));
    return out;
}

/** Hostname of a stored machine from its newest READABLE record (one read in
 *  the normal case); null when none is readable. */
function storedHostname(machineId, weeks) {
    for (let i = weeks.length - 1; i >= 0; i--) {
        const { entry } = readEntrySafe(machineId, weeks[i]);
        if (entry) return entry.hostname || null;
    }
    return null;
}

// ---------------------------------------------------------------------------
// default-oauth -> account labelling (read time only)
// ---------------------------------------------------------------------------

function oauthMapPath() {
    return process.env.FLEET_TOKEN_OAUTH_MAP
        || path.join(__dirname, '..', 'config', 'token-oauth-accounts.json');
}

/** Absent file = no statements (everything unmapped). A present-but-broken
 *  file throws: it must surface, never read as "unmapped". */
function loadOauthMap() {
    let raw;
    try {
        raw = fs.readFileSync(oauthMapPath(), 'utf8');
    } catch (e) {
        if (e.code === 'ENOENT') return {};
        throw e;
    }
    const machines = JSON.parse(raw).machines;
    if (!machines || typeof machines !== 'object') throw new Error('token-oauth-accounts: no "machines" object');
    return machines;
}

function shortName(host) {
    return String(host || '').toLowerCase().split('.')[0];
}

/** How one machine's default-oauth rows are labelled. */
function resolveDefaultOauth(map, record) {
    const loginHash = (record.coverage && record.coverage.default_oauth_account_hash) || null;
    const name = shortName(record.machine);
    const key = Object.keys(map).find(k => k === name
        || (Array.isArray(map[k].aliases) && map[k].aliases.includes(name))) || null;
    const entry = key ? map[key] : null;
    const out = { login_hash: loginHash, config_key: key, stated_account: null,
                  provenance: entry ? entry.provenance || null : null };
    if (!entry || !entry.default_oauth_account) return Object.assign(out, { resolved_as: 'default-oauth:unmapped' });
    out.stated_account = entry.default_oauth_account;
    const h = entry.login_hash_observed;
    if (h && h !== loginHash) return Object.assign(out, { resolved_as: 'default-oauth:login-changed' });
    const clash = h && Object.values(map).some(v => v.login_hash_observed === h
        && v.default_oauth_account && v.default_oauth_account !== entry.default_oauth_account);
    if (clash) return Object.assign(out, { resolved_as: 'default-oauth:conflict' });
    return Object.assign(out, { resolved_as: entry.default_oauth_account });
}

/** Fleet account totals for one week: every REPORTED machine's rows summed by
 *  account label. Missing machines contribute nothing; they are listed beside
 *  the totals, so a gap is never read as zero spend. */
function accountTotals(machines) {
    const totals = {};
    for (const m of machines) {
        if (m.status !== 'reported') continue;
        for (const row of m.record.rows) {
            let acct = row.account;
            if (acct === 'default-oauth') acct = m.default_oauth.resolved_as;
            else if (acct === 'unattributed:not_in_map'
                     && (row.session_class === 'gate' || row.session_class === 'scheduled')) {
                acct = 'unattributed:headless_route_unknown';
            }
            const t = totals[acct] || (totals[acct] = { input: 0, output: 0, cache_creation: 0, cache_read: 0, total: 0 });
            for (const f of CORE_FIELDS.concat('total')) t[f] += row.tokens[f];
        }
    }
    return totals;
}

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------

/**
 * @param {import('express').Application} app
 * @param {{ listFleetMachines?: () => Array<{machine_id: string, hostname: string}> }} [opts]
 *   listFleetMachines — the live fleet roster (server.js's machines Map), so a
 *   machine that reports status but never sent a token record shows as missing.
 */
function registerTokenReportsRoutes(app, opts = {}) {
    const listFleetMachines = opts.listFleetMachines || (() => []);

    app.post('/api/token-reports', requireApiKey, (req, res) => {
        const invalid = validateSubmission(req.body);
        if (invalid) return res.status(invalid.status).json({ error: invalid.error });

        const { machine_id, hostname, record } = req.body;
        try {
            const stored = readEntry(machine_id, record.week);
            const verdict = decide(stored, record);
            if (verdict.refuse) {
                return res.status(409).json({
                    error: 'refused', reason: verdict.refuse,
                    week: record.week, stored_final: stored.record.final,
                    stored_generated_at: stored.record.generated_at,
                });
            }
            const now = new Date().toISOString();
            if (verdict.action !== 'unchanged') {
                writeEntry(machine_id, record.week, {
                    machine_id,
                    hostname,
                    first_received_at: (stored && stored.first_received_at) || now,
                    stored_at: now,
                    record,
                });
            }
            return res.status(verdict.action === 'stored' ? 201 : 200).json({
                ok: true, action: verdict.action, machine_id, week: record.week, final: record.final,
            });
        } catch (e) {
            console.error('token-reports: store error:', e.message);
            return res.status(500).json({ error: 'store error' });
        }
    });

    app.get('/api/token-reports', requireApiKey, (req, res) => {
        const week = req.query.week;
        if (week === undefined) {
            try {
                return res.json({ entries: listIndex() });
            } catch (e) {
                console.error('token-reports: index error:', e.message);
                return res.status(500).json({ error: 'store unreadable' });
            }
        }
        if (typeof week !== 'string' || !(WEEK_RE.test(week) || week === 'last')) {
            return res.status(400).json({ error: 'week must be YYYY-Www or "last"' });
        }
        const wk = week === 'last' ? lastCompletedWeek() : week;

        const machines = [];
        const summary = { reported: 0, final: 0, partial: 0, missing: 0, unreadable: 0 };
        try {
            // Roster = every machine that ever sent a token report + the live
            // fleet. Built from directory and file NAMES; only this week's file
            // is opened per machine (XACA-1300-020), never the whole history.
            const roster = new Map();
            for (const id of storedMachineIds()) {
                roster.set(id, { hostname: null, weeks: storedWeeks(id), sources: new Set(['token-reports']) });
            }
            for (const m of listFleetMachines()) {
                if (!m || !m.machine_id) continue;
                if (!roster.has(m.machine_id)) roster.set(m.machine_id, { hostname: null, weeks: [], sources: new Set() });
                const info = roster.get(m.machine_id);
                info.sources.add('fleet');
                info.hostname = info.hostname || m.hostname || null;
            }
            const oauthMap = loadOauthMap();
            for (const [machineId, info] of roster) {
                const has = info.weeks.includes(wk);
                const got = has ? readEntrySafe(machineId, wk) : {};
                const entry = got.entry || null;
                const base = { machine_id: machineId,
                               hostname: (entry && entry.hostname)
                                   || (entry ? null : storedHostname(machineId, info.weeks.filter(w => w !== wk)))
                                   || info.hostname || null,
                               roster_sources: Array.from(info.sources).sort() };
                if (got.error) {
                    summary.unreadable++;
                    machines.push(Object.assign(base, { status: 'unreadable', error: got.error, detail: got.detail, record: null }));
                    continue;
                }
                if (!entry) {
                    summary.missing++;
                    machines.push(Object.assign(base, { status: 'missing', record: null }));
                    continue;
                }
                summary.reported++;
                summary[entry.record.final ? 'final' : 'partial']++;
                machines.push(Object.assign(base, {
                    status: 'reported', final: entry.record.final,
                    complete: entry.record.coverage.complete,
                    generated_at: entry.record.generated_at, stored_at: entry.stored_at,
                    default_oauth: resolveDefaultOauth(oauthMap, entry.record),
                    record: entry.record,
                }));
            }
        } catch (e) {
            console.error('token-reports: read error:', e.message);
            return res.status(500).json({ error: 'store unreadable' });
        }
        machines.sort((a, b) => String(a.hostname).localeCompare(String(b.hostname)));
        return res.json({
            week: wk, summary, account_totals: accountTotals(machines),
            missing_machines: machines.filter(m => m.status === 'missing').map(m => m.hostname || m.machine_id),
            unreadable_machines: machines.filter(m => m.status === 'unreadable').map(m => m.hostname || m.machine_id),
            machines,
        });
    });
}

module.exports = {
    registerTokenReportsRoutes,
    validateSubmission,
    decide,
    isoWeekOf,
    lastCompletedWeek,
    resolveDefaultOauth,
    accountTotals,
    SUPPORTED_SCHEMA_VERSION,
};
