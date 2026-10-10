//
//  email.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * SMTP email notify provider (XACA-1401-003, EPIC-0068 D5: SMTP via nodemailer,
 * TLS REQUIRED). Follows the contract in ./index.js.
 *
 *  params:  host, port, from, to (address, comma list, or array),
 *           secure ('implicit' = TLS from connect, usually 465;
 *                   'starttls' = upgrade, usually 587; default by port)
 *  secrets: user, pass (both optional, but supplied together)
 *
 * TLS policy: `requireTLS` is ALWAYS set, so a server that does not offer
 * STARTTLS fails the send instead of falling back to plaintext. `ignoreTLS`
 * and `tls.rejectUnauthorized` are never set. nodemailer's `logger`/`debug`
 * are never enabled (they dump the SMTP conversation, credentials included).
 *
 * Errors: only fixed text plus a sanitized error CODE. nodemailer messages
 * embed hosts, addresses and server responses, so they are never copied.
 */

const net = require('net');
const { NotifyConfigError, NotifySendError } = require('./index');

const CONNECTION_TIMEOUT_MS = 10000;
const GREETING_TIMEOUT_MS = 10000;
const SOCKET_TIMEOUT_MS = 20000;
const MAX_RECIPIENTS = 20;
const MAX_SUBJECT = 200;

// Deliberately simple: one @, no whitespace/angle/comma/CRLF, dotted domain.
const ADDR_RE = /^[^\s\x00-\x1f\x7f@<>,;"'\\]+@[^\s\x00-\x1f\x7f@<>,;"'\\.]+(\.[^\s\x00-\x1f\x7f@<>,;"'\\.]+)+$/;
const HOST_RE = /^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$/;

function parseRecipients(to) {
    if (Array.isArray(to)) return to.map((a) => (typeof a === 'string' ? a.trim() : a));
    if (typeof to === 'string') return to.split(',').map((a) => a.trim());
    return null;
}

function resolveMode(params) {
    const port = Number(params.port);
    const s = params.secure;
    if (s === undefined || s === null || s === '') return port === 465 ? 'implicit' : 'starttls';
    if (s === true || s === 'true' || s === 'implicit') return 'implicit';
    if (s === 'starttls') return 'starttls';
    // `false`, 'false', 'none', 'plain'... would mean plaintext: refuse.
    return null;
}

function validate(connection) {
    const params = (connection && connection.params) || {};
    const secrets = (connection && connection.secrets) || {};
    const bad = [];

    if (typeof params.host !== 'string' || params.host.trim().length > 253 || !HOST_RE.test(params.host.trim())) bad.push('host');
    const portOk = typeof params.port === 'number' || (typeof params.port === 'string' && /^\s*\d{1,5}\s*$/.test(params.port));
    const port = portOk ? Number(params.port) : NaN;
    if (!Number.isInteger(port) || port < 1 || port > 65535) bad.push('port');
    if (typeof params.from !== 'string' || !ADDR_RE.test(params.from.trim())) bad.push('from');
    const rcpts = parseRecipients(params.to);
    if (!rcpts || rcpts.length === 0 || rcpts.length > MAX_RECIPIENTS
        || !rcpts.every((a) => typeof a === 'string' && ADDR_RE.test(a))) bad.push('to');
    if (resolveMode(params) === null) bad.push('secure');

    const hasUser = secrets.user !== undefined && secrets.user !== '';
    const hasPass = secrets.pass !== undefined && secrets.pass !== '';
    if ((hasUser && typeof secrets.user !== 'string')
        || (hasPass && typeof secrets.pass !== 'string')
        || hasUser !== hasPass) {
        bad.push('user', 'pass');
    }

    if (bad.length) throw new NotifyConfigError(`email provider invalid fields: ${[...new Set(bad)].join(', ')}`);
}

function buildTransportOptions(connection) {
    const params = connection.params;
    const secrets = connection.secrets || {};
    const opts = {
        host: params.host.trim(),
        port: Number(params.port),
        secure: resolveMode(params) === 'implicit',
        requireTLS: true,
        connectionTimeout: CONNECTION_TIMEOUT_MS,
        greetingTimeout: GREETING_TIMEOUT_MS,
        socketTimeout: SOCKET_TIMEOUT_MS,
    };
    if (secrets.user && secrets.pass) opts.auth = { user: secrets.user, pass: secrets.pass };
    return opts;
}

function oneLine(s, max) {
    return String(s == null ? '' : s).replace(/[\r\n\u2028\u2029]+/g, ' ').trim().slice(0, max);
}

function buildMail(connection, message) {
    const m = message || {};
    const sev = oneLine(m.severity || 'info', 16).toUpperCase();
    const lines = [oneLine(m.title, 500), ''];
    if (m.body) lines.push(String(m.body), '');
    if (m.team) lines.push(`Team: ${oneLine(m.team, 100)}`);
    if (m.type) lines.push(`Type: ${oneLine(m.type, 100)}`);
    if (m.ref) lines.push(`Ref: ${oneLine(m.ref, 200)}`);
    if (m.severity) lines.push(`Severity: ${sev}`);
    return {
        from: connection.params.from.trim(),
        to: parseRecipients(connection.params.to),
        subject: oneLine(`[${sev}] ${m.title || ''}`, MAX_SUBJECT),
        text: lines.join('\n').trimEnd() + '\n',
    };
}

function safeCode(err) {
    const c = err && (err.code || err.responseCode);
    return typeof c === 'string' || typeof c === 'number'
        ? String(c).replace(/[^A-Za-z0-9_-]/g, '').slice(0, 32) : '';
}

function createEmailProvider({ createTransport } = {}) {
    const factory = createTransport || ((o) => require('nodemailer').createTransport(o));
    return {
        name: 'email',
        paramFields: ['host', 'port', 'from', 'to', 'secure'],
        secretFields: ['user', 'pass'],
        validate,
        async send(connection, message, ctx) {
            const signal = ctx && ctx.signal;
            if (signal && signal.aborted) throw new NotifySendError('email send aborted');
            let transport;
            let onAbort;
            // nodemailer's SMTP transport.close() does NOT cancel an in-flight
            // connection, so hand it a socket we own and destroy it on abort
            // (XACA-1401-006: a timed-out send otherwise lingered until the
            // 10 s / 20 s nodemailer timeouts).
            const socket = new net.Socket();
            try {
                transport = factory({ ...buildTransportOptions(connection), socket });
                const mail = buildMail(connection, message);
                const aborted = new Promise((_, reject) => {
                    if (!signal) return;
                    onAbort = () => {
                        try { socket.destroy(); } catch (_e) { /* best effort */ }
                        try { transport.close(); } catch (_e) { /* best effort */ }
                        reject(new NotifySendError('email send aborted'));
                    };
                    signal.addEventListener('abort', onAbort, { once: true });
                });
                const sent = Promise.resolve(transport.sendMail(mail));
                sent.catch(() => {}); // avoid unhandled rejection if abort wins the race
                const info = await Promise.race([sent, aborted]);
                const out = {};
                if (info && typeof info.messageId === 'string' && info.messageId) out.providerMessageId = info.messageId;
                return out;
            } catch (err) {
                if (err instanceof NotifySendError) throw err;
                const code = safeCode(err);
                throw new NotifySendError(code ? `email send failed (${code})` : 'email send failed');
            } finally {
                if (signal && onAbort) signal.removeEventListener('abort', onAbort);
                try { socket.destroy(); } catch (_e) { /* best effort */ }
                if (transport) { try { transport.close(); } catch (_e) { /* best effort */ } }
            }
        },
    };
}

module.exports = { createEmailProvider, buildTransportOptions };
