//
//  auth-middleware.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Shared API-key auth gate for fleet-monitor (XACA-0395-004).
 *
 * Implements the auth contract at
 * kanban/plans/XACA-0395/XACA-0395_auth_contract.md exactly — that document is
 * normative; this file must not deviate from it without a contract update.
 *
 * TWO TIERS (XACA-0398-003, contract §3.6 + §7 "Tiers"):
 *   fleet tier -> FLEET_AUTH_TOKEN. Machine-to-machine routes (reporters,
 *                 kanban-helpers.sh, msg-client.js). Header credentials only.
 *                 Accepts the fleet key OR the admin key (admin is a superset).
 *   admin tier -> FLEET_ADMIN_TOKEN. Operator routes (vault writes, machine
 *                 registration, engines, credentials, dashboards, epics,
 *                 nickname). Accepts a header equal to the admin-tier expected
 *                 key, OR the lib/admin-session.js cookie when every CSRF rule
 *                 holds. While FLEET_ADMIN_TOKEN is unset, the admin-tier
 *                 expected key falls back to FLEET_AUTH_TOKEN (staging
 *                 posture; startup logs a WARN).
 *   Both tiers are OPEN only when NEITHER key is set, so there is no
 *   configuration where one tier is open and the other closed.
 *
 * SECRET: `FLEET_AUTH_TOKEN` (env var only — no file. The Fly.io instance gets
 * it from Fly secrets). This is a DIFFERENT secret than LCARS's
 * `AITEAMFORGE_API_KEY` (contract §1) — do not read AITEAMFORGE_API_KEY here,
 * and do not let this module's key leak into LCARS.
 *
 * POSTURE (contract §7): no key resolves -> the gate is OPEN and every
 * request proceeds. A key resolves -> the gate is CLOSED and every gated
 * request must present a matching credential or get the §4 401.
 *
 * THREE key states, not two (XACA-0395-004 correction): FLEET_AUTH_TOKEN can
 * be ABSENT (never set — matches msg-relay's pre-existing
 * `if (!expected) return true;` behavior, unchanged), BLANK (set to the empty
 * string or ASCII-whitespace-only — a *configuration error*, e.g. a deploy
 * template or secret substitution that produced nothing), or SET (a real
 * value — gated). ABSENT and BLANK both resolve to the SAME open posture —
 * that is deliberate and unchanged by this correction (see resolveKeyState()
 * below) — but they are NOT the same event and must not be logged as if they
 * were: fleet-monitor is env-var-only with no file fallback (contract §2 —
 * unlike LCARS's ~/.aiteamforge/api-key), so a blank env var here is the
 * ENTIRE resolution chain coming up empty on an internet-facing instance, and
 * it deserves a louder, distinct startup warning than "nobody configured a
 * key yet." logAuthStartupNotice() below emits that distinct line without
 * ever including the value, its length, or any prefix of it.
 *
 * SHAPE (contract §9): the pre-existing `requireBearer` in msg-relay-routes.js
 * is a boolean GUARD (`if (!requireBearer(req, res)) return;`), not Express
 * middleware, and it gates a GET (`GET /api/msg`, returns sealed envelopes —
 * fails the public-route allowlist's R2). A middleware-only shared module
 * would force that GET's handler to be reshaped, or tempt an "apply to
 * mutating verbs only" sweep that silently drops its gate — the highest-risk
 * regression in this ticket (plan D2a). So this module exports THREE things
 * that all defer to one predicate:
 *
 *   isAuthorized(req)        -> boolean. The single implementation. No res,
 *                                no side effects, safe to call from anywhere.
 *   requireApiKey(req,res,next) -> Express middleware:
 *                                app.post(path, requireApiKey, handler)
 *   checkApiKey(req, res)    -> boolean. Guard form, drop-in replacement for
 *                                the old requireBearer(req, res).
 *   isAdminAuthorized / requireAdminKey / checkAdminKey -> the same three
 *                                shapes for the ADMIN tier (XACA-0398).
 *   getAuthPosture()         -> { fleet, admin } key states (never values).
 *   getAdminExpectedKey()    -> admin-tier key for lib/auth-routes.js only.
 *   safeEqual(a, b)          -> constant-time credential equality (exported
 *                                for its own unit test, contract §5).
 *   logAuthStartupNotice()   -> logs the one required startup posture line
 *                                (contract §7 — "never silently open"), plus
 *                                a distinct CONFIG ERROR line for the BLANK
 *                                state. Called ONCE by server.js at process
 *                                startup — mirrors lcars-ui/server.py's
 *                                resolve_api_key_or_die() minus the
 *                                FLEET_REQUIRE_AUTH abort path itself: that
 *                                path IS implemented (XACA-0395-005), but it
 *                                lives in server.js, immediately after this
 *                                function's call site, not inside this
 *                                function or this module (see below).
 *
 * FLEET_REQUIRE_AUTH (contract §7 "path to fail-closed"): IS implemented —
 * server.js's "AUTH GATE STARTUP NOTICE" block calls logAuthStartupNotice()
 * above, then checks FLEET_REQUIRE_AUTH itself: if it is "1" and the
 * resolved key state of EITHER tier is not 'set' (XACA-0398 user decision:
 * the switch also requires FLEET_ADMIN_TOKEN), it logs a FATAL message and calls
 * process.exit(1) before app.listen() runs, refusing to start rather than
 * serve state-mutating routes unauthenticated. This mirrors LCARS's
 * AITEAMFORGE_REQUIRE_AUTH / resolve_api_key_or_die(). This module
 * deliberately does NOT implement that check itself: the call site is
 * process startup, which lives in server.js, not here.
 *
 * COMPARISON (contract §5): both credential values are SHA-256 hashed first,
 * then compared with crypto.timingSafeEqual on the two (unconditionally
 * 32-byte) digests. Do NOT add an early `a.length !== b.length` fast path
 * (leaks the secret's length via timing) and do NOT wrap timingSafeEqual in a
 * bare try/catch (its catch is reachable ONLY on a length mismatch, so the
 * throw IS the length oracle). Hashing first makes both digests always equal
 * length, so timingSafeEqual can never throw here.
 *
 * LOGGING: the resolved key is never an argument to a log/print call, an
 * exception, or a response body anywhere in this module (contract §8, L1/L3).
 * The 401 body is byte-identical across every rejection reason — absent,
 * malformed, wrong, or disagreeing-duplicate-headers all produce the same
 * bytes (contract §4/L2).
 */

const crypto = require('crypto');
const adminSession = require('./admin-session');

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

// Contract §4 — byte-exact, compact separators, this key order, no trailing
// newline. Do not vary this body by rejection reason (that is the leak the
// contract forbids).
const UNAUTHORIZED_BODY = { error: 'Unauthorized', code: 'unauthorized' };

// Contract §3.3 — applied to whichever credential was extracted, after
// stripping. Closes the empty-credential, Node duplicate-header
// (`Bearer a, Bearer b` contains a comma), and header-smuggling cases at once.
const CREDENTIAL_SHAPE_RE = /^[A-Za-z0-9._~+/=-]{16,512}$/;

// Contract §3.1 — scheme is case-insensitive; at least one space/tab required
// between the scheme and the credential.
const BEARER_RE = /^[Bb][Ee][Aa][Rr][Ee][Rr][ \t]+(.+)$/;

// ASCII whitespace only (contract §2/§3) — deliberately narrower than
// String.prototype.trim(), which also strips non-ASCII Unicode whitespace.
const ASCII_WS_RE = /^[ \t\n\r\f\v]+|[ \t\n\r\f\v]+$/g;

function stripAsciiWhitespace(value) {
    return String(value).replace(ASCII_WS_RE, '');
}

// ---------------------------------------------------------------------------
// Constant-time comparison (contract §5) — mandatory, prescribed exactly.
// ---------------------------------------------------------------------------

/**
 * Constant-time credential equality. Never throws, never leaks length.
 * Hashes both sides to a fixed 32-byte SHA-256 digest before comparing, so
 * crypto.timingSafeEqual (which throws on length mismatch) can never observe
 * a length difference between the two original inputs.
 */
function safeEqual(presented, expected) {
    const a = crypto.createHash('sha256').update(String(presented), 'utf8').digest();
    const b = crypto.createHash('sha256').update(String(expected), 'utf8').digest();
    return crypto.timingSafeEqual(a, b);
}

// ---------------------------------------------------------------------------
// Expected key resolution — three states (XACA-0395-004 correction)
// ---------------------------------------------------------------------------

const KEY_STATE_ABSENT = 'absent'; // FLEET_AUTH_TOKEN never set
const KEY_STATE_BLANK  = 'blank';  // set, but empty/ASCII-whitespace-only — a config error
const KEY_STATE_SET    = 'set';    // set to a real value

/**
 * Resolve one env var into { state, key }. Read fresh on every call —
 * deliberately NOT cached at module load (unlike LCARS's file-backed
 * resolution, contract §2's caching rationale doesn't apply here: there is
 * no file to re-read, just an env var lookup, and per-call reads are what
 * let tests flip the env between cases against one required() module
 * instance).
 *
 * ABSENT and BLANK both yield key: null — the distinction exists purely so
 * logAuthStartupNotice() can tell "nobody configured a key" apart from
 * "someone tried to and produced nothing," without ever inspecting or
 * logging the actual value.
 */
function resolveEnvKeyState(envName) {
    const raw = process.env[envName];
    if (typeof raw !== 'string') {
        return { state: KEY_STATE_ABSENT, key: null };
    }
    const stripped = stripAsciiWhitespace(raw);
    if (stripped.length === 0) {
        return { state: KEY_STATE_BLANK, key: null };
    }
    return { state: KEY_STATE_SET, key: stripped };
}

/** FLEET_AUTH_TOKEN (fleet tier). */
function resolveKeyState() {
    return resolveEnvKeyState('FLEET_AUTH_TOKEN');
}

/** FLEET_ADMIN_TOKEN (admin tier, XACA-0398). */
function resolveAdminKeyState() {
    return resolveEnvKeyState('FLEET_ADMIN_TOKEN');
}

/**
 * Per-tier key states, for server.js's FLEET_REQUIRE_AUTH block and tests.
 * States only — never a key value.
 * @returns {{ fleet: 'absent'|'blank'|'set', admin: 'absent'|'blank'|'set' }}
 */
function getAuthPosture() {
    return { fleet: resolveKeyState().state, admin: resolveAdminKeyState().state };
}

/**
 * The admin-tier expected key: FLEET_ADMIN_TOKEN if set, else the
 * FLEET_AUTH_TOKEN staging fallback, else null (open posture). Exported for
 * lib/auth-routes.js (login + cookie issue); never logged.
 */
function getAdminExpectedKey() {
    const admin = resolveAdminKeyState().key;
    if (admin) return admin;
    return resolveKeyState().key;
}

// ---------------------------------------------------------------------------
// Header extraction (contract §3)
// ---------------------------------------------------------------------------

function getHeader(req, name) {
    return req.get ? req.get(name) : (req.headers && req.headers[name.toLowerCase()]);
}

/**
 * Extract the Bearer credential from Authorization, or null if the header is
 * absent, or present with a non-Bearer scheme (contract §3.1: fall through to
 * X-API-Key rather than 401 immediately — a proxy-injected Basic header must
 * not break an X-API-Key caller).
 */
function extractBearerCredential(req) {
    const header = getHeader(req, 'authorization');
    if (!header) return null;
    const match = BEARER_RE.exec(String(header));
    if (!match) return null;
    return stripAsciiWhitespace(match[1]);
}

/** Extract the X-API-Key credential verbatim (no scheme prefix), or null. */
function extractApiKeyCredential(req) {
    const header = getHeader(req, 'x-api-key');
    if (!header) return null;
    return stripAsciiWhitespace(header);
}

function hasValidShape(credential) {
    return typeof credential === 'string' && CREDENTIAL_SHAPE_RE.test(credential);
}

/**
 * Apply contract §3.3/§3.4 to the two headers.
 * @returns {{ status: 'none'|'conflict'|'present', credential: string|null }}
 *   none     -> neither header yielded a valid-shape credential
 *   conflict -> both did, and they differ (always a rejection, §3.4)
 *   present  -> exactly one usable credential
 */
function extractHeaderCredential(req) {
    const bearerRaw = extractBearerCredential(req);
    const apiKeyRaw = extractApiKeyCredential(req);
    const bearer = hasValidShape(bearerRaw) ? bearerRaw : null;
    const apiKey = hasValidShape(apiKeyRaw) ? apiKeyRaw : null;

    if (bearer && apiKey) {
        // §3.4 — both present. Equal: use it. Differ: reject, do not try
        // either individually. The agreement check itself MUST be
        // constant-time — `===` would reintroduce the oracle on this path.
        if (!safeEqual(bearer, apiKey)) return { status: 'conflict', credential: null };
        return { status: 'present', credential: bearer };
    }
    if (bearer) return { status: 'present', credential: bearer };
    if (apiKey) return { status: 'present', credential: apiKey };
    return { status: 'none', credential: null };
}

// ---------------------------------------------------------------------------
// Core predicates — one per tier
// ---------------------------------------------------------------------------

/**
 * isAuthorized(req) -> boolean — the FLEET tier.
 *
 * No res, no side effects — safe to call from a guard, from middleware, or
 * from a plain function. Implements contract §3.1-§3.4 and §7. Accepts a
 * header credential equal to the fleet key OR the admin key (admin is a
 * superset). NEVER accepts the session cookie: no browser page calls a
 * fleet-tier route, so the cookie stays least-privilege.
 */
function isAuthorized(req) {
    const fleetKey = resolveKeyState().key;
    const adminKey = resolveAdminKeyState().key;
    if (!fleetKey && !adminKey) return true; // §7 — open only when neither tier has a key

    const { status, credential } = extractHeaderCredential(req);
    if (status !== 'present') return false;

    // Evaluate both comparisons unconditionally (no short-circuit), so which
    // key matched is not visible in timing.
    const fleetOk = fleetKey ? safeEqual(credential, fleetKey) : false;
    const adminOk = adminKey ? safeEqual(credential, adminKey) : false;
    return fleetOk || adminOk;
}

/**
 * isAdminAuthorized(req) -> boolean — the ADMIN tier (XACA-0398).
 *
 * Expected key: getAdminExpectedKey() (FLEET_ADMIN_TOKEN, else the
 * FLEET_AUTH_TOKEN staging fallback). Open only when neither key is set.
 *
 * Credential sources, in precedence order (contract §3.6):
 *   1. A valid-shape header credential. If one is presented, the decision is
 *      made on it alone — a wrong header 401s even alongside a good cookie.
 *   2. Otherwise the __Host-fleet_admin session cookie, accepted only when
 *      every request-side CSRF rule holds (X-Fleet-CSRF: 1, Origin host ==
 *      Host exactly, Sec-Fetch-Site same-origin when present). A CSRF
 *      failure is "no credential presented", i.e. the byte-identical 401.
 */
function isAdminAuthorized(req) {
    const expected = getAdminExpectedKey();
    if (!expected) return true; // §7 — open only when neither tier has a key

    const { status, credential } = extractHeaderCredential(req);
    if (status === 'conflict') return false;
    if (status === 'present') return safeEqual(credential, expected);

    const cookie = adminSession.readSessionCookie(req);
    if (!cookie) return false;
    if (!adminSession.passesCsrfChecks(req)) return false;
    return adminSession.verifySession(cookie, expected).valid;
}

// ---------------------------------------------------------------------------
// 401 emission — byte-identical across every rejection reason (contract §4)
// ---------------------------------------------------------------------------

function sendUnauthorized(res) {
    // XACA-0401 (test finding 014): the unconditional
    // `.set('Access-Control-Allow-Origin', '*')` that used to be here has been
    // REMOVED. It was pre-existing (XACA-0395), but it overrode the
    // fail-closed `origin` decision the cors() middleware in server.js makes
    // for every other response — so every 401 from a requireApiKey-gated
    // route still handed a literal wildcard to any origin that asked,
    // regardless. A wildcard on the auth-REJECTED path is the last place it
    // belongs.
    //
    // Nothing replaces it deliberately: cors() runs BEFORE the route handlers
    // and has already applied the correct per-origin decision (including
    // `Vary: Origin`, which the cors package emits automatically for a
    // function-valued origin) by the time this runs. Setting anything here
    // would override that decision a second time, which is the defect.
    //
    // The 401 BODY is untouched — contract §4 requires it byte-identical
    // across every rejection reason, and that is unaffected by header changes.
    res.status(401)
        .set('WWW-Authenticate', 'Bearer')
        .json(UNAUTHORIZED_BODY);
}

// ---------------------------------------------------------------------------
// Adapters
// ---------------------------------------------------------------------------

/** Express middleware form: app.post(path, requireApiKey, handler) */
function requireApiKey(req, res, next) {
    if (isAuthorized(req)) return next();
    sendUnauthorized(res);
}

/** Express middleware form, ADMIN tier: app.post(path, requireAdminKey, handler) */
function requireAdminKey(req, res, next) {
    if (isAdminAuthorized(req)) return next();
    sendUnauthorized(res);
}

/** Guard form, ADMIN tier. Same shape as checkApiKey. */
function checkAdminKey(req, res) {
    if (isAdminAuthorized(req)) return true;
    sendUnauthorized(res);
    return false;
}

/**
 * Guard form — drop-in replacement for msg-relay-routes.js's old
 * requireBearer(req, res). Returns true if authorized; otherwise writes the
 * 401 and returns false. Callers gate with `if (!checkApiKey(req, res)) return;`
 */
function checkApiKey(req, res) {
    if (isAuthorized(req)) return true;
    sendUnauthorized(res);
    return false;
}

// ---------------------------------------------------------------------------
// Startup notice (contract §7 — "never silently open")
// ---------------------------------------------------------------------------

/**
 * Log the required startup posture: exactly ONE line per tier (XACA-0398),
 * fleet tier first, then admin tier. Intended to be called ONCE by server.js
 * at process startup. Never logs a key, its length, or any prefix of it —
 * the messages below are the entire log surface.
 *
 * Fleet-tier line (unchanged from XACA-0395 except the admin-only case):
 * - SET    -> "AUTH: gate ACTIVE" (contract §7, exact wording, no extras).
 * - ABSENT -> the exact contract §7 open-posture line — matches LCARS's
 *             equivalent "no API key configured" message.
 * - BLANK  -> a DISTINCT, louder CONFIG ERROR line. This is the case this
 *             correction exists for: FLEET_AUTH_TOKEN was set by something
 *             (a deploy template, a secret substitution) but resolved to
 *             nothing, and on an env-only server with no file fallback that
 *             silently opens the gate fleet-wide. Says only that the
 *             variable was set-but-blank and is being ignored — nothing
 *             about what it contained.
 * - fleet not set but FLEET_ADMIN_TOKEN set -> a WARN that the gate is
 *             active with the admin key only (reporters cannot authenticate).
 *
 * Admin-tier line (contract §7 "Tiers"):
 * - FLEET_ADMIN_TOKEN set          -> "AUTH ADMIN: gate ACTIVE" via log().
 * - unset/blank, fleet key set     -> WARN "AUTH ADMIN: sharing fleet token".
 * - blank, no fleet key            -> WARN AUTH ADMIN CONFIG ERROR, gate OPEN.
 * - neither key                    -> WARN "AUTH ADMIN: gate OPEN".
 *
 * @param {{log: Function, warn: Function}} [logger] injectable for tests;
 *   defaults to the real console.
 * @returns {'absent'|'blank'|'set'} the FLEET-tier state (unchanged return
 *   contract). Use getAuthPosture() for both tiers.
 */
function logAuthStartupNotice(logger = console) {
    const fleet = resolveKeyState().state;
    const admin = resolveAdminKeyState().state;

    // ---- Fleet tier: exactly one line ----
    if (fleet === KEY_STATE_SET) {
        logger.log('[fleet-monitor] AUTH: gate ACTIVE');
    } else if (admin === KEY_STATE_SET) {
        // The fleet tier is CLOSED (it accepts the admin key), but no fleet
        // key exists, so reporters holding only a fleet token will 401.
        logger.warn(
            '[fleet-monitor] AUTH: gate ACTIVE with the admin token only — ' +
            'FLEET_AUTH_TOKEN is ' + (fleet === KEY_STATE_BLANK ? 'set but blank (CONFIG ERROR)' : 'unset') +
            ', so fleet reporters cannot authenticate.'
        );
    } else if (fleet === KEY_STATE_BLANK) {
        logger.warn(
            '[fleet-monitor] AUTH CONFIG ERROR: FLEET_AUTH_TOKEN is set but blank ' +
            '(empty or whitespace-only) and is being IGNORED. The gate is OPEN — ' +
            'state-mutating routes are UNAUTHENTICATED. This is usually a deploy ' +
            'template or secret substitution producing an empty value, not an ' +
            'intentional choice. Set FLEET_AUTH_TOKEN to a real credential, or ' +
            'unset it entirely if the open posture is intended.'
        );
    } else {
        logger.warn('[fleet-monitor] AUTH: gate OPEN — no API key configured; state-mutating routes are UNAUTHENTICATED');
    }

    // ---- Admin tier: exactly one line (XACA-0398) ----
    if (admin === KEY_STATE_SET) {
        logger.log('[fleet-monitor] AUTH ADMIN: gate ACTIVE');
    } else if (fleet === KEY_STATE_SET) {
        logger.warn(
            '[fleet-monitor] AUTH ADMIN: sharing fleet token — FLEET_ADMIN_TOKEN is ' +
            (admin === KEY_STATE_BLANK ? 'set but blank (CONFIG ERROR, ignored)' : 'unset') +
            ', so admin routes accept FLEET_AUTH_TOKEN. Any machine holding the fleet ' +
            'token can perform admin actions. Staging posture only; set FLEET_ADMIN_TOKEN.'
        );
    } else if (admin === KEY_STATE_BLANK) {
        logger.warn(
            '[fleet-monitor] AUTH ADMIN CONFIG ERROR: FLEET_ADMIN_TOKEN is set but blank ' +
            'and is being IGNORED. The admin gate is OPEN — admin routes are UNAUTHENTICATED.'
        );
    } else {
        logger.warn('[fleet-monitor] AUTH ADMIN: gate OPEN — no admin or fleet key configured; admin routes are UNAUTHENTICATED');
    }

    return fleet;
}

module.exports = {
    isAuthorized,
    requireApiKey,
    checkApiKey,
    isAdminAuthorized,
    requireAdminKey,
    checkAdminKey,
    getAuthPosture,
    getAdminExpectedKey,
    safeEqual,
    logAuthStartupNotice,
};
