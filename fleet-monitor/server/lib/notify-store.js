//
//  notify-store.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Notification hub connection store (XACA-1400-001, EPIC-0068 plan D2/D4).
 *
 * Persists data/notify-store.json (fleet_data volume): operator-created
 * "connections" ({id, provider, label, params, secrets}) whose secret values
 * are AES-256-GCM encrypted under NOTIFY_STORE_KEY (a Fly secret).
 *
 *  - WRITE-ONLY SECRETS: the public view (listConnections/getConnection) reports
 *    a secret field as 'set' and nothing else. Only resolveConnection() returns
 *    plaintext, and it exists for the in-process dispatcher; no HTTP route may
 *    expose it.
 *  - FAIL CLOSED: a missing or malformed key builds the store in a `disabled`
 *    state (status() -> {enabled:false, reason}). Every mutation and
 *    resolveConnection() then throws NotifyStoreDisabledError. There is no
 *    plaintext fallback, and construction never throws on a bad key.
 *  - AAD = `${connectionId}:${field}`, so ciphertext cannot be swapped between
 *    connections or fields. Fresh 12-byte IV per secret value.
 *  - Atomic writes (temp + rename, mode 0600); in-memory state is swapped only
 *    after the write succeeds. A corrupt file is moved aside (".corrupt-<ts>")
 *    and the store starts empty; it never crashes boot.
 *  - Envelope v1 carries `routes: {}` untouched. XACA-1400-002 adds route
 *    methods inside the same factory via the internal _mutate() helper.
 *
 * Provider registry (injected): { has(name), get(name) }; a provider is
 * { name, paramFields, secretFields, validate(connection) } and validate is
 * sync, no network, throws NotifyConfigError.
 */

const fs     = require('fs');
const path   = require('path');
const crypto = require('crypto');
const teamRoutes = require('./notify-team-routes');
const { scrubText } = require('./notify-scrub');

const SCHEMA_VERSION = 1;
// One id grammar for connections, shared with the route schema (D5): a connection the
// store accepts must be one a team can route to.
const ID_RE = teamRoutes.ID_RE;
const MAX_LABEL = 200;
const MAX_VALUE = 4096;
const FILE_MODE = 0o600;

const has = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
const isPlainObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const clone = (o) => JSON.parse(JSON.stringify(o));

class NotifyStoreError extends Error {
    constructor(message, code, status) {
        super(message);
        this.name = 'NotifyStoreError';
        this.code = code || 'store_error';
        this.status = status || 500;
    }
}
class NotifyStoreDisabledError extends NotifyStoreError {
    constructor(reason) {
        super(`notify store disabled: ${reason}`, 'store_disabled', 503);
        this.name = 'NotifyStoreDisabledError';
    }
}
class NotifyValidationError extends NotifyStoreError {
    constructor(message) { super(message, 'invalid', 400); this.name = 'NotifyValidationError'; }
}
class NotifyNotFoundError extends NotifyStoreError {
    constructor(id) { super(`connection not found: ${id}`, 'not_found', 404); this.name = 'NotifyNotFoundError'; }
}
class NotifyConflictError extends NotifyStoreError {
    constructor(id) { super(`connection already exists: ${id}`, 'conflict', 409); this.name = 'NotifyConflictError'; }
}
/** Decrypt failure (wrong key, tampered data, AAD mismatch). Never carries the value. */
class NotifyCryptoError extends NotifyStoreError {
    constructor(id, field) {
        super(`cannot decrypt secret '${field}' of connection '${id}' (wrong key or tampered data)`, 'decrypt_failed', 500);
        this.name = 'NotifyCryptoError';
    }
}

/** Parse a 32-byte key from 64 hex chars or base64. Returns {key} or {reason}. */
function parseKey(raw) {
    if (Buffer.isBuffer(raw)) {
        return raw.length === 32 ? { key: Buffer.from(raw) } : { reason: 'NOTIFY_STORE_KEY must be 32 bytes' };
    }
    if (typeof raw !== 'string' || raw.trim() === '') {
        return { reason: 'NOTIFY_STORE_KEY is not set' };
    }
    const s = raw.trim();
    if (/^[0-9a-fA-F]{64}$/.test(s)) return { key: Buffer.from(s, 'hex') };
    if (/^[A-Za-z0-9+/]{43}=?$/.test(s) || /^[A-Za-z0-9_-]{43}=?$/.test(s)) {
        const b = Buffer.from(s.replace(/-/g, '+').replace(/_/g, '/'), 'base64');
        if (b.length === 32) return { key: b };
    }
    return { reason: 'NOTIFY_STORE_KEY is malformed (need 32 bytes as base64 or 64 hex chars)' };
}

function encryptValue(key, aad, plaintext) {
    const iv = crypto.randomBytes(12);
    const c = crypto.createCipheriv('aes-256-gcm', key, iv);
    c.setAAD(Buffer.from(aad, 'utf8'));
    const ct = Buffer.concat([c.update(plaintext, 'utf8'), c.final()]);
    return { iv: iv.toString('base64'), tag: c.getAuthTag().toString('base64'), ct: ct.toString('base64') };
}

function decryptValue(key, aad, envl) {
    const d = crypto.createDecipheriv('aes-256-gcm', key, Buffer.from(envl.iv, 'base64'));
    d.setAAD(Buffer.from(aad, 'utf8'));
    d.setAuthTag(Buffer.from(envl.tag, 'base64'));
    return Buffer.concat([d.update(Buffer.from(envl.ct, 'base64')), d.final()]).toString('utf8');
}

function isEnvelope(e) {
    return isPlainObject(e) && typeof e.iv === 'string' && typeof e.tag === 'string' && typeof e.ct === 'string';
}

function defaultFile() {
    return process.env.FLEET_NOTIFY_STORE_FILE || path.join(__dirname, '..', 'data', 'notify-store.json');
}

/**
 * @param {{file?:string, key?:string|Buffer|null, registry:{has:Function,get:Function}, clock?:()=>Date}} opts
 */
function createNotifyStore(opts) {
    opts = opts || {};
    const file = opts.file || defaultFile();
    const registry = opts.registry;
    const clock = typeof opts.clock === 'function' ? opts.clock : () => new Date();
    if (!registry || typeof registry.has !== 'function' || typeof registry.get !== 'function') {
        throw new TypeError('createNotifyStore: opts.registry with has()/get() is required');
    }

    const parsed = parseKey(opts.key !== undefined ? opts.key : process.env.NOTIFY_STORE_KEY);
    const key = parsed.key || null;
    const disabledReason = key ? null : parsed.reason;

    let state = { version: SCHEMA_VERSION, connections: {}, routes: {} };
    // Recovery trace (D3/D4): ids and a basename only, never contents.
    let movedAside = null;
    let quarantined = [];
    let recoveredEnvelope = false;

    // ----- persistence ------------------------------------------------------
    function load() {
        let text;
        try { text = fs.readFileSync(file, 'utf8'); } catch (e) {
            if (e.code === 'ENOENT') return;
            moveAside(); return;
        }
        let j;
        try {
            j = JSON.parse(text);
            if (!isPlainObject(j) || j.version !== SCHEMA_VERSION || !isPlainObject(j.connections)) {
                throw new Error('bad envelope');
            }
        } catch (_) { moveAside(); return; }
        // Per-entry validation (D3): one malformed connection must not take the others down.
        const good = {};
        const bad = [];
        for (const [id, c] of Object.entries(j.connections)) {
            const ok = isPlainObject(c) && c.id === id && isPlainObject(c.secrets) && isPlainObject(c.params)
                && Object.values(c.secrets).every(isEnvelope);
            if (ok) good[id] = c; else bad.push(ID_RE.test(id) ? id : '<invalid-id>');
        }
        state = {
            version: SCHEMA_VERSION,
            connections: good,
            routes: isPlainObject(j.routes) ? j.routes : {},
        };
        if (bad.length === 0) return;
        quarantined = bad;
        // Preserve the original bytes, then rewrite the file without the bad entries so the
        // next boot does not quarantine (and copy aside) the same file again.
        const aside = `${file}.corrupt-${clock().getTime()}`;
        try {
            fs.copyFileSync(file, aside);
            movedAside = path.basename(aside);
            persist(state);
        } catch (_) { /* best effort: the in-memory state is already usable */ }
    }
    function moveAside() {
        const aside = `${file}.corrupt-${clock().getTime()}`;
        try {
            fs.renameSync(file, aside);
            movedAside = path.basename(aside);
        } catch (_) { /* best effort */ }
        recoveredEnvelope = true;
    }
    function persist(next) {
        fs.mkdirSync(path.dirname(file), { recursive: true });
        const tmp = `${file}.tmp-${process.pid}-${crypto.randomBytes(4).toString('hex')}`;
        try {
            fs.writeFileSync(tmp, JSON.stringify(next, null, 2), { mode: FILE_MODE });
            fs.chmodSync(tmp, FILE_MODE);
            fs.renameSync(tmp, file);
        } catch (e) {
            try { fs.unlinkSync(tmp); } catch (_) { /* ignore */ }
            throw new NotifyStoreError(`failed to persist notify store: ${e.code || 'write error'}`, 'persist_failed', 500);
        }
    }
    /** Apply fn to a deep copy of state; persist; swap in only on success. Additive hook for routes (-002). */
    function mutate(fn) {
        requireEnabled();
        const draft = clone(state);
        const result = fn(draft);
        persist(draft);
        state = draft;
        return result;
    }
    function requireEnabled() {
        if (!key) throw new NotifyStoreDisabledError(disabledReason);
    }

    // ----- helpers ----------------------------------------------------------
    function publicView(c) {
        const secrets = {};
        for (const f of Object.keys(c.secrets)) secrets[f] = 'set';
        return {
            id: c.id, provider: c.provider, label: c.label,
            params: clone(c.params), secrets,
            createdAt: c.createdAt, updatedAt: c.updatedAt,
        };
    }
    function getProvider(name) {
        if (typeof name !== 'string' || !registry.has(name)) {
            throw new NotifyValidationError('unknown provider');
        }
        return registry.get(name);
    }
    function checkLabel(label) {
        if (typeof label !== 'string' || label.trim() === '' || label.length > MAX_LABEL) {
            throw new NotifyValidationError(`label must be a non-empty string up to ${MAX_LABEL} chars`);
        }
    }
    function checkParams(provider, params) {
        if (!isPlainObject(params)) throw new NotifyValidationError('params must be an object');
        for (const k of Object.keys(params)) {
            if (!provider.paramFields.includes(k)) throw new NotifyValidationError(`unknown param field for ${provider.name}: ${k.slice(0, 64)}`);
            const v = params[k];
            if (typeof v === 'string' && v.length > MAX_VALUE) throw new NotifyValidationError(`param '${k}' too long`);
        }
    }
    function checkSecretKeys(provider, secrets) {
        if (!isPlainObject(secrets)) throw new NotifyValidationError('secrets must be an object');
        for (const [k, v] of Object.entries(secrets)) {
            if (!provider.secretFields.includes(k)) throw new NotifyValidationError(`unknown secret field for ${provider.name}: ${k.slice(0, 64)}`);
            if (v !== null && typeof v !== 'string') throw new NotifyValidationError(`secret '${k}' must be a string (or null/'' to clear)`);
            if (typeof v === 'string' && v.length > MAX_VALUE) throw new NotifyValidationError(`secret '${k}' too long`);
        }
    }
    /** Run provider.validate on the would-be connection; scrub secret values from any message. */
    function runProviderValidate(provider, conn) {
        try {
            provider.validate(conn);
        } catch (e) {
            const msg = String((e && e.message) || 'invalid connection');
            throw new NotifyValidationError(scrubText(msg, Object.values(conn.secrets).filter((v) => typeof v === 'string'), 300));
        }
    }
    function decryptSecrets(c) {
        const out = {};
        for (const [f, envl] of Object.entries(c.secrets)) {
            try { out[f] = decryptValue(key, `${c.id}:${f}`, envl); }
            catch (_) { throw new NotifyCryptoError(c.id, f); }
        }
        return out;
    }

    // Canonical notice-type catalog (bundled; loaded lazily so a bad file cannot break boot).
    let canonicalDoc = null;
    function canonicalCatalog() {
        if (canonicalDoc) return canonicalDoc;
        try { canonicalDoc = teamRoutes.loadCanonicalCatalog(opts.catalogFile); }
        catch (_) { throw new NotifyStoreError('bundled notice-type catalog unavailable', 'catalog_unavailable', 500); }
        return canonicalDoc;
    }

    load();

    // ----- public API -------------------------------------------------------
    return {
        file,
        status() {
            const st = key ? { enabled: true } : { enabled: false, reason: disabledReason };
            if (recoveredEnvelope || quarantined.length > 0) {
                st.recovered = { movedAside, quarantined: quarantined.length };
                if (quarantined.length > 0) st.quarantined = quarantined.slice();
            }
            return st;
        },
        listConnections() {
            return Object.values(state.connections).map(publicView)
                .sort((a, b) => a.id.localeCompare(b.id));
        },
        getConnection(id) {
            const c = has(state.connections, id) ? state.connections[id] : null;
            return c ? publicView(c) : null;
        },
        createConnection(input) {
            requireEnabled();
            if (!isPlainObject(input)) throw new NotifyValidationError('body must be an object');
            const { id, provider: pname, label } = input;
            const params = input.params === undefined ? {} : input.params;
            const secrets = input.secrets === undefined ? {} : input.secrets;
            if (typeof id !== 'string' || !ID_RE.test(id)) throw new NotifyValidationError('id must match /^[a-z][a-z0-9-]{0,31}$/');
            const provider = getProvider(pname);
            checkLabel(label);
            checkParams(provider, params);
            checkSecretKeys(provider, secrets);
            const plain = {};
            for (const [k, v] of Object.entries(secrets)) if (typeof v === 'string' && v !== '') plain[k] = v;
            runProviderValidate(provider, { id, provider: pname, label, params, secrets: plain });
            return mutate((draft) => {
                if (has(draft.connections, id)) throw new NotifyConflictError(id);
                const now = clock().toISOString();
                const encd = {};
                for (const [k, v] of Object.entries(plain)) encd[k] = encryptValue(key, `${id}:${k}`, v);
                draft.connections[id] = {
                    id, provider: pname, label, params: clone(params),
                    secrets: encd, createdAt: now, updatedAt: now,
                };
                return publicView(draft.connections[id]);
            });
        },
        updateConnection(id, patch) {
            requireEnabled();
            if (!isPlainObject(patch)) throw new NotifyValidationError('body must be an object');
            const cur = has(state.connections, id) ? state.connections[id] : null;
            if (!cur) throw new NotifyNotFoundError(id);
            for (const k of Object.keys(patch)) {
                if (!['label', 'params', 'secrets', 'provider', 'id'].includes(k)) throw new NotifyValidationError(`unknown field: ${k.slice(0, 64)}`);
            }
            if (patch.id !== undefined && patch.id !== id) throw new NotifyValidationError('id cannot be changed');
            if (patch.provider !== undefined && patch.provider !== cur.provider) throw new NotifyValidationError('provider cannot be changed; delete and recreate');
            const provider = getProvider(cur.provider);
            const label = patch.label !== undefined ? patch.label : cur.label;
            const params = patch.params !== undefined ? patch.params : cur.params;
            checkLabel(label);
            checkParams(provider, params);
            const sp = patch.secrets === undefined ? {} : patch.secrets;
            checkSecretKeys(provider, sp);
            const plain = decryptSecrets(cur);
            for (const [k, v] of Object.entries(sp)) {
                if (v === null || v === '') delete plain[k]; else plain[k] = v;
            }
            runProviderValidate(provider, { id, provider: cur.provider, label, params, secrets: plain });
            return mutate((draft) => {
                const d = draft.connections[id];
                d.label = label;
                d.params = clone(params);
                for (const [k, v] of Object.entries(sp)) {
                    if (v === null || v === '') delete d.secrets[k];
                    else d.secrets[k] = encryptValue(key, `${id}:${k}`, v);
                }
                d.updatedAt = clock().toISOString();
                return publicView(d);
            });
        },
        deleteConnection(id) {
            requireEnabled();
            if (!has(state.connections, id)) throw new NotifyNotFoundError(id);
            mutate((draft) => { delete draft.connections[id]; });
            return true;
        },
        /** Full decrypted connection for the dispatcher ONLY. Never expose over HTTP. */
        resolveConnection(id) {
            requireEnabled();
            const c = has(state.connections, id) ? state.connections[id] : null;
            if (!c) return null;
            return {
                id: c.id, provider: c.provider, label: c.label,
                params: clone(c.params), secrets: decryptSecrets(c),
            };
        },
        /**
         * XACA-1400-002: validate + persist a team's pushed routes.
         * input = { config: <notify.json v2>, catalog?: <team notice_types.json layer> }.
         * Stores { config, catalog: <merged catalog>, updatedAt }. Fails closed
         * (NotifyStoreDisabledError, 503) when the store is disabled, same as
         * every other mutation.
         */
        setTeamRoutes(team, input) {
            requireEnabled();
            if (typeof team !== 'string' || !teamRoutes.TEAM_RE.test(team)) throw new NotifyValidationError('invalid team id');
            const canonical = canonicalCatalog();
            const res = teamRoutes.validateTeamPush(input, canonical);
            if (!res.ok) throw new NotifyValidationError(res.errors.join('; ').slice(0, 1000));
            return mutate((draft) => {
                if (!isPlainObject(draft.routes)) draft.routes = {};
                draft.routes[team] = { config: res.config, catalog: res.catalog, updatedAt: clock().toISOString() };
                return clone(draft.routes[team]);
            });
        },
        /** Stored { config, catalog, updatedAt } for a team, or null. No secrets live here. */
        getTeamRoutes(team) {
            const r = isPlainObject(state.routes) && has(state.routes, team) ? state.routes[team] : null;
            return r ? clone(r) : null;
        },
        /** Additive seam for XACA-1400-002 route methods. Not for HTTP callers. */
        _mutate: mutate,
        _state: () => state,
    };
}

module.exports = {
    createNotifyStore, parseKey, ID_RE,
    NotifyStoreError, NotifyStoreDisabledError, NotifyValidationError,
    NotifyNotFoundError, NotifyConflictError, NotifyCryptoError,
};
