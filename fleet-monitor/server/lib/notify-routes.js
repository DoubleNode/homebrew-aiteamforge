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
 * Every route is ADMIN tier (requireAdminKey). No response ever contains a
 * secret value: connections are returned in their public view (secret fields
 * as 'set'), and error bodies carry a fixed code plus the store's own message,
 * which never includes submitted secret values. The request body is never
 * echoed. A disabled store (missing/malformed NOTIFY_STORE_KEY) answers 503.
 */

const { requireAdminKey, requireApiKey } = require('./auth-middleware');
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

    // ----- team routes (XACA-1400-002): fleet API key, team-scoped by id + registry.
    // The key is fleet-wide, so scoping = well-formed id AND registered team.
    // No isRegisteredTeam injected => fail closed (every team is "unknown").
    const teamGate = (handler) => guard((req, res) => {
        const team = req.params.team;
        if (typeof team !== 'string' || !TEAM_RE.test(team)) {
            return res.status(400).json({ error: 'invalid', message: 'invalid team id' });
        }
        let known = false;
        try { known = typeof isRegisteredTeam === 'function' && isRegisteredTeam(team) === true; } catch (_) { known = false; }
        if (!known) return res.status(404).json({ error: 'not_found', message: 'unknown team' });
        return handler(req, res, team);
    });

    app.put('/api/notify/routes/:team', requireApiKey, teamGate((req, res, team) => {
        const rec = store.setTeamRoutes(team, req.body);
        res.json({ team, routes: rec.config.routes, updatedAt: rec.updatedAt, catalogTypes: Object.keys(rec.catalog).length });
    }));

    app.get('/api/notify/routes/:team', requireApiKey, teamGate((req, res, team) => {
        const rec = store.getTeamRoutes(team);
        if (!rec) return res.status(404).json({ error: 'not_found', message: 'no routes pushed for team' });
        res.json({ team, config: rec.config, catalog: rec.catalog, updatedAt: rec.updatedAt });
    }));

    // ----- dispatch (XACA-1400-003): fleet API key, same team scoping as routes.
    app.post('/api/notify', requireApiKey, guard(async (req, res) => {
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

module.exports = { registerNotifyRoutes, wireNotifyHub };
