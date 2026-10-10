//
//  teams.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Microsoft Teams notify provider (XACA-1401-001, EPIC-0068 D5).
 * Node port of kanban-hooks/release_notify_teams.py.
 *
 * Two payload shapes, chosen by the connection param `shape` (default "flow"):
 *   flow     Power Automate "When an HTTP request is received" flow: a
 *            `message` envelope carrying one Adaptive Card 1.4.
 *   webhook  Plain Teams incoming webhook: {"text": ...}.
 *
 * The webhook URL is the secret (`secrets.webhookUrl`). Error messages here
 * are static strings, field names, an HTTP status or an error TYPE - never the
 * URL or foreign exception text. One POST, no retries, no redirects (a
 * redirected POST would be replayed to a URL nobody vetted).
 *
 * Deliberate divergences from Python:
 *  - The Node message carries title/body/severity, so the text is rendered
 *    here ("[SEVERITY] title\n\nbody\n\nteam · type · ref"; info has no
 *    prefix, absent context fields are skipped). Python receives pre-rendered
 *    text.
 *  - The webhook host must be a Microsoft endpoint (ALLOWED_HOST_SUFFIXES);
 *    Python accepts any https URL.
 */

const { NotifyConfigError, NotifySendError, errorTypeName } = require('./index');

const SHAPES = ['flow', 'webhook'];
const DEFAULT_SHAPE = 'flow';
const ID_HEADERS = ['x-ms-workflow-run-id', 'x-ms-request-id']; // not secrets; useful in a receipt

function renderText(message) {
    const m = message || {};
    const parts = [];
    const sev = typeof m.severity === 'string' ? m.severity.toLowerCase() : 'info';
    const title = typeof m.title === 'string' ? m.title : '';
    const head = sev && sev !== 'info' ? `[${sev.toUpperCase()}] ${title}`.trim() : title;
    if (head) parts.push(head);
    if (typeof m.body === 'string' && m.body) parts.push(m.body);
    // Context line (XACA-1401, user decision 2026-10-10): the Node message is
    // structured, so unlike release_notify_teams.py's pre-rendered text the
    // card would otherwise never say which team, notice type or ref it is about.
    const ctx = [m.team, m.type, m.ref].filter((v) => typeof v === 'string' && v);
    if (ctx.length) parts.push(ctx.join(' · '));
    return parts.join('\n\n');
}

// Microsoft-hosted endpoints only (XACA-1401, user decision 2026-10-10): the
// webhook URL is operator-entered, so an open https policy would let a
// connection point FM's outbound POST at any host. Matched as a dot-suffix.
const ALLOWED_HOST_SUFFIXES = ['.logic.azure.com', '.webhook.office.com', '.powerplatform.com', '.powerautomate.com'];

function hostAllowed(hostname) {
    const h = String(hostname || '').toLowerCase();
    return ALLOWED_HOST_SUFFIXES.some((sfx) => h.endsWith(sfx) && h.length > sfx.length);
}

function buildPayload(shape, text) {
    if (shape === 'webhook') return { text };
    return {
        type: 'message',
        attachments: [{
            contentType: 'application/vnd.microsoft.card.adaptive',
            contentUrl: null,
            content: {
                $schema: 'http://adaptivecards.io/schemas/adaptive-card.json',
                type: 'AdaptiveCard',
                version: '1.4',
                body: [{ type: 'TextBlock', text, wrap: true }],
            },
        }],
    };
}

function shapeOf(connection) {
    const p = (connection && connection.params) || {};
    return p.shape === undefined || p.shape === '' ? DEFAULT_SHAPE : p.shape;
}

function urlOf(connection) {
    const s = connection && connection.secrets;
    return s && typeof s.webhookUrl === 'string' ? s.webhookUrl.trim() : '';
}

function createTeamsProvider({ fetchImpl } = {}) {
    const doFetch = fetchImpl || ((...a) => globalThis.fetch(...a));
    return {
        name: 'teams',
        paramFields: ['shape'],
        secretFields: ['webhookUrl'],
        validate(connection) {
            if (!SHAPES.includes(shapeOf(connection))) {
                throw new NotifyConfigError('teams param shape must be one of: flow, webhook');
            }
            let u = null;
            try { u = new URL(urlOf(connection)); } catch (_e) { u = null; }
            if (!u || u.protocol !== 'https:' || !u.hostname || u.username || u.password || u.port) {
                throw new NotifyConfigError('teams secret webhookUrl must be an https URL');
            }
            if (!hostAllowed(u.hostname)) {
                throw new NotifyConfigError('teams secret webhookUrl must be a Microsoft Teams / Power Automate URL');
            }
        },
        async send(connection, message, { signal } = {}) {
            const body = JSON.stringify(buildPayload(shapeOf(connection), renderText(message)));
            let res;
            try {
                res = await doFetch(urlOf(connection), {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body,
                    redirect: 'manual',
                    signal,
                });
            } catch (err) {
                throw new NotifySendError(`teams transport error (${errorTypeName(err)})`);
            }
            const status = res && res.status;
            if (!Number.isInteger(status) || status < 200 || status >= 300) {
                throw new NotifySendError(`teams returned HTTP ${Number.isInteger(status) ? status : 0}`);
            }
            let id;
            for (const h of ID_HEADERS) {
                const v = res.headers && typeof res.headers.get === 'function' ? res.headers.get(h) : null;
                if (v) { id = v; break; }
            }
            return id ? { providerMessageId: id } : {};
        },
    };
}

module.exports = { createTeamsProvider, buildPayload, renderText, SHAPES, DEFAULT_SHAPE, ALLOWED_HOST_SUFFIXES };
