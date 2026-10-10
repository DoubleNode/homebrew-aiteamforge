//
//  pushover.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Pushover notify provider (XACA-1401-004, EPIC-0068 D5).
 *
 * secrets: appToken, userKey.  param (optional): device.
 * Severity -> priority: info -1, warning 0, high 1, critical 2. Priority 2
 * (emergency) is rejected by Pushover without retry/expire, so they are always
 * sent with it (retry 60 s, expire 3600 s).
 *
 * Error messages are static text plus an HTTP status or error TYPE - never a
 * token, user key, device, URL or response body. One POST, no retries, no
 * redirects.
 */

const { NotifyConfigError, NotifySendError, errorTypeName } = require('./index');

const ENDPOINT = 'https://api.pushover.net/1/messages.json';
const PRIORITY = { info: -1, warning: 0, high: 1, critical: 2 };
const EMERGENCY_RETRY_S = 60;
const EMERGENCY_EXPIRE_S = 3600;
const LIMITS = { title: 250, message: 1024, url: 512 };

function str(v) { return typeof v === 'string' ? v.trim() : ''; }
function secret(c, k) { return str(c && c.secrets && c.secrets[k]); }

function trunc(s, max) {
    const chars = Array.from(s);
    return chars.length <= max ? s : chars.slice(0, max - 1).join('') + '…';
}

function createPushoverProvider({ fetchImpl } = {}) {
    const doFetch = fetchImpl || ((...a) => globalThis.fetch(...a));
    return {
        name: 'pushover',
        paramFields: ['device'],
        secretFields: ['appToken', 'userKey'],
        validate(connection) {
            if (!secret(connection, 'appToken')) throw new NotifyConfigError('pushover secret appToken is required');
            if (!secret(connection, 'userKey')) throw new NotifyConfigError('pushover secret userKey is required');
            const d = connection && connection.params && connection.params.device;
            if (d !== undefined && d !== null && d !== '' && (typeof d !== 'string' || !/^[A-Za-z0-9_-]{1,25}(,[A-Za-z0-9_-]{1,25})*$/.test(d.trim()))) {
                throw new NotifyConfigError('pushover param device is invalid');
            }
        },
        async send(connection, message, { signal } = {}) {
            const m = message || {};
            const sev = Object.prototype.hasOwnProperty.call(PRIORITY, m.severity) ? m.severity : 'info';
            const priority = PRIORITY[sev];
            const title = str(m.title);
            const text = str(m.body) || title || '(no message)';
            const form = new URLSearchParams();
            form.set('token', secret(connection, 'appToken'));
            form.set('user', secret(connection, 'userKey'));
            form.set('message', trunc(text, LIMITS.message));
            if (title) form.set('title', trunc(title, LIMITS.title));
            form.set('priority', String(priority));
            if (priority === 2) {
                form.set('retry', String(EMERGENCY_RETRY_S));
                form.set('expire', String(EMERGENCY_EXPIRE_S));
            }
            const device = str(connection && connection.params && connection.params.device);
            if (device) form.set('device', device);
            const ref = str(m.ref);
            if (/^https?:\/\//i.test(ref)) form.set('url', trunc(ref, LIMITS.url));

            let res;
            try {
                res = await doFetch(ENDPOINT, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                    body: form.toString(),
                    redirect: 'manual',
                    signal,
                });
            } catch (err) {
                throw new NotifySendError(`pushover transport error (${errorTypeName(err)})`);
            }
            const status = res && res.status;
            if (!Number.isInteger(status) || status < 200 || status >= 300) {
                throw new NotifySendError(`pushover returned HTTP ${Number.isInteger(status) ? status : 0}`);
            }
            let body = null;
            try { body = await res.json(); } catch (_e) { body = null; }
            if (!body || body.status !== 1) throw new NotifySendError('pushover rejected the message');
            return typeof body.request === 'string' && body.request ? { providerMessageId: body.request } : {};
        },
    };
}

module.exports = { createPushoverProvider, PRIORITY, LIMITS, ENDPOINT };
