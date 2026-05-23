//
//  vault-store.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * vault-store.js
 * XACA-0537-003: Secret Vault — encrypted-at-rest store helpers.
 *
 * Persists to fleet-monitor/server/data/vault.json.
 * Schema: v1 envelope from SECRET-VAULT-DESIGN.md §6.
 *
 * Pattern: mirrors engines-store.js exactly — atomic temp+rename writes,
 * auto-seed on missing file, same error shapes.
 *
 * Exports:
 *   readVault()                               — load vault, auto-seed if missing
 *   writeVault(data)                          — atomic write, returns boolean
 *   findMachine(id)                           — lookup by machine id
 *   findSecret(engineSlug, accountSlug)       — lookup by primary key
 *   upsertMachine(machine)                    — add or update machine entry
 *   removeMachine(id)                         — remove machine by id
 *   upsertSecret(secret)                      — add or update secret entry
 *   removeSecret(engineSlug, accountSlug)     — remove secret by primary key
 *
 * CRYPTO RULE (design doc §3, §7.3):
 *   - Server NEVER calls crypto_box_seal_open. It never has plaintext.
 *   - Server validates public_key decodes to exactly 32 bytes.
 *   - Server validates sealed decodes to ≥ crypto_box_SEALBYTES (48).
 *   - Validation is in vault-crypto.js helpers (isValid32ByteKey, isValidSealedBox).
 *   - Mutation helpers in this file enforce validation rules; route layer (004)
 *     adds business-logic validation (engine/account existence, slug RE, etc.).
 *
 * ENCODING: base64 ORIGINAL variant everywhere (see design doc §3.5).
 */

const fs   = require('fs');
const path = require('path');

const { isValid32ByteKey, isValidSealedBox } = require('./vault-crypto');

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

// Default path is unchanged production behavior. FLEET_VAULT_FILE is an ADDITIVE
// test seam (XACA-0537-006): when set, the store reads/writes that path instead,
// letting tests point at isolated temp files so they never touch the real
// data/vault.json. Default (env unset) is byte-identical to prior behavior.
const VAULT_FILE = process.env.FLEET_VAULT_FILE || path.join(__dirname, '..', 'data', 'vault.json');

// Mirror engines-store.js / design doc §7.3 size limits.
const MAX_FIELD_LEN  = 200;
const MAX_SLUG_LEN   = 64;
const MAX_SEALED_LEN = 8192;  // base64 chars, ~6 KB plaintext ceiling
const MAX_CIPHERTEXTS = 64;   // max per-recipient entries per secret

const SLUG_RE = /^[a-z][a-z0-9-]*$/;

/** Empty vault shape — written when vault.json is missing. See design doc §6.5. */
const EMPTY_SEED = {
    version:    1,
    updated_at: '',
    machines:   [],
    secrets:    [],
};

// ---------------------------------------------------------------------------
// Core I/O — mirrors engines-store.js
// ---------------------------------------------------------------------------

/**
 * Read the vault from disk. Auto-creates vault.json with the empty seed
 * if it does not exist (same pattern as readEngines).
 * @returns {{ version: number, updated_at: string, machines: Array, secrets: Array }}
 */
function readVault() {
    try {
        if (fs.existsSync(VAULT_FILE)) {
            return JSON.parse(fs.readFileSync(VAULT_FILE, 'utf8'));
        }
    } catch (err) {
        console.error('[vault-store] Error reading vault.json:', err.message);
    }

    // File missing or unreadable — seed it.
    const seed = Object.assign({}, EMPTY_SEED, {
        updated_at: new Date().toISOString(),
        machines:   [],
        secrets:    [],
    });
    writeVault(seed);
    return seed;
}

/**
 * Persist the vault to disk using an atomic temp+rename write.
 * Mirrors writeEngines — `.tmp.${process.pid}` suffix, renameSync for atomicity,
 * best-effort temp cleanup on error.
 *
 * NOTE: callers are responsible for setting `data.updated_at` before writing.
 * The store does NOT auto-set updated_at here so the route layer controls
 * the timestamp (mirrors engines-store.js behavior).
 *
 * @param {{ version: number, updated_at: string, machines: Array, secrets: Array }} data
 * @returns {boolean} true on success
 */
function writeVault(data) {
    const dir = path.dirname(VAULT_FILE);
    const tmp = `${VAULT_FILE}.tmp.${process.pid}`;
    try {
        if (!fs.existsSync(dir)) {
            fs.mkdirSync(dir, { recursive: true });
        }
        fs.writeFileSync(tmp, JSON.stringify(data, null, 2));
        fs.renameSync(tmp, VAULT_FILE);
        return true;
    } catch (err) {
        console.error('[vault-store] Error writing vault.json:', err.message);
        try { fs.unlinkSync(tmp); } catch (_) {}
        return false;
    }
}

// ---------------------------------------------------------------------------
// Lookup helpers
// ---------------------------------------------------------------------------

/**
 * Find a registered machine by its stable id.
 * @param {string} id
 * @returns {object|null}
 */
function findMachine(id) {
    const vault = readVault();
    return vault.machines.find(m => m.id === id) || null;
}

/**
 * Find a secret by its composite primary key: (engine_slug, account_slug).
 * @param {string} engineSlug
 * @param {string} accountSlug
 * @returns {object|null}
 */
function findSecret(engineSlug, accountSlug) {
    const vault = readVault();
    return vault.secrets.find(
        s => s.engine_slug === engineSlug && s.account_slug === accountSlug
    ) || null;
}

// ---------------------------------------------------------------------------
// Mutation helpers
// ---------------------------------------------------------------------------

/**
 * Validate a machine entry's required fields.
 * Returns an array of error strings; empty array = valid.
 *
 * Enforces design doc §6.2 rules:
 *   - id: required, matches SLUG_RE, ≤ MAX_SLUG_LEN
 *   - label: required, non-empty, ≤ MAX_FIELD_LEN
 *   - public_key: required, base64 decoding to exactly 32 bytes
 *
 * IMPORTANT: sodium must be initialized (await ensureReady()) before this is
 * called, because isValid32ByteKey calls sodium.from_base64 internally.
 * Route layer (004) is responsible for ensuring sodium is ready.
 *
 * @param {object} machine
 * @returns {string[]}
 */
function validateMachineFields(machine) {
    const errors = [];
    if (!machine.id || typeof machine.id !== 'string') {
        errors.push('id is required');
    } else if (!SLUG_RE.test(machine.id)) {
        errors.push('id must match ^[a-z][a-z0-9-]*$');
    } else if (machine.id.length > MAX_SLUG_LEN) {
        errors.push(`id must be ≤ ${MAX_SLUG_LEN} characters`);
    }
    if (!machine.label || typeof machine.label !== 'string' || machine.label.trim() === '') {
        errors.push('label is required and must be non-empty');
    } else if (machine.label.length > MAX_FIELD_LEN) {
        errors.push(`label must be ≤ ${MAX_FIELD_LEN} characters`);
    }
    if (!machine.public_key || typeof machine.public_key !== 'string') {
        errors.push('public_key is required');
    } else if (!isValid32ByteKey(machine.public_key)) {
        errors.push('public_key must be base64 (ORIGINAL) encoding of exactly 32 bytes');
    }
    return errors;
}

/**
 * Validate a ciphertext entry's fields.
 * Returns an array of error strings; empty array = valid.
 *
 * Enforces design doc §6.4 / §7.3 rules:
 *   - machine_id: required, matches SLUG_RE, ≤ MAX_SLUG_LEN
 *   - sealed: required, base64 string, decodes to ≥ crypto_box_SEALBYTES (48),
 *             ≤ MAX_SEALED_LEN base64 chars
 *
 * NOTE: does NOT verify machine_id is registered — that's a business-logic check
 * for the route layer (004), not a structural field check.
 *
 * @param {object} ct   ciphertext entry
 * @returns {string[]}
 */
function validateCiphertextFields(ct) {
    const errors = [];
    if (!ct.machine_id || typeof ct.machine_id !== 'string') {
        errors.push('ciphertext.machine_id is required');
    } else if (!SLUG_RE.test(ct.machine_id)) {
        errors.push('ciphertext.machine_id must match ^[a-z][a-z0-9-]*$');
    } else if (ct.machine_id.length > MAX_SLUG_LEN) {
        errors.push(`ciphertext.machine_id must be ≤ ${MAX_SLUG_LEN} characters`);
    }
    if (!ct.sealed || typeof ct.sealed !== 'string') {
        errors.push('ciphertext.sealed is required');
    } else if (ct.sealed.length > MAX_SEALED_LEN) {
        errors.push(`ciphertext.sealed must be ≤ ${MAX_SEALED_LEN} base64 characters`);
    } else if (!isValidSealedBox(ct.sealed)) {
        errors.push(`ciphertext.sealed must be a base64 (ORIGINAL) sealed box of ≥ 48 bytes`);
    }
    return errors;
}

/**
 * Validate a secret entry's required fields.
 * Returns an array of error strings; empty array = valid.
 *
 * Enforces design doc §6.3 / §7.3 rules:
 *   - engine_slug: required, slug format, ≤ MAX_SLUG_LEN
 *   - account_slug: required, slug format, ≤ MAX_SLUG_LEN
 *   - label: optional but if present ≤ MAX_FIELD_LEN
 *   - ciphertexts: required, non-empty, ≤ MAX_CIPHERTEXTS, all entries valid
 *
 * @param {object} secret
 * @returns {string[]}
 */
function validateSecretFields(secret) {
    const errors = [];
    if (!secret.engine_slug || typeof secret.engine_slug !== 'string') {
        errors.push('engine_slug is required');
    } else if (!SLUG_RE.test(secret.engine_slug)) {
        errors.push('engine_slug must match ^[a-z][a-z0-9-]*$');
    } else if (secret.engine_slug.length > MAX_SLUG_LEN) {
        errors.push(`engine_slug must be ≤ ${MAX_SLUG_LEN} characters`);
    }
    if (!secret.account_slug || typeof secret.account_slug !== 'string') {
        errors.push('account_slug is required');
    } else if (!SLUG_RE.test(secret.account_slug)) {
        errors.push('account_slug must match ^[a-z][a-z0-9-]*$');
    } else if (secret.account_slug.length > MAX_SLUG_LEN) {
        errors.push(`account_slug must be ≤ ${MAX_SLUG_LEN} characters`);
    }
    if (secret.label !== undefined) {
        if (typeof secret.label !== 'string') {
            errors.push('label must be a string');
        } else if (secret.label.length > MAX_FIELD_LEN) {
            errors.push(`label must be ≤ ${MAX_FIELD_LEN} characters`);
        }
    }
    if (!Array.isArray(secret.ciphertexts) || secret.ciphertexts.length === 0) {
        errors.push('ciphertexts must be a non-empty array');
    } else if (secret.ciphertexts.length > MAX_CIPHERTEXTS) {
        errors.push(`ciphertexts must have ≤ ${MAX_CIPHERTEXTS} entries`);
    } else {
        secret.ciphertexts.forEach((ct, idx) => {
            validateCiphertextFields(ct).forEach(e => errors.push(`ciphertexts[${idx}]: ${e}`));
        });
    }
    return errors;
}

/**
 * Add or update a machine entry in the vault.
 *
 * - If a machine with `machine.id` already exists, its `public_key`, `label`,
 *   and `updated_at` are updated (key rotation or label edit). `registered_at`
 *   and `id` are immutable once set.
 * - If no machine with `machine.id` exists, it is appended with a new
 *   `registered_at` (server-set).
 * - Validates fields via validateMachineFields; returns { ok, errors } shape.
 *
 * @param {{ id: string, label: string, public_key: string, registered_at?: string, updated_at?: string }} machine
 * @returns {{ ok: boolean, machine?: object, errors?: string[] }}
 */
function upsertMachine(machine) {
    const errors = validateMachineFields(machine);
    if (errors.length > 0) return { ok: false, errors };

    const vault = readVault();
    const now = new Date().toISOString();
    const idx = vault.machines.findIndex(m => m.id === machine.id);

    let entry;
    if (idx >= 0) {
        // Update existing — preserve registered_at and id, update everything else.
        entry = Object.assign({}, vault.machines[idx], {
            label:      machine.label,
            public_key: machine.public_key,
            updated_at: now,
        });
        vault.machines[idx] = entry;
    } else {
        // New registration.
        entry = {
            id:            machine.id,
            label:         machine.label,
            public_key:    machine.public_key,
            registered_at: now,
            updated_at:    now,
        };
        vault.machines.push(entry);
    }

    vault.updated_at = now;
    const written = writeVault(vault);
    return written ? { ok: true, machine: entry } : { ok: false, errors: ['Failed to persist vault'] };
}

/**
 * Remove a machine by id.
 * Does NOT cascade-delete orphaned ciphertext entries — that is intentional
 * per design doc §4.4 ("harmless orphaned copies; rotate upstream on key leak").
 *
 * @param {string} id
 * @returns {{ ok: boolean, existed: boolean }}
 */
function removeMachine(id) {
    const vault = readVault();
    const idx = vault.machines.findIndex(m => m.id === id);
    if (idx < 0) return { ok: true, existed: false };

    vault.machines.splice(idx, 1);
    vault.updated_at = new Date().toISOString();
    const written = writeVault(vault);
    return { ok: written, existed: true };
}

/**
 * Add or update a secret entry in the vault.
 *
 * - (engine_slug, account_slug) is the primary key (design doc §6.3).
 * - If the secret already exists, its `ciphertexts` array is REPLACED entirely
 *   (this is a re-seal — the new ciphertext array supersedes the old one).
 *   `label` is updated if provided; `created_at` is preserved; `updated_at` bumped.
 * - If the secret does not exist, it is created with server-set timestamps.
 * - Validates fields via validateSecretFields; returns { ok, errors } shape.
 *
 * @param {{ engine_slug: string, account_slug: string, label?: string, ciphertexts: Array }} secret
 * @returns {{ ok: boolean, secret?: object, errors?: string[] }}
 */
function upsertSecret(secret) {
    const errors = validateSecretFields(secret);
    if (errors.length > 0) return { ok: false, errors };

    const vault = readVault();
    const now = new Date().toISOString();
    const idx = vault.secrets.findIndex(
        s => s.engine_slug === secret.engine_slug && s.account_slug === secret.account_slug
    );

    // Normalize ciphertexts — ensure sealed_at is set (use now if client omitted it).
    const normalizedCiphertexts = secret.ciphertexts.map(ct => ({
        machine_id: ct.machine_id,
        sealed:     ct.sealed,
        sealed_at:  ct.sealed_at || now,
    }));

    let entry;
    if (idx >= 0) {
        // Replace ciphertext array; update label if provided; preserve created_at.
        entry = Object.assign({}, vault.secrets[idx], {
            label:       secret.label !== undefined ? secret.label : vault.secrets[idx].label,
            updated_at:  now,
            ciphertexts: normalizedCiphertexts,
        });
        vault.secrets[idx] = entry;
    } else {
        // New secret.
        entry = {
            engine_slug:  secret.engine_slug,
            account_slug: secret.account_slug,
            label:        secret.label || '',
            created_at:   now,
            updated_at:   now,
            ciphertexts:  normalizedCiphertexts,
        };
        vault.secrets.push(entry);
    }

    vault.updated_at = now;
    const written = writeVault(vault);
    return written ? { ok: true, secret: entry } : { ok: false, errors: ['Failed to persist vault'] };
}

/**
 * Remove a secret by its primary key (engine_slug, account_slug).
 *
 * @param {string} engineSlug
 * @param {string} accountSlug
 * @returns {{ ok: boolean, existed: boolean }}
 */
function removeSecret(engineSlug, accountSlug) {
    const vault = readVault();
    const idx = vault.secrets.findIndex(
        s => s.engine_slug === engineSlug && s.account_slug === accountSlug
    );
    if (idx < 0) return { ok: true, existed: false };

    vault.secrets.splice(idx, 1);
    vault.updated_at = new Date().toISOString();
    const written = writeVault(vault);
    return { ok: written, existed: true };
}

// ---------------------------------------------------------------------------
// Vault mode detection (XACA-0539 — /api/vault/mode endpoint)
// ---------------------------------------------------------------------------

/**
 * Detect whether the server is running in full vault mode or env-var failover.
 *
 * Heuristic (per VAULT-MODE-SIGNAL-CONTRACT.md §Implementation Notes):
 *   - If the vault store file exists and is readable → "vault" mode.
 *     The file may be empty/seeded (no machines/secrets yet), but its presence
 *     means the server is using the encrypted-at-rest data path.
 *   - If the file is absent or cannot be read → "env_failover".
 *     This signals that vault has not been provisioned on this server and the
 *     LCARS popup should warn the operator.
 *
 * NOTE: This function never reads secret data — only tests file existence and
 * parsability (no crypto, no plaintext, no private keys). Safe to call from
 * any route handler. NEVER returns any credential material in its result.
 *
 * @returns {{ mode: 'vault'|'env_failover', source: string }}
 */
function getVaultMode() {
    try {
        if (fs.existsSync(VAULT_FILE)) {
            // Verify the file is parseable (not corrupted) — parse-then-discard.
            JSON.parse(fs.readFileSync(VAULT_FILE, 'utf8'));
            return {
                mode:   'vault',
                source: 'encrypted vault',
            };
        }
    } catch (_) {
        // File exists but is unreadable or unparseable → treat as failover.
    }
    return {
        mode:   'env_failover',
        source: 'environment variable fallback (FLEET_VAULT_KEY)',
    };
}

// ---------------------------------------------------------------------------
// Exports
// ---------------------------------------------------------------------------

module.exports = {
    // Core I/O
    readVault,
    writeVault,
    // Lookups
    findMachine,
    findSecret,
    // Mutations
    upsertMachine,
    removeMachine,
    upsertSecret,
    removeSecret,
    // Validation (exported so route layer 004 can call them directly)
    validateMachineFields,
    validateSecretFields,
    validateCiphertextFields,
    // Mode detection (XACA-0539)
    getVaultMode,
    // Constants (exported for route layer + tests)
    VAULT_FILE,
    MAX_FIELD_LEN,
    MAX_SLUG_LEN,
    MAX_SEALED_LEN,
    MAX_CIPHERTEXTS,
    SLUG_RE,
};
