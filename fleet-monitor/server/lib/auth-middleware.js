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
 *   safeEqual(a, b)          -> constant-time credential equality (exported
 *                                for its own unit test, contract §5).
 *   logAuthStartupNotice()   -> logs the one required startup posture line
 *                                (contract §7 — "never silently open"), plus
 *                                a distinct CONFIG ERROR line for the BLANK
 *                                state. Intended to be called ONCE by
 *                                server.js at process startup — mirrors
 *                                lcars-ui/server.py's resolve_api_key_or_die()
 *                                minus the FLEET_REQUIRE_AUTH abort path,
 *                                which is not implemented anywhere in
 *                                fleet-monitor yet (see note below) and is
 *                                deliberately not added here.
 *
 * FLEET_REQUIRE_AUTH (contract §7 "path to fail-closed"): grep confirms this
 * switch does not exist anywhere in fleet-monitor today — no refuse-to-start
 * path exists to preserve or extend. Wiring it (mirroring LCARS's
 * AITEAMFORGE_REQUIRE_AUTH / resolve_api_key_or_die()) is out of this
 * module's scope: it requires a call site at actual process startup, which
 * lives in server.js. Out of scope for this file/subitem.
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
 * Resolve FLEET_AUTH_TOKEN into { state, key }. Read fresh on every call —
 * deliberately NOT cached at module load (unlike LCARS's file-backed
 * resolution, contract §2's caching rationale doesn't apply here: there is
 * no file to re-read, just an env var lookup, and per-call reads are what
 * let tests flip FLEET_AUTH_TOKEN between cases against one required()
 * module instance).
 *
 * ABSENT and BLANK both yield key: null (open posture, contract §7,
 * unchanged) — the distinction exists purely so callers (isAuthorized via
 * getExpectedToken, and logAuthStartupNotice) can tell "nobody configured a
 * key" apart from "someone tried to and produced nothing," without ever
 * inspecting or logging the actual value.
 */
function resolveKeyState() {
    const raw = process.env.FLEET_AUTH_TOKEN;
    if (typeof raw !== 'string') {
        return { state: KEY_STATE_ABSENT, key: null };
    }
    const stripped = stripAsciiWhitespace(raw);
    if (stripped.length === 0) {
        return { state: KEY_STATE_BLANK, key: null };
    }
    return { state: KEY_STATE_SET, key: stripped };
}

/** Resolve the expected key from FLEET_AUTH_TOKEN, or null (open posture)
 *  for either the ABSENT or BLANK state — see resolveKeyState() above. */
function getExpectedToken() {
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

// ---------------------------------------------------------------------------
// Core predicate — the single implementation
// ---------------------------------------------------------------------------

/**
 * isAuthorized(req) -> boolean
 *
 * The single implementation. No res, no side effects — safe to call from a
 * guard, from middleware, or from a plain function. Implements contract §3
 * (header parsing + both-headers-present rules) and §7 (open-when-unset).
 */
function isAuthorized(req) {
    const expected = getExpectedToken();
    if (!expected) return true; // §7 — open posture when no server token configured

    const bearerRaw = extractBearerCredential(req);
    const apiKeyRaw = extractApiKeyCredential(req);
    const bearer = hasValidShape(bearerRaw) ? bearerRaw : null;
    const apiKey = hasValidShape(apiKeyRaw) ? apiKeyRaw : null;

    let credential;
    if (bearer && apiKey) {
        // §3.4 — both present. Equal: use it. Differ: 401, do not try either
        // individually. The agreement check itself MUST be constant-time —
        // comparing with `===` would reintroduce the oracle on this path.
        if (!safeEqual(bearer, apiKey)) return false;
        credential = bearer;
    } else if (bearer) {
        credential = bearer;
    } else if (apiKey) {
        credential = apiKey;
    } else {
        return false; // neither yielded a valid-shape credential
    }

    return safeEqual(credential, expected);
}

// ---------------------------------------------------------------------------
// 401 emission — byte-identical across every rejection reason (contract §4)
// ---------------------------------------------------------------------------

function sendUnauthorized(res) {
    res.status(401)
        .set('WWW-Authenticate', 'Bearer')
        .set('Access-Control-Allow-Origin', '*')
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
 * Log the single required startup posture line. Intended to be called ONCE
 * by server.js at process startup (not wired here — that call site is out of
 * this module's scope; see the module doc comment). Never logs the key, its
 * length, or any prefix of it — the three messages below are the entire log
 * surface.
 *
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
 *
 * @param {{log: Function, warn: Function}} [logger] injectable for tests;
 *   defaults to the real console.
 * @returns {'absent'|'blank'|'set'} the resolved state, for callers/tests
 *   that want to assert on it without re-deriving it.
 */
function logAuthStartupNotice(logger = console) {
    const { state } = resolveKeyState();

    if (state === KEY_STATE_SET) {
        logger.log('[fleet-monitor] AUTH: gate ACTIVE');
        return state;
    }

    if (state === KEY_STATE_BLANK) {
        logger.warn(
            '[fleet-monitor] AUTH CONFIG ERROR: FLEET_AUTH_TOKEN is set but blank ' +
            '(empty or whitespace-only) and is being IGNORED. The gate is OPEN — ' +
            'state-mutating routes are UNAUTHENTICATED. This is usually a deploy ' +
            'template or secret substitution producing an empty value, not an ' +
            'intentional choice. Set FLEET_AUTH_TOKEN to a real credential, or ' +
            'unset it entirely if the open posture is intended.'
        );
        return state;
    }

    logger.warn('[fleet-monitor] AUTH: gate OPEN — no API key configured; state-mutating routes are UNAUTHENTICATED');
    return state;
}

module.exports = {
    isAuthorized,
    requireApiKey,
    checkApiKey,
    safeEqual,
    logAuthStartupNotice,
};
