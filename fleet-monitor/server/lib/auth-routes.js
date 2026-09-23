//
//  auth-routes.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Operator login/logout/session routes for the admin tier (XACA-0398-003).
 *
 * Normative spec: kanban/plans/XACA-0395/XACA-0395_auth_contract.md §3.6.
 *
 *   POST /api/auth/login    body { token } -> 200 + __Host-fleet_admin cookie
 *   POST /api/auth/logout   -> 204, clears the cookie
 *   GET  /api/auth/session  -> { gate, authenticated, expiresAt } (public)
 *
 * The browser pastes the ADMIN-tier token once (LCARS unlock dialog,
 * public/{lcars,lcars2}/js/fleet-api-auth.js). The token is never stored by
 * the page: the server swaps it for an HttpOnly cookie that page scripts
 * cannot read and that expires after 8 h (lib/admin-session.js).
 *
 * WHAT THIS FILE NEVER DOES:
 *   - log, echo, or put the presented token (or its length/prefix) anywhere;
 *   - return a failure body that varies by reason — every credential failure
 *     is the contract §4 byte-identical 401 (via auth-middleware's sender);
 *   - accept a login that fails the CSRF rules (login CSRF would let a hostile
 *     page plant ITS session in the operator's browser).
 *
 * RATE LIMIT: FAILED logins are counted per client address in a fixed
 * window (LOGIN_MAX_FAILURES per LOGIN_WINDOW_MS -> 429). Successful logins
 * are not counted. The token's entropy is the primary control; this only
 * caps guessing noise.
 *
 * CLIENT ADDRESS (XACA-0398-006): see resolveLoginClientKey() below. Behind
 * Fly's proxy the TCP peer (and `req.ip`, since `trust proxy` is unset) is
 * the proxy, so keying on it put every client in ONE bucket and let a single
 * attacker lock the operator out for the whole window. The key is now the
 * `Fly-Client-IP` header, trusted ONLY when running on Fly.
 */

const net = require('net');
const authMiddleware = require('./auth-middleware');
const adminSession = require('./admin-session');

const LOGIN_MAX_FAILURES = 10;
const LOGIN_WINDOW_MS = 15 * 60 * 1000;
const LOGIN_BUCKET_CAP = 10000; // bound memory under an address-spraying flood

const UNAUTHORIZED_BODY = { error: 'Unauthorized', code: 'unauthorized' };
const CSRF_BODY = { error: 'Forbidden', code: 'csrf' };
const RATE_LIMITED_BODY = { error: 'Too Many Requests', code: 'rate_limited' };
const GATE_OPEN_BODY = { error: 'Auth gate is open', code: 'gate_open' };

// Same shape rule as the header credential (contract §3.3).
const CREDENTIAL_SHAPE_RE = /^[A-Za-z0-9._~+/=-]{16,512}$/;
const ASCII_WS_RE = /^[ \t\n\r\f\v]+|[ \t\n\r\f\v]+$/g;

function createLoginLimiter({ maxFailures = LOGIN_MAX_FAILURES, windowMs = LOGIN_WINDOW_MS, now = Date.now } = {}) {
    const buckets = new Map(); // key -> { count, resetAt }

    function prune(t) {
        for (const [k, b] of buckets) {
            if (b.resetAt <= t) buckets.delete(k);
        }
    }

    return {
        isBlocked(key) {
            const b = buckets.get(key);
            if (!b) return false;
            if (b.resetAt <= now()) { buckets.delete(key); return false; }
            return b.count >= maxFailures;
        },
        recordFailure(key) {
            const t = now();
            if (buckets.size >= LOGIN_BUCKET_CAP) prune(t);
            if (buckets.size >= LOGIN_BUCKET_CAP) buckets.clear(); // fail toward availability, not unbounded memory
            const b = buckets.get(key);
            if (!b || b.resetAt <= t) {
                buckets.set(key, { count: 1, resetAt: t + windowMs });
            } else {
                b.count += 1;
            }
        },
        reset() { buckets.clear(); },
    };
}

/**
 * The rate-limit bucket key for a login attempt (XACA-0398-006).
 *
 * On Fly (FLY_APP_NAME is set in every Fly Machine's environment by the
 * platform) the key is the `Fly-Client-IP` request header, which Fly's edge
 * proxy SETS on every request it forwards — overwriting any value the client
 * sent — to the address it accepted the connection from. The app's only
 * public listener is the fly.toml `[http_service]`, i.e. that proxy; the
 * sole other path to port 3000 is Fly's private 6PN network, reachable only
 * by machines and WireGuard peers inside the operator's own Fly org (an
 * accepted, already-privileged residual). So a public client cannot choose
 * its bucket.
 *
 * Off Fly (a local fleet-monitor, the tests) nothing sets the header, so a
 * client-supplied one is IGNORED and the key is the TCP peer address. That
 * is the anti-spoofing half: the header is trusted only where the platform
 * guarantees who wrote it.
 *
 * A present-but-invalid header (not a bare IPv4/IPv6 literal — e.g. a
 * comma-joined duplicate) also falls back to the TCP peer, i.e. the old
 * shared-bucket behaviour: never a per-request-unique key that would let an
 * attacker escape the limiter by varying a string.
 *
 * WHY NOT `app.set('trust proxy', N)`: that is process-wide. Besides req.ip
 * it makes req.protocol/req.secure honour X-Forwarded-Proto and req.hostname
 * honour X-Forwarded-Host, and its correctness depends on the exact hop count
 * of Fly's X-Forwarded-For chain. Nothing reads those today (the session
 * cookie hard-codes `Secure`, CORS reads the Origin header, the CSRF check
 * reads the raw Host header), but any future reader would silently inherit
 * client-influenced values. Scoping the trust to this one limiter key keeps
 * the blast radius at "which bucket a failed login is counted in".
 *
 * @param {import('express').Request} req
 * @param {Object<string, string|undefined>} [env] injectable for tests;
 *   defaults to the process environment
 * @returns {string}
 */
function resolveLoginClientKey(req, env = process.env) {
    const peer = String((req.socket && req.socket.remoteAddress) || req.ip || 'unknown');
    if (!env.FLY_APP_NAME) return peer;
    const raw = req.get ? req.get('fly-client-ip') : (req.headers && req.headers['fly-client-ip']);
    const value = typeof raw === 'string' ? raw.trim() : '';
    if (value && net.isIP(value) !== 0) return value;
    return peer;
}

function noStore(res) {
    res.set('Cache-Control', 'no-store');
}

function sendUnauthorized(res) {
    // Byte-identical to auth-middleware's 401 (contract §4).
    res.status(401).set('WWW-Authenticate', 'Bearer').json(UNAUTHORIZED_BODY);
}

/**
 * Register the auth routes.
 * @param {import('express').Express} app
 * @param {{ limiter?: ReturnType<typeof createLoginLimiter> }} [opts]
 */
function registerAuthRoutes(app, opts = {}) {
    const limiter = opts.limiter || createLoginLimiter();

    app.post('/api/auth/login', (req, res) => {
        noStore(res);

        if (!authMiddleware.getAdminExpectedKey()) {
            return res.status(409).json(GATE_OPEN_BODY);
        }
        if (!adminSession.passesCsrfChecks(req)) {
            return res.status(403).json(CSRF_BODY);
        }

        const clientKey = resolveLoginClientKey(req);
        if (limiter.isBlocked(clientKey)) {
            res.set('Retry-After', String(Math.ceil(LOGIN_WINDOW_MS / 1000)));
            return res.status(429).json(RATE_LIMITED_BODY);
        }

        const raw = req.body && typeof req.body.token === 'string' ? req.body.token : '';
        const presented = raw.replace(ASCII_WS_RE, '');
        // Resolve the expected key AFTER the checks above, and compare with
        // the constant-time primitive. A malformed token is still a plain
        // credential failure (same 401 bytes), and still counts.
        const expected = authMiddleware.getAdminExpectedKey();
        const ok = CREDENTIAL_SHAPE_RE.test(presented) && authMiddleware.safeEqual(presented, expected);
        if (!ok) {
            limiter.recordFailure(clientKey);
            return sendUnauthorized(res);
        }

        const session = adminSession.issueSession(expected);
        res.append('Set-Cookie', adminSession.serializeSessionCookie(session.value, session.maxAgeSeconds));
        return res.status(200).json({ authenticated: true, expiresAt: session.expiresAtMs });
    });

    app.post('/api/auth/logout', (req, res) => {
        noStore(res);
        if (!adminSession.passesCsrfChecks(req)) {
            return res.status(403).json(CSRF_BODY);
        }
        res.append('Set-Cookie', adminSession.serializeClearCookie());
        return res.status(204).end();
    });

    app.get('/api/auth/session', (req, res) => {
        noStore(res);
        const expected = authMiddleware.getAdminExpectedKey();
        if (!expected) {
            return res.json({ gate: 'open', authenticated: false, expiresAt: null });
        }
        const cookie = adminSession.readSessionCookie(req);
        const result = cookie ? adminSession.verifySession(cookie, expected) : { valid: false, expiresAtMs: null };
        return res.json({
            gate: 'closed',
            authenticated: result.valid,
            expiresAt: result.valid ? result.expiresAtMs : null,
        });
    });

    return { limiter };
}

module.exports = {
    registerAuthRoutes,
    createLoginLimiter,
    resolveLoginClientKey,
    LOGIN_MAX_FAILURES,
    LOGIN_WINDOW_MS,
};
