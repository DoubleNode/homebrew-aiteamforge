//
//  ntfy.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * ntfy notify provider (XACA-1401-004, EPIC-0068 D5).
 *
 * param  server  base URL, default https://ntfy.sh. Self-hosted allowed, but
 *                https only (fail closed on http). Not a secret.
 * secret topic   DESIGN CHOICE: on a public ntfy server the topic name IS the
 *                capability - anyone who knows it can read and publish - so it
 *                is stored as a secret (redacted by the hub's scrubber, never
 *                echoed). Registry convention (index.js) puts anything that
 *                grants access in secretFields.
 * secret token   optional Bearer token (protected self-hosted topics).
 *
 * Publishes JSON to the server root. Severity -> priority: info 2, warning 3,
 * high 4, critical 5. Errors carry an HTTP status or error TYPE only. One
 * POST, no retries, no redirects.
 */

const { NotifyConfigError, NotifySendError, errorTypeName } = require('./index');

const DEFAULT_SERVER = 'https://ntfy.sh';
const PRIORITY = { info: 2, warning: 3, high: 4, critical: 5 };
const TOPIC_RE = /^[A-Za-z0-9_-]{1,64}$/;

function str(v) { return typeof v === 'string' ? v.trim() : ''; }

function serverOf(connection) {
    const raw = connection && connection.params && connection.params.server;
    // A mistyped (non-string) server must NOT fall back to the public default:
    // the secret topic would be published to ntfy.sh (XACA-1401-006).
    if (raw !== undefined && raw !== null && typeof raw !== 'string') return null;
    return str(raw) || DEFAULT_SERVER;
}

function parseServer(connection) {
    let u = null;
    const raw = serverOf(connection);
    if (raw === null) return null;
    try { u = new URL(raw); } catch (_e) { return null; }
    if (u.protocol !== 'https:' || !u.hostname || u.username || u.password || u.search || u.hash) return null;
    return u;
}

function createNtfyProvider({ fetchImpl } = {}) {
    const doFetch = fetchImpl || ((...a) => globalThis.fetch(...a));
    return {
        name: 'ntfy',
        paramFields: ['server'],
        secretFields: ['topic', 'token'],
        validate(connection) {
            if (!parseServer(connection)) throw new NotifyConfigError('ntfy param server must be an https URL');
            const topic = str(connection && connection.secrets && connection.secrets.topic);
            if (!TOPIC_RE.test(topic)) throw new NotifyConfigError('ntfy secret topic is required (letters, digits, - and _ only)');
            const tok = connection && connection.secrets && connection.secrets.token;
            if (tok !== undefined && tok !== null && typeof tok !== 'string') throw new NotifyConfigError('ntfy secret token must be a string');
            // Header value: printable ASCII only, so CR/LF can never split the header (late TypeError otherwise).
            if (typeof tok === 'string' && /[^\x21-\x7e]/.test(tok.trim())) throw new NotifyConfigError('ntfy secret token has invalid characters');
        },
        async send(connection, message, { signal } = {}) {
            const m = message || {};
            const sev = Object.prototype.hasOwnProperty.call(PRIORITY, m.severity) ? m.severity : 'info';
            const u = parseServer(connection);
            if (!u) throw new NotifySendError('ntfy server is not a valid https URL');
            const payload = {
                topic: str(connection.secrets && connection.secrets.topic),
                message: str(m.body) || str(m.title) || '(no message)',
                priority: PRIORITY[sev],
                tags: [sev],
            };
            if (str(m.title)) payload.title = str(m.title);
            const team = str(m.team);
            if (/^[A-Za-z0-9_-]{1,32}$/.test(team)) payload.tags.push(team);
            const ref = str(m.ref);
            if (/^https?:\/\//i.test(ref)) payload.click = ref;

            const headers = { 'Content-Type': 'application/json' };
            const token = str(connection.secrets && connection.secrets.token);
            if (token) headers.Authorization = `Bearer ${token}`;

            let res;
            try {
                res = await doFetch(u.toString(), {
                    method: 'POST', headers, body: JSON.stringify(payload), redirect: 'manual', signal,
                });
            } catch (err) {
                throw new NotifySendError(`ntfy transport error (${errorTypeName(err)})`);
            }
            const status = res && res.status;
            if (!Number.isInteger(status) || status < 200 || status >= 300) {
                throw new NotifySendError(`ntfy returned HTTP ${Number.isInteger(status) ? status : 0}`);
            }
            let body = null;
            try { body = await res.json(); } catch (_e) { body = null; }
            return body && typeof body.id === 'string' && body.id ? { providerMessageId: body.id } : {};
        },
    };
}

module.exports = { createNtfyProvider, PRIORITY, DEFAULT_SERVER };
