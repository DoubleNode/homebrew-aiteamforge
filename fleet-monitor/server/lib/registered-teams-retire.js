//
//  registered-teams-retire.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1766-002: retire a stale machine slug from the registered-teams `machines` map.
 *
 * Contract: kanban/plans/XACA-1766/retire-contract.md (C1-C5). The route handlers in server.js
 * (and their hand-mirror in tests/helpers/app-factory.js) are deliberately thin; ALL decisions live
 * here so they are testable against the real code, not just the mirror.
 *
 * Order (C4/C5): validate -> compute the change -> APPEND AUDIT -> mutate memory -> persist.
 *   - audit append fails  -> 500 AUDIT_WRITE_FAILED, nothing mutated (fail-closed)
 *   - persist returns false -> in-memory pre-image restored, a second audit line with
 *     result "persist_failed" is appended, 500 PERSIST_FAILED
 *
 * Plain delete (C3): no tombstone. team-register re-adds the slug if the machine asserts it again.
 *
 * Audit file: append-only JSONL. Field ALLOWLIST enforced in code (unknown keys are dropped), so a
 * header, token, IP or body handed in by a careless caller can never be written.
 */

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const vaultStore = require('./vault-store');

const AUDIT_FIELDS = ['at', 'tier', 'scope', 'slug', 'teams', 'prior', 'requestId', 'result'];
const MAX_TEAMS = 500;
const MAX_STR = 256;
const REQUEST_ID_RE = /^[A-Za-z0-9._:-]{1,128}$/;

function str(v) {
    return typeof v === 'string' ? v.slice(0, MAX_STR) : null;
}

/** Reduce an audit entry to the allowlisted, scalar-only shape. Pure. */
function sanitizeAuditEntry(entry) {
    const src = entry && typeof entry === 'object' ? entry : {};
    const out = {};
    for (const key of AUDIT_FIELDS) {
        const v = src[key];
        if (v === undefined) continue;
        if (key === 'teams') {
            if (!Array.isArray(v)) continue;
            out.teams = v.filter((t) => typeof t === 'string').slice(0, MAX_TEAMS).map((t) => t.slice(0, MAX_STR));
        } else if (key === 'prior') {
            if (!v || typeof v !== 'object' || Array.isArray(v)) continue;
            const prior = {};
            for (const team of Object.keys(v).slice(0, MAX_TEAMS)) {
                const e = v[team] || {};
                prior[team.slice(0, MAX_STR)] = { machineId: str(e.machineId), lastSeen: str(e.lastSeen) };
            }
            out.prior = prior;
        } else if (key === 'requestId') {
            if (typeof v === 'string' && REQUEST_ID_RE.test(v)) out.requestId = v;
        } else {
            const s = str(v);
            if (s !== null) out[key] = s;
        }
    }
    return out;
}

/**
 * Build an appender bound to one file. The returned function THROWS on any I/O failure, because
 * the caller must not proceed unaudited. One appendFileSync per line (O_APPEND), mode 0600.
 */
function createRetireAudit(file) {
    return function appendRetireAudit(entry) {
        const line = JSON.stringify(sanitizeAuditEntry(entry)) + '\n';
        fs.mkdirSync(path.dirname(file), { recursive: true });
        fs.appendFileSync(file, line, { mode: 0o600 });
    };
}

/**
 * XACA-1766-012: write the registered-teams file via temp + rename, so a failure mid-write (disk
 * full, EIO) leaves the previous file intact instead of truncated. Same idiom as
 * ci-pool-store.js writeAtomic. Throws on failure; the temp file is removed best-effort.
 */
function writeTeamsFileAtomic(file, data) {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    const tmp = `${file}.tmp-${process.pid}`;
    try {
        fs.writeFileSync(tmp, JSON.stringify(data, null, 2));
        fs.renameSync(tmp, file);
    } catch (e) {
        try { fs.unlinkSync(tmp); } catch (_) { /* nothing to clean */ }
        throw e;
    }
}

function hasOwn(obj, key) {
    return Object.prototype.hasOwnProperty.call(obj, key);
}

function isValidSlug(slug) {
    return typeof slug === 'string' && vaultStore.SLUG_RE.test(slug) && slug.length <= vaultStore.MAX_SLUG_LEN;
}

function fail(status, code, error, extra) {
    return { status, body: Object.assign({ error, code }, extra || {}) };
}

/**
 * @param {object}   o
 * @param {'team'|'machine'} o.scope
 * @param {string}   [o.team]            required for scope 'team'
 * @param {string}   o.slug
 * @param {Map}      o.registeredTeams
 * @param {Function} o.saveRegisteredTeams  returns true on success, false on failure
 * @param {Function} o.appendRetireAudit    throws on failure
 * @param {string}   [o.requestId]  optional caller id; when absent or not REQUEST_ID_RE-shaped a
 *                                  random UUID is minted (XACA-1766-011) so the attempt line and a
 *                                  later persist_failed line for the same call can be correlated
 * @returns {{status:number, body:object}}
 */
function retireMachineSlug(o) {
    const { scope, team, slug, registeredTeams, saveRegisteredTeams, appendRetireAudit } = o;
    const requestId = typeof o.requestId === 'string' && REQUEST_ID_RE.test(o.requestId) ? o.requestId : crypto.randomUUID();

    if (!isValidSlug(slug)) {
        return fail(400, 'INVALID_MACHINE_SLUG', 'Invalid machineSlug', {
            message: `slug must match ${vaultStore.SLUG_RE} and be <= ${vaultStore.MAX_SLUG_LEN} characters`
        });
    }

    // Compute the change without touching state.
    const targets = [];
    if (scope === 'team') {
        const teamData = registeredTeams.get(team);
        if (!teamData) return fail(404, 'TEAM_NOT_REGISTERED', `Team '${team}' is not registered`);
        if (!hasOwn(teamData.machines || {}, slug)) {
            return fail(404, 'SLUG_NOT_REGISTERED', `Slug '${slug}' is not registered for team '${team}'`);
        }
        targets.push([team, teamData]);
    } else {
        for (const [teamId, teamData] of registeredTeams.entries()) {
            if (hasOwn((teamData && teamData.machines) || {}, slug)) targets.push([teamId, teamData]);
        }
        if (targets.length === 0) {
            return fail(404, 'SLUG_NOT_REGISTERED', `Slug '${slug}' is not registered for any team`);
        }
    }

    const teams = targets.map(([id]) => id);
    const removed = {};
    for (const [id, data] of targets) removed[id] = data.machines[slug];
    const prior = {};
    for (const id of teams) prior[id] = { machineId: removed[id].machineId, lastSeen: removed[id].lastSeen };
    const auditBase = { tier: 'admin', scope, slug, teams, prior, requestId };

    // Audit BEFORE mutation; if it cannot be written, nothing changes.
    try {
        appendRetireAudit(Object.assign({ at: new Date().toISOString() }, auditBase));
    } catch (err) {
        console.error('[RETIRE] audit append failed, refusing to mutate:', err && err.message);
        return fail(500, 'AUDIT_WRITE_FAILED', 'Audit log write failed; nothing was retired');
    }

    // Mutate memory by replacing each team record (the originals are the pre-image), then persist.
    const preImage = new Map(targets);
    const machinesAfter = {};
    for (const [id, data] of targets) {
        const after = Object.assign({}, data.machines);
        delete after[slug];
        machinesAfter[id] = after;
        registeredTeams.set(id, Object.assign({}, data, { machines: after }));
    }

    if (saveRegisteredTeams() !== true) {
        for (const [id, original] of preImage) registeredTeams.set(id, original);
        try {
            appendRetireAudit(Object.assign({ at: new Date().toISOString(), result: 'persist_failed' }, auditBase));
        } catch (err) {
            console.error('[RETIRE] persist_failed audit append also failed:', err && err.message);
        }
        return fail(500, 'PERSIST_FAILED', 'Could not persist registered teams; retirement rolled back');
    }

    console.log(`[RETIRE] slug '${slug}' retired from ${teams.length} team(s) (scope: ${scope})`);
    return {
        status: 200,
        body: { success: true, scope, slug, removedFrom: teams, removed, machines: machinesAfter }
    };
}

module.exports = { retireMachineSlug, createRetireAudit, sanitizeAuditEntry, writeTeamsFileAtomic, AUDIT_FIELDS };
