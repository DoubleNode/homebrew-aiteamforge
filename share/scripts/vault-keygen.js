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
 * Exit codes (full text in HELP below): 0 ok, 1 failure, 2 usage, 3 ENROLLMENT
 * PENDING, 4 rotation refused with nothing written — no admin credential, or
 * (XACA-0398-021) a previous rotation's `<slug>.rotating` staging slot still
 * exists; recover that with --resume-rotation.
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
const BASE64_ORIGINAL  = 'base64.ORIGINAL'; // sentinel; resolved against sodium at runtime

// XACA-0398-004 INCIDENT: this used to be `const VAULT_DIR = path.join(os.homedir(), ...)`,
// evaluated ONCE at module require() time. That is the exact anti-pattern
// resolveFleetUrl()'s own comment already warns against ("call this LAZILY... never
// bind it to a module-level constant, or the config is read once at require time and
// can never be exercised per-test") — and this file had it anyway, one function over.
// MEASURED: a test suite that requires this module BEFORE sandboxing $HOME (the normal
// order — `require()` calls sit at the top of a test file) got a VAULT_DIR frozen to the
// REAL home directory forever; two real files landed under the real
// ~/.aiteamforge/vault/ during this ticket's own test development, because
// fallbackKeyPath() closed over the stale constant instead of re-deriving it.
// vaultDir() below re-reads os.homedir() (which itself re-reads $HOME) on every call.
function vaultDir() {
    return path.join(os.homedir(), '.aiteamforge', 'vault');
}

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
// EXCEPTION: the ADMIN credential is never sent over non-loopback http — see
// adminTransportCheck() (XACA-0398-015).

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
        // XACA-0972-028: do NOT echo the value. This branch used to interpolate it
        // via JSON.stringify, which contradicted the contract the userinfo branch
        // below deliberately upholds - and did so on the ONE input class most
        // likely to carry a credential. "https://user:pass@host:notaport/" fails
        // to PARSE, so it lands here, not in the userinfo branch: the credential
        // would have been printed to stderr and, through the cc path, into the
        // operator's terminal and shell scrollback.
        //
        // The caller already names the SOURCE (the env var, or the config file
        // path), which is what an operator needs to find the bad line. The length
        // is included because it is the one detail that distinguishes a truncated
        // or whitespace-only value from a genuinely malformed one, and a character
        // count is not a credential.
        const len = typeof value === 'string' ? value.length : 0;
        return {
            ok: false,
            reason: `is not a valid absolute URL (${len} characters; the value is ` +
                    `not echoed here because a malformed URL can embed credentials)`,
        };
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

// -----------------------------------------------------------------------------
// Explicitly-supplied fleet URLs (XACA-0972-027)
// -----------------------------------------------------------------------------
//
// validateFleetUrl above is only reached by resolveFleetUrl(), i.e. by the
// values this process reads for itself. But every vault client also accepts an
// EXPLICIT URL - `--server` on the CLI, `opts.serverUrl` / `opts.server` in
// process - and an explicit value has always short-circuited resolution
// entirely (`opts.serverUrl || resolveFleetUrl()`). That made the finding-022
// guard bypassable on the route that is actually used most:
//
//   _kb_msg_relay_url in kanban-helpers.sh reads THE SAME fleet-config.json,
//   shell-side, with no validation of any kind, and passes the result to
//   msg-client as `--server`. So the file we hardened is re-read by a different
//   reader and handed straight to fetch(), and the JS-side check never runs.
//
// "Explicit means the operator typed it" does not hold here: on the primary msg
// path the explicit value came off the same disk as the resolved one. Validate
// BOTH, so the guarantee is a property of the JS entry points rather than of
// what any particular caller happens to pass. vault-migrate-env-keys already
// did this; this makes the other clients match.
//
// NOTE: this deliberately does NOT fall back to resolveFleetUrl() when an
// explicit value is refused. A caller that named a server and got it rejected
// must fail closed, not quietly talk to somewhere else instead - the same rule
// resolveFleetUrl() applies to a rejected config entry.

/**
 * Accept an explicitly-supplied fleet base URL, or refuse it.
 *
 * Records the rejection so unresolvedFleetUrlMessage() can name the source and
 * the reason, exactly as it does for a refused config entry.
 *
 * @param {string} value  the URL as supplied (trailing slashes are tolerated)
 * @param {string} source human-readable origin, e.g. '--server'
 * @returns {string|null} normalised base URL (no trailing slash), or null when refused
 */
function acceptFleetUrl(value, source) {
    const raw = typeof value === 'string' ? value.replace(/\/+$/, '') : '';
    const v = validateFleetUrl(raw);
    if (!v.ok) {
        _lastFleetUrlRejection = { source: source || 'an explicitly supplied server URL', reason: v.reason };
        return null;
    }
    _lastFleetUrlRejection = null;
    return raw;
}

// -----------------------------------------------------------------------------
// Redirect refusal (XACA-0972-029)
// -----------------------------------------------------------------------------
//
// fetch() follows redirects by default, which quietly undoes the host
// validation above: a validated https://fleet.example may 30x to
// https://evil.example, and every check we just performed was against a host we
// no longer talk to. The consequence is not abstract. The machine-registry GET
// returns the PUBLIC KEYS that vault-migrate-env-keys and msg-client then SEAL
// SECRETS TO. Substitute that response and the operator's real API keys are
// sealed to an attacker's key - by a client that validated its URL and found
// nothing wrong, because at validation time nothing was.
//
// DECISION: `redirect: 'manual'` plus an explicit refusal, NOT `redirect:
// 'error'`, and NOT follow-then-re-validate.
//
//   * vs 'error': both fail closed, but 'error' collapses a redirect into a
//     generic `TypeError: fetch failed`, indistinguishable from a dead network.
//     That is precisely the "a missing setting reads as a network fault"
//     failure mode this whole ticket exists to remove. With 'manual' the 3xx
//     comes back as a real Response, so the diagnostic can name what happened
//     and where it pointed.
//   * vs follow-and-re-validate: the vault API has no legitimate reason to
//     redirect, so there is no working deployment to preserve. Re-validating
//     per hop means getting every hop right forever, on the path that handles
//     key material; refusing outright is one rule with no edge cases.
//
// The legitimate non-redirect path is untouched: a 2xx, a 4xx and a 5xx all
// behave exactly as before. Only a 3xx - which no vault endpoint emits - is
// newly refused.
//
// REDACTION: the message names ONLY the redirect target's hostname, never the
// raw Location header, which can carry credentials or a token in its query
// string. Same contract as validateFleetUrl (XACA-0972-028).

/**
 * The fetch init fields every fleet-bound request must carry.
 * Spread into the caller's own init: `{ ...fleetFetchInit(), method: 'POST' }`.
 * @returns {{ redirect: 'manual' }}
 */
function fleetFetchInit() {
    return { redirect: 'manual' };
}

/**
 * Refuse a redirect response instead of following it.
 *
 * Pass-through for every non-3xx response, so callers can wrap a fetch() call
 * inline without changing how they handle success or ordinary HTTP errors.
 *
 * @param {{ status?: number, headers?: { get?: Function } }} res
 * @param {string} [requestUrl] the URL that was requested (base for a relative Location)
 * @returns {*} res, unchanged, when it is not a redirect
 * @throws {Error} with .code = 'FLEET_REDIRECT_REFUSED' and .httpStatus set
 */
function assertNoRedirect(res, requestUrl) {
    if (!res || typeof res.status !== 'number') return res;

    // XACA-0972-037: a 3xx status is only what an UNFOLLOWED redirect looks
    // like. If `redirect: 'manual'` is ever lost -- a caller override, a new
    // call site that forgets fleetFetchInit() -- fetch follows transparently
    // and hands us a 200 from the redirected host, which the status check
    // below would wave straight through. `res.redirected` is the only signal
    // that survives that, so check it FIRST and treat it as the same refusal.
    // Defence in depth: the spread order is the primary guard, this is the
    // backstop for when someone changes it.
    if (res.redirected === true) {
        const err = new Error(
            'fleet server redirected and the redirect was FOLLOWED before this ' +
            'check ran, which means the redirect guard was bypassed. Refusing ' +
            'the response: key material must not reach a host the URL ' +
            'validation never saw. Ensure the fetch init keeps redirect: manual.'
        );
        err.code = 'FLEET_REDIRECT_FOLLOWED';
        throw err;
    }

    if (res.status < 300 || res.status > 399) return res;

    let where = 'an undisclosed host';
    try {
        const loc = res.headers && typeof res.headers.get === 'function'
            ? res.headers.get('location')
            : null;
        if (loc) {
            // Resolve against the request URL so a RELATIVE Location still yields
            // a hostname. Refused either way - a same-host redirect is still a
            // redirect from an API that must not emit one - but naming the host
            // is what makes the message actionable.
            const target = new URL(loc, requestUrl || undefined);
            where = `"${target.hostname}"`;
        }
    } catch (_) { /* unparseable Location - stay with the redacted placeholder */ }

    const err = new Error(
        `fleet server returned HTTP ${res.status} (a redirect) and it was REFUSED, ` +
        `not followed: it pointed at ${where}. The vault API does not redirect. ` +
        `Following it would hand key material to a host that was never validated. ` +
        `Point the fleet URL directly at the real server.`
    );
    err.code       = 'FLEET_REDIRECT_REFUSED';
    err.httpStatus = res.status;
    throw err;
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

// -----------------------------------------------------------------------------
// Two-tier bearer-token resolution (XACA-0398-004)
// -----------------------------------------------------------------------------
//
// Design: kanban/plans/XACA-0398/XACA-0398_credential_design.md §2.2/§4.1
// (USER DECISIONS: two-tier model approved). This module already hosts the
// shared FLEET URL resolver above, for the same reason it must host the
// shared TOKEN resolvers too — it is the one vault file mirrored into the
// Homebrew tap and required() by msg-client.js, vault-fetch.js and
// vault-migrate-env-keys.js, so a second copy is a second chance to drift
// (msg-client.js's own resolveAuthToken() had already drifted this way —
// first-existing-file-wins vs resolveFleetUrl()'s loop-and-fall-through,
// XACA-0972-016 — before this ticket deduped it onto resolveFleetAuthToken()
// below).
//
// FLEET tier: machine-to-machine traffic (reporters, msg-client, the
// msg-relay guard). Read-only, synchronous, and — same posture as the
// private-key file fallback — lives in fleet-config.json at mode 0600.
//
// ADMIN tier: everything an operator does by hand from a CLI (vault
// registration/rotation, the migration tool). NEVER persisted anywhere —
// env var for one command, or a hidden TTY prompt. Because a TTY prompt is
// asynchronous, resolution here is async even on the fleet-tier path, so
// every caller can `await` uniformly regardless of which tier it asked for.

/**
 * Resolve the FLEET-tier bearer token: env FLEET_AUTH_TOKEN first (if
 * non-blank), else LOOP fleetConfigCandidates() and fall THROUGH a file that
 * exists but carries no usable authToken — mirrors resolveFleetUrl()'s
 * fall-through (XACA-0972-016). Keep this in sync with kanban-helpers.sh's
 * _kb_fleet_auth_args, which currently uses first-existing-file-wins;
 * aligning that shell copy is optional in-scope polish per the design doc,
 * not required by this ticket.
 * @returns {string|null} the token, or null if nothing resolves
 */
function resolveFleetAuthToken() {
    if (typeof process.env.FLEET_AUTH_TOKEN === 'string') {
        const envTok = process.env.FLEET_AUTH_TOKEN.trim();
        if (envTok.length > 0) return envTok;
    }
    for (const cfgPath of fleetConfigCandidates()) {
        let token;
        try {
            const cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
            token = cfg && cfg.centralServer && cfg.centralServer.authToken;
        } catch (_) {
            continue; // missing, unreadable, or malformed — try the next one
        }
        if (typeof token === 'string' && token.trim().length > 0) return token.trim();
    }
    return null;
}

/**
 * Hidden (non-echoing) single-line TTY read. Used ONLY for the admin-token
 * prompt below — there is deliberately no interactive path for the fleet
 * token. Never writes the typed value anywhere but the resolved Promise;
 * every keystroke handling branch below discards its input on Ctrl-C.
 *
 * Injectable via `deps` so tests never touch a real TTY: pass fake
 * `stdin`/`stdout` EventEmitter-shaped stubs and drive `onData` yourself.
 *
 * @param {string} promptText
 * @param {{ stdin?: object, stdout?: object }} [deps]
 * @returns {Promise<string|null>} the typed line (untrimmed), or null on Ctrl-C
 */
function readHiddenLine(promptText, deps) {
    deps = deps || {};
    const stdin = deps.stdin || process.stdin;
    const stdout = deps.stdout || process.stdout;
    return new Promise((resolve) => {
        stdout.write(promptText);
        let input = '';
        const canRaw = typeof stdin.setRawMode === 'function';
        const wasRaw = canRaw && typeof stdin.isRaw === 'boolean' ? stdin.isRaw : false;
        if (canRaw) stdin.setRawMode(true);
        if (typeof stdin.resume === 'function') stdin.resume();
        if (typeof stdin.setEncoding === 'function') stdin.setEncoding('utf8');

        function cleanup() {
            stdin.removeListener('data', onData);
            if (canRaw) stdin.setRawMode(wasRaw);
            if (typeof stdin.pause === 'function') stdin.pause();
        }

        function onData(chunk) {
            const s = chunk.toString();
            for (const ch of s) {
                if (ch === '\n' || ch === '\r') {
                    cleanup();
                    stdout.write('\n');
                    resolve(input);
                    return;
                }
                if (ch === '\u0003') { // Ctrl-C — abandon, never partial-resolve
                    cleanup();
                    stdout.write('\n');
                    resolve(null);
                    return;
                }
                if (ch === '\u007f' || ch === '\b') { // backspace/delete
                    input = input.slice(0, -1);
                    continue;
                }
                input += ch;
            }
        }
        stdin.on('data', onData);
    });
}

/**
 * Resolve the ADMIN-tier bearer token (design §2.2/§4.1). Env
 * FLEET_ADMIN_TOKEN first (if non-blank); otherwise, only when the caller
 * allows an interactive prompt AND stdin is a real TTY, a hidden prompt.
 * NEVER reads or writes any file — that is the entire point of the two-tier
 * split (design §6): this credential must not be able to sit in plaintext on
 * a fleet machine the way the fleet token does.
 *
 * @param {{ interactive?: boolean }} [opts]
 * @param {{ isTTY?: boolean, readHiddenLine?: Function, stdin?: object, stdout?: object }} [deps]
 *        injectable for tests — `isTTY: false` (or omitting a real TTY)
 *        short-circuits to null with no prompt, exactly as an unattended run
 *        (stdin closed to /dev/null) does in production.
 * @returns {Promise<string|null>}
 */
async function resolveFleetAdminToken(opts, deps) {
    opts = opts || {};
    deps = deps || {};
    if (typeof process.env.FLEET_ADMIN_TOKEN === 'string') {
        const envTok = process.env.FLEET_ADMIN_TOKEN.trim();
        if (envTok.length > 0) return envTok;
    }
    const isTTY = deps.isTTY !== undefined ? deps.isTTY : !!(process.stdin && process.stdin.isTTY);
    if (!opts.interactive || !isTTY) return null;
    const prompt = deps.readHiddenLine || readHiddenLine;
    const line = await prompt('FLEET_ADMIN_TOKEN (input hidden, Ctrl-C to skip): ', deps);
    if (!line) return null;
    const trimmed = line.trim();
    return trimmed.length > 0 ? trimmed : null;
}

// -----------------------------------------------------------------------------
// Admin-credential transport rule (XACA-0398-015)
// -----------------------------------------------------------------------------
//
// ALLOWED_FLEET_SCHEMES deliberately permits plain http for ANY host (a LAN/dev
// fleet-monitor is legitimate — see validateFleetUrl). That is acceptable for
// the FLEET token's traffic, whose posture predates this rule and is out of
// scope here. It is NOT acceptable for the ADMIN credential: it unlocks vault
// writes, machine (re-)registration and the engine registry, and over http to
// a non-loopback host it crosses the network in cleartext.
//
// Rule: the admin Authorization header is attached ONLY to an https:// URL, or
// to http:// on a loopback host (localhost, 127.0.0.0/8, ::1 — traffic that
// never leaves the machine). Anything else fails closed with
// ADMIN_TOKEN_INSECURE_TRANSPORT BEFORE the request is sent. Callers also
// avoid PROMPTING for a token they would then be unable to send.
//
// Every admin-header sender goes through this: registerMachine() (register,
// --register-only, --rotate) here, and adminAuthHeaders() in
// scripts/vault-migrate-env-keys.js.

/** @returns {boolean} true for localhost, 127.0.0.0/8, or ::1 (URL.hostname form) */
function isLoopbackHost(hostname) {
    const h = String(hostname || '').toLowerCase();
    if (h === 'localhost') return true;
    if (h === '[::1]' || h === '::1') return true;
    const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(h);
    if (m && Number(m[1]) === 127 && m.slice(2).every((o) => Number(o) <= 255)) return true;
    return false;
}

/**
 * May the admin credential be sent to this URL?
 * @param {string} url absolute URL
 * @returns {{ ok: true }|{ ok: false, reason: string }} reason names scheme +
 *          host only (never userinfo, path or query)
 */
function adminTransportCheck(url) {
    let parsed;
    try {
        parsed = new URL(String(url));
    } catch (_) {
        return { ok: false, reason: 'the fleet URL is not a valid absolute URL' };
    }
    if (parsed.protocol === 'https:') return { ok: true };
    if (parsed.protocol === 'http:' && isLoopbackHost(parsed.hostname)) return { ok: true };
    return {
        ok: false,
        reason: `the fleet URL is ${parsed.protocol}//${parsed.hostname} — the admin credential ` +
                `is only sent over https, or over plain http to a loopback host ` +
                `(localhost, 127.0.0.0/8, ::1)`,
    };
}

/**
 * Throw ADMIN_TOKEN_INSECURE_TRANSPORT unless adminTransportCheck(url) passes.
 * The message never contains the credential.
 */
function assertAdminTransport(url) {
    const check = adminTransportCheck(url);
    if (check.ok) return;
    const err = new Error(
        `Refusing to send the admin credential (FLEET_ADMIN_TOKEN): ${check.reason}. ` +
        `Nothing was sent. Point FLEET_MONITOR_URL / --server at the https:// endpoint.`
    );
    err.code = 'ADMIN_TOKEN_INSECURE_TRANSPORT';
    throw err;
}

/**
 * Build the Authorization header for a fleet-bound request, or `{}` when no
 * credential resolves. Nothing is ever logged. Always returns a Promise so
 * callers can `await` uniformly regardless of tier — the fleet-tier branch
 * resolves synchronously under the hood, but exposing that difference to
 * callers is exactly the kind of asymmetry that produces a forgotten-`await`
 * bug later.
 * @param {'fleet'|'admin'} tier
 * @param {{ interactive?: boolean }} [opts] passed through to resolveFleetAdminToken
 * @returns {Promise<{Authorization?: string}>}
 */
async function fleetAuthHeaders(tier, opts) {
    const token = tier === 'admin'
        ? await resolveFleetAdminToken(opts)
        : resolveFleetAuthToken();
    return token ? { Authorization: `Bearer ${token}` } : {};
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

/**
 * Derive the X25519 PUBLIC key from a stored PRIVATE key (base64 ORIGINAL).
 * Used by --register-only (XACA-0398-004), which re-registers an EXISTING
 * key without regenerating it — mirrors msg-client.js's sealOpenLocal(),
 * which already derives its own public key the same way (crypto_scalarmult_
 * base) precisely so the server never needs to hand a machine its own
 * pubkey back.
 * @param {string} privateKeyB64
 * @returns {Promise<string>} base64 ORIGINAL public key
 */
async function derivePublicKeyFromPrivate(privateKeyB64) {
    const sodium = await ensureSodium();
    const v = sodium.base64_variants.ORIGINAL;
    const sk = sodium.from_base64(privateKeyB64, v);
    const pk = sodium.crypto_scalarmult_base(sk);
    return sodium.to_base64(pk, v);
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
    return path.join(vaultDir(), `${slug}.key`);
}

// -----------------------------------------------------------------------------
// Rotation staging slot (XACA-0398-014)
// -----------------------------------------------------------------------------
//
// --rotate used to overwrite the stored private key FIRST and register the new
// public key SECOND. Any failure in between (no admin credential -> ENROLLMENT
// PENDING, a 401, a 5xx, a dead network) left the server holding the OLD
// public key while the only copy of the matching private key had just been
// destroyed: every secret sealed to this machine became unopenable.
//
// The rule now: the stored key is not touched until the server has ACCEPTED
// the new public key (2xx). Neither backend offers an atomic
// "replace-if-the-server-agrees", so the new key goes to a STAGING slot first:
//   1. resolve the admin credential + fleet URL (refuse, writing nothing, if
//      either is missing);
//   2. write the new key to the staging slot (a failure here aborts BEFORE
//      anything is sent — the server never learns a pubkey we cannot open);
//   3. PUT the new public key;
//   4. only on 2xx, promote: write it over the primary slot, then drop staging.
// A non-2xx or a throw at step 3 leaves the primary key exactly as it was. The
// staging slot is deliberately NOT deleted on failure: a network error can
// happen AFTER the server applied the PUT, and in that case the staged key is
// the only copy of the private key the server now expects.
//
// XACA-0398-021: for that same reason a later --rotate must NEVER overwrite
// an existing staging slot. It used to (force:true), so "network error after
// the server applied the PUT" followed by a retried --rotate that then failed
// destroyed the only key matching the server. Now --rotate REFUSES while a
// staging slot exists (ROTATE_STAGING_EXISTS -> EXIT_ROTATE_REFUSED, nothing
// written, nothing sent). Recovery is --resume-rotation, which re-PUTs the
// STAGED key's public key and promotes it on 2xx. That is correct whichever
// key the server holds right now: if it already has the staged key the PUT is
// a no-op, and if it still has the old one the PUT completes the rotation.
//
// The staging slug appends ".rotating". validateSlug() forbids "." so it can
// never collide with a real machine id: file backend -> <slug>.rotating.key,
// Keychain -> account "<slug>.rotating" under the same service.

/** @returns {string} the staging-slot slug used during --rotate */
function stagingSlug(slug) {
    return `${slug}.rotating`;
}

/**
 * Best-effort removal of the staging slot after a successful promote. Never
 * throws: the promote already succeeded, so a leftover staging copy is only
 * clutter (it holds the SAME key as the primary slot by then).
 * @returns {boolean} whether it was removed
 */
function removeStagedKey(slug, deps) {
    deps = deps || {};
    const backend = deps.backend || chooseKeyStorageBackend();
    try {
        if (backend === 'keychain') {
            const del = deps.keychainDelete || ((acct) => execFileSync(
                'security',
                ['delete-generic-password', '-s', KEYCHAIN_SERVICE, '-a', acct],
                { stdio: 'ignore' }
            ));
            del(stagingSlug(slug));
        } else {
            (deps.unlink || fs.unlinkSync)(fallbackKeyPath(stagingSlug(slug)));
        }
        return true;
    } catch (_) {
        return false;
    }
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

// -----------------------------------------------------------------------------
// Keychain write channel (XACA-1224)
// -----------------------------------------------------------------------------
//
// keychainAddPassword used to pass the private key as `-w <value>` — an argv
// element. MEASURED (M1Mini, 2026-09-14, over SSH, login Keychain locked): when
// `security add-generic-password` fails, Node's execFileSync builds the thrown
// Error's `.message` by joining the FULL argv, so the freshly generated private
// key was printed verbatim to stderr. Argv is also visible to any other local
// process via `ps` for the life of the child, independent of whether it fails.
//
// Three channels were evaluated empirically against throwaway keychains
// (`security create-keychain` under /tmp, deleted afterwards — never the real
// login Keychain, never a real key):
//
//   (a) `security -i` (interactive/batch command mode): the command line is fed
//       on the CHILD'S STDIN via execFileSync's `input` option, so the secret
//       never touches argv and is invisible to `ps` (verified: polled `ps
//       auxww` for the base64 payload substring while `security -i` sat
//       blocked on stdin — no match). CHOSEN. Verified:
//         - success: item is added and independently readable via
//           `find-generic-password` WITHOUT `-w` (existence only, never
//           re-reading the secret in a test assertion).
//         - genuine inner failure propagates a real nonzero exit: adding a
//           duplicate item without `-U` exited 45 (not 0) with stderr
//           containing "already exists" / "-25299".
//         - a malformed command line exits 1, not 0.
//         - quoted literals (the -D/-j description strings, which contain
//           spaces) round-trip correctly through `-i`'s line tokenizer.
//       KNOWN HAZARD (does not apply to this call site): if a positional
//       keychain-file argument is given and does NOT exist as a file, `security`
//       silently falls through to the DEFAULT keychain and exits 0 — a
//       "malformed check returns the reassuring result" trap. This call never
//       passes a keychain-file argument (matches the pre-fix behaviour, which
//       also always targeted the default keychain), so that hazard is not
//       reachable here; it is recorded so nobody "improves" this by adding an
//       explicit keychain path without re-verifying.
//
//   (b) `-w` as the LAST option with no value (security prompts, value piped to
//       stdin). REJECTED — measured, not assumed: with `-w` truly last (no
//       trailing positional keychain arg — the same shape production uses),
//       piping the secret to stdin produced TWO tty-style prompts
//       ("password data for new item:" / "retype password for new item:")
//       and silently stored an EMPTY password with exit 0 — proof it reads via
//       `readpassphrase()` against /dev/tty, not stdin, exactly the
//       SSH/non-tty failure this ticket exists to fix, and worse: it "succeeds"
//       (exit 0) while storing the wrong value. Separately, placing `-w`
//       immediately before a positional keychain-path argument (to target a
//       throwaway keychain for testing) caused `security` to consume that path
//       AS THE -w VALUE instead of prompting — so this form cannot even be
//       safely test-isolated from the caller's real default keychain.
//
//   (c) (not used) writing the key to a temp file and using some `security`
//       file-input form — `security` has no such option for
//       add-generic-password; not applicable.
//
// Failures are classified via classifyKeychainFailure() below and re-thrown as
// a FIXED, sanitized Error (XACA-1224-002) — see that function's doc comment.
// -----------------------------------------------------------------------------

/**
 * Known `security(1)` OSStatus failure signatures we recognize and give a
 * specific, actionable (but still argv/secret-free) message for. Matched
 * against captured stderr text. Codes + exact message text confirmed via
 * `security error <code>` on this machine (2026-09-15) — not guessed:
 *   -25308 "User interaction is not allowed."            (locked, no GUI/SSH)
 *   -25293 "The user name or passphrase you entered is not correct."
 *   -25299 "The specified item already exists in the keychain."
 *   -128   "User canceled the operation."
 *   -25291 "No keychain is available. You may need to restart your computer."
 * Anything unmatched falls through to a generic, exit-code-only message —
 * NEVER the raw stderr text, which could echo something unexpected.
 * @type {Array<{ match: RegExp, message: string }>}
 */
const KEYCHAIN_ERROR_SIGNATURES = [
    {
        match: /-25308|interaction is not allowed/i,
        message: 'Keychain write failed: the Keychain is locked and cannot prompt for ' +
                 'unlock in this session (no GUI / running over SSH). Unlock it first ' +
                 '(e.g. `security unlock-keychain`) or run this from a GUI session.',
    },
    {
        match: /-25293|passphrase you entered is not correct/i,
        message: 'Keychain write failed: the Keychain password entered to unlock it was incorrect.',
    },
    {
        match: /-25299|already exists in the keychain/i,
        message: 'Keychain write failed: an item already exists for this machine id. Pass --force to replace it, or --rotate to update it in place.',
    },
    {
        // "returned -128" is the literal shape `security` emits (verified —
        // see the file-level comment); matching that instead of a bare "-128"
        // avoids false-matching an unrelated "-128" substring elsewhere.
        match: /returned -128\b|User canceled the operation/i,
        message: 'Keychain write failed: the Keychain access prompt was canceled.',
    },
    {
        match: /-25291|No keychain is available/i,
        message: 'Keychain write failed: no Keychain is available on this system.',
    },
];

/**
 * Classify a failed `security` invocation into a FIXED, sanitized message.
 * NEVER echoes the command line, argv, or raw stderr — only a recognized
 * failure class, or a generic exit-code-only fallback.
 * @param {string} stderrText captured stderr (may be empty/undefined)
 * @param {number|string|null} [exitStatus] child exit code or signal name
 * @returns {string}
 */
function classifyKeychainFailure(stderrText, exitStatus) {
    const text = typeof stderrText === 'string' ? stderrText : '';
    for (const sig of KEYCHAIN_ERROR_SIGNATURES) {
        if (sig.match.test(text)) return sig.message;
    }
    const statusText = exitStatus === undefined || exitStatus === null ? 'unknown' : String(exitStatus);
    return `Keychain write failed (security exit ${statusText}).`;
}

/**
 * Add (or update with force) the private key as a Keychain generic password.
 *
 * The private key is fed to `security -i` (interactive/batch command mode) on
 * the child's STDIN, never as an argv element — see the file-level comment
 * above ("Keychain write channel", XACA-1224) for the empirical evaluation of
 * why. `-U` (force) updates an existing item.
 *
 * On failure this throws a sanitized Error (`.sanitized = true`) whose message
 * is one of the fixed classifications in classifyKeychainFailure() — never the
 * raw child error, which Node would otherwise build from argv/stderr.
 *
 * @param {string} slug
 * @param {string} privateKeyB64
 * @param {boolean} force
 */
function keychainAddPassword(slug, privateKeyB64, force) {
    // security -i's line tokenizer supports double-quoted values containing
    // spaces (verified empirically — the -D/-j literals below round-trip
    // correctly). slug is restricted upstream to ^[a-z][a-z0-9-]*$ and
    // privateKeyB64 is base64 (ORIGINAL variant: [A-Za-z0-9+/=] only) — neither
    // charset can contain a `"` or break out of a quoted token, but refuse
    // outright rather than trust that invariant silently: a value that could
    // break the command line must never be interpolated into it.
    if (/["\\\r\n]/.test(slug) || /["\\\r\n]/.test(privateKeyB64)) {
        throw new Error('Refusing to write to Keychain: machine id or key material contains an unexpected character.');
    }

    const parts = [
        'add-generic-password',
        '-s', `"${KEYCHAIN_SERVICE}"`,
        '-a', `"${slug}"`,
        '-w', `"${privateKeyB64}"`,
        '-D', '"AITeamForge vault private key"',
        '-j', '"X25519 private key for Fleet Monitor secret vault. Do not export."',
    ];
    if (force) parts.push('-U');
    const script = parts.join(' ') + '\n';

    try {
        // Default stdio ('pipe') captures stdout/stderr into err.stdout/err.stderr
        // on failure rather than letting them inherit to our own stdout/stderr —
        // the key never appears there because it was never on argv to begin with,
        // and we never print the captured stderr raw (see catch below).
        execFileSync('security', ['-i'], { input: script, encoding: 'utf8' });
    } catch (err) {
        const stderrText = (err && (err.stderr || '')).toString();
        const exitStatus = err && (err.status !== undefined && err.status !== null ? err.status : err.signal);
        const sanitized = new Error(classifyKeychainFailure(stderrText, exitStatus));
        sanitized.sanitized = true;
        sanitized.code = 'KEYCHAIN_WRITE_FAILED';
        throw sanitized;
    }
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
 * @param {{ serverUrl?: string, rotate?: boolean, fetchImpl?: Function,
 *           adminToken?: string|null, interactiveAdmin?: boolean }} [opts]
 *   rotate=true -> PUT /api/vault/machines/:id (in-place key update, §8.2)
 *   rotate=false -> POST /api/vault/machines (create; 409 on collision)
 *   adminToken: if provided (including `null`/`''`), used AS-IS — no
 *     resolution or prompt is attempted, so a caller that already resolved
 *     (or deliberately withheld) the credential is never asked twice. If
 *     `undefined` (the default), the admin token is resolved here via
 *     fleetAuthHeaders('admin', { interactive: interactiveAdmin }).
 * @returns {Promise<{ status: number, body: any }>}
 */
async function registerMachine(payload, opts) {
    opts = opts || {};
    // Resolve LAZILY, at call time. An explicit opts.serverUrl always wins; only
    // the default changed (XACA-0972-002). No silent localhost fallback.
    //
    // XACA-0972-027: an explicit value is VALIDATED too, not waved through. It
    // still wins over resolution, but "wins" means "is used if acceptable", not
    // "skips the check". A refused explicit URL does NOT fall back to
    // resolveFleetUrl() - see acceptFleetUrl's note on failing closed.
    const resolved = opts.serverUrl
        ? acceptFleetUrl(opts.serverUrl, '--server / opts.serverUrl')
        : resolveFleetUrl();
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

    // XACA-0398-004: register/rotate is an ADMIN-tier route now. Send the
    // Authorization header alongside the fleet-URL/redirect guards this
    // function already applies — none of that machinery changes.
    //
    // XACA-0398-015: never PROMPT for a token that cannot be sent (insecure
    // transport), and never SEND one: the check below runs before fetch().
    const transportOk = adminTransportCheck(url).ok;
    const adminHeaders = opts.adminToken !== undefined
        ? (opts.adminToken ? { Authorization: `Bearer ${opts.adminToken}` } : {})
        : await fleetAuthHeaders('admin', { interactive: !!opts.interactiveAdmin && transportOk });
    if (adminHeaders.Authorization && !transportOk) assertAdminTransport(url);

    // XACA-0972-029: refuse redirects rather than following them. This request
    // carries the machine's PUBLIC key and registers it under an id; a redirect
    // would register this machine with a host the URL validation never saw.
    const res = assertNoRedirect(await doFetch(url, {
        method,
        headers: { 'Content-Type': 'application/json', ...adminHeaders },
        body: JSON.stringify(payload),
        // XACA-0972-037: LAST, so nothing above can override the guard.
        ...fleetFetchInit(),
    }), url);

    let body = null;
    try { body = await res.json(); } catch (_) { /* non-JSON / empty body */ }
    return { status: res.status, body };
}

/**
 * Is `machineId` currently listed in the PUBLIC machine registry?
 * (XACA-0398-004 §5.3 — the registration-trap fix.) This GET is unauthenticated
 * (design §5.2/§1) on every posture, so this never needs a credential.
 *
 * Used by registerOnly() to decide POST (never seen before) vs PUT (rotate an
 * existing entry) — which is also what makes it the authoritative "is this
 * machine actually enrolled" signal: it is the server's own answer, not a
 * local marker file that could drift from it (a marker survives a manual
 * `DELETE /api/vault/machines/:id`; this does not).
 *
 * @param {string} serverUrl already-resolved base URL (no trailing slash)
 * @param {string} machineId
 * @param {{ fetchImpl?: Function }} [opts]
 * @returns {Promise<boolean>}
 * @throws {Error} on a non-2xx response or a network/parse failure — callers
 *         that want a "don't know" tri-state should catch and treat any
 *         throw as unknown, never as false.
 */
async function isMachineRegistered(serverUrl, machineId, opts) {
    opts = opts || {};
    const doFetch = opts.fetchImpl || globalThis.fetch;
    if (typeof doFetch !== 'function') {
        throw new Error('No fetch implementation available (Node 18+ required, or pass opts.fetchImpl)');
    }
    const base = serverUrl.replace(/\/+$/, '');
    const url = `${base}/api/vault/machines`;
    const res = assertNoRedirect(await doFetch(url, { ...fleetFetchInit() }), url);
    if (!res.ok) {
        const err = new Error(`GET /api/vault/machines returned HTTP ${res.status}`);
        err.httpStatus = res.status;
        throw err;
    }
    const body = await res.json();
    const machines = (body && body.machines) || [];
    return machines.some((m) => m && m.id === machineId);
}

/**
 * Re-register an ALREADY-STORED key without regenerating it (XACA-0398-004
 * §4.2, closing the §5.3 registration trap). Derives the public key from the
 * stored private key (derivePublicKeyFromPrivate), checks the public registry
 * to decide POST vs PUT, and requires the ADMIN-tier credential — the same
 * ENROLLMENT PENDING posture as provisionMachine() applies when none resolves.
 *
 * @param {{ machineId?: string, label?: string, serverUrl?: string,
 *           dryRun?: boolean, log?: (msg:string)=>void }} [opts]
 * @returns {Promise<{ machineId: string, publicKey: string,
 *                     registration: object|null, payload: object, pending: boolean }>}
 */
async function registerOnly(opts) {
    opts = opts || {};
    const log = opts.log || (() => {});
    const machineId = opts.machineId || defaultMachineSlug();
    const label = opts.label || `${os.userInfo().username}@${os.hostname()}`;

    const slugErrors = validateSlug(machineId);
    if (slugErrors.length) {
        throw new Error('Invalid machine id: ' + slugErrors.join('; '));
    }

    const backend = chooseKeyStorageBackend();
    if (!privateKeyExists(machineId, { backend })) {
        throw new Error(
            `No stored private key for machine "${machineId}" (${backend}). ` +
            `--register-only never generates a key — run vault-keygen without ` +
            `it first, or without --register-only, to create one.`
        );
    }
    const privateKeyB64 = readPrivateKey(machineId, { backend });
    const publicKey = await derivePublicKeyFromPrivate(privateKeyB64);
    const payload = await buildRegistrationPayload({ id: machineId, label, publicKey });

    if (opts.dryRun) {
        log('[dry-run] Skipping registration lookup and network calls.');
        return { machineId, publicKey, registration: null, payload, pending: false };
    }

    const resolvedUrl = opts.serverUrl
        ? acceptFleetUrl(opts.serverUrl, '--server / opts.serverUrl')
        : resolveFleetUrl();
    if (!resolvedUrl) {
        const err = new Error(unresolvedFleetUrlMessage('vault-keygen --register-only'));
        err.code = 'FLEET_URL_UNRESOLVED';
        throw err;
    }

    // XACA-0398-015: --register-only exists to send the admin credential; if
    // the URL cannot carry it, say so now instead of prompting for it.
    assertAdminTransport(resolvedUrl);

    // Admin credential is resolved ONCE, here, and handed to registerMachine
    // as an already-known value (opts.adminToken) so a TTY prompt — if one
    // happens — never fires twice for one invocation.
    const adminToken = await resolveFleetAdminToken({ interactive: true });
    if (!adminToken) {
        log(
            'ENROLLMENT PENDING: no admin credential available (FLEET_ADMIN_TOKEN ' +
            'unset, and no interactive TTY to prompt). Nothing was sent to the ' +
            'server. Re-run with FLEET_ADMIN_TOKEN set once you have it.'
        );
        return { machineId, publicKey, registration: null, payload, pending: true };
    }

    let alreadyRegistered = false;
    try {
        alreadyRegistered = await isMachineRegistered(resolvedUrl, machineId, { fetchImpl: opts.fetchImpl });
    } catch (err) {
        // Skip-on-doubt: an unreadable registry answer must not silently pick
        // POST-vs-PUT — try POST (first-time enrollment is the more common
        // reason --register-only gets run) and let the server's own 409 say
        // "already exists" if that guess was wrong.
        log(`Warning: could not confirm current registration (${err.message}); assuming not yet registered.`);
    }

    const registration = await registerMachine(payload, {
        serverUrl: resolvedUrl,
        rotate: alreadyRegistered,
        adminToken,
        fetchImpl: opts.fetchImpl,
    });

    if (registration.status >= 200 && registration.status < 300) {
        log(`Registered public key (${registration.status}).`);
    } else if (registration.status === 401) {
        log('Registration returned HTTP 401: the admin credential was rejected. Supply a valid FLEET_ADMIN_TOKEN and retry.');
    } else if (registration.status === 409) {
        log(`Server returned 409 (machine id "${machineId}" already registered). Re-run once more — the registry now shows it, so the next attempt rotates instead.`);
    } else {
        log(`Registration returned HTTP ${registration.status}: ` + JSON.stringify(registration.body || {}));
    }

    return { machineId, publicKey, registration, payload, pending: false };
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
 *                     registration: object|null, payload: object, pending: boolean }>}
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
        return { machineId, publicKey, storage: null, registration: null, payload, pending: false };
    }

    if (opts.rotate) {
        return rotateMachineKey({ machineId, backend, publicKey, privateKey, payload, opts, log });
    }

    // Persist the private key (force when explicitly forced).
    const storage = persistPrivateKey(machineId, privateKey, {
        backend,
        force: opts.force || opts.rotate,
    });
    log(`Private key stored: ${storage.location}`);

    // XACA-0398-004 §4.2/§5.3/§6: registration is now ADMIN-tier. Resolve the
    // credential BEFORE attempting the POST/PUT — env FLEET_ADMIN_TOKEN, or
    // (only when stdin is a real TTY) a hidden prompt. An UNATTENDED caller
    // (kb-msg-provision closes stdin to /dev/null under --unattended) never
    // has a TTY here, so this naturally resolves to null with no prompt and
    // no hang — that IS the "unattended install stops at ENROLLMENT PENDING"
    // decision (design §6/§10 Q4), not a separate code path to remember.
    const adminToken = await resolveFleetAdminToken({ interactive: true });
    if (!adminToken) {
        log(
            'ENROLLMENT PENDING: the key is generated and stored, but NOT registered ' +
            '— no admin credential available (FLEET_ADMIN_TOKEN unset, and no ' +
            'interactive TTY to prompt). An operator must complete enrollment with:\n' +
            `    FLEET_ADMIN_TOKEN=<token> node vault-keygen.js --register-only --machine-id ${machineId}`
        );
        return { machineId, publicKey, storage, registration: null, payload, pending: true };
    }

    // Register the public key with the vault.
    const registration = await registerMachine(payload, {
        serverUrl: opts.serverUrl,
        rotate: opts.rotate,
        adminToken,
    });

    if (registration.status >= 200 && registration.status < 300) {
        log(`Registered public key (${registration.status}).`);
    } else if (registration.status === 401) {
        log('Registration returned HTTP 401: the admin credential was rejected. Supply FLEET_ADMIN_TOKEN and retry (or --register-only once you have a valid one).');
    } else if (registration.status === 409) {
        log(`Server returned 409 (machine id "${machineId}" already registered). ` +
            `Use --rotate to update the existing entry's public_key.`);
    } else {
        log(`Registration returned HTTP ${registration.status}: ` +
            JSON.stringify(registration.body || {}));
    }

    return { machineId, publicKey, storage, registration, payload, pending: false };
}

/**
 * The --rotate half of provisionMachine (XACA-0398-014). See the "Rotation
 * staging slot" comment above fallbackKeyPath for the ordering and why it
 * cannot lose the key. Throws ROTATE_ADMIN_REQUIRED (-> EXIT_ROTATE_REFUSED)
 * with NOTHING written when no admin credential is available.
 */
async function rotateMachineKey({ machineId, backend, publicKey, privateKey, payload, opts, log }) {
    // -1. XACA-0398-021: an existing staging slot may be the ONLY key that
    //     matches the server (a previous PUT applied, then its response was
    //     lost). Never overwrite it — refuse before anything else happens.
    if (privateKeyExists(stagingSlug(machineId), { backend })) {
        throw stagingExistsError(machineId, backend);
    }

    // 0. Resolve the URL (no throw yet, no write). XACA-0398-015: a URL that
    //    cannot carry the admin credential makes rotation impossible — refuse
    //    before prompting for the credential or writing anything.
    const resolvedUrl = opts.serverUrl
        ? acceptFleetUrl(opts.serverUrl, '--server / opts.serverUrl')
        : resolveFleetUrl();
    if (resolvedUrl) assertAdminTransport(resolvedUrl);

    // 1. Credential FIRST (before any write). No ENROLLMENT PENDING for a rotation: pending would
    //    mean "new key stored, server still on the old one" — the exact state
    //    this ordering exists to make impossible.
    const adminToken = await resolveFleetAdminToken({ interactive: true });
    if (!adminToken) {
        const err = new Error(
            'Refusing to rotate: no admin credential available (FLEET_ADMIN_TOKEN unset, ' +
            'and no interactive TTY to prompt). Rotation must register the new public key ' +
            'in the same run, so NOTHING was generated into storage and the existing key ' +
            'is unchanged. Re-run with FLEET_ADMIN_TOKEN set.'
        );
        err.code = 'ROTATE_ADMIN_REQUIRED';
        throw err;
    }

    // 2. An unresolvable URL is refused here — still before any write.
    //    registerMachine would refuse it too, but only AFTER staging.
    if (!resolvedUrl) {
        const err = new Error(unresolvedFleetUrlMessage('vault-keygen --rotate'));
        err.code = 'FLEET_URL_UNRESOLVED';
        throw err;
    }

    // 3. Stage the new private key. The primary slot is untouched. force:false
    //    (XACA-0398-021): the slot was just checked empty, and on the Keychain
    //    backend a racing writer then fails -25299 instead of being clobbered.
    const staged = persistPrivateKey(stagingSlug(machineId), privateKey, { backend, force: false });
    log(`New private key staged: ${staged.location}`);

    return registerAndPromote({ machineId, backend, publicKey, privateKey, payload,
        resolvedUrl, adminToken, staged, opts, log });
}

/**
 * The refusal --rotate raises when a staging slot already exists (XACA-0398-021).
 * Mapped to EXIT_ROTATE_REFUSED by main(). Nothing has been written or sent.
 */
function stagingExistsError(machineId, backend) {
    const where = backend === 'keychain'
        ? `Keychain ${KEYCHAIN_SERVICE} / ${stagingSlug(machineId)}`
        : fallbackKeyPath(stagingSlug(machineId));
    const err = new Error(
        `Refusing to rotate: a previous rotation's staged key still exists (${where}). ` +
        `It may be the ONLY private key matching the server — a rotation whose response ` +
        `was lost can still have been applied — so it is never overwritten. NOTHING was ` +
        `written or sent. To recover, run:\n` +
        `    FLEET_ADMIN_TOKEN=<token> node vault-keygen.js --resume-rotation --machine-id ${machineId}\n` +
        `That re-registers the STAGED key's public key and promotes it on success, which is ` +
        `correct whichever key the server lists now (GET /api/vault/machines). Only if you are ` +
        `certain the server still lists your CURRENT key and you want to abandon the staged ` +
        `one, remove the staged slot by hand, then --rotate again. ` +
        `See docs/fleet-monitor-auth-cutover.md.`
    );
    err.code = 'ROTATE_STAGING_EXISTS';
    err.sanitized = true;
    return err;
}

/**
 * Steps 4-5 of a rotation, shared by rotateMachineKey and resumeRotation:
 * PUT the staged key's public key, and only on 2xx promote it over the
 * primary slot and drop staging. Any failure leaves both slots as they were.
 */
async function registerAndPromote({ machineId, backend, publicKey, privateKey, payload,
    resolvedUrl, adminToken, staged, opts, log }) {
    // 4. Register the new public key. A throw here propagates with the primary
    //    key intact and the staged copy kept (see the staging-slot comment).
    let registration;
    try {
        registration = await registerMachine(payload, {
            serverUrl: resolvedUrl,
            rotate: true,
            adminToken,
            fetchImpl: opts.fetchImpl,
        });
    } catch (err) {
        log(`Rotation NOT applied: registering the new public key failed (${err.message}). ` +
            `The existing private key is unchanged. The new key is left in staging at ` +
            `${staged.location} in case the server applied it anyway — run ` +
            `--resume-rotation --machine-id ${machineId} to finish (it is safe either way).`);
        throw err;
    }

    if (!(registration.status >= 200 && registration.status < 300)) {
        if (registration.status === 401) {
            log('Rotation returned HTTP 401: the admin credential was rejected.');
        } else {
            log(`Rotation returned HTTP ${registration.status}: ` + JSON.stringify(registration.body || {}));
        }
        log(`Rotation NOT applied: the stored private key is unchanged, and the new key is ` +
            `kept in staging at ${staged.location}. Retry with --resume-rotation --machine-id ${machineId}.`);
        return { machineId, publicKey, storage: null, registration, payload, pending: false };
    }

    // 5. Server accepted the new public key: promote.
    let storage;
    try {
        storage = persistPrivateKey(machineId, privateKey, { backend, force: true });
    } catch (err) {
        const e = new Error(
            `The server accepted the new public key, but promoting the new private key failed ` +
            `(${err.message}). It is still in staging at ${staged.location} — run ` +
            `--resume-rotation --machine-id ${machineId} before doing anything else, or secrets ` +
            `sealed to the new key cannot be opened.`
        );
        e.code = 'ROTATE_PROMOTE_FAILED';
        e.sanitized = true;
        throw e;
    }
    removeStagedKey(machineId, { backend });
    log(`Registered new public key (${registration.status}); private key rotated: ${storage.location}`);
    return { machineId, publicKey, storage, registration, payload, pending: false };
}

/**
 * --resume-rotation (XACA-0398-021): finish a rotation whose staging slot was
 * left behind (lost response, non-2xx, or a failed promote). Re-PUTs the
 * STAGED key's public key and promotes it on 2xx — see the staging-slot
 * comment for why that is right whichever key the server holds. Never
 * generates a key. Refuses (ROTATE_ADMIN_REQUIRED, nothing sent) without an
 * admin credential, like --rotate.
 */
async function resumeRotation(opts) {
    opts = opts || {};
    const log = opts.log || (() => {});
    const machineId = opts.machineId || defaultMachineSlug();
    const label = opts.label || `${os.userInfo().username}@${os.hostname()}`;
    const slugErrors = validateSlug(machineId);
    if (slugErrors.length) throw new Error('Invalid machine id: ' + slugErrors.join('; '));

    const backend = chooseKeyStorageBackend();
    const staging = stagingSlug(machineId);
    if (!privateKeyExists(staging, { backend })) {
        throw new Error(`No staged rotation for machine "${machineId}" (${backend}); nothing to resume.`);
    }
    const privateKey = readPrivateKey(staging, { backend });
    const publicKey = await derivePublicKeyFromPrivate(privateKey);
    const payload = await buildRegistrationPayload({ id: machineId, label, publicKey });
    log(`Resuming rotation for ${machineId} with the staged key (public key ${publicKey}).`);

    if (opts.dryRun) {
        log('[dry-run] Skipping registration and promotion.');
        return { machineId, publicKey, storage: null, registration: null, payload, pending: false };
    }

    const resolvedUrl = opts.serverUrl
        ? acceptFleetUrl(opts.serverUrl, '--server / opts.serverUrl')
        : resolveFleetUrl();
    if (!resolvedUrl) {
        const err = new Error(unresolvedFleetUrlMessage('vault-keygen --resume-rotation'));
        err.code = 'FLEET_URL_UNRESOLVED';
        throw err;
    }
    assertAdminTransport(resolvedUrl);
    const adminToken = await resolveFleetAdminToken({ interactive: true });
    if (!adminToken) {
        const err = new Error(
            'Refusing to resume rotation: no admin credential available (FLEET_ADMIN_TOKEN unset, ' +
            'and no interactive TTY to prompt). Nothing was sent; both keys are unchanged.'
        );
        err.code = 'ROTATE_ADMIN_REQUIRED';
        throw err;
    }
    const staged = { backend, location: backend === 'keychain'
        ? `Keychain ${KEYCHAIN_SERVICE} / ${staging}` : fallbackKeyPath(staging) };
    return registerAndPromote({ machineId, backend, publicKey, privateKey, payload,
        resolvedUrl, adminToken, staged, opts, log });
}

// ─────────────────────────────────────────────────────────────────────────────
// CLI
// ─────────────────────────────────────────────────────────────────────────────

function parseArgs(argv) {
    const opts = { force: false, rotate: false, dryRun: false, registerOnly: false };
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        switch (a) {
            case '--machine-id':   opts.machineId = argv[++i]; break;
            case '--label':        opts.label = argv[++i]; break;
            case '--server':
            case '--server-url':   opts.serverUrl = argv[++i]; break;
            case '--force':        opts.force = true; break;
            case '--rotate':       opts.rotate = true; break;
            case '--dry-run':      opts.dryRun = true; break;
            case '--register-only': opts.registerOnly = true; break;
            case '--resume-rotation': opts.resumeRotation = true; break;
            case '-h':
            case '--help':         opts.help = true; break;
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
                        Refused (exit 4) while a previous rotation's staged key
                        still exists - use --resume-rotation instead.
  --resume-rotation     Finish an interrupted --rotate (XACA-0398-021): re-register
                        the STAGED key's public key and, on success, promote it
                        to the stored key. Safe whichever key the server holds.
  --force               Replace an existing local private key without rotating.
  --register-only       Re-register the ALREADY-STORED key for this machine id
                        without generating a new one (XACA-0398-004). Use this to
                        complete an ENROLLMENT PENDING machine, or to recover one
                        whose key was stored on an earlier run but never actually
                        registered (registration is checked against the live
                        registry, not assumed from local state).
  --dry-run             Generate + show the payload; do NOT store the key or register.
  -h, --help            Show this help.

CREDENTIALS (XACA-0398-004 — two tiers):
  Registration/rotation (POST/PUT /api/vault/machines) is an ADMIN-tier call.
  Supply the credential via the FLEET_ADMIN_TOKEN environment variable, or —
  only when stdin is a real interactive TTY — this tool prompts for it (input
  is never echoed). It is NEVER written to disk. If neither is available (for
  example an unattended install/upgrade, which closes stdin), the key is still
  generated and stored, but registration is skipped and this exits with the
  ENROLLMENT PENDING code below — an operator finishes it later with
  --register-only.
  The admin credential is only ever sent to an https:// URL, or to plain http
  on a loopback host (localhost, 127.0.0.0/8, ::1). Any other http URL is
  refused before anything is sent (XACA-0398-015).

EXIT CODES:
  0  success (registered, or --dry-run / --help)
  1  registration failed (validation error, or the server rejected it) — see
     the printed HTTP status; also returned on an unexpected top-level error
  2  usage error (bad argument)
  3  ENROLLMENT PENDING — the key was generated/stored (or already existed)
     but could NOT be registered because no admin credential was available.
     This is NOT a failure of key generation; it means the machine needs an
     operator to run --register-only with FLEET_ADMIN_TOKEN set.
  4  --rotate / --resume-rotation refused. NOTHING was written or sent; the
     existing key is unchanged. Either no admin credential was available, or
     (--rotate only, XACA-0398-021) a previous rotation's staged key still
     exists and might be the only key matching the server - finish it with
     --resume-rotation. (Rotation never stores the new key until the server
     has accepted its public key, so it has no pending state.)

The private key is stored in the macOS Keychain (service com.aiteamforge.vault,
account = machine id) when available, otherwise in ~/.aiteamforge/vault/<slug>.key
(mode 0600). It is NEVER printed and NEVER sent to the server.`;

// XACA-0398-004: the ENROLLMENT PENDING exit code. Distinct from 0 (success),
// 1 (a real failure — validation or a rejected registration) and 2 (usage
// error) so a caller (kb-msg-provision, an operator's own script) can tell
// "the key exists and is fine, only registration is outstanding" apart from
// an actual error without parsing stdout. kb-msg-provision mirrors this
// literal value in its own VAULT_KEYGEN_EXIT_ENROLLMENT_PENDING constant —
// there is no way to import a JS constant into that Python file, so keep the
// two literal 3's in sync if this ever changes.
const EXIT_ENROLLMENT_PENDING = 3;

// XACA-0398-014: --rotate refused BEFORE anything was written, because no
// admin credential was available. Distinct from 3: pending means "a key was
// stored and awaits registration"; this means "nothing changed at all".
// XACA-0398-021 reuses it for "a staging slot already exists" (same contract:
// refused, nothing written, nothing sent); stderr names which cause it was.
const EXIT_ROTATE_REFUSED = 4;

// -----------------------------------------------------------------------------
// Top-level error sanitization (XACA-1224-002)
// -----------------------------------------------------------------------------
//
// keychainAddPassword already never puts the private key on argv and always
// throws its own fixed-message, `.sanitized = true` Error on failure (see its
// doc comment above) — that is the primary fix. This is defense-in-depth for
// main()'s own top-level catch: if some OTHER error ever reaches here that
// looks like a raw Node child_process failure (execFileSync/execSync/spawnSync
// throw shape — Node builds `.message` by joining the full argv, per the
// child_process docs), refuse to print it verbatim rather than trust that
// every call site upstream remembered to sanitize.

/**
 * True when `err` has the shape Node's execFileSync/execSync/spawnSync give a
 * failed-child-process Error: a `.cmd` string plus a numeric `.status` or a
 * `.signal` string. Such an error's `.message` is built from the full argv.
 * @param {*} err
 * @returns {boolean}
 */
function looksLikeChildProcessError(err) {
    return !!err && typeof err === 'object' &&
        typeof err.cmd === 'string' &&
        (typeof err.status === 'number' || typeof err.signal === 'string');
}

/**
 * The message to print for a top-level CLI failure. Passes through any error
 * we already sanitized ourselves (`.sanitized === true`, e.g. from
 * keychainAddPassword) or any ordinary validation/logic Error unchanged. Any
 * error that LOOKS like a raw child_process failure but was NOT already
 * sanitized is replaced with a generic, argv-free message instead of being
 * printed verbatim — a last-resort backstop, not the primary defense.
 * @param {*} err
 * @returns {string}
 */
function safeErrorMessage(err) {
    if (err && err.sanitized === true) return err.message;
    if (looksLikeChildProcessError(err)) {
        const statusText = err.status !== undefined && err.status !== null ? err.status : (err.signal || 'unknown');
        return `A system command failed (exit ${statusText}). Details withheld: ` +
               `a failed command's default error text can include sensitive arguments.`;
    }
    return (err && err.message) || String(err);
}

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
    if (opts.resumeRotation && (opts.rotate || opts.force || opts.registerOnly)) {
        process.stderr.write('--resume-rotation cannot be combined with --rotate, --force or --register-only.\n\n' + HELP + '\n');
        return 2;
    }

    try {
        const result = opts.resumeRotation
            ? await resumeRotation({
                ...opts,
                log: (m) => process.stdout.write(m + '\n'),
            })
            : opts.registerOnly
            ? await registerOnly({
                ...opts,
                log: (m) => process.stdout.write(m + '\n'),
            })
            : await provisionMachine({
                ...opts,
                log: (m) => process.stdout.write(m + '\n'),
            });
        // Echo the public key + payload (safe — public). NEVER the private key.
        process.stdout.write('\nRegistration payload (public data only):\n');
        process.stdout.write(JSON.stringify(result.payload, null, 2) + '\n');
        if (result.pending) {
            return EXIT_ENROLLMENT_PENDING;
        }
        if (result.registration && result.registration.status >= 400) {
            return 1;
        }
        process.stdout.write('\nDone. You\'re welcome.\n');
        return 0;
    } catch (err) {
        process.stderr.write('Error: ' + safeErrorMessage(err) + '\n');
        if (err && (err.code === 'ROTATE_ADMIN_REQUIRED' || err.code === 'ROTATE_STAGING_EXISTS')) {
            return EXIT_ROTATE_REFUSED;
        }
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
    X25519_KEY_BYTES,
    vaultDir, // XACA-0398-004: was the frozen VAULT_DIR constant; now a function — see its own comment
    // fleet URL resolution (shared with vault-fetch.js / vault-migrate-env-keys.js)
    fleetConfigPath,
    fleetConfigCandidates,
    validateFleetUrl,
    acceptFleetUrl,
    lastFleetUrlRejection,
    resolveFleetUrl,
    unresolvedFleetUrlMessage,
    fleetFetchInit,
    assertNoRedirect,
    // two-tier bearer-token resolution (XACA-0398-004)
    resolveFleetAuthToken,
    resolveFleetAdminToken,
    fleetAuthHeaders,
    readHiddenLine,
    isLoopbackHost,
    adminTransportCheck,
    assertAdminTransport,
    EXIT_ENROLLMENT_PENDING,
    EXIT_ROTATE_REFUSED,
    // slug/label
    defaultMachineSlug,
    validateSlug,
    validateLabel,
    // crypto
    ensureSodium,
    generateKeypair,
    derivePublicKeyFromPrivate,
    // storage
    chooseKeyStorageBackend,
    securityCliAvailable,
    fallbackKeyPath,
    stagingSlug,
    removeStagedKey,
    privateKeyExists,
    persistPrivateKey,
    readPrivateKey,
    keychainAddPassword,
    classifyKeychainFailure,
    // registration
    buildRegistrationPayload,
    registerMachine,
    isMachineRegistered,
    provisionMachine,
    rotateMachineKey,
    resumeRotation,
    registerOnly,
    // cli
    parseArgs,
    main,
    safeErrorMessage,
    looksLikeChildProcessError,
};
