//
//  notify-policies.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Notification dispatcher policies (XACA-1400-004, EPIC-0068 D6).
 *
 * Pure policy building blocks the dispatcher composes. No I/O, no network.
 * Semantics mirror kanban-hooks/release_notify_routing.py (XACA-1399), which
 * is the source of truth: SEVERITIES, DEFAULT_DEDUPE_WINDOW_SECONDS, the
 * HH:MM grammar, [start,end) quiet hours that may span midnight, and the
 * dedupe key "team|type|ref" with a missing/empty ref keyed as "".
 *
 * STATE IS IN-MEMORY. A server restart resets every dedupe and rate window.
 * Acceptable for the MVP (worst case: one extra notice after a restart).
 *
 * Policy order, enforced by the dispatcher not here: quiet-hours -> dedupe
 * -> per-connection rate limit.
 *
 * Quiet hours
 *  - critical ALWAYS bypasses quiet hours. It does NOT bypass dedupe or the
 *    rate limiter: those apply to every severity (the plan scopes the
 *    critical bypass to quiet hours only).
 *  - Bad input fails TOWARD DELIVERY but VISIBLY: an unknown timezone,
 *    malformed/equal start/end, bad severity or bad clock returns
 *    { suppress: false, warning: '<code>' } so the dispatcher can surface it.
 *    A broken config must never silently swallow a notice, nor silently read
 *    as "not quiet".
 *
 * Dedupe: WHEN is a key recorded?
 *  check() is READ-ONLY. record() is a separate call the dispatcher makes
 *  only AFTER the notice was delivered to at least one connection.
 *  Therefore none of these open a window: quiet-hours suppression,
 *  rate-limit suppression, or a notice that failed on every connection.
 *  A failure can never hide a later retry, and a quiet-hours notice is not
 *  swallowed forever once quiet hours end. A dedupe-suppressed notice does
 *  NOT refresh the window (fixed window from the first delivery).
 *  Caveat: check and record are not atomic across awaited deliveries; two
 *  identical notices in flight at once can both pass. Acceptable for MVP.
 *
 * Rate limiter: sliding-window log per connection. Denied attempts are not
 * counted (a denied notice does not extend its own penalty).
 *
 * Memory is bounded everywhere (entry caps, oldest evicted first).
 */

const SEVERITIES = ['info', 'warning', 'high', 'critical']; // ascending
const DEFAULT_DEDUPE_WINDOW_SECONDS = 300;
const DEFAULT_DEDUPE_MAX_ENTRIES = 10000;
const DEFAULT_RATE_LIMIT = 20;
const DEFAULT_RATE_WINDOW_SECONDS = 600;
const DEFAULT_RATE_MAX_CONNECTIONS = 1000;

// Same grammar as Python HHMM_RE; the (?![\s\S]) is "end of string" (no
// trailing newline, unlike $).
const HHMM_RE = /^([01][0-9]|2[0-3]):([0-5][0-9])(?![\s\S])/;

function severityRank(s) {
    return SEVERITIES.indexOf(s);
}

function isValidSeverity(s) {
    return typeof s === 'string' && SEVERITIES.includes(s);
}

function nowMs(clock) {
    return +new Date(clock());
}

// ---------------------------------------------------------------- quiet hours

function minutes(hhmm) {
    const m = typeof hhmm === 'string' ? HHMM_RE.exec(hhmm) : null;
    return m ? parseInt(m[1], 10) * 60 + parseInt(m[2], 10) : null;
}

const formatters = new Map(); // zone -> Intl.DateTimeFormat | null (invalid)
const FORMATTER_CAP = 64;

function formatterFor(zone) {
    if (formatters.has(zone)) return formatters.get(zone);
    let fmt = null;
    // Python requires the canonical name; Intl is case-insensitive and also
    // accepts offset zones. Reject both so the two runtimes agree.
    if (typeof zone === 'string' && zone && !/^[+-]/.test(zone)) {
        try {
            const f = new Intl.DateTimeFormat('en-GB', {
                timeZone: zone, hourCycle: 'h23', hour: '2-digit', minute: '2-digit',
            });
            const resolved = f.resolvedOptions().timeZone;
            const caseOnlyMismatch = resolved !== zone && resolved.toLowerCase() === zone.toLowerCase();
            fmt = caseOnlyMismatch ? null : f;
        } catch (_) { fmt = null; }
    }
    if (formatters.size >= FORMATTER_CAP) formatters.delete(formatters.keys().next().value);
    formatters.set(zone, fmt);
    return fmt;
}

function localMinutes(fmt, date) {
    const parts = fmt.formatToParts(date);
    const h = parseInt(parts.find((p) => p.type === 'hour').value, 10) % 24;
    const m = parseInt(parts.find((p) => p.type === 'minute').value, 10);
    return h * 60 + m;
}

/**
 * Should a notice of `severity` be suppressed at `now`?
 * @returns {{suppress: boolean, reason?: 'quiet-hours', warning?: string}}
 */
function quietHoursDecision(severity, quietHours, now) {
    if (!isValidSeverity(severity)) return { suppress: false, warning: 'invalid-severity' };
    if (!quietHours) return { suppress: false };
    const date = now instanceof Date ? now : new Date(now);
    if (Number.isNaN(date.getTime())) return { suppress: false, warning: 'invalid-time' };

    const start = minutes(quietHours.start);
    const end = minutes(quietHours.end);
    if (start === null || end === null || start === end) {
        return { suppress: false, warning: 'invalid-quiet-hours' };
    }
    const fmt = formatterFor(quietHours.timezone);
    if (!fmt) return { suppress: false, warning: 'invalid-timezone' };

    const cur = localMinutes(fmt, date);
    const inside = start < end ? (cur >= start && cur < end) : (cur >= start || cur < end);
    if (!inside || severity === 'critical') return { suppress: false };
    return { suppress: true, reason: 'quiet-hours' };
}

// --------------------------------------------------------------------- dedupe

function dedupeKey(team, type, ref) {
    return `${team}|${type}|${ref || ''}`;
}

function createDedupeTracker(opts = {}) {
    const clock = opts.clock || (() => new Date());
    const maxEntries = Number.isInteger(opts.maxEntries) && opts.maxEntries > 0
        ? opts.maxEntries : DEFAULT_DEDUPE_MAX_ENTRIES;
    const seen = new Map(); // key -> expiresAtMs (insertion order = age)

    function resolveWindow(windowSeconds) {
        if (windowSeconds === undefined) return DEFAULT_DEDUPE_WINDOW_SECONDS;
        // Invalid values fail toward delivery (treated as disabled).
        if (!Number.isFinite(windowSeconds) || windowSeconds < 0) return 0;
        return windowSeconds;
    }

    function prune(t) {
        // Front-prune expired entries; stops at the first live one, and the
        // hard cap below bounds anything mixed windows leave behind.
        for (const [k, exp] of seen) {
            if (exp > t) break;
            seen.delete(k);
        }
    }

    /** READ-ONLY. Does not open a window. */
    function check(team, type, ref, windowSeconds) {
        const key = dedupeKey(team, type, ref);
        if (resolveWindow(windowSeconds) === 0) return { duplicate: false, key };
        const exp = seen.get(key);
        const t = nowMs(clock);
        if (exp === undefined) return { duplicate: false, key };
        if (exp <= t) { seen.delete(key); return { duplicate: false, key }; }
        return { duplicate: true, key };
    }

    /** Open the window. Call only after a successful delivery. */
    function record(team, type, ref, windowSeconds) {
        const key = dedupeKey(team, type, ref);
        const w = resolveWindow(windowSeconds);
        if (w === 0) return { recorded: false, key };
        const t = nowMs(clock);
        prune(t);
        seen.delete(key); // re-insert at the young end
        seen.set(key, t + w * 1000);
        while (seen.size > maxEntries) seen.delete(seen.keys().next().value);
        return { recorded: true, key };
    }

    return { check, record, size: () => seen.size };
}

// ----------------------------------------------------------------- rate limit

function createRateLimiter(opts = {}) {
    const clock = opts.clock || (() => new Date());
    const limit = Number.isInteger(opts.limit) && opts.limit > 0 ? opts.limit : DEFAULT_RATE_LIMIT;
    const windowSeconds = Number.isFinite(opts.windowSeconds) && opts.windowSeconds > 0
        ? opts.windowSeconds : DEFAULT_RATE_WINDOW_SECONDS;
    const maxConnections = Number.isInteger(opts.maxConnections) && opts.maxConnections > 0
        ? opts.maxConnections : DEFAULT_RATE_MAX_CONNECTIONS;
    const windowMs = windowSeconds * 1000;
    const buckets = new Map(); // connectionId -> [ts, ...] ascending, <= limit long

    /** Consume one slot for `connectionId`, or say when to retry. */
    function take(connectionId) {
        const t = nowMs(clock);
        const key = String(connectionId);
        let stamps = buckets.get(key);
        if (!stamps) {
            stamps = [];
        } else {
            buckets.delete(key); // re-insert below so eviction order = recency
        }
        while (stamps.length && stamps[0] <= t - windowMs) stamps.shift();

        let result;
        if (stamps.length >= limit) {
            const retryMs = stamps[0] + windowMs - t;
            result = { allowed: false, retryAfterSeconds: Math.max(1, Math.ceil(retryMs / 1000)) };
        } else {
            stamps.push(t);
            result = { allowed: true };
        }
        buckets.set(key, stamps);
        while (buckets.size > maxConnections) buckets.delete(buckets.keys().next().value);
        return result;
    }

    return { take, size: () => buckets.size };
}

module.exports = {
    SEVERITIES,
    DEFAULT_DEDUPE_WINDOW_SECONDS,
    severityRank,
    isValidSeverity,
    quietHoursDecision,
    createDedupeTracker,
    createRateLimiter,
};
