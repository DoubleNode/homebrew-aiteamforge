//
//  admin-session.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Stateless admin session cookie for fleet-monitor (XACA-0398-003).
 *
 * Normative spec: kanban/plans/XACA-0395/XACA-0395_auth_contract.md §3.6
 * (XACA-0398 amendment). Design: kanban/plans/XACA-0398/
 * XACA-0398_credential_design.md §2.1 "Mechanism E".
 *
 * WHY STATELESS: fleet-monitor runs on Fly and restarts on every deploy. A
 * session store would log every operator out on restart and would not work
 * across machines. The cookie carries its own expiry and an HMAC over it.
 *
 * WHY NO SIGNING SECRET OF ITS OWN: the MAC key is derived from the admin-tier
 * expected key (HMAC-SHA256(adminKey, SESSION_KEY_LABEL)). Rotating the admin
 * token therefore revokes every outstanding session, with nothing extra to
 * provision or rotate. The first time FLEET_ADMIN_TOKEN is set, sessions that
 * were issued while the admin tier shared FLEET_AUTH_TOKEN stop verifying.
 * That is intended.
 *
 * PURITY: every function here takes the key as an argument. This module never
 * reads process.env and never requires auth-middleware.js (which requires this
 * module), so there is no require cycle and tests can drive it directly.
 *
 * LOGGING: nothing in this module logs. Neither the key, the session key, nor
 * a cookie value is ever placed in an exception message.
 *
 * GOTCHA (local HTTP): the `__Host-` prefix requires `Secure`. A browser on
 * plain HTTP to a non-localhost address will silently refuse to store the
 * cookie. That only matters on a CLOSED gate, and a closed gate is only
 * expected on the TLS-terminated Fly instance. Local fleet-monitors run open.
 */

const crypto = require('crypto');

const COOKIE_NAME = '__Host-fleet_admin';
const SESSION_VERSION = 'v1';
const SESSION_TTL_SECONDS = 8 * 60 * 60; // 8 h — user decision, XACA-0398
const CLOCK_SKEW_SECONDS = 60;
const SESSION_KEY_LABEL = 'fleet-monitor/admin-session/v1';
const NONCE_BYTES = 16;
const MAC_BYTES = 32;

// Cookie headers larger than this are not parsed at all (defence against a
// pathological header; real browsers send a few hundred bytes here).
const MAX_COOKIE_HEADER_LENGTH = 8192;

const B64URL_RE = /^[A-Za-z0-9_-]+$/;
const EXP_RE = /^[0-9]{1,12}$/;

function b64url(buf) {
    return Buffer.from(buf).toString('base64')
        .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function fromB64url(str) {
    if (typeof str !== 'string' || !B64URL_RE.test(str)) return null;
    const pad = str.length % 4 === 0 ? '' : '='.repeat(4 - (str.length % 4));
    return Buffer.from(str.replace(/-/g, '+').replace(/_/g, '/') + pad, 'base64');
}

/** HMAC-SHA256(adminKey, label). Never returned to a caller outside this module. */
function deriveSessionKey(adminKey) {
    return crypto.createHmac('sha256', String(adminKey)).update(SESSION_KEY_LABEL, 'utf8').digest();
}

function computeMac(adminKey, exp, nonce) {
    return crypto.createHmac('sha256', deriveSessionKey(adminKey))
        .update(`${SESSION_VERSION}.${exp}.${nonce}`, 'utf8')
        .digest();
}

function nowSeconds(nowMs) {
    return Math.floor((typeof nowMs === 'number' ? nowMs : Date.now()) / 1000);
}

/**
 * Issue a new session value for adminKey.
 * @returns {{ value: string, expiresAtMs: number, maxAgeSeconds: number }}
 */
function issueSession(adminKey, { nowMs } = {}) {
    if (!adminKey) throw new Error('issueSession: no admin-tier key resolved');
    const exp = nowSeconds(nowMs) + SESSION_TTL_SECONDS;
    const nonce = b64url(crypto.randomBytes(NONCE_BYTES));
    const mac = b64url(computeMac(adminKey, exp, nonce));
    return {
        value: `${SESSION_VERSION}.${exp}.${nonce}.${mac}`,
        expiresAtMs: exp * 1000,
        maxAgeSeconds: SESSION_TTL_SECONDS,
    };
}

/**
 * Verify a session value against adminKey. Never throws.
 * @returns {{ valid: boolean, expiresAtMs: number|null }}
 */
function verifySession(value, adminKey, { nowMs } = {}) {
    const INVALID = { valid: false, expiresAtMs: null };
    try {
        if (!adminKey || typeof value !== 'string' || value.length > 512) return INVALID;
        const parts = value.split('.');
        if (parts.length !== 4) return INVALID;
        const [version, expStr, nonce, macStr] = parts;
        if (version !== SESSION_VERSION) return INVALID;
        if (!EXP_RE.test(expStr)) return INVALID;
        const nonceBuf = fromB64url(nonce);
        if (!nonceBuf || nonceBuf.length !== NONCE_BYTES) return INVALID;
        const presentedMac = fromB64url(macStr);
        // MAC_BYTES is a public format constant, not a secret — a length check
        // here leaks nothing about the key.
        if (!presentedMac || presentedMac.length !== MAC_BYTES) return INVALID;

        const exp = Number(expStr);
        const expectedMac = computeMac(adminKey, exp, nonce);
        const macOk = crypto.timingSafeEqual(presentedMac, expectedMac);
        if (!macOk) return INVALID;

        const now = nowSeconds(nowMs);
        if (exp <= now) return INVALID; // expired
        // A cookie claiming to live longer than a freshly issued one cannot
        // have come from issueSession(); refuse it rather than trust it.
        if (exp > now + SESSION_TTL_SECONDS + CLOCK_SKEW_SECONDS) return INVALID;

        return { valid: true, expiresAtMs: exp * 1000 };
    } catch (_) {
        return INVALID;
    }
}

/**
 * Minimal Cookie header parser. First occurrence of a name wins. Never throws.
 * @returns {Object<string,string>}
 */
function parseCookies(header) {
    const out = Object.create(null);
    if (typeof header !== 'string' || header.length === 0 || header.length > MAX_COOKIE_HEADER_LENGTH) {
        return out;
    }
    for (const piece of header.split(';')) {
        const idx = piece.indexOf('=');
        if (idx <= 0) continue;
        const name = piece.slice(0, idx).trim();
        const val = piece.slice(idx + 1).trim();
        if (!name || name in out) continue;
        out[name] = val;
    }
    return out;
}

function getHeader(req, name) {
    return req.get ? req.get(name) : (req.headers && req.headers[name.toLowerCase()]);
}

/** The raw session cookie value presented on req, or null. */
function readSessionCookie(req) {
    const cookies = parseCookies(getHeader(req, 'cookie'));
    const v = cookies[COOKIE_NAME];
    return typeof v === 'string' && v.length > 0 ? v : null;
}

function serializeSessionCookie(value, maxAgeSeconds = SESSION_TTL_SECONDS) {
    return `${COOKIE_NAME}=${value}; Path=/; Max-Age=${maxAgeSeconds}; HttpOnly; Secure; SameSite=Strict`;
}

function serializeClearCookie() {
    return `${COOKIE_NAME}=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Strict`;
}

// ---------------------------------------------------------------------------
// CSRF rules (contract §3.6). Rule 1 (SameSite=Strict) is an issuance
// attribute — see serializeSessionCookie(). Rules 2-4 are request checks.
// Each is exported on its own so the tests can prove each one rejects alone.
// ---------------------------------------------------------------------------

const CSRF_HEADER = 'X-Fleet-CSRF';

/** Rule 2: the custom header a cross-origin page cannot get past preflight. */
function hasCsrfHeader(req) {
    return String(getHeader(req, CSRF_HEADER) || '') === '1';
}

/**
 * Rule 3: Origin is present, is an http(s) URL, and its host (hostname +
 * port) equals the Host header exactly (case-insensitive). No Public Suffix
 * List logic: *.fly.dev is a shared suffix, so "same site" is not enough.
 */
function originMatchesHost(req) {
    const origin = getHeader(req, 'origin');
    const host = getHeader(req, 'host');
    if (!origin || !host) return false;
    let parsed;
    try {
        parsed = new URL(String(origin));
    } catch (_) {
        return false; // includes the literal "null" origin
    }
    if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') return false;
    // An Origin carries no path; anything beyond scheme://host[:port] is not a
    // browser-generated Origin header.
    if (String(origin).trim().replace(/\/$/, '').toLowerCase() !== parsed.origin.toLowerCase()) return false;
    return parsed.host.toLowerCase() === String(host).trim().toLowerCase();
}

/** Rule 4: if the browser sent Sec-Fetch-Site, it must say same-origin. */
function secFetchSiteOk(req) {
    const v = getHeader(req, 'sec-fetch-site');
    if (v === undefined || v === null || v === '') return true;
    return String(v).trim().toLowerCase() === 'same-origin';
}

/** All request-side CSRF rules. */
function passesCsrfChecks(req) {
    return hasCsrfHeader(req) && originMatchesHost(req) && secFetchSiteOk(req);
}

module.exports = {
    COOKIE_NAME,
    CSRF_HEADER,
    SESSION_TTL_SECONDS,
    issueSession,
    verifySession,
    parseCookies,
    readSessionCookie,
    serializeSessionCookie,
    serializeClearCookie,
    hasCsrfHeader,
    originMatchesHost,
    secFetchSiteOk,
    passesCsrfChecks,
};
