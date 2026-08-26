//
//  vault-keygen.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * vault-keygen.js
 * EPIC-0016 Phase A.4.1 / XACA-0537-002 — Machine keypair generation + registration.
 *
 * CLIENT SIDE ONLY. This tool:
 *   1. Generates a machine X25519 keypair (crypto_box_keypair via libsodium-wrappers).
 *   2. Stores the PRIVATE key locally — macOS Keychain (preferred) or a chmod-600
 *      file (fallback). NEVER printed, NEVER committed, NEVER sent to the server.
 *   3. Registers the PUBLIC key with the Fleet Monitor vault registration endpoint
 *      (POST /api/vault/machines, or PUT .../:id for rotation) per
 *      SECRET-VAULT-DESIGN.md §7.1.
 *
 * The server-side routes are subitem 004's job; this code is written against the
 * contract in SECRET-VAULT-DESIGN.md §7, not against a live server.
 *
 * Design decisions resolved here (SECRET-VAULT-DESIGN.md §8):
 *   - §8.1 machine_id: CLIENT-PROPOSED slug. Defaults to a slugified hostname,
 *     overridable via --machine-id. Collisions surface as a 409 from the server;
 *     the caller picks a different slug or uses --rotate to update the existing one.
 *   - §8.2 key rotation: IN-PLACE update via PUT /api/vault/machines/:id (keeps the
 *     id, replaces public_key). Re-sealing of existing secrets is downstream
 *     (A.4.2/A.4.3) and is NOT done here — see §5.4.
 *
 * ───────────────────────────────────────────────────────────────────────────
 * Private-key storage locations (document & keep in sync with downstream open tooling):
 *   - macOS Keychain: generic-password item
 *       service = "com.aiteamforge.vault"
 *       account = "<machine-slug>"
 *     Read back with: security find-generic-password -s com.aiteamforge.vault -a <slug> -w
 *   - Fallback file: ~/.aiteamforge/vault/<machine-slug>.key   (mode 0600, dir 0700)
 *     Contents: base64 (ORIGINAL variant) of the 32-byte X25519 private key, single line.
 * ───────────────────────────────────────────────────────────────────────────
 *
 * libsodium-wrappers initializes ASYNCHRONOUSLY. Every entry point here awaits
 * sodium.ready before touching crypto — see SECRET-VAULT-DESIGN.md §3.3.
 */

const os            = require('os');
const fs            = require('fs');
const path          = require('path');
const { execFileSync } = require('child_process');

// ── Constants (mirror server-side validation, SECRET-VAULT-DESIGN.md §6.2 / §7.3) ──
const SLUG_RE        = /^[a-z][a-z0-9-]*$/;
const MAX_SLUG_LEN   = 64;
const MAX_FIELD_LEN  = 200;
const X25519_KEY_BYTES = 32;

const KEYCHAIN_SERVICE = 'com.aiteamforge.vault';
const VAULT_DIR        = path.join(os.homedir(), '.aiteamforge', 'vault');
const BASE64_ORIGINAL  = 'base64.ORIGINAL'; // sentinel; resolved against sodium at runtime

// -----------------------------------------------------------------------------
// Fleet URL resolution (XACA-0972-001)
// -----------------------------------------------------------------------------
//
// The vault clients used to default to `http://localhost:3000` when
// FLEET_MONITOR_URL was unset. Nothing listens on :3000 on a normal fleet
// machine, so every vault call died as "Network error fetching ciphertext:
// fetch failed" - measured on M3Pro 2026-08-25, where the identical call
// succeeded the moment the URL was supplied. A silent localhost fallback for a
// FLEET service is the wrong default: it turns "not configured" into
// "connection refused", which reads as a network fault rather than a missing
// setting. There is no localhost fallback here, by design.
//
// This mirrors _kb_msg_relay_url in kanban-helpers.sh - keep the two in sync.
//
// These live in vault-keygen.js rather than a new shared module ON PURPOSE:
// vault-fetch.js, msg-client.js and vault-migrate-env-keys.js already require
// this file, and it is the ONLY vault file mirrored into the Homebrew tap
// (sync-tap.sh). A new module would also have to be added to sync-tap.sh AND
// install-shell.sh's copy allowlist, or a tap-installed consumer would die on
// MODULE_NOT_FOUND at require time. For the same reason this block uses node
// builtins only (os/fs/path, already required above) - add no new top-level
// require to this file.

/**
 * Every fleet-config.json location we consult, in precedence order:
 * ~/.aiteamforge/ first, then the legacy ~/.dev-team/ location.
 *
 * Returned as a LIST, not a single winner, because resolveFleetUrl() must be
 * able to fall THROUGH a file that exists but carries no apiEndpoint - see the
 * note on resolveFleetUrl below. Computed per call (never cached at module
 * scope) so a test that redirects $HOME is actually honoured.
 * @returns {string[]} absolute paths, most-preferred first (may not exist)
 */
function fleetConfigCandidates() {
    return [
        path.join(os.homedir(), '.aiteamforge', 'fleet-config.json'),
        path.join(os.homedir(), '.dev-team', 'fleet-config.json'),
    ];
}

/**
 * Locate the fleet-config.json the fleet reporters read.
 * Prefers ~/.aiteamforge/, falls back to the legacy ~/.dev-team/ location.
 * Mirrors msg-client.js fleetConfigPath(). When neither exists the preferred
 * path is returned anyway, so callers have a concrete path to name in an error.
 *
 * This is the path we NAME IN DIAGNOSTICS. It is deliberately NOT the one
 * resolveFleetUrl() reads from - that one loops (XACA-0972-016).
 * @returns {string} absolute path (which may not exist)
 */
function fleetConfigPath() {
    const candidates = fleetConfigCandidates();
    for (const c of candidates) {
        if (fs.existsSync(c)) return c;
    }
    return candidates[0];
}

// -----------------------------------------------------------------------------
// Fleet URL validation (XACA-0972-022)
// -----------------------------------------------------------------------------
//
// The resolved URL no longer comes only from an env var the operator typed this
// session - it now comes from a FILE on disk. vault-migrate-env-keys seals real
// API keys to machine public keys FETCHED FROM THIS HOST, so a hostile or
// corrupted fleet-config.json can redirect key material to an attacker-chosen
// server. That makes the config file an input worth validating, not just parsing.
//
// Rules, and why each one:
//   - must parse as an absolute URL           - a bare "example.com" or a typo'd
//                                               fragment is a misconfiguration
//   - scheme must be http: or https:          - blocks file:, data:, javascript:
//                                               and any other exotic scheme from
//                                               reaching a fetch() call site
//   - host must be non-empty                  - "http:///path" resolves to no host
//   - NO embedded userinfo (user:pass@host)   - "https://fleet-monitor.fly.dev@evil
//                                               .example/" reads to a human as the
//                                               real host but RESOLVES to
//                                               evil.example. That is the exact
//                                               confusion this check exists to stop,
//                                               and it also keeps credentials out of
//                                               a URL we may echo in diagnostics.
//
// https is NOT required: a LAN/dev fleet-monitor over plain http is a legitimate
// deployment, and the tests exercise it. Tightening that is a separate decision.

const ALLOWED_FLEET_SCHEMES = ['http:', 'https:'];

/**
 * Validate a candidate fleet base URL.
 * @param {string} value
 * @returns {{ ok: true, url: string }|{ ok: false, reason: string }}
 *          `reason` is short, human-actionable, and never echoes credentials.
 */
function validateFleetUrl(value) {
    if (typeof value !== 'string' || value.trim().length === 0) {
        return { ok: false, reason: 'is empty' };
    }
    let parsed;
    try {
        parsed = new URL(value);           // WHATWG URL is a Node global - no new require
    } catch (_) {
        return { ok: false, reason: `is not a valid absolute URL: ${JSON.stringify(value)}` };
    }
    if (!ALLOWED_FLEET_SCHEMES.includes(parsed.protocol)) {
        return {
            ok: false,
            reason: `uses unsupported scheme "${parsed.protocol}" ` +
                    `(only ${ALLOWED_FLEET_SCHEMES.join(' and ')} are allowed)`,
        };
    }
    if (!parsed.hostname) {
        return { ok: false, reason: 'has no host' };
    }
    if (parsed.username || parsed.password) {
        // Do NOT echo the userinfo back - it may be a credential. Name the host
        // the URL ACTUALLY resolves to, which is the whole point of the warning.
        return {
            ok: false,
            reason: `embeds credentials before the host (it actually resolves to ` +
                    `"${parsed.hostname}", which is probably not what it looks like)`,
        };
    }
    return { ok: true, url: value };
}

// The most recent rejection, so unresolvedFleetUrlMessage() can say WHY rather
// than the misleading "nothing is configured" when something IS configured but
// was refused. Module-scoped and overwritten per resolve attempt; read it only
// immediately after a resolveFleetUrl() that returned null.
let _lastFleetUrlRejection = null;

/**
 * The reason the last resolveFleetUrl() call refused a configured value, or null
 * when the last call simply found nothing configured.
 * @returns {{ source: string, reason: string }|null}
 */
function lastFleetUrlRejection() {
    return _lastFleetUrlRejection;
}

/**
 * Resolve the fleet base URL - resolved, never guessed.
 *
 * Order: explicit FLEET_MONITOR_URL, then .centralServer.apiEndpoint from
 * fleet-config.json (the same key fleet-reporter reads) with its /api... suffix
 * stripped. Call this LAZILY, at use time - never bind it to a module-level
 * constant, or the config is read once at require time and can never be
 * exercised per-test.
 *
 * @returns {string|null} base URL with no trailing slash, or null when
 *                        unresolvable. NEVER returns localhost.
 */
function resolveFleetUrl() {
    _lastFleetUrlRejection = null;

    if (process.env.FLEET_MONITOR_URL) {
        const raw = process.env.FLEET_MONITOR_URL.replace(/\/+$/, '');
        if (!raw) return null;
        const v = validateFleetUrl(raw);
        if (!v.ok) {
            _lastFleetUrlRejection = { source: '$FLEET_MONITOR_URL', reason: v.reason };
            return null;
        }
        return raw;
    }

    // XACA-0972-016: LOOP over every candidate config and fall THROUGH one that
    // exists but carries no usable apiEndpoint. The previous version picked
    // fleetConfigPath() - the FIRST file that EXISTS - and gave up if that file
    // happened to lack the key, so an empty ~/.aiteamforge/fleet-config.json
    // masked a perfectly good ~/.dev-team/fleet-config.json underneath it.
    //
    // That was a real divergence from _kb_msg_relay_url in kanban-helpers.sh,
    // which this function is documented to mirror: the shell version iterates
    // both paths and `continue`s when the endpoint is empty. Keep the two in
    // sync - including this fall-through.
    for (const cfgPath of fleetConfigCandidates()) {
        let endpoint;
        try {
            const cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
            endpoint = cfg && cfg.centralServer && cfg.centralServer.apiEndpoint;
        } catch (_) {
            continue; // missing, unreadable, or malformed - try the next one
        }
        if (typeof endpoint !== 'string' || endpoint.length === 0) continue;

        // Strip the trailing /api... path, exactly as _kb_msg_relay_url does - in TWO
        // steps, and the second is NOT redundant. The documented shape is
        // "<base>/api/status", which the first step handles; the bare "<base>/api"
        // form has no slash AFTER /api and does not match it. Omitting the second
        // step silently produced a relay base of "https://host/api" during the
        // XACA-0885 fix and only surfaced in a test. Do not collapse these.
        let base = endpoint;
        const apiIdx = base.lastIndexOf('/api/');   // mirrors ${ep%/api/*}
        if (apiIdx !== -1) base = base.slice(0, apiIdx);
        base = base.replace(/\/api$/, '');          // mirrors ${base%/api}
        base = base.replace(/\/+$/, '');
        if (!base) continue;

        // XACA-0972-022: this value came off DISK. Validate before any caller
        // fetches machine public keys from it and seals secrets to them.
        // A refused config does NOT fall through to the next candidate - a
        // hostile entry must not be able to make us quietly try somewhere else
        // as if nothing happened. Record why and stop.
        const v = validateFleetUrl(base);
        if (!v.ok) {
            _lastFleetUrlRejection = { source: cfgPath, reason: v.reason };
            return null;
        }
        return base;
    }

    return null;
}

/**
 * The one canonical "no fleet URL anywhere" message, shared by every vault
 * client so the operator sees the same actionable text from all of them.
 * Names BOTH the environment variable and the concrete config path - a bare
 * "fetch failed" is what sent us down this road in the first place.
 * @param {string} toolName e.g. "vault-fetch"
 * @returns {string}
 */
function unresolvedFleetUrlMessage(toolName) {
    // XACA-0972-022: distinguish "nothing configured" from "something IS
    // configured and we REFUSED it". Telling an operator to set a value they
    // already set sends them in a circle; naming the rejected source and the
    // reason points them straight at the bad line.
    const rejection = lastFleetUrlRejection();
    const head = rejection
        ? `${toolName}: the configured fleet server URL was REJECTED, so there is nothing safe to talk to.\n` +
          `  Source: ${rejection.source}\n` +
          `  Problem: the URL ${rejection.reason}.\n` +
          `  Fix that value, or override it by any ONE of:\n`
        : `${toolName}: no fleet server URL is configured, so there is nothing to talk to.\n` +
          `  Fix it by any ONE of:\n`;
    return head +
           `    - pass --server <url>\n` +
           `    - export FLEET_MONITOR_URL=<url>\n` +
           `    - set .centralServer.apiEndpoint in ${fleetConfigPath()}\n` +
           `  (There is deliberately no localhost fallback: a fleet service is remote by definition.)`;
}

// Lazily-loaded sodium handle so the module is requireable without the dep present
// (e.g. in environments that only run the storage/payload logic). Crypto callers
// must call ensureSodium() first.
let _sodium = null;

/**
 * Load + initialize libsodium-wrappers exactly once.
 * @returns {Promise<object>} the ready sodium instance
 */
async function ensureSodium() {
    if (_sodium && _sodium.ready === undefined) return _sodium; // already resolved handle
    const sodium = require('libsodium-wrappers');
    await sodium.ready; // #1 footgun if skipped (SECRET-VAULT-DESIGN.md §3.3)
    _sodium = sodium;
    return sodium;
}

// ─────────────────────────────────────────────────────────────────────────────
// Slug helpers
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Derive a default machine slug from the hostname.
 * "Darrens-MacBook-Air.local" -> "darrens-macbook-air"
 * @param {string} [hostname] override (testing)
 * @returns {string} a slug matching SLUG_RE (best effort; may be empty if hostname is exotic)
 */
function defaultMachineSlug(hostname) {
    const raw = (hostname || os.hostname() || '').toLowerCase();
    let slug = raw
        .replace(/\.local$/, '')      // strip mDNS suffix
        .replace(/\..*$/, '')         // strip any remaining domain
        .replace(/[^a-z0-9]+/g, '-')  // non-alnum -> dash
        .replace(/^-+/, '')           // leading dashes (slug must start alpha)
        .replace(/-+$/, '')           // trailing dashes
        .slice(0, MAX_SLUG_LEN);
    // Slug must START with a letter; if it starts with a digit/empty, prefix "m-".
    if (!slug || !/^[a-z]/.test(slug)) {
        slug = ('m-' + slug).replace(/-+$/, '').slice(0, MAX_SLUG_LEN);
    }
    return slug;
}

/**
 * Validate a machine slug against the server contract (SECRET-VAULT-DESIGN.md §6.2).
 * @param {string} slug
 * @returns {string[]} array of error strings (empty == valid)
 */
function validateSlug(slug) {
    const errors = [];
    if (!slug || typeof slug !== 'string') {
        errors.push('machine id (slug) is required');
    } else if (!SLUG_RE.test(slug)) {
        errors.push('machine id must match ^[a-z][a-z0-9-]*$');
    } else if (slug.length > MAX_SLUG_LEN) {
        errors.push(`machine id max length is ${MAX_SLUG_LEN}`);
    }
    return errors;
}

/**
 * Validate a human label (SECRET-VAULT-DESIGN.md §6.2).
 * @param {string} label
 * @returns {string[]} errors
 */
function validateLabel(label) {
    const errors = [];
    if (!label || typeof label !== 'string' || !label.trim()) {
        errors.push('label is required and must be non-empty');
    } else if (label.trim().length > MAX_FIELD_LEN) {
        errors.push(`label max length is ${MAX_FIELD_LEN}`);
    }
    return errors;
}

// ─────────────────────────────────────────────────────────────────────────────
// Keypair generation
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Generate a fresh X25519 keypair for vault use (SECRET-VAULT-DESIGN.md §5.1).
 * Returns base64 (ORIGINAL variant) strings. The private key is sensitive — the
 * caller must store it via persistPrivateKey() and NEVER log it.
 * @returns {Promise<{ publicKey: string, privateKey: string }>} base64 ORIGINAL
 */
async function generateKeypair() {
    const sodium = await ensureSodium();
    const kp = sodium.crypto_box_keypair(); // { publicKey: Uint8Array(32), privateKey: Uint8Array(32), keyType }
    const variant = sodium.base64_variants.ORIGINAL;
    return {
        publicKey: sodium.to_base64(kp.publicKey, variant),
        privateKey: sodium.to_base64(kp.privateKey, variant),
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// Private-key storage backend selection + implementations
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Decide which private-key storage backend to use.
 * macOS with the `security` CLI available -> 'keychain'; otherwise 'file'.
 * @param {{ platform?: string, hasSecurityCli?: boolean }} [opts] injectable for tests
 * @returns {'keychain'|'file'}
 */
function chooseKeyStorageBackend(opts) {
    opts = opts || {};
    const platform = opts.platform || process.platform;
    if (platform !== 'darwin') return 'file';
    const hasSecurity =
        opts.hasSecurityCli !== undefined ? opts.hasSecurityCli : securityCliAvailable();
    return hasSecurity ? 'keychain' : 'file';
}

/** @returns {boolean} whether the macOS `security` CLI is callable */
function securityCliAvailable() {
    try {
        execFileSync('security', ['help'], { stdio: 'ignore' });
        return true;
    } catch (_) {
        return false;
    }
}

/** @returns {string} absolute fallback key-file path for a slug */
function fallbackKeyPath(slug) {
    return path.join(VAULT_DIR, `${slug}.key`);
}

/**
 * Is there already a stored private key for this machine slug, on the chosen backend?
 * @param {string} slug
 * @param {{ backend?: string, fileExists?: (p:string)=>boolean, keychainHas?: (s:string)=>boolean }} [deps]
 * @returns {boolean}
 */
function privateKeyExists(slug, deps) {
    deps = deps || {};
    const backend = deps.backend || chooseKeyStorageBackend();
    if (backend === 'keychain') {
        const has = deps.keychainHas || keychainHasItem;
        return has(slug);
    }
    const exists = deps.fileExists || ((p) => fs.existsSync(p));
    return exists(fallbackKeyPath(slug));
}

/** @returns {boolean} whether a Keychain item exists for this slug (no value read) */
function keychainHasItem(slug) {
    try {
        execFileSync(
            'security',
            ['find-generic-password', '-s', KEYCHAIN_SERVICE, '-a', slug],
            { stdio: 'ignore' }
        );
        return true;
    } catch (_) {
        return false;
    }
}

/**
 * Persist the private key on the chosen backend. NEVER logs the key.
 * @param {string} slug machine slug (== keychain account / file basename)
 * @param {string} privateKeyB64 base64 ORIGINAL of the 32-byte private key
 * @param {{ backend?: string, force?: boolean,
 *           writeFile?: Function, mkdir?: Function, chmod?: Function,
 *           keychainAdd?: Function }} [deps] injectable for tests
 * @returns {{ backend: string, location: string }} where it landed (location is NOT the key)
 */
function persistPrivateKey(slug, privateKeyB64, deps) {
    deps = deps || {};
    const backend = deps.backend || chooseKeyStorageBackend();
    const force = !!deps.force;

    if (backend === 'keychain') {
        const add = deps.keychainAdd || keychainAddPassword;
        add(slug, privateKeyB64, force);
        return { backend: 'keychain', location: `Keychain ${KEYCHAIN_SERVICE} / ${slug}` };
    }

    // File fallback: dir 0700, file 0600, single-line base64.
    const filePath = fallbackKeyPath(slug);
    const mkdir = deps.mkdir || ((d) => fs.mkdirSync(d, { recursive: true, mode: 0o700 }));
    const writeFile = deps.writeFile || fsWriteFile0600;
    mkdir(path.dirname(filePath));
    writeFile(filePath, privateKeyB64 + '\n');
    // Best-effort tighten the directory mode too (mkdir mode is umask-masked).
    try { (deps.chmod || fs.chmodSync)(path.dirname(filePath), 0o700); } catch (_) { /* non-fatal */ }
    return { backend: 'file', location: filePath };
}

/**
 * Add (or update with force) the private key as a Keychain generic password.
 * Uses `-w` to pass the value; `-U` (force) updates an existing item.
 * @param {string} slug
 * @param {string} privateKeyB64
 * @param {boolean} force
 */
function keychainAddPassword(slug, privateKeyB64, force) {
    const args = [
        'add-generic-password',
        '-s', KEYCHAIN_SERVICE,
        '-a', slug,
        '-w', privateKeyB64,
        '-D', 'AITeamForge vault private key',
        '-j', 'X25519 private key for Fleet Monitor secret vault. Do not export.',
    ];
    if (force) args.push('-U');
    // stdio ignore so the key never lands in our stdout/stderr.
    execFileSync('security', args, { stdio: 'ignore' });
}

/** Write a file with mode 0600 atomically-ish (open with explicit mode). */
function fsWriteFile0600(filePath, contents) {
    // wx avoids clobbering without intent; persistPrivateKey already gates on force,
    // so by the time we get here we intend to write. Open w with explicit mode 0600.
    const fd = fs.openSync(filePath, 'w', 0o600);
    try {
        fs.writeFileSync(fd, contents);
    } finally {
        fs.closeSync(fd);
    }
    // Re-assert mode in case the file pre-existed with looser perms.
    fs.chmodSync(filePath, 0o600);
}

/**
 * Read back a private key (used by downstream open tooling; provided here for
 * completeness + tests). Enforces 0600 on the fallback file (refuses looser).
 * @param {string} slug
 * @param {{ backend?: string, readFile?: Function, statMode?: Function, keychainRead?: Function }} [deps]
 * @returns {string} base64 ORIGINAL private key
 */
function readPrivateKey(slug, deps) {
    deps = deps || {};
    const backend = deps.backend || chooseKeyStorageBackend();
    if (backend === 'keychain') {
        const read = deps.keychainRead || keychainReadPassword;
        return read(slug);
    }
    const filePath = fallbackKeyPath(slug);
    const statMode = deps.statMode || ((p) => fs.statSync(p).mode);
    const mode = statMode(filePath) & 0o777;
    if (mode & 0o077) {
        throw new Error(
            `Refusing to read private key: ${filePath} is group/world-accessible ` +
            `(mode ${mode.toString(8)}); expected 0600. Fix with: chmod 600 "${filePath}"`
        );
    }
    const readFile = deps.readFile || ((p) => fs.readFileSync(p, 'utf8'));
    return readFile(filePath).trim();
}

/** Read a Keychain generic password value (returns the private key). */
function keychainReadPassword(slug) {
    const out = execFileSync(
        'security',
        ['find-generic-password', '-s', KEYCHAIN_SERVICE, '-a', slug, '-w'],
        { encoding: 'utf8' }
    );
    return out.trim();
}

// ─────────────────────────────────────────────────────────────────────────────
// Registration payload + HTTP
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Build the registration request body for POST/PUT /api/vault/machines
 * (SECRET-VAULT-DESIGN.md §7.1). Validates the public key decodes to 32 bytes.
 * @param {{ id: string, label: string, publicKey: string }} args
 * @returns {Promise<{ id: string, label: string, public_key: string }>}
 * @throws {Error} on validation failure (slug, label, or non-32-byte pubkey)
 */
async function buildRegistrationPayload({ id, label, publicKey }) {
    const errors = [...validateSlug(id), ...validateLabel(label)];
    if (!publicKey || typeof publicKey !== 'string') {
        errors.push('public_key is required');
    } else {
        // Verify the base64 ORIGINAL decodes to exactly 32 bytes — the server
        // will reject otherwise (SECRET-VAULT-DESIGN.md §7.3); fail fast here.
        const sodium = await ensureSodium();
        let decoded;
        try {
            decoded = sodium.from_base64(publicKey, sodium.base64_variants.ORIGINAL);
        } catch (_) {
            decoded = null;
        }
        if (!decoded) {
            errors.push('public_key must be valid base64 (ORIGINAL variant)');
        } else if (decoded.length !== X25519_KEY_BYTES) {
            errors.push(`public_key must decode to exactly ${X25519_KEY_BYTES} bytes (got ${decoded.length})`);
        }
    }
    if (errors.length) {
        const err = new Error('Registration payload validation failed: ' + errors.join('; '));
        err.validationErrors = errors;
        throw err;
    }
    return { id, label: label.trim(), public_key: publicKey };
}

/**
 * POST or PUT the registration payload to the vault.
 * @param {object} payload from buildRegistrationPayload
 * @param {{ serverUrl?: string, rotate?: boolean, fetchImpl?: Function }} [opts]
 *   rotate=true -> PUT /api/vault/machines/:id (in-place key update, §8.2)
 *   rotate=false -> POST /api/vault/machines (create; 409 on collision)
 * @returns {Promise<{ status: number, body: any }>}
 */
async function registerMachine(payload, opts) {
    opts = opts || {};
    // Resolve LAZILY, at call time. An explicit opts.serverUrl always wins; only
    // the default changed (XACA-0972-002). No silent localhost fallback.
    const resolved = opts.serverUrl || resolveFleetUrl();
    if (!resolved) {
        const err = new Error(unresolvedFleetUrlMessage('vault-keygen'));
        err.code = 'FLEET_URL_UNRESOLVED';
        throw err;
    }
    const serverUrl = resolved.replace(/\/+$/, '');
    const doFetch = opts.fetchImpl || globalThis.fetch;
    if (typeof doFetch !== 'function') {
        throw new Error('No fetch implementation available (Node 18+ required, or pass opts.fetchImpl)');
    }

    const method = opts.rotate ? 'PUT' : 'POST';
    const url = opts.rotate
        ? `${serverUrl}/api/vault/machines/${encodeURIComponent(payload.id)}`
        : `${serverUrl}/api/vault/machines`;

    const res = await doFetch(url, {
        method,
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
    });

    let body = null;
    try { body = await res.json(); } catch (_) { /* non-JSON / empty body */ }
    return { status: res.status, body };
}

// ─────────────────────────────────────────────────────────────────────────────
// High-level orchestration (used by the CLI / shell wrapper)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Full provision flow: choose/validate slug, guard against overwrite, generate,
 * store private key, register public key.
 *
 * @param {{
 *   machineId?: string, label?: string, serverUrl?: string,
 *   force?: boolean, rotate?: boolean, dryRun?: boolean,
 *   log?: (msg:string)=>void
 * }} opts
 * @returns {Promise<{ machineId: string, publicKey: string, storage: object,
 *                     registration: object|null, payload: object }>}
 */
async function provisionMachine(opts) {
    opts = opts || {};
    const log = opts.log || (() => {});
    const machineId = opts.machineId || defaultMachineSlug();
    const label = opts.label || `${os.userInfo().username}@${os.hostname()}`;

    const slugErrors = validateSlug(machineId);
    if (slugErrors.length) {
        throw new Error('Invalid machine id: ' + slugErrors.join('; '));
    }

    const backend = chooseKeyStorageBackend();
    const alreadyExists = privateKeyExists(machineId, { backend });

    // Idempotence guard (deliverable req #4): do not silently overwrite an existing key.
    if (alreadyExists && !opts.force && !opts.rotate) {
        throw new Error(
            `A private key for machine "${machineId}" already exists (${backend}). ` +
            `Refusing to overwrite. Use --rotate to generate a new key (then re-seal ` +
            `existing secrets per SECRET-VAULT-DESIGN.md §5.4), or --force to replace.`
        );
    }

    log(`Storage backend: ${backend}`);
    log(`Machine id: ${machineId}`);
    log(`Label: ${label}`);
    if (alreadyExists) {
        log(opts.rotate ? 'Rotating existing machine key (in-place update).' : 'Overwriting existing key (--force).');
    }

    // Generate the keypair.
    const { publicKey, privateKey } = await generateKeypair();

    // Build + validate the registration payload BEFORE we touch storage, so a
    // malformed pubkey never leaves an orphaned private key behind.
    const payload = await buildRegistrationPayload({ id: machineId, label, publicKey });

    if (opts.dryRun) {
        log('[dry-run] Skipping private-key storage and registration.');
        return { machineId, publicKey, storage: null, registration: null, payload };
    }

    // Persist the private key (force when rotating or explicitly forced).
    const storage = persistPrivateKey(machineId, privateKey, {
        backend,
        force: opts.force || opts.rotate,
    });
    log(`Private key stored: ${storage.location}`);

    // Register the public key with the vault.
    const registration = await registerMachine(payload, {
        serverUrl: opts.serverUrl,
        rotate: opts.rotate,
    });

    if (registration.status >= 200 && registration.status < 300) {
        log(`Registered public key (${registration.status}).`);
    } else if (registration.status === 409) {
        log(`Server returned 409 (machine id "${machineId}" already registered). ` +
            `Use --rotate to update the existing entry's public_key.`);
    } else {
        log(`Registration returned HTTP ${registration.status}: ` +
            JSON.stringify(registration.body || {}));
    }

    return { machineId, publicKey, storage, registration, payload };
}

// ─────────────────────────────────────────────────────────────────────────────
// CLI
// ─────────────────────────────────────────────────────────────────────────────

function parseArgs(argv) {
    const opts = { force: false, rotate: false, dryRun: false };
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        switch (a) {
            case '--machine-id': opts.machineId = argv[++i]; break;
            case '--label':      opts.label = argv[++i]; break;
            case '--server':
            case '--server-url': opts.serverUrl = argv[++i]; break;
            case '--force':      opts.force = true; break;
            case '--rotate':     opts.rotate = true; break;
            case '--dry-run':    opts.dryRun = true; break;
            case '-h':
            case '--help':       opts.help = true; break;
            default:
                if (a.startsWith('--machine-id=')) opts.machineId = a.split('=')[1];
                else if (a.startsWith('--label=')) opts.label = a.split('=')[1];
                else if (a.startsWith('--server=') || a.startsWith('--server-url=')) opts.serverUrl = a.split('=')[1];
                else throw new Error(`Unknown argument: ${a}`);
        }
    }
    return opts;
}

const HELP = `vault-keygen — generate a machine X25519 keypair, store the private key
locally, and register the public key with the Fleet Monitor secret vault.

Usage:
  node vault-keygen.js [options]

Options:
  --machine-id <slug>   Machine id/slug (default: slugified hostname).
                        Must match ^[a-z][a-z0-9-]*$, max 64 chars.
  --label <text>        Human-readable label (default: user@hostname).
  --server <url>        Vault base URL. Default: $FLEET_MONITOR_URL, else
                        .centralServer.apiEndpoint from
                        ~/.aiteamforge/fleet-config.json. There is NO localhost
                        fallback - if neither is set this exits non-zero and
                        tells you exactly what to set.
  --rotate              Generate a NEW keypair for an existing machine and update
                        its registration in place (PUT). You MUST then re-seal all
                        existing secrets to the new key (SECRET-VAULT-DESIGN.md §5.4).
  --force               Replace an existing local private key without rotating.
  --dry-run             Generate + show the payload; do NOT store the key or register.
  -h, --help            Show this help.

The private key is stored in the macOS Keychain (service com.aiteamforge.vault,
account = machine id) when available, otherwise in ~/.aiteamforge/vault/<slug>.key
(mode 0600). It is NEVER printed and NEVER sent to the server.`;

async function main(argv) {
    let opts;
    try {
        opts = parseArgs(argv);
    } catch (err) {
        process.stderr.write(err.message + '\n\n' + HELP + '\n');
        return 2;
    }
    if (opts.help) {
        process.stdout.write(HELP + '\n');
        return 0;
    }

    try {
        const result = await provisionMachine({
            ...opts,
            log: (m) => process.stdout.write(m + '\n'),
        });
        // Echo the public key + payload (safe — public). NEVER the private key.
        process.stdout.write('\nRegistration payload (public data only):\n');
        process.stdout.write(JSON.stringify(result.payload, null, 2) + '\n');
        if (result.registration && result.registration.status >= 400) {
            return 1;
        }
        process.stdout.write('\nDone. You\'re welcome.\n');
        return 0;
    } catch (err) {
        process.stderr.write('Error: ' + err.message + '\n');
        return 1;
    }
}

// Run as CLI when invoked directly.
if (require.main === module) {
    main(process.argv.slice(2)).then((code) => process.exit(code));
}

module.exports = {
    // constants
    KEYCHAIN_SERVICE,
    VAULT_DIR,
    X25519_KEY_BYTES,
    // fleet URL resolution (shared with vault-fetch.js / vault-migrate-env-keys.js)
    fleetConfigPath,
    fleetConfigCandidates,
    validateFleetUrl,
    lastFleetUrlRejection,
    resolveFleetUrl,
    unresolvedFleetUrlMessage,
    // slug/label
    defaultMachineSlug,
    validateSlug,
    validateLabel,
    // crypto
    ensureSodium,
    generateKeypair,
    // storage
    chooseKeyStorageBackend,
    securityCliAvailable,
    fallbackKeyPath,
    privateKeyExists,
    persistPrivateKey,
    readPrivateKey,
    // registration
    buildRegistrationPayload,
    registerMachine,
    provisionMachine,
    // cli
    parseArgs,
    main,
};
