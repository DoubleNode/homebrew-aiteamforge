//
//  notify-routes.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Notification hub API routes (XACA-1400-001, EPIC-0068).
 *
 * This subitem registers the connection CRUD + status only. XACA-1400-002 adds
 * PUT /api/notify/routes/:team and later work adds POST /api/notify, inside
 * registerNotifyRoutes() below.
 *
 * Auth tiers. ADMIN (requireAdminKey): status, connection CRUD, receipts, and the
 * per-team key mint/revoke routes (XACA-1488). TEAM tier (PUT/GET
 * /api/notify/routes/:team and POST /api/notify) uses makeRequireNotifyTeamKey:
 * the admin key, or the team's own `fnt_` key bound to the team the request
 * targets. The fleet API key no longer opens these routes (XACA-1488-004).
 * FAIL CLOSED: the admin bypass and the mint/revoke routes require a SEPARATE admin tier
 * (FLEET_ADMIN_TOKEN set and different from FLEET_AUTH_TOKEN). With the admin fallback to the fleet
 * key, identical tokens, or open posture, mint/revoke answer 503 admin_tier_not_configured and the
 * team routes accept only valid `fnt_` keys (everything else 401).
 *
 * No response contains a secret value, with ONE deliberate exception: the mint
 * route returns the new team key's plaintext exactly once (Cache-Control:
 * no-store; never logged, only its hash is stored). Connections are returned in
 * their public view (secret fields as 'set'), and error bodies carry a fixed
 * code plus the store's own message, which never includes submitted secret
 * values. The request body is never echoed. A disabled store (missing/malformed
 * NOTIFY_STORE_KEY) answers 503.
 */

const { requireAdminKey, isAdminAuthorized, getAuthPosture, extractHeaderCredential, sendUnauthorized } = require('./auth-middleware');
const { TEAM_RE, SEVERITIES } = require('./notify-team-routes');
const { NotifyStoreError } = require('./notify-store');
const { createNotifyDispatcher, NotifyDispatchError } = require('./notify-dispatcher');
const { createReceiptLog } = require('./notify-receipts');

const TYPE_RE = /^[a-z][a-z0-9-]{0,31}$/;
const REF_RE = /^[A-Za-z0-9][A-Za-z0-9._:/#-]{0,127}$/;
const NOTIFY_KEYS = ['team', 'type', 'title', 'body', 'ref', 'severity'];
const MAX_TITLE = 200;
const MAX_BODY = 4000;
const MAX_RECEIPTS = 200;

/** Field-naming validation errors; values are never echoed. Returns message or null. */
function validateNotifyBody(b) {
    if (b === null || typeof b !== 'object' || Array.isArray(b)) return 'body must be an object';
    if (Object.keys(b).some((k) => !NOTIFY_KEYS.includes(k))) return 'unknown field in body';
    if (typeof b.team !== 'string' || !TEAM_RE.test(b.team)) return 'invalid team id';
    if (typeof b.type !== 'string' || !TYPE_RE.test(b.type)) return 'invalid type';
    if (typeof b.title !== 'string' || b.title.trim() === '' || b.title.length > MAX_TITLE) return `title must be a non-empty string up to ${MAX_TITLE} chars`;
    if (typeof b.body !== 'string' || b.body.length > MAX_BODY) return `body must be a string up to ${MAX_BODY} chars`;
    if (b.ref !== undefined && (typeof b.ref !== 'string' || !REF_RE.test(b.ref))) return 'invalid ref';
    if (b.severity !== undefined && !SEVERITIES.includes(b.severity)) return 'invalid severity';
    return null;
}

function sendError(res, e) {
    if (e instanceof NotifyDispatchError) {
        if (e.result !== undefined) return res.status(e.status).json({ error: e.code, message: e.message, result: e.result });
        return res.status(e.status).json({ error: e.code, message: e.message });
    }
    if (e instanceof NotifyStoreError) {
        return res.status(e.status).json({ error: e.code, message: e.message });
    }
    return res.status(500).json({ error: 'internal_error', message: 'internal error' });
}

const TEAM_KEY_PREFIX = 'fnt_';

/**
 * XACA-1488: the admin tier is "separate" only when FLEET_ADMIN_TOKEN is set AND differs from
 * FLEET_AUTH_TOKEN. auth-middleware's admin tier otherwise falls back to the fleet key (or is open),
 * which would let the fleet key pass the admin bypass / mint team keys. Fail closed here only; the
 * global admin behaviour is untouched. Evaluated per request (env may change in tests).
 */
function adminTierSeparate() {
    const p = getAuthPosture();
    return p.admin === 'set' && !p.identical;
}

/**
 * Posture guard for the mint/revoke routes, placed AFTER requireAdminKey (the route inventory test reads the first gate): 503 unless the admin tier is
 * separate, so a fleet-key caller (fallback/identical/open posture) can never reach the handler.
 */
function requireSeparateAdminTier(req, res, next) {
    if (!adminTierSeparate()) {
        return res.status(503).json({
            error: 'admin_tier_not_configured',
            message: 'per-team notify keys require FLEET_ADMIN_TOKEN set and different from FLEET_AUTH_TOKEN',
        });
    }
    return next();
}

/**
 * XACA-1488-003: per-team notify key gate (plan D1/D3/D4).
 *   a. admin credential (exactly as requireAdminKey accepts it) -> next(), no binding.
 *   b. `fnt_` credential -> store.verifyTeamKey: disabled 503, no match 401,
 *      bound team missing/different 403 (one fixed body naming neither team),
 *      match -> req.notifyTeam = team, next().
 *   c. anything else (fleet key, garbage, nothing) -> the standard byte-identical 401.
 * A non-`fnt_` credential is never hashed against team hashes. Credentials are never logged.
 *
 * @param {{verifyTeamKey: Function}} store  createNotifyStore() object
 * @param {(req) => any} bindTeam            team this request targets (req.params.team / req.body.team)
 * @param {(req,res,bound) => boolean} [preBind]  optional: runs AFTER the key is verified and BEFORE the
 *        binding compare; return false only if it already sent the response. Lets the route keep its
 *        400/404 (invalid / unregistered team) answers ahead of the 403 (plan D4).
 */
function makeRequireNotifyTeamKey(store, bindTeam, preBind) {
    return function requireNotifyTeamKey(req, res, next) {
        try {
            if (adminTierSeparate() && isAdminAuthorized(req)) return next();
            const { status, credential } = extractHeaderCredential(req);
            if (status !== 'present' || typeof credential !== 'string' || !credential.startsWith(TEAM_KEY_PREFIX)) {
                return sendUnauthorized(res);
            }
            const team = store.verifyTeamKey(credential);
            if (!team) return sendUnauthorized(res);
            let bound;
            try { bound = bindTeam(req); } catch (_) { bound = undefined; }
            if (typeof preBind === 'function' && preBind(req, res, bound) === false) return undefined;
            if (typeof bound !== 'string' || bound !== team) {
                return res.status(403).json({ error: 'forbidden', message: 'key not valid for this team' });
            }
            req.notifyTeam = team;
            return next();
        } catch (e) {
            if (e && e.code === 'store_disabled') {
                // Same body as guard(): the reason comes from store.status(), not e.message (which already carries the prefix).
                let reason = null;
                try { reason = store.status().reason; } catch (_) { reason = null; }
                return res.status(503).json({ error: 'store_disabled', message: `notify store disabled: ${reason || 'unavailable'}` });
            }
            return res.status(500).json({ error: 'internal_error', message: 'internal error' });
        }
    };
}

/**
 * @param {import('express').Application|import('express').Router} app
 * @param {{store: object, registry: {has:Function,get:Function,names?:Function}}} deps
 */
function registerNotifyRoutes(app, { store, registry, isRegisteredTeam, dispatcher, receipts }) {
    // Defaults: one receipt log shared by the dispatcher and GET /api/notify/receipts.
    // When injecting `dispatcher`, inject the SAME `receipts` it writes to.
    const receiptLog = receipts || createReceiptLog();
    const disp = dispatcher || createNotifyDispatcher({ store, registry, receipts: receiptLog });

    // 503 when the store is disabled; any thrown error is mapped without echoing input.
    const guard = (handler) => (req, res) => {
        try {
            const s = store.status();
            if (!s.enabled) {
                return res.status(503).json({ error: 'store_disabled', message: `notify store disabled: ${s.reason}` });
            }
            return handler(req, res);
        } catch (e) { return sendError(res, e); }
    };

    app.get('/api/notify/status', requireAdminKey, (req, res) => {
        const s = store.status();
        const providers = registry && typeof registry.names === 'function' ? registry.names() : [];
        const body = { enabled: s.enabled, reason: s.reason || null, providers };
        if (s.recovered) body.recovered = s.recovered;
        res.json(body);
    });

    app.get('/api/notify/connections', requireAdminKey, guard((req, res) => {
        res.json({ connections: store.listConnections() });
    }));

    app.get('/api/notify/connections/:id', requireAdminKey, guard((req, res) => {
        const c = store.getConnection(req.params.id);
        if (!c) return res.status(404).json({ error: 'not_found', message: 'connection not found' });
        res.json(c);
    }));

    app.post('/api/notify/connections', requireAdminKey, guard((req, res) => {
        res.status(201).json(store.createConnection(req.body));
    }));

    app.put('/api/notify/connections/:id', requireAdminKey, guard((req, res) => {
        res.json(store.updateConnection(req.params.id, req.body));
    }));

    app.delete('/api/notify/connections/:id', requireAdminKey, guard((req, res) => {
        store.deleteConnection(req.params.id);
        res.json({ deleted: req.params.id });
    }));

    // ----- team routes (XACA-1400-002): scoped by well-formed id AND registered team.
    // No isRegisteredTeam injected => fail closed (every team is "unknown").
    // Sends the 400/404 for a malformed / unregistered team id and returns true; false = team OK.
    const sendTeamProblem = (res, team) => {
        if (typeof team !== 'string' || !TEAM_RE.test(team)) {
            res.status(400).json({ error: 'invalid', message: 'invalid team id' });
            return true;
        }
        let known = false;
        try { known = typeof isRegisteredTeam === 'function' && isRegisteredTeam(team) === true; } catch (_) { known = false; }
        if (!known) {
            res.status(404).json({ error: 'not_found', message: 'unknown team' });
            return true;
        }
        return false;
    };
    const teamGate = (handler) => guard((req, res) => {
        const team = req.params.team;
        if (sendTeamProblem(res, team)) return undefined;
        return handler(req, res, team);
    });

    // preBind hooks (plan D4): keep the 400/404 answers ahead of the key-binding 403.
    // Return false only when the response has been sent.
    const preBindTeam = (req, res, bound) => (sendTeamProblem(res, bound) ? false : true);
    const preBindDispatch = (req, res, bound) => {
        const bad = validateNotifyBody(req.body);
        if (bad) { res.status(400).json({ error: 'invalid', message: bad }); return false; }
        return sendTeamProblem(res, bound) ? false : true;
    };
    const teamKeyGate = makeRequireNotifyTeamKey(store, (r) => r.params.team, preBindTeam);
    const dispatchKeyGate = makeRequireNotifyTeamKey(store, (r) => r.body && r.body.team, preBindDispatch);

    // ----- per-team notify keys (XACA-1488-002): ADMIN only. Mint returns the plaintext once.
    app.post('/api/notify/teams/:team/key', requireAdminKey, requireSeparateAdminTier, teamGate((req, res, team) => {
        const key = store.mintTeamKey(team);
        const entry = store.listTeamKeys().find((k) => k.team === team);
        res.set('Cache-Control', 'no-store');
        res.status(201).json({
            team, key, createdAt: entry ? entry.createdAt : null,
            note: 'This key is shown once and cannot be retrieved again; store it now. Minting again replaces it.',
        });
    }));

    app.delete('/api/notify/teams/:team/key', requireAdminKey, requireSeparateAdminTier, teamGate((req, res, team) => {
        const revoked = store.revokeTeamKey(team);
        res.set('Cache-Control', 'no-store');
        res.json({ team, revoked });
    }));

    app.put('/api/notify/routes/:team', teamKeyGate, teamGate((req, res, team) => {
        const rec = store.setTeamRoutes(team, req.body);
        res.json({ team, routes: rec.config.routes, updatedAt: rec.updatedAt, catalogTypes: Object.keys(rec.catalog).length });
    }));

    app.get('/api/notify/routes/:team', teamKeyGate, teamGate((req, res, team) => {
        const rec = store.getTeamRoutes(team);
        if (!rec) return res.status(404).json({ error: 'not_found', message: 'no routes pushed for team' });
        res.json({ team, config: rec.config, catalog: rec.catalog, updatedAt: rec.updatedAt });
    }));

    // ----- dispatch (XACA-1400-003): same team scoping as routes; key gate is team-bound (XACA-1488-004).
    app.post('/api/notify', dispatchKeyGate, guard(async (req, res) => {
        try {
            const bad = validateNotifyBody(req.body);
            if (bad) return res.status(400).json({ error: 'invalid', message: bad });
            let known = false;
            try { known = typeof isRegisteredTeam === 'function' && isRegisteredTeam(req.body.team) === true; } catch (_) { known = false; }
            if (!known) return res.status(404).json({ error: 'not_found', message: 'unknown team' });
            return res.json(await disp.dispatch(req.body));
        } catch (e) { return sendError(res, e); }
    }));

    app.get('/api/notify/receipts', requireAdminKey, (req, res) => {
        const { team } = req.query;
        if (team !== undefined && (typeof team !== 'string' || !TEAM_RE.test(team))) {
            return res.status(400).json({ error: 'invalid', message: 'invalid team id' });
        }
        let limit = 50;
        if (req.query.limit !== undefined) {
            limit = typeof req.query.limit === 'string' && /^[0-9]{1,4}$/.test(req.query.limit) ? parseInt(req.query.limit, 10) : 0;
            if (limit < 1 || limit > MAX_RECEIPTS) return res.status(400).json({ error: 'invalid', message: `limit must be 1-${MAX_RECEIPTS}` });
        }
        try { return res.json({ receipts: receiptLog.recent({ team, limit }) }); } catch (e) { return sendError(res, e); }
    });

    // Scoped error handler (D1). The global express.json() runs BEFORE these routes, and its
    // SyntaxError message embeds a snippet of the body (a secret prefix). Express's default
    // handler would send and log that text, so errors on /api/notify paths end here instead:
    // fixed bodies, and at most the error TYPE is logged. Other routes are untouched.
    app.use('/api/notify', (err, req, res, next) => {
        if (res.headersSent) return next(err);
        const parseFailure = err && (err.type === 'entity.parse.failed' || err instanceof SyntaxError);
        console.error('[NOTIFY] request error:', parseFailure ? 'entity.parse.failed' : ((err && err.name) || 'Error'));
        if (parseFailure) {
            return res.status(400).json({ error: 'invalid_json', message: 'request body is not valid JSON' });
        }
        return res.status(500).json({ error: 'internal_error', message: 'internal error' });
    });
}

/**
 * Single composition server.js calls (XACA-1400-006): builds the provider registry, the encrypted
 * store (key from NOTIFY_STORE_KEY via the store's own default), ONE receipt log, and mounts the
 * routes with all of them. A disabled store never stops startup: the routes answer 503 and ONE
 * log line says why. The line carries the store's fixed reason text only, never key material.
 *
 * @param {object} app
 * @param {{isRegisteredTeam: Function, logger?: object, storeOpts?: object, receiptOpts?: object}} opts
 * @returns {{store: object, registry: object, receipts: object, imessageQueue: object}}
 */
function wireNotifyHub(app, opts) {
    const o = opts || {};
    if (typeof o.isRegisteredTeam !== 'function') throw new TypeError('wireNotifyHub: isRegisteredTeam is required');
    const logger = o.logger || console;
    const { createNotifyStore } = require('./notify-store');
    const { defaultRegistry } = require('./notify-providers');
    const receipts = createReceiptLog(o.receiptOpts);
    // iMessage sender pool (XACA-1402): ONE in-memory queue shared by the provider (enqueue)
    // and the relay routes (claim/ack); settling a job appends the delivery receipt.
    const { createImessageQueue } = require('./notify-imessage-queue');
    const { registerImessageRelayRoutes, createDeliveryReceiptSink } = require('./notify-imessage-routes');
    const imessageQueue = o.imessageQueue || createImessageQueue({ onSettle: createDeliveryReceiptSink(receipts, logger) });
    const registry = defaultRegistry({ imessageQueue });
    const store = createNotifyStore(Object.assign({}, o.storeOpts, { registry }));
    registerImessageRelayRoutes(app, { queue: imessageQueue });
    registerNotifyRoutes(app, { store, registry, receipts, isRegisteredTeam: o.isRegisteredTeam });
    // Lease/TTL expiry is also swept lazily on every queue call; this timer makes a failed
    // delivery receipt appear even when no relay is polling. unref'd: never holds the process open.
    const sweepMs = Number.isFinite(o.imessageSweepMs) && o.imessageSweepMs > 0 ? o.imessageSweepMs : 15000;
    const sweeper = setInterval(() => { try { imessageQueue.sweep(); } catch (_) { /* next tick */ } }, sweepMs);
    if (typeof sweeper.unref === 'function') sweeper.unref();
    const s = store.status();
    const rec = s.recovered;
    const recovery = rec
        ? ` — RECOVERED: ${[
            rec.movedAside ? `store file moved aside to ${rec.movedAside}` : null,
            rec.quarantined > 0 ? `${rec.quarantined} connection(s) quarantined` : null,
        ].filter(Boolean).join('; ') || 'store file could not be read'}`
        : '';
    logger.log(s.enabled
        ? `[NOTIFY] hub enabled${recovery}`
        : `[NOTIFY] hub disabled (${s.reason})${recovery}; /api/notify endpoints answer 503`);
    return { store, registry, receipts, imessageQueue };
}

module.exports = { registerNotifyRoutes, wireNotifyHub, makeRequireNotifyTeamKey };
