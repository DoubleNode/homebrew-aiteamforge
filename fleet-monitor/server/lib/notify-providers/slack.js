//
//  slack.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Slack notify provider (XACA-1401-002, EPIC-0068 D5). Incoming webhook.
 *
 *   secretFields: ['webhookUrl']   the webhook URL IS the credential
 *   paramFields:  []
 *
 * Fail-closed host policy: https only, host EXACTLY hooks.slack.com, path under
 * /services/, no embedded credentials or custom port. Anything else is
 * rejected at validate() so a connection can never point the hub at an
 * arbitrary host (SSRF) with a Slack-shaped payload.
 *
 * Error messages carry field names / status codes / error types only: never
 * the URL, message text or foreign exception text (see lib/notify-scrub.js).
 * Webhooks return the literal text `ok` and no message id, so none is returned.
 */

const { NotifyConfigError, NotifySendError, errorTypeName } = require('./index');

const HEADER_MAX = 150;      // Slack header block plain_text limit
const SECTION_MAX = 3000;    // section text limit
const CONTEXT_MAX = 300;     // keep context elements short (limit is 2000)
const FALLBACK_MAX = 3000;

/** severity -> attachment sidebar colour. */
const SEVERITY_COLORS = Object.freeze({
    info: '#2eb67d',
    warning: '#ecb22e',
    high: '#e8912d',
    critical: '#e01e5a',
});
const DEFAULT_COLOR = SEVERITY_COLORS.info;

function truncate(s, max) {
    const str = String(s == null ? '' : s);
    const chars = Array.from(str);
    if (chars.length <= max) return str;
    return chars.slice(0, max - 1).join('') + '…';
}

/** Slack mrkdwn control characters. */
function escapeMrkdwn(s) {
    return String(s == null ? '' : s)
        .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function isHttpUrl(s) {
    try {
        const u = new URL(s);
        return u.protocol === 'https:' || u.protocol === 'http:';
    } catch (_) { return false; }
}

function checkWebhookUrl(raw) {
    if (typeof raw !== 'string' || !raw.trim()) {
        throw new NotifyConfigError('slack provider requires webhookUrl');
    }
    let u;
    try { u = new URL(raw.trim()); } catch (_) {
        throw new NotifyConfigError('slack webhookUrl is not a valid URL');
    }
    if (u.protocol !== 'https:' || u.hostname !== 'hooks.slack.com' || u.port
        || u.username || u.password || !u.pathname.startsWith('/services/')
        || u.pathname.length <= '/services/'.length) {
        throw new NotifyConfigError('slack webhookUrl must be a Slack incoming-webhook URL');
    }
    return u.toString();
}

function buildPayload(message) {
    const m = message || {};
    const severity = Object.prototype.hasOwnProperty.call(SEVERITY_COLORS, m.severity) ? m.severity : 'info';
    const title = String(m.title || '').trim() || '(no title)';
    const body = String(m.body || '');
    const ref = String(m.ref || '').trim();

    const blocks = [
        { type: 'header', text: { type: 'plain_text', text: truncate(title, HEADER_MAX), emoji: false } },
    ];
    if (body.trim()) {
        blocks.push({ type: 'section', text: { type: 'mrkdwn', text: truncate(escapeMrkdwn(body), SECTION_MAX) } });
    }
    const ctx = [];
    const meta = [m.team, m.type, severity].filter((x) => typeof x === 'string' && x).join(' | ');
    if (meta) ctx.push({ type: 'mrkdwn', text: truncate(escapeMrkdwn(meta), CONTEXT_MAX) });
    if (ref) {
        const label = truncate(escapeMrkdwn(ref), CONTEXT_MAX);
        const text = isHttpUrl(ref)
            ? `<${ref.replace(/[<>|\s]/g, encodeURIComponent)}|${label}>`
            : `ref: ${label}`;
        ctx.push({ type: 'mrkdwn', text });
    }
    if (ctx.length) blocks.push({ type: 'context', elements: ctx.slice(0, 10) });

    // Top-level `text` is rendered as mrkdwn by Slack: escape it or a body of
    // `<!channel>` pings the channel (XACA-1401-006).
    const fallback = truncate(escapeMrkdwn(body.trim() ? `${title}\n${body}` : title), FALLBACK_MAX);
    return {
        text: fallback,
        attachments: [{ color: SEVERITY_COLORS[severity] || DEFAULT_COLOR, fallback: truncate(title, HEADER_MAX), blocks }],
    };
}

function createSlackProvider({ fetchImpl } = {}) {
    return {
        name: 'slack',
        paramFields: [],
        secretFields: ['webhookUrl'],
        validate(connection) {
            checkWebhookUrl(connection && connection.secrets && connection.secrets.webhookUrl);
        },
        async send(connection, message, ctx) {
            const signal = ctx && ctx.signal;
            const url = checkWebhookUrl(connection && connection.secrets && connection.secrets.webhookUrl);
            const doFetch = fetchImpl || globalThis.fetch;
            let res;
            try {
                res = await doFetch(url, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(buildPayload(message)),
                    redirect: 'error',
                    signal,
                });
            } catch (err) {
                // Type only: a fetch error's text can embed the URL.
                if (signal && signal.aborted) throw new NotifySendError('slack send aborted');
                throw new NotifySendError(`slack request failed (${errorTypeName(err)})`);
            }
            if (!res || !res.ok) {
                const status = res && Number.isInteger(res.status) ? res.status : 'unknown';
                throw new NotifySendError(`slack webhook returned status ${status}`);
            }
            return {};
        },
    };
}

module.exports = { createSlackProvider, buildPayload, SEVERITY_COLORS, escapeMrkdwn, truncate };
