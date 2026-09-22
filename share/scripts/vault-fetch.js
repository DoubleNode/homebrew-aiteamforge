//
//  vault-fetch.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * vault-fetch.js
 * EPIC-0016 Phase A.4.2 / XACA-0538-004 — Client-side fetch+decrypt helper.
 *
 * Fetches a sealed secret from the Fleet Monitor vault delivery endpoint, decrypts
 * it locally with the machine's private key (crypto_box_seal_open), and emits the
 * plaintext to stdout. A local cache reduces unnecessary server round-trips.
 *
 * The private key NEVER leaves the machine. Plaintext is ONLY written to stdout.
 *
 * ── Exit code contract (A.4.3 / XACA-0539 consuming interface) ──────────────
 *   0  ok              Ciphertext decrypted; plaintext on stdout.
 *   1  usage error     Bad arguments (conventional POSIX).
 *   2  (reserved)      Reserved for runtime errors not covered below.
 *   3  not-configured  No keypair found for the default machine slug (vault-keygen
 *                      has not been run or the key was deleted). This machine is
 *                      NOT vault-provisioned; the legacy env-var model is the
 *                      intended path. NON-RETRYABLE.
 *   4  unreachable     Server responded non-2xx (other than 404), timed out, or
 *                      returned non-JSON. RETRYABLE — a later attempt may succeed.
 *   5  cache-hit       A fresh cached plaintext was returned; stdout contains it.
 *   6  decrypt-failed  Ciphertext could not be decrypted with this machine's key
 *                      (wrong/rotated key, or sealed to a different machine).
 *                      NON-RETRYABLE — re-provision / re-seal for this machine.
 *   7  not-found       OUR VAULT returned HTTP 404 carrying one of its documented
 *                      error codes: no such secret exists for this engine/account,
 *                      or none is sealed for this machine.
 *                      A definitive answer, NOT a dead server — contrast exit 4.
 *                      A 404 WITHOUT a recognised vault error code is reported as
 *                      exit 4, not 7: any captive portal or proxy can emit a 404,
 *                      and only positive evidence earns the downgrade (XACA-0972-021).
 *                      NON-RETRYABLE — seal the secret first (vault-migrate-env-keys
 *                      or the vault UI); retrying changes nothing.
 *   8  no-fleet-url    A keypair EXISTS on this machine, but no fleet server URL
 *                      could be resolved from --server, $FLEET_MONITOR_URL, or
 *                      fleet-config.json (or the configured URL was rejected as
 *                      unsafe). NON-RETRYABLE until an operator fixes config.
 *
 *                      WHY THIS IS NOT EXIT 3 (XACA-0972-018): the keypair check
 *                      runs BEFORE URL resolution, so reaching this branch at all
 *                      PROVES a keypair is present. Folding it into 3 told
 *                      cc-launch "this machine has no vault", which dropped a
 *                      vault-provisioned machine out of the stale-cache tier it
 *                      used to reach — before this work, an unset URL produced a
 *                      localhost connection-refused, i.e. exit 4, i.e. stale
 *                      cache. Code 8 restores that tier while still naming the
 *                      real fault. A consumer that does not know code 8 must
 *                      treat it like 4 (fail closed), never like 3.
 *
 * ── Cache ─────────────────────────────────────────────────────────────────────
 *   Location: ~/.aiteamforge/vault-cache/<machine_slug>/<engine>/<account>.plain
 *   Mode:     0600 (file), 0700 (all ancestor dirs)
 *   TTL:      VAULT_FETCH_CACHE_TTL_SECONDS env var, or CACHE_TTL_SECONDS (300s)
 *   --no-cache bypasses both reads and writes.
 *   Contents: raw plaintext (UTF-8). The cache stores decrypted plaintext so there
 *   is no need to touch the private key on a cache hit — and so the cache is
 *   useless without OS-level access to the user's home directory (same threat model
 *   as the private key file itself).
 *
 *   Security posture: per-user directory, mode 0700, files 0600. Attacker with read
 *   access to the user's home dir already has the private key file; caching plaintext
 *   does not raise the threat bar. For higher-sensitivity environments use --no-cache.
 *
 * ── A.4.3 consuming interface ─────────────────────────────────────────────────
 *   cc-launch (XACA-0539) should call vault-fetch like this:
 *
 *   PLAIN=$(node vault-fetch.js <engine> <account> [--server URL] [--cache-dir DIR])
 *   code=$?
 *   case $code in
 *     0) ;;            # plaintext in PLAIN; continue startup
 *     5) ;;            # cache hit — plaintext in PLAIN; continue startup
 *     3) echo "No vault keypair on this machine." >&2; exit 1;;               # non-retryable
 *     8) echo "Vault keypair present but NO fleet URL configured — fix config." >&2; exit 1;;
 *     4) echo "Vault server unreachable — safe to RETRY later." >&2; exit 1;;   # RETRYABLE
 *     6) echo "Vault secret cannot be decrypted on this machine — re-provision / re-seal." \
 *             >&2; exit 1;;  # NON-retryable: do NOT loop, surface to the operator
 *     7) echo "No such vault secret for this engine/account." >&2; exit 1;;     # non-retryable
 *     *) echo "vault-fetch failed (code $code)" >&2; exit 1;;
 *   esac
 *
 *   RETRY POLICY: only exit 4 is retryable. Exits 3, 6, 7 and 8 are persistent
 *   configuration/state errors — retrying them loops forever without resolving
 *   anything. In particular 7 (not-found) must NOT be folded back into 4: giving
 *   it its own code is the entire point.
 *
 *   FALLBACK ELIGIBILITY is a SEPARATE axis from retryability. Codes 4 and 8 both
 *   mean "this machine has a vault it cannot currently use", so both may fall back
 *   to a stale cache and both must FAIL CLOSED if nothing else yields a token.
 *   Code 7 may NOT use the stale cache (the secret was deliberately removed) and
 *   code 3 is not a vault machine at all.
 *
 *   NOTE: Both exit code 0 and 5 deliver plaintext on stdout. cc-launch must treat
 *   them identically (both = success). The distinction is informational (cache vs.
 *   live fetch) and is logged to stderr, not stdout.
 *
 * ── Private-key storage ───────────────────────────────────────────────────────
 *   Reads the same storage written by vault-keygen.js:
 *     - macOS Keychain: generic-password, service com.aiteamforge.vault, account <slug>
 *     - Fallback file: ~/.aiteamforge/vault/<slug>.key (mode 0600)
 *   The machine slug defaults to a slugified hostname (same derivation as vault-keygen.js).
 *   Override via --machine-id.
 *
 * ── Crypto ────────────────────────────────────────────────────────────────────
 *   The public key is derived from the stored private key via crypto_scalarmult_base
 *   (X25519 scalar multiplication with the Curve25519 base point). Both are needed
 *   for crypto_box_seal_open. Only the private key is stored; the public key is
 *   re-derived on every use — no extra storage, no sync drift.
 */

const os   = require('os');
const fs   = require('fs');
const path = require('path');

// ── Re-use vault-keygen.js storage/slug helpers ───────────────────────────────
// vault-keygen.js lives alongside us. We import it for the storage layer so the
// private-key reading logic stays in exactly one place.
const kg = require('./vault-keygen.js');

// ── Constants ──────────────────────────────────────────────────────────────────
const CACHE_TTL_SECONDS  = parseInt(process.env.VAULT_FETCH_CACHE_TTL_SECONDS || '300', 10);
const DEFAULT_CACHE_DIR  = path.join(os.homedir(), '.aiteamforge', 'vault-cache');
const FETCH_TIMEOUT_MS   = 10_000; // 10 s; treat as unreachable if exceeded

// Slug shape — MUST mirror the server's canonical pattern (vault-store.js SLUG_RE
// and engines-routes.js ACCOUNT_SLUG_RE: /^[a-z][a-z0-9-]*$/, ≤ 64 chars). The
// server already validates, but we re-validate client-side (defense-in-depth) so a
// crafted engine/account slug can never escape the cache root via path components
// (e.g. "../../etc"). XACA-0538-014.
const SLUG_RE      = /^[a-z][a-z0-9-]*$/;
const MAX_SLUG_LEN = 64;

// ── Authoritative-404 evidence (XACA-0972-021) ────────────────────────────────
//
// A 404 is the ONLY status that downgrades a session to "this secret does not
// exist" (exit 7), which in turn tells cc-launch to stop trying and launch on
// default OAuth. Any intermediary can produce a 404: a captive portal, a
// misconfigured reverse proxy, a CDN edge that has never heard of /api/vault.
// Treating those as authoritative hands an attacker (or a coffee-shop wifi
// splash page) a way to silently downgrade the account a session bills to.
//
// So a 404 must PROVE it came from our vault before it is believed. The server
// already provides that proof: fleet-monitor/server/lib/vault-routes.js
// documents a stable `code` on every error from this endpoint, precisely so the
// client can branch without string-matching human-readable text. The ciphertext
// route emits exactly these two 404 codes — verified against the live server
// 2026-08-26, which answers an unknown secret with:
//     {"error":"Secret 'anthropic/academy' not found","code":"secret_not_found"}
//
// Anything else — a non-JSON body, a JSON body with no `code`, or a `code` we do
// not recognise — is NOT proof, and FAILS TOWARD EXIT 4 (unreachable/retryable).
// That is the fail-closed direction: a real 404 misread as 4 costs a retry and,
// on a vault machine, keeps the stale-cache tier; a portal's 404 misread as 7
// silently drops the account. Prefer the cheap mistake.
//
// If the server ever adds a THIRD authoritative 404 code, add it here. Until
// then an unknown code degrades safely rather than being trusted by default.
const AUTHORITATIVE_404_CODES = new Set([
    'secret_not_found',           // no such (engine, account) secret exists
    'no_ciphertext_for_machine',  // secret exists, but nothing sealed for this machine
]);

// ── Exit codes ─────────────────────────────────────────────────────────────────
const EXIT_OK             = 0;
const EXIT_USAGE          = 1;
// EXIT_RESERVED          = 2  — reserved for future runtime errors
const EXIT_NOT_CFG        = 3;
const EXIT_UNREACHABLE    = 4;
const EXIT_CACHE_HIT      = 5;
const EXIT_DECRYPT_FAILED = 6;
const EXIT_NOT_FOUND      = 7;
const EXIT_NO_FLEET_URL   = 8;

// ── libsodium lazy handle (same pattern as vault-keygen.js) ───────────────────
let _sodium = null;
async function ensureSodium() {
    if (_sodium && _sodium.ready === undefined) return _sodium;
    const sodium = require('libsodium-wrappers');
    await sodium.ready;
    _sodium = sodium;
    return sodium;
}

// ─────────────────────────────────────────────────────────────────────────────
// Cache helpers
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Validate a slug against the canonical server pattern. Throws on a bad slug so a
 * crafted CLI argument can never be used as a raw path component. Defense-in-depth:
 * the server validates too, but the client must not trust its own argv. XACA-0538-014.
 * @param {string} value
 * @param {string} label  human label for the error message (e.g. "engine slug")
 * @throws {Error} when value is missing, malformed, or too long (no value echoed
 *                 beyond a short, non-sensitive hint of the offending field)
 */
function validateSlug(value, label) {
    if (typeof value !== 'string' || value.length === 0) {
        throw new Error(`${label} is required`);
    }
    if (value.length > MAX_SLUG_LEN) {
        throw new Error(`${label} exceeds ${MAX_SLUG_LEN} characters`);
    }
    if (!SLUG_RE.test(value)) {
        throw new Error(`${label} must match ${SLUG_RE.source} (lowercase, no path separators)`);
    }
}

/**
 * Build the cache file path for a (machineSlug, engineSlug, accountSlug) triple.
 * Each component is slug-validated before use so it cannot traverse outside the
 * cache root. XACA-0538-014.
 * @param {string} cacheDir
 * @param {string} machineSlug
 * @param {string} engineSlug
 * @param {string} accountSlug
 * @returns {string}
 */
function cachePath(cacheDir, machineSlug, engineSlug, accountSlug) {
    validateSlug(machineSlug, 'machine slug');
    validateSlug(engineSlug, 'engine slug');
    validateSlug(accountSlug, 'account slug');
    return path.join(cacheDir, machineSlug, engineSlug, `${accountSlug}.plain`);
}

/**
 * Ensure a directory (and all parents) exist with mode 0700.
 * @param {string} dir
 */
function mkdirSecure(dir) {
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    // Re-assert mode — mkdirSync mode is umask-masked.
    try { fs.chmodSync(dir, 0o700); } catch (_) { /* non-fatal on existing dirs */ }
}

/**
 * Write plaintext to the cache file securely (0600).
 * @param {string} filePath
 * @param {string} plaintext
 */
function writeCacheFile(filePath, plaintext) {
    mkdirSecure(path.dirname(filePath));
    const fd = fs.openSync(filePath, 'w', 0o600);
    try {
        fs.writeFileSync(fd, plaintext);
    } finally {
        fs.closeSync(fd);
    }
    fs.chmodSync(filePath, 0o600); // re-assert in case file pre-existed
}

/**
 * Read a cache entry if it exists and is within the TTL.
 * Returns the plaintext string, or null if missing/stale.
 * @param {string} filePath
 * @param {number} ttlSeconds
 * @returns {string|null}
 */
function readCacheEntry(filePath, ttlSeconds) {
    let stat;
    try {
        stat = fs.statSync(filePath);
    } catch (_) {
        return null; // not found
    }
    const ageSeconds = (Date.now() - stat.mtimeMs) / 1000;
    if (ageSeconds > ttlSeconds) {
        return null; // stale
    }
    try {
        return fs.readFileSync(filePath, 'utf8');
    } catch (_) {
        return null;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Private-key resolution (delegates to vault-keygen.js)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Load the machine's private key from wherever vault-keygen stored it.
 * Returns null (instead of throwing) when no key is configured, so callers can
 * emit exit code 3 cleanly.
 *
 * @param {string} slug machine slug
 * @param {object} [deps] injectable for tests (backend, keychainRead, readFile, statMode)
 * @returns {{ privateKeyB64: string }|null}
 */
function loadPrivateKey(slug, deps) {
    deps = deps || {};
    try {
        const privateKeyB64 = kg.readPrivateKey(slug, deps);
        if (!privateKeyB64) return null;
        return { privateKeyB64 };
    } catch (_) {
        return null;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Fetch + decrypt
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Derive the X25519 public key from the private key bytes.
 * @param {object} sodium initialized sodium instance
 * @param {Uint8Array} privateKeyBytes
 * @returns {Uint8Array} 32-byte public key
 */
function derivePublicKey(sodium, privateKeyBytes) {
    return sodium.crypto_scalarmult_base(privateKeyBytes);
}

/**
 * Fetch the sealed ciphertext from the vault delivery endpoint.
 * Returns { machine_id, sealed, sealed_at } on success.
 * Throws on network failure, timeout, non-2xx, or non-JSON.
 *
 * On a non-2xx the thrown Error carries `.httpStatus` so the caller can
 * discriminate a definitive 404 (the secret does not exist for this
 * engine/account) from a transient failure, and `.errorCode` - the server's
 * stable machine-readable error code, or null when the body was not JSON or
 * carried no string `code`. Callers MUST branch on those properties - never
 * string-match the message, which is brittle. There is still exactly one throw
 * site for non-2xx; only the tags are new. XACA-0972-003 / XACA-0972-021.
 *
 * @param {string} serverUrl
 * @param {string} engineSlug
 * @param {string} accountSlug
 * @param {string} machineId
 * @param {{ fetchImpl?: Function, timeoutMs?: number }} [opts]
 * @returns {Promise<{ machine_id: string, sealed: string, sealed_at: string }>}
 */
async function fetchCiphertext(serverUrl, engineSlug, accountSlug, machineId, opts) {
    opts = opts || {};
    const doFetch  = opts.fetchImpl || globalThis.fetch;
    const timeout  = opts.timeoutMs !== undefined ? opts.timeoutMs : FETCH_TIMEOUT_MS;

    if (typeof doFetch !== 'function') {
        throw new Error('No fetch implementation (Node 18+ required)');
    }

    const url = `${serverUrl.replace(/\/+$/, '')}/api/vault/secrets` +
                `/${encodeURIComponent(engineSlug)}/${encodeURIComponent(accountSlug)}` +
                `/ciphertext?machine_id=${encodeURIComponent(machineId)}`;

    // AbortController gives us a clean timeout without relying on fetch's own options.
    const ac = new AbortController();
    const timer = setTimeout(() => ac.abort(), timeout);
    let res;
    try {
        // XACA-0972-029: redirect:'manual' + refusal. A 30x here could serve
        // attacker-chosen ciphertext, or - more usefully to an attacker - forge
        // one of the authoritative 404 codes below and downgrade the session to
        // default OAuth. assertNoRedirect throws, so it lands in the same catch
        // as any other transport failure and is classified exit 4 (retryable,
        // fails closed), never exit 7.
        res = kg.assertNoRedirect(await doFetch(url, { ...kg.fleetFetchInit(), signal: ac.signal }), url);
    } catch (fetchErr) {
        // A REFUSED REDIRECT is not a network error - relabelling it as one sends
        // the operator to check their connection when the fault is that the fleet
        // URL points somewhere that bounces. Re-throw it verbatim; it still ends
        // up classified as exit 4 by the caller, which is the correct FALLBACK
        // behaviour, but the message the operator reads names the real cause.
        if (fetchErr && fetchErr.code === 'FLEET_REDIRECT_REFUSED') throw fetchErr;
        throw new Error(`Network error fetching ciphertext: ${fetchErr.message}`);
    } finally {
        clearTimeout(timer);
    }

    if (!res.ok) {
        // Most non-2xx responses are "unreachable" from the caller's perspective
        // — vault not ready, machine not registered, secret not yet sealed for
        // this machine, etc. A 404 is the exception: it is a DEFINITIVE answer
        // that no such secret exists for this engine/account, which is not the
        // same thing as a dead server. Tag the status here and let the caller
        // decide; do not fan out into multiple throw sites. XACA-0972-003.
        let bodySnippet = '';
        let errorCode   = null;
        try {
            const j = await res.json();
            bodySnippet = j.error || JSON.stringify(j);
            // XACA-0972-021: carry the server's stable machine-readable `code`
            // so the caller can demand POSITIVE EVIDENCE that a 404 is ours.
            // Only a string counts — a JSON body with `code: {...}` is not the
            // server's shape and must not be coerced into looking like it.
            if (j && typeof j.code === 'string') errorCode = j.code;
        } catch (_) { /* non-JSON body — errorCode stays null, which is the point */ }
        const err = new Error(`Server returned HTTP ${res.status}${bodySnippet ? ': ' + bodySnippet : ''}`);
        err.httpStatus = res.status;
        err.errorCode  = errorCode;
        throw err;
    }

    let body;
    try {
        body = await res.json();
    } catch (_) {
        throw new Error('Server returned non-JSON response');
    }

    if (!body || typeof body.sealed !== 'string' || typeof body.machine_id !== 'string') {
        throw new Error('Unexpected ciphertext response shape from server');
    }

    return body; // { machine_id, sealed, sealed_at }
}

/**
 * Decrypt a sealed box using the machine's private key.
 * Derives the public key from the private key internally.
 *
 * @param {string} sealedB64      base64 ORIGINAL sealed box
 * @param {string} privateKeyB64  base64 ORIGINAL private key
 * @returns {Promise<string>}     decrypted UTF-8 plaintext
 */
async function decryptSealed(sealedB64, privateKeyB64) {
    const sodium  = await ensureSodium();
    const variant = sodium.base64_variants.ORIGINAL;
    const sk      = sodium.from_base64(privateKeyB64, variant);
    const pk      = derivePublicKey(sodium, sk);
    const sealed  = sodium.from_base64(sealedB64, variant);
    const opened  = sodium.crypto_box_seal_open(sealed, pk, sk);
    // crypto_box_seal_open returns false on authentication failure (wrong key / tampered).
    if (opened === false || opened == null) {
        throw new Error(
            'Decryption failed: ciphertext is tampered, truncated, or encrypted to a different key'
        );
    }
    return sodium.to_string(opened);
}

// ─────────────────────────────────────────────────────────────────────────────
// High-level orchestration
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Main fetch+decrypt flow.
 *
 * @param {{
 *   engineSlug: string,
 *   accountSlug: string,
 *   machineId?: string,
 *   serverUrl?: string,
 *   cacheDir?: string,
 *   noCache?: boolean,
 *   log?: (msg: string) => void,
 *   // Injectable for tests:
 *   keyDeps?: object,
 *   fetchImpl?: Function,
 *   timeoutMs?: number,
 *   cacheTtlSeconds?: number,
 *   // Low-level cache IO overrides for tests:
 *   readCacheEntry?: Function,
 *   writeCacheFile?: Function,
 * }} opts
 * @returns {Promise<{ exitCode: number, plaintext: string|null }>}
 */
async function vaultFetch(opts) {
    opts = opts || {};
    const log           = opts.log || (() => {});
    const machineSlug   = opts.machineId || kg.defaultMachineSlug();
    const cacheDir      = opts.cacheDir  || DEFAULT_CACHE_DIR;
    const noCache       = !!opts.noCache;
    const ttl           = opts.cacheTtlSeconds !== undefined ? opts.cacheTtlSeconds : CACHE_TTL_SECONDS;
    const engineSlug    = opts.engineSlug;
    const accountSlug   = opts.accountSlug;

    // ── 1. Load private key ───────────────────────────────────────────────────
    const keyResult = loadPrivateKey(machineSlug, opts.keyDeps);
    if (!keyResult) {
        log(`[vault-fetch] No private key found for machine slug "${machineSlug}". ` +
            `Run vault-keygen to generate and register a keypair.`);
        return { exitCode: EXIT_NOT_CFG, plaintext: null };
    }

    // ── 2. Cache check ────────────────────────────────────────────────────────
    const cFile = cachePath(cacheDir, machineSlug, engineSlug, accountSlug);
    if (!noCache) {
        const readFn = opts.readCacheEntry || readCacheEntry;
        const cached = readFn(cFile, ttl);
        if (cached !== null) {
            log(`[vault-fetch] Cache hit for ${engineSlug}/${accountSlug} (TTL ${ttl}s)`);
            return { exitCode: EXIT_CACHE_HIT, plaintext: cached };
        }
    }

    // ── 3. Resolve the server URL ─────────────────────────────────────────────
    // Resolved LAZILY, here, rather than at require time - a module-level
    // constant reads the config on import and cannot be exercised per-test.
    // An explicit --server / opts.serverUrl always wins; only the default
    // changed. Deliberately AFTER the cache read: a machine with a fresh cache
    // entry needs no server at all, so it keeps working. XACA-0972-002.
    //
    // "No fleet URL anywhere" is its OWN condition: EXIT_NO_FLEET_URL (8), not 3
    // and not 4. It was exit 3 in the first revision of XACA-0972; that conflated
    // it with "no keypair" and cost a vault-configured machine its stale-cache
    // tier, which pre-fix it reached via localhost -> refused -> exit 4.
    // Exit 3 is the code _cc_export_account_credentials already routes to the
    // documented default-OAuth path; exit 4 would keep failing closed forever on
    // a machine that has no vault to reach in the first place.
    //
    // XACA-0972-027: an EXPLICIT --server / opts.serverUrl is validated on the
    // same terms as a resolved one. It still wins, but winning means "is used if
    // acceptable" - not "skips the check". The bypass this closes is real: the
    // shell resolves the same fleet-config.json itself and passes the result in
    // as --server, so an explicit value is not necessarily operator-typed. A
    // refused explicit URL is exit 8, the same as an unresolvable one, and does
    // NOT silently fall back to resolveFleetUrl().
    const serverUrl = opts.serverUrl
        ? kg.acceptFleetUrl(opts.serverUrl, '--server / opts.serverUrl')
        : kg.resolveFleetUrl();
    if (!serverUrl) {
        log(kg.unresolvedFleetUrlMessage('vault-fetch'));
        // EXIT_NO_FLEET_URL (8), NOT EXIT_NOT_CFG (3). We only get here because the
        // keypair load in step 1 SUCCEEDED, so "no keypair" and "no URL" are
        // structurally distinguishable and must not share a code. See the exit-code
        // contract at the top of this file. XACA-0972-018.
        return { exitCode: EXIT_NO_FLEET_URL, plaintext: null };
    }

    // ── 4. Fetch ciphertext from server ───────────────────────────────────────
    let ciphertextResponse;
    try {
        ciphertextResponse = await fetchCiphertext(serverUrl, engineSlug, accountSlug, machineSlug, {
            fetchImpl: opts.fetchImpl,
            timeoutMs: opts.timeoutMs,
        });
    } catch (fetchErr) {
        // ONLY a 404 means "does not exist". A 401/403 is an auth problem that may
        // well be transient or fixable, and a 5xx is a server problem - both stay
        // retryable under exit 4. Branch on the tagged status, never on the
        // message text. XACA-0972-003.
        if (fetchErr.httpStatus === 404) {
            // XACA-0972-021: a bare 404 is NOT enough. Require the server's stable
            // `code` before treating it as authoritative — see AUTHORITATIVE_404_CODES
            // above for why, and for what the live server actually sends.
            if (AUTHORITATIVE_404_CODES.has(fetchErr.errorCode)) {
                log(`[vault-fetch] Not found (${fetchErr.errorCode}): no secret ` +
                    `${engineSlug}/${accountSlug} sealed for machine "${machineSlug}". NON-retryable.`);
                // Returning here also guarantees no cache entry is written for a 404 -
                // the cache write is step 6, below the decrypt.
                return { exitCode: EXIT_NOT_FOUND, plaintext: null };
            }
            log(`[vault-fetch] Got HTTP 404 with no recognised vault error code ` +
                `(code=${fetchErr.errorCode === null ? 'absent' : JSON.stringify(fetchErr.errorCode)}). ` +
                `This did not demonstrably come from the vault — a captive portal or proxy ` +
                `can return 404 for anything — so treating it as UNREACHABLE, not as ` +
                `"no such secret". Retryable.`);
            return { exitCode: EXIT_UNREACHABLE, plaintext: null };
        }
        log(`[vault-fetch] Unreachable: ${fetchErr.message}`);
        return { exitCode: EXIT_UNREACHABLE, plaintext: null };
    }

    // ── 5. Decrypt locally ────────────────────────────────────────────────────
    let plaintext;
    try {
        plaintext = await decryptSealed(ciphertextResponse.sealed, keyResult.privateKeyB64);
    } catch (decErr) {
        // Decryption failure is a PERSISTENT configuration/integrity problem — a
        // wrong/rotated key or ciphertext sealed to a different machine. It will NOT
        // resolve on retry, so it must NOT share the retryable EXIT_UNREACHABLE code
        // (cc-launch retries 4 forever). EXIT_DECRYPT_FAILED (6) is non-retryable:
        // the operator must re-provision/re-seal for this machine. The error message
        // is non-leaky by construction (decryptSealed never includes plaintext or
        // key material — only a static "tampered/wrong key" string).
        log(`[vault-fetch] Decryption failed: ${decErr.message}`);
        return { exitCode: EXIT_DECRYPT_FAILED, plaintext: null };
    }

    // ── 6. Write/refresh cache ────────────────────────────────────────────────
    if (!noCache) {
        try {
            const writeFn = opts.writeCacheFile || writeCacheFile;
            writeFn(cFile, plaintext);
            log(`[vault-fetch] Cache written: ${cFile}`);
        } catch (cacheErr) {
            // Non-fatal — log and proceed. The plaintext is still returned.
            log(`[vault-fetch] Warning: cache write failed: ${cacheErr.message}`);
        }
    }

    return { exitCode: EXIT_OK, plaintext };
}

// ─────────────────────────────────────────────────────────────────────────────
// CLI
// ─────────────────────────────────────────────────────────────────────────────

const HELP = `vault-fetch — fetch and decrypt a sealed secret from the Fleet Monitor vault.

Usage:
  node vault-fetch.js <engine_slug> <account_slug> [options]

Arguments:
  engine_slug   The engine identifier (e.g. "anthropic", "openai").
  account_slug  The account identifier (e.g. "academy", "prod").

Options:
  --machine-id <slug>  Machine id to look up the private key (default: slugified hostname).
  --server <url>       Vault base URL. Default: $FLEET_MONITOR_URL, else
                       .centralServer.apiEndpoint from ~/.aiteamforge/fleet-config.json.
                       No localhost fallback; unresolvable exits 8, NOT 3.
                       A configured URL that fails validation (non-http(s)
                       scheme, no host, or embedded user:pass@) is REFUSED and
                       also exits 8 - it is never silently fallen back from.
  --cache-dir <dir>    Cache directory (default: ~/.aiteamforge/vault-cache).
  --no-cache           Skip cache read and write; always fetch from server.
  -h, --help           Show this help.

Exit codes:
  0  ok              Ciphertext fetched and decrypted; plaintext on stdout.
  1  usage error     Missing or invalid arguments.
  3  not-configured  No keypair found for this machine (run vault-keygen
                     first). This machine is NOT vault-provisioned. NON-retryable.
                     This code does NOT cover a missing fleet server URL - the
                     keypair check runs BEFORE URL resolution, so the two are
                     structurally distinguishable and must not share a code.
                     No fleet URL is exit 8. See XACA-0972-018.
  8  no-fleet-url    Keypair present, but no fleet server URL is configured
                     (--server / FLEET_MONITOR_URL / fleet-config.json), or the
                     configured URL was rejected as unsafe.
  4  unreachable     Server unreachable, non-2xx (other than 404), timeout, or
                     non-JSON. RETRYABLE.
  5  cache-hit       Fresh cached plaintext returned; stdout contains it.
  6  decrypt-failed  Ciphertext could not be decrypted with this machine's key
                     (wrong/rotated key, or sealed to a different machine).
                     NON-retryable — re-provision / re-seal for this machine.
  7  not-found       Our vault returned HTTP 404 with a recognised vault error
                     code: the secret does not exist for this
                     engine/account, or none is sealed for this machine. A
                     definitive answer, NOT a dead server (contrast 4).
                     NON-retryable — seal the secret, then retry.

Exit codes 0 and 5 both deliver plaintext on stdout and represent success.
All diagnostic messages go to stderr; stdout carries ONLY the plaintext.

Environment:
  FLEET_MONITOR_URL              Default vault server URL. Overrides fleet-config.json;
                                 overridden by --server.
  VAULT_FETCH_CACHE_TTL_SECONDS  Cache TTL in seconds (default: 300).`;

function parseArgs(argv) {
    if (argv.length === 0 || argv[0] === '-h' || argv[0] === '--help') {
        return { help: true };
    }

    const opts = {};
    let i = 0;

    // Positional: engine_slug, account_slug
    if (!argv[i] || argv[i].startsWith('-')) {
        throw new Error('engine_slug is required as the first positional argument');
    }
    opts.engineSlug = argv[i++];

    if (!argv[i] || argv[i].startsWith('-')) {
        throw new Error('account_slug is required as the second positional argument');
    }
    opts.accountSlug = argv[i++];

    // Defense-in-depth: reject malformed slugs at the boundary so they can never be
    // used as raw path components downstream (cachePath). Mirrors the server's
    // canonical SLUG_RE. A bad slug is a usage error (exit 1). XACA-0538-014.
    validateSlug(opts.engineSlug, 'engine_slug');
    validateSlug(opts.accountSlug, 'account_slug');

    // Optional flags
    for (; i < argv.length; i++) {
        const a = argv[i];
        switch (a) {
            case '--machine-id': opts.machineId = argv[++i]; break;
            case '--server':     opts.serverUrl = argv[++i]; break;
            case '--cache-dir':  opts.cacheDir  = argv[++i]; break;
            case '--no-cache':   opts.noCache   = true;      break;
            case '-h':
            case '--help':       opts.help      = true;      break;
            default:
                if (a.startsWith('--machine-id=')) {
                    opts.machineId = a.slice('--machine-id='.length);
                } else if (a.startsWith('--server=')) {
                    opts.serverUrl = a.slice('--server='.length);
                } else if (a.startsWith('--cache-dir=')) {
                    opts.cacheDir = a.slice('--cache-dir='.length);
                } else {
                    throw new Error(`Unknown argument: ${a}`);
                }
        }
    }

    // --machine-id is also used as a path component (cache dir), so validate it
    // when explicitly supplied. The default slug (kg.defaultMachineSlug) is trusted.
    // XACA-0538-014.
    if (opts.machineId !== undefined) {
        validateSlug(opts.machineId, 'machine-id');
    }

    return opts;
}

async function main(argv) {
    let opts;
    try {
        opts = parseArgs(argv);
    } catch (err) {
        process.stderr.write(`Error: ${err.message}\n\n${HELP}\n`);
        return EXIT_USAGE;
    }

    if (opts.help) {
        process.stdout.write(HELP + '\n');
        return EXIT_OK;
    }

    const result = await vaultFetch({
        ...opts,
        log: (m) => process.stderr.write(m + '\n'),
    });

    if (result.plaintext !== null) {
        // stdout carries ONLY the plaintext — no trailing newline manipulation,
        // since the plaintext itself may or may not include one.
        process.stdout.write(result.plaintext);
    }

    return result.exitCode;
}

if (require.main === module) {
    main(process.argv.slice(2)).then((code) => process.exit(code));
}

module.exports = {
    // constants
    CACHE_TTL_SECONDS,
    DEFAULT_CACHE_DIR,
    EXIT_OK,
    EXIT_USAGE,
    EXIT_NOT_CFG,
    EXIT_UNREACHABLE,
    EXIT_CACHE_HIT,
    EXIT_DECRYPT_FAILED,
    EXIT_NOT_FOUND,
    EXIT_NO_FLEET_URL,
    SLUG_RE,
    MAX_SLUG_LEN,
    // validation
    validateSlug,
    // cache
    cachePath,
    readCacheEntry,
    writeCacheFile,
    // key
    loadPrivateKey,
    // crypto
    ensureSodium,
    derivePublicKey,
    decryptSealed,
    // fetch
    fetchCiphertext,
    // orchestration
    vaultFetch,
    // cli
    parseArgs,
    main,
};
